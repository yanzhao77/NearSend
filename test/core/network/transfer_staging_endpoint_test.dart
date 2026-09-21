import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:nearsend/core/network/control_authorization.dart';
import 'package:nearsend/core/network/control_message.dart';
import 'package:nearsend/core/network/control_pipeline.dart';
import 'package:nearsend/core/network/manifest_staging_registry.dart';
import 'package:nearsend/core/network/transfer_creation_handler.dart';
import 'package:nearsend/core/network/transfer_staging_endpoint.dart';
import 'package:nearsend/core/protocol/api_routes.dart';
import 'package:nearsend/core/protocol/base64url.dart';
import 'package:nearsend/core/protocol/chunk_manifest.dart';
import 'package:nearsend/core/protocol/manifest.dart';
import 'package:nearsend/core/protocol/manifest_page.dart';
import 'package:nearsend/core/protocol/protocol_exception.dart';
import 'package:nearsend/core/protocol/protocol_limits.dart';
import 'package:nearsend/core/protocol/protocol_validation.dart';
import 'package:nearsend/core/protocol/transfer_direction.dart';
import 'package:nearsend/core/protocol/transfer_state.dart';
import 'package:nearsend/core/storage/chunk_repository.dart';
import 'package:nearsend/core/storage/idempotency_repository.dart';
import 'package:nearsend/core/storage/near_send_database.dart';
import 'package:nearsend/core/storage/transfer_repository.dart';

/// The staging lifecycle endpoints, driven through a real database.
///
/// `ManifestStaging`'s internal rules already have their own tests, so these are about what
/// only an endpoint can get wrong: finding the right staging for the transfer in the path,
/// answering §6's re-send rule the same way twice, applying the thirty-minute window, and
/// turning a seal into a durable state change **without** moving the task when the manifest
/// does not seal.
void main() {
  late Directory dir;
  late NearSendDatabase database;
  late ChunkRepository tasks;
  late TransferRepository transfers;
  late IdempotencyRepository idempotency;
  late ManifestStagingRegistry registry;
  late TransferStagingEndpoint endpoint;
  late TransferCreationEndpoint creation;
  late int clock;

  const String transferId = '11111111-2222-4333-8444-555555555555';
  const String unknownTransfer = '99999999-8888-4777-8666-555555555555';

  /// §7's rows split the credentials: creating a transfer asks for a session identity,
  /// while staging its manifest asks for a task token for that transfer - and §7's
  /// client_to_server rule lives in the token's grant.
  final String sessionToken = encodeBase64UrlNoPadding(
    Uint8List.fromList(List<int>.filled(32, 0x11)),
  );
  final String taskToken = encodeBase64UrlNoPadding(
    Uint8List.fromList(List<int>.filled(32, 0x22)),
  );
  final String serverTaskToken = encodeBase64UrlNoPadding(
    Uint8List.fromList(List<int>.filled(32, 0x33)),
  );

  String uuid(int n) =>
      '00000000-0000-4000-8000-${n.toString().padLeft(12, '0')}';

  List<ChunkRecord> chunksFor(int sizeBytes) => <ChunkRecord>[
    for (
      int i = 0;
      i < chunkCountForSize(sizeBytes, ProtocolLimits.chunkSizeBytes);
      i++
    )
      ChunkRecord(
        index: i,
        length: chunkLengthForIndex(
          sizeBytes,
          ProtocolLimits.chunkSizeBytes,
          i,
        ),
        sha256: (i + 1).toRadixString(16).padLeft(64, '0'),
      ),
  ];

  ManifestFile file(int n, int sizeBytes) {
    final List<ChunkRecord> chunks = chunksFor(sizeBytes);
    return ManifestFile(
      fileId: uuid(n),
      relativePath: 'file-$n.bin',
      sizeBytes: sizeBytes,
      chunkSizeBytes: ProtocolLimits.chunkSizeBytes,
      chunkCount: chunks.length,
      fileSha256: (n + 100).toRadixString(16).padLeft(64, '0'),
      chunkManifestDigest: ChunkManifestCodec.digest(
        chunks: chunks,
        sizeBytes: sizeBytes,
        chunkSizeBytes: ProtocolLimits.chunkSizeBytes,
      ),
    );
  }

  /// Two files: a conforming manifest needs every file and chunk page.
  final List<ManifestFile> files = <ManifestFile>[file(0, 4), file(1, 8)];
  final String digest = FrozenManifest(
    protocolMajor: ProtocolLimits.protocolMajor,
    protocolMinor: ProtocolLimits.protocolMinor,
    transferId: transferId,
    files: files,
  ).manifestDigest;

  List<Map<String, Object?>> filePageJson({
    String forDigest = '',
    String forTransfer = transferId,
  }) => <Map<String, Object?>>[
    for (final ManifestFilePage page in ManifestPager.filePages(
      manifestDigest: forDigest.isEmpty ? digest : forDigest,
      files: forTransfer == transferId ? files : <ManifestFile>[file(9, 4)],
    ))
      page.toJson(),
  ];

  List<Map<String, Object?>> chunkPageJson({
    String forDigest = '',
    List<ManifestFile>? over,
  }) => <Map<String, Object?>>[
    for (final ManifestFile f in over ?? files)
      for (final ManifestChunkPage page in ManifestPager.chunkPages(
        manifestDigest: forDigest.isEmpty ? digest : forDigest,
        fileId: f.fileId,
        chunks: chunksFor(f.sizeBytes),
      ))
        page.toJson(),
  ];

  void registerTransfer({
    String id = transferId,
    String? manifestDigest,
    String direction = 'client_to_server',
    TransferState state = TransferState.staging,
  }) {
    tasks.registerTask(
      taskId: id,
      role: 'receiver',
      direction: direction,
      state: state,
      protocolMajor: ProtocolLimits.protocolMajor,
      protocolMinor: ProtocolLimits.protocolMinor,
      manifestDigest: manifestDigest ?? digest,
      nowMillis: clock,
    );
  }

  /// Stages every page a conforming sender would send.
  void stageEverything({String id = transferId}) {
    for (final Map<String, Object?> page in filePageJson()) {
      endpoint.putManifest(transferId: id, body: page);
    }
    for (final Map<String, Object?> page in chunkPageJson()) {
      endpoint.putManifest(transferId: id, body: page);
    }
  }

  ControlRequest requestFor({
    required String target,
    required HttpMethod method,
    Map<String, Object?>? body,
    String? withToken,
  }) {
    final String credential = withToken ?? taskToken;
    return ControlRequest(
      method: method,
      target: target,
      headers: <String, String>{'authorization': 'Bearer $credential'},
      body: body == null
          ? null
          : Uint8List.fromList(utf8.encode(jsonEncode(body))),
    );
  }

  setUp(() {
    dir = Directory.systemTemp.createTempSync('nearsend-staging-');
    database = NearSendDatabase.open(
      path: '${dir.path}${Platform.pathSeparator}staging.db',
    );
    tasks = ChunkRepository(database);
    transfers = TransferRepository(database);
    idempotency = IdempotencyRepository(database);
    clock = 1000;
    registry = ManifestStagingRegistry(transfers: transfers, now: () => clock);
    endpoint = TransferStagingEndpoint(
      idempotency: idempotency,
      transfers: transfers,
      staging: registry,
      now: () => clock,
    );
    creation = TransferCreationEndpoint(
      idempotency: idempotency,
      transfers: transfers,
      tasks: tasks,
      now: () => clock,
    );
  });

  tearDown(() {
    database.close();
    if (dir.existsSync()) {
      dir.deleteSync(recursive: true);
    }
  });

  Matcher refusedWith(ProtocolErrorCode code) => throwsA(
    isA<ProtocolViolation>().having(
      (ProtocolViolation e) => e.code,
      'code',
      code,
    ),
  );

  String sealRequestId = 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee';

  Map<String, Object?> sealBody({String? digestValue, String? requestId}) =>
      <String, Object?>{
        'requestId': requestId ?? sealRequestId,
        'manifestDigest': digestValue ?? digest,
      };

  group('PUT /transfers/{id}/manifest', () {
    test('stores a page and acknowledges it', () {
      registerTransfer();
      final ControlResponse response = endpoint.putManifest(
        transferId: transferId,
        body: filePageJson().first,
      );

      expect(response.status, 200);
      expect(response.decodeJsonBody(), <String, Object?>{'stored': true});
      expect(registry.stagingFor(transferId).stagedFileCount, 2);
    });

    test('a re-sent page is a success, not an error', () {
      // §6: "重传相同页返回成功". A client whose response was lost cannot tell the two cases
      // apart, so answering an error to the second would make that loss unrecoverable.
      registerTransfer();
      endpoint.putManifest(transferId: transferId, body: filePageJson().first);
      final ControlResponse again = endpoint.putManifest(
        transferId: transferId,
        body: filePageJson().first,
      );

      expect(again.status, 200);
      expect(again.decodeJsonBody()['stored'], true);
      expect(
        registry.stagingFor(transferId).stagedFileCount,
        2,
        reason: 'a duplicate page must not inflate the count',
      );
    });

    test('an overlapping range with different content is refused', () {
      registerTransfer();
      endpoint.putManifest(transferId: transferId, body: filePageJson().first);

      // The same index, a different entry.
      final Map<String, Object?> conflicting = ManifestFilePage(
        manifestDigest: digest,
        startIndex: 0,
        items: <ManifestFile>[file(9, 4)],
      ).toJson();

      expect(
        () => endpoint.putManifest(transferId: transferId, body: conflicting),
        refusedWith(ProtocolErrorCode.manifestMismatch),
      );
    });

    test('a page for an unknown transfer is NOT_FOUND', () {
      expect(
        () => endpoint.putManifest(
          transferId: unknownTransfer,
          body: filePageJson().first,
        ),
        refusedWith(ProtocolErrorCode.notFound),
      );
    });

    test('a page naming another manifest digest is refused', () {
      registerTransfer();
      expect(
        () => endpoint.putManifest(
          transferId: transferId,
          body: filePageJson(forDigest: 'b' * 64).first,
        ),
        refusedWith(ProtocolErrorCode.manifestMismatch),
      );
    });

    test('a page with an unknown field is a malformed request', () {
      registerTransfer();
      final Map<String, Object?> page = filePageJson().first..['extra'] = 'x';
      expect(
        () => endpoint.putManifest(transferId: transferId, body: page),
        refusedWith(ProtocolErrorCode.invalidField),
      );
    });

    test('a page after the seal cannot change the manifest', () {
      registerTransfer();
      stageEverything();
      endpoint.seal(
        transferId: transferId,
        body: sealBody(),
        request: requestFor(
          target: '/v1/transfers/$transferId/seal',
          method: HttpMethod.post,
        ),
      );

      expect(
        () => endpoint.putManifest(
          transferId: transferId,
          body: filePageJson().first,
        ),
        refusedWith(ProtocolErrorCode.invalidState),
        reason: '§6: "seal 后页不可修改"',
      );
    });

    test("a page past §6's window is TASK_EXPIRED", () {
      registerTransfer();
      endpoint.putManifest(transferId: transferId, body: filePageJson().first);

      clock += ProtocolLimits.stagingTimeoutSeconds * 1000;
      expect(
        () => endpoint.putManifest(
          transferId: transferId,
          body: filePageJson().first,
        ),
        refusedWith(ProtocolErrorCode.taskExpired),
      );
    });
  });

  group('POST /transfers/{id}/seal', () {
    test('a complete manifest seals and moves the task to WAITING_ACCEPT', () {
      registerTransfer();
      stageEverything();

      final ControlResponse response = endpoint.seal(
        transferId: transferId,
        body: sealBody(),
        request: requestFor(
          target: '/v1/transfers/$transferId/seal',
          method: HttpMethod.post,
        ),
      );

      expect(response.status, 200);
      expect(response.decodeJsonBody(), <String, Object?>{
        'state': 'WAITING_ACCEPT',
      });
      expect(transfers.taskState(transferId), TransferState.waitingAccept);
    });

    test('an empty manifest cannot seal and the task stays in STAGING', () {
      registerTransfer();
      expect(
        () => endpoint.seal(
          transferId: transferId,
          body: sealBody(),
          request: requestFor(
            target: '/v1/transfers/$transferId/seal',
            method: HttpMethod.post,
          ),
        ),
        refusedWith(ProtocolErrorCode.manifestMismatch),
        reason: '§6: 缺页时 seal 失败，不能进入 WAITING_ACCEPT',
      );
      expect(
        transfers.taskState(transferId),
        TransferState.staging,
        reason: 'the refusal must not have moved the task',
      );
    });

    test('a missing chunk page cannot seal', () {
      registerTransfer();
      // Every file page, but no chunk page: §6's "缺页".
      for (final Map<String, Object?> page in filePageJson()) {
        endpoint.putManifest(transferId: transferId, body: page);
      }

      expect(
        () => endpoint.seal(
          transferId: transferId,
          body: sealBody(),
          request: requestFor(
            target: '/v1/transfers/$transferId/seal',
            method: HttpMethod.post,
          ),
        ),
        refusedWith(ProtocolErrorCode.manifestMismatch),
      );
      expect(transfers.taskState(transferId), TransferState.staging);
    });

    test('a seal naming a different digest is refused', () {
      registerTransfer();
      stageEverything();

      expect(
        () => endpoint.seal(
          transferId: transferId,
          body: sealBody(digestValue: 'b' * 64),
          request: requestFor(
            target: '/v1/transfers/$transferId/seal',
            method: HttpMethod.post,
          ),
        ),
        refusedWith(ProtocolErrorCode.manifestMismatch),
        reason:
            'the declared digest is the authority; without this a client could seal against '
            'one manifest and be told another is ready',
      );
      expect(transfers.taskState(transferId), TransferState.staging);
    });

    test(
      'a retry with the same request id replays instead of sealing twice',
      () {
        registerTransfer();
        stageEverything();

        ControlResponse call() => endpoint.seal(
          transferId: transferId,
          body: sealBody(),
          request: requestFor(
            target: '/v1/transfers/$transferId/seal',
            method: HttpMethod.post,
          ),
        );

        final ControlResponse first = call();
        final ControlResponse second = call();

        expect(second.status, 200);
        expect(second.decodeJsonBody(), first.decodeJsonBody());
        expect(
          transfers.taskState(transferId),
          TransferState.waitingAccept,
          reason:
              'a second transition would be refused, so a 200 here proves the stored result '
              'was replayed rather than the effect re-run',
        );
      },
    );

    test(
      'the same request id with a different digest is REQUEST_ID_CONFLICT',
      () {
        registerTransfer();
        stageEverything();
        endpoint.seal(
          transferId: transferId,
          body: sealBody(),
          request: requestFor(
            target: '/v1/transfers/$transferId/seal',
            method: HttpMethod.post,
          ),
        );

        expect(
          () => endpoint.seal(
            transferId: transferId,
            body: sealBody(digestValue: 'b' * 64),
            request: requestFor(
              target: '/v1/transfers/$transferId/seal',
              method: HttpMethod.post,
            ),
          ),
          refusedWith(ProtocolErrorCode.requestIdConflict),
          reason:
              '§9 rejects the same id carrying different parameters. The digest check sits '
              'inside the effect, so idempotency sees the request first and this is reported '
              'as id reuse rather than as a wrong manifest',
        );
      },
    );

    test('a different request id after a successful seal is INVALID_STATE', () {
      registerTransfer();
      stageEverything();
      endpoint.seal(
        transferId: transferId,
        body: sealBody(),
        request: requestFor(
          target: '/v1/transfers/$transferId/seal',
          method: HttpMethod.post,
        ),
      );

      expect(
        () => endpoint.seal(
          transferId: transferId,
          body: sealBody(requestId: 'bbbbbbbb-cccc-4ddd-8eee-ffffffffffff'),
          request: requestFor(
            target: '/v1/transfers/$transferId/seal',
            method: HttpMethod.post,
          ),
        ),
        refusedWith(ProtocolErrorCode.invalidState),
        reason:
            '§10 defines no WAITING_ACCEPT→WAITING_ACCEPT edge, so a second seal under a new '
            'request id is a state error rather than a silent success',
      );
    });

    test('a malformed seal body is refused before anything moves', () {
      registerTransfer();
      stageEverything();
      final Map<String, Object?> body = sealBody()
        ..['requestId'] = 'not-a-uuid';

      expect(
        () => endpoint.seal(
          transferId: transferId,
          body: body,
          request: requestFor(
            target: '/v1/transfers/$transferId/seal',
            method: HttpMethod.post,
          ),
        ),
        refusedWith(ProtocolErrorCode.invalidField),
      );
      expect(transfers.taskState(transferId), TransferState.staging);
    });
  });

  group('through the pipeline', () {
    ControlPipeline pipeline() => ControlPipeline(
      authenticator: _MapAuthenticator(<String, ControlGrant>{
        sessionToken: const SessionGrant(peerId: 'peer-a'),
        taskToken: TaskGrant(
          transferId: transferId,
          direction: TransferDirection.clientToServer,
        ),
        serverTaskToken: TaskGrant(
          transferId: transferId,
          direction: TransferDirection.serverToClient,
        ),
      }),
      handlers: <String, ControlHandler>{
        ApiRoutes.createTransfer.name: creation.handler,
        ...endpoint.handlers(),
      },
      now: () => clock,
    );

    test('a page is accepted with a task token and is uncacheable', () async {
      registerTransfer();
      final ControlResponse response = await pipeline().handle(
        requestFor(
          target: '/v1/transfers/$transferId/manifest',
          method: HttpMethod.put,
          body: filePageJson().first,
        ),
      );

      expect(response.status, 200);
      expect(response.headers['cache-control'], 'no-store');
    });

    test('no credential is 401 and nothing is staged', () async {
      registerTransfer();
      final ControlResponse response = await pipeline().handle(
        ControlRequest(
          method: HttpMethod.put,
          target: '/v1/transfers/$transferId/manifest',
          body: Uint8List.fromList(
            utf8.encode(jsonEncode(filePageJson().first)),
          ),
        ),
      );

      expect(response.status, 401);
      expect(registry.stagedTransferCount, 0);
    });

    test('a server_to_client task cannot stage manifests', () async {
      // §7: only the client sender may write staging. The direction check refuses it before
      // the handler runs.
      registerTransfer(direction: 'server_to_client');
      final ControlResponse response = await pipeline().handle(
        requestFor(
          target: '/v1/transfers/$transferId/manifest',
          method: HttpMethod.put,
          body: filePageJson().first,
          // The direction lives in the grant the authority issues, so §7's rule is
          // triggered by a token for a server_to_client task.
          withToken: serverTaskToken,
        ),
      );

      expect(response.status, 403);
      expect(response.decodeError().code, ProtocolErrorCode.directionForbidden);
      expect(registry.stagedTransferCount, 0);
    });

    test('the whole lifecycle runs from create to sealed', () async {
      // create -> file pages -> chunk pages -> seal. The credentials change on the way: §7
      // asks for a session identity to create a transfer and a task token to stage it, which
      // is why the session-to-transfer mapping matters for more than convenience.
      final ControlPipeline control = pipeline();

      final ControlResponse created = await control.handle(
        ControlRequest(
          method: HttpMethod.post,
          target: '/v1/transfers',
          headers: <String, String>{'authorization': 'Bearer $sessionToken'},
          body: Uint8List.fromList(
            utf8.encode(
              jsonEncode(<String, Object?>{
                'requestId': '11111111-2222-4333-8444-000000000001',
                'transferId': transferId,
                'manifestDigest': digest,
                'fileCount': files.length,
                'totalBytes':
                    '${files.fold<int>(0, (int a, ManifestFile f) => a + f.sizeBytes)}',
                'direction': 'client_to_server',
              }),
            ),
          ),
        ),
      );
      expect(created.status, 201);
      expect(transfers.taskState(transferId), TransferState.staging);

      for (final Map<String, Object?> page in <Map<String, Object?>>[
        ...filePageJson(),
        ...chunkPageJson(),
      ]) {
        final ControlResponse stored = await control.handle(
          requestFor(
            target: '/v1/transfers/$transferId/manifest',
            method: HttpMethod.put,
            body: page,
          ),
        );
        expect(stored.status, 200);
      }

      final ControlResponse sealed = await control.handle(
        requestFor(
          target: '/v1/transfers/$transferId/seal',
          method: HttpMethod.post,
          body: sealBody(),
        ),
      );

      expect(sealed.status, 200);
      expect(sealed.decodeJsonBody()['state'], 'WAITING_ACCEPT');
      expect(transfers.taskState(transferId), TransferState.waitingAccept);
      expect(
        registry.stagedTransferCount,
        0,
        reason: 'seal persists the task transition and releases the process-local registry',
      );
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
