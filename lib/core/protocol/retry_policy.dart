/// Timeouts and retry semantics, `docs/protocol/v1.0-draft1.md` §11.
///
/// The draft fixes concrete numbers, and they matter in both directions: a client that
/// times out a 20 GiB transfer on total duration would abort healthy work, and one with
/// no ceiling on reconnection would retry forever, which
/// `docs/architecture/SYSTEM_ARCHITECTURE.md` §6 forbids. Both rules are therefore
/// encoded here rather than at each call site.
///
/// Jitter is a parameter, not a hidden random source, so the sequence can be asserted
/// exactly in tests.
library;

/// Fixed timeouts from §11.
abstract final class ProtocolTimeouts {
  /// Connection and TLS establishment.
  static const Duration connectAndTls = Duration(seconds: 10);

  /// An ordinary control request.
  static const Duration controlRequest = Duration(seconds: 30);

  /// A chunk transfer times out on **no byte progress**, not on total duration.
  ///
  /// §11 is explicit that a 20 GiB transfer is not bounded by this value; it is reset
  /// whenever bytes move.
  static const Duration chunkNoProgress = Duration(seconds: 30);

  /// How long the app keeps retrying in the foreground before it stops and waits for
  /// the user (§11: "前台约2分钟后等待用户").
  static const Duration foregroundRetryWindow = Duration(minutes: 2);
}

/// What to do next after a failed attempt.
class RetryDecision {
  const RetryDecision({
    required this.retry,
    required this.delay,
    required this.handOverToUser,
  });

  /// Whether another attempt should be made.
  final bool retry;

  /// How long to wait first. Zero when [retry] is false.
  final Duration delay;

  /// Whether the automatic window is exhausted and the user must act.
  ///
  /// §11 and `SYSTEM_ARCHITECTURE.md` §6 both require retries to be bounded, so an
  /// exhausted window is reported rather than silently continuing.
  final bool handOverToUser;

  @override
  String toString() =>
      'RetryDecision(retry=$retry, delay=${delay.inMilliseconds}ms, '
      'handOverToUser=$handOverToUser)';
}

/// Exponential reconnection backoff with bounded jitter.
class ReconnectBackoff {
  const ReconnectBackoff({
    this.baseDelay = const Duration(seconds: 1),
    this.maxDelay = const Duration(seconds: 30),
    this.jitterFraction = 0.2,
  });

  /// The first delay. §11 gives the sequence as 1/2/4/8 seconds.
  final Duration baseDelay;

  /// §11 caps the delay at 30 seconds.
  final Duration maxDelay;

  /// How much of the delay may be added as jitter, as a fraction.
  ///
  /// A project decision: §11 says "递增加抖动" without quantifying it. Spreading
  /// reconnects matters when several devices retry after one access point returns.
  final double jitterFraction;

  /// The delay for a 1-based [attempt], before jitter.
  Duration nominalDelayForAttempt(int attempt) {
    if (attempt < 1) {
      throw ArgumentError.value(attempt, 'attempt', 'attempts are 1-based');
    }
    // Doubling from the base, saturating at the cap. Computed with a loop rather than
    // a bit shift so an absurd attempt number cannot overflow.
    Duration delay = baseDelay;
    for (int i = 1; i < attempt; i++) {
      delay *= 2;
      if (delay >= maxDelay) {
        return maxDelay;
      }
    }
    return delay > maxDelay ? maxDelay : delay;
  }

  /// The delay for [attempt] with [jitter] applied.
  ///
  /// [jitter] is a value in `[0, 1)` supplied by the caller, so tests are deterministic
  /// and production can pass a random source.
  Duration delayForAttempt(int attempt, {double jitter = 0.0}) {
    if (jitter < 0 || jitter >= 1) {
      throw ArgumentError.value(jitter, 'jitter', 'must be in [0, 1)');
    }
    final Duration nominal = nominalDelayForAttempt(attempt);
    final int extraMicros = (nominal.inMicroseconds * jitterFraction * jitter)
        .round();
    final Duration jittered = nominal + Duration(microseconds: extraMicros);
    return jittered > maxDelay ? maxDelay : jittered;
  }
}

/// The ceiling this client puts on a peer-supplied `Retry-After`.
///
/// §11 says to honour `Retry-After` in seconds for a 429 but sets no ceiling, which
/// would let a peer stall the client for an arbitrary period. Capping it is a project
/// safety decision, recorded in the ledger, and deliberately generous so that a
/// legitimate rate limiter is still respected.
const Duration maxHonouredRetryAfter = Duration(minutes: 5);

/// Retry rules built from §11.
abstract final class RetryPolicy {
  static const ReconnectBackoff reconnect = ReconnectBackoff();

  /// Decides the next step for a dropped link.
  ///
  /// [elapsed] is how long the task has been retrying in the foreground. Once it
  /// reaches [ProtocolTimeouts.foregroundRetryWindow] the client stops retrying and
  /// waits for the user, as §11 requires.
  static RetryDecision forNetworkRetry({
    required int attempt,
    Duration elapsed = Duration.zero,
    double jitter = 0.0,
  }) {
    if (elapsed >= ProtocolTimeouts.foregroundRetryWindow) {
      return const RetryDecision(
        retry: false,
        delay: Duration.zero,
        handOverToUser: true,
      );
    }
    return RetryDecision(
      retry: true,
      delay: reconnect.delayForAttempt(attempt, jitter: jitter),
      handOverToUser: false,
    );
  }

  /// The delay to honour for a 429 with the given `Retry-After` seconds.
  ///
  /// Negative values are invalid and clamped to zero rather than trusted; a caller that
  /// receives a malformed header should retry immediately or treat it as a protocol
  /// violation, and this method makes the arithmetic safe either way.
  static Duration retryAfterDelay(int seconds) {
    if (seconds <= 0) {
      return Duration.zero;
    }
    final Duration requested = Duration(seconds: seconds);
    return requested > maxHonouredRetryAfter
        ? maxHonouredRetryAfter
        : requested;
  }

  /// Whether a chunk transfer should be abandoned for lack of progress.
  ///
  /// Progress, not total time, is what is bounded: §11 requires a 20 GiB transfer at
  /// full speed never to hit this timeout.
  static bool chunkTimedOut(Duration sinceLastByte) =>
      sinceLastByte >= ProtocolTimeouts.chunkNoProgress;
}
