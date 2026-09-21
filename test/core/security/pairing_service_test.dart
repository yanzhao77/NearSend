/// Tests for [PairingService]: §3's two credentials and the rules between them.
///
/// The class issues a one-time pairing token (300 seconds, monotonic) and, on a successful
/// `POST /v1/pair`, a session access token (1800 seconds). The properties worth pinning are
/// the ones where a mistake stays invisible against an honest client: that a rejection cannot
/// be used to probe for a session, that a rate limit is applied before the token is examined,
/// and that a re-issued QR stops the previous access token from working.
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:nearsend/core/network/control_authorization.dart';
import 'package:nearsend/core/network/control_message.dart';
import 'package:nearsend/core/protocol/base64url.dart';
import 'package:nearsend/core/protocol/protocol_exception.dart';
import 'package:nearsend/core/protocol/protocol_limits.dart';
import 'package:nearsend/core/protocol/protocol_validation.dart';
import 'package:nearsend/core/security/pair_request.dart';
import 'package:nearsend/core/security/pairing_payload.dart';
import 'package:nearsend/core/security/pairing_service.dart';

void main() {
  const String pin =
      'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

  late int now;
  late PairingService service;

  setUp(() {
    now = 0;
    service = PairingService(
      serverFingerprint: pin,
      candidates: const <PairingCandidate>[
        PairingCandidate(host: '192.168.10.100', port: 8443),
      ],
      clock: () => now,
    );
  });

  PairRequest requestFor(PairingPayload payload, {String? token}) =>
      PairRequest(
        requestId: randomUuidV4(),
        sessionId: payload.sessionId,
        pairToken: token ?? payload.pairToken,
        clientLabel: 'test client',
      );

  _PairResult pairIt(PairRequest request, {String source = 'peer-a'}) =>
      _PairResult(service.pair(request: request, source: source));

  String sessionTokenFrom(_PairResult result) =>
      PairResponse.parse(result.body).sessionAccessToken;

  group('opening a session', () {
    test('the QR payload names this server and survives its own parser', () {
      final PairingPayload payload = service.openSession();

      expect(payload.serverFingerprint, pin);
      expect(payload.expiresInSeconds, ProtocolLimits.pairTokenTtlSeconds);
      expect(payload.candidates.single.host, '192.168.10.100');

      // Round-tripped through the strict parser: a payload this build could not read back is
      // a payload no client could read either.
      final PairingPayload reparsed = PairingPayload.parse(
        jsonEncode(payload.toJson()),
      );
      expect(reparsed.sessionId, payload.sessionId);
      expect(reparsed.pairToken, payload.pairToken);
    });

    test('session ids are canonical version 4 UUIDs', () {
      for (int i = 0; i < 50; i++) {
        final String id = randomUuidV4();
        // §4's canonical form; the validator refuses anything else, which is the point.
        expect(() => uuidToBytes(id, 'sessionId'), returnsNormally);
        expect(id[14], '4', reason: 'the version nibble');
        expect('89ab'.contains(id[19]), isTrue, reason: 'the RFC 4122 variant');
      }
    });

    test('two sessions never share an id or a token', () {
      final PairingPayload a = service.openSession();
      final PairingPayload b = service.openSession();
      expect(a.sessionId, isNot(b.sessionId));
      expect(a.pairToken, isNot(b.pairToken));
    });
  });

  group('POST /v1/pair', () {
    test('a correct token yields a session access token', () {
      final PairingPayload payload = service.openSession();
      final _PairResult result = pairIt(requestFor(payload));

      expect(result.status, 200);
      final PairResponse parsed = PairResponse.parse(result.body);
      expect(parsed.protocolMajor, ProtocolLimits.protocolMajor);
      expect(
        parsed.expiresInSeconds,
        ProtocolLimits.sessionAccessTokenTtlSeconds,
      );

      // The token is a real 32-byte credential, and it is what the authenticator accepts.
      expect(
        () => decodeBase64UrlNoPaddingExact(
          parsed.sessionAccessToken,
          'sessionAccessToken',
          expectedBytes: ProtocolLimits.accessTokenBytes,
        ),
        returnsNormally,
      );
      expect(
        service.authenticate(token: parsed.sessionAccessToken, nowMillis: 0),
        isA<SessionGrant>(),
      );
    });

    test('an unknown session and a wrong token are the same answer', () {
      final PairingPayload payload = service.openSession();

      final _PairResult wrongToken = pairIt(
        requestFor(payload, token: encodeBase64UrlNoPadding(_bytes(0x22))),
      );
      final _PairResult unknownSession = pairIt(
        PairRequest(
          requestId: randomUuidV4(),
          sessionId: randomUuidV4(),
          pairToken: payload.pairToken,
          clientLabel: 'test client',
        ),
      );

      expect(wrongToken.status, 401);
      expect(wrongToken.errorCode, ProtocolErrorCode.pairRejected);
      expect(unknownSession.status, 401);
      expect(
        unknownSession.errorCode,
        wrongToken.errorCode,
        reason: 'a finer answer would let a caller probe for a session',
      );
    });

    test('a pairing token is consumed once', () {
      final PairingPayload payload = service.openSession();
      expect(pairIt(requestFor(payload)).status, 200);

      final _PairResult second = pairIt(requestFor(payload));
      expect(second.status, 401);
      expect(second.errorCode, ProtocolErrorCode.pairRejected);
    });

    test('a token stops working after its window, judged monotonically', () {
      final PairingPayload payload = service.openSession();
      now = ProtocolLimits.pairTokenTtlSeconds * 1000 + 1;

      expect(pairIt(requestFor(payload)).status, 401);
    });

    test('the rate limit is applied before the token is examined', () {
      final PairingPayload payload = service.openSession();

      // Five failures exhaust §3's per-source allowance.
      for (int i = 0; i < 5; i++) {
        pairIt(
          requestFor(payload, token: encodeBase64UrlNoPadding(_bytes(0x22))),
        );
      }

      // The next attempt presents the *correct* token. It must still be refused: otherwise a
      // caller could tell a valid token from an invalid one by which error it gets.
      final _PairResult limited = pairIt(requestFor(payload));
      expect(limited.status, 429);
      expect(limited.errorCode, ProtocolErrorCode.rateLimited);
      expect(
        limited.retryAfterSeconds,
        greaterThan(0),
        reason: '§11 attaches Retry-After to a 429',
      );

      // Another source is unaffected, so the limit is per source rather than global-only.
      expect(pairIt(requestFor(payload), source: 'peer-b').status, 200);
    });
  });

  group('session access tokens', () {
    test('a re-issued QR stops the previous access token', () {
      final PairingPayload first = service.openSession();
      final String firstToken = sessionTokenFrom(pairIt(requestFor(first)));

      // §3: a lost pairing response means a new QR, and the old code must not still pair.
      final PairingPayload second = service.openSession(
        sessionId: first.sessionId,
      );
      final String secondToken = sessionTokenFrom(pairIt(requestFor(second)));

      expect(
        service.authenticate(token: firstToken, nowMillis: 0),
        isNull,
        reason: 'the superseded token must not survive the new QR',
      );
      expect(
        service.authenticate(token: secondToken, nowMillis: 0),
        isA<SessionGrant>(),
      );
    });

    test('a session token expires on the monotonic clock', () {
      final PairingPayload payload = service.openSession();
      final String token = sessionTokenFrom(pairIt(requestFor(payload)));

      now = ProtocolLimits.sessionAccessTokenTtlSeconds * 1000 + 1;
      expect(service.authenticate(token: token, nowMillis: now), isNull);
    });

    test('an unknown token is rejected', () {
      expect(
        service.authenticate(
          token: encodeBase64UrlNoPadding(_bytes(0x33)),
          nowMillis: 0,
        ),
        isNull,
      );
    });
  });
}

/// The parts of a [ControlResponse] these tests assert on.
class _PairResult {
  _PairResult(this.response);

  final ControlResponse response;

  int get status => response.status;

  Map<String, Object?> get body => response.decodeJsonBody();

  ProtocolErrorCode? get errorCode =>
      status >= 400 ? response.decodeError().code : null;

  int get retryAfterSeconds =>
      int.parse(response.headers['retry-after'] ?? '0');
}

List<int> _bytes(int fill) => List<int>.filled(32, fill);
