/// The `POST /transfers` request body, `docs/protocol/v1.0-draft1.md` §7.
///
/// §7's row is:
///
/// > `requestId,transferId,manifestDigest,fileCount,totalBytes,direction` →
/// > `201 {transferId,state:STAGING}`；**客户端仅可提议 `client_to_server`**；服务端发送由本地创建
///
/// and §6 says what the call is for: "客户端为发送者：`POST /transfers` 创建 staging 任务".
///
/// ## Why the field types matter here more than usual
///
/// §4 splits the numbers in two, and this body is one of the few that carries both kinds:
/// `totalBytes` is a **byte count** and therefore a decimal string, while `fileCount` is a
/// **JSON integer**. Getting that backwards produces a body that one implementation reads
/// and another refuses, so the two are parsed by different validators and a test asserts
/// that swapping them fails.
///
/// ## What this file does not decide
///
/// [assertClientMayPropose] is separate from parsing. "Is `server_to_client` a direction
/// this protocol defines" and "may a client ask for it" are different questions with
/// different answers, and merging them into one parse would report the second as a syntax
/// error. §7 answers the first with §11's `INVALID_FIELD` and the second with
/// `DIRECTION_FORBIDDEN`.
library;

import 'package:crypto/crypto.dart';

import 'package:nearsend/core/protocol/canonical_writer.dart';
import 'package:nearsend/core/protocol/protocol_exception.dart';
import 'package:nearsend/core/protocol/protocol_limits.dart';
import 'package:nearsend/core/protocol/protocol_validation.dart';
import 'package:nearsend/core/protocol/transfer_direction.dart';

/// A parsed `POST /transfers` body.
class TransferCreationRequest {
  const TransferCreationRequest({
    required this.requestId,
    required this.transferId,
    required this.manifestDigest,
    required this.fileCount,
    required this.totalBytes,
    required this.direction,
  });

  /// Canonical UUID. §9's idempotency key for this operation.
  final String requestId;

  /// Canonical UUID proposed by the client. §7 lists it as a request field, so the client
  /// chooses it rather than the server allocating one.
  final String transferId;

  /// The LFTM1 digest of the manifest that will be staged (§5.2), 64 lowercase hex.
  final String manifestDigest;

  /// A JSON integer (§4).
  final int fileCount;

  /// A byte count, so a decimal string on the wire (§4).
  final int totalBytes;

  final TransferDirection direction;

  static const Set<String> _keys = <String>{
    'requestId',
    'transferId',
    'manifestDigest',
    'fileCount',
    'totalBytes',
    'direction',
  };

  /// Parses and validates the body.
  ///
  /// §5's limits are applied here as well as §4's shapes, because a declaration this build
  /// could never fulfil is a request error rather than something to discover at seal:
  /// `fileCount` over 10,000 or a byte count needing more than 1,048,576 chunks is answered
  /// `RESOURCE_LIMIT`, whose §11 guidance is to shrink the task.
  static TransferCreationRequest parse(Map<String, Object?> json) {
    rejectUnknownKeys(json, _keys, 'the transfer creation request');

    final String requestId = _uuid(
      requireField(json, 'requestId', 'the transfer creation request'),
      'requestId',
    );
    final String transferId = _uuid(
      requireField(json, 'transferId', 'the transfer creation request'),
      'transferId',
    );
    sha256HexToBytes(
      requireField(json, 'manifestDigest', 'the transfer creation request'),
      'manifestDigest',
    );
    final String digest = json['manifestDigest']! as String;

    // A JSON integer, not a decimal string (§4).
    final int fileCount = parseJsonInteger(
      requireField(json, 'fileCount', 'the transfer creation request'),
      'fileCount',
    );
    if (fileCount < 1) {
      throw const ProtocolViolation(
        ProtocolErrorCode.invalidField,
        'fileCount must be at least 1',
      );
    }
    if (fileCount > ProtocolLimits.maxFilesPerTransfer) {
      throw ProtocolViolation(
        ProtocolErrorCode.resourceLimit,
        'fileCount $fileCount is over §5s ${ProtocolLimits.maxFilesPerTransfer} file limit',
      );
    }

    // A byte count, so a decimal string (§4).
    final int totalBytes = parseDecimalString(
      requireField(json, 'totalBytes', 'the transfer creation request'),
      'totalBytes',
    );
    final int chunkCount = totalBytes == 0
        ? 0
        : (totalBytes + ProtocolLimits.chunkSizeBytes - 1) ~/
              ProtocolLimits.chunkSizeBytes;
    if (chunkCount > ProtocolLimits.maxChunksPerTransfer) {
      throw ProtocolViolation(
        ProtocolErrorCode.resourceLimit,
        'totalBytes $totalBytes needs $chunkCount chunks, over §5s '
        '${ProtocolLimits.maxChunksPerTransfer} chunk limit',
      );
    }

    final Object? rawDirection = requireField(
      json,
      'direction',
      'the transfer creation request',
    );
    if (rawDirection is! String) {
      throw const ProtocolViolation(
        ProtocolErrorCode.invalidField,
        'direction must be a string',
      );
    }

    return TransferCreationRequest(
      requestId: requestId,
      transferId: transferId,
      manifestDigest: digest,
      fileCount: fileCount,
      totalBytes: totalBytes,
      direction: TransferDirection.parse(rawDirection),
    );
  }

  /// Refuses a direction a client is not allowed to propose.
  ///
  /// §7: "客户端仅可提议 `client_to_server`；服务端发送由本地创建". A client asking for
  /// `server_to_client` is not sending a malformed request, it is asking for something the
  /// protocol reserves to the local user, so §11's `DIRECTION_FORBIDDEN` (403, "终止错误操作")
  /// is the answer rather than `INVALID_FIELD`.
  void assertClientMayPropose() {
    if (direction != TransferDirection.clientProposable) {
      throw ProtocolViolation(
        ProtocolErrorCode.directionForbidden,
        'a client may only propose ${TransferDirection.clientProposable.wireValue}, not '
        '${direction.wireValue}; §7 creates server-sent transfers locally',
      );
    }
  }

  /// The digest §9's idempotency record stores, so the same `requestId` carrying different
  /// parameters is detectable.
  ///
  /// Built from the **parsed** fields in a fixed order rather than from the raw body bytes.
  /// Two bodies that mean the same thing but differ in key order or whitespace are the same
  /// request, and a retry that reordered its keys must replay rather than be refused as a
  /// conflict. The fields are written at fixed widths by [CanonicalWriter], so no separator
  /// is needed and no concatenation of variable-length values can be ambiguous.
  ///
  /// `requestId` is deliberately absent: it is the key this digest is stored under, not a
  /// parameter of the request.
  String get requestDigest {
    final CanonicalWriter writer = CanonicalWriter();
    writer.raw(uuidToBytes(transferId, 'transferId'));
    writer.raw(sha256HexToBytes(manifestDigest, 'manifestDigest'));
    writer.u64(fileCount);
    writer.u64(totalBytes);
    // Written from the wire value rather than the enum's index, so reordering the enum
    // cannot silently change a stored digest and make every retry look like a conflict.
    writer.u8(direction == TransferDirection.clientToServer ? 1 : 2);
    return sha256.convert(writer.toBytes()).toString();
  }

  @override
  String toString() =>
      'TransferCreationRequest($transferId, ${direction.wireValue}, '
      '$fileCount files, $totalBytes bytes)';

  static String _uuid(Object? value, String field) {
    uuidToBytes(value, field);
    return value! as String;
  }
}
