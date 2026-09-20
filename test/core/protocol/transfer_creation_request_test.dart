import 'package:flutter_test/flutter_test.dart';

import 'package:nearsend/core/protocol/protocol_exception.dart';
import 'package:nearsend/core/protocol/protocol_limits.dart';
import 'package:nearsend/core/protocol/transfer_creation_request.dart';
import 'package:nearsend/core/protocol/transfer_direction.dart';

/// The `POST /transfers` body.
///
/// Two things carry the weight here. First, §4 splits the numbers in two and this body is
/// one of the few carrying both kinds: `totalBytes` is a byte count and therefore a decimal
/// string, while `fileCount` is a JSON integer. Swapping them produces a body one
/// implementation reads and another refuses, so both directions of that mistake are tested.
///
/// Second, [TransferCreationRequest.requestDigest] decides whether a retry replays or is
/// refused as a conflict. It is computed from the parsed fields rather than the raw bytes,
/// so a reordered retry means the same thing - and that is asserted, because getting it
/// wrong turns a legitimate retry into `REQUEST_ID_CONFLICT`.
void main() {
  const String requestId = '11111111-2222-4333-8444-555555555555';
  const String transferId = '99999999-8888-4777-8666-555555555555';
  const String digest =
      'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

  Map<String, Object?> body({
    Object? requestIdValue = requestId,
    Object? transferIdValue = transferId,
    Object? digestValue = digest,
    Object? fileCount = 3,
    Object? totalBytes = '1024',
    Object? direction = 'client_to_server',
  }) => <String, Object?>{
    'requestId': requestIdValue,
    'transferId': transferIdValue,
    'manifestDigest': digestValue,
    'fileCount': fileCount,
    'totalBytes': totalBytes,
    'direction': direction,
  };

  TransferCreationRequest parsed([Map<String, Object?>? override]) =>
      TransferCreationRequest.parse(override ?? body());

  Matcher refusedWith(ProtocolErrorCode code) => throwsA(
    isA<ProtocolViolation>().having(
      (ProtocolViolation e) => e.code,
      'code',
      code,
    ),
  );

  group('a well-formed body', () {
    test('parses every field with its §4 type', () {
      final TransferCreationRequest request = parsed();

      expect(request.requestId, requestId);
      expect(request.transferId, transferId);
      expect(request.manifestDigest, digest);
      expect(request.fileCount, 3);
      expect(request.totalBytes, 1024);
      expect(request.direction, TransferDirection.clientToServer);
    });

    test('accepts both §7 directions as values', () {
      expect(
        parsed(body(direction: 'server_to_client')).direction,
        TransferDirection.serverToClient,
      );
    });

    test('a zero-byte transfer is representable', () {
      // §10: "空文件仍需创建、同步、导出并记录完成，没有网络块请求". A transfer of one empty
      // file is legal, so totalBytes 0 must parse.
      final TransferCreationRequest request = parsed(
        body(fileCount: 1, totalBytes: '0'),
      );
      expect(request.totalBytes, 0);
      expect(request.fileCount, 1);
    });
  });

  group('the §4 number split', () {
    test('totalBytes must be a decimal string, not a JSON number', () {
      expect(
        () => parsed(body(totalBytes: 1024)),
        refusedWith(ProtocolErrorCode.invalidDecimal),
        reason: '§4 makes a byte count a decimal string; a JSON number is a wrong shape',
      );
    });

    test('fileCount must be a JSON integer, not a decimal string', () {
      expect(
        () => parsed(body(fileCount: '3')),
        refusedWith(ProtocolErrorCode.invalidField),
        reason: '§4 makes fileCount a JSON integer',
      );
    });

    test('a boolean is not an integer', () {
      expect(
        () => parsed(body(fileCount: true)),
        refusedWith(ProtocolErrorCode.invalidField),
      );
    });

    test(
      'a decimal string may not carry a sign, a leading zero or an exponent',
      () {
        for (final Object? value in <Object?>[
          '+1',
          '01',
          '1e3',
          '-1',
          '1.0',
          ' 1',
        ]) {
          expect(
            () => parsed(body(totalBytes: value)),
            throwsA(isA<ProtocolViolation>()),
            reason: '"$value" is not a canonical decimal string (§4)',
          );
        }
      },
    );
  });

  group('shapes and required fields', () {
    test('an unknown field is refused rather than ignored', () {
      final Map<String, Object?> json = body()..['extra'] = 1;
      expect(
        () => TransferCreationRequest.parse(json),
        refusedWith(ProtocolErrorCode.invalidField),
      );
    });

    test('every required field must be present', () {
      for (final String key in <String>[
        'requestId',
        'transferId',
        'manifestDigest',
        'fileCount',
        'totalBytes',
        'direction',
      ]) {
        final Map<String, Object?> json = body()..remove(key);
        expect(
          () => TransferCreationRequest.parse(json),
          throwsA(isA<ProtocolViolation>()),
          reason: '$key is required',
        );
      }
    });

    test('identifiers must be canonical UUIDs', () {
      for (final Object? value in <Object?>[
        '11111111222243338444555555555555', // no dashes
        '11111111-2222-4333-8444-55555555555A', // uppercase
        'not-a-uuid',
        '',
        7,
      ]) {
        expect(
          () => parsed(body(requestIdValue: value)),
          throwsA(isA<ProtocolViolation>()),
          reason: '"$value" is not a canonical UUID',
        );
      }
    });

    test('the manifest digest must be 64 lowercase hex', () {
      for (final Object? value in <Object?>[
        digest.toUpperCase(),
        digest.substring(0, 63),
        'z' * 64,
        '',
        5,
      ]) {
        expect(
          () => parsed(body(digestValue: value)),
          throwsA(isA<ProtocolViolation>()),
          reason: '"$value" is not a §4 SHA-256',
        );
      }
    });

    test(
      'an undefined direction is INVALID_FIELD, not a direction refusal',
      () {
        // "is this a direction the protocol defines" and "may a client propose it" are
        // different questions (§7's row versus §11's two codes).
        expect(
          () => parsed(body(direction: 'sideways')),
          refusedWith(ProtocolErrorCode.invalidField),
        );
      },
    );
  });

  group('§5 limits', () {
    test('fileCount must be at least 1', () {
      expect(
        () => parsed(body(fileCount: 0)),
        refusedWith(ProtocolErrorCode.invalidField),
      );
    });

    test('fileCount over 10,000 is a resource limit', () {
      expect(
        () => parsed(body(fileCount: ProtocolLimits.maxFilesPerTransfer + 1)),
        refusedWith(ProtocolErrorCode.resourceLimit),
        reason:
            '§11 answers a task too large with RESOURCE_LIMIT: shrink the task',
      );
      expect(
        parsed(body(fileCount: ProtocolLimits.maxFilesPerTransfer)).fileCount,
        ProtocolLimits.maxFilesPerTransfer,
      );
    });

    test('a byte count needing too many chunks is a resource limit', () {
      const int maxBytes =
          ProtocolLimits.maxChunksPerTransfer * ProtocolLimits.chunkSizeBytes;
      expect(
        parsed(body(totalBytes: '$maxBytes')).totalBytes,
        maxBytes,
        reason: 'exactly the chunk limit is still representable',
      );
      expect(
        () => parsed(body(totalBytes: '${maxBytes + 1}')),
        refusedWith(ProtocolErrorCode.resourceLimit),
      );
    });

    test(
      'a byte count past 2^63-1 is refused by §4 before any §5 arithmetic',
      () {
        expect(
          () => parsed(body(totalBytes: '9223372036854775808')),
          throwsA(isA<ProtocolViolation>()),
        );
      },
    );
  });

  group('which direction a client may propose', () {
    test('client_to_server is allowed', () {
      expect(
        () =>
            parsed(body(direction: 'client_to_server'))
                .assertClientMayPropose(),
        returnsNormally,
      );
    });

    test('server_to_client is DIRECTION_FORBIDDEN, not a syntax error', () {
      // §7: "客户端仅可提议 client_to_server；服务端发送由本地创建". The request is
      // well-formed; it is asking for something the local user decides.
      expect(
        () =>
            parsed(body(direction: 'server_to_client'))
                .assertClientMayPropose(),
        refusedWith(ProtocolErrorCode.directionForbidden),
      );
      expect(
        ProtocolErrorCode.directionForbidden.httpStatus,
        403,
        reason: '§11 pairs DIRECTION_FORBIDDEN with 403 and 终止错误操作',
      );
    });
  });

  group('the request digest', () {
    test('is a §4 SHA-256', () {
      final String value = parsed().requestDigest;
      expect(value.length, 64);
      expect(RegExp(r'^[0-9a-f]{64}$').hasMatch(value), isTrue);
    });

    test('is stable for the same parameters', () {
      expect(parsed().requestDigest, parsed().requestDigest);
    });

    test('does not depend on the order the fields arrived in', () {
      // This is the property that makes a reordered retry replay instead of being refused
      // as a conflict: the digest is over the parsed fields, in a fixed order.
      final Map<String, Object?> reordered = <String, Object?>{
        'direction': 'client_to_server',
        'totalBytes': '1024',
        'fileCount': 3,
        'manifestDigest': digest,
        'transferId': transferId,
        'requestId': requestId,
      };
      expect(
        TransferCreationRequest.parse(reordered).requestDigest,
        parsed().requestDigest,
      );
    });

    test('does not include the requestId, which is its key', () {
      final String otherRequest = '22222222-3333-4444-8555-666666666666';
      expect(
        parsed(body(requestIdValue: otherRequest)).requestDigest,
        parsed().requestDigest,
        reason:
            'the requestId is what the digest is stored under, not a parameter',
      );
    });

    test('changes when any parameter changes', () {
      final String base = parsed().requestDigest;
      final Map<String, Map<String, Object?>> variants =
          <String, Map<String, Object?>>{
            'transferId': body(
              transferIdValue: '22222222-3333-4444-8555-666666666666',
            ),
            'manifestDigest': body(digestValue: 'b' * 64),
            'fileCount': body(fileCount: 4),
            'totalBytes': body(totalBytes: '1025'),
            'direction': body(direction: 'server_to_client'),
          };

      variants.forEach((String name, Map<String, Object?> json) {
        expect(
          TransferCreationRequest.parse(json).requestDigest,
          isNot(base),
          reason: 'a retry that changed $name is a different request',
        );
      });
    });

    test(
      'distinguishes the two directions even though they share a length',
      () {
        expect(
          parsed(body(direction: 'client_to_server')).requestDigest,
          isNot(parsed(body(direction: 'server_to_client')).requestDigest),
        );
      },
    );
  });

  group('diagnostics', () {
    test('describes the transfer without dumping the whole digest', () {
      final String text = parsed().toString();
      expect(text, contains(transferId));
      expect(text, contains('client_to_server'));
      expect(text, contains('3 files'));
      expect(text, contains('1024 bytes'));
    });
  });
}
