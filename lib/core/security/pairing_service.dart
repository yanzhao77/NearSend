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

export 'package:nearsend/core/security/pairing_token.dart' show randomUuidV4;

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

  /// Presentation only: a client label is not a persistent device identity.
  /// Readiness requires recent authenticated traffic and an unexpired token.
  List<PairedClientPresence> get pairedClients {
    final int now = _clock();
    return List<PairedClientPresence>.unmodifiable([
      for (final session in _sessionsByDigest.values)
        PairedClientPresence(
          sessionId: session.sessionId,
          label: session.clientLabel,
          isRecent:
              session.expiresAtMillis > now &&
              now - session.lastSeenMillis < 30000,
        ),
    ]);
  }

  /// Whether [source] has exhausted its pairing failure allowance.
  bool isRateLimited(String source) => _issuer.isRateLimited(source);

  /// Whether a peer has paired with the session [sessionId] this device published.
  ///
  /// This is not a security decision and does not gate anything: it answers "has anybody become a
  /// **client of mine**", which is a question the sending side has to ask before it can choose how
  /// to move a file. §6 lists offers to the session a transfer is bound to, so a transfer this
  /// device proposes as a **server** is invisible to a peer that never paired with it - and a sender
  /// that chose that path blindly would wait for a peer that cannot see it.
  ///
  /// Expiry is applied here rather than left to the caller: an expired session is one whose access
  /// token no longer authenticates, so counting it as a live client would produce exactly the wait
  /// this getter exists to avoid.
  bool hasPairedClient(String sessionId) {
    final String? digest = _digestBySession[sessionId];
    if (digest == null) {
      return false;
    }
    final _PairedSession? session = _sessionsByDigest[digest];
    if (session == null || session.sessionId != sessionId) {
      return false;
    }
    return session.expiresAtMillis > _clock();
  }

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
      clientLabel: request.clientLabel,
      lastSeenMillis: _clock(),
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
    session.lastSeenMillis = _clock();
    return SessionGrant(peerId: session.sessionId);
  }

  @override
  String toString() =>
      'PairingService(${_sessionsByDigest.length} live sessions)';
}

final class _PairedSession {
  _PairedSession({
    required this.sessionId,
    required this.tokenDigest,
    required this.clientLabel,
    required this.lastSeenMillis,
    required this.expiresAtMillis,
  });

  final String sessionId;
  final String tokenDigest;
  final String clientLabel;
  int lastSeenMillis;
  final int expiresAtMillis;
}

/// Safe UI projection: deliberately carries no credentials or trust grants.
class PairedClientPresence {
  const PairedClientPresence({
    required this.sessionId,
    required this.label,
    required this.isRecent,
  });
  final String sessionId;
  final String label;
  final bool isRecent;
}
