/// The `POST /transfers/{id}/decision` body, `docs/protocol/v1.0-draft1.md` §7.
///
/// §7's row:
///
/// > `POST /transfers/{id}/decision` | `requestId,manifestDigest,decision:accept或reject` |
/// > `200 {state}`；**仅客户端接收者调用**；server 接收者本地决定
///
/// §6 says what accepting commits to:
///
/// > 只有接收方能接受……批准清单摘要、保存位置以及空间估算一起持久化；路径或身份变化需要重新确认。
///
/// ## Why the body carries only three fields
///
/// The save location and the space estimate are named by §6 as part of the approval, but §7's
/// request row does **not** carry them. `AGENTS.md` §3 forbids inventing protocol fields, so
/// they are not added here. What that means in practice is that they are the *decider's* facts:
/// whoever runs the decision - the server for `client_to_server`, the client for
/// `server_to_client` - records its own save location and its own space estimate. That is also
/// the only honest arrangement, because a remote peer cannot report what it measured on a
/// volume belonging to somebody else.
library;

import 'package:crypto/crypto.dart';

import 'package:nearsend/core/protocol/canonical_writer.dart';
import 'package:nearsend/core/protocol/protocol_exception.dart';
import 'package:nearsend/core/protocol/protocol_validation.dart';

/// §7's `decision` value.
enum TransferDecisionChoice {
  accept('accept'),
  reject('reject');

  const TransferDecisionChoice(this.wireValue);

  final String wireValue;

  /// Parses the wire value, refusing anything §7 does not define.
  static TransferDecisionChoice parse(Object? value) {
    for (final TransferDecisionChoice choice in TransferDecisionChoice.values) {
      if (choice.wireValue == value) {
        return choice;
      }
    }
    throw const ProtocolViolation(
      ProtocolErrorCode.invalidField,
      'decision must be accept or reject',
    );
  }
}

/// A parsed `POST /transfers/{id}/decision` body.
class TaskDecisionRequest {
  const TaskDecisionRequest({
    required this.requestId,
    required this.manifestDigest,
    required this.choice,
  });

  /// Canonical UUID. §9's idempotency key for this operation.
  final String requestId;

  /// The digest the receiver is approving or rejecting (§5.2), 64 lowercase hex.
  final String manifestDigest;

  final TransferDecisionChoice choice;

  bool get isAccept => choice == TransferDecisionChoice.accept;

  static const Set<String> _keys = <String>{
    'requestId',
    'manifestDigest',
    'decision',
  };

  /// Parses and validates the body.
  static TaskDecisionRequest parse(Map<String, Object?> json) {
    rejectUnknownKeys(json, _keys, 'the decision request');

    final Object? requestId = requireField(
      json,
      'requestId',
      'the decision request',
    );
    uuidToBytes(requestId, 'requestId');

    final Object? digest = requireField(
      json,
      'manifestDigest',
      'the decision request',
    );
    sha256HexToBytes(digest, 'manifestDigest');

    return TaskDecisionRequest(
      requestId: requestId! as String,
      manifestDigest: digest! as String,
      choice: TransferDecisionChoice.parse(json['decision']),
    );
  }

  /// The digest §9's idempotency record stores.
  ///
  /// Built from the parsed fields through the shared [CanonicalWriter] rather than from the raw
  /// bytes, so a retry that reordered its keys is the same request. `requestId` is absent
  /// because it is the key this digest is stored under.
  String get requestDigest {
    final CanonicalWriter writer = CanonicalWriter();
    writer.raw(sha256HexToBytes(manifestDigest, 'manifestDigest'));
    writer.u8(choice == TransferDecisionChoice.accept ? 1 : 0);
    return sha256.convert(writer.toBytes()).toString();
  }

  @override
  String toString() =>
      'TaskDecisionRequest($requestId, ${choice.wireValue}, $manifestDigest)';
}
