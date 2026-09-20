/// The transfer direction, as §7 spells it on the wire.
///
/// §7 uses exactly two values. `POST /transfers` carries `direction` as a request field and
/// fixes who may propose which one: "客户端仅可提议 client_to_server；服务端发送由本地创建".
/// The chunk endpoints then depend on it: `PUT .../chunks/{index}` is "仅 client_to_server"
/// and `GET .../chunks/{index}` is "仅 server_to_client".
///
/// That last part is why this is a type rather than a string. `AGENTS.md` §5 requires every
/// file request to verify "任务授权、**操作方向**、文件 ID、块编号、长度、偏移范围、
/// lease_epoch 和摘要" before anything else, and a direction that is a bare `String` cannot be
/// checked exhaustively: a typo in a comparison, or a third value arriving from somewhere,
/// compiles and compares unequal without anything noticing.
///
/// **Reading note.** The names are the direction *of the data*, not of the request: in
/// `client_to_server` the client sends and the server receives, which is why the same
/// direction permits a chunk `PUT` and forbids a chunk `GET`. The two endpoints are not
/// symmetric views of one value; they are opposite halves of it.
library;

import 'package:nearsend/core/protocol/protocol_exception.dart';

/// Who sends and who receives for one transfer (§7).
enum TransferDirection {
  /// The client sends and the server receives. The only direction a client may propose.
  clientToServer('client_to_server'),

  /// The server sends and the client receives.
  serverToClient('server_to_client');

  const TransferDirection(this.wireValue);

  final String wireValue;

  /// The direction a client is allowed to propose (§7's `POST /transfers` row).
  static const TransferDirection clientProposable = clientToServer;

  /// Parses a wire value, refusing anything §7 does not define.
  ///
  /// Returns null rather than defaulting, so a caller has to decide what an unknown value
  /// means instead of silently getting one of the two.
  static TransferDirection? fromWireValue(String value) {
    for (final TransferDirection direction in TransferDirection.values) {
      if (direction.wireValue == value) {
        return direction;
      }
    }
    return null;
  }

  /// Parses a wire value, throwing when it is not one §7 defines.
  static TransferDirection parse(String value, [String scope = 'direction']) {
    final TransferDirection? direction = fromWireValue(value);
    if (direction == null) {
      throw ProtocolViolation(
        ProtocolErrorCode.invalidField,
        '$scope must be ${TransferDirection.values.map((TransferDirection d) => d.wireValue).join(' or ')}',
      );
    }
    return direction;
  }

  /// The direction whose sender is this one's receiver.
  TransferDirection get opposite =>
      this == clientToServer ? serverToClient : clientToServer;

  /// Whether a peer in this direction may `PUT` a chunk (the sender writes).
  bool get permitsChunkUpload => this == clientToServer;

  /// Whether a peer in this direction may `GET` a chunk (the receiver pulls).
  bool get permitsChunkDownload => this == serverToClient;

  @override
  String toString() => wireValue;
}
