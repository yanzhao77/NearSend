import 'package:flutter_test/flutter_test.dart';

import 'package:nearsend/core/protocol/idempotency.dart';
import 'package:nearsend/core/protocol/protocol_exception.dart';

/// `request_id` idempotency and `lease_epoch` arbitration, §8 and §9.
///
/// The rules under test are the ones that make recovery safe: a retried request must not
/// produce a second effect, the same recovery id must not advance the write generation
/// twice, and a superseded generation must not be handed back a writable token.
void main() {
  const String transferId = '00000000-0000-4000-8000-000000000001';
  const String requestA = '11111111-1111-4111-8111-111111111111';
  const String requestB = '22222222-2222-4222-8222-222222222222';

  RequestScope scopeOf(
    ProtocolOperation operation, {
    String credential = 'credential-fingerprint-1',
  }) => RequestScope(
    transferId: transferId,
    operation: operation,
    credentialFingerprint: credential,
  );

  group('request id validation', () {
    test('a non-canonical id is refused before anything is stored', () {
      final IdempotencyStore store = IdempotencyStore();
      for (final String bad in <String>[
        'not-a-uuid',
        '11111111-1111-4111-8111-11111111111',
        '11111111-1111-4111-8111-11111111111Z',
        '11111111111141118111111111111111',
      ]) {
        expect(
          () => store.begin(
            scope: scopeOf(ProtocolOperation.pause),
            requestId: bad,
            requestDigest: 'd',
            leaseEpoch: const LeaseEpoch(1),
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
      expect(store.length, 0);
    });
  });

  group('idempotency store', () {
    test('a new id is accepted once and then reported in flight', () {
      final IdempotencyStore store = IdempotencyStore();
      final RequestScope scope = scopeOf(ProtocolOperation.checkpoint);

      expect(
        store
            .begin(
              scope: scope,
              requestId: requestA,
              requestDigest: 'digest-1',
              leaseEpoch: const LeaseEpoch(1),
            )
            .kind,
        IdempotencyOutcomeKind.fresh,
      );
      expect(
        store
            .begin(
              scope: scope,
              requestId: requestA,
              requestDigest: 'digest-1',
              leaseEpoch: const LeaseEpoch(1),
            )
            .kind,
        IdempotencyOutcomeKind.inFlight,
        reason: '§9 answers 202 while the request is still being processed',
      );
    });

    test('a completed id replays the stored result verbatim', () {
      final IdempotencyStore store = IdempotencyStore();
      final RequestScope scope = scopeOf(ProtocolOperation.seal);

      store.begin(
        scope: scope,
        requestId: requestA,
        requestDigest: 'digest-1',
        leaseEpoch: const LeaseEpoch(1),
      );
      store.complete(
        scope: scope,
        requestId: requestA,
        result: const <String, Object?>{'state': 'WAITING_ACCEPT'},
        leaseEpoch: const LeaseEpoch(1),
      );

      final IdempotencyOutcome outcome = store.begin(
        scope: scope,
        requestId: requestA,
        requestDigest: 'digest-1',
        leaseEpoch: const LeaseEpoch(1),
      );
      expect(outcome.kind, IdempotencyOutcomeKind.replay);
      expect(outcome.record!.result, <String, Object?>{
        'state': 'WAITING_ACCEPT',
      });
      expect(
        store.length,
        1,
        reason: 'a replay must not create a second record',
      );
    });

    test('the same id with different parameters is a conflict', () {
      final IdempotencyStore store = IdempotencyStore();
      final RequestScope scope = scopeOf(ProtocolOperation.decision);

      store.begin(
        scope: scope,
        requestId: requestA,
        requestDigest: 'digest-1',
        leaseEpoch: const LeaseEpoch(1),
      );
      final IdempotencyOutcome outcome = store.begin(
        scope: scope,
        requestId: requestA,
        requestDigest: 'digest-2',
        leaseEpoch: const LeaseEpoch(1),
      );
      expect(outcome.kind, IdempotencyOutcomeKind.conflict);
      expect(outcome.errorCode, ProtocolErrorCode.requestIdConflict);
    });

    test('the same id in a different scope is an independent request', () {
      final IdempotencyStore store = IdempotencyStore();
      expect(
        store
            .begin(
              scope: scopeOf(ProtocolOperation.pause),
              requestId: requestA,
              requestDigest: 'digest-1',
              leaseEpoch: const LeaseEpoch(1),
            )
            .kind,
        IdempotencyOutcomeKind.fresh,
      );
      // Different operation.
      expect(
        store
            .begin(
              scope: scopeOf(ProtocolOperation.cancel),
              requestId: requestA,
              requestDigest: 'digest-1',
              leaseEpoch: const LeaseEpoch(1),
            )
            .kind,
        IdempotencyOutcomeKind.fresh,
      );
      // Different recovery credential: §9 scopes the id to the credential in force, so a
      // request id from before a re-pairing must not collide with one after it.
      expect(
        store
            .begin(
              scope: scopeOf(
                ProtocolOperation.pause,
                credential: 'credential-fingerprint-2',
              ),
              requestId: requestA,
              requestDigest: 'digest-1',
              leaseEpoch: const LeaseEpoch(1),
            )
            .kind,
        IdempotencyOutcomeKind.fresh,
      );
      expect(store.length, 3);
    });

    test('completing an id that was never accepted is an internal error', () {
      final IdempotencyStore store = IdempotencyStore();
      expect(
        () => store.complete(
          scope: scopeOf(ProtocolOperation.seal),
          requestId: requestA,
          result: const <String, Object?>{},
          leaseEpoch: const LeaseEpoch(1),
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

  group('lease guard', () {
    test('no writer may write before a generation exists', () {
      final LeaseGuard guard = LeaseGuard();
      expect(guard.current, LeaseEpoch.none);
      expect(guard.current.isAllocated, isFalse);
      expect(
        () => guard.assertWritable(LeaseEpoch.none),
        throwsA(
          isA<ProtocolViolation>().having(
            (ProtocolViolation e) => e.code,
            'code',
            ProtocolErrorCode.staleLease,
          ),
        ),
      );
    });

    test('advancing revokes the previous generation', () {
      final LeaseGuard guard = LeaseGuard();
      final LeaseEpoch first = guard.revokeAndAdvance();
      expect(first, const LeaseEpoch(1));
      expect(guard.isWritable(first), isTrue);

      final LeaseEpoch second = guard.revokeAndAdvance();
      expect(second, const LeaseEpoch(2));
      expect(
        guard.isWritable(first),
        isFalse,
        reason: '§8: an old generation must not keep writing',
      );
      expect(
        () => guard.assertWritable(first),
        throwsA(
          isA<ProtocolViolation>()
              .having(
                (ProtocolViolation e) => e.code,
                'code',
                ProtocolErrorCode.staleLease,
              )
              .having(
                (ProtocolViolation e) => e.detail,
                'detail',
                contains('is not current'),
              ),
        ),
      );
    });

    test('epochs are ordered', () {
      expect(const LeaseEpoch(2) > const LeaseEpoch(1), isTrue);
      expect(const LeaseEpoch(1) < const LeaseEpoch(2), isTrue);
      expect(const LeaseEpoch(1) == const LeaseEpoch(1), isTrue);
      expect(const LeaseEpoch(1).next(), const LeaseEpoch(2));
    });
  });

  group('resume coordination', () {
    late LeaseGuard guard;
    late IdempotencyStore store;
    late ResumeCoordinator coordinator;
    final RequestScope resumeScope = scopeOf(ProtocolOperation.resume);

    setUp(() {
      guard = LeaseGuard();
      store = IdempotencyStore();
      coordinator = ResumeCoordinator(guard: guard, store: store);
    });

    test('a first resume is granted a new generation', () {
      final ResumeOutcome outcome = coordinator.resume(
        scope: resumeScope,
        requestId: requestA,
        requestDigest: 'digest-1',
      );
      expect(outcome.kind, ResumeOutcomeKind.granted);
      expect(outcome.leaseEpoch, const LeaseEpoch(1));
      expect(guard.current, const LeaseEpoch(1));
    });

    test('the same id while in flight answers 202 semantics, not a second generation', () {
      coordinator.resume(
        scope: resumeScope,
        requestId: requestA,
        requestDigest: 'digest-1',
      );
      final ResumeOutcome second = coordinator.resume(
        scope: resumeScope,
        requestId: requestA,
        requestDigest: 'digest-1',
      );
      expect(second.kind, ResumeOutcomeKind.inFlight);
      expect(
        guard.current,
        const LeaseEpoch(1),
        reason: '§9: a retried recovery id must not advance the generation',
      );
    });

    test(
      'retrying a completed resume replays it without advancing the generation',
      () {
        coordinator.resume(
          scope: resumeScope,
          requestId: requestA,
          requestDigest: 'digest-1',
        );
        coordinator.completeResume(
          scope: resumeScope,
          requestId: requestA,
          result: const <String, Object?>{'state': 'READY'},
        );

        final ResumeOutcome replay = coordinator.resume(
          scope: resumeScope,
          requestId: requestA,
          requestDigest: 'digest-1',
        );
        expect(replay.kind, ResumeOutcomeKind.replayed);
        expect(replay.leaseEpoch, const LeaseEpoch(1));
        expect(replay.result, <String, Object?>{'state': 'READY'});
        expect(
          guard.current,
          const LeaseEpoch(1),
          reason: '§9: the same request id must not increment the epoch again',
        );
      },
    );

    test('a second resume with a new id advances the generation', () {
      coordinator.resume(
        scope: resumeScope,
        requestId: requestA,
        requestDigest: 'digest-1',
      );
      coordinator.completeResume(
        scope: resumeScope,
        requestId: requestA,
        result: const <String, Object?>{'state': 'READY'},
      );

      final ResumeOutcome second = coordinator.resume(
        scope: resumeScope,
        requestId: requestB,
        requestDigest: 'digest-2',
      );
      expect(second.kind, ResumeOutcomeKind.granted);
      expect(second.leaseEpoch, const LeaseEpoch(2));
    });

    test('an older id is refused once a newer generation exists', () {
      coordinator.resume(
        scope: resumeScope,
        requestId: requestA,
        requestDigest: 'digest-1',
      );
      coordinator.completeResume(
        scope: resumeScope,
        requestId: requestA,
        result: const <String, Object?>{'state': 'READY'},
      );
      coordinator.resume(
        scope: resumeScope,
        requestId: requestB,
        requestDigest: 'digest-2',
      );

      final ResumeOutcome stale = coordinator.resume(
        scope: resumeScope,
        requestId: requestA,
        requestDigest: 'digest-1',
      );
      expect(
        stale.kind,
        ResumeOutcomeKind.staleResumeRequest,
        reason:
            '§9: the old id must not be answered with a writable token for a '
            'superseded generation',
      );
      expect(stale.errorCode, ProtocolErrorCode.staleResumeRequest);
      expect(
        stale.leaseEpoch,
        const LeaseEpoch(1),
        reason: 'the superseded generation is reported for diagnostics, not for use',
      );
    });

    test(
      'the same id with different parameters is a conflict, not a grant',
      () {
        coordinator.resume(
          scope: resumeScope,
          requestId: requestA,
          requestDigest: 'digest-1',
        );
        final ResumeOutcome conflict = coordinator.resume(
          scope: resumeScope,
          requestId: requestA,
          requestDigest: 'digest-different',
        );
        expect(conflict.kind, ResumeOutcomeKind.conflict);
        expect(conflict.errorCode, ProtocolErrorCode.requestIdConflict);
        expect(guard.current, const LeaseEpoch(1));
      },
    );

    test('the coordinator refuses to handle other operations', () {
      expect(
        () => coordinator.resume(
          scope: scopeOf(ProtocolOperation.pause),
          requestId: requestA,
          requestDigest: 'digest-1',
        ),
        throwsA(
          isA<ProtocolViolation>().having(
            (ProtocolViolation e) => e.code,
            'code',
            ProtocolErrorCode.invalidField,
          ),
        ),
      );
    });

    test('completing a resume that was never granted is an internal error', () {
      expect(
        () => coordinator.completeResume(
          scope: resumeScope,
          requestId: requestB,
          result: const <String, Object?>{},
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

    test(
      'a guard shared between tasks is detected rather than silently allowed',
      () {
        // Two tasks must never share a lease guard. Simulate the mistake by rewinding the
        // guard below a generation it already granted.
        coordinator.resume(
          scope: resumeScope,
          requestId: requestA,
          requestDigest: 'digest-1',
        );
        coordinator.completeResume(
          scope: resumeScope,
          requestId: requestA,
          result: const <String, Object?>{'state': 'READY'},
        );

        final LeaseGuard rewound = LeaseGuard();
        final ResumeCoordinator other = ResumeCoordinator(
          guard: rewound,
          store: store,
        );
        expect(
          () => other.resume(
            scope: resumeScope,
            requestId: requestA,
            requestDigest: 'digest-1',
          ),
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
  });
}
