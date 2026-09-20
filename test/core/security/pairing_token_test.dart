import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:nearsend/core/protocol/base64url.dart';
import 'package:nearsend/core/protocol/protocol_exception.dart';
import 'package:nearsend/core/protocol/protocol_limits.dart';
import 'package:nearsend/core/security/pairing_token.dart';

/// Issuing and consuming one-time pairing tokens.
///
/// §3 fixes several behaviours that are easy to get subtly wrong and that a happy-path
/// test would not notice: the window is judged on a **monotonic** clock, a token is
/// consumed exactly once, a restart invalidates everything unconsumed, and every failure
/// looks the same to the peer.
void main() {
  const String sessionId = '3f2504e0-4f89-41d3-9a0c-0305e82c3301';
  const String otherSession = '9c858901-8a57-4791-81fe-4c455b099bc9';
  const String source = '192.168.43.10';

  late int now;
  late PairingTokenIssuer issuer;

  int clock() => now;

  setUp(() {
    now = 1000;
    issuer = PairingTokenIssuer(clock: clock);
  });

  List<int> bytes(int seed) =>
      Uint8List.fromList(List<int>.generate(32, (int i) => (seed + i) & 0xFF));

  String tokenText(int seed) => encodeBase64UrlNoPadding(bytes(seed));

  group('issuing', () {
    test('the issued token is the canonical spelling of the bytes given', () {
      final IssuedPairingToken issued = issuer.issue(
        sessionId: sessionId,
        tokenBytes: bytes(1),
      );

      expect(issued.sessionId, sessionId);
      expect(issued.token, tokenText(1));
      expect(issued.token, hasLength(ProtocolLimits.pairTokenChars));
      expect(
        issued.expiresAtMillis,
        now + ProtocolLimits.pairTokenTtlSeconds * 1000,
      );
    });

    test('a fresh token is accepted once', () {
      final IssuedPairingToken issued = issuer.issue(
        sessionId: sessionId,
        tokenBytes: bytes(1),
      );

      final PairingAttempt attempt = issuer.consume(
        source: source,
        sessionId: sessionId,
        pairToken: issued.token,
      );

      expect(attempt.result, PairingAttemptResult.accepted);
      expect(attempt.sessionId, sessionId);
      expect(attempt.wireCode, isNull);
    });

    test('issuing again replaces the outstanding token', () {
      final IssuedPairingToken first = issuer.issue(
        sessionId: sessionId,
        tokenBytes: bytes(1),
      );
      final IssuedPairingToken second = issuer.issue(
        sessionId: sessionId,
        tokenBytes: bytes(2),
      );

      expect(second.token, isNot(first.token));
      expect(
        issuer
            .consume(
              source: source,
              sessionId: sessionId,
              pairToken: first.token,
            )
            .isAccepted,
        isFalse,
        reason:
            'a screenshot of the previous QR code must not stay a working credential '
            'once a new one has been generated',
      );
      expect(
        issuer
            .consume(
              source: source,
              sessionId: sessionId,
              pairToken: second.token,
            )
            .isAccepted,
        isTrue,
      );
    });

    test('a session id that is not a canonical UUID is refused', () {
      expect(
        () => issuer.issue(sessionId: 'not-a-uuid', tokenBytes: bytes(1)),
        throwsA(isA<ProtocolViolation>()),
      );
      expect(
        () => issuer.issue(
          sessionId: sessionId.toUpperCase(),
          tokenBytes: bytes(1),
        ),
        throwsA(isA<ProtocolViolation>()),
      );
    });

    test('the wrong number of token bytes is refused', () {
      expect(
        () => issuer.issue(
          sessionId: sessionId,
          tokenBytes: bytes(1).sublist(0, 16),
        ),
        throwsA(isA<ProtocolViolation>()),
      );
    });
  });

  group('the window is judged on the monotonic clock', () {
    test('a token is accepted just inside the window', () {
      final IssuedPairingToken issued = issuer.issue(
        sessionId: sessionId,
        tokenBytes: bytes(1),
      );

      now += ProtocolLimits.pairTokenTtlSeconds * 1000 - 1;

      expect(
        issuer
            .consume(
              source: source,
              sessionId: sessionId,
              pairToken: issued.token,
            )
            .isAccepted,
        isTrue,
      );
    });

    test('a token is rejected once the window has closed', () {
      final IssuedPairingToken issued = issuer.issue(
        sessionId: sessionId,
        tokenBytes: bytes(1),
      );

      now += ProtocolLimits.pairTokenTtlSeconds * 1000;

      final PairingAttempt attempt = issuer.consume(
        source: source,
        sessionId: sessionId,
        pairToken: issued.token,
      );

      expect(attempt.result, PairingAttemptResult.rejected);
      expect(attempt.rejection, PairingRejection.expired);
    });

    test('an expired token is forgotten, so the session becomes unknown', () {
      final IssuedPairingToken issued = issuer.issue(
        sessionId: sessionId,
        tokenBytes: bytes(1),
      );
      now += ProtocolLimits.pairTokenTtlSeconds * 1000;

      expect(
        issuer
            .consume(
              source: source,
              sessionId: sessionId,
              pairToken: issued.token,
            )
            .rejection,
        PairingRejection.expired,
      );
      expect(
        issuer
            .consume(
              source: source,
              sessionId: sessionId,
              pairToken: issued.token,
            )
            .rejection,
        PairingRejection.unknownSession,
        reason: 'the dead credential is not kept around',
      );
    });

    test('elapsed time is what matters, not the value the clock starts at', () {
      final IssuedPairingToken issued = issuer.issue(
        sessionId: sessionId,
        tokenBytes: bytes(1),
      );

      // A second issuer starting from a completely different origin, with the same
      // elapsed time, accepts its own token - which is what "monotonic elapsed" means.
      now = 900000;
      final PairingTokenIssuer later = PairingTokenIssuer(clock: clock);
      final IssuedPairingToken other = later.issue(
        sessionId: sessionId,
        tokenBytes: bytes(3),
      );
      expect(issued.token, isNot(other.token));

      now = 900000 + ProtocolLimits.pairTokenTtlSeconds * 1000 - 1;
      expect(
        later
            .consume(
              source: source,
              sessionId: sessionId,
              pairToken: other.token,
            )
            .isAccepted,
        isTrue,
      );
    });
  });

  group('single consumption', () {
    test('a consumed token cannot be used again', () {
      final IssuedPairingToken issued = issuer.issue(
        sessionId: sessionId,
        tokenBytes: bytes(1),
      );

      expect(
        issuer
            .consume(
              source: source,
              sessionId: sessionId,
              pairToken: issued.token,
            )
            .isAccepted,
        isTrue,
      );
      final PairingAttempt second = issuer.consume(
        source: source,
        sessionId: sessionId,
        pairToken: issued.token,
      );
      expect(second.isAccepted, isFalse);
      expect(second.rejection, PairingRejection.unknownSession);
    });

    test('a lost response does not restore the token', () {
      // The token was consumed but the client never saw the answer. §3: do not restore it;
      // the QR is regenerated instead.
      final IssuedPairingToken issued = issuer.issue(
        sessionId: sessionId,
        tokenBytes: bytes(1),
      );
      issuer.consume(
        source: source,
        sessionId: sessionId,
        pairToken: issued.token,
      );

      expect(
        issuer
            .consume(
              source: source,
              sessionId: sessionId,
              pairToken: issued.token,
            )
            .isAccepted,
        isFalse,
        reason: 'there is no API that could put a consumed token back',
      );

      final IssuedPairingToken regenerated = issuer.issue(
        sessionId: sessionId,
        tokenBytes: bytes(4),
      );
      expect(
        issuer
            .consume(
              source: source,
              sessionId: sessionId,
              pairToken: regenerated.token,
            )
            .isAccepted,
        isTrue,
      );
    });

    test('a non-canonical spelling of the same bytes is not the token', () {
      final IssuedPairingToken issued = issuer.issue(
        sessionId: sessionId,
        tokenBytes: bytes(1),
      );
      final String mutated =
          '${issued.token.substring(0, issued.token.length - 1)}B';

      expect(mutated, isNot(issued.token));
      expect(
        issuer
            .consume(source: source, sessionId: sessionId, pairToken: mutated)
            .isAccepted,
        isFalse,
      );
    });
  });

  group('failures look the same to the peer', () {
    test('every rejection reason answers the same wire code', () {
      final IssuedPairingToken issued = issuer.issue(
        sessionId: sessionId,
        tokenBytes: bytes(1),
      );

      final List<PairingAttempt> rejections = <PairingAttempt>[
        // unknown session
        issuer.consume(
          source: source,
          sessionId: otherSession,
          pairToken: tokenText(1),
        ),
        // wrong token
        issuer.consume(
          source: source,
          sessionId: sessionId,
          pairToken: tokenText(99),
        ),
      ];
      // expired
      now += ProtocolLimits.pairTokenTtlSeconds * 1000;
      rejections.add(
        issuer.consume(
          source: source,
          sessionId: sessionId,
          pairToken: issued.token,
        ),
      );

      expect(
        rejections.map((PairingAttempt a) => a.wireCode).toSet(),
        <ProtocolErrorCode>{ProtocolErrorCode.pairRejected},
        reason:
            '§3 requires a uniform PAIR_REJECTED so that a caller cannot learn whether '
            'a token exists',
      );
      expect(
        rejections.map((PairingAttempt a) => a.rejection).toSet(),
        <PairingRejection>{
          PairingRejection.unknownSession,
          PairingRejection.wrongToken,
          PairingRejection.expired,
        },
        reason: 'the local reasons are still distinguishable for diagnostics',
      );
    });

    test('the local reason is never reachable from the wire code', () {
      expect(
        const PairingAttempt.rejected(PairingRejection.wrongToken).wireCode,
        ProtocolErrorCode.pairRejected,
      );
      expect(
        const PairingAttempt.rejected(PairingRejection.expired).wireCode,
        ProtocolErrorCode.pairRejected,
      );
      expect(
        const PairingAttempt.rejected(PairingRejection.unknownSession).wireCode,
        ProtocolErrorCode.pairRejected,
      );
    });

    test('the rate limit is the one distinguishable answer', () {
      expect(
        const PairingAttempt.rateLimited().wireCode,
        ProtocolErrorCode.rateLimited,
      );
      expect(const PairingAttempt.rateLimited().wireCode!.httpStatus, 429);
    });
  });

  group('rate limiting', () {
    test('the per-source limit refuses further attempts', () {
      for (
        int i = 0;
        i < PairingTokenIssuer.defaultPerSourceFailureLimit;
        i++
      ) {
        expect(
          issuer
              .consume(
                source: source,
                sessionId: otherSession,
                pairToken: tokenText(i),
              )
              .result,
          PairingAttemptResult.rejected,
        );
      }

      expect(issuer.isRateLimited(source), isTrue);
      expect(
        issuer
            .consume(
              source: source,
              sessionId: otherSession,
              pairToken: tokenText(0),
            )
            .result,
        PairingAttemptResult.rateLimited,
      );
    });

    test('a valid token is still refused while the source is limited', () {
      final IssuedPairingToken issued = issuer.issue(
        sessionId: sessionId,
        tokenBytes: bytes(1),
      );
      for (
        int i = 0;
        i < PairingTokenIssuer.defaultPerSourceFailureLimit;
        i++
      ) {
        issuer.consume(
          source: source,
          sessionId: otherSession,
          pairToken: tokenText(i),
        );
      }

      expect(
        issuer
            .consume(
              source: source,
              sessionId: sessionId,
              pairToken: issued.token,
            )
            .result,
        PairingAttemptResult.rateLimited,
        reason:
            'the limit is checked before the token is examined, so a limited caller '
            'learns nothing about the token it presented',
      );
    });

    test('the limit is per source', () {
      for (
        int i = 0;
        i < PairingTokenIssuer.defaultPerSourceFailureLimit;
        i++
      ) {
        issuer.consume(
          source: source,
          sessionId: otherSession,
          pairToken: tokenText(i),
        );
      }

      expect(issuer.isRateLimited(source), isTrue);
      expect(
        issuer.isRateLimited('192.168.43.11'),
        isFalse,
        reason: 'one noisy client must not lock out another',
      );
    });

    test('the global limit blocks a source that has no failures', () {
      for (int i = 0; i < PairingTokenIssuer.defaultGlobalFailureLimit; i++) {
        // Spread across sources so no single one reaches its own limit.
        issuer.consume(
          source: '192.168.43.${100 + (i ~/ 5)}',
          sessionId: otherSession,
          pairToken: tokenText(i),
        );
      }

      expect(
        issuer.isRateLimited('192.168.43.200'),
        isTrue,
        reason:
            '§3 also sets a global limit, so the total cannot be raised by rotating '
            'the apparent source',
      );
    });

    test('failures age out of the window', () {
      for (
        int i = 0;
        i < PairingTokenIssuer.defaultPerSourceFailureLimit;
        i++
      ) {
        issuer.consume(
          source: source,
          sessionId: otherSession,
          pairToken: tokenText(i),
        );
      }
      expect(issuer.isRateLimited(source), isTrue);

      now += PairingTokenIssuer.defaultFailureWindowMillis + 1;

      expect(
        issuer.isRateLimited(source),
        isFalse,
        reason: 'a rolling minute, so a client is not locked out permanently',
      );
    });

    test('it reports how long to wait, which is what Retry-After carries', () {
      expect(
        issuer.retryAfterSeconds(source),
        0,
        reason: 'an unlimited source has nothing to wait for',
      );

      // Spread the failures so the oldest one leaves the window sooner.
      for (
        int i = 0;
        i < PairingTokenIssuer.defaultPerSourceFailureLimit;
        i++
      ) {
        issuer.consume(
          source: source,
          sessionId: otherSession,
          pairToken: tokenText(i),
        );
        now += 10000;
      }
      now -= 10000;

      final int wait = issuer.retryAfterSeconds(source);
      expect(
        wait,
        greaterThan(0),
        reason: '§11 attaches Retry-After to a 429 and prescribes backing off by it',
      );
      expect(
        wait,
        lessThanOrEqualTo(
          PairingTokenIssuer.defaultFailureWindowMillis ~/ 1000,
        ),
      );

      // Waiting exactly that long must actually lift the limit, or the header lied.
      now += wait * 1000;
      expect(issuer.isRateLimited(source), isFalse);
    });

    test('the wait follows the oldest failure, not the window length', () {
      // Five failures in the same instant: the whole window is still ahead.
      for (
        int i = 0;
        i < PairingTokenIssuer.defaultPerSourceFailureLimit;
        i++
      ) {
        issuer.consume(
          source: source,
          sessionId: otherSession,
          pairToken: tokenText(i),
        );
      }
      final int fromStart = issuer.retryAfterSeconds(source);

      // Twenty seconds later the same five are twenty seconds closer to ageing out.
      now += 20000;
      final int later = issuer.retryAfterSeconds(source);

      expect(
        later,
        lessThan(fromStart),
        reason:
            'telling a client to wait a full minute when twenty seconds would do is its '
            'own kind of wrong',
      );
      expect(later, greaterThan(0));
    });

    test('a success does not clear the failure record', () {
      final IssuedPairingToken issued = issuer.issue(
        sessionId: sessionId,
        tokenBytes: bytes(1),
      );
      for (int i = 0; i < 4; i++) {
        issuer.consume(
          source: source,
          sessionId: otherSession,
          pairToken: tokenText(i),
        );
      }
      expect(
        issuer
            .consume(
              source: source,
              sessionId: sessionId,
              pairToken: issued.token,
            )
            .isAccepted,
        isTrue,
      );

      // One more failure reaches the limit: §3 counts failures in a window, and a
      // successful pair in between does not erase what was tried before it.
      issuer.consume(
        source: source,
        sessionId: otherSession,
        pairToken: tokenText(7),
      );
      expect(issuer.isRateLimited(source), isTrue);
    });
  });

  group('a restart', () {
    test('has no outstanding tokens', () {
      final IssuedPairingToken issued = issuer.issue(
        sessionId: sessionId,
        tokenBytes: bytes(1),
      );

      // A new process: nothing was persisted, so §3's "服务重启时未消费的配对令牌全部失效"
      // holds by construction rather than by an invalidation step that could be missed.
      final PairingTokenIssuer restarted = PairingTokenIssuer(clock: clock);

      final PairingAttempt attempt = restarted.consume(
        source: source,
        sessionId: sessionId,
        pairToken: issued.token,
      );
      expect(attempt.isAccepted, isFalse);
      expect(attempt.rejection, PairingRejection.unknownSession);
      expect(attempt.wireCode, ProtocolErrorCode.pairRejected);
    });
  });

  group('generating tokens', () {
    test('produces 32 bytes and does not repeat', () {
      final List<int> first = generatePairingTokenBytes();
      final List<int> second = generatePairingTokenBytes();

      expect(first, hasLength(ProtocolLimits.pairTokenBytes));
      expect(
        first,
        isNot(second),
        reason: '§3 requires 32 random bytes, and rate limiting does not replace entropy',
      );
    });

    test('the generated bytes produce a canonical 43 character token', () {
      final PairingTokenIssuer local = PairingTokenIssuer(clock: clock);
      final IssuedPairingToken issued = local.issue(
        sessionId: sessionId,
        tokenBytes: generatePairingTokenBytes(),
      );
      expect(issued.token, hasLength(ProtocolLimits.pairTokenChars));
      expect(
        decodeBase64UrlNoPaddingExact(
          issued.token,
          'pairToken',
          expectedBytes: ProtocolLimits.pairTokenBytes,
        ),
        hasLength(ProtocolLimits.pairTokenBytes),
      );
    });
  });
}
