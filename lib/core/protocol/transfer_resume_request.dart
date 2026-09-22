/// The `POST /transfers/{id}/resume` body, `docs/protocol/v1.0-draft1.md` §7 and §9.
///
/// §7's row:
///
/// > `POST /transfers/{id}/resume` | `requestId,manifestDigest,taskResumeSecret,receiverState?` |
/// > `202 {state:CHECKING_RESUME}` 或 `200 {taskAccessToken,expiresInSeconds:1800,leaseEpoch,
/// > checkpointSeq,state}`；**client 接收时必带已恢复的 receiverState**
///
/// §9 fixes the meaning of the optional part:
///
/// > client 接收者：先在本地持久化新 epoch、复核断点，再提交
/// > `receiverState={leaseEpoch,checkpointSeq,committedBytes}`；发送者验证**不回退**并更新镜像。
/// > **恢复只以接收端已经持久化的 committed 块与 checkpoint 为准**；发送端记录始终是镜像。
///
/// ## What `receiverState` is for, and what it is not
///
/// It exists so the sender can notice that its mirror is ahead of the receiver's truth and stop
/// reporting a figure the receiver does not have. It is therefore **read as a claim to compare,
/// never as a fact to store**: `AGENTS.md` §2 rule 8 makes the receiver's committed rows the
/// only authority, so nothing here may overwrite a sender-side record with what arrived.
library;

import 'package:crypto/crypto.dart';

import 'package:nearsend/core/protocol/base64url.dart';
import 'package:nearsend/core/protocol/canonical_writer.dart';
import 'package:nearsend/core/protocol/protocol_exception.dart';
import 'package:nearsend/core/protocol/protocol_limits.dart';
import 'package:nearsend/core/protocol/protocol_validation.dart';

/// The receiver's own durable position, as §9 defines it.
class ReceiverState {
  const ReceiverState({
    required this.leaseEpoch,
    required this.checkpointSeq,
    required this.committedBytes,
  });

  /// The write generation the receiver has persisted.
  final int leaseEpoch;

  /// The receiver's last committed checkpoint sequence.
  final int checkpointSeq;

  /// Committed bytes, for the sender's display mirror only.
  final int committedBytes;

  static const Set<String> _keys = <String>{
    'leaseEpoch',
    'checkpointSeq',
    'committedBytes',
  };

  Map<String, Object?> toJson() => <String, Object?>{
    'leaseEpoch': encodeDecimalString(leaseEpoch, 'leaseEpoch'),
    'checkpointSeq': encodeDecimalString(checkpointSeq, 'checkpointSeq'),
    'committedBytes': encodeDecimalString(committedBytes, 'committedBytes'),
  };

  static ReceiverState parse(Object? value) {
    if (value is! Map) {
      throw const ProtocolViolation(
        ProtocolErrorCode.invalidField,
        'receiverState must be an object',
      );
    }
    final Map<String, Object?> json = value.cast<String, Object?>();
    rejectUnknownKeys(json, _keys, 'receiverState');
    return ReceiverState(
      leaseEpoch: parseDecimalString(
        requireField(json, 'leaseEpoch', 'receiverState'),
        'receiverState.leaseEpoch',
      ),
      checkpointSeq: parseDecimalString(
        requireField(json, 'checkpointSeq', 'receiverState'),
        'receiverState.checkpointSeq',
      ),
      committedBytes: parseDecimalString(
        requireField(json, 'committedBytes', 'receiverState'),
        'receiverState.committedBytes',
      ),
    );
  }

  @override
  String toString() =>
      'ReceiverState(epoch $leaseEpoch, seq $checkpointSeq, $committedBytes B)';
}

/// A parsed `POST /transfers/{id}/resume` body.
class TransferResumeRequest {
  const TransferResumeRequest({
    required this.requestId,
    required this.manifestDigest,
    required this.taskResumeSecret,
    this.receiverState,
  });

  /// Canonical UUID. §9's idempotency key for this operation, and the reason a repeated resume
  /// does not allocate a second generation.
  final String requestId;

  /// The digest the task was sealed with.
  final String manifestDigest;

  /// §3's per-task recovery secret. Travels in the body because §7 says so, and is never
  /// rendered by [toString].
  final String taskResumeSecret;

  /// Present only when the caller is the client receiver (§7's "client 接收时必带").
  final ReceiverState? receiverState;

  static const Set<String> _keys = <String>{
    'requestId',
    'manifestDigest',
    'taskResumeSecret',
    'receiverState',
  };

  /// Parses and validates the body.
  static TransferResumeRequest parse(Map<String, Object?> json) {
    rejectUnknownKeys(json, _keys, 'the resume request');

    final Object? requestId = requireField(
      json,
      'requestId',
      'the resume request',
    );
    uuidToBytes(requestId, 'requestId');

    final Object? digest = requireField(
      json,
      'manifestDigest',
      'the resume request',
    );
    sha256HexToBytes(digest, 'manifestDigest');

    final Object? secret = requireField(
      json,
      'taskResumeSecret',
      'the resume request',
    );
    // §2 and §3 make every task secret a 32-byte value in §4's canonical unpadded base64url.
    // Checking the shape here means a malformed secret is refused as a bad request rather than
    // silently failing to match a stored digest.
    decodeBase64UrlNoPaddingExact(
      secret,
      'taskResumeSecret',
      expectedBytes: ProtocolLimits.accessTokenBytes,
    );

    return TransferResumeRequest(
      requestId: requestId! as String,
      manifestDigest: digest! as String,
      taskResumeSecret: secret! as String,
      receiverState: json.containsKey('receiverState')
          ? ReceiverState.parse(json['receiverState'])
          : null,
    );
  }

  /// The digest §9's idempotency record stores.
  ///
  /// The secret is deliberately **not** part of it: §9 scopes a request id to the credential in
  /// force, and that scope is applied separately as a fingerprint, so including the secret
  /// here would store a second copy of a value `AGENTS.md` §5 keeps out of ordinary storage.
  String get requestDigest {
    final CanonicalWriter writer = CanonicalWriter();
    writer.raw(sha256HexToBytes(manifestDigest, 'manifestDigest'));
    return sha256.convert(writer.toBytes()).toString();
  }

  @override
  String toString() =>
      'TransferResumeRequest($requestId, $manifestDigest, secret not rendered)';
}

/// The `POST /transfers/{id}/authorization/receipt` body, §7.
///
/// > `POST /transfers/{id}/authorization/receipt` | `requestId` | `200 {stored:true}`，
/// > 确认客户端已安全保存凭证
class AuthorizationReceiptRequest {
  const AuthorizationReceiptRequest({required this.requestId});

  /// Canonical UUID. §9's idempotency key for this operation.
  final String requestId;

  static const Set<String> _keys = <String>{'requestId'};

  static AuthorizationReceiptRequest parse(Map<String, Object?> json) {
    rejectUnknownKeys(json, _keys, 'the authorization receipt');
    final Object? requestId = requireField(
      json,
      'requestId',
      'the authorization receipt',
    );
    uuidToBytes(requestId, 'requestId');
    return AuthorizationReceiptRequest(requestId: requestId! as String);
  }

  /// A receipt carries no parameters, so its digest is over the empty sequence.
  ///
  /// §9 still requires a digest: without one, "same id, different parameters" could not be
  /// distinguished from a replay, and this endpoint's only parameter is its request id.
  String get requestDigest => sha256.convert(const <int>[]).toString();

  @override
  String toString() => 'AuthorizationReceiptRequest($requestId)';
}
