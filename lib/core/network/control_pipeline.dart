/// §7's request pipeline, up to the endpoint boundary.
///
/// `APP_AND_SERVICE_DESIGN.md` §5 fixes the order:
///
/// > `TLS → pin/会话身份 → 协议版本 → token/任务授权 → request_id 幂等 → 参数/范围验证 →
/// > 用例 → 结构化错误`
///
/// with the rule that "任何环节失败都不执行后续文件操作". Three of those stages are built and
/// two are not, and the difference is stated rather than glossed:
///
/// | Stage | Here? |
/// | --- | --- |
/// | TLS, pin | No. It terminates the connection, so it is the transport's job; this pipeline receives a [ControlRequest] that is already framed. |
/// | 协议版本 | **No.** §3's negotiation belongs with the pairing handshake, and nothing in §7's rows carries a version for the other endpoints. Not modelled rather than invented. |
/// | token/任务授权 | Yes, in [ControlAuthorizer]. |
/// | request_id 幂等 | **No.** §9's `requestId` needs a table of which routes take one and a persisted record; both exist separately but are not wired here. |
/// | 参数/范围验证 | Yes, in `ApiRoutes.match`, which validates every parameter before it returns. |
/// | 用例 | By name: the handler registered for the route. |
/// | 结构化错误 | Yes, in [ControlResponse.error] via `WireError`. |
///
/// ## Why validation happens before authorisation
///
/// §7 requires every parameter to be parsed and validated "先", before use, and the route has
/// to be known before its credential requirement can be looked up. So a malformed target is
/// answered `INVALID_PATH`/`INVALID_FIELD` even when the caller also had no valid token. That
/// leaks nothing: the shape of a path is public, and §7's "统一 404" protects *resources*, not
/// syntax.
///
/// ## Why an unregistered route answers 404
///
/// No endpoint's use-case is implemented yet, so the handler map is empty and every request
/// gets `NOT_FOUND`. That is the same reading `ApiRoutes` already records for an unknown
/// method: §11 has no 405, and the answer declines to confirm which endpoints exist. A
/// half-built server that answered `500` would be telling the peer more than this one does.
library;

import 'package:nearsend/core/network/control_authorization.dart';
import 'package:nearsend/core/network/control_message.dart';
import 'package:nearsend/core/network/task_ownership.dart';
import 'package:nearsend/core/protocol/api_routes.dart';
import 'package:nearsend/core/protocol/protocol_exception.dart';
import 'package:nearsend/core/protocol/protocol_validation.dart';

/// The use-case behind one route.
///
/// Receives the matched request, so it never re-parses a target or re-validates an identifier
/// that the routing stage already checked, and the authorisation result, so it can scope what
/// it does to the credential that was accepted: §9's idempotency scope is
/// "同一任务＋操作＋**当前恢复凭证**", which a handler cannot know on its own.
typedef ControlHandler = Future<ControlResponse> Function(
  ControlRequest request,
  MatchedApiRequest matched,
  ControlAuthorized authorization,
);

/// §7's pipeline: match, authorise, dispatch, and turn every failure into a §7 error body.
class ControlPipeline {
  ControlPipeline({
    required this.authenticator,
    Map<String, ControlHandler> handlers = const <String, ControlHandler>{},
    this.ownership = const NoTaskOwnership(),
    this.now = _systemNowMillis,
  }) : handlers = Map<String, ControlHandler>.unmodifiable(handlers) {
    ControlAuthTable.assertCoversEveryRoute();
  }

  /// Resolves a bearer token to a grant. See [ControlAuthenticator].
  final ControlAuthenticator authenticator;

  /// Which peer owns each transfer, so §7's session-scoped rows can be answered for a session
  /// that is actually bound to the task. Defaults to owning nothing; see [TaskOwnership].
  final TaskOwnership ownership;

  /// The use-case for each route name. A route that is not present answers `NOT_FOUND`.
  final Map<String, ControlHandler> handlers;

  /// Clock injection for token expiry, so a test does not depend on wall time.
  final int Function() now;

  static int _systemNowMillis() => DateTime.now().millisecondsSinceEpoch;

  /// Routes this pipeline serves.
  Set<String> get servedRoutes => handlers.keys.toSet();

  /// Runs the stages and always returns a response.
  ///
  /// Always, on purpose: a pipeline that could throw would push the decision about what to
  /// answer onto the transport, where the §7 error body is not available and the natural
  /// mistake is to close the connection. [ProtocolViolation] carries a §11 code, so it is
  /// answered rather than propagated. An unexpected error is answered as
  /// `DB_COMMIT_FAILED`'s nearest honest §11 code only for *protocol* failures; anything
  /// else is rethrown, because inventing a wire code for a bug would hide it.
  Future<ControlResponse> handle(ControlRequest request) async {
    final String? requestId = _optionalRequestId(request);

    final MatchedApiRequest matched;
    try {
      matched = ApiRoutes.match(method: request.method, target: request.target);
    } on ProtocolViolation catch (violation) {
      return ControlResponse.violation(violation, requestId: requestId);
    }

    final ControlAuthorization decision =
        ControlAuthorizer(authenticator, ownership: ownership).authorize(
          request: request,
          route: matched.route,
          transferId: matched.transferId,
          nowMillis: now(),
        );

    final ControlAuthorized authorization;
    switch (decision) {
      case ControlDenied(:final ProtocolErrorCode code):
        return ControlResponse.error(code, requestId: requestId);
      case ControlAuthorized():
        authorization = decision;
    }

    final ControlHandler? handler = handlers[matched.route.name];
    if (handler == null) {
      return ControlResponse.error(
        ProtocolErrorCode.notFound,
        requestId: requestId,
      );
    }

    try {
      return await handler(request, matched, authorization);
    } on ProtocolViolation catch (violation) {
      return ControlResponse.violation(violation, requestId: requestId);
    }
  }

  /// The `requestId` a request supplied, if any.
  ///
  /// §7 puts `requestId` in the *body* of the routes that take one, and a control body is
  /// JSON. It is read leniently here and only for echoing into an error: a malformed body is
  /// not the routing stage's business, and a route that requires a `requestId` validates it
  /// in its own handler. A body that cannot be read simply yields no requestId.
  String? _optionalRequestId(ControlRequest request) {
    if (request.body.isEmpty) {
      return null;
    }
    try {
      final Object? raw = request.decodeJsonBody()['requestId'];
      if (raw is! String) {
        return null;
      }
      uuidToBytes(raw, 'requestId');
      return raw;
    } on ProtocolViolation {
      return null;
    }
  }
}
