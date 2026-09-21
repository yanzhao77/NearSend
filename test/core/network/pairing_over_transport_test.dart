/// The server-side negotiation, end to end, over a real TLS connection.
///
/// `POST /v1/pair` is the one route §7 exempts from a bearer, and everything else needs the
/// token it returns. That makes this loop the shortest thing that can be wrong in a way no
/// unit test would catch: an issuer that produces a token its own authenticator will not
/// accept passes every test on both sides and still fails the first real pairing.
///
/// So the assertions here follow the credential rather than the status codes: the token that
/// comes out of `/v1/pair` is the token that creates a transfer, and the task row is checked
/// in the database rather than inferred from a 201.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:nearsend/core/network/control_message.dart';
import 'package:nearsend/core/network/control_pipeline.dart';
import 'package:nearsend/core/network/https_control_client.dart';
import 'package:nearsend/core/network/https_control_server.dart';
import 'package:nearsend/core/network/transfer_creation_handler.dart';
import 'package:nearsend/core/protocol/api_routes.dart';
import 'package:nearsend/core/protocol/base64url.dart';
import 'package:nearsend/core/protocol/protocol_exception.dart';
import 'package:nearsend/core/security/pair_request.dart';
import 'package:nearsend/core/security/pairing_payload.dart';
import 'package:nearsend/core/security/pairing_service.dart';
import 'package:nearsend/core/security/tls_identity.dart';
import 'package:nearsend/core/storage/chunk_repository.dart';
import 'package:nearsend/core/storage/idempotency_repository.dart';
import 'package:nearsend/core/storage/near_send_database.dart';
import 'package:nearsend/core/storage/transfer_repository.dart';

void main() {
  late Directory dir;
  late NearSendDatabase database;
  late TlsIdentity identity;
  late PairingService pairing;
  late HttpsControlServer server;

  const String transferId = '99999999-8888-4777-8666-555555555555';
  const String digest =
      'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('nearsend-pairing-');
    database = NearSendDatabase.open(
      path: '${dir.path}${Platform.pathSeparator}pairing.db',
    );

    identity = generateTlsIdentity(
      commonName: 'NearSend',
      subjectAltNames: <String>['127.0.0.1'],
    );

    final TransferCreationEndpoint creation = TransferCreationEndpoint(
      idempotency: IdempotencyRepository(database),
      transfers: TransferRepository(database),
      tasks: ChunkRepository(database),
      now: () => 1000,
    );

    pairing = PairingService(
      serverFingerprint: identity.pin,
      candidates: <PairingCandidate>[
        PairingCandidate(host: '127.0.0.1', port: 0),
      ],
    );

    server = HttpsControlServer(
      identity: identity,
      pipeline: ControlPipeline(
        authenticator: pairing,
        handlers: <String, ControlHandler>{
          ...pairing.handlers(),
          ApiRoutes.createTransfer.name: creation.handler,
        },
      ),
      address: InternetAddress.loopbackIPv4,
    );
    await server.start();
  });

  tearDown(() async {
    await server.stop();
    database.close();
    if (dir.existsSync()) {
      dir.deleteSync(recursive: true);
    }
  });

  int taskCount() =>
      database.db.select('SELECT COUNT(*) AS c FROM tasks;').first['c'] as int;

  HttpsControlClient clientWithPin(String pin) =>
      HttpsControlClient(pin: pin, host: '127.0.0.1', port: server.boundPort);

  ControlRequest pairRequest(
    PairingPayload payload, {
    String? token,
  }) => ControlRequest(
    method: HttpMethod.post,
    target: '/v1/pair',
    headers: <String, String>{
      // §7: pair is the stated exception, so no Authorization header is sent.
      'content-type': 'application/json; charset=utf-8',
    },
    body: Uint8List.fromList(
      utf8.encode(
        jsonEncode(
          PairRequest(
            requestId: randomUuidV4(),
            sessionId: payload.sessionId,
            pairToken: token ?? payload.pairToken,
            clientLabel: 'android sender',
          ).toJson(),
        ),
      ),
    ),
  );

  ControlRequest createRequest(String sessionToken) => ControlRequest(
    method: HttpMethod.post,
    target: '/v1/transfers',
    headers: <String, String>{
      'authorization': 'Bearer $sessionToken',
      'content-type': 'application/json; charset=utf-8',
    },
    body: Uint8List.fromList(
      utf8.encode(
        jsonEncode(<String, Object?>{
          'requestId': randomUuidV4(),
          'transferId': transferId,
          'manifestDigest': digest,
          'fileCount': 1,
          'totalBytes': '4096',
          'direction': 'client_to_server',
        }),
      ),
    ),
  );

  test(
    'pair, then use the token it returned, over one TLS connection pair',
    () async {
      final HttpsControlClient client = clientWithPin(identity.pin);
      final PairingPayload payload = pairing.openSession();

      final ReceivedControlResponse paired = await client.send(
        pairRequest(payload),
      );
      expect(
        paired.status,
        200,
        reason: 'body: ${utf8.decode(paired.body, allowMalformed: true)}',
      );
      final String sessionToken = PairResponse.parse(paired.decodeJsonBody())
          .sessionAccessToken;
      expect(taskCount(), 0, reason: 'pairing alone creates nothing');

      final ReceivedControlResponse created = await client.send(
        createRequest(sessionToken),
      );
      expect(
        created.status,
        201,
        reason: 'body: ${utf8.decode(created.body, allowMalformed: true)}',
      );
      expect(created.decodeJsonBody()['state'], 'STAGING');
      expect(
        taskCount(),
        1,
        reason: 'the token really authorised a state change',
      );

      client.close();
    },
  );

  test(
    'a session token cannot be guessed at, and a bad one creates nothing',
    () async {
      final HttpsControlClient client = clientWithPin(identity.pin);
      pairing.openSession();

      final ReceivedControlResponse response = await client.send(
        createRequest(encodeBase64UrlNoPadding(List<int>.filled(32, 0x7f))),
      );

      expect(response.status, 401);
      expect(response.decodeError().code, ProtocolErrorCode.authExpired);
      expect(taskCount(), 0);
      client.close();
    },
  );

  test(
    'a pairing token that was never issued is refused before anything else',
    () async {
      final HttpsControlClient client = clientWithPin(identity.pin);
      final PairingPayload payload = pairing.openSession();

      final ReceivedControlResponse response = await client.send(
        pairRequest(
          payload,
          token: encodeBase64UrlNoPadding(List<int>.filled(32, 0x22)),
        ),
      );

      expect(response.status, 401);
      expect(response.decodeError().code, ProtocolErrorCode.pairRejected);
      expect(taskCount(), 0);
      client.close();
    },
  );

  test('a client that cannot prove the pin never reaches /v1/pair', () async {
    final TlsIdentity other = generateTlsIdentity(
      commonName: 'Not NearSend',
      subjectAltNames: <String>['127.0.0.1'],
    );
    final HttpsControlClient client = clientWithPin(other.pin);
    final PairingPayload payload = pairing.openSession();

    await expectLater(
      client.send(pairRequest(payload)),
      throwsA(isA<ProtocolViolation>()),
    );
    // The honest statement is narrower than "nothing happened": the pairing token was never
    // presented, so it is still outstanding and could still be used by whoever holds the QR.
    expect(pairing.liveSessionCount, 0, reason: 'no session was authorised');
    client.close();
  });
}
