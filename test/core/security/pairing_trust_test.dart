import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nearsend/core/protocol/base64url.dart';
import 'package:nearsend/core/protocol/protocol_exception.dart';
import 'package:nearsend/core/protocol/protocol_validation.dart';
import 'package:nearsend/core/security/pairing_payload.dart';
import 'package:nearsend/core/security/pairing_trust.dart';

/// Comparing the server's identity before releasing a credential.
///
/// §2 requires the fingerprint comparison to happen before the pairing token is sent.
/// Most of these tests exist to show that the requirement is not merely documented: the
/// token is unreachable until the comparison has succeeded, and a failed comparison makes
/// it unreachable permanently.
void main() {
  /// Stands in for a leaf certificate's DER. Nothing here parses X.509 - §2 digests the
  /// encoding, and the TLS layer is what obtains it.
  final Uint8List leafDer = Uint8List.fromList(<int>[
    0x30,
    0x82,
    0x01,
    0x0a,
    0x02,
    0x82,
    0x01,
    0x01,
    0x00,
    0xc4,
    0x7d,
    0x11,
  ]);
  final Uint8List otherDer = Uint8List.fromList(<int>[
    0x30,
    0x82,
    0x01,
    0x0a,
    0x02,
    0x82,
    0x01,
    0x01,
    0x00,
    0xc4,
    0x7d,
    0x12,
  ]);

  PairingPayload payloadFor(List<int> der, {String? sessionId}) =>
      PairingPayload(
        serverFingerprint: serverFingerprintOf(der),
        sessionId: sessionId ?? '3f2504e0-4f89-41d3-9a0c-0305e82c3301',
        candidates: const <PairingCandidate>[
          PairingCandidate(host: '192.168.43.1', port: 8443),
        ],
        pairToken: encodeBase64UrlNoPadding(
          Uint8List.fromList(List<int>.generate(32, (i) => i)),
        ),
        expiresInSeconds: 300,
      );

  Matcher refusedWith(Matcher reason) => throwsA(
    isA<ProtocolViolation>()
        .having(
          (ProtocolViolation e) => e.code.wireCode,
          'wireCode',
          'PAIR_REJECTED',
        )
        .having((ProtocolViolation e) => e.detail, 'detail', reason),
  );

  group('what the fingerprint is', () {
    test('it is the SHA-256 of the DER', () {
      expect(
        serverFingerprintOf(leafDer),
        bytesToSha256Hex(sha256.convert(leafDer).bytes),
      );
      expect(serverFingerprintOf(leafDer), hasLength(64));
      expect(serverFingerprintOf(leafDer), matches(RegExp(r'^[0-9a-f]{64}$')));
    });

    test('it is not the digest of the PEM text', () {
      // The mistake this guards against is a plausible-looking pin that simply never
      // matches, or that matches something other than the certificate.
      final String pem =
          '-----BEGIN CERTIFICATE-----\n${base64.encode(leafDer)}\n'
          '-----END CERTIFICATE-----\n';
      final String pemDigest = bytesToSha256Hex(
        sha256.convert(utf8.encode(pem)).bytes,
      );

      expect(
        serverFingerprintOf(leafDer),
        isNot(pemDigest),
        reason:
            '§2 defines the pin over the DER, and a PEM-text digest is a different value '
            'of the same shape',
      );
    });

    test('it covers the whole encoding, not a part of it', () {
      // Standing in for an SPKI-only digest: a digest over a slice of the certificate is
      // not the digest over the certificate.
      final List<int> slice = leafDer.sublist(4);
      expect(
        serverFingerprintOf(slice),
        isNot(serverFingerprintOf(leafDer)),
        reason: 'a digest over part of the DER is not the pin §2 defines',
      );
    });

    test('an empty encoding is refused rather than hashed', () {
      expect(
        () => serverFingerprintOf(<int>[]),
        throwsA(isA<ProtocolViolation>()),
      );
    });
  });

  group('the token is unreachable until the comparison happens', () {
    test('reading it before verifying is refused', () {
      final PairingHandshake handshake = PairingHandshake(
        payload: payloadFor(leafDer),
      );

      expect(handshake.isVerified, isFalse);
      expect(handshake.mayReleaseCredentials, isFalse);
      expect(
        () => handshake.pairingToken,
        refusedWith(contains('must not be sent before that comparison')),
      );
    });

    test('it becomes available after a match', () {
      final PairingPayload payload = payloadFor(leafDer);
      final PairingHandshake handshake = PairingHandshake(payload: payload);

      expect(
        handshake.verifyServerCertificate(leafDer),
        PairingCertificateVerdict.trusted,
      );
      expect(handshake.isVerified, isTrue);
      expect(handshake.mayReleaseCredentials, isTrue);
      expect(handshake.pairingToken, payload.pairToken);
    });

    test('the token it returns is the canonical spelling the body carries', () {
      final PairingPayload payload = payloadFor(leafDer);
      final PairingHandshake handshake = PairingHandshake(payload: payload)
        ..verifyServerCertificate(leafDer);

      expect(handshake.pairingToken, hasLength(43));
      expect(
        encodeBase64UrlNoPadding(payload.pairTokenBytes),
        handshake.pairingToken,
      );
    });
  });

  group('a mismatch is terminal for the connection', () {
    test('it is reported and closes the context', () {
      final PairingHandshake handshake = PairingHandshake(
        payload: payloadFor(leafDer),
      );

      expect(
        handshake.verifyServerCertificate(otherDer),
        PairingCertificateVerdict.fingerprintMismatch,
      );
      expect(handshake.isVerified, isFalse);
      expect(handshake.isClosed, isTrue);
      expect(handshake.mayReleaseCredentials, isFalse);
    });

    test('the token stays unreachable afterwards', () {
      final PairingHandshake handshake = PairingHandshake(
        payload: payloadFor(leafDer),
      )..verifyServerCertificate(otherDer);

      expect(() => handshake.pairingToken, refusedWith(contains('closed')));
    });

    test('the connection cannot be renegotiated on the same context', () {
      final PairingHandshake handshake = PairingHandshake(
        payload: payloadFor(leafDer),
      )..verifyServerCertificate(otherDer);

      expect(
        () => handshake.verifyServerCertificate(leafDer),
        refusedWith(contains('closed')),
        reason:
            'retrying the comparison on a connection whose peer already failed its '
            'identity check is how a retry loop becomes an attack; §2 closes instead',
      );
      expect(handshake.mayReleaseCredentials, isFalse);
    });

    test('a mismatch on one connection does not leak into another', () {
      final PairingPayload payload = payloadFor(leafDer);
      final PairingHandshake first = PairingHandshake(payload: payload)
        ..verifyServerCertificate(otherDer);
      final PairingHandshake second = PairingHandshake(payload: payload);

      expect(first.isClosed, isTrue);
      expect(
        second.isVerified,
        isFalse,
        reason: '§2 requires a per-connection trust context',
      );
      expect(
        second.verifyServerCertificate(leafDer),
        PairingCertificateVerdict.trusted,
      );
      expect(second.pairingToken, payload.pairToken);
    });
  });

  group('abandoning', () {
    test('closes the context and hides the token', () {
      final PairingHandshake handshake = PairingHandshake(
        payload: payloadFor(leafDer),
      )..verifyServerCertificate(leafDer);
      expect(handshake.mayReleaseCredentials, isTrue);

      handshake.abandon();

      expect(handshake.isClosed, isTrue);
      expect(handshake.isVerified, isFalse);
      expect(() => handshake.pairingToken, refusedWith(contains('closed')));
    });

    test('abandoning before verifying also hides the token', () {
      final PairingHandshake handshake = PairingHandshake(
        payload: payloadFor(leafDer),
      )..abandon();

      expect(() => handshake.pairingToken, refusedWith(contains('closed')));
    });
  });

  group('comparison details', () {
    test('a directly built payload with an uppercase pin still matches', () {
      // The parser rejects an uppercase fingerprint, so this can only arise from a
      // directly constructed payload. The comparison normalises anyway rather than
      // depending on every construction path being canonical.
      final PairingPayload payload = PairingPayload(
        serverFingerprint: serverFingerprintOf(leafDer).toUpperCase(),
        sessionId: '3f2504e0-4f89-41d3-9a0c-0305e82c3301',
        candidates: const <PairingCandidate>[
          PairingCandidate(host: '192.168.43.1', port: 8443),
        ],
        pairToken: encodeBase64UrlNoPadding(Uint8List(32)),
        expiresInSeconds: 300,
      );

      expect(
        PairingHandshake(payload: payload).verifyServerCertificate(leafDer),
        PairingCertificateVerdict.trusted,
      );
    });

    test('a one byte difference is still a mismatch', () {
      final Uint8List almostTheSame = Uint8List.fromList(leafDer);
      almostTheSame[almostTheSame.length - 1] ^= 0x01;

      expect(
        PairingHandshake(payload: payloadFor(leafDer))
            .verifyServerCertificate(almostTheSame),
        PairingCertificateVerdict.fingerprintMismatch,
      );
    });

    test(
      'an unusable certificate closes the context rather than comparing',
      () {
        final PairingHandshake handshake = PairingHandshake(
          payload: payloadFor(leafDer),
        );
        expect(
          () => handshake.verifyServerCertificate(<int>[]),
          throwsA(isA<ProtocolViolation>()),
        );
        expect(
          handshake.isClosed,
          isTrue,
          reason:
              'the invariant is "closed unless the comparison returned trusted": a '
              'certificate the TLS layer could not produce is still a peer whose identity '
              'was not established',
        );
        expect(handshake.isVerified, isFalse);
        expect(handshake.mayReleaseCredentials, isFalse);
        expect(() => handshake.pairingToken, refusedWith(contains('closed')));
      },
    );
  });
}
