import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:nearsend/core/protocol/base64url.dart';
import 'package:nearsend/core/protocol/protocol_exception.dart';
import 'package:nearsend/core/protocol/protocol_limits.dart';
import 'package:nearsend/core/protocol/protocol_version.dart';
import 'package:nearsend/core/security/pair_request.dart';

/// The `POST /v1/pair` body (§3, §4).
///
/// Synthetic capability identifiers are used throughout, on purpose: the draft writes
/// `capabilities:[...]` without enumerating anything, and `AGENTS.md` §3 forbids settling
/// that by preference, so the tests exercise the algorithm without inventing a vocabulary.
void main() {
  const String requestId = '3f2504e0-4f89-41d3-9a0c-0305e82c3301';
  const String sessionId = '9c858901-8a57-4791-81fe-4c455b099bc9';
  final String pairToken = encodeBase64UrlNoPadding(
    Uint8List.fromList(List<int>.generate(32, (int i) => i)),
  );
  final String accessToken = encodeBase64UrlNoPadding(
    Uint8List.fromList(List<int>.generate(32, (int i) => 255 - i)),
  );

  Map<String, Object?> request({
    Object? requestIdValue = requestId,
    Object? sessionIdValue = sessionId,
    Object? pairTokenValue,
    Object? clientLabel = 'Pixel 7',
    Object? protocolMajor = 1,
    Object? protocolMinor = 0,
  }) => <String, Object?>{
    'requestId': requestIdValue,
    'sessionId': sessionIdValue,
    'pairToken': pairTokenValue ?? pairToken,
    'clientLabel': clientLabel,
    'protocolMajor': protocolMajor,
    'protocolMinor': protocolMinor,
  };

  Map<String, Object?> response({
    Object? token,
    Object? expires = 1800,
    Object? capabilities,
    Object? protocolMajor = 1,
    Object? protocolMinor = 0,
  }) => <String, Object?>{
    'sessionAccessToken': token ?? accessToken,
    'expiresInSeconds': expires,
    'protocolMajor': protocolMajor,
    'protocolMinor': protocolMinor,
    'capabilities': capabilities ?? <Object?>['x-synthetic-a', 'x-synthetic-b'],
  };

  Matcher refuses = throwsA(isA<ProtocolViolation>());

  group('a well formed request', () {
    test('parses every field', () {
      final PairRequest parsed = PairRequest.parse(request());

      expect(parsed.requestId, requestId);
      expect(parsed.sessionId, sessionId);
      expect(parsed.pairToken, pairToken);
      expect(parsed.clientLabel, 'Pixel 7');
      expect(parsed.protocolMajor, 1);
      expect(parsed.protocolMinor, 0);
    });

    test('survives a round trip', () {
      final PairRequest first = PairRequest.parse(request());
      final PairRequest second = PairRequest.parse(first.toJson());

      expect(second.requestId, first.requestId);
      expect(second.pairToken, first.pairToken);
      expect(second.clientLabel, first.clientLabel);
    });

    test('its text form never carries the token', () {
      final String rendered = PairRequest.parse(request()).toString();

      expect(
        rendered,
        isNot(contains(pairToken)),
        reason: 'a request body reaches logs and crash reports',
      );
      expect(rendered, contains('Pixel 7'));
    });
  });

  group('§4 rejects undefined and missing fields', () {
    test('an extra field is refused', () {
      final Map<String, Object?> json = request()..['extra'] = 'x';
      expect(() => PairRequest.parse(json), refuses);
    });

    test('a missing field is refused', () {
      final Map<String, Object?> json = request()..remove('clientLabel');
      expect(() => PairRequest.parse(json), refuses);
    });

    test('a missing token is refused', () {
      final Map<String, Object?> json = request()..remove('pairToken');
      expect(() => PairRequest.parse(json), refuses);
    });
  });

  group('identifiers', () {
    test('an uppercase request id is refused', () {
      expect(
        () =>
            PairRequest.parse(request(requestIdValue: requestId.toUpperCase())),
        refuses,
      );
    });

    test('a request id without hyphens is refused', () {
      expect(
        () => PairRequest.parse(
          request(requestIdValue: requestId.replaceAll('-', '')),
        ),
        refuses,
      );
    });

    test('a session id that is not a UUID is refused', () {
      expect(
        () => PairRequest.parse(request(sessionIdValue: 'session-1')),
        refuses,
      );
    });
  });

  group('the token', () {
    test('a padded one is refused', () {
      expect(
        () => PairRequest.parse(request(pairTokenValue: '$pairToken=')),
        refuses,
      );
    });

    test('one of the wrong length is refused', () {
      expect(
        () => PairRequest.parse(
          request(pairTokenValue: encodeBase64UrlNoPadding(Uint8List(16))),
        ),
        refuses,
      );
    });

    test('a non-canonical spelling is refused', () {
      final String mutated = '${pairToken.substring(0, pairToken.length - 1)}B';
      expect(
        () => PairRequest.parse(request(pairTokenValue: mutated)),
        refuses,
      );
    });

    test('a value that is not a string is refused', () {
      expect(() => PairRequest.parse(request(pairTokenValue: 12345)), refuses);
    });
  });

  group('the client label', () {
    test('is bounded at 128 UTF-8 bytes, not 128 characters', () {
      // 'é' is two bytes in UTF-8, so 64 of them fill the limit exactly.
      final String exactlyAtLimit = 'é' * 64;
      expect(
        PairRequest.parse(request(clientLabel: exactlyAtLimit)).clientLabel,
        exactlyAtLimit,
      );

      expect(
        () => PairRequest.parse(request(clientLabel: 'é' * 65)),
        refuses,
        reason:
            'a character count would let a multi-byte label exceed the byte limit §3 '
            'actually sets',
      );
    });

    test('an empty one is refused', () {
      expect(() => PairRequest.parse(request(clientLabel: '')), refuses);
    });

    test('one with a control character is refused', () {
      expect(
        () => PairRequest.parse(request(clientLabel: 'Pixel\u00007')),
        refuses,
      );
    });

    test('one that is not a string is refused', () {
      expect(() => PairRequest.parse(request(clientLabel: 7)), refuses);
    });

    test('a long one is refused before it can be displayed', () {
      expect(() => PairRequest.parse(request(clientLabel: 'x' * 129)), refuses);
    });
  });

  group('the version', () {
    test('a string version is refused', () {
      expect(() => PairRequest.parse(request(protocolMajor: '1')), refuses);
    });

    test('a boolean version is refused', () {
      expect(() => PairRequest.parse(request(protocolMinor: false)), refuses);
    });

    test('a negative version is refused', () {
      expect(() => PairRequest.parse(request(protocolMinor: -1)), refuses);
    });
  });

  group('a well formed response', () {
    test('parses every field', () {
      final PairResponse parsed = PairResponse.parse(response());

      expect(parsed.sessionAccessToken, accessToken);
      expect(parsed.expiresInSeconds, 1800);
      expect(parsed.protocolMajor, 1);
      expect(parsed.protocolMinor, 0);
      expect(parsed.capabilities.ids, <String>{
        'x-synthetic-a',
        'x-synthetic-b',
      });
    });

    test('survives a round trip', () {
      final PairResponse first = PairResponse.parse(response());
      final PairResponse second = PairResponse.parse(first.toJson());

      expect(second.sessionAccessToken, first.sessionAccessToken);
      expect(second.capabilities.ids, first.capabilities.ids);
      expect(second.expiresInSeconds, first.expiresInSeconds);
    });

    test('its text form never carries the access token', () {
      expect(
        PairResponse.parse(response()).toString(),
        isNot(contains(accessToken)),
      );
    });

    test('the default expiry is the value §3 fixes', () {
      expect(
        PairResponse(
          sessionAccessToken: accessToken,
          capabilities: CapabilitySet(const <Capability>[]),
        ).expiresInSeconds,
        ProtocolLimits.sessionAccessTokenTtlSeconds,
      );
    });
  });

  group('response validation', () {
    test('an access token of the wrong length is refused', () {
      expect(
        () => PairResponse.parse(
          response(token: encodeBase64UrlNoPadding(Uint8List(16))),
        ),
        refuses,
      );
    });

    test('a padded access token is refused', () {
      expect(
        () => PairResponse.parse(response(token: '$accessToken=')),
        refuses,
      );
    });

    test('a zero expiry is refused', () {
      expect(() => PairResponse.parse(response(expires: 0)), refuses);
    });

    test('a non-array capabilities field is refused', () {
      expect(
        () => PairResponse.parse(response(capabilities: 'x-synthetic-a')),
        refuses,
      );
    });

    test('a duplicated capability is refused', () {
      expect(
        () =>
            PairResponse.parse(response(capabilities: <Object?>['x-a', 'x-a'])),
        refuses,
        reason:
            '§4 rejects input that does not match the specification rather than '
            'silently normalising it',
      );
    });

    test('a capability with a space is refused', () {
      expect(
        () => PairResponse.parse(response(capabilities: <Object?>['x a'])),
        refuses,
      );
    });

    test('an empty capability is refused', () {
      expect(
        () => PairResponse.parse(response(capabilities: <Object?>[''])),
        refuses,
      );
    });

    test('an empty capability list is accepted', () {
      expect(
        PairResponse.parse(response(capabilities: <Object?>[]))
            .capabilities
            .isEmpty,
        isTrue,
        reason:
            'the vocabulary is undefined, so an empty list is a legitimate answer and '
            'not something this layer may reject',
      );
    });

    test('an extra field is refused', () {
      final Map<String, Object?> json = response()
        ..['serverFingerprint'] = 'a' * 64;
      expect(() => PairResponse.parse(json), refuses);
    });
  });

  group('the capability vocabulary is not invented here', () {
    test('arbitrary identifiers round trip unchanged', () {
      final List<String> synthetic = <String>[
        'x-alpha',
        'x-beta-2',
        'X-UPPER',
        'x.with.dots',
      ];
      final PairResponse parsed = PairResponse.parse(
        response(capabilities: synthetic),
      );

      expect(parsed.capabilities.toJson(), synthetic..sort());
    });

    test(
      'a capability identifier is bounded but not otherwise constrained',
      () {
        // 64 printable ASCII bytes is the documented bound; nothing narrower is imposed
        // because the draft defines no grammar.
        final String atBound = 'x${'a' * 63}';
        expect(
          PairResponse.parse(response(capabilities: <Object?>[atBound]))
              .capabilities
              .toJson(),
          <String>[atBound],
        );
        expect(
          () => PairResponse.parse(
            response(capabilities: <Object?>['x${'a' * 64}']),
          ),
          refuses,
        );
      },
    );
  });
}
