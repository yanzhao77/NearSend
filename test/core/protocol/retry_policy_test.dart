import 'package:flutter_test/flutter_test.dart';

import 'package:nearsend/core/protocol/retry_policy.dart';

/// Timeouts and retry semantics from §11.
///
/// The numbers are asserted exactly because both directions of error are harmful: a
/// client that bounds a 20 GiB transfer by total duration aborts healthy work, and one
/// without a reconnection ceiling violates `SYSTEM_ARCHITECTURE.md` §6.
void main() {
  group('§11 timeouts', () {
    test('the fixed durations match the draft', () {
      expect(ProtocolTimeouts.connectAndTls, const Duration(seconds: 10));
      expect(ProtocolTimeouts.controlRequest, const Duration(seconds: 30));
      expect(ProtocolTimeouts.chunkNoProgress, const Duration(seconds: 30));
      expect(
        ProtocolTimeouts.foregroundRetryWindow,
        const Duration(minutes: 2),
      );
    });

    test('a chunk is abandoned on stalled progress, not on elapsed time', () {
      // §11 is explicit that a 20 GiB transfer is not bounded by this value. Progress
      // resets the timer, so only a stall of the full window trips it.
      expect(RetryPolicy.chunkTimedOut(const Duration(seconds: 29)), isFalse);
      expect(RetryPolicy.chunkTimedOut(const Duration(seconds: 30)), isTrue);
      expect(
        RetryPolicy.chunkTimedOut(const Duration(minutes: 45)),
        isTrue,
        reason: 'a long stall is still a stall',
      );
      expect(
        RetryPolicy.chunkTimedOut(Duration.zero),
        isFalse,
        reason: 'a just-received byte must not be treated as a timeout',
      );
    });
  });

  group('reconnection backoff', () {
    const ReconnectBackoff backoff = ReconnectBackoff();

    test('the nominal sequence doubles from one second and caps at thirty', () {
      expect(backoff.nominalDelayForAttempt(1), const Duration(seconds: 1));
      expect(backoff.nominalDelayForAttempt(2), const Duration(seconds: 2));
      expect(backoff.nominalDelayForAttempt(3), const Duration(seconds: 4));
      expect(backoff.nominalDelayForAttempt(4), const Duration(seconds: 8));
      expect(backoff.nominalDelayForAttempt(5), const Duration(seconds: 16));
      expect(
        backoff.nominalDelayForAttempt(6),
        const Duration(seconds: 30),
        reason: '§11 caps the delay at 30 seconds',
      );
      expect(backoff.nominalDelayForAttempt(7), const Duration(seconds: 30));
      expect(backoff.nominalDelayForAttempt(1000), const Duration(seconds: 30));
    });

    test('the cap survives an absurd attempt number without overflowing', () {
      expect(
        backoff.nominalDelayForAttempt(100000),
        const Duration(seconds: 30),
      );
    });

    test('attempts are one-based', () {
      expect(
        () => backoff.nominalDelayForAttempt(0),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => backoff.nominalDelayForAttempt(-1),
        throwsA(isA<ArgumentError>()),
      );
    });

    test(
      'jitter is a caller-supplied value, so the result is deterministic',
      () {
        expect(
          backoff.delayForAttempt(1, jitter: 0),
          const Duration(seconds: 1),
        );
        expect(
          backoff.delayForAttempt(1, jitter: 0.5),
          const Duration(milliseconds: 1100),
          reason: '20% of one second, halved',
        );
        expect(
          backoff.delayForAttempt(1, jitter: 0.999),
          const Duration(microseconds: 1199800),
        );
      },
    );

    test('jitter is bounded and validated', () {
      expect(
        () => backoff.delayForAttempt(1, jitter: -0.1),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => backoff.delayForAttempt(1, jitter: 1.0),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('jitter never pushes the delay past the cap', () {
      for (final double jitter in <double>[0, 0.5, 0.99]) {
        expect(
          backoff.delayForAttempt(10, jitter: jitter),
          lessThanOrEqualTo(const Duration(seconds: 30)),
        );
      }
    });
  });

  group('network retry is bounded', () {
    test('retries with a delay while inside the foreground window', () {
      final RetryDecision decision = RetryPolicy.forNetworkRetry(
        attempt: 3,
        elapsed: const Duration(seconds: 30),
      );
      expect(decision.retry, isTrue);
      expect(decision.handOverToUser, isFalse);
      expect(decision.delay, const Duration(seconds: 4));
    });

    test('hands over to the user once the window is exhausted', () {
      for (final Duration elapsed in <Duration>[
        const Duration(minutes: 2),
        const Duration(minutes: 5),
        const Duration(hours: 1),
      ]) {
        final RetryDecision decision = RetryPolicy.forNetworkRetry(
          attempt: 20,
          elapsed: elapsed,
        );
        expect(
          decision.retry,
          isFalse,
          reason: '§11 and SYSTEM_ARCHITECTURE §6 forbid unbounded retrying',
        );
        expect(decision.handOverToUser, isTrue);
        expect(decision.delay, Duration.zero);
      }
    });

    test('the window boundary is inclusive on the hand-over side', () {
      expect(
        RetryPolicy.forNetworkRetry(
          attempt: 1,
          elapsed: const Duration(minutes: 1, seconds: 59),
        ).retry,
        isTrue,
      );
      expect(
        RetryPolicy.forNetworkRetry(
          attempt: 1,
          elapsed: const Duration(minutes: 2),
        ).retry,
        isFalse,
      );
    });
  });

  group('Retry-After handling', () {
    test('a positive value is honoured', () {
      expect(RetryPolicy.retryAfterDelay(1), const Duration(seconds: 1));
      expect(RetryPolicy.retryAfterDelay(30), const Duration(seconds: 30));
      expect(RetryPolicy.retryAfterDelay(300), const Duration(minutes: 5));
    });

    test('zero and negative values do not produce a negative delay', () {
      expect(RetryPolicy.retryAfterDelay(0), Duration.zero);
      expect(RetryPolicy.retryAfterDelay(-5), Duration.zero);
    });

    test('an implausible value is capped rather than trusted', () {
      // §11 sets no ceiling, so a peer could otherwise stall this client indefinitely.
      // The cap is a documented project safety decision.
      expect(
        RetryPolicy.retryAfterDelay(86400),
        maxHonouredRetryAfter,
        reason: 'a peer must not be able to park the client for a day',
      );
      expect(maxHonouredRetryAfter, const Duration(minutes: 5));
    });
  });
}
