import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:nearsend/core/protocol/base64url.dart';
import 'package:nearsend/core/protocol/protocol_exception.dart';
import 'package:nearsend/core/protocol/protocol_limits.dart';
import 'package:nearsend/core/protocol/wire_error.dart';

/// The error body and credential header of §7, and §11's status table.
void main() {
  const String requestId = '3f2504e0-4f89-41d3-9a0c-0305e82c3301';
  final String token = encodeBase64UrlNoPadding(
    Uint8List.fromList(List<int>.generate(32, (int i) => i)),
  );

  Matcher refuses = throwsA(isA<ProtocolViolation>());

  Map<String, Object?> body({
    Object? code = 'RATE_LIMITED',
    Object? message = 'protocol.rateLimited',
    Object? retryable = true,
    Object? requestIdValue,
  }) => <String, Object?>{
    'code': code,
    'message': message,
    'retryable': retryable,
    'requestId': ?requestIdValue,
  };

  group('the body this build writes', () {
    test('carries the code, its message key and its retryability', () {
      final WireError error = WireError.of(ProtocolErrorCode.manifestMismatch);

      expect(error.toJson(), <String, Object?>{
        'code': 'MANIFEST_MISMATCH',
        'message': 'protocol.manifestMismatch',
        'retryable': false,
      });
      expect(error.httpStatus, 422);
    });

    test('includes the request id only when there is one', () {
      expect(
        WireError.of(ProtocolErrorCode.notFound)
            .toJson()
            .containsKey('requestId'),
        isFalse,
      );
      expect(
        WireError.of(
          ProtocolErrorCode.notFound,
          requestId: requestId,
        ).toJson()['requestId'],
        requestId,
      );
    });

    test('takes its fields from the code, so a caller cannot choose them', () {
      // There is no parameter for the message or the retryability, which is the point:
      // a caller cannot put free text on the wire, so a caller cannot put a secret there.
      for (final ProtocolErrorCode code in ProtocolErrorCode.values) {
        final WireError error = WireError.of(code);
        expect(error.message, code.messageKey);
        expect(error.retryable, code.retryable);
        expect(error.httpStatus, code.httpStatus);
      }
    });

    test('carries no key, token or local path for any code', () {
      for (final ProtocolErrorCode code in ProtocolErrorCode.values) {
        final String message = WireError.of(code).message;
        expect(message, isNot(contains('-----BEGIN')));
        expect(message, isNot(contains('/')));
        expect(message, isNot(contains(r'\')));
        expect(
          message,
          matches(RegExp(r'^[A-Za-z0-9.]+$')),
          reason:
              'the message is a stable key, so it cannot carry anything else',
        );
      }
    });

    test('round trips', () {
      final WireError first = WireError.of(
        ProtocolErrorCode.storageSyncFailed,
        requestId: requestId,
      );
      final WireError second = WireError.parse(first.toJson());

      expect(second.code, first.code);
      expect(second.message, first.message);
      expect(second.retryable, first.retryable);
      expect(second.requestId, first.requestId);
    });

    test('its text form does not include the message text', () {
      expect(
        WireError.parse(
          body(code: 'NOT_FOUND', message: 'nope', retryable: false),
        ).toString(),
        isNot(contains('nope')),
      );
    });
  });

  group('parsing a received body', () {
    test('accepts a well formed one', () {
      final WireError error = WireError.parse(body(requestIdValue: requestId));

      expect(error.code, ProtocolErrorCode.rateLimited);
      expect(error.isRetryable, isTrue);
      expect(error.requestId, requestId);
    });

    test('refuses an unknown code', () {
      expect(
        () => WireError.parse(body(code: 'SOMETHING_ELSE')),
        refuses,
        reason:
            'a code this build does not know cannot be mapped to a behaviour',
      );
    });

    test('refuses a code that is not a string', () {
      expect(() => WireError.parse(body(code: 429)), refuses);
    });

    test('refuses an unknown field', () {
      final Map<String, Object?> json = body()..['detail'] = 'x';
      expect(() => WireError.parse(json), refuses);
    });

    test('refuses a missing field', () {
      final Map<String, Object?> json = body()..remove('retryable');
      expect(() => WireError.parse(json), refuses);
    });

    test('refuses a non-boolean retryable', () {
      expect(() => WireError.parse(body(retryable: 'true')), refuses);
    });

    test('refuses a retryable that disagrees with the code', () {
      expect(
        () =>
            WireError.parse(body(code: 'CHUNK_HASH_MISMATCH', retryable: true)),
        refuses,
        reason:
            '§11 makes a hash mismatch block rather than retry; a peer claiming otherwise '
            'would be inviting a client to retry a corrupt block forever',
      );
    });

    test('refuses a retryable that denies what the code allows', () {
      expect(
        () => WireError.parse(
          body(code: 'STORAGE_SYNC_FAILED', retryable: false),
        ),
        refuses,
        reason:
            'refusing to retry a transient disk failure is the other half of the '
            'same mistake',
      );
    });

    test('refuses a message with a control character', () {
      expect(
        () => WireError.parse(
          body(code: 'NOT_FOUND', message: 'a\u0000b', retryable: false),
        ),
        refuses,
      );
    });

    test('refuses an over-long message', () {
      expect(
        () => WireError.parse(
          body(
            code: 'NOT_FOUND',
            message: 'x' * (ProtocolLimits.wireMessageMaxBytes + 1),
            retryable: false,
          ),
        ),
        refuses,
      );
    });

    test('refuses a message that is not a string', () {
      expect(
        () => WireError.parse(
          body(code: 'NOT_FOUND', message: 7, retryable: false),
        ),
        refuses,
      );
    });

    test('refuses a request id that is not a canonical UUID', () {
      expect(
        () => WireError.parse(body(requestIdValue: requestId.toUpperCase())),
        refuses,
      );
    });
  });

  group('§11 is pinned', () {
    // The table as written in §11. Kept as data so a changed status on a code fails here
    // rather than in a peer's error handling.
    const Map<int, Set<String>> documented = <int, Set<String>>{
      400: <String>{'INVALID_FIELD', 'INVALID_DECIMAL', 'INVALID_PATH'},
      401: <String>{'PAIR_REJECTED', 'AUTH_EXPIRED', 'RESUME_REJECTED'},
      403: <String>{'DIRECTION_FORBIDDEN'},
      404: <String>{'NOT_FOUND'},
      409: <String>{
        'STALE_LEASE',
        'REQUEST_ID_CONFLICT',
        'SNAPSHOT_EXPIRED',
        'INVALID_STATE',
        'STALE_RESUME_REQUEST',
      },
      410: <String>{'TASK_EXPIRED', 'TASK_CANCELLED'},
      413: <String>{'RESOURCE_LIMIT', 'BODY_TOO_LARGE'},
      422: <String>{
        'MANIFEST_MISMATCH',
        'CHUNK_HASH_MISMATCH',
        'SOURCE_CHANGED',
      },
      429: <String>{'RATE_LIMITED'},
      500: <String>{'STORAGE_SYNC_FAILED', 'DB_COMMIT_FAILED'},
      507: <String>{'SPACE_INSUFFICIENT'},
    };

    test('every code carries the status §11 gives it', () {
      for (final MapEntry<int, Set<String>> entry in documented.entries) {
        for (final String wireCode in entry.value) {
          final ProtocolErrorCode? code = ProtocolErrorCode.fromWireCode(
            wireCode,
          );
          expect(
            code,
            isNotNull,
            reason: '$wireCode is in §11 but not in the enum',
          );
          expect(
            code!.httpStatus,
            entry.key,
            reason: '§11 pairs $wireCode with ${entry.key}',
          );
        }
      }
    });

    test('no code carries a status §11 does not give it', () {
      final Set<String> documentedCodes = <String>{
        for (final Set<String> codes in documented.values) ...codes,
      };
      expect(
        ProtocolErrorCode.values
            .map((ProtocolErrorCode c) => c.wireCode)
            .toSet(),
        documentedCodes,
        reason: 'a status a code invents is a status a peer will not expect',
      );
    });

    test('only the retryable behaviours are marked retryable', () {
      // §11's behaviour column: back off for RATE_LIMITED, and do not confirm the commit
      // for the two 500s. Everything else asks a human or a new identity to intervene.
      const Set<String> retryable = <String>{
        'RATE_LIMITED',
        'STORAGE_SYNC_FAILED',
        'DB_COMMIT_FAILED',
      };
      for (final ProtocolErrorCode code in ProtocolErrorCode.values) {
        expect(
          code.retryable,
          retryable.contains(code.wireCode),
          reason: '${code.wireCode} retryability',
        );
      }
    });

    test('a space-insufficient answer is not retryable and is 507', () {
      expect(ProtocolErrorCode.spaceInsufficient.httpStatus, 507);
      expect(ProtocolErrorCode.spaceInsufficient.retryable, isFalse);
    });
  });

  group('the Authorization header', () {
    test('carries the token', () {
      expect(BearerHeader.parse('Bearer $token'), token);
    });

    test('accepts the scheme in any case', () {
      expect(BearerHeader.parse('bearer $token'), token);
      expect(BearerHeader.parse('BEARER $token'), token);
    });

    test('refuses a missing header', () {
      expect(() => BearerHeader.parse(null), refuses);
    });

    test('refuses another scheme', () {
      expect(() => BearerHeader.parse('Basic $token'), refuses);
    });

    test('refuses an empty token', () {
      expect(() => BearerHeader.parse('Bearer '), refuses);
      expect(() => BearerHeader.parse('Bearer'), refuses);
    });

    test('refuses extra whitespace', () {
      expect(() => BearerHeader.parse('Bearer  $token'), refuses);
      expect(() => BearerHeader.parse('Bearer $token '), refuses);
      expect(() => BearerHeader.parse(' Bearer $token'), refuses);
    });

    test('refuses a token of the wrong length', () {
      expect(
        () => BearerHeader.parse(
          'Bearer ${encodeBase64UrlNoPadding(Uint8List(16))}',
        ),
        refuses,
      );
    });

    test('refuses a padded token', () {
      expect(() => BearerHeader.parse('Bearer $token='), refuses);
    });

    test('refuses a token that is not base64url', () {
      expect(() => BearerHeader.parse('Bearer +${'a' * 42}'), refuses);
    });

    test('isWellFormed answers without throwing', () {
      expect(BearerHeader.isWellFormed('Bearer $token'), isTrue);
      expect(BearerHeader.isWellFormed('Bearer nope'), isFalse);
      expect(BearerHeader.isWellFormed(null), isFalse);
    });
  });

  group('Retry-After', () {
    test('parses whole seconds', () {
      expect(RetryAfterHeader.parse('30'), 30);
      expect(RetryAfterHeader.parse('1'), 1);
      expect(RetryAfterHeader.parse(null), isNull);
    });

    test('refuses anything that is not whole seconds', () {
      expect(() => RetryAfterHeader.parse('30.5'), refuses);
      expect(() => RetryAfterHeader.parse('-1'), refuses);
      expect(() => RetryAfterHeader.parse('+1'), refuses);
      expect(() => RetryAfterHeader.parse(' 30'), refuses);
      expect(() => RetryAfterHeader.parse('soon'), refuses);
    });

    test('refuses the HTTP-date form', () {
      expect(
        () => RetryAfterHeader.parse('Wed, 21 Oct 2026 07:28:00 GMT'),
        refuses,
        reason:
            'an offline device\'s clock is exactly what the protocol declines to trust; '
            'a client that mis-read a date would hammer the peer or wait far too long',
      );
    });

    test('a 429 must carry a usable delay', () {
      expect(
        RetryAfterHeader.requireFor(ProtocolErrorCode.rateLimited, '30'),
        30,
      );
      expect(
        () => RetryAfterHeader.requireFor(ProtocolErrorCode.rateLimited, null),
        refuses,
        reason:
            '§11 makes the backoff the prescribed behaviour, so a limit without a '
            'delay leaves nothing to obey',
      );
      expect(
        () => RetryAfterHeader.requireFor(ProtocolErrorCode.rateLimited, '0'),
        refuses,
      );
    });

    test('no other code carries one', () {
      expect(
        () => RetryAfterHeader.requireFor(ProtocolErrorCode.notFound, '30'),
        refuses,
      );
    });
  });
}
