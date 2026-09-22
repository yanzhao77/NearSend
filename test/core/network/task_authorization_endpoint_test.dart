import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

import 'package:nearsend/core/network/control_message.dart';
import 'package:nearsend/core/network/manifest_staging_registry.dart';
import 'package:nearsend/core/network/task_authorization_endpoint.dart';
import 'package:nearsend/core/protocol/api_responses.dart';
import 'package:nearsend/core/protocol/api_routes.dart';
import 'package:nearsend/core/protocol/chunk_manifest.dart';
import 'package:nearsend/core/protocol/manifest.dart';
import 'package:nearsend/core/protocol/manifest_page.dart';
import 'package:nearsend/core/protocol/protocol_exception.dart';
import 'package:nearsend/core/protocol/protocol_limits.dart';
import 'package:nearsend/core/protocol/protocol_validation.dart';
import 'package:nearsend/core/protocol/transfer_state.dart';
import 'package:nearsend/core/storage/chunk_repository.dart';
import 'package:nearsend/core/storage/idempotency_repository.dart';
import 'package:nearsend/core/storage/near_send_database.dart';
import 'package:nearsend/core/storage/receiver_mirror_repository.dart';
import 'package:nearsend/core/storage/space_plan.dart';
import 'package:nearsend/core/storage/storage_schema.dart';
import 'package:nearsend/core/storage/task_authorization_repository.dart';
import 'package:nearsend/core/storage/task_credential_repository.dart';
import 'package:nearsend/core/storage/transfer_repository.dart';

/// §6's decision, §3's authorisation delivery and §9's resume.
///
/// What these tests are for, stated because a green status code proves none of it: every case
/// below asserts **database state** - the task's state, whether an approval row exists, which
/// write generation is in force, what the credentials table holds - because §6's value is that
/// nothing touches the receiver's bytes before it decides, and §9's is that the receiver's
/// persisted position is what recovery reads.
void main() {
  late Directory dir;
  late NearSendDatabase database;
  late ChunkRepository tasks;
  late TransferRepository transfers;
  late ManifestStagingRegistry staging;
  late TaskAuthorizationRepository authorizations;
  late TaskCredentialRepository credentials;
  late ReceiverMirrorRepository mirror;
  late TaskAuthorizationEndpoint endpoint;
  late int clock;

  const String transferId = '11111111-2222-4333-8444-555555555555';
  const String fileId = '00000000-0000-4000-8000-000000000001';
  const int fileSize = 4;

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

  final List<ManifestFile> files = <ManifestFile>[
    ManifestFile(
      fileId: fileId,
      relativePath: 'note.txt',
      sizeBytes: fileSize,
      chunkSizeBytes: ProtocolLimits.chunkSizeBytes,
      chunkCount: 1,
      fileSha256: 'aa'.padLeft(64, '0'),
      chunkManifestDigest: ChunkManifestCodec.digest(
        chunks: chunksFor(fileSize),
        sizeBytes: fileSize,
        chunkSizeBytes: ProtocolLimits.chunkSizeBytes,
      ),
    ),
  ];

  final String digest = FrozenManifest(
    protocolMajor: ProtocolLimits.protocolMajor,
    protocolMinor: ProtocolLimits.protocolMinor,
    transferId: transferId,
    files: files,
  ).manifestDigest;

  /// A context with a volume that can hold anything asked of it.
  ReceiverStorageContext roomyContext() => ReceiverStorageContext(
    stagingVolume: const VolumeId('staging'),
    exportVolume: const VolumeId('internal'),
    databaseVolume: const VolumeId('internal'),
    availability: <VolumeId, VolumeAvailability>{
      const VolumeId('staging'): const VolumeAvailability.known(1 << 40),
      const VolumeId('internal'): const VolumeAvailability.known(1 << 40),
    },
    saveLocationRef: 'volume:internal/Downloads',
  );

  /// Two distinct canonical 32-byte bearer tokens.
  ///
  /// §4 fixes a token as 32 random bytes in *canonical* unpadded base64url, and the request
  /// reader enforces that by re-encoding, so the trailing bits have to be zero: a token like
  /// `session-token` is refused by the reader, which would make these cases pass for a reason
  /// that has nothing to do with what they test. `Q` is `010000`, whose low four bits are zero.
  final String sessionToken = 'A' * 43;
  final String taskToken = '${'A' * 42}Q';

  ControlRequest bearer(String token) => ControlRequest(
    method: HttpMethod.post,
    target: '/v1/transfers/$transferId/decision',
    headers: <String, String>{'authorization': 'Bearer $token'},
  );

  /// Registers a task in [state] with the frozen manifest already sealed.
  void seedTask({
    TransferState state = TransferState.waitingAccept,
    String direction = 'server_to_client',
    String? withDigest = 'yes',
  }) {
    tasks.registerTask(
      taskId: transferId,
      role: 'receiver',
      direction: direction,
      state: TransferState.staging,
      protocolMajor: ProtocolLimits.protocolMajor,
      protocolMinor: ProtocolLimits.protocolMinor,
      manifestDigest: withDigest == 'yes' ? digest : null,
      nowMillis: clock,
    );
    if (withDigest == 'yes') {
      for (final ManifestFilePage page in ManifestPager.filePages(
        manifestDigest: digest,
        files: files,
      )) {
        staging.addPage(transferId, page);
      }
      for (final ManifestFile f in files) {
        for (final ManifestChunkPage page in ManifestPager.chunkPages(
          manifestDigest: digest,
          fileId: f.fileId,
          chunks: chunksFor(f.sizeBytes),
        )) {
          staging.addPage(transferId, page);
        }
      }
      staging.seal(transferId);
      transfers.transitionTask(
        taskId: transferId,
        to: TransferState.waitingAccept,
      );
    }
    if (state != TransferState.waitingAccept) {
      // Walk §10's defined edges rather than jumping: the state machine refuses an undefined
      // transition, so a shortcut here would fail for a reason unrelated to the test.
      switch (state) {
        case TransferState.staging:
          break;
        case TransferState.ready:
          transfers.transitionTask(taskId: transferId, to: TransferState.ready);
        case TransferState.transferring:
          transfers.transitionTask(taskId: transferId, to: TransferState.ready);
          transfers.transitionTask(
            taskId: transferId,
            to: TransferState.transferring,
          );
        case TransferState.paused:
          // §10 states pause as TRANSFERRING→PAUSING→PAUSED.
          transfers.transitionTask(taskId: transferId, to: TransferState.ready);
          transfers.transitionTask(
            taskId: transferId,
            to: TransferState.transferring,
          );
          transfers.transitionTask(
            taskId: transferId,
            to: TransferState.pausing,
          );
          transfers.transitionTask(
            taskId: transferId,
            to: TransferState.paused,
          );
        case TransferState.cancelled:
          transfers.transitionTask(
            taskId: transferId,
            to: TransferState.cancelled,
          );
        default:
          throw StateError('the test does not know how to reach $state');
      }
    }
  }

  int decisionCount() =>
      database.db
              .select(
                'SELECT COUNT(*) AS c FROM ${StorageSchema.taskAuthorizationsTable};',
              )
              .first['c']
          as int;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('nearsend-authz-');
    database = NearSendDatabase.open(
      path: '${dir.path}${Platform.pathSeparator}authz.db',
    );
    clock = 1000;
    tasks = ChunkRepository(database);
    transfers = TransferRepository(database, now: () => clock);
    staging = ManifestStagingRegistry(transfers: transfers, now: () => clock);
    authorizations = TaskAuthorizationRepository(database, now: () => clock);
    credentials = TaskCredentialRepository(database, now: () => clock);
    mirror = ReceiverMirrorRepository(database, now: () => clock);
    endpoint = TaskAuthorizationEndpoint(
      idempotency: IdempotencyRepository(database, now: () => clock),
      transfers: transfers,
      tasks: tasks,
      staging: staging,
      authorizations: authorizations,
      credentials: credentials,
      mirror: mirror,
      receiverContext: (String _) => roomyContext(),
      now: () => clock,
    );
  });

  tearDown(() {
    database.close();
    if (dir.existsSync()) {
      dir.deleteSync(recursive: true);
    }
  });

  Map<String, Object?> decisionBody({
    required String requestId,
    String? forDigest,
    String choice = 'accept',
  }) => <String, Object?>{
    'requestId': requestId,
    'manifestDigest': forDigest ?? digest,
    'decision': choice,
  };

  group('POST /decision', () {
    test('accepting records the approval and moves the task to READY', () {
      seedTask();
      final ControlResponse response = endpoint.decision(
        transferId: transferId,
        body: decisionBody(requestId: uuid(1)),
        request: bearer(sessionToken),
      );

      expect(response.status, 200);
      expect(
        StateResponse.parse(response.decodeJsonBody()).state,
        TransferState.ready,
      );

      final TaskAuthorizationRecord record = authorizations.read(transferId)!;
      expect(record.isAccepted, isTrue);
      expect(record.manifestDigest, digest);
      expect(
        record.saveLocationRef,
        'volume:internal/Downloads',
        reason: '§6 persists the save location with the approval',
      );
      expect(
        record.spaceEstimate,
        isNotNull,
        reason: '§6 persists the space estimate with the approval',
      );
      expect(
        record.spaceEstimate!.volumes.expand(
          (SpaceVolumeSnapshot v) => v.lines,
        ),
        isNotEmpty,
        reason: '§8 requires the plan to carry its explanations, not just a verdict',
      );
      expect(transfers.taskState(transferId), TransferState.ready);
    });

    test('accepting mints the two secrets but stores only their digests', () {
      seedTask();
      endpoint.decision(
        transferId: transferId,
        body: decisionBody(requestId: uuid(1)),
        request: bearer(sessionToken),
      );

      // §3: "用户接受任务后服务端生成该任务的客户端恢复密钥并持久化验证材料".
      final ResultSet rows = database.db.select(
        'SELECT kind, digest FROM ${StorageSchema.taskCredentialsTable} ORDER BY kind;',
      );
      expect(rows, hasLength(2));
      for (final Row row in rows) {
        final String stored = row['digest'] as String;
        expect(
          stored.length,
          64,
          reason: 'the persisted material is a SHA-256 digest, not a secret',
        );
      }

      final IssuedTaskSecrets? pending = credentials.pendingSecrets(transferId);
      expect(pending, isNotNull);
      final List<String> columns = <String>[
        for (final Row row in database.db.select(
          'SELECT * FROM ${StorageSchema.taskCredentialsTable};',
        ))
          for (final String column in row.keys) '${row[column]}',
      ];
      expect(
        columns.any((String value) => value == pending!.taskResumeSecret),
        isFalse,
        reason:
            'AGENTS.md §5 keeps a recovery secret out of an ordinary SQLite field; the '
            'plaintext must not appear anywhere in the credentials table',
      );
    });

    test('a volume that cannot hold the transfer is SPACE_INSUFFICIENT', () {
      seedTask();
      final TaskAuthorizationEndpoint tight = TaskAuthorizationEndpoint(
        idempotency: IdempotencyRepository(database, now: () => clock),
        transfers: transfers,
        tasks: tasks,
        staging: staging,
        authorizations: authorizations,
        credentials: credentials,
        mirror: mirror,
        receiverContext: (String _) => ReceiverStorageContext(
          stagingVolume: const VolumeId('staging'),
          exportVolume: const VolumeId('internal'),
          databaseVolume: const VolumeId('internal'),
          availability: <VolumeId, VolumeAvailability>{
            const VolumeId('staging'): const VolumeAvailability.known(8),
            const VolumeId('internal'): const VolumeAvailability.known(8),
          },
          saveLocationRef: 'volume:internal/Downloads',
        ),
        now: () => clock,
      );

      expect(
        () => tight.decision(
          transferId: transferId,
          body: decisionBody(requestId: uuid(1)),
          request: bearer(sessionToken),
        ),
        throwsA(
          isA<ProtocolViolation>().having(
            (ProtocolViolation e) => e.code,
            'code',
            ProtocolErrorCode.spaceInsufficient,
          ),
        ),
      );
      expect(
        decisionCount(),
        0,
        reason: 'a refused acceptance must not leave an approval behind',
      );
      expect(
        transfers.taskState(transferId),
        TransferState.waitingAccept,
        reason: '§6 forbids starting anything before the receiver has accepted',
      );
    });

    test('an unverifiable volume is accepted but recorded as unknown', () {
      // §16.1 wants the unknown case surfaced to the person deciding rather than folded into a
      // pass; this endpoint *is* that decision, so the estimate the user approved is stored
      // with `unknown` in it rather than being silently upgraded to `sufficient`.
      seedTask();
      final TaskAuthorizationEndpoint unknown = TaskAuthorizationEndpoint(
        idempotency: IdempotencyRepository(database, now: () => clock),
        transfers: transfers,
        tasks: tasks,
        staging: staging,
        authorizations: authorizations,
        credentials: credentials,
        mirror: mirror,
        receiverContext: (String _) => const ReceiverStorageContext(
          stagingVolume: VolumeId('staging'),
          exportVolume: VolumeId('internal'),
          databaseVolume: VolumeId('internal'),
          availability: <VolumeId, VolumeAvailability>{},
        ),
        now: () => clock,
      );

      expect(
        unknown
            .decision(
              transferId: transferId,
              body: decisionBody(requestId: uuid(1)),
              request: bearer(sessionToken),
            )
            .status,
        200,
      );
      expect(
        authorizations.read(transferId)!.spaceEstimate!.verdict,
        SpaceVerdict.unknown,
        reason: 'an unverifiable volume must not be stored as if it had been checked',
      );
    });

    test('rejecting cancels the task and leaves no credentials', () {
      seedTask();
      final ControlResponse response = endpoint.decision(
        transferId: transferId,
        body: decisionBody(requestId: uuid(1), choice: 'reject'),
        request: bearer(sessionToken),
      );

      expect(response.status, 200);
      expect(
        StateResponse.parse(response.decodeJsonBody()).state,
        TransferState.cancelled,
      );
      expect(transfers.taskState(transferId), TransferState.cancelled);
      expect(authorizations.read(transferId)!.isAccepted, isFalse);
      expect(
        database.db
            .select(
              'SELECT COUNT(*) AS c FROM ${StorageSchema.taskCredentialsTable};',
            )
            .first['c'],
        0,
        reason: 'a rejected task has nothing to recover, so it must hand out no credentials',
      );
    });

    test('a decision naming another digest is MANIFEST_MISMATCH', () {
      seedTask();
      final String other = FrozenManifest(
        protocolMajor: ProtocolLimits.protocolMajor,
        protocolMinor: ProtocolLimits.protocolMinor,
        transferId: transferId,
        files: <ManifestFile>[
          ManifestFile(
            fileId: uuid(9),
            relativePath: 'other.bin',
            sizeBytes: 4,
            chunkSizeBytes: ProtocolLimits.chunkSizeBytes,
            chunkCount: 1,
            fileSha256: 'bb'.padLeft(64, '0'),
            chunkManifestDigest: ChunkManifestCodec.digest(
              chunks: <ChunkRecord>[
                ChunkRecord(index: 0, length: 4, sha256: 'cc'.padLeft(64, '0')),
              ],
              sizeBytes: 4,
              chunkSizeBytes: ProtocolLimits.chunkSizeBytes,
            ),
          ),
        ],
      ).manifestDigest;

      expect(
        () => endpoint.decision(
          transferId: transferId,
          body: decisionBody(requestId: uuid(1), forDigest: other),
          request: bearer(sessionToken),
        ),
        throwsA(
          isA<ProtocolViolation>().having(
            (ProtocolViolation e) => e.code,
            'code',
            ProtocolErrorCode.manifestMismatch,
          ),
        ),
      );
      expect(decisionCount(), 0);
      expect(transfers.taskState(transferId), TransferState.waitingAccept);
    });

    test('a repeated request id replays instead of deciding twice', () {
      seedTask();
      endpoint.decision(
        transferId: transferId,
        body: decisionBody(requestId: uuid(1)),
        request: bearer(sessionToken),
      );
      final int decidedAt = authorizations.read(transferId)!.decidedAtMillis;

      clock += 5000;
      final ControlResponse replay = endpoint.decision(
        transferId: transferId,
        body: decisionBody(requestId: uuid(1)),
        request: bearer(sessionToken),
      );

      expect(replay.status, 200);
      expect(
        authorizations.read(transferId)!.decidedAtMillis,
        decidedAt,
        reason: 'the stored result is replayed rather than the decision being re-made',
      );
      expect(decisionCount(), 1);
    });

    test('the same request id with a different decision conflicts', () {
      seedTask();
      endpoint.decision(
        transferId: transferId,
        body: decisionBody(requestId: uuid(1)),
        request: bearer(sessionToken),
      );

      expect(
        () => endpoint.decision(
          transferId: transferId,
          body: decisionBody(requestId: uuid(1), choice: 'reject'),
          request: bearer(sessionToken),
        ),
        throwsA(
          isA<ProtocolViolation>().having(
            (ProtocolViolation e) => e.code,
            'code',
            ProtocolErrorCode.requestIdConflict,
          ),
        ),
      );
      expect(
        transfers.taskState(transferId),
        TransferState.ready,
        reason: '§9 makes a conflicting retry an error, not a second effect',
      );
    });

    test('a decision on a task that is not waiting is INVALID_STATE', () {
      seedTask(state: TransferState.ready);
      // Seeding READY sets the state directly, so the endpoint must notice.
      transfers.transitionTask(
        taskId: transferId,
        to: TransferState.transferring,
      );

      expect(
        () => endpoint.decision(
          transferId: transferId,
          body: decisionBody(requestId: uuid(1)),
          request: bearer(sessionToken),
        ),
        throwsA(
          isA<ProtocolViolation>().having(
            (ProtocolViolation e) => e.code,
            'code',
            ProtocolErrorCode.invalidState,
          ),
        ),
      );
    });
  });

  group('GET /authorization', () {
    test('delivers two §4-shaped secrets for an accepted task', () {
      seedTask();
      endpoint.decision(
        transferId: transferId,
        body: decisionBody(requestId: uuid(1)),
        request: bearer(sessionToken),
      );

      final ControlResponse response = endpoint.authorization(
        transferId: transferId,
      );
      expect(response.status, 200);
      final AuthorizationGrant grant = AuthorizationGrant.parse(
        response.decodeJsonBody(),
      );
      // §4: 32 random bytes encode to 43 unpadded base64url characters.
      expect(grant.taskResumeSecret.length, ProtocolLimits.pairTokenChars);
      expect(grant.completionQuerySecret.length, ProtocolLimits.pairTokenChars);
      expect(
        grant.taskResumeSecret,
        isNot(grant.completionQuerySecret),
        reason:
            '§2 requires the completion query to use a different credential',
      );
    });

    test('a retry before the receipt receives the same secrets', () {
      // §3: "未收到 receipt 时保留同一待交付密钥……**禁止每次重试生成不同密钥**". A different
      // secret on the retry would silently invalidate the copy the client already saved.
      seedTask();
      endpoint.decision(
        transferId: transferId,
        body: decisionBody(requestId: uuid(1)),
        request: bearer(sessionToken),
      );

      final AuthorizationGrant first = AuthorizationGrant.parse(
        endpoint.authorization(transferId: transferId).decodeJsonBody(),
      );
      final AuthorizationGrant second = AuthorizationGrant.parse(
        endpoint.authorization(transferId: transferId).decodeJsonBody(),
      );

      expect(second.taskResumeSecret, first.taskResumeSecret);
      expect(second.completionQuerySecret, first.completionQuerySecret);
    });

    test('an undecided transfer is NOT_FOUND rather than an empty grant', () {
      seedTask();
      expect(
        () => endpoint.authorization(transferId: transferId),
        throwsA(
          isA<ProtocolViolation>().having(
            (ProtocolViolation e) => e.code,
            'code',
            ProtocolErrorCode.notFound,
          ),
        ),
      );
    });

    test('a rejected transfer does not deliver credentials', () {
      seedTask();
      endpoint.decision(
        transferId: transferId,
        body: decisionBody(requestId: uuid(1), choice: 'reject'),
        request: bearer(sessionToken),
      );
      expect(
        () => endpoint.authorization(transferId: transferId),
        throwsA(
          isA<ProtocolViolation>().having(
            (ProtocolViolation e) => e.code,
            'code',
            ProtocolErrorCode.notFound,
          ),
        ),
      );
    });

    test(
      'after the receipt the plaintext is gone and re-delivery is refused',
      () {
        seedTask();
        endpoint.decision(
          transferId: transferId,
          body: decisionBody(requestId: uuid(1)),
          request: bearer(sessionToken),
        );
        endpoint.authorizationReceipt(
          transferId: transferId,
          body: <String, Object?>{'requestId': uuid(2)},
          request: bearer(taskToken),
        );

        expect(credentials.pendingSecrets(transferId), isNull);
        expect(authorizations.read(transferId)!.hasReceipt, isTrue);
        expect(
          () => endpoint.authorization(transferId: transferId),
          throwsA(
            isA<ProtocolViolation>().having(
              (ProtocolViolation e) => e.code,
              'code',
              ProtocolErrorCode.invalidState,
            ),
          ),
        );
      },
    );

    test('a receipt is idempotent', () {
      seedTask();
      endpoint.decision(
        transferId: transferId,
        body: decisionBody(requestId: uuid(1)),
        request: bearer(sessionToken),
      );
      final ControlResponse first = endpoint.authorizationReceipt(
        transferId: transferId,
        body: <String, Object?>{'requestId': uuid(2)},
        request: bearer(taskToken),
      );
      final int receiptAt = authorizations.read(transferId)!.receiptAtMillis!;

      clock += 5000;
      final ControlResponse second = endpoint.authorizationReceipt(
        transferId: transferId,
        body: <String, Object?>{'requestId': uuid(2)},
        request: bearer(taskToken),
      );

      expect(first.status, 200);
      expect(second.status, 200);
      expect(
        StoredAck.parse(second.decodeJsonBody()).toJson(),
        <String, Object?>{'stored': true},
      );
      expect(
        authorizations.read(transferId)!.receiptAtMillis,
        receiptAt,
        reason: 'a replayed receipt must not restamp the confirmation',
      );
    });
  });

  group('POST /resume', () {
    /// Runs the whole §3 sequence so a resume has something to resume.
    IssuedTaskSecrets approve() {
      seedTask();
      endpoint.decision(
        transferId: transferId,
        body: decisionBody(requestId: uuid(1)),
        request: bearer(sessionToken),
      );
      return credentials.pendingSecrets(transferId)!;
    }

    Map<String, Object?> resumeBody({
      required String requestId,
      required String secret,
      Map<String, Object?>? receiverState,
    }) => <String, Object?>{
      'requestId': requestId,
      'manifestDigest': digest,
      'taskResumeSecret': secret,
      // §7 makes the report optional in general and required for a client receiver, so it is
      // omitted rather than sent as null when the test is exercising the omission.
      'receiverState': ?receiverState,
    };

    test('a first resume allocates generation 1 and issues a task token', () {
      final IssuedTaskSecrets secrets = approve();

      final ControlResponse response = endpoint.resume(
        transferId: transferId,
        body: resumeBody(
          requestId: uuid(3),
          secret: secrets.taskResumeSecret,
          receiverState: <String, Object?>{
            'leaseEpoch': '0',
            'checkpointSeq': '0',
            'committedBytes': '0',
          },
        ),
      );

      expect(response.status, 200);
      final ResumeGranted granted = ResumeGranted.parse(
        response.decodeJsonBody(),
      );
      expect(
        granted.leaseEpoch,
        1,
        reason:
            '0 means "no write generation has been allocated"; the first resume is what '
            'allocates one, and §8 refuses a commit that presents generation 0',
      );
      expect(granted.checkpointSeq, 0);
      expect(granted.state, TransferState.ready);
      expect(granted.taskAccessToken.length, ProtocolLimits.pairTokenChars);
      expect(tasks.leaseEpoch(transferId), 1);
    });

    test('the issued token authenticates and is bound to the task', () {
      final IssuedTaskSecrets secrets = approve();
      final ResumeGranted granted = ResumeGranted.parse(
        endpoint
            .resume(
              transferId: transferId,
              body: resumeBody(
                requestId: uuid(3),
                secret: secrets.taskResumeSecret,
                receiverState: <String, Object?>{
                  'leaseEpoch': '0',
                  'checkpointSeq': '0',
                  'committedBytes': '0',
                },
              ),
            )
            .decodeJsonBody(),
      );

      // Signing and verifying are the same class in production; checking them here means a
      // token that its own verifier rejects fails a test rather than the first real device.
      final TaskAccessLookup? lookup = credentials.lookupTaskAccess(
        granted.taskAccessToken,
      );
      expect(lookup, isNotNull);
      expect(lookup!.transferId, transferId);
      expect(
        credentials.lookupTaskAccess('not-the-token'),
        isNull,
        reason: 'an unknown token must not resolve to anything',
      );
    });

    test('a wrong resume secret is RESUME_REJECTED and allocates nothing', () {
      approve();
      final String wrong = AuthorizationGrant.parse(
        endpoint.authorization(transferId: transferId).decodeJsonBody(),
      ).completionQuerySecret;

      expect(
        () => endpoint.resume(
          transferId: transferId,
          body: resumeBody(requestId: uuid(3), secret: wrong),
        ),
        throwsA(
          isA<ProtocolViolation>().having(
            (ProtocolViolation e) => e.code,
            'code',
            ProtocolErrorCode.resumeRejected,
          ),
        ),
      );
      expect(
        tasks.leaseEpoch(transferId),
        0,
        reason: 'a refused resume must not advance the write generation',
      );
    });

    test('a client receiver must report its recovered state', () {
      // §7: "client 接收时必带已恢复的 receiverState". Without it the sender has nothing to
      // compare against, and §9 makes the receiver's persisted position the only authority.
      final IssuedTaskSecrets secrets = approve();
      expect(
        () => endpoint.resume(
          transferId: transferId,
          body: resumeBody(
            requestId: uuid(3),
            secret: secrets.taskResumeSecret,
          ),
        ),
        throwsA(
          isA<ProtocolViolation>().having(
            (ProtocolViolation e) => e.code,
            'code',
            ProtocolErrorCode.invalidField,
          ),
        ),
      );
      expect(tasks.leaseEpoch(transferId), 0);
    });

    test('the reported receiver state is mirrored, never adopted', () {
      final IssuedTaskSecrets secrets = approve();
      endpoint.resume(
        transferId: transferId,
        body: resumeBody(
          requestId: uuid(3),
          secret: secrets.taskResumeSecret,
          receiverState: <String, Object?>{
            'leaseEpoch': '0',
            'checkpointSeq': '7',
            'committedBytes': '1234',
          },
        ),
      );

      final ReceiverMirror? stored = mirror.read(transferId);
      expect(stored, isNotNull);
      expect(stored!.committedBytes, 1234);
      expect(
        tasks.checkpointSeq(transferId),
        0,
        reason:
            '§9 makes the receiver the authority: the sender mirrors the figure and must '
            'not copy it into its own checkpoint sequence',
      );
    });

    test(
      'repeating the same request id replays without advancing the generation',
      () {
        // §9: "同一恢复 requestId 重试不得再次递增 epoch". Advancing on a retry would revoke the
        // token the client just received and leave it writing under a superseded generation.
        final IssuedTaskSecrets secrets = approve();
        ControlRequest resumeTarget() => ControlRequest(
          method: HttpMethod.post,
          target: '/v1/transfers/$transferId/resume',
        );
        final Map<String, Object?> body = resumeBody(
          requestId: uuid(3),
          secret: secrets.taskResumeSecret,
          receiverState: <String, Object?>{
            'leaseEpoch': '0',
            'checkpointSeq': '0',
            'committedBytes': '0',
          },
        );

        final ResumeGranted first = ResumeGranted.parse(
          endpoint.resume(transferId: transferId, body: body).decodeJsonBody(),
        );
        final Map<String, Object?> replayRequest = body;
        expect(
          endpoint.resume(transferId: transferId, body: replayRequest).status,
          200,
        );
        expect(resumeTarget(), isA<ControlRequest>());

        final ResumeGranted second = ResumeGranted.parse(
          endpoint
              .resume(transferId: transferId, body: replayRequest)
              .decodeJsonBody(),
        );
        expect(second.leaseEpoch, first.leaseEpoch);
        expect(second.taskAccessToken, first.taskAccessToken);
        expect(tasks.leaseEpoch(transferId), 1);
      },
    );

    test(
      'a resume whose generation was superseded is STALE_RESUME_REQUEST',
      () {
        final IssuedTaskSecrets secrets = approve();
        Map<String, Object?> body(String requestId) => resumeBody(
          requestId: requestId,
          secret: secrets.taskResumeSecret,
          receiverState: <String, Object?>{
            'leaseEpoch': '0',
            'checkpointSeq': '0',
            'committedBytes': '0',
          },
        );

        endpoint.resume(transferId: transferId, body: body(uuid(3)));
        // A second, different resume allocates generation 2.
        endpoint.resume(transferId: transferId, body: body(uuid(4)));
        expect(tasks.leaseEpoch(transferId), 2);

        expect(
          () => endpoint.resume(transferId: transferId, body: body(uuid(3))),
          throwsA(
            isA<ProtocolViolation>().having(
              (ProtocolViolation e) => e.code,
              'code',
              ProtocolErrorCode.staleResumeRequest,
            ),
          ),
          reason: '§9 forbids returning a writable token for a generation that has been revoked',
        );
      },
    );

    test('resuming a cancelled task is refused', () {
      seedTask();
      endpoint.decision(
        transferId: transferId,
        body: decisionBody(requestId: uuid(1), choice: 'reject'),
        request: bearer(sessionToken),
      );
      // The reject revoked the credentials, so no secret can match; the refusal is the same
      // shape as an unknown task, which is deliberate.
      expect(
        () => endpoint.resume(
          transferId: transferId,
          body: resumeBody(requestId: uuid(3), secret: 'A' * 43),
        ),
        throwsA(
          isA<ProtocolViolation>().having(
            (ProtocolViolation e) => e.code,
            'code',
            ProtocolErrorCode.resumeRejected,
          ),
        ),
      );
    });

    test('a paused task passes through CHECKING_RESUME back to READY', () {
      final IssuedTaskSecrets secrets = approve();
      // §10 states pause as TRANSFERRING→PAUSING→PAUSED, so the task has to reach PAUSED the
      // way the product reaches it rather than by jumping.
      transfers.transitionTask(
        taskId: transferId,
        to: TransferState.transferring,
      );
      transfers.transitionTask(taskId: transferId, to: TransferState.pausing);
      transfers.transitionTask(taskId: transferId, to: TransferState.paused);

      final ResumeGranted granted = ResumeGranted.parse(
        endpoint
            .resume(
              transferId: transferId,
              body: resumeBody(
                requestId: uuid(3),
                secret: secrets.taskResumeSecret,
                receiverState: <String, Object?>{
                  'leaseEpoch': '0',
                  'checkpointSeq': '0',
                  'committedBytes': '0',
                },
              ),
            )
            .decodeJsonBody(),
      );

      expect(granted.state, TransferState.ready);
      expect(transfers.taskState(transferId), TransferState.ready);
    });
  });

  group('credential lifecycle', () {
    test('revoking removes every credential of a task', () {
      seedTask();
      endpoint.decision(
        transferId: transferId,
        body: decisionBody(requestId: uuid(1)),
        request: bearer(sessionToken),
      );
      final IssuedTaskAccessToken token = credentials.issueTaskAccessToken(
        transferId,
      );
      expect(credentials.lookupTaskAccess(token.token), isNotNull);

      credentials.revokeAll(transferId);

      expect(credentials.lookupTaskAccess(token.token), isNull);
      expect(credentials.pendingSecrets(transferId), isNull);
      expect(
        database.db
            .select(
              'SELECT COUNT(*) AS c FROM ${StorageSchema.taskCredentialsTable};',
            )
            .first['c'],
        0,
      );
    });

    test('an expired task token no longer authenticates', () {
      seedTask();
      final IssuedTaskAccessToken token = credentials.issueTaskAccessToken(
        transferId,
        ttlSeconds: 10,
      );
      expect(credentials.lookupTaskAccess(token.token), isNotNull);

      clock += 11 * 1000;
      expect(
        credentials.lookupTaskAccess(token.token),
        isNull,
        reason: 'an expired token must not resolve to a grant',
      );
    });

    test(
      'a task token survives a restart because only its digest is needed',
      () {
        seedTask();
        final IssuedTaskAccessToken token = credentials.issueTaskAccessToken(
          transferId,
        );

        final NearSendDatabase reopened = NearSendDatabase.open(
          path: '${dir.path}${Platform.pathSeparator}authz.db',
        );
        try {
          final TaskCredentialRepository afterRestart =
              TaskCredentialRepository(reopened, now: () => clock);
          expect(
            afterRestart.lookupTaskAccess(token.token)?.transferId,
            transferId,
            reason:
                'persisting the digest is what stops a restart from forcing every in-flight '
                'task to resume again, which §9 would answer by refusing to advance',
          );
        } finally {
          reopened.close();
        }
      },
    );
  });
}
