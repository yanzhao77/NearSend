import 'package:flutter_test/flutter_test.dart';

import 'package:nearsend/core/protocol/api_routes.dart';
import 'package:nearsend/core/protocol/protocol_exception.dart';
import 'package:nearsend/core/protocol/protocol_limits.dart';

/// The `/v1` request surface (§7, with §6 and §8 for the parameters they govern).
void main() {
  const String transferId = '3f2504e0-4f89-41d3-9a0c-0305e82c3301';
  const String fileId = '9c858901-8a57-4791-81fe-4c455b099bc9';

  Matcher refuses = throwsA(isA<ProtocolViolation>());

  Matcher refusesWith(ProtocolErrorCode code) => throwsA(
    isA<ProtocolViolation>().having(
      (ProtocolViolation e) => e.code,
      'code',
      code,
    ),
  );

  MatchedApiRequest match(HttpMethod method, String target) =>
      ApiRoutes.match(method: method, target: target);

  group('the table matches §7', () {
    // The table as written in §7, as data. A route added, removed or re-methoded without
    // §7 changing fails here rather than in a peer's client.
    const List<String> documented = <String>[
      'POST /v1/pair',
      'GET /v1/offers',
      'POST /v1/transfers',
      'PUT /v1/transfers/{id}/manifest',
      'GET /v1/transfers/{id}/manifest',
      'POST /v1/transfers/{id}/seal',
      'POST /v1/transfers/{id}/decision',
      'GET /v1/transfers/{id}/authorization',
      'POST /v1/transfers/{id}/authorization/receipt',
      'POST /v1/transfers/{id}/resume',
      'GET /v1/transfers/{id}/status',
      'PUT /v1/transfers/{id}/files/{fid}/chunks/{index}',
      'GET /v1/transfers/{id}/files/{fid}/chunks/{index}',
      'POST /v1/transfers/{id}/checkpoint',
      'POST /v1/transfers/{id}/pause',
      'POST /v1/transfers/{id}/complete',
      'POST /v1/transfers/{id}/cancel',
      'GET /v1/transfers/{id}/control',
      'POST /v1/transfers/{id}/control/receipt',
    ];

    test('every row is registered, with the method §7 gives it', () {
      final Set<String> registered = <String>{
        for (final ApiRoute route in ApiRoutes.all)
          '${route.method.name.toUpperCase()} ${route.template}',
      };
      expect(registered, documented.toSet());
    });

    test('no two routes collide', () {
      final Set<String> seen = <String>{};
      for (final ApiRoute route in ApiRoutes.all) {
        expect(
          seen.add('${route.method.name} ${route.template}'),
          isTrue,
          reason:
              '${route.template} is registered twice for ${route.method.name}',
        );
      }
    });

    test('every path is under the §7 prefix', () {
      for (final ApiRoute route in ApiRoutes.all) {
        expect(route.template, startsWith('${ApiRoutes.prefix}/'));
      }
    });
  });

  group('matching', () {
    test('every route matches its own template', () {
      for (final ApiRoute route in ApiRoutes.all) {
        final String target = route.template
            .replaceAll('{id}', transferId)
            .replaceAll('{fid}', fileId)
            .replaceAll('{index}', '0');
        final MatchedApiRequest request = match(route.method, target);
        expect(request.route.name, route.name, reason: target);
      }
    });

    test('an unknown path is not found', () {
      expect(
        () => match(HttpMethod.get, '/v1/nothing'),
        refusesWith(ProtocolErrorCode.notFound),
      );
    });

    test('the wrong method on a known path is not found', () {
      expect(
        () => match(HttpMethod.post, '/v1/offers'),
        refusesWith(ProtocolErrorCode.notFound),
        reason:
            '§11 has no 405, so the conservative reading is §7\'s "unknown and '
            'unauthorised are both 404", which also declines to confirm the API surface',
      );
    });

    test('only the three methods §7 uses exist', () {
      expect(
        HttpMethod.values.map((HttpMethod m) => m.name).toSet(),
        <String>{'get', 'post', 'put'},
        reason:
            'a method the table does not use has no defined behaviour, so there would be '
            'no way to answer it correctly',
      );
    });

    test('a path that is not under the prefix is not found', () {
      expect(
        () => match(HttpMethod.get, '/offers'),
        refusesWith(ProtocolErrorCode.notFound),
      );
      expect(
        () => match(HttpMethod.get, 'v1/offers'),
        refusesWith(ProtocolErrorCode.notFound),
      );
    });

    test('a wrong number of segments is not found', () {
      expect(
        () => match(HttpMethod.get, '/v1'),
        refusesWith(ProtocolErrorCode.notFound),
      );
      expect(
        () => match(HttpMethod.get, '/v1/transfers/$transferId'),
        refusesWith(ProtocolErrorCode.notFound),
      );
      expect(
        () => match(HttpMethod.get, '/v1/transfers/$transferId/status/extra'),
        refusesWith(ProtocolErrorCode.notFound),
      );
    });

    test('an empty segment is refused', () {
      expect(
        () => match(HttpMethod.get, '/v1//offers'),
        refusesWith(ProtocolErrorCode.invalidPath),
      );
      expect(
        () => match(HttpMethod.get, '/v1/offers/'),
        refusesWith(ProtocolErrorCode.invalidPath),
      );
    });

    test('a dot segment is refused', () {
      expect(
        () => match(HttpMethod.get, '/v1/offers/../pair'),
        refusesWith(ProtocolErrorCode.invalidPath),
      );
      expect(
        () => match(HttpMethod.get, '/v1/./offers'),
        refusesWith(ProtocolErrorCode.invalidPath),
      );
    });

    test('percent-encoding is refused anywhere in the target', () {
      for (final String target in <String>[
        '/v1/transfers/%2e%2e/status',
        '/v1/transfers/a%2Fb/status',
        '/v1/offers?cursor=a%20b',
        '/v1/%6ffers',
      ]) {
        expect(
          () => match(HttpMethod.get, target),
          refusesWith(ProtocolErrorCode.invalidPath),
          reason:
              '$target needs an escape, and nothing this surface carries does; refusing '
              'it removes %2F and %2e%2e from ever reaching the matcher',
        );
      }
    });
  });

  group('path parameters are validated before use', () {
    test('a transfer id must be a canonical lowercase UUID', () {
      expect(
        () => match(
          HttpMethod.get,
          '/v1/transfers/${transferId.toUpperCase()}/status',
        ),
        refuses,
      );
      expect(
        () => match(
          HttpMethod.get,
          '/v1/transfers/${transferId.replaceAll('-', '')}/status',
        ),
        refuses,
      );
      expect(
        () => match(HttpMethod.get, '/v1/transfers/not-a-uuid/status'),
        refuses,
      );
    });

    test('a file id must be a canonical UUID too', () {
      final String base = '/v1/transfers/$transferId/files';
      expect(() => match(HttpMethod.get, '$base/not-a-uuid/chunks/0'), refuses);
      expect(match(HttpMethod.get, '$base/$fileId/chunks/0').fileId, fileId);
    });

    test('a valid id is exposed as given', () {
      expect(
        match(HttpMethod.get, '/v1/transfers/$transferId/status').transferId,
        transferId,
      );
    });

    test('a chunk index is a protocol decimal string', () {
      expect(
        match(
          HttpMethod.get,
          '/v1/transfers/$transferId/files/$fileId/chunks/0',
        ).chunkIndex,
        0,
      );
      expect(
        match(
          HttpMethod.get,
          '/v1/transfers/$transferId/files/$fileId/chunks/12345',
        ).chunkIndex,
        12345,
      );
    });

    test('a chunk index with a leading zero is refused', () {
      expect(
        () => match(
          HttpMethod.get,
          '/v1/transfers/$transferId/files/$fileId/chunks/01',
        ),
        refuses,
        reason:
            '§4 forbids a leading zero, so one index cannot have two spellings',
      );
    });

    test('a negative or non-numeric chunk index is refused', () {
      for (final String index in <String>[
        '-1',
        '+1',
        '1e3',
        'abc',
        '1.0',
        '',
      ]) {
        expect(
          () => match(
            HttpMethod.get,
            '/v1/transfers/$transferId/files/$fileId/chunks/$index',
          ),
          refuses,
          reason: 'index "$index"',
        );
      }
    });

    test('a chunk index beyond the transfer maximum is refused', () {
      expect(
        () => match(
          HttpMethod.get,
          '/v1/transfers/$transferId/files/$fileId/chunks/'
          '${ProtocolLimits.maxChunksPerTransfer}',
        ),
        refuses,
      );
    });
  });

  group('query parameters', () {
    test('an unknown parameter is refused', () {
      expect(
        () => match(HttpMethod.get, '/v1/offers?limit=10'),
        refuses,
        reason:
            'a parameter one implementation honours and another drops is a behaviour '
            'difference no test of either one would catch',
      );
    });

    test('a repeated parameter is refused', () {
      expect(
        () => match(HttpMethod.get, '/v1/offers?cursor=a&cursor=b'),
        refuses,
      );
    });

    test('a parameter without a value is refused', () {
      expect(() => match(HttpMethod.get, '/v1/offers?cursor'), refuses);
      expect(() => match(HttpMethod.get, '/v1/offers?=x'), refuses);
    });

    test('an empty query string is accepted', () {
      expect(match(HttpMethod.get, '/v1/offers?').queryParameters, isEmpty);
    });

    test('a cursor is passed through without decoding', () {
      expect(
        match(
          HttpMethod.get,
          '/v1/offers?cursor=abc-123_XYZ',
        ).queryParameters['cursor'],
        'abc-123_XYZ',
      );
    });

    test('the offsets of a chunk are not readable from the request', () {
      expect(
        () => match(
          HttpMethod.put,
          '/v1/transfers/$transferId/files/$fileId/chunks/0?offset=100',
        ),
        refuses,
        reason:
            '§8 derives the offset from the index and refuses a client-supplied one, so '
            'there is no parameter through which one could arrive',
      );
    });
  });

  group('page limits', () {
    test('a file page defaults to 128 and cannot exceed it', () {
      final MatchedApiRequest request = match(
        HttpMethod.get,
        '/v1/transfers/$transferId/manifest?kind=files',
      );
      expect(request.pageLimit(), ProtocolLimits.filePageLimit);
      expect(request.pageLimit(), 128);

      expect(
        match(
          HttpMethod.get,
          '/v1/transfers/$transferId/manifest?kind=files&limit=128',
        ).pageLimit(),
        128,
      );
      expect(
        () => match(
          HttpMethod.get,
          '/v1/transfers/$transferId/manifest?kind=files&limit=129',
        ).pageLimit(),
        refuses,
      );
    });

    test('a chunk page defaults to 1024 and cannot exceed it', () {
      final MatchedApiRequest request = match(
        HttpMethod.get,
        '/v1/transfers/$transferId/manifest?kind=chunks&fileId=$fileId',
      );
      expect(request.pageLimit(), ProtocolLimits.chunkPageLimit);
      expect(request.pageLimit(), 1024);

      expect(
        () => match(
          HttpMethod.get,
          '/v1/transfers/$transferId/manifest?kind=chunks&fileId=$fileId&limit=1025',
        ).pageLimit(),
        refuses,
      );
    });

    test('the status page is capped at the chunk page limit', () {
      expect(
        match(HttpMethod.get, '/v1/transfers/$transferId/status').pageLimit(),
        ProtocolLimits.chunkPageLimit,
      );
      expect(
        () => match(
          HttpMethod.get,
          '/v1/transfers/$transferId/status?limit=1025',
        ).pageLimit(),
        refuses,
      );
    });

    test('a zero or malformed limit is refused', () {
      for (final String limit in <String>['0', '-1', 'many', '1.5', '']) {
        expect(
          () => match(
            HttpMethod.get,
            '/v1/transfers/$transferId/status?limit=$limit',
          ).pageLimit(),
          refuses,
          reason: 'limit "$limit"',
        );
      }
    });

    test('an endpoint with no page does not accept a limit', () {
      expect(
        () => match(
          HttpMethod.get,
          '/v1/transfers/$transferId/authorization',
        ).pageLimit(),
        refuses,
      );
    });
  });

  group('manifest page parameters', () {
    test('kind is required', () {
      expect(
        () => match(
          HttpMethod.get,
          '/v1/transfers/$transferId/manifest',
        ).manifestKind(),
        refuses,
      );
    });

    test('kind is one of the two §6 values', () {
      expect(
        match(
          HttpMethod.get,
          '/v1/transfers/$transferId/manifest?kind=files',
        ).manifestKind(),
        ManifestPageKind.files,
      );
      expect(
        match(
          HttpMethod.get,
          '/v1/transfers/$transferId/manifest?kind=chunks&fileId=$fileId',
        ).manifestKind(),
        ManifestPageKind.chunks,
      );
      for (final String kind in <String>['file', 'FILES', 'chunk', '']) {
        expect(
          () => match(
            HttpMethod.get,
            '/v1/transfers/$transferId/manifest?kind=$kind',
          ).manifestKind(),
          refuses,
          reason: 'kind "$kind"',
        );
      }
    });

    test('a files page must not carry a fileId, and a chunks page must', () {
      expect(
        () => match(
          HttpMethod.get,
          '/v1/transfers/$transferId/manifest?kind=files&fileId=$fileId',
        ).manifestKind(),
        refuses,
        reason: '§6: files 页不得带 fileId',
      );
      expect(
        () => match(
          HttpMethod.get,
          '/v1/transfers/$transferId/manifest?kind=chunks',
        ).manifestKind(),
        refuses,
        reason: '§6: chunks 页必须带 fileId',
      );
      expect(
        () => match(
          HttpMethod.get,
          '/v1/transfers/$transferId/manifest?kind=chunks&fileId=not-a-uuid',
        ).manifestKind(),
        refuses,
        reason: 'the fileId is an identifier, so it is validated like one',
      );
    });
  });

  group('paging offsets', () {
    test('startIndex defaults to 0 and is a decimal string', () {
      expect(
        match(HttpMethod.get, '/v1/transfers/$transferId/status').startIndex(),
        0,
      );
      expect(
        match(
          HttpMethod.get,
          '/v1/transfers/$transferId/status?startIndex=128',
        ).startIndex(),
        128,
      );
      expect(
        () => match(
          HttpMethod.get,
          '/v1/transfers/$transferId/status?startIndex=0128',
        ).startIndex(),
        refuses,
      );
    });

    test('afterSeq defaults to 0 and is a decimal string', () {
      expect(
        match(HttpMethod.get, '/v1/transfers/$transferId/control').afterSeq(),
        0,
      );
      expect(
        match(
          HttpMethod.get,
          '/v1/transfers/$transferId/control?afterSeq=7',
        ).afterSeq(),
        7,
      );
      expect(
        () => match(
          HttpMethod.get,
          '/v1/transfers/$transferId/control?afterSeq=-1',
        ).afterSeq(),
        refuses,
      );
    });
  });

  group('the chunk offset is derived, never supplied', () {
    test('it is the index times the protocol chunk size', () {
      final MatchedApiRequest request = match(
        HttpMethod.get,
        '/v1/transfers/$transferId/files/$fileId/chunks/3',
      );
      expect(
        request.chunkOffsetBytes(sizeBytes: 4 * ProtocolLimits.chunkSizeBytes),
        3 * ProtocolLimits.chunkSizeBytes,
      );
    });

    test('an index past the end of the file is refused', () {
      final MatchedApiRequest request = match(
        HttpMethod.get,
        '/v1/transfers/$transferId/files/$fileId/chunks/4',
      );
      expect(
        () => request.chunkOffsetBytes(
          sizeBytes: 4 * ProtocolLimits.chunkSizeBytes,
        ),
        refuses,
      );
    });

    test('an empty file has no chunk 0', () {
      final MatchedApiRequest request = match(
        HttpMethod.get,
        '/v1/transfers/$transferId/files/$fileId/chunks/0',
      );
      expect(() => request.chunkOffsetBytes(sizeBytes: 0), refuses);
    });
  });
}
