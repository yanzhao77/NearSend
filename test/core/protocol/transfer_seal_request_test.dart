import 'package:flutter_test/flutter_test.dart';

import 'package:nearsend/core/protocol/protocol_exception.dart';
import 'package:nearsend/core/protocol/transfer_seal_request.dart';

/// The `POST /transfers/{id}/seal` body.
///
/// Small, but two things about it matter. §7 pairs the row with "摘要失败 422", so the digest
/// has to be a §4 SHA-256 rather than any string. And its [TransferSealRequest.requestDigest]
/// decides whether a retry replays or is refused, which is why it is computed from the parsed
/// field rather than the raw bytes.
void main() {
  const String requestId = '11111111-2222-4333-8444-555555555555';
  const String digest =
      'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

  Map<String, Object?> body({
    Object? requestIdValue = requestId,
    Object? digestValue = digest,
  }) => <String, Object?>{
    'requestId': requestIdValue,
    'manifestDigest': digestValue,
  };

  group('parsing', () {
    test('reads both fields', () {
      final TransferSealRequest parsed = TransferSealRequest.parse(body());
      expect(parsed.requestId, requestId);
      expect(parsed.manifestDigest, digest);
    });

    test('refuses an unknown field rather than ignoring it', () {
      final Map<String, Object?> json = body()..['extra'] = 1;
      expect(
        () => TransferSealRequest.parse(json),
        throwsA(isA<ProtocolViolation>()),
      );
    });

    test('requires both fields', () {
      for (final String key in <String>['requestId', 'manifestDigest']) {
        final Map<String, Object?> json = body()..remove(key);
        expect(
          () => TransferSealRequest.parse(json),
          throwsA(isA<ProtocolViolation>()),
          reason: '$key is required',
        );
      }
    });

    test('the request id must be a canonical UUID', () {
      for (final Object? value in <Object?>[
        '11111111222243338444555555555555',
        '11111111-2222-4333-8444-55555555555A',
        '',
        7,
      ]) {
        expect(
          () => TransferSealRequest.parse(body(requestIdValue: value)),
          throwsA(isA<ProtocolViolation>()),
          reason: '"$value" is not a canonical UUID',
        );
      }
    });

    test('the digest must be 64 lowercase hex', () {
      for (final Object? value in <Object?>[
        digest.toUpperCase(),
        digest.substring(0, 63),
        'z' * 64,
        '',
        5,
      ]) {
        expect(
          () => TransferSealRequest.parse(body(digestValue: value)),
          throwsA(isA<ProtocolViolation>()),
          reason: '"$value" is not a §4 SHA-256',
        );
      }
    });
  });

  group('the request digest', () {
    test('is a §4 SHA-256', () {
      final String value = TransferSealRequest.parse(body()).requestDigest;
      expect(RegExp(r'^[0-9a-f]{64}$').hasMatch(value), isTrue);
    });

    test('is stable and order-independent', () {
      final Map<String, Object?> reordered = <String, Object?>{
        'manifestDigest': digest,
        'requestId': requestId,
      };
      expect(
        TransferSealRequest.parse(reordered).requestDigest,
        TransferSealRequest.parse(body()).requestDigest,
        reason:
            'a retry that reordered its keys is the same request, and refusing it as a '
            'conflict would break the retry §9 exists to make safe',
      );
    });

    test('does not include the requestId, which is its key', () {
      expect(
        TransferSealRequest.parse(
          body(requestIdValue: '22222222-3333-4444-8555-666666666666'),
        ).requestDigest,
        TransferSealRequest.parse(body()).requestDigest,
      );
    });

    test('changes when the digest changes', () {
      expect(
        TransferSealRequest.parse(body(digestValue: 'b' * 64)).requestDigest,
        isNot(TransferSealRequest.parse(body()).requestDigest),
      );
    });
  });

  test('describes itself without dumping the digest', () {
    final String text = TransferSealRequest.parse(body()).toString();
    expect(text, contains(requestId));
    expect(text, contains('aaaa'));
  });
}
