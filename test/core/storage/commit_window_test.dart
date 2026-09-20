import 'package:flutter_test/flutter_test.dart';

import 'package:nearsend/core/protocol/protocol_limits.dart';
import 'package:nearsend/core/storage/commit_window.dart';

/// §8's batch checkpoint window.
///
/// The property that matters is the invariant: **the window never holds more than §8
/// allows**. §8's bound is what makes batching safe at all - everything above it would be
/// verified work that a crash throws away - so most of these tests are about the ways the
/// bound could quietly not hold: a chunk that does not fit, a caller that ignores the
/// plan, or a window that never becomes due because nothing arrives again.
///
/// Numbers are small here so the cases are readable. That the real values come from
/// [ProtocolLimits] is asserted separately, so shrinking a test constant cannot become a
/// silent protocol change.
void main() {
  const CommitWindowPolicy policy = CommitWindowPolicy(
    maxPendingBytes: 16,
    flushIntervalMillis: 1000,
    chunkSizeBytes: 4,
  );

  PendingChunkCommit receipt(int index, {int lengthBytes = 4}) =>
      PendingChunkCommit(
        index: index,
        lengthBytes: lengthBytes,
        sha256: 'a' * 64,
      );

  group('the protocol values', () {
    test('the default policy is §8s numbers, not a local choice', () {
      final ChunkCommitWindow window = ChunkCommitWindow();
      expect(
        window.policy.maxPendingBytes,
        ProtocolLimits.maxPendingCheckpointBytes,
      );
      expect(
        window.policy.flushIntervalMillis,
        ProtocolLimits.checkpointIntervalMillis,
      );
      expect(window.policy.chunkSizeBytes, ProtocolLimits.chunkSizeBytes);
      expect(
        ProtocolLimits.maxPendingCheckpointBytes,
        16 * 1024 * 1024,
        reason: '§8 says 16 MiB',
      );
      expect(
        ProtocolLimits.checkpointIntervalMillis,
        1000,
        reason: '§8 says 1 second',
      );
    });
  });

  group('construction', () {
    test('refuses a window smaller than one chunk', () {
      expect(
        () => ChunkCommitWindow(
          policy: const CommitWindowPolicy(
            maxPendingBytes: 3,
            chunkSizeBytes: 4,
          ),
        ),
        throwsArgumentError,
        reason:
            '§5 chunks are 4 MiB, so a smaller window could not admit a single chunk; '
            'discovering that as a hang or a refusal at the first write would be worse',
      );
    });

    test('refuses a window that can hold nothing', () {
      expect(
        () => ChunkCommitWindow(
          policy: const CommitWindowPolicy(
            maxPendingBytes: 0,
            chunkSizeBytes: 0,
          ),
        ),
        throwsArgumentError,
      );
    });

    test('refuses a negative interval', () {
      expect(
        () => ChunkCommitWindow(
          policy: const CommitWindowPolicy(flushIntervalMillis: -1),
        ),
        throwsArgumentError,
      );
    });

    test('accepts a window of exactly one chunk', () {
      expect(
        () => ChunkCommitWindow(
          policy: const CommitWindowPolicy(
            maxPendingBytes: 4,
            chunkSizeBytes: 4,
            flushIntervalMillis: 0,
          ),
        ),
        returnsNormally,
      );
    });
  });

  group('the bound', () {
    test('a fresh window holds nothing and is not due', () {
      final ChunkCommitWindow window = ChunkCommitWindow(policy: policy);
      expect(window.hasPending, isFalse);
      expect(window.pendingBytes, 0);
      expect(window.pending, isEmpty);
      expect(window.isCheckpointDue(nowMillis: 0), isFalse);
    });

    test('four 4-byte chunks fit in a 16-byte window', () {
      final ChunkCommitWindow window = ChunkCommitWindow(policy: policy);
      for (int i = 0; i < 4; i++) {
        expect(
          window.plan(lengthBytes: 4, nowMillis: 0).flushBefore,
          isFalse,
          reason: 'chunk $i still fits',
        );
        window.enqueue(receipt(i), nowMillis: 0);
      }
      expect(window.pendingBytes, 16);
      expect(window.pending.length, 4);
      expect(
        window.isCheckpointDue(nowMillis: 0),
        isTrue,
        reason: 'reaching §8s 16 MiB is itself the checkpoint',
      );
    });

    test('the fifth chunk is refused admission until the window is flushed', () {
      final ChunkCommitWindow window = ChunkCommitWindow(policy: policy);
      for (int i = 0; i < 4; i++) {
        window.enqueue(receipt(i), nowMillis: 0);
      }

      expect(
        window.plan(lengthBytes: 4, nowMillis: 0).flushBefore,
        isTrue,
        reason:
            'without this the window would grow to 20 bytes; §8 caps it at 16',
      );
    });

    test('enqueue refuses a receipt the caller was told to flush first', () {
      final ChunkCommitWindow window = ChunkCommitWindow(policy: policy);
      for (int i = 0; i < 4; i++) {
        window.enqueue(receipt(i), nowMillis: 0);
      }

      expect(
        () => window.enqueue(receipt(4), nowMillis: 0),
        throwsStateError,
        reason:
            'the bound is only real if bypassing the plan fails loudly rather than '
            'letting the window drift upward',
      );
      expect(window.pendingBytes, 16, reason: 'the refusal changed nothing');
    });

    test('the bound holds across a mixed sequence of lengths', () {
      final ChunkCommitWindow window = ChunkCommitWindow(policy: policy);
      const List<int> lengths = <int>[4, 3, 4, 3, 4, 4, 1, 2, 4, 3, 4];

      for (int i = 0; i < lengths.length; i++) {
        if (window.plan(lengthBytes: lengths[i], nowMillis: 0).flushBefore) {
          window.markFlushed();
        }
        window.enqueue(receipt(i, lengthBytes: lengths[i]), nowMillis: 0);
        expect(
          window.pendingBytes,
          lessThanOrEqualTo(policy.maxPendingBytes),
          reason: 'the window exceeded §8s bound after chunk $i',
        );
      }
    });

    test('a chunk larger than the whole window cannot be admitted', () {
      final ChunkCommitWindow window = ChunkCommitWindow(policy: policy);
      expect(
        () => window.plan(lengthBytes: 17, nowMillis: 0),
        throwsArgumentError,
      );
    });

    test('a negative length is rejected', () {
      final ChunkCommitWindow window = ChunkCommitWindow(policy: policy);
      expect(
        () => window.plan(lengthBytes: -1, nowMillis: 0),
        throwsArgumentError,
      );
    });

    test('plan does not change the window, so it can be re-asked', () {
      final ChunkCommitWindow window = ChunkCommitWindow(policy: policy);
      window.enqueue(receipt(0), nowMillis: 0);
      expect(window.plan(lengthBytes: 4, nowMillis: 500).flushBefore, isFalse);
      expect(window.plan(lengthBytes: 4, nowMillis: 500).flushBefore, isFalse);
      expect(window.pendingBytes, 4);
    });
  });

  group('the one-second rule', () {
    test('is not due just before the interval and due at it', () {
      final ChunkCommitWindow window = ChunkCommitWindow(policy: policy);
      window.enqueue(receipt(0), nowMillis: 0);

      expect(
        window.isCheckpointDue(nowMillis: 999),
        isFalse,
        reason: 'the window is filling and the second has not passed',
      );
      expect(window.isCheckpointDue(nowMillis: 1000), isTrue);
    });

    test('the second runs from the first chunk, not the most recent one', () {
      final ChunkCommitWindow window = ChunkCommitWindow(policy: policy);
      window.enqueue(receipt(0, lengthBytes: 1), nowMillis: 0);
      window.enqueue(receipt(1, lengthBytes: 1), nowMillis: 900);
      window.enqueue(receipt(2, lengthBytes: 1), nowMillis: 999);

      expect(
        window.isCheckpointDue(nowMillis: 1000),
        isTrue,
        reason:
            '§8 says "每 ... 1 秒 checkpoint": the data from t=0 must be persisted, and '
            'measuring from the newest chunk would let a steady stream postpone the '
            'checkpoint forever',
      );
    });

    test('an overdue window is flushed before the next chunk is admitted', () {
      final ChunkCommitWindow window = ChunkCommitWindow(policy: policy);
      window.enqueue(receipt(0, lengthBytes: 1), nowMillis: 0);

      expect(
        window.plan(lengthBytes: 4, nowMillis: 1000).flushBefore,
        isTrue,
        reason: 'the pending data is already past its limit',
      );
    });

    test('markFlushed resets the clock so the next window starts fresh', () {
      final ChunkCommitWindow window = ChunkCommitWindow(policy: policy);
      window.enqueue(receipt(0), nowMillis: 0);
      window.markFlushed();

      expect(window.hasPending, isFalse);
      expect(window.pendingBytes, 0);

      window.enqueue(receipt(1), nowMillis: 1000);
      expect(
        window.isCheckpointDue(nowMillis: 1000),
        isFalse,
        reason:
            'the second window began at t=1000; counting from the previous flush would '
            'make every window immediately due',
      );
      expect(window.isCheckpointDue(nowMillis: 2000), isTrue);
    });
  });

  group('forced boundaries', () {
    test(
      'a pause or file end forces a checkpoint when something is pending',
      () {
        final ChunkCommitWindow window = ChunkCommitWindow(policy: policy);
        window.enqueue(receipt(0, lengthBytes: 1), nowMillis: 0);

        expect(
          window.isCheckpointDue(nowMillis: 1, forced: true),
          isTrue,
          reason:
              '§8 forces a commit on pause and at the end of a file, because those are the '
              'moments at which the answer stops changing',
        );
      },
    );

    test('forcing an empty window is not a checkpoint', () {
      final ChunkCommitWindow window = ChunkCommitWindow(policy: policy);
      expect(window.isCheckpointDue(nowMillis: 0, forced: true), isFalse);
    });
  });

  group('the immediate policy', () {
    test('every chunk is due, including a partial one', () {
      final ChunkCommitWindow window = ChunkCommitWindow(
        policy: CommitWindowPolicy.immediate,
      );

      window.enqueue(receipt(0, lengthBytes: 4), nowMillis: 0);
      expect(
        window.isCheckpointDue(nowMillis: 0),
        isTrue,
        reason: 'a full chunk fills the window',
      );
      window.markFlushed();

      window.enqueue(receipt(1, lengthBytes: 1), nowMillis: 0);
      expect(
        window.isCheckpointDue(nowMillis: 0),
        isTrue,
        reason:
            'a tail chunk is smaller than the window, so only the zero interval makes it '
            'due; relying on the size alone would leave the last chunk of every file '
            'verified but never committed',
      );
    });

    test('holds exactly one chunk, so §8s bound still holds', () {
      final ChunkCommitWindow window = ChunkCommitWindow(
        policy: CommitWindowPolicy.immediate,
      );
      expect(
        window.policy.maxPendingBytes,
        ProtocolLimits.chunkSizeBytes,
        reason: 'one chunk is the most this policy allows to accumulate',
      );
    });
  });

  group('diagnostics', () {
    test('the pending list cannot be mutated by a caller', () {
      final ChunkCommitWindow window = ChunkCommitWindow(policy: policy);
      window.enqueue(receipt(0), nowMillis: 0);
      expect(() => window.pending.add(receipt(1)), throwsUnsupportedError);
    });

    test('receipts describe themselves without dumping the whole digest', () {
      expect(receipt(7).toString(), contains('7'));
      expect(
        receipt(7, lengthBytes: 12).toString(),
        allOf(contains('12B'), contains('aaaaaaaa')),
      );
    });
  });
}
