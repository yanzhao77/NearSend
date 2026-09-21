/// What §7 requires of a caller before an endpoint runs.
///
/// ## The rules being implemented
///
/// §7 opens with:
///
/// > 所有 ID 参数须先解析校验。**除 pair 外均需要有效 Bearer**，resume 使用
/// > taskResumeSecret 专用请求体；初次 resume 无须旧会话令牌。**任务查询对无权限资源统一
/// > 404**。
///
/// Three separate things live in that sentence, and conflating them is the usual mistake:
///
/// 1. **Which credential a route needs.** `/v1/pair` is the stated exception, and the resume
///    row names a second one: its secret travels in the request body and "初次 resume 无须旧
///    会话令牌", so demanding a bearer there would refuse the very first resume.
/// 2. **What a credential is scoped to.** A session identity can reach any transfer that
///    session is authorised for; a task access token is bound to one transfer.
/// 3. **What to answer when the credential is not good enough.** A missing, malformed,
///    unknown or expired token is a `401`. A *valid* token used for a transfer it does not
///    cover is deliberately indistinguishable from a transfer that does not exist: §7 says
///    "统一 404", so an attacker cannot use the status to enumerate transfer ids.
///
/// `AGENTS.md` §5 adds a fourth, for file requests specifically: "所有文件请求先验证任务授权、
/// **操作方向**、文件 ID、块编号、长度、偏移范围、`lease_epoch` 和摘要". The direction check is
/// therefore mandatory, not an extra: a chunk `PUT` belongs to `client_to_server` and a chunk
/// `GET` to `server_to_client` (§7), and answering the wrong direction with data would be
/// worse than refusing it.
///
/// ## What this file does not do
///
/// It does not issue or store credentials. §3's tokens are issued by the pairing and resume
/// endpoints; this is only the port that asks whether one is currently valid, so the
/// decision can be tested without a token store and the store can be swapped without the
/// decision changing.
library;

import 'package:nearsend/core/network/control_message.dart';
import 'package:nearsend/core/network/task_ownership.dart';
import 'package:nearsend/core/protocol/api_routes.dart';
import 'package:nearsend/core/protocol/protocol_exception.dart';
import 'package:nearsend/core/protocol/transfer_direction.dart';
import 'package:nearsend/core/security/credential_fingerprint.dart';

/// The credential §7 requires before a route runs.
enum ControlCredential {
  /// No credential. §7's stated exception, `/v1/pair`: the pairing token is in the body and
  /// is the thing being verified.
  none,

  /// A bearer token belonging to a session identity, not bound to one transfer.
  ///
  /// §7's `offers` row says "会话身份" and the `authorization` row "已授权会话".
  session,

  /// A bearer token bound to the transfer named in the path.
  transferTask,

  /// A session identity or a task token for the transfer named in the path.
  ///
  /// §7's `status` row: "会话、任务令牌或受限完成查询令牌".
  sessionOrTransferTask,

  /// The resume secret travels in the **request body**, and a first resume carries no token
  /// at all (§7's `resume` row).
  ///
  /// The pipeline does not demand a bearer here and does not validate the secret: it has no
  /// issuer to check it against yet, and §9 makes the *original server* the verifier. What
  /// this value records is that the route is not anonymous, so a future reader cannot
  /// mistake it for one.
  resumeBodySecret,
}

/// The kinds of thing a valid bearer token can turn out to be.
enum ControlGrantKind {
  /// A paired session, which may act for any transfer it is authorised for.
  session,

  /// One transfer's write generation holder.
  task,

  /// §7's restricted completion-query credential, which may only read a finished task's
  /// result and never its contents.
  completionQuery,
}

/// What a valid credential grants.
sealed class ControlGrant {
  const ControlGrant();

  ControlGrantKind get kind;

  /// The transfer this grant is limited to, or null when it is not transfer-scoped.
  String? get transferId => null;

  @override
  String toString() => 'ControlGrant(${kind.name})';
}

/// A paired session identity.
class SessionGrant extends ControlGrant {
  const SessionGrant({required this.peerId});

  /// The paired peer this session belongs to. Used for diagnostics, never for authorisation
  /// decisions on its own.
  final String peerId;

  @override
  ControlGrantKind get kind => ControlGrantKind.session;

  @override
  String toString() => 'SessionGrant($peerId)';
}

/// A task access token, bound to one transfer and to that task's direction.
class TaskGrant extends ControlGrant {
  const TaskGrant({required this.transferId, required this.direction});

  @override
  final String transferId;

  /// The task's direction, which decides whether §7's chunk endpoints apply to it at all.
  final TransferDirection direction;

  @override
  ControlGrantKind get kind => ControlGrantKind.task;

  @override
  String toString() => 'TaskGrant($transferId, ${direction.wireValue})';
}

/// §7's restricted completion-query credential.
///
/// §9 bounds what it returns: "受限完成凭证只返回终态、文件ID及摘要确认，不返回路径、清单、
/// 密钥或文件数据". The bound is enforced by the endpoint; modelling it as its own grant kind
/// is what stops it being accepted anywhere a session is accepted.
class CompletionQueryGrant extends ControlGrant {
  const CompletionQueryGrant({required this.transferId});

  @override
  final String transferId;

  @override
  ControlGrantKind get kind => ControlGrantKind.completionQuery;

  @override
  String toString() => 'CompletionQueryGrant($transferId)';
}

/// The port that says whether a bearer token is currently valid.
///
/// [authenticate] returning null covers every rejection the caller must not distinguish
/// between - unknown, expired, revoked, belonging to a re-paired identity - because §7
/// answers all of them the same way and a finer-grained answer would leak which one it was.
abstract class ControlAuthenticator {
  /// Resolves [token] to a grant, or null when it is not valid now.
  ControlGrant? authenticate({required String token, required int nowMillis});
}

/// A port that always rejects, for a server that has issued no tokens.
///
/// Worth having as a named type rather than as a closure at each call site: a server whose
/// token issuance is not implemented must not accidentally accept a token, and "always
/// rejects" is a safe default in a way that a *missing* authenticator would not be if it
/// defaulted to open.
class RejectingAuthenticator implements ControlAuthenticator {
  const RejectingAuthenticator();

  @override
  ControlGrant? authenticate({required String token, required int nowMillis}) =>
      null;
}

/// The §9 scope component for [request]: its credential, fingerprinted rather than held.
///
/// Read from the request because the pipeline hands a handler a *grant*, not the secret - by
/// design, since a grant must never carry one. It lives here rather than in each endpoint
/// because §9's scope is one rule: two endpoints computing it differently would give one
/// credential two scopes, and a retry would stop replaying.
///
/// Throws [StateError] when no bearer reached the handler. That is a programming error rather
/// than a request error: the caller is an endpoint registered against a route the credential
/// table says needs a bearer, so reaching here without one means the two disagree.
String credentialFingerprintOf(ControlRequest request) {
  final String? token = request.bearerToken();
  if (token == null) {
    throw StateError(
      'a bearer route reached its handler with no credential; the §7 credential table and '
      'the endpoint disagree',
    );
  }
  return credentialFingerprint(token);
}

/// The direction a route's operation requires of the task, when §7 names one.
class ControlDirectionRequirement {
  const ControlDirectionRequirement({
    required this.required,
    required this.why,
  });

  final TransferDirection required;

  /// Why the route needs it, from §7's row. Kept so a diagnostic can say which rule refused.
  final String why;
}

/// What §7 requires of a caller for one route.
class ControlAuthRequirement {
  const ControlAuthRequirement({required this.credential, this.direction});

  final ControlCredential credential;

  /// The task direction this route only applies to, or null when §7 names none.
  final ControlDirectionRequirement? direction;

  /// Whether this route needs a bearer token at all.
  bool get needsBearer =>
      credential == ControlCredential.session ||
      credential == ControlCredential.transferTask ||
      credential == ControlCredential.sessionOrTransferTask;

  @override
  String toString() =>
      'ControlAuthRequirement(${credential.name}'
      '${direction == null ? '' : ', ${direction!.required.wireValue}'})';
}

/// §7's per-route credrequirements, derived from the table rather than restated.
///
/// The table is keyed by [ApiRoute.name] so a route that is added to [ApiRoutes.all] without
/// a requirement fails loudly instead of silently becoming anonymous. That direction of
/// failure matters: a missing requirement that defaulted to "no credential needed" would
/// turn a new endpoint into an open one.
abstract final class ControlAuthTable {
  /// The requirement for each of §7's nineteen rows.
  static const Map<String, ControlAuthRequirement>
  byRouteName = <String, ControlAuthRequirement>{
    // §7: "除 pair 外均需要有效 Bearer" - pair is the stated exception.
    'pair': ControlAuthRequirement(credential: ControlCredential.none),

    // "会话身份"
    'offers': ControlAuthRequirement(credential: ControlCredential.session),

    // The client proposes a transfer; the session is what authorises the proposal.
    'createTransfer': ControlAuthRequirement(
      credential: ControlCredential.session,
    ),

    // "仅客户端发送者可写 staging"
    'putManifest': ControlAuthRequirement(
      credential: ControlCredential.transferTask,
      direction: ControlDirectionRequirement(
        required: TransferDirection.clientToServer,
        why: '§7: only the client sender may write staging',
      ),
    ),

    // "与已授权任务绑定"
    'getManifest': ControlAuthRequirement(
      credential: ControlCredential.transferTask,
    ),

    'seal': ControlAuthRequirement(
      credential: ControlCredential.transferTask,
      direction: ControlDirectionRequirement(
        required: TransferDirection.clientToServer,
        why: '§7: only the client sender may write staging',
      ),
    ),

    // "仅客户端接收者调用；server 接收者本地决定"
    'decision': ControlAuthRequirement(
      credential: ControlCredential.transferTask,
      direction: ControlDirectionRequirement(
        required: TransferDirection.serverToClient,
        why: '§7: only the client receiver decides acceptance',
      ),
    ),

    // "已授权会话"
    'authorization': ControlAuthRequirement(
      credential: ControlCredential.session,
    ),

    'authorizationReceipt': ControlAuthRequirement(
      credential: ControlCredential.transferTask,
      direction: ControlDirectionRequirement(
        required: TransferDirection.serverToClient,
        why: '§7: the receipt confirms the client saved the credentials',
      ),
    ),

    // "resume 使用 taskResumeSecret 专用请求体；初次 resume 无须旧会话令牌"
    'resume': ControlAuthRequirement(
      credential: ControlCredential.resumeBodySecret,
    ),

    // "会话、任务令牌或受限完成查询令牌"
    'status': ControlAuthRequirement(
      credential: ControlCredential.sessionOrTransferTask,
    ),

    // "仅 client_to_server"
    'putChunk': ControlAuthRequirement(
      credential: ControlCredential.transferTask,
      direction: ControlDirectionRequirement(
        required: TransferDirection.clientToServer,
        why: '§7: the chunk upload belongs to client_to_server',
      ),
    ),

    // "仅 server_to_client"
    'getChunk': ControlAuthRequirement(
      credential: ControlCredential.transferTask,
      direction: ControlDirectionRequirement(
        required: TransferDirection.serverToClient,
        why: '§7: the chunk download belongs to server_to_client',
      ),
    ),

    // "仅 client 接收者汇报，server 只更新显示镜像"
    'checkpoint': ControlAuthRequirement(
      credential: ControlCredential.transferTask,
      direction: ControlDirectionRequirement(
        required: TransferDirection.serverToClient,
        why: '§7: only the client receiver reports its checkpoint',
      ),
    ),

    'pause': ControlAuthRequirement(credential: ControlCredential.transferTask),
    'complete': ControlAuthRequirement(
      credential: ControlCredential.transferTask,
    ),
    'cancel': ControlAuthRequirement(
      credential: ControlCredential.transferTask,
    ),

    // "taskAccessToken"
    'control': ControlAuthRequirement(
      credential: ControlCredential.transferTask,
    ),
    'controlReceipt': ControlAuthRequirement(
      credential: ControlCredential.transferTask,
    ),
  };

  /// The requirement for [route].
  ///
  /// Throws when the route has none, rather than defaulting: see the class comment.
  static ControlAuthRequirement forRoute(ApiRoute route) {
    final ControlAuthRequirement? requirement = byRouteName[route.name];
    if (requirement == null) {
      throw ProtocolViolation(
        ProtocolErrorCode.invalidField,
        'route ${route.name} has no §7 credential requirement registered',
      );
    }
    return requirement;
  }

  /// Whether the table covers every route and nothing else.
  static void assertCoversEveryRoute() {
    final Set<String> known = <String>{
      for (final ApiRoute route in ApiRoutes.all) route.name,
    };
    final Set<String> covered = byRouteName.keys.toSet();
    if (known.length != covered.length || !known.containsAll(covered)) {
      throw ProtocolViolation(
        ProtocolErrorCode.invalidField,
        'the §7 credential table does not match the route table: '
        'missing ${known.difference(covered)}, extra ${covered.difference(known)}',
      );
    }
  }
}

/// The outcome of the authorisation stage: either the caller, or the answer to send.
///
/// Modelled as a result rather than as a thrown error because "which error" *is* the
/// decision here, and returning it keeps that decision visible and testable instead of
/// hiding it in a catch block.
sealed class ControlAuthorization {
  const ControlAuthorization();
}

/// The request may proceed.
class ControlAuthorized extends ControlAuthorization {
  const ControlAuthorized({required this.grant});

  /// The grant that authorised it, or null for a route that needs none.
  final ControlGrant? grant;

  @override
  String toString() => 'ControlAuthorized(${grant ?? 'anonymous'})';
}

/// The request may not proceed, and this is what to answer.
class ControlDenied extends ControlAuthorization {
  const ControlDenied({required this.code, required this.why});

  final ProtocolErrorCode code;

  /// Why, for local diagnostics only. Never reaches the peer: the wire body carries the
  /// code's own message key, so a refusal cannot explain to an attacker which check failed.
  final String why;

  @override
  String toString() => 'ControlDenied(${code.wireCode}, $why)';
}

/// Decides §7's authorisation stage.
class ControlAuthorizer {
  const ControlAuthorizer(
    this.authenticator, {
    this.ownership = const NoTaskOwnership(),
  });

  final ControlAuthenticator authenticator;

  /// Which peer owns each transfer, so a session identity can be scoped to the tasks it is
  /// actually entitled to. The default owns nothing, which keeps the fail-closed behaviour
  /// this class had before the mapping existed.
  final TaskOwnership ownership;

  /// Applies §7's rules to [request] for a matched [route] and its path parameters.
  ControlAuthorization authorize({
    required ControlRequest request,
    required ApiRoute route,
    required String? transferId,
    required int nowMillis,
  }) {
    final ControlAuthRequirement requirement = ControlAuthTable.forRoute(route);

    switch (requirement.credential) {
      case ControlCredential.none:
        return const ControlAuthorized(grant: null);

      case ControlCredential.resumeBodySecret:
        // §7 makes the resume secret body-borne and a first resume tokenless, so there is
        // nothing to check here; §9 gives the check to the original server.
        return const ControlAuthorized(grant: null);

      case ControlCredential.session:
      case ControlCredential.transferTask:
      case ControlCredential.sessionOrTransferTask:
        break;
    }

    final String? token;
    try {
      token = request.bearerToken();
    } on ProtocolViolation catch (violation) {
      return ControlDenied(code: violation.code, why: violation.detail);
    }
    if (token == null) {
      return const ControlDenied(
        code: ProtocolErrorCode.authExpired,
        why: '§7 requires a bearer token for this route and none was supplied',
      );
    }

    final ControlGrant? grant = authenticator.authenticate(
      token: token,
      nowMillis: nowMillis,
    );
    if (grant == null) {
      // Unknown, expired, revoked and re-paired all answer the same way: a finer answer
      // would tell the caller which of them it was.
      return const ControlDenied(
        code: ProtocolErrorCode.authExpired,
        why: 'the bearer token is not valid now',
      );
    }

    return _applyScope(
      grant: grant,
      requirement: requirement,
      transferId: transferId,
    );
  }

  ControlAuthorization _applyScope({
    required ControlGrant grant,
    required ControlAuthRequirement requirement,
    required String? transferId,
  }) {
    final bool scopedToTransfer =
        requirement.credential == ControlCredential.transferTask ||
        requirement.credential == ControlCredential.sessionOrTransferTask;

    // A session identity is not transfer-scoped, so it is not compared with the path when the
    // route only asks for a session. A transfer-scoped route does need one, and §7's
    // "会话到任务的映射" is what decides it: without a binding, refusing stays the answer.
    if (grant is SessionGrant) {
      if (requirement.credential == ControlCredential.session) {
        return ControlAuthorized(grant: grant);
      }

      final TaskOwner? owner = transferId == null
          ? null
          : ownership.ownerOf(transferId);
      if (owner == null) {
        // Deliberately the same answer as a transfer that does not exist: §7's "任务查询对
        // 无权限资源统一 404" exists so the status cannot be used to enumerate transfer ids.
        return const ControlDenied(
          code: ProtocolErrorCode.notFound,
          why:
              'this session is not bound to the transfer named in the path, so it cannot '
              'reach a transfer-scoped route for it',
        );
      }
      if (owner.peerId != grant.peerId) {
        return const ControlDenied(
          code: ProtocolErrorCode.notFound,
          why: 'the transfer belongs to a different paired peer',
        );
      }
      final ControlDirectionRequirement? sessionDirection =
          requirement.direction;
      if (sessionDirection != null &&
          owner.direction != sessionDirection.required) {
        // A session now reaches routes that carry a direction requirement, so the direction
        // check has to run for it too - otherwise the mapping would have opened a path around
        // `AGENTS.md` §5's per-request direction verification.
        return ControlDenied(
          code: ProtocolErrorCode.directionForbidden,
          why:
              '${sessionDirection.why}; the task direction is '
              '${owner.direction.wireValue}',
        );
      }
      return ControlAuthorized(grant: grant);
    }

    if (grant is CompletionQueryGrant) {
      if (requirement.credential != ControlCredential.sessionOrTransferTask) {
        return const ControlDenied(
          code: ProtocolErrorCode.notFound,
          why: 'a completion-query credential reaches only the status route',
        );
      }
      return _matchTransfer(grant, transferId);
    }

    if (grant is TaskGrant) {
      if (!scopedToTransfer) {
        // A task token is narrower than the session identity this route asks for, so it is
        // refused rather than promoted. §7 asks for "会话身份" here.
        return const ControlDenied(
          code: ProtocolErrorCode.notFound,
          why: 'this route asks for a session identity, not a task token',
        );
      }
      final ControlAuthorization matched = _matchTransfer(grant, transferId);
      if (matched is ControlDenied) {
        return matched;
      }
      final ControlDirectionRequirement? direction = requirement.direction;
      if (direction != null && grant.direction != direction.required) {
        // AGENTS.md §5 requires the operation direction to be verified on every file
        // request; §7 names the direction each chunk endpoint belongs to.
        return ControlDenied(
          code: ProtocolErrorCode.directionForbidden,
          why:
              '${direction.why}; the task direction is '
              '${grant.direction.wireValue}',
        );
      }
      return matched;
    }

    return const ControlDenied(
      code: ProtocolErrorCode.notFound,
      why: 'the credential is not accepted for this route',
    );
  }

  /// §7: "任务查询对无权限资源统一 404".
  ///
  /// A token for another transfer is answered exactly like a transfer that does not exist,
  /// so the status cannot be used to enumerate transfer ids.
  ControlAuthorization _matchTransfer(ControlGrant grant, String? transferId) {
    if (transferId == null) {
      return ControlAuthorized(grant: grant);
    }
    if (grant.transferId != transferId) {
      return const ControlDenied(
        code: ProtocolErrorCode.notFound,
        why: 'the credential does not cover the transfer named in the path',
      );
    }
    return ControlAuthorized(grant: grant);
  }
}
