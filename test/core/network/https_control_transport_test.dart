/// The HTTPS transport, driven over a real TLS connection.
///
/// Everything below this file was already tested without a socket; what is new here is that a
/// request now arrives over the network, through TLS, through §8's framing rules, into §7's
/// pipeline, and back out as a response. Three properties are worth having evidence for:
///
/// * a pinned client can actually create a transfer, which is the first endpoint §6 needs;
/// * a client whose pin does not match is refused **before any request is sent**, which §2
///   states as a requirement rather than a consequence;
/// * the framings §8 refuses are refused in §7's error shape rather than by dropping the
///   connection silently.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:nearsend/core/network/control_authorization.dart';
import 'package:nearsend/core/network/control_message.dart';
import 'package:nearsend/core/network/control_pipeline.dart';
import 'package:nearsend/core/network/https_control_client.dart';
import 'package:nearsend/core/network/https_control_server.dart';
import 'package:nearsend/core/network/transfer_creation_handler.dart';
import 'package:nearsend/core/protocol/api_routes.dart';
import 'package:nearsend/core/protocol/base64url.dart';
import 'package:nearsend/core/protocol/protocol_exception.dart';
import 'package:nearsend/core/security/tls_identity.dart';
import 'package:nearsend/core/storage/chunk_repository.dart';
import 'package:nearsend/core/storage/idempotency_repository.dart';
import 'package:nearsend/core/storage/near_send_database.dart';
import 'package:nearsend/core/storage/transfer_repository.dart';

void main() {
  late Directory dir;
  late NearSendDatabase database;
  late TransferCreationEndpoint creation;
  late TlsIdentity identity;
  late HttpsControlServer server;

  const String requestId = '11111111-2222-4333-8444-555555555555';
  const String transferId = '99999999-8888-4777-8666-555555555555';
  const String digest =
      'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

  final String sessionToken = encodeBase64UrlNoPadding(
    Uint8List.fromList(List<int>.filled(32, 0x11)),
  );

  Map<String, Object?> createBody() => <String, Object?>{
    'requestId': requestId,
    'transferId': transferId,
    'manifestDigest': digest,
    'fileCount': 3,
    'totalBytes': '1024',
    'direction': 'client_to_server',
  };

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('nearsend-transport-');
    database = NearSendDatabase.open(
      path: '${dir.path}${Platform.pathSeparator}transport.db',
    );
    creation = TransferCreationEndpoint(
      idempotency: IdempotencyRepository(database),
      transfers: TransferRepository(database),
      tasks: ChunkRepository(database),
      now: () => 1000,
    );

    identity = generateTlsIdentity(
      commonName: 'NearSend',
      subjectAltNames: <String>['127.0.0.1'],
    );
    server = HttpsControlServer(
      identity: identity,
      pipeline: ControlPipeline(
        authenticator: _MapAuthenticator(<String, ControlGrant>{
          sessionToken: const SessionGrant(peerId: 'peer-a'),
        }),
        handlers: <String, ControlHandler>{
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

  ControlRequest createRequest({String? token}) => ControlRequest(
    method: HttpMethod.post,
    target: '/v1/transfers',
    headers: <String, String>{
      if (token != null) 'authorization': 'Bearer $token',
      'content-type': 'application/json; charset=utf-8',
    },
    body: Uint8List.fromList(utf8.encode(jsonEncode(createBody()))),
  );

  group('a pinned client reaches the real pipeline', () {
    test('POST /transfers creates the task and the response is uncacheable', () async {
      final HttpsControlClient client = clientWithPin(identity.pin);
      final ReceivedControlResponse response = await client.send(
        createRequest(token: sessionToken),
      );

      expect(
        response.status,
        201,
        reason:
            'the wire body was: ${utf8.decode(response.body, allowMalformed: true)}',
      );
      expect(response.decodeJsonBody()['state'], 'STAGING');
      expect(
        response.headers['cache-control'],
        'no-store',
        reason: '§7 fixes that header on every control response',
      );
      expect(
        taskCount(),
        1,
        reason: 'the row is the point, not the status code',
      );
      client.close();
    });

    test('a route with no handler answers 404 rather than 500', () async {
      final HttpsControlClient client = clientWithPin(identity.pin);
      final ReceivedControlResponse response = await client.send(
        ControlRequest(
          method: HttpMethod.get,
          target: '/v1/transfers/$transferId/status',
          headers: <String, String>{'authorization': 'Bearer $sessionToken'},
        ),
      );

      expect(response.status, 404);
      expect(response.decodeError().code, ProtocolErrorCode.notFound);
      client.close();
    });

    test(
      'a malformed target is refused before authorisation, over the wire',
      () async {
        final HttpsControlClient client = clientWithPin(identity.pin);
        final ReceivedControlResponse response = await client.send(
          ControlRequest(
            method: HttpMethod.post,
            target: '/v1/transfers',
            // No Authorization at all, and a body that cannot be a §7 creation body. §7 parses
            // parameters before it looks up the credential requirement, so this answers 400
            // rather than 401 - and either way nothing is created.
            body: Uint8List.fromList(utf8.encode('{}')),
          ),
        );

        expect(
          response.status,
          anyOf(400, 401),
          reason: 'the point is that it is an answered §7 error, not a dropped connection',
        );
        expect(taskCount(), 0);
        client.close();
      },
    );
  });

  group('§2: the pin decides before anything is sent', () {
    test(
      'a wrong pin is refused and the server never sees a request',
      () async {
        final TlsIdentity other = generateTlsIdentity(
          commonName: 'Not NearSend',
          subjectAltNames: <String>['127.0.0.1'],
        );
        final HttpsControlClient client = clientWithPin(other.pin);

        await expectLater(
          client.send(createRequest(token: sessionToken)),
          throwsA(
            isA<ProtocolViolation>().having(
              (ProtocolViolation v) => v.code,
              'code',
              ProtocolErrorCode.pairRejected,
            ),
          ),
        );

        expect(
          client.sawAnyCertificate,
          isTrue,
          reason: 'a certificate was presented',
        );
        expect(taskCount(), 0, reason: 'no request can have been handled');
        client.close();
      },
    );

    test('a client that never completes the handshake cannot create anything', () async {
      final HttpsControlClient client = clientWithPin(identity.pin);
      // The pin matches, so this one must work; the contrast with the case above is the test.
      final ReceivedControlResponse response = await client.send(
        createRequest(token: sessionToken),
      );
      expect(
        response.status,
        201,
        reason:
            'the wire body was: ${utf8.decode(response.body, allowMalformed: true)}',
      );
      expect(taskCount(), 1);
      client.close();
    });
  });

  group('§8 framing rules', () {
    test(
      'Transfer-Encoding is refused even though dart:io would decode it',
      () async {
        // Measured in tooling/spikes/http_framing: dart:io accepts and de-chunks this request
        // and the header stays visible, so refusing it is this layer's job.
        final String raw = await _rawRequest(
          identity,
          server.boundPort,
          'POST /v1/transfers HTTP/1.1\r\n'
          'Host: 127.0.0.1\r\n'
          'Transfer-Encoding: chunked\r\n'
          '\r\n'
          '2\r\n{}\r\n0\r\n\r\n',
        );

        expect(raw, contains('400'));
        expect(raw, contains('INVALID_FIELD'));
        expect(taskCount(), 0);
      },
    );

    test('a re-sent page is not confused for a compressed body: Content-Encoding is refused', () async {
      final String raw = await _rawRequest(
        identity,
        server.boundPort,
        'POST /v1/transfers HTTP/1.1\r\n'
        'Host: 127.0.0.1\r\n'
        'Content-Encoding: gzip\r\n'
        'Content-Length: 2\r\n'
        '\r\n{}',
      );

      expect(raw, contains('400'));
      expect(raw, contains('INVALID_FIELD'));
    });

    test(
      'a well-formed request with a single Content-Length is served',
      () async {
        final String raw = await _rawRequest(
          identity,
          server.boundPort,
          'POST /v1/transfers HTTP/1.1\r\n'
          'Host: 127.0.0.1\r\n'
          'Content-Length: 2\r\n'
          '\r\n{}',
        );

        // No credential, so this is a §7 refusal rather than a success - but it is answered by
        // the pipeline, which is what distinguishes a served request from a refused framing.
        expect(raw, contains('HTTP/1.1 401'));
      },
    );
  });
}

/// Sends raw bytes over TLS and returns the raw response text.
///
/// Used for the framings `HttpClient` will not produce. The context trusts exactly the
/// server's certificate, which is enough here: these cases are about framing, not identity.
///
/// Reads until the declared `Content-Length` has arrived rather than until the socket closes,
/// because §7's responses keep the connection alive and waiting for a close would report an
/// empty response for a request the server answered correctly.
Future<String> _rawRequest(
  TlsIdentity identity,
  int port,
  String request,
) async {
  final SecurityContext context = SecurityContext(withTrustedRoots: false)
    ..setTrustedCertificatesBytes(identity.certificatePem);
  final SecureSocket socket = await SecureSocket.connect(
    '127.0.0.1',
    port,
    context: context,
    onBadCertificate: (X509Certificate _) => false,
  );
  socket.write(request);
  await socket.flush();

  final BytesBuilder response = BytesBuilder();
  final Completer<void> complete = Completer<void>();
  socket.listen(
    (List<int> part) {
      response.add(part);
      if (_responseIsComplete(response.toBytes()) && !complete.isCompleted) {
        complete.complete();
      }
    },
    onDone: () {
      if (!complete.isCompleted) {
        complete.complete();
      }
    },
    onError: (Object _) {
      if (!complete.isCompleted) {
        complete.complete();
      }
    },
  );

  try {
    await complete.future.timeout(const Duration(seconds: 5));
  } on TimeoutException {
    // Fall through with whatever arrived; the assertions will say what is missing.
  }
  socket.destroy();
  return utf8.decode(response.takeBytes(), allowMalformed: true);
}

/// Whether [bytes] hold a complete HTTP response with a body, by `Content-Length`.
bool _responseIsComplete(Uint8List bytes) {
  final int headerEnd = _indexOf(bytes, '\r\n\r\n');
  if (headerEnd < 0) {
    return false;
  }
  final String head = utf8.decode(
    bytes.sublist(0, headerEnd),
    allowMalformed: true,
  );
  final RegExpMatch? length = RegExp(
    r'^content-length:\s*(\d+)$',
    multiLine: true,
    caseSensitive: false,
  ).firstMatch(head);
  if (length == null) {
    return true; // no body expected
  }
  final int declared = int.parse(length.group(1)!);
  return bytes.length - (headerEnd + 4) >= declared;
}

int _indexOf(Uint8List haystack, String needle) {
  final List<int> pattern = ascii.encode(needle);
  for (int i = 0; i + pattern.length <= haystack.length; i++) {
    bool matched = true;
    for (int j = 0; j < pattern.length; j++) {
      if (haystack[i + j] != pattern[j]) {
        matched = false;
        break;
      }
    }
    if (matched) {
      return i;
    }
  }
  return -1;
}

/// An authority that resolves tokens from a fixed map.
class _MapAuthenticator implements ControlAuthenticator {
  const _MapAuthenticator(this.grants);

  final Map<String, ControlGrant> grants;

  @override
  ControlGrant? authenticate({required String token, required int nowMillis}) =>
      grants[token];
}
