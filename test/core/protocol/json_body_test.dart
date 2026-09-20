import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:nearsend/core/protocol/json_body.dart';
import 'package:nearsend/core/protocol/protocol_exception.dart';
import 'package:nearsend/core/protocol/protocol_limits.dart';

/// Strict decoding of a control body (§4, §7).
///
/// The rules here are the ones that stop two implementations from reading the same bytes
/// and disagreeing about what they say, so most of the tests are refusals.
void main() {
  Uint8List bytesOf(String text) => Uint8List.fromList(utf8.encode(text));

  Matcher refuses = throwsA(isA<ProtocolViolation>());

  Map<String, Object?> decode(String text) => decodeControlBody(bytesOf(text));

  group('a well formed body', () {
    test('is decoded', () {
      final Map<String, Object?> body = decode(
        '{"a":1,"b":"two","c":[true,null]}',
      );

      expect(body['a'], 1);
      expect(body['b'], 'two');
      expect(body['c'], <Object?>[true, null]);
    });

    test('may be surrounded by whitespace', () {
      expect(decode('  \n\t{"a":1}\r\n ')['a'], 1);
    });

    test('may contain nested values up to the depth limit', () {
      String nested(int depth) => '${'{"a":' * depth}1${'}' * depth}';

      expect(decode(nested(ProtocolLimits.maxJsonDepth)), isNotEmpty);
    });

    test('handles escapes, including a surrogate pair', () {
      // A pair spells one character; the decoded key must be that character and not two
      // lone surrogates.
      final Map<String, Object?> body = decode(r'{"\ud83d\ude00":1}');
      expect(body.keys.single, String.fromCharCode(0x1F600));
    });
  });

  group('size and encoding', () {
    test('a byte order mark is refused', () {
      final Uint8List withBom = Uint8List.fromList(<int>[
        0xEF,
        0xBB,
        0xBF,
        ...utf8.encode('{"a":1}'),
      ]);
      expect(
        () => decodeControlBody(withBom),
        throwsA(
          isA<ProtocolViolation>().having(
            (ProtocolViolation e) => e.detail,
            'detail',
            contains('byte order mark'),
          ),
        ),
        reason: '§4 says the content is interpreted as UTF-8 and a BOM is not accepted',
      );
    });

    test('invalid UTF-8 is refused', () {
      expect(
        () => decodeControlBody(
          Uint8List.fromList(<int>[0x7B, 0x22, 0x61, 0x22, 0x3A, 0xFF, 0x7D]),
        ),
        refuses,
        reason:
            'a malformed sequence would otherwise become U+FFFD, which is a different '
            'string than the one that arrived',
      );
    });

    test('a truncated multi-byte sequence is refused', () {
      expect(
        () => decodeControlBody(
          Uint8List.fromList(<int>[0x7B, 0x22, 0xE4, 0xB8, 0x7D]),
        ),
        refuses,
      );
    });

    test('a body over the control limit is refused as too large', () {
      final Uint8List tooBig = Uint8List(ProtocolLimits.controlBodyMaxBytes + 1)
        ..fillRange(0, ProtocolLimits.controlBodyMaxBytes + 1, 0x20);

      expect(
        () => decodeControlBody(tooBig),
        throwsA(
          isA<ProtocolViolation>().having(
            (ProtocolViolation e) => e.code,
            'code',
            ProtocolErrorCode.bodyTooLarge,
          ),
        ),
      );
    });
  });

  group('duplicate keys are refused, however they are spelled', () {
    test('a plain duplicate is refused', () {
      expect(
        () => decode('{"a":1,"a":2}'),
        throwsA(
          isA<ProtocolViolation>().having(
            (ProtocolViolation e) => e.detail,
            'detail',
            contains('repeats'),
          ),
        ),
        reason:
            'Dart\'s decoder keeps the last value and says nothing, which is exactly how '
            'two implementations come to disagree about the same bytes',
      );
    });

    test('a duplicate spelled with an escape is refused', () {
      expect(
        () => decode(r'{"a":1,"\u0061":2}'),
        refuses,
        reason:
            'comparing raw source text would call this valid and let the decoder pick one; '
            'the scanner decodes escapes before comparing',
      );
    });

    test('a duplicate spelled with a surrogate pair is refused', () {
      expect(() => decode(r'{"\ud83d\ude00":1,"😀":2}'), refuses);
    });

    test('the same key in different objects is not a duplicate', () {
      expect(decode('{"a":{"x":1},"b":{"x":2}}'), hasLength(2));
    });

    test('the key is not echoed back in the error', () {
      final String secret = 'x' * 40;
      try {
        decode('{"$secret":1,"$secret":2}');
        fail('the body should have been refused');
      } on ProtocolViolation catch (error) {
        expect(
          error.detail,
          isNot(contains(secret)),
          reason: 'the key came from the body, and a control body can carry a token',
        );
      }
    });
  });

  group('depth', () {
    test('one level too deep is refused', () {
      final int depth = ProtocolLimits.maxJsonDepth + 1;
      final String body = '${'{"a":' * depth}1${'}' * depth}';
      expect(
        () => decode(body),
        throwsA(
          isA<ProtocolViolation>().having(
            (ProtocolViolation e) => e.detail,
            'detail',
            contains('nests deeper'),
          ),
        ),
      );
    });

    test('deeply nested arrays are bounded too', () {
      final int depth = ProtocolLimits.maxJsonDepth + 1;
      expect(() => decode('{"a":${'[' * depth}1${']' * depth}}'), refuses);
    });
  });

  group('values JSON does not allow', () {
    test('NaN is refused', () {
      expect(() => decode('{"a":NaN}'), refuses);
    });

    test('Infinity is refused', () {
      expect(() => decode('{"a":Infinity}'), refuses);
    });

    test('-Infinity is refused', () {
      expect(() => decode('{"a":-Infinity}'), refuses);
    });

    test('a leading zero is refused', () {
      expect(() => decode('{"a":01}'), refuses);
    });

    test('a bare minus is refused', () {
      expect(() => decode('{"a":-}'), refuses);
    });

    test('a fraction without digits is refused', () {
      expect(() => decode('{"a":1.}'), refuses);
    });

    test('an exponent without digits is refused', () {
      expect(() => decode('{"a":1e}'), refuses);
    });

    test('a hexadecimal literal is refused', () {
      expect(() => decode('{"a":0x10}'), refuses);
    });

    test('single quotes are refused', () {
      expect(() => decode("{'a':1}"), refuses);
    });

    test('a trailing comma is refused', () {
      expect(() => decode('{"a":1,}'), refuses);
    });
  });

  group('strings', () {
    test('an unescaped control character is refused', () {
      expect(() => decode('{"a":"x\u0001y"}'), refuses);
    });

    test('an unterminated string is refused', () {
      expect(() => decode('{"a":"xy}'), refuses);
    });

    test('an invalid escape is refused', () {
      expect(() => decode(r'{"a":"\q"}'), refuses);
    });

    test('an unpaired high surrogate escape is refused', () {
      expect(() => decode(r'{"a":"\ud83d"}'), refuses);
    });

    test('an unpaired low surrogate escape is refused', () {
      expect(() => decode(r'{"a":"\ude00"}'), refuses);
    });

    test('a short unicode escape is refused', () {
      expect(() => decode(r'{"a":"\u12"}'), refuses);
    });

    test('a non-hexadecimal unicode escape is refused', () {
      expect(() => decode(r'{"a":"\u12g4"}'), refuses);
    });
  });

  group('structure', () {
    test('a top level array is refused', () {
      expect(
        () => decode('[1,2]'),
        throwsA(
          isA<ProtocolViolation>().having(
            (ProtocolViolation e) => e.detail,
            'detail',
            contains('JSON object'),
          ),
        ),
        reason: 'every control body in §7 is an object',
      );
    });

    test('a bare scalar is refused', () {
      expect(() => decode('42'), refuses);
      expect(() => decode('"text"'), refuses);
      expect(() => decode('null'), refuses);
    });

    test('content after the top level value is refused', () {
      expect(() => decode('{"a":1}{"b":2}'), refuses);
      expect(() => decode('{"a":1} x'), refuses);
    });

    test('an empty body is refused', () {
      expect(() => decode(''), refuses);
    });

    test('an unterminated object is refused', () {
      expect(() => decode('{"a":1'), refuses);
    });

    test('an object key that is not a string is refused', () {
      expect(() => decode('{a:1}'), refuses);
    });

    test('a key without a value is refused', () {
      expect(() => decode('{"a"}'), refuses);
    });

    test('an empty object is accepted', () {
      expect(decode('{}'), isEmpty);
    });
  });
}
