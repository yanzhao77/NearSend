/// The server half of §3: opening a pairing session, and deciding what comes back.
///
/// `docs/protocol/v1.0-draft1.md` §3 splits the work in two. The QR code carries a
/// **one-time** token with a 300 second window, judged by server monotonic time; a successful
/// `POST /v1/pair` returns a **session access token** valid for 1800 seconds, which then
/// authorises everything else §7 lists. Those are different credentials with different
/// lifetimes, and this file is where they meet.
///
/// ## Only digests are stored
///
/// §2 already applies this to the resume key, and §3's wording is the same shape, so neither
/// the pairing token nor the session access token is held: what is stored is
/// `SHA-256(token)`. The issuer keeps its own digest of the pairing token; this class keeps
/// one of the access token. A caller cannot recover a credential from either map, which is
/// what makes "logs must not contain tokens" a property of the design rather than of the
/// logging code.
///
/// ## Why `nowMillis` is ignored
///
/// [authenticate] receives the pipeline's clock and does not use it. §3 requires the pairing
/// window to be judged "以服务端单调计时判定" precisely because a wall clock can be moved -
/// by NTP, by a user, by a flat battery. Applying a monotonic rule to one credential and a
/// wall-clock rule to the other would mean a clock jump extends one and truncates the other.
/// The injected clock is monotonic, and tests control it directly.
///
/// ## What is deliberately not decided here
///
/// §3's response carries `capabilities:[...]` and the specification never enumerates an
/// identifier. `AGENTS.md` §3 forbids settling an unresolved protocol detail by preference,
/// so this server advertises an **empty** capability set and performs no negotiation. That
/// is a registered gap (`docs/PROJECT_LEDGER.md` §5), and it is honest rather than convenient:
/// both ends of this build are the same code, so they agree because neither claims anything.
library;

import 'package:nearsend/core/network/control_authorization.dart';
import 'package:nearsend/core/network/control_message.dart';
import 'package:nearsend/core/network/control_pipeline.dart';
import 'package:nearsend/core/protocol/api_routes.dart';
import 'package:nearsend/core/protocol/base64url.dart';
import 'package:nearsend/core/protocol/protocol_exception.dart';
import 'package:nearsend/core/protocol/protocol_limits.dart';
import 'package:nearsend/core/protocol/protocol_version.dart';
import 'package:nearsend/core/security/credential_fingerprint.dart';
import 'package:nearsend/core/security/pair_request.dart';
import 'package:nearsend/core/security/pairing_payload.dart';
import 'package:nearsend/core/security/pairing_token.dart';

/// The source key used when the transport did not report a peer address.
///
/// A single shared bucket, deliberately: sharing means peers with no address compete for one
/// limit, which is the fail-closed direction. See [ControlRequest.peerAddress].
const String unknownPairingSource = 'unknown-source';

/// Issues pairing sessions and resolves the session access tokens they produce.
///
/// Implements [ControlAuthenticator] as well as serving the endpoint, because the two halves
/// are one fact: the token this class issues is the token that class must later accept.
/// Splitting them would let the issuer and the authenticator disagree about what an issued
/// token looks like, which is a failure nothing would catch until a real pairing failed.
class PairingService implements ControlAuthenticator {
  PairingService({
    required this.serverFingerprint,
    required this.candidates,
    MonotonicMillis? clock,
    int? pairTokenTtlMillis,
    int? sessionTtlMillis,
  }) : _clock = clock ?? _stopwatchClock(),
       _sessionTtlMillis =
           sessionTtlMillis ??
           ProtocolLimits.sessionAccessTokenTtlSeconds * 1000 {
    _issuer = PairingTokenIssuer(
      clock: _clock,
      ttlMillis:
          pairTokenTtlMillis ?? ProtocolLimits.pairTokenTtlSeconds * 1000,
    );
  }

  /// The pin this server publishes: `SHA-256(leaf certificate DER)` (§2).
  final String serverFingerprint;

  /// The addresses the QR code offers, in order (§3).
  /// The addresses the QR code offers.
  ///
  /// **Mutable on purpose.** A server that asks the system for a free port does not know it until
  /// the socket is bound, so a payload issued before then would offer port `0` - an address no peer
  /// can connect to. The node re-points these once it is listening, and nothing else may: the pin,
  /// the session and the token are what a payload's trust rests on, and this only changes where the
  /// peer is told to look.
  List<PairingCandidate> candidates;

  final MonotonicMillis _clock;
  final int _sessionTtlMillis;
  late final PairingTokenIssuer _issuer;

  /// Access tokens by digest. The token itself is never a key or a value.
  final Map<String, _PairedSession> _sessionsByDigest =
      <String, _PairedSession>{};

  /// Session id to the digest of its current access token.
  ///
  /// A second index rather than a scan, because [openSession] has to find and drop the
  /// previous token for a session it is re-issuing. Without it, re-issuing would leave the
  /// old access token working, which is the opposite of what §3 asks for.
  final Map<String, String> _digestBySession = <String, String>{};

  static MonotonicMillis _stopwatchClock() {
    final Stopwatch stopwatch = Stopwatch()..start();
    return () => stopwatch.elapsedMilliseconds;
  }

  /// The number of live sessions, for tests and diagnostics. Never the tokens.
  int get liveSessionCount => _sessionsByDigest.length;

  /// Whether [source] has exhausted its pairing failure allowance.
  bool isRateLimited(String source) => _issuer.isRateLimited(source);

  /// Re-points the candidates at the port the socket actually bound.
  ///
  /// Called by the node once it is listening, and only then: a payload issued while the port was
  /// still unknown would offer `0`, which no peer can connect to. Kept as an explicit method rather
  /// than a settable field so the one caller that may do this is visible, and so its comment can say
  /// what it must not be used for - changing identity or credentials, which live elsewhere in the
  /// payload and are what trust rests on.
  void repointCandidates(List<PairingCandidate> bound) {
    candidates = List<PairingCandidate>.unmodifiable(bound);
  }

  /// Opens a new pairing session and returns what the QR code should carry.
  ///
  /// Any session already existing for [sessionId] loses its access token: §3 says a lost
  /// pairing response means "重新生成 QR", and a screenshot of the previous code must not
  /// remain a working credential once a new one exists.
  PairingPayload openSession({String? sessionId}) {
    final String id = sessionId ?? randomUuidV4();
    final List<int> tokenBytes = generatePairingTokenBytes();
    final IssuedPairingToken issued = _issuer.issue(
      sessionId: id,
      tokenBytes: tokenBytes,
    );

    // §3: a new QR replaces the old one, so the previous access token for this session stops
    // working. Leaving it live would make a screenshot of the earlier code a credential.
    final String? previousDigest = _digestBySession.remove(id);
    if (previousDigest != null) {
      _sessionsByDigest.remove(previousDigest);
    }

    return PairingPayload(
      serverFingerprint: serverFingerprint,
      sessionId: issued.sessionId,
      candidates: candidates,
      pairToken: encodeBase64UrlNoPadding(tokenBytes),
      expiresInSeconds: ProtocolLimits.pairTokenTtlSeconds,
    );
  }

  /// Serves `POST /v1/pair`.
  ///
  /// The rate limit is consulted through the issuer, which checks it **before** looking at
  /// the token: a caller that is over its allowance must not be able to tell a valid token
  /// from an invalid one by watching which error it gets.
  ControlResponse pair({
    required PairRequest request,
    required String? source,
  }) {
    final String sourceKey = source ?? unknownPairingSource;
    final PairingAttempt attempt = _issuer.consume(
      source: sourceKey,
      sessionId: request.sessionId,
      pairToken: request.pairToken,
    );

    switch (attempt.result) {
      case PairingAttemptResult.rateLimited:
        // §11 attaches Retry-After to a 429, and the issuer derives a delay from when the
        // limit actually lifts rather than from the window length.
        return ControlResponse.error(
          ProtocolErrorCode.rateLimited,
          retryAfterSeconds: _issuer.retryAfterSeconds(sourceKey),
        );
      case PairingAttemptResult.rejected:
        // Every local rejection reason maps to one wire code, so the answer cannot be used
        // to probe whether a session or a token exists.
        return ControlResponse.error(attempt.wireCode!);
      case PairingAttemptResult.accepted:
        break;
    }

    final String accessToken = encodeBase64UrlNoPadding(
      generateSecureRandomBytes(ProtocolLimits.accessTokenBytes),
    );
    final String digest = credentialFingerprint(accessToken);
    _sessionsByDigest[digest] = _PairedSession(
      sessionId: request.sessionId,
      tokenDigest: digest,
      expiresAtMillis: _clock() + _sessionTtlMillis,
    );
    _digestBySession[request.sessionId] = digest;

    return ControlResponse.json(
      status: 200,
      body: PairResponse(
        sessionAccessToken: accessToken,
        // See the library comment: the vocabulary is undefined, so nothing is claimed.
        capabilities: CapabilitySet(const <Capability>[]),
      ).toJson(),
    );
  }

  /// The pipeline closures, keyed by route name.
  Map<String, ControlHandler> handlers() => <String, ControlHandler>{
    ApiRoutes.pair.name:
        (
          ControlRequest request,
          MatchedApiRequest matched,
          ControlAuthorized authorization,
        ) async => pair(
          request: PairRequest.parse(
            request.decodeJsonBody(scope: 'the pairing request'),
          ),
          source: request.peerAddress,
        ),
  };

  @override
  ControlGrant? authenticate({required String token, required int nowMillis}) {
    // The pipeline's clock is deliberately unused; see the library comment.
    final String digest = credentialFingerprint(token);
    final _PairedSession? session = _sessionsByDigest[digest];
    if (session == null) {
      return null;
    }
    if (_clock() >= session.expiresAtMillis) {
      _sessionsByDigest.remove(digest);
      return null;
    }
    // The peer id is the session, not a device fingerprint. §3 makes the client label
    // display-only and the peer identity is established separately (T04-01's peer
    // repository), so claiming a device identity here would be inventing one.
    return SessionGrant(peerId: session.sessionId);
  }

  @override
  String toString() =>
      'PairingService(${_sessionsByDigest.length} live sessions)';
}

final class _PairedSession {
  const _PairedSession({
    required this.sessionId,
    required this.tokenDigest,
    required this.expiresAtMillis,
  });

  final String sessionId;
  final String tokenDigest;
  final int expiresAtMillis;
}

/// Generates a canonical lowercase UUID version 4 (§4).
///
/// Written here rather than taken from a package because §4's rules are about the *spelling*,
/// and a UUID library that emits uppercase or urn-prefixed forms would produce identifiers
/// this project's own `uuidToBytes` refuses. The version and variant bits are set as RFC 4122
/// requires, so the result is a real v4 and not merely 16 random bytes in the right shape.
String randomUuidV4() {
  final List<int> bytes = generateSecureRandomBytes(ProtocolLimits.uuidBytes);
  bytes[6] = (bytes[6] & 0x0F) | 0x40; // version 4
  bytes[8] = (bytes[8] & 0x3F) | 0x80; // RFC 4122 variant
  final String hex = bytes
      .map((int b) => b.toRadixString(16).padLeft(2, '0'))
      .join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}
