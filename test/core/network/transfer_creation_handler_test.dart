import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:nearsend/core/network/control_authorization.dart';
import 'package:nearsend/core/network/control_message.dart';
import 'package:nearsend/core/network/control_pipeline.dart';
import 'package:nearsend/core/network/transfer_creation_handler.dart';
import 'package:nearsend/core/protocol/api_routes.dart';
import 'package:nearsend/core/protocol/base64url.dart';
import 'package:nearsend/core/protocol/protocol_exception.dart';
import 'package:nearsend/core/protocol/transfer_state.dart';
import 'package:nearsend/core/security/credential_fingerprint.dart';
import 'package:nearsend/core/storage/chunk_repository.dart';
import 'package:nearsend/core/storage/idempotency_repository.dart';
import 'package:nearsend/core/storage/near_send_database.dart';
import 'package:nearsend/core/storage/transfer_repository.dart';

/// `POST /transfers`, driven through a real database.
///
/// The property under test is that **the effect and the idempotency record cannot disagree**.
/// §9 requires a retry to return the same result rather than run the effect twice, and the
/// only arrangement that guarantees it is writing both in one transaction - so most of these
/// tests check the database, not just the response: a second creation must leave one task
/// row, and a failed effect must leave no record that would block a corrected retry.
void main() {
  late Directory dir;
  late NearSendDatabase database;
  late ChunkRepository tasks;
  late TransferRepository transfers;
  late IdempotencyRepository idempotency;
  late TransferCreationEndpoint endpoint;

  const String requestId = '11111111-2222-4333-8444-555555555555';
  const String transferId = '99999999-8888-4777-8666-555555555555';
  const String otherRequestId = '22222222-3333-4444-8555-666666666666';
  const String digest =
      'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

  final String sessionToken = encodeBase64UrlNoPadding(
    Uint8List.fromList(List<int>.filled(32, 0x11)),
  );
  final String otherToken = encodeBase64UrlNoPadding(
    Uint8List.fromList(List<int>.filled(32, 0x22)),
  );

  setUp(() {
    dir = Directory.systemTemp.createTempSync('nearsend-create-');
    database = NearSendDatabase.open(
      path: '${dir.path}${Platform.pathSeparator}create.db',
    );
    tasks = ChunkRepository(database);
    transfers = TransferRepository(database);
    idempotency = IdempotencyRepository(database);
    endpoint = TransferCreationEndpoint(
      idempotency: idempotency,
      transfers: transfers,
      tasks: tasks,
      now: () => 1000,
    );
  });

  tearDown(() {
    database.close();
    if (dir.existsSync()) {
      dir.deleteSync(recursive: true);
    }
  });

  Map<String, Object?> body({
    Object? requestIdValue = requestId,
    Object? transferIdValue = transferId,
    Object? digestValue = digest,
    Object? fileCount = 3,
    Object? totalBytes = '1024',
    Object? direction = 'client_to_server',
  }) => <String, Object?>{
    'requestId': requestIdValue,
    'transferId': transferIdValue,
    'manifestDigest': digestValue,
    'fileCount': fileCount,
    'totalBytes': totalBytes,
    'direction': direction,
  };

  ControlAuthorized authorizedAs(String token) =>
      ControlAuthorized(grant: const SessionGrant(peerId: 'peer-a'));

  ControlRequest requestFor({String? token, Map<String, Object?>? json}) {
    json ??= body();
    return ControlRequest(
      method: HttpMethod.post,
      target: '/v1/transfers',
      headers: <String, String>{
        if (token != null) 'authorization': 'Bearer $token',
      },
      body: Uint8List.fromList(utf8.encode(jsonEncode(json))),
    );
  }

  /// Runs the endpoint the way the pipeline would, with a resolved credential.
  ControlResponse call({String token = '', Map<String, Object?>? json}) =>
      endpoint.handle(
        body: json ?? body(),
        authorization: authorizedAs(token.isEmpty ? sessionToken : token),
        request: requestFor(
          token: token.isEmpty ? sessionToken : token,
          json: json,
        ),
      );

  int taskCount() =>
      database.db.select('SELECT COUNT(*) AS c FROM tasks;').first['c'] as int;

  int idempotencyCount() =>
      database.db.select('SELECT COUNT(*) AS c FROM idempotency;').first['c']
          as int;

  group('creating a transfer', () {
    test('answers 201 with the §7 body and records the task in STAGING', () {
      final ControlResponse response = call();

      expect(response.status, 201);
      expect(response.decodeJsonBody(), <String, Object?>{
        'transferId': transferId,
        'state': 'STAGING',
      });

      expect(taskCount(), 1);
      expect(transfers.taskState(transferId), TransferState.staging);

      final TransferDeclaration declaration = transfers.readDeclaration(
        transferId,
      )!;
      expect(declaration.direction, 'client_to_server');
      expect(declaration.manifestDigest, digest);
      expect(declaration.protocolMajor, 1);
      expect(declaration.protocolMinor, 0);
    });

    test('does not allocate a write generation', () {
      call();
      expect(
        tasks.leaseEpoch(transferId),
        0,
        reason:
            '§8 allocates the generation at the first resume; a transfer being created has '
            'nothing to write, and 0 is what "not yet allocated" means',
      );
    });

    test('records the request id in the same transaction as the task', () {
      call();
      expect(idempotencyCount(), 1);
      expect(taskCount(), 1);
    });

    test('the response is uncacheable like every control response', () {
      expect(call().headers['cache-control'], 'no-store');
    });
  });

  group('a retry with the same request id', () {
    test('replays the result and creates nothing second time', () {
      final ControlResponse first = call();
      final ControlResponse second = call();

      expect(second.status, 201);
      expect(second.decodeJsonBody(), first.decodeJsonBody());
      expect(taskCount(), 1, reason: '§9: the effect must not run twice');
      expect(idempotencyCount(), 1);
    });

    test('a retry that changed a parameter is REQUEST_ID_CONFLICT', () {
      call();
      expect(
        () => call(json: body(fileCount: 4)),
        throwsA(
          isA<ProtocolViolation>().having(
            (ProtocolViolation e) => e.code,
            'code',
            ProtocolErrorCode.requestIdConflict,
          ),
        ),
      );
      expect(
        ProtocolErrorCode.requestIdConflict.httpStatus,
        409,
        reason: '§11 pairs REQUEST_ID_CONFLICT with 409',
      );
      // The stored declaration is untouched.
      expect(transfers.readDeclaration(transferId)!.manifestDigest, digest);
    });

    test('a reordered retry is the same request, not a conflict', () {
      call();
      final Map<String, Object?> reordered = <String, Object?>{
        'direction': 'client_to_server',
        'totalBytes': '1024',
        'fileCount': 3,
        'manifestDigest': digest,
        'transferId': transferId,
        'requestId': requestId,
      };
      expect(call(json: reordered).status, 201);
      expect(taskCount(), 1);
    });

    test('a different credential is a different scope, so the id is fresh', () {
      // §9 scopes a request id to "同一任务＋操作＋当前恢复凭证": a request id from before a
      // re-pairing must not silently match one made after it.
      call();
      expect(call(token: otherToken).status, 201);
      expect(
        idempotencyCount(),
        2,
        reason: 'two credentials mean two scopes and therefore two records',
      );
      expect(
        taskCount(),
        1,
        reason: 'the second call proposed an identical declaration, so nothing was written',
      );
    });
  });

  group('a client-proposed identifier that already exists', () {
    test(
      'the same declaration under a new request id succeeds without writing',
      () {
        call();
        final ControlResponse second = call(
          json: body(requestIdValue: otherRequestId),
        );

        expect(second.status, 201);
        expect(taskCount(), 1);
        expect(
          idempotencyCount(),
          2,
          reason: 'the new request id is its own record even though the effect was a no-op',
        );
      },
    );

    test('a different declaration under a new request id is INVALID_STATE', () {
      call();
      expect(
        () => call(
          json: body(requestIdValue: otherRequestId, digestValue: 'b' * 64),
        ),
        throwsA(
          isA<ProtocolViolation>().having(
            (ProtocolViolation e) => e.code,
            'code',
            ProtocolErrorCode.invalidState,
          ),
        ),
        reason: 'overwriting would destroy a task another transfer may still be using',
      );
      expect(transfers.readDeclaration(transferId)!.manifestDigest, digest);
    });

    test('a different direction under a new request id is refused', () {
      call();
      expect(
        () => call(
          json: body(
            requestIdValue: otherRequestId,
            direction: 'server_to_client',
          ),
        ),
        throwsA(isA<ProtocolViolation>()),
      );
      expect(
        transfers.readDeclaration(transferId)!.direction,
        'client_to_server',
      );
    });
  });

  group('the direction rule', () {
    test('server_to_client is DIRECTION_FORBIDDEN and writes nothing', () {
      expect(
        () => call(json: body(direction: 'server_to_client')),
        throwsA(
          isA<ProtocolViolation>().having(
            (ProtocolViolation e) => e.code,
            'code',
            ProtocolErrorCode.directionForbidden,
          ),
        ),
        reason: '§7: 客户端仅可提议 client_to_server；服务端发送由本地创建',
      );
      expect(taskCount(), 0);
      expect(idempotencyCount(), 0);
    });
  });

  group('atomicity of the effect and the record', () {
    test('a failed effect leaves no idempotency record behind', () {
      // The failure is caused by a conflicting declaration, so the effect throws after the
      // in-flight row was inserted. If that row survived, a corrected retry would find a
      // phantom record and be refused as a conflict for a request that never took effect.
      call();
      expect(
        () => call(
          json: body(requestIdValue: otherRequestId, digestValue: 'b' * 64),
        ),
        throwsA(isA<ProtocolViolation>()),
      );

      expect(
        database.db.select(
          'SELECT COUNT(*) AS c FROM idempotency WHERE request_id = ?;',
          <Object?>[otherRequestId],
        ).first['c'],
        0,
      );

      // A corrected retry under the same request id therefore succeeds.
      final ControlResponse corrected = call(
        json: body(requestIdValue: otherRequestId, transferIdValue: transferId),
      );
      expect(corrected.status, 201);
    });

    test('a stored result this build cannot read is refused, not echoed', () {
      call();
      // Simulate a record written by another version.
      database.db.execute(
        'UPDATE idempotency SET result_json = ? WHERE request_id = ?;',
        <Object?>['{"transferId":"not-a-uuid","state":"STAGING"}', requestId],
      );

      expect(
        () => call(),
        throwsA(isA<ProtocolViolation>()),
        reason:
            'returning an unchecked stored body would put an unvalidated response on the '
            'wire',
      );
    });
  });

  group('through the pipeline', () {
    ControlPipeline pipelineWith({ControlAuthenticator? authenticator}) =>
        ControlPipeline(
          authenticator:
              authenticator ??
              _MapAuthenticator(<String, ControlGrant>{
                sessionToken: const SessionGrant(peerId: 'peer-a'),
              }),
          handlers: <String, ControlHandler>{
            'createTransfer': endpoint.handler,
          },
          now: () => 1000,
        );

    test('a session posts a transfer and gets 201', () async {
      final ControlResponse response = await pipelineWith().handle(
        requestFor(token: sessionToken),
      );

      expect(response.status, 201);
      expect(response.decodeJsonBody()['state'], 'STAGING');
      expect(transfers.taskState(transferId), TransferState.staging);
      expect(response.headers['cache-control'], 'no-store');
    });

    test('without a credential it is 401 and nothing is created', () async {
      final ControlResponse response = await pipelineWith().handle(
        requestFor(),
      );
      expect(response.status, 401);
      expect(response.decodeError().code, ProtocolErrorCode.authExpired);
      expect(taskCount(), 0);
    });

    test('a malformed body is 400 and nothing is created', () async {
      final ControlResponse response = await pipelineWith().handle(
        requestFor(token: sessionToken, json: body()..['extra'] = 1),
      );
      expect(response.status, 400);
      expect(response.decodeError().code, ProtocolErrorCode.invalidField);
      expect(taskCount(), 0);
    });

    test('a body that is not JSON at all is 400', () async {
      final ControlResponse response = await pipelineWith().handle(
        ControlRequest(
          method: HttpMethod.post,
          target: '/v1/transfers',
          headers: <String, String>{'authorization': 'Bearer $sessionToken'},
          body: Uint8List.fromList(<int>[0xFF, 0xFE]),
        ),
      );
      expect(response.status, 400);
      expect(taskCount(), 0);
    });

    test('a server_to_client proposal is 403 through the pipeline', () async {
      final ControlResponse response = await pipelineWith().handle(
        requestFor(
          token: sessionToken,
          json: body(direction: 'server_to_client'),
        ),
      );
      expect(response.status, 403);
      expect(response.decodeError().code, ProtocolErrorCode.directionForbidden);
      expect(taskCount(), 0);
    });

    test('a retry through the pipeline is still 201 with one task', () async {
      final ControlPipeline pipeline = pipelineWith();
      await pipeline.handle(requestFor(token: sessionToken));
      final ControlResponse again = await pipeline.handle(
        requestFor(token: sessionToken),
      );
      expect(again.status, 201);
      expect(taskCount(), 1);
    });
  });

  group('the fingerprint used for the scope', () {
    test('is derived from the credential the request carried', () {
      call();
      // The stored scope must be the fingerprint of the token, never the token itself.
      final String stored =
          database.db
                  .select('SELECT credential_fingerprint FROM idempotency;')
                  .first['credential_fingerprint']
              as String;

      expect(stored, credentialFingerprint(sessionToken));
      expect(stored, isNot(contains(sessionToken)));
      expect(looksLikeCredentialFingerprint(stored), isTrue);
    });
  });
}

/// An authority that resolves tokens from a fixed map.
class _MapAuthenticator implements ControlAuthenticator {
  const _MapAuthenticator(this.grants);

  final Map<String, ControlGrant> grants;

  @override
  ControlGrant? authenticate({required String token, required int nowMillis}) =>
      grants[token];
}
