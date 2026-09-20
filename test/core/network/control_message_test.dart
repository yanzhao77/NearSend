import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:nearsend/core/network/control_message.dart';
import 'package:nearsend/core/protocol/api_routes.dart';
import 'package:nearsend/core/protocol/protocol_exception.dart';
import 'package:nearsend/core/protocol/protocol_limits.dart';
import 'package:nearsend/core/protocol/wire_error.dart';

/// The control-plane envelope.
///
/// The property that carries the weight is that **§7's `Cache-Control: no-store` cannot be
/// omitted or overridden**. §7 states it for every control response, and a rule that each
/// call site has to remember is one that gets forgotten exactly once - on the response that
/// carries a token. So most of the first group is about the ways it could leak out: a
/// factory that forgets it, a caller who passes their own, a caller who deletes it after.
void main() {
  final Uint8List empty = Uint8List(0);

  Uint8List jsonBytes(Map<String, Object?> body) =>
      Uint8List.fromList(utf8.encode(jsonEncode(body)));

  group('every response is uncacheable', () {
    test('a JSON response carries no-store', () {
      final ControlResponse response = ControlResponse.json(
        status: 200,
        body: <String, Object?>{'stored': true},
      );
      expect(response.headers['cache-control'], 'no-store');
    });

    test('an error response carries no-store', () {
      final ControlResponse response = ControlResponse.error(
        ProtocolErrorCode.notFound,
      );
      expect(response.headers['cache-control'], 'no-store');
    });

    test('a binary response carries no-store', () {
      final ControlResponse response = ControlResponse.binary(
        status: 200,
        body: Uint8List.fromList(<int>[1, 2, 3]),
      );
      expect(
        response.headers['cache-control'],
        'no-store',
        reason:
            '§8 marks the chunk download as "下载成功不代表接收端持久化", which is the last '
            'thing a cache should hold on to',
      );
    });

    test('a caller cannot override it', () {
      final ControlResponse response = ControlResponse.json(
        status: 200,
        body: <String, Object?>{'state': 'PAUSED'},
        headers: <String, String>{'Cache-Control': 'max-age=3600'},
      );

      expect(
        response.headers['cache-control'],
        'no-store',
        reason:
            '§7 wins over a call site; silently preferring the caller would make the rule '
            'advisory',
      );
      expect(
        response.headers.length,
        2,
        reason:
            'the caller attempt did not leave a second, differing entry behind',
      );
    });

    test('a caller cannot remove it afterwards', () {
      final ControlResponse response = ControlResponse.error(
        ProtocolErrorCode.authExpired,
      );
      expect(
        () => response.headers.remove('cache-control'),
        throwsUnsupportedError,
      );
      expect(response.headers['cache-control'], 'no-store');
    });

    test('the constant matches what §7 asks for', () {
      expect(cacheControlNoStore, 'Cache-Control: no-store');
    });
  });

  group('error responses are built from §11', () {
    test('the status comes from the code', () {
      expect(ControlResponse.error(ProtocolErrorCode.invalidField).status, 400);
      expect(ControlResponse.error(ProtocolErrorCode.authExpired).status, 401);
      expect(
        ControlResponse.error(ProtocolErrorCode.directionForbidden).status,
        403,
      );
      expect(ControlResponse.error(ProtocolErrorCode.notFound).status, 404);
      expect(
        ControlResponse.error(ProtocolErrorCode.chunkHashMismatch).status,
        422,
      );
      expect(
        ControlResponse.error(ProtocolErrorCode.dbCommitFailed).status,
        500,
      );
      expect(
        ControlResponse.error(ProtocolErrorCode.spaceInsufficient).status,
        507,
      );
    });

    test('the body is the §7 error body', () {
      final ControlResponse response = ControlResponse.error(
        ProtocolErrorCode.directionForbidden,
      );
      final Map<String, Object?> body = response.decodeJsonBody();

      expect(body['code'], 'DIRECTION_FORBIDDEN');
      expect(body['message'], ProtocolErrorCode.directionForbidden.messageKey);
      expect(body['retryable'], isFalse);
      expect(
        body.containsKey('requestId'),
        isFalse,
        reason: '§7 marks requestId optional, so it is absent rather than null',
      );
    });

    test('the message is never free text', () {
      // A caller cannot pass one, so the only way to get a different message is to be a
      // different code. That is the point of WireError.of taking no message. Every code is
      // walked, so a new code cannot be added without being emittable.
      for (final ProtocolErrorCode code in ProtocolErrorCode.values) {
        final ControlResponse response = code == ProtocolErrorCode.rateLimited
            ? ControlResponse.error(code, retryAfterSeconds: 1)
            : ControlResponse.error(code);
        expect(response.decodeError().message, code.messageKey);
        expect(response.decodeError().code, code);
        expect(response.status, code.httpStatus);
      }
    });

    test('requestId is echoed back when the peer supplied one', () {
      const String requestId = '11111111-2222-4333-8444-555555555555';
      final ControlResponse response = ControlResponse.error(
        ProtocolErrorCode.invalidField,
        requestId: requestId,
      );
      expect(response.decodeError().requestId, requestId);
    });

    test('a 429 must carry a positive Retry-After', () {
      final ControlResponse response = ControlResponse.error(
        ProtocolErrorCode.rateLimited,
        retryAfterSeconds: 5,
      );
      expect(response.status, 429);
      expect(response.headers['retry-after'], '5');
      expect(response.decodeError().retryable, isTrue);
    });

    test('a 429 without a delay is a programming error, not a response', () {
      expect(
        () => ControlResponse.error(ProtocolErrorCode.rateLimited),
        throwsArgumentError,
        reason:
            '§11 makes the backoff the prescribed behaviour for 429, and a limit with no '
            'delay leaves a client with nothing to obey',
      );
      expect(
        () => ControlResponse.error(
          ProtocolErrorCode.rateLimited,
          retryAfterSeconds: 0,
        ),
        throwsArgumentError,
      );
    });

    test('Retry-After on any other code is a programming error', () {
      expect(
        () => ControlResponse.error(
          ProtocolErrorCode.notFound,
          retryAfterSeconds: 5,
        ),
        throwsArgumentError,
      );
    });

    test('a ProtocolViolation is answered with its own code', () {
      final ControlResponse response = ControlResponse.violation(
        const ProtocolViolation(
          ProtocolErrorCode.invalidPath,
          'a request path must not be percent-encoded',
        ),
      );
      expect(response.status, 400);
      expect(response.decodeError().code, ProtocolErrorCode.invalidPath);
      expect(
        response.decodeJsonBody()['message'],
        ProtocolErrorCode.invalidPath.messageKey,
        reason:
            'the local detail is for diagnostics and must not reach the peer',
      );
    });
  });

  group('content types', () {
    test('a control body is §4s JSON type', () {
      final ControlResponse response = ControlResponse.json(
        status: 200,
        body: <String, Object?>{'state': 'STAGING'},
      );
      expect(response.headers['content-type'], controlContentType);
      expect(controlContentType, 'application/json; charset=utf-8');
      expect(response.isControlBody, isTrue);
    });

    test('a chunk body is §8s octet-stream with a length', () {
      final ControlResponse response = ControlResponse.binary(
        status: 200,
        body: Uint8List.fromList(List<int>.filled(10, 7)),
      );
      expect(response.headers['content-type'], 'application/octet-stream');
      expect(
        response.headers['content-length'],
        '10',
        reason: '§8 fixes the chunk body length, and the receiver checks it',
      );
      expect(response.isControlBody, isFalse);
    });

    test(
      'a control body over §4s 1 MiB limit is refused here, not by the peer',
      () {
        final Map<String, Object?> huge = <String, Object?>{
          'padding': 'a' * (ProtocolLimits.controlBodyMaxBytes + 1),
        };
        expect(
          () => ControlResponse.json(status: 200, body: huge),
          throwsA(
            isA<ProtocolViolation>().having(
              (ProtocolViolation e) => e.code,
              'code',
              ProtocolErrorCode.resourceLimit,
            ),
          ),
          reason:
              'writing a response our own parser must refuse is worse than failing where '
              'the cause is still visible',
        );
      },
    );
  });

  group('requests', () {
    test('headers are matched case-insensitively', () {
      final ControlRequest request = ControlRequest(
        method: HttpMethod.get,
        target: '/v1/offers',
        headers: <String, String>{'Authorization': 'Bearer x'},
      );
      expect(request.header('authorization'), 'Bearer x');
      expect(request.header('AUTHORIZATION'), 'Bearer x');
      expect(request.header('authorisation'), isNull);
    });

    test('two spellings of one header are refused rather than merged', () {
      expect(
        () => ControlRequest(
          method: HttpMethod.post,
          target: '/v1/transfers',
          headers: <String, String>{'Content-Type': 'a', 'content-type': 'b'},
        ),
        throwsA(
          isA<ProtocolViolation>().having(
            (ProtocolViolation e) => e.code,
            'code',
            ProtocolErrorCode.invalidField,
          ),
        ),
        reason:
            'a map cannot hold both, so keeping one means choosing a value on the '
            'senders behalf - the same condition §8 refuses for Content-Length',
      );
    });

    test('an absent Authorization header is null, not an error', () {
      final ControlRequest request = ControlRequest(
        method: HttpMethod.get,
        target: '/v1/offers',
      );
      expect(request.bearerToken(), isNull);
    });

    test('a well-formed bearer token is returned', () {
      const String token = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
      final ControlRequest request = ControlRequest(
        method: HttpMethod.get,
        target: '/v1/offers',
        headers: <String, String>{'authorization': 'Bearer $token'},
      );
      expect(request.bearerToken(), token);
    });

    test(
      'a malformed Authorization header throws rather than reading as absent',
      () {
        // Treating garbage as "absent" would let two implementations disagree about whether a
        // credential was presented.
        const String validToken = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
        for (final String value in <String>[
          'Basic $validToken', // wrong scheme
          'Bearer', // no token at all
          'Bearer ', // empty token
          'Bearer  $validToken', // two spaces, so the token starts with one
          'bearer$validToken', // scheme and token run together
          'Bearer $validToken extra', // more than a scheme and a token
          'Bearer short', // not 32 bytes
        ]) {
          final ControlRequest request = ControlRequest(
            method: HttpMethod.get,
            target: '/v1/offers',
            headers: <String, String>{'authorization': value},
          );
          expect(
            () => request.bearerToken(),
            throwsA(isA<ProtocolViolation>()),
            reason: '"$value" is not a bearer credential',
          );
        }
      },
    );

    test('a request without a body shares one empty allocation', () {
      final ControlRequest a = ControlRequest(
        method: HttpMethod.get,
        target: '/v1/offers',
      );
      final ControlRequest b = ControlRequest(
        method: HttpMethod.get,
        target: '/v1/offers',
      );
      expect(a.body, isEmpty);
      expect(identical(a.body, b.body), isTrue);
    });

    test('the body decodes through the §4 rules', () {
      final ControlRequest request = ControlRequest(
        method: HttpMethod.post,
        target: '/v1/transfers/11111111-2222-4333-8444-555555555555/seal',
        headers: <String, String>{'content-type': controlContentType},
        body: jsonBytes(<String, Object?>{'requestId': 'x'}),
      );
      expect(request.decodeJsonBody()['requestId'], 'x');
    });

    test('a duplicate JSON key is refused by the shared decoder', () {
      final ControlRequest request = ControlRequest(
        method: HttpMethod.post,
        target: '/v1/pair',
        body: Uint8List.fromList(utf8.encode('{"a":1,"a":2}')),
      );
      expect(
        () => request.decodeJsonBody(),
        throwsA(isA<ProtocolViolation>()),
        reason:
            'Dart does not reject duplicate keys on its own, and two implementations '
            'reading different values from one body is the parser differential §4 closes',
      );
    });

    test('a body over 1 MiB is refused', () {
      final ControlRequest request = ControlRequest(
        method: HttpMethod.post,
        target: '/v1/pair',
        body: Uint8List(ProtocolLimits.controlBodyMaxBytes + 1),
      );
      expect(
        () => request.decodeJsonBody(),
        throwsA(
          isA<ProtocolViolation>().having(
            (ProtocolViolation e) => e.code,
            'code',
            ProtocolErrorCode.bodyTooLarge,
          ),
        ),
      );
    });

    test('toString reports the length, never the bytes', () {
      final ControlRequest request = ControlRequest(
        method: HttpMethod.post,
        target: '/v1/pair',
        body: jsonBytes(<String, Object?>{'pairToken': 'a-secret-value'}),
      );
      expect(request.toString(), contains('POST /v1/pair'));
      expect(request.toString(), contains('${request.body.length}B'));
      expect(
        request.toString(),
        isNot(contains('a-secret-value')),
        reason:
            'a request body can carry a pairing token, and this goes to logs',
      );
    });

    test('an empty header map costs nothing', () {
      final ControlRequest request = ControlRequest(
        method: HttpMethod.get,
        target: '/v1/offers',
        headers: const <String, String>{},
      );
      expect(request.headers, isEmpty);
      expect(
        identical(request.body, ControlRequest.emptyBody),
        isTrue,
        reason: 'a request without a body should not allocate one per request',
      );
    });
  });

  group('round trips', () {
    test('a written error body parses back to the same thing', () {
      const String requestId = '11111111-2222-4333-8444-555555555555';
      final ControlResponse response = ControlResponse.error(
        ProtocolErrorCode.staleLease,
        requestId: requestId,
      );
      final WireError parsed = WireError.parse(response.decodeJsonBody());

      expect(parsed.code, ProtocolErrorCode.staleLease);
      expect(parsed.httpStatus, 409);
      expect(parsed.retryable, isFalse);
      expect(parsed.requestId, requestId);
    });

    test('the response carries no header a caller did not ask for', () {
      final ControlResponse response = ControlResponse.json(
        status: 201,
        body: <String, Object?>{'state': 'STAGING'},
      );
      expect(response.headers.keys.toSet(), <String>{
        'cache-control',
        'content-type',
      });
    });
  });
}
