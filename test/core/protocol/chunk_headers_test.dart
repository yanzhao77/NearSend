import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:nearsend/core/protocol/base64url.dart';
import 'package:nearsend/core/protocol/chunk_headers.dart';
import 'package:nearsend/core/protocol/protocol_exception.dart';

/// The chunk request and response rules of §8.
///
/// These are the framing rules request smuggling lives in, so almost every case here is a
/// refusal: a message whose length two hops disagree about is a message that can be split
/// into two.
void main() {
  final String token = encodeBase64UrlNoPadding(
    Uint8List.fromList(List<int>.generate(32, (int i) => i)),
  );
  final String digest = 'a' * 64;
  const int expectedBytes = 4194304;

  Matcher refuses = throwsA(isA<ProtocolViolation>());

  Matcher refusesWith(ProtocolErrorCode code) => throwsA(
    isA<ProtocolViolation>().having(
      (ProtocolViolation e) => e.code,
      'code',
      code,
    ),
  );

  Map<String, String> put({
    Object? contentType = chunkContentType,
    Object? contentLength = '4194304',
    Object? transferEncoding,
    Object? contentEncoding,
    Object? authorization,
    Object? epoch = '3',
    Object? manifest,
    Map<String, String> extra = const <String, String>{},
  }) => <String, String>{
    if (contentType != null) 'Content-Type': contentType as String,
    if (contentLength != null) 'Content-Length': contentLength as String,
    if (transferEncoding != null)
      'Transfer-Encoding': transferEncoding as String,
    if (contentEncoding != null) 'Content-Encoding': contentEncoding as String,
    'Authorization': (authorization as String?) ?? 'Bearer $token',
    if (epoch != null) leaseEpochHeader: epoch as String,
    manifestDigestHeader: (manifest as String?) ?? digest,
    ...extra,
  };

  group('a well formed chunk PUT', () {
    test('parses every field', () {
      final ChunkPutHeaders parsed = ChunkPutHeaders.parse(put());

      expect(parsed.contentLength, expectedBytes);
      expect(parsed.taskAccessToken, token);
      expect(parsed.leaseEpoch, 3);
      expect(parsed.manifestDigest, digest);
    });

    test('header names are case-insensitive', () {
      final ChunkPutHeaders parsed = ChunkPutHeaders.parse(<String, String>{
        'content-type': chunkContentType,
        'CONTENT-LENGTH': '4194304',
        'authorization': 'Bearer $token',
        'x-lft-lease-epoch': '3',
        'X-LFT-MANIFEST-DIGEST': digest,
      });
      expect(parsed.contentLength, expectedBytes);
      expect(parsed.leaseEpoch, 3);
    });

    test('surrounding whitespace in a value is trimmed, as HTTP allows', () {
      expect(
        ChunkPutHeaders.parse(put(contentType: ' application/octet-stream '))
            .contentLength,
        expectedBytes,
      );
    });

    test('its text form does not render the token', () {
      expect(ChunkPutHeaders.parse(put()).toString(), isNot(contains(token)));
    });

    test('unrelated headers are ignored', () {
      expect(
        ChunkPutHeaders.parse(
          put(extra: <String, String>{'User-Agent': 'nearsend/1.0'}),
        ).leaseEpoch,
        3,
        reason:
            'HTTP carries many headers that have nothing to do with this protocol, so only '
            'the namespace this project owns can be rejected',
      );
    });
  });

  group('framing is decided before anything else', () {
    test('Transfer-Encoding is refused, whatever it says', () {
      for (final String value in <String>[
        'chunked',
        'identity',
        'gzip, chunked',
      ]) {
        expect(
          () => ChunkPutHeaders.parse(put(transferEncoding: value)),
          refusesWith(ProtocolErrorCode.invalidField),
          reason: 'Transfer-Encoding: $value',
        );
      }
    });

    test(
      'a message carrying both Transfer-Encoding and Content-Length is refused',
      () {
        expect(
          () => ChunkPutHeaders.parse(
            put(transferEncoding: 'chunked', contentLength: '4194304'),
          ),
          refuses,
          reason:
              '§8 names this combination explicitly: it is the classic disagreement about '
              'where a message ends',
        );
      },
    );

    test('a missing Content-Length is refused', () {
      expect(() => ChunkPutHeaders.parse(put(contentLength: null)), refuses);
    });

    test('two joined Content-Length values are refused', () {
      expect(
        () => ChunkPutHeaders.parse(put(contentLength: '4194304, 4194304')),
        refuses,
        reason:
            'a header map cannot hold one name twice, so a repetition arrives as a joined '
            'value - and that is a peer saying there are two lengths',
      );
    });

    test('two lengths that disagree are refused too', () {
      expect(
        () => ChunkPutHeaders.parse(put(contentLength: '4194304, 1')),
        refuses,
      );
    });

    test('a Content-Length repeated in different cases is refused', () {
      expect(
        () => ChunkPutHeaders.parse(
          put(extra: <String, String>{'content-length': '5'}),
        ),
        refuses,
        reason:
            'HTTP field names are case-insensitive, so folding them silently would pick '
            'one length and leave which one to the implementation',
      );
    });

    test('a non-numeric Content-Length is refused', () {
      for (final String value in <String>[
        'abc',
        '',
        '4.5',
        '-1',
        '+4',
        '4e6',
      ]) {
        expect(
          () => ChunkPutHeaders.parse(put(contentLength: value)),
          refuses,
          reason: 'Content-Length: "$value"',
        );
      }
    });

    test('leading zeros are accepted because HTTP allows them', () {
      expect(
        ChunkPutHeaders.parse(put(contentLength: '0004194304')).contentLength,
        expectedBytes,
        reason:
            'the §4 canonical form is a rule about protocol fields; this is an HTTP field, '
            'and the parsed value is what the manifest is compared against',
      );
    });

    test('a compressed body is refused', () {
      for (final String value in <String>['gzip', 'deflate', 'br']) {
        expect(
          () => ChunkPutHeaders.parse(put(contentEncoding: value)),
          refuses,
          reason: 'Content-Encoding: $value',
        );
      }
    });

    test('an explicit identity encoding is accepted', () {
      expect(
        ChunkPutHeaders.parse(put(contentEncoding: 'identity')).contentLength,
        expectedBytes,
        reason:
            'identity means no compression, so it is not the thing §8 forbids',
      );
    });
  });

  group('the media type', () {
    test('a missing Content-Type is refused', () {
      expect(() => ChunkPutHeaders.parse(put(contentType: null)), refuses);
    });

    test('a different media type is refused', () {
      for (final String value in <String>[
        'application/json',
        'text/plain',
        'application/octet-stream; charset=binary',
        'application/octetstream',
      ]) {
        expect(
          () => ChunkPutHeaders.parse(put(contentType: value)),
          refuses,
          reason: 'Content-Type: $value',
        );
      }
    });

    test('the media type is matched case-insensitively', () {
      expect(
        ChunkPutHeaders.parse(put(contentType: 'Application/Octet-Stream'))
            .contentLength,
        expectedBytes,
      );
    });
  });

  group('identity and generation', () {
    test('a missing Authorization header is refused', () {
      expect(() => ChunkPutHeaders.parse(put(authorization: '')), refuses);
    });

    test('another scheme is refused', () {
      expect(
        () => ChunkPutHeaders.parse(put(authorization: 'Basic $token')),
        refuses,
      );
    });

    test('a token of the wrong shape is refused', () {
      expect(
        () => ChunkPutHeaders.parse(put(authorization: 'Bearer short')),
        refuses,
      );
      expect(
        () => ChunkPutHeaders.parse(put(authorization: 'Bearer $token=')),
        refuses,
      );
    });

    test('a missing lease epoch header is refused', () {
      expect(() => ChunkPutHeaders.parse(put(epoch: null)), refuses);
    });

    test('the lease epoch is a §4 decimal string', () {
      expect(ChunkPutHeaders.parse(put(epoch: '0')).leaseEpoch, 0);
      for (final String value in <String>['03', '-1', '1.0', 'x', '']) {
        expect(
          () => ChunkPutHeaders.parse(put(epoch: value)),
          refuses,
          reason: 'X-LFT-Lease-Epoch: "$value"',
        );
      }
    });

    test('a missing manifest digest header is refused', () {
      expect(
        () => ChunkPutHeaders.parse(<String, String>{
          'Content-Type': chunkContentType,
          'Content-Length': '1',
          'Authorization': 'Bearer $token',
          leaseEpochHeader: '1',
        }),
        refuses,
      );
    });

    test('the manifest digest is a lowercase SHA-256', () {
      expect(() => ChunkPutHeaders.parse(put(manifest: 'A' * 64)), refuses);
      expect(() => ChunkPutHeaders.parse(put(manifest: 'a' * 63)), refuses);
    });
  });

  group('the namespace this project owns', () {
    test('an undefined X-LFT header is refused', () {
      expect(
        () => ChunkPutHeaders.parse(
          put(extra: <String, String>{'X-LFT-Something': '1'}),
        ),
        refuses,
        reason:
            'the prefix is ours, so a parameter one implementation honours and another '
            'drops cannot hide there',
      );
    });

    test('every defined X-LFT header is accepted', () {
      expect(
        ChunkPutHeaders.parse(
          put(
            extra: <String, String>{
              leaseEpochHeader: '3',
              manifestDigestHeader: digest,
            },
          ),
        ).leaseEpoch,
        3,
      );
    });
  });

  group('the body must be exactly the expected length (§8)', () {
    test('an exact body is accepted', () {
      expect(
        () => assertChunkBodyLength(
          receivedBytes: expectedBytes,
          expectedBytes: expectedBytes,
        ),
        returnsNormally,
      );
    });

    test('a trailing byte is refused', () {
      expect(
        () => assertChunkBodyLength(
          receivedBytes: expectedBytes + 1,
          expectedBytes: expectedBytes,
        ),
        throwsA(
          isA<ProtocolViolation>().having(
            (ProtocolViolation e) => e.detail,
            'detail',
            contains('trailing data'),
          ),
        ),
      );
    });

    test('a long tail is refused', () {
      expect(
        () => assertChunkBodyLength(
          receivedBytes: expectedBytes * 2,
          expectedBytes: expectedBytes,
        ),
        refuses,
      );
    });

    test('a short body is refused', () {
      expect(
        () => assertChunkBodyLength(
          receivedBytes: expectedBytes - 1,
          expectedBytes: expectedBytes,
        ),
        refuses,
      );
      expect(
        () => assertChunkBodyLength(
          receivedBytes: 0,
          expectedBytes: expectedBytes,
        ),
        refuses,
      );
    });

    test('a zero length chunk is accepted when the manifest says zero', () {
      expect(
        () => assertChunkBodyLength(receivedBytes: 0, expectedBytes: 0),
        returnsNormally,
      );
    });

    test(
      'the refusal is INVALID_FIELD so the request is not retried unchanged',
      () {
        expect(
          () => assertChunkBodyLength(receivedBytes: 1, expectedBytes: 2),
          throwsA(
            isA<ProtocolViolation>().having(
              (ProtocolViolation e) => e.code,
              'code',
              ProtocolErrorCode.invalidField,
            ),
          ),
          reason:
              '§11 pairs INVALID_FIELD with "修正请求，不自动原样重试", which is the right '
              'instruction for a message whose framing is wrong',
        );
      },
    );
  });

  group('the chunk GET response (§8)', () {
    test('builds the two headers §8 lists', () {
      final ChunkGetResponseHeaders headers = ChunkGetResponseHeaders(
        contentLength: expectedBytes,
        chunkSha256: digest,
      );
      expect(headers.toHeaders(), <String, String>{
        'Content-Length': '4194304',
        chunkSha256Header: digest,
      });
    });

    test('round trips', () {
      final ChunkGetResponseHeaders parsed = ChunkGetResponseHeaders.parse(
        <String, String>{
          'content-length': '4194304',
          'x-lft-chunk-sha256': digest,
        },
      );
      expect(parsed.contentLength, expectedBytes);
      expect(parsed.chunkSha256, digest);
    });

    test('a missing advisory digest is refused', () {
      expect(
        () => ChunkGetResponseHeaders.parse(<String, String>{
          'Content-Length': '1',
        }),
        refuses,
      );
    });

    test('a digest that is not a SHA-256 is refused', () {
      expect(
        () => ChunkGetResponseHeaders.parse(<String, String>{
          'Content-Length': '1',
          chunkSha256Header: 'abc',
        }),
        refuses,
      );
    });

    test('its text form does not render the digest', () {
      expect(
        ChunkGetResponseHeaders.parse(<String, String>{
          'Content-Length': '1',
          chunkSha256Header: digest,
        }).toString(),
        isNot(contains(digest)),
      );
    });
  });

  group('the frozen manifest is authoritative, not the header', () {
    final ChunkGetResponseHeaders response = ChunkGetResponseHeaders(
      contentLength: 4,
      chunkSha256: 'b' * 64,
    );

    test('an agreeing header is reported as agreeing', () {
      expect(response.agreesWithManifest('b' * 64), isTrue);
      expect(response.agreesWithManifest('B' * 64), isTrue);
    });

    test('a disagreeing header is reported without being a refusal', () {
      expect(
        response.agreesWithManifest('c' * 64),
        isFalse,
        reason:
            '§8: 接收者仍以冻结清单为权威; refusing on the advisory field would hand a peer '
            'the power to fail a download it could not otherwise affect',
      );
      expect(
        response.chunkSha256,
        'b' * 64,
        reason:
            'the header is still what the peer said, and is reported as such',
      );
    });
  });
}
