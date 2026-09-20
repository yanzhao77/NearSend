import 'package:flutter_test/flutter_test.dart';

import 'package:nearsend/core/security/credential_fingerprint.dart';

/// §9's idempotency scope has to vary with the credential while the credential itself must
/// never be stored (`AGENTS.md` §5). A fingerprint is what resolves those two, so what
/// matters is that it really does distinguish credentials and really is not the credential.
void main() {
  const String tokenA = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
  const String tokenB = 'BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB';

  group('the fingerprint', () {
    test('has the shape of every other protocol digest', () {
      final String value = credentialFingerprint(tokenA);
      expect(value.length, 64);
      expect(RegExp(r'^[0-9a-f]{64}$').hasMatch(value), isTrue);
    });

    test('is deterministic', () {
      expect(credentialFingerprint(tokenA), credentialFingerprint(tokenA));
    });

    test('distinguishes credentials that differ by one character', () {
      expect(
        credentialFingerprint(tokenA),
        isNot(credentialFingerprint(tokenB)),
        reason:
            'a re-pairing issues a new credential, and a request id from before it must not '
            'silently match one made after it',
      );
      expect(
        credentialFingerprint(tokenA),
        isNot(credentialFingerprint('${tokenA.substring(0, 42)}B')),
      );
    });

    test('does not contain the credential', () {
      final String value = credentialFingerprint(tokenA);
      expect(value, isNot(contains('AAAA')));
    });

    test('refuses an empty credential', () {
      expect(
        () => credentialFingerprint(''),
        throwsArgumentError,
        reason: 'an empty credential would give every unauthenticated caller one scope',
      );
    });
  });

  group('recognising one', () {
    test('accepts what the function produces', () {
      expect(
        looksLikeCredentialFingerprint(credentialFingerprint(tokenA)),
        isTrue,
      );
    });

    test('rejects anything else', () {
      for (final String value in <String>[
        tokenA,
        credentialFingerprint(tokenA).toUpperCase(),
        credentialFingerprint(tokenA).substring(0, 63),
        '${credentialFingerprint(tokenA)}0',
        'z' * 64,
        '',
      ]) {
        expect(
          looksLikeCredentialFingerprint(value),
          isFalse,
          reason: '"$value" was not produced by this code',
        );
      }
    });
  });
}
