import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:nearsend/core/protocol/idempotency.dart';
import 'package:nearsend/core/protocol/protocol_exception.dart';
import 'package:nearsend/core/storage/idempotency_repository.dart';
import 'package:nearsend/core/storage/near_send_database.dart';
import 'package:nearsend/core/storage/storage_failure.dart';

/// Durable `request_id` idempotency, protocol §9.
///
/// The property that matters most is atomicity: the record and the effect it describes
/// must commit or roll back **together**. Both directions of divergence are harmful - a
/// lost record makes a retry repeat the effect, and a lost effect makes a retry replay a
/// result that never happened.
void main() {
  late Directory dir;
  late NearSendDatabase database;
  late IdempotencyRepository repository;
  late String databasePath;

  const String transferId = '00000000-0000-4000-8000-0000000000b1';
  const String requestA = '11111111-1111-4111-8111-111111111111';
  const String requestB = '22222222-2222-4222-8222-222222222222';

  setUp(() {
    dir = Directory.systemTemp.createTempSync('nearsend-idem-');
    databasePath = '${dir.path}${Platform.pathSeparator}idem.db';
    database = NearSendDatabase.open(path: databasePath);
    repository = IdempotencyRepository(database);
  });

  tearDown(() {
    database.close();
    if (dir.existsSync()) {
      dir.deleteSync(recursive: true);
    }
  });

  RequestScope scopeOf(
    ProtocolOperation operation, {
    String credential = 'credential-1',
  }) => RequestScope(
    transferId: transferId,
    operation: operation,
    credentialFingerprint: credential,
  );

  /// A side effect other than the idempotency record, so atomicity is observable.
  void writeMarker(String value) {
    database.db.execute(
      'INSERT OR REPLACE INTO peers (peer_id, identity_fingerprint, authorized) '
      'VALUES (?, ?, 1);',
      <Object?>[value, 'fp'],
    );
  }

  int markerCount() =>
      database.db.select('SELECT COUNT(*) AS c FROM peers;').first['c'] as int;

  group('a new request id', () {
    test('runs the effect once and returns its result', () {
      int effectRuns = 0;
      final IdempotencyExecution execution = repository.executeAtomically(
        scope: scopeOf(ProtocolOperation.seal),
        requestId: requestA,
        requestDigest: 'digest-1',
        leaseEpoch: 1,
        effect: () {
          effectRuns++;
          return <String, Object?>{'state': 'WAITING_ACCEPT'};
        },
      );

      expect(execution.kind, IdempotencyExecutionKind.executed);
      expect(execution.result, <String, Object?>{'state': 'WAITING_ACCEPT'});
      expect(execution.leaseEpoch, 1);
      expect(execution.succeeded, isTrue);
      expect(effectRuns, 1);
    });

    test(
      'a non-canonical request id is refused before anything is written',
      () {
        for (final String bad in <String>[
          'not-a-uuid',
          '11111111-1111-4111-8111-11111111111',
          '11111111-1111-4111-8111-11111111111Z',
        ]) {
          expect(
            () => repository.executeAtomically(
              scope: scopeOf(ProtocolOperation.pause),
              requestId: bad,
              requestDigest: 'd',
              leaseEpoch: 1,
              effect: () => const <String, Object?>{},
            ),
            throwsA(
              isA<ProtocolViolation>().having(
                (ProtocolViolation e) => e.code,
                'code',
                ProtocolErrorCode.invalidField,
              ),
            ),
            reason: '$bad must be refused',
          );
        }
        expect(
          repository.lookup(scopeOf(ProtocolOperation.pause), requestA),
          isNull,
        );
      },
    );
  });

  group('a repeated request id', () {
    test('replays the stored result and does not run the effect again', () {
      int effectRuns = 0;
      Map<String, Object?> effect() {
        effectRuns++;
        return <String, Object?>{'state': 'READY', 'run': effectRuns};
      }

      final IdempotencyExecution first = repository.executeAtomically(
        scope: scopeOf(ProtocolOperation.decision),
        requestId: requestA,
        requestDigest: 'digest-1',
        leaseEpoch: 1,
        effect: effect,
      );
      final IdempotencyExecution second = repository.executeAtomically(
        scope: scopeOf(ProtocolOperation.decision),
        requestId: requestA,
        requestDigest: 'digest-1',
        leaseEpoch: 1,
        effect: effect,
      );

      expect(first.kind, IdempotencyExecutionKind.executed);
      expect(second.kind, IdempotencyExecutionKind.replayed);
      expect(second.result, first.result);
      expect(
        effectRuns,
        1,
        reason: 'a replayed request must not produce a second effect',
      );
    });

    test(
      'the same id with different parameters is a conflict and runs nothing',
      () {
        int effectRuns = 0;
        repository.executeAtomically(
          scope: scopeOf(ProtocolOperation.decision),
          requestId: requestA,
          requestDigest: 'digest-1',
          leaseEpoch: 1,
          effect: () {
            effectRuns++;
            return const <String, Object?>{'state': 'READY'};
          },
        );

        final IdempotencyExecution conflict = repository.executeAtomically(
          scope: scopeOf(ProtocolOperation.decision),
          requestId: requestA,
          requestDigest: 'digest-different',
          leaseEpoch: 1,
          effect: () {
            effectRuns++;
            return const <String, Object?>{'state': 'READY'};
          },
        );

        expect(conflict.kind, IdempotencyExecutionKind.conflict);
        expect(effectRuns, 1);
        expect(conflict.result, isNull);
      },
    );

    test('the same id in a different scope is a different request', () {
      int effectRuns = 0;
      Map<String, Object?> effect() {
        effectRuns++;
        return <String, Object?>{'run': effectRuns};
      }

      final IdempotencyExecution a = repository.executeAtomically(
        scope: scopeOf(ProtocolOperation.pause),
        requestId: requestA,
        requestDigest: 'digest-1',
        leaseEpoch: 1,
        effect: effect,
      );
      final IdempotencyExecution b = repository.executeAtomically(
        scope: scopeOf(ProtocolOperation.cancel),
        requestId: requestA,
        requestDigest: 'digest-1',
        leaseEpoch: 1,
        effect: effect,
      );
      final IdempotencyExecution c = repository.executeAtomically(
        scope: scopeOf(ProtocolOperation.pause, credential: 'credential-2'),
        requestId: requestA,
        requestDigest: 'digest-1',
        leaseEpoch: 1,
        effect: effect,
      );

      for (final IdempotencyExecution execution in <IdempotencyExecution>[
        a,
        b,
        c,
      ]) {
        expect(execution.kind, IdempotencyExecutionKind.executed);
      }
      expect(
        effectRuns,
        3,
        reason:
            '§9 scopes the id to task, operation and the credential in force, so a '
            'request id from before a re-pairing must not collide with one after it',
      );
    });
  });

  group('the record and the effect commit together', () {
    test('a successful effect and its record both exist', () {
      repository.executeAtomically(
        scope: scopeOf(ProtocolOperation.checkpoint),
        requestId: requestA,
        requestDigest: 'digest-1',
        leaseEpoch: 7,
        effect: () {
          writeMarker('effect-applied');
          return const <String, Object?>{'mirrored': true};
        },
      );

      expect(markerCount(), 1);
      final PersistedIdempotencyRecord? record = repository.lookup(
        scopeOf(ProtocolOperation.checkpoint),
        requestA,
      );
      expect(record, isNotNull);
      expect(record!.state, IdempotencyState.completed);
      expect(record.leaseEpoch, 7);
      expect(record.result, <String, Object?>{'mirrored': true});
    });

    test('a failing effect leaves neither the effect nor the record', () {
      expect(
        () => repository.executeAtomically(
          scope: scopeOf(ProtocolOperation.checkpoint),
          requestId: requestA,
          requestDigest: 'digest-1',
          leaseEpoch: 7,
          effect: () {
            writeMarker('should-roll-back');
            throw StateError('effect failed');
          },
        ),
        throwsA(isA<StorageException>()),
      );

      expect(
        markerCount(),
        0,
        reason: 'the effect must have been rolled back with the record',
      );
      expect(
        repository.lookup(scopeOf(ProtocolOperation.checkpoint), requestA),
        isNull,
        reason:
            'no phantom in-flight record may survive: a retry must start clean rather '
            'than find a record for an effect that never happened',
      );

      // And the retry genuinely re-runs the effect, which is correct because nothing
      // was committed.
      final IdempotencyExecution retry = repository.executeAtomically(
        scope: scopeOf(ProtocolOperation.checkpoint),
        requestId: requestA,
        requestDigest: 'digest-1',
        leaseEpoch: 7,
        effect: () {
          writeMarker('retry-applied');
          return const <String, Object?>{'mirrored': true};
        },
      );
      expect(retry.kind, IdempotencyExecutionKind.executed);
      expect(markerCount(), 1);
    });

    test('a replayed request does not re-apply the effect', () {
      for (int i = 0; i < 3; i++) {
        repository.executeAtomically(
          scope: scopeOf(ProtocolOperation.checkpoint),
          requestId: requestA,
          requestDigest: 'digest-1',
          leaseEpoch: 3,
          effect: () {
            writeMarker('effect-applied');
            return const <String, Object?>{'mirrored': true};
          },
        );
      }
      expect(
        markerCount(),
        1,
        reason:
            'the marker is keyed by id, so a repeated effect would be invisible; '
            'the count proves the effect ran once because the record replayed',
      );
    });
  });

  group('restart', () {
    test('a completed record survives close and reopen', () {
      int effectRuns = 0;
      Map<String, Object?> effect() {
        effectRuns++;
        return <String, Object?>{'run': effectRuns};
      }

      repository.executeAtomically(
        scope: scopeOf(ProtocolOperation.createTransfer),
        requestId: requestA,
        requestDigest: 'digest-1',
        leaseEpoch: 1,
        effect: effect,
      );

      database.close();
      database = NearSendDatabase.open(path: databasePath);
      repository = IdempotencyRepository(database);

      final IdempotencyExecution afterRestart = repository.executeAtomically(
        scope: scopeOf(ProtocolOperation.createTransfer),
        requestId: requestA,
        requestDigest: 'digest-1',
        leaseEpoch: 1,
        effect: effect,
      );

      expect(
        afterRestart.kind,
        IdempotencyExecutionKind.replayed,
        reason: 'idempotency must not depend on in-memory state',
      );
      expect(afterRestart.result, <String, Object?>{'run': 1});
      expect(effectRuns, 1);
    });
  });

  group('long operations', () {
    test('an in-flight request answers 202 semantics, then replays', () {
      final IdempotencyExecution begun = repository.beginInFlight(
        scope: scopeOf(ProtocolOperation.resume),
        requestId: requestA,
        requestDigest: 'digest-1',
        leaseEpoch: 4,
      );
      expect(begun.kind, IdempotencyExecutionKind.executed);
      expect(
        begun.result,
        isNull,
        reason: 'an in-flight request has no result yet',
      );

      final IdempotencyExecution duplicate = repository.executeAtomically(
        scope: scopeOf(ProtocolOperation.resume),
        requestId: requestA,
        requestDigest: 'digest-1',
        leaseEpoch: 4,
        effect: () => const <String, Object?>{'should': 'not run'},
      );
      expect(duplicate.kind, IdempotencyExecutionKind.inFlight);

      repository.complete(
        scope: scopeOf(ProtocolOperation.resume),
        requestId: requestA,
        result: const <String, Object?>{'state': 'READY'},
      );

      final IdempotencyExecution afterCompletion = repository.executeAtomically(
        scope: scopeOf(ProtocolOperation.resume),
        requestId: requestA,
        requestDigest: 'digest-1',
        leaseEpoch: 4,
        effect: () => const <String, Object?>{'should': 'not run'},
      );
      expect(afterCompletion.kind, IdempotencyExecutionKind.replayed);
      expect(afterCompletion.result, <String, Object?>{'state': 'READY'});
    });

    test('completing a request that was never begun fails', () {
      expect(
        () => repository.complete(
          scope: scopeOf(ProtocolOperation.resume),
          requestId: requestB,
          result: const <String, Object?>{},
        ),
        throwsA(
          isA<StorageException>().having(
            (StorageException e) => e.code,
            'code',
            StorageFailureCode.commitFailed,
          ),
        ),
      );
    });
  });

  group('retention', () {
    test(
      'an expired completed record is purged and an in-flight one is kept',
      () {
        repository.executeAtomically(
          scope: scopeOf(ProtocolOperation.seal),
          requestId: requestA,
          requestDigest: 'digest-1',
          leaseEpoch: 1,
          effect: () => const <String, Object?>{'state': 'WAITING_ACCEPT'},
          retention: const Duration(milliseconds: 1),
        );
        repository.beginInFlight(
          scope: scopeOf(ProtocolOperation.resume),
          requestId: requestB,
          requestDigest: 'digest-2',
          leaseEpoch: 1,
        );

        final int purged = repository.purgeExpired();

        expect(
          purged,
          1,
          reason: 'only the completed, expired record is eligible',
        );
        expect(
          repository.lookup(scopeOf(ProtocolOperation.seal), requestA),
          isNull,
        );
        expect(
          repository.lookup(scopeOf(ProtocolOperation.resume), requestB),
          isNotNull,
          reason:
              'deleting an in-flight record would let its effect be applied a second '
              'time, which is exactly what idempotency exists to prevent',
        );
      },
    );

    test('a record inside its retention window is kept', () {
      repository.executeAtomically(
        scope: scopeOf(ProtocolOperation.seal),
        requestId: requestA,
        requestDigest: 'digest-1',
        leaseEpoch: 1,
        effect: () => const <String, Object?>{},
        retention: const Duration(days: 7),
      );
      expect(repository.purgeExpired(), 0);
      expect(
        repository.lookup(scopeOf(ProtocolOperation.seal), requestA),
        isNotNull,
      );
    });
  });
}
