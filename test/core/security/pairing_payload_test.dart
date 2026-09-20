import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:nearsend/core/protocol/base64url.dart';
import 'package:nearsend/core/protocol/protocol_exception.dart';
import 'package:nearsend/core/protocol/protocol_limits.dart';
import 'package:nearsend/core/security/pairing_payload.dart';

/// Parsing the pairing QR code.
///
/// Almost every test here is a negative one. The payload is the first thing a client reads
/// from an untrusted source, and it decides where to connect and what identity to trust, so
/// the interesting behaviour is what it refuses - `AGENTS.md` §7 requires the security
/// negatives, not just the happy path.
void main() {
  final String goodFingerprint = 'a' * 64;
  const String goodSessionId = '3f2504e0-4f89-41d3-9a0c-0305e82c3301';
  final String goodToken = encodeBase64UrlNoPadding(Uint8List(32));

  List<Map<String, Object?>> candidates([int count = 1]) =>
      <Map<String, Object?>>[
        for (int i = 0; i < count; i++)
          <String, Object?>{'host': '192.168.43.${10 + i}', 'port': 8443},
      ];

  String qr({
    Object? kind = pairingKind,
    Object? protocolMajor = 1,
    Object? protocolMinor = 0,
    Object? serverFingerprint,
    Object? sessionId = goodSessionId,
    Object? candidateList,
    Object? pairToken,
    Object? expiresInSeconds = 300,
  }) => jsonEncode(<String, Object?>{
    'kind': kind,
    'protocolMajor': protocolMajor,
    'protocolMinor': protocolMinor,
    'serverFingerprint': serverFingerprint ?? goodFingerprint,
    'sessionId': sessionId,
    'candidates': candidateList ?? candidates(),
    'pairToken': pairToken ?? goodToken,
    'expiresInSeconds': expiresInSeconds,
  });

  Matcher refuses = throwsA(isA<ProtocolViolation>());

  group('a well formed payload', () {
    test('is accepted and exposes every field', () {
      final PairingPayload payload = PairingPayload.parse(qr());

      expect(payload.protocolMajor, 1);
      expect(payload.protocolMinor, 0);
      expect(payload.serverFingerprint, goodFingerprint);
      expect(payload.sessionId, goodSessionId);
      expect(payload.pairToken, goodToken);
      expect(payload.expiresInSeconds, 300);
      expect(payload.candidates, hasLength(1));
      expect(payload.candidates.single.host, '192.168.43.10');
      expect(payload.candidates.single.port, 8443);
    });

    test('survives a round trip through the encoder', () {
      final PairingPayload first = PairingPayload.parse(
        qr(candidateList: candidates(3)),
      );
      final PairingPayload second = PairingPayload.parse(first.encode());

      expect(second.serverFingerprint, first.serverFingerprint);
      expect(second.sessionId, first.sessionId);
      expect(second.pairToken, first.pairToken);
      expect(second.candidates, first.candidates);
    });

    test('the token decodes to exactly 32 bytes', () {
      final PairingPayload payload = PairingPayload.parse(qr());
      expect(payload.pairTokenBytes, hasLength(ProtocolLimits.pairTokenBytes));
      expect(payload.pairToken, hasLength(ProtocolLimits.pairTokenChars));
      expect(
        encodeBase64UrlNoPadding(payload.pairTokenBytes),
        payload.pairToken,
        reason: 'the payload must carry the canonical spelling',
      );
    });

    test('candidate order is preserved', () {
      final PairingPayload payload = PairingPayload.parse(
        qr(
          candidateList: <Map<String, Object?>>[
            <String, Object?>{'host': '10.0.0.2', 'port': 5001},
            <String, Object?>{'host': '10.0.0.1', 'port': 5000},
          ],
        ),
      );
      expect(
        payload.candidates.map((PairingCandidate c) => c.host).toList(),
        <String>['10.0.0.2', '10.0.0.1'],
        reason: 'the issuer orders the candidates and the client tries them in order',
      );
    });

    test('an IPv6 candidate with a zone is accepted', () {
      final PairingPayload payload = PairingPayload.parse(
        qr(
          candidateList: <Map<String, Object?>>[
            <String, Object?>{'host': 'fe80::1%wlan0', 'port': 8443},
          ],
        ),
      );
      expect(payload.candidates.single.host, 'fe80::1%wlan0');
    });

    test('eight candidates are allowed', () {
      expect(
        PairingPayload.parse(qr(candidateList: candidates(8))).candidates,
        hasLength(ProtocolLimits.pairingCandidatesMax),
      );
    });
  });

  group('size', () {
    test('an oversized payload is refused before it is parsed', () {
      // The extra field is not a defined one, so if the size check came second this would
      // fail as an unknown field instead of as an oversized payload.
      final String huge = jsonEncode(<String, Object?>{
        'kind': pairingKind,
        'padding': 'x' * (ProtocolLimits.pairingQrMaxBytes + 1),
      });

      expect(
        () => PairingPayload.parse(huge),
        throwsA(
          isA<ProtocolViolation>().having(
            (ProtocolViolation e) => e.detail,
            'detail',
            contains('byte limit'),
          ),
        ),
      );
    });
  });

  group('§4 rejects undefined fields', () {
    test('an extra top level field is refused', () {
      final Map<String, Object?> json =
          jsonDecode(qr()) as Map<String, Object?>;
      json['extra'] = 'x';
      expect(() => PairingPayload.parse(jsonEncode(json)), refuses);
    });

    test('an extra candidate field is refused', () {
      expect(
        () => PairingPayload.parse(
          qr(
            candidateList: <Map<String, Object?>>[
              <String, Object?>{'host': '10.0.0.1', 'port': 8443, 'path': '/x'},
            ],
          ),
        ),
        refuses,
      );
    });
  });

  group('kind and version', () {
    test('a payload that is not a pairing payload is refused', () {
      expect(() => PairingPayload.parse(qr(kind: 'lft-transfer')), refuses);
    });

    test('a missing kind is refused', () {
      final Map<String, Object?> json =
          jsonDecode(qr()) as Map<String, Object?>;
      json.remove('kind');
      expect(() => PairingPayload.parse(jsonEncode(json)), refuses);
    });

    test('a version sent as a string is refused', () {
      expect(() => PairingPayload.parse(qr(protocolMajor: '1')), refuses);
    });

    test('a version sent as a boolean is refused', () {
      expect(
        () => PairingPayload.parse(qr(protocolMajor: true)),
        refuses,
        reason: 'in JSON-derived maps a bool is not an int, and §4 says so explicitly',
      );
    });

    test('a negative minor version is refused', () {
      expect(() => PairingPayload.parse(qr(protocolMinor: -1)), refuses);
    });
  });

  group('the fingerprint', () {
    test('one that is too short is refused', () {
      expect(
        () => PairingPayload.parse(qr(serverFingerprint: 'a' * 63)),
        refuses,
      );
    });

    test('one that is too long is refused', () {
      expect(
        () => PairingPayload.parse(qr(serverFingerprint: 'a' * 65)),
        refuses,
      );
    });

    test('an uppercase one is refused', () {
      expect(
        () => PairingPayload.parse(qr(serverFingerprint: 'A' * 64)),
        refuses,
        reason: '§2 fixes the fingerprint as lowercase hexadecimal',
      );
    });

    test('a non-hexadecimal one is refused', () {
      expect(
        () => PairingPayload.parse(qr(serverFingerprint: 'z' * 64)),
        refuses,
      );
    });

    test('a base64 digest is refused even at the right length', () {
      expect(
        () => PairingPayload.parse(qr(serverFingerprint: 'aB0-_${'a' * 59}')),
        refuses,
        reason:
            'a digest in a different encoding is the wrong pin of a similar shape, which '
            'is why the field is validated as a digest and not as a string',
      );
    });
  });

  group('the session id', () {
    test('uppercase is refused', () {
      expect(
        () => PairingPayload.parse(qr(sessionId: goodSessionId.toUpperCase())),
        refuses,
      );
    });

    test('a UUID without hyphens is refused', () {
      expect(
        () => PairingPayload.parse(
          qr(sessionId: goodSessionId.replaceAll('-', '')),
        ),
        refuses,
      );
    });

    test('a non-UUID string is refused', () {
      expect(() => PairingPayload.parse(qr(sessionId: 'session-1')), refuses);
    });
  });

  group('the pairing token', () {
    test('a padded one is refused', () {
      expect(
        () => PairingPayload.parse(qr(pairToken: '$goodToken=')),
        refuses,
        reason:
            '§4 removes padding, and a padded spelling is a different string',
      );
    });

    test('one of the wrong length is refused', () {
      expect(
        () => PairingPayload.parse(
          qr(pairToken: encodeBase64UrlNoPadding(Uint8List(16))),
        ),
        refuses,
      );
    });

    test('a non-canonical spelling of the right length is refused', () {
      // Unpadded base64 leaves spare bits in its final character, so more than one string
      // can spell the same 32 bytes. §4 requires decoding and re-encoding to reproduce
      // the string exactly, which makes only one of them legal.
      final String canonical = encodeBase64UrlNoPadding(Uint8List(32));
      final String mutated = '${canonical.substring(0, canonical.length - 1)}B';

      expect(mutated, isNot(canonical));
      expect(
        () => PairingPayload.parse(qr(pairToken: mutated)),
        refuses,
        reason:
            'both the decoder and the re-encode check may be what rejects it, and either '
            'is acceptable; what matters is that the non-canonical spelling never parses',
      );
    });

    test('the standard base64 alphabet is refused', () {
      expect(
        () => PairingPayload.parse(
          qr(pairToken: '+${'a' * (ProtocolLimits.pairTokenChars - 1)}'),
        ),
        refuses,
      );
    });

    test('an empty one is refused', () {
      expect(() => PairingPayload.parse(qr(pairToken: '')), refuses);
    });
  });

  group('candidates', () {
    test('an empty list is refused', () {
      expect(
        () => PairingPayload.parse(qr(candidateList: <Object?>[])),
        refuses,
      );
    });

    test('more than eight are refused', () {
      expect(
        () => PairingPayload.parse(qr(candidateList: candidates(9))),
        refuses,
      );
    });

    test('port zero is refused', () {
      expect(
        () => PairingPayload.parse(
          qr(
            candidateList: <Map<String, Object?>>[
              <String, Object?>{'host': '10.0.0.1', 'port': 0},
            ],
          ),
        ),
        refuses,
      );
    });

    test('a port above 65535 is refused', () {
      expect(
        () => PairingPayload.parse(
          qr(
            candidateList: <Map<String, Object?>>[
              <String, Object?>{'host': '10.0.0.1', 'port': 65536},
            ],
          ),
        ),
        refuses,
      );
    });

    test('a port sent as a string is refused', () {
      expect(
        () => PairingPayload.parse(
          qr(
            candidateList: <Map<String, Object?>>[
              <String, Object?>{'host': '10.0.0.1', 'port': '8443'},
            ],
          ),
        ),
        refuses,
      );
    });

    test('a host carrying a scheme is refused', () {
      expect(
        () => PairingPayload.parse(
          qr(
            candidateList: <Map<String, Object?>>[
              <String, Object?>{'host': 'https://evil.example', 'port': 443},
            ],
          ),
        ),
        refuses,
        reason: '§3 forbids anything but a bare address in this field',
      );
    });

    test('a host carrying credentials is refused', () {
      expect(
        () => PairingPayload.parse(
          qr(
            candidateList: <Map<String, Object?>>[
              <String, Object?>{'host': 'user:pass@10.0.0.1', 'port': 8443},
            ],
          ),
        ),
        refuses,
      );
    });

    test('a host carrying a path is refused', () {
      expect(
        () => PairingPayload.parse(
          qr(
            candidateList: <Map<String, Object?>>[
              <String, Object?>{'host': '10.0.0.1/x', 'port': 8443},
            ],
          ),
        ),
        refuses,
      );
    });

    test('a host carrying a query is refused', () {
      expect(
        () => PairingPayload.parse(
          qr(
            candidateList: <Map<String, Object?>>[
              <String, Object?>{'host': '10.0.0.1?t=1', 'port': 8443},
            ],
          ),
        ),
        refuses,
      );
    });

    test('a host carrying whitespace is refused', () {
      expect(
        () => PairingPayload.parse(
          qr(
            candidateList: <Map<String, Object?>>[
              <String, Object?>{'host': '10.0.0.1 ', 'port': 8443},
            ],
          ),
        ),
        refuses,
      );
    });

    test('a bracketed address is refused', () {
      expect(
        () => PairingPayload.parse(
          qr(
            candidateList: <Map<String, Object?>>[
              <String, Object?>{'host': '[fe80::1]', 'port': 8443},
            ],
          ),
        ),
        refuses,
        reason:
            'the port is a separate field, so brackets are not needed to disambiguate; '
            'accepting both spellings would mean two names for one address',
      );
    });

    test('an IPv4 octet above 255 is refused', () {
      expect(
        () => PairingPayload.parse(
          qr(
            candidateList: <Map<String, Object?>>[
              <String, Object?>{'host': '10.0.0.256', 'port': 8443},
            ],
          ),
        ),
        refuses,
      );
    });

    test('an IPv4 octet with a leading zero is refused', () {
      expect(
        () => PairingPayload.parse(
          qr(
            candidateList: <Map<String, Object?>>[
              <String, Object?>{'host': '10.0.0.01', 'port': 8443},
            ],
          ),
        ),
        refuses,
        reason:
            'a leading zero resolves differently in some parsers as octal, so one string '
            'would mean two addresses',
      );
    });

    test('a hostname is refused', () {
      expect(
        () => PairingPayload.parse(
          qr(
            candidateList: <Map<String, Object?>>[
              <String, Object?>{'host': 'nearsend.local', 'port': 8443},
            ],
          ),
        ),
        refuses,
        reason: '§3 requires an explicit local interface address',
      );
    });

    test('an IPv6 address with two elisions is refused', () {
      expect(
        () => PairingPayload.parse(
          qr(
            candidateList: <Map<String, Object?>>[
              <String, Object?>{'host': 'fe80::1::2', 'port': 8443},
            ],
          ),
        ),
        refuses,
      );
    });

    test('an IPv6 group longer than four digits is refused', () {
      expect(
        () => PairingPayload.parse(
          qr(
            candidateList: <Map<String, Object?>>[
              <String, Object?>{'host': 'fe80::12345', 'port': 8443},
            ],
          ),
        ),
        refuses,
      );
    });

    test('a candidate that is not an object is refused', () {
      expect(
        () => PairingPayload.parse(qr(candidateList: <Object?>['10.0.0.1'])),
        refuses,
      );
    });
  });

  group('expiry', () {
    test('zero is refused', () {
      expect(() => PairingPayload.parse(qr(expiresInSeconds: 0)), refuses);
    });

    test('a string is refused', () {
      expect(() => PairingPayload.parse(qr(expiresInSeconds: '300')), refuses);
    });
  });

  group('things that are not a pairing payload at all', () {
    test('plain text is refused', () {
      expect(() => PairingPayload.parse('hello'), refuses);
    });

    test('a JSON array is refused', () {
      expect(() => PairingPayload.parse('[1,2,3]'), refuses);
    });

    test('malformed JSON is refused', () {
      expect(() => PairingPayload.parse('{'), refuses);
    });

    test('a URL is refused', () {
      expect(
        () => PairingPayload.parse('https://nearsend.local/pair?token=x'),
        refuses,
        reason:
            '§3 says the QR code is JSON, not something that auto-navigates',
      );
    });
  });

  group('candidate identity', () {
    test('candidates compare by value', () {
      expect(
        const PairingCandidate(host: '10.0.0.1', port: 1),
        const PairingCandidate(host: '10.0.0.1', port: 1),
      );
      expect(
        const PairingCandidate(host: '10.0.0.1', port: 1),
        isNot(const PairingCandidate(host: '10.0.0.1', port: 2)),
      );
    });

    test('the candidate list cannot be modified through the payload', () {
      final PairingPayload payload = PairingPayload.parse(qr());
      expect(
        () => payload.candidates.add(
          const PairingCandidate(host: '10.0.0.9', port: 1),
        ),
        throwsUnsupportedError,
      );
    });
  });
}
