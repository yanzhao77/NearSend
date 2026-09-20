/// The `POST /transfers/{id}/seal` body, `docs/protocol/v1.0-draft1.md` §7.
///
/// §7's row:
///
/// > `POST /transfers/{id}/seal` | `requestId,manifestDigest` | `200 {state:WAITING_ACCEPT}`，
/// > 摘要失败 `422`
///
/// and §6 says what the call concludes:
///
/// > 缺页、重复 fileId、块数量/长度错误、总摘要不一致时 seal 失败，**不能进入 WAITING_ACCEPT**。
///
/// The digest here is the one the client believes it uploaded. The staging holds the digest
/// the transfer was created with (§7's `POST /transfers`), so a client that seals against a
/// different manifest is refused rather than having its own claim taken as the truth.
library;

import 'package:crypto/crypto.dart';

import 'package:nearsend/core/protocol/canonical_writer.dart';
import 'package:nearsend/core/protocol/protocol_validation.dart';

/// A parsed `POST /transfers/{id}/seal` body.
class TransferSealRequest {
  const TransferSealRequest({
    required this.requestId,
    required this.manifestDigest,
  });

  /// Canonical UUID. §9's idempotency key for this operation, and the reason a client whose
  /// response was lost can retry without risking a second seal.
  final String requestId;

  /// The LFTM1 digest of the manifest being sealed (§5.2), 64 lowercase hex.
  final String manifestDigest;

  static const Set<String> _keys = <String>{'requestId', 'manifestDigest'};

  /// Parses and validates the body.
  static TransferSealRequest parse(Map<String, Object?> json) {
    rejectUnknownKeys(json, _keys, 'the seal request');

    final Object? requestId = requireField(
      json,
      'requestId',
      'the seal request',
    );
    uuidToBytes(requestId, 'requestId');

    final Object? digest = requireField(
      json,
      'manifestDigest',
      'the seal request',
    );
    sha256HexToBytes(digest, 'manifestDigest');

    return TransferSealRequest(
      requestId: requestId! as String,
      manifestDigest: digest! as String,
    );
  }

  /// The digest §9's idempotency record stores.
  ///
  /// Built from the parsed field through the shared [CanonicalWriter] rather than from the
  /// raw bytes, so a retry that reordered its keys or added whitespace is the same request.
  /// `requestId` is absent because it is the key this digest is stored under.
  String get requestDigest {
    final CanonicalWriter writer = CanonicalWriter();
    writer.raw(sha256HexToBytes(manifestDigest, 'manifestDigest'));
    return sha256.convert(writer.toBytes()).toString();
  }

  @override
  String toString() => 'TransferSealRequest($requestId, $manifestDigest)';
}
