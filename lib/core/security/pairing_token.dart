/// The server half of pairing: issuing and consuming a one-time pairing token.
///
/// `docs/protocol/v1.0-draft1.md` §3 fixes the behaviour this file implements:
///
/// > 配对令牌 300 秒内单次消费，以服务端**单调计时**判定；服务重启时未消费的配对令牌全部失效。
/// > 配对响应丢失时不恢复已消费配对令牌，重新生成 QR；既有已授权任务走恢复凭证。
/// > 失败统一 PAIR_REJECTED，避免暴露令牌存在性。
/// > 每来源初始限制每分钟 5 次失败，全局每分钟 30 次失败，返回 429，限流不替代随机熵。
///
/// ## Three decisions worth stating
///
/// **Only a digest of the token is kept.** §2 already applies this principle to the
/// recovery secret - "服务端仅保存恢复密钥验证摘要" - and the pairing token deserves the
/// same treatment: a process memory dump then yields no usable token, and the comparison
/// never involves the token itself.
///
/// **The comparison is not claimed to be constant time.** Comparing secrets in constant
/// time is normally the right default, but Dart offers no such guarantee: the JIT may
/// reorder, and the runtime gives a plain comparison no timing contract. A hand-written
/// loop would therefore be a *false* assurance - worse than an ordinary comparison,
/// because it asserts a property the platform does not provide. What actually bounds the
/// risk here is structural: 256 bits of entropy, single use, a 300 second window, a
/// sliding failure limit, and a stored digest rather than the token.
///
/// **Failures are uniform on the wire.** Unknown session, expired token, already consumed
/// token and wrong token are indistinguishable to the peer, because §3 requires that a
/// caller cannot learn whether a token exists. The internal reason is kept for
/// diagnostics and is deliberately unreachable from [PairingAttempt.wireCode].
///
/// ## Nothing is persisted, on purpose
///
/// A restart must invalidate every unconsumed token (§3). Keeping the state in memory
/// makes that automatic rather than something a crash could violate, so there is no
/// store, no file and no column for it.
library;

import 'dart:math';

import 'package:crypto/crypto.dart';

import 'package:nearsend/core/protocol/base64url.dart';
import 'package:nearsend/core/protocol/protocol_exception.dart';
import 'package:nearsend/core/protocol/protocol_limits.dart';
import 'package:nearsend/core/protocol/protocol_validation.dart';

/// A monotonic elapsed-time source, in milliseconds.
///
/// §3 requires the window to be judged by a monotonic clock. A wall clock can move
/// backwards - an NTP correction or a user changing the date would otherwise extend a
/// token's life or expire a live one - so the type is named for what it must be.
typedef MonotonicMillis = int Function();

/// A pairing token that has been handed out.
class IssuedPairingToken {
  const IssuedPairingToken({
    required this.sessionId,
    required this.token,
    required this.expiresAtMillis,
  });

  final String sessionId;

  /// The canonical unpadded base64url spelling, which is what the QR code carries.
  final String token;

  /// When it stops being accepted, on the issuer's monotonic clock.
  final int expiresAtMillis;

  @override
  String toString() =>
      'IssuedPairingToken(session $sessionId, expires at $expiresAtMillis)';
}

/// Why an attempt was rejected, for local diagnostics only.
///
/// Never serialised: §3 requires every failure to look the same to the peer, and this
/// enum is the one thing that would distinguish them.
enum PairingRejection {
  /// No token is outstanding for that session - never issued, already consumed, or lost
  /// to a restart.
  unknownSession,

  /// The token existed and its window has closed.
  expired,

  /// A token is outstanding but the presented value is not it.
  wrongToken,
}

/// What happened to one `POST /v1/pair` attempt.
enum PairingAttemptResult {
  /// The token was valid and has now been consumed.
  accepted,

  /// The attempt did not pair. The peer is told only `PAIR_REJECTED`.
  rejected,

  /// Too many failures from this source or overall. The peer is told `RATE_LIMITED`.
  rateLimited,
}

/// The outcome of one attempt.
class PairingAttempt {
  const PairingAttempt._({
    required this.result,
    this.sessionId,
    this.rejection,
  });

  const PairingAttempt.accepted(String sessionId)
    : this._(result: PairingAttemptResult.accepted, sessionId: sessionId);

  const PairingAttempt.rejected(PairingRejection rejection)
    : this._(result: PairingAttemptResult.rejected, rejection: rejection);

  const PairingAttempt.rateLimited()
    : this._(result: PairingAttemptResult.rateLimited);

  final PairingAttemptResult result;

  /// The session that was authorised. Set only when accepted.
  final String? sessionId;

  /// The local reason. **Never sent to the peer**; see [wireCode].
  final PairingRejection? rejection;

  bool get isAccepted => result == PairingAttemptResult.accepted;

  /// The answer the peer receives.
  ///
  /// A rejection always maps to the same code so that a caller cannot probe for the
  /// existence of a token; only the rate limit is distinguishable, because §3 prescribes
  /// 429 for it.
  ProtocolErrorCode? get wireCode {
    switch (result) {
      case PairingAttemptResult.accepted:
        return null;
      case PairingAttemptResult.rejected:
        return ProtocolErrorCode.pairRejected;
      case PairingAttemptResult.rateLimited:
        return ProtocolErrorCode.rateLimited;
    }
  }

  @override
  String toString() =>
      'PairingAttempt(${result.name}'
      '${rejection == null ? '' : ', ${rejection!.name}'})';
}

/// Generates the 32 random bytes a pairing token is made of.
///
/// `Random.secure()` is the platform CSPRNG; §3's "限流不替代随机熵" is the reason this is
/// the only sanctioned source, and the reason the entropy is not reduced because a rate
/// limit also exists.
List<int> generatePairingTokenBytes() {
  final Random random = Random.secure();
  return List<int>.generate(
    ProtocolLimits.pairTokenBytes,
    (_) => random.nextInt(256),
  );
}

/// Issues and consumes one-time pairing tokens.
class PairingTokenIssuer {
  PairingTokenIssuer({
    MonotonicMillis? clock,
    this.ttlMillis = ProtocolLimits.pairTokenTtlSeconds * 1000,
    this.perSourceFailureLimit = defaultPerSourceFailureLimit,
    this.globalFailureLimit = defaultGlobalFailureLimit,
    this.failureWindowMillis = defaultFailureWindowMillis,
  }) : _clock = clock ?? _stopwatchClock();

  final MonotonicMillis _clock;

  /// How long an unconsumed token stays valid (§3: 300 seconds).
  final int ttlMillis;

  /// Failures allowed per source inside the window (§3: 5 per minute).
  final int perSourceFailureLimit;

  /// Failures allowed in total inside the window (§3: 30 per minute).
  final int globalFailureLimit;

  final int failureWindowMillis;

  static const int defaultPerSourceFailureLimit = 5;
  static const int defaultGlobalFailureLimit = 30;
  static const int defaultFailureWindowMillis = 60000;

  /// Outstanding tokens, keyed by session, holding only a digest of the token.
  final Map<String, _OutstandingToken> _outstanding =
      <String, _OutstandingToken>{};

  /// Failure timestamps, for the sliding window.
  final Map<String, List<int>> _failuresBySource = <String, List<int>>{};
  final List<int> _globalFailures = <int>[];

  static MonotonicMillis _stopwatchClock() {
    final Stopwatch stopwatch = Stopwatch()..start();
    return () => stopwatch.elapsedMilliseconds;
  }

  /// Issues a token for [sessionId], replacing any token already outstanding for it.
  ///
  /// Replacing is the reading of "配对响应丢失时……重新生成 QR": once a new QR exists the
  /// old one must not still pair, or a screenshot of the previous code would remain a
  /// working credential.
  IssuedPairingToken issue({
    required String sessionId,
    required List<int> tokenBytes,
  }) {
    // §4's canonical UUID form, so a session id cannot mean two things.
    uuidToBytes(sessionId, 'sessionId');
    if (tokenBytes.length != ProtocolLimits.pairTokenBytes) {
      throw ProtocolViolation(
        ProtocolErrorCode.invalidField,
        'a pairing token must be ${ProtocolLimits.pairTokenBytes} random bytes, got '
        '${tokenBytes.length}',
      );
    }

    final int now = _clock();
    _dropExpired(now);

    final String token = encodeBase64UrlNoPadding(tokenBytes);
    final IssuedPairingToken issued = IssuedPairingToken(
      sessionId: sessionId,
      token: token,
      expiresAtMillis: now + ttlMillis,
    );
    _outstanding[sessionId] = _OutstandingToken(
      digest: _digestOf(token),
      expiresAtMillis: issued.expiresAtMillis,
    );
    return issued;
  }

  /// Whether [source] is currently refused new attempts.
  bool isRateLimited(String source) {
    final int now = _clock();
    _pruneFailures(now);
    return _globalFailures.length >= globalFailureLimit ||
        (_failuresBySource[source]?.length ?? 0) >= perSourceFailureLimit;
  }

  /// Consumes the token for [sessionId], if it is valid.
  ///
  /// [source] identifies the caller for the per-source failure limit. The rate limit is
  /// checked **before** the token is examined, so a caller that is over the limit learns
  /// nothing about the token it presented.
  PairingAttempt consume({
    required String source,
    required String sessionId,
    required String pairToken,
  }) {
    if (isRateLimited(source)) {
      return const PairingAttempt.rateLimited();
    }

    final int now = _clock();
    final _OutstandingToken? outstanding = _outstanding[sessionId];

    if (outstanding == null) {
      return _recordFailure(source, PairingRejection.unknownSession);
    }
    if (now >= outstanding.expiresAtMillis) {
      // Consumed either way: an expired token must not be reusable if the clock is
      // somehow rewound, and leaving it would keep a dead credential in memory.
      _outstanding.remove(sessionId);
      return _recordFailure(source, PairingRejection.expired);
    }

    // Compared as digests. The token itself is never held by the issuer, so this is the
    // only form in which the comparison can be made.
    if (_digestOf(pairToken) != outstanding.digest) {
      return _recordFailure(source, PairingRejection.wrongToken);
    }

    // Single consumption, whether or not the response reaches the peer (§3).
    _outstanding.remove(sessionId);
    return PairingAttempt.accepted(sessionId);
  }

  PairingAttempt _recordFailure(String source, PairingRejection rejection) {
    final int now = _clock();
    (_failuresBySource[source] ??= <int>[]).add(now);
    _globalFailures.add(now);
    return PairingAttempt.rejected(rejection);
  }

  void _dropExpired(int now) {
    _outstanding.removeWhere(
      (String _, _OutstandingToken token) => now >= token.expiresAtMillis,
    );
  }

  void _pruneFailures(int now) {
    final int cutoff = now - failureWindowMillis;
    _globalFailures.removeWhere((int at) => at <= cutoff);
    _failuresBySource.removeWhere((String _, List<int> times) {
      times.removeWhere((int at) => at <= cutoff);
      return times.isEmpty;
    });
  }

  /// SHA-256 of the canonical spelling, which is what the issuer stores and compares.
  static String _digestOf(String token) =>
      bytesToSha256Hex(sha256.convert(token.codeUnits).bytes);
}

/// What the issuer remembers about one outstanding token.
class _OutstandingToken {
  const _OutstandingToken({
    required this.digest,
    required this.expiresAtMillis,
  });

  final String digest;
  final int expiresAtMillis;
}
