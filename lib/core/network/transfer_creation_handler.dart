/// `POST /transfers`, the first §7 endpoint with a use case behind it.
///
/// §6 says what it does: "客户端为发送者：`POST /transfers` 创建 staging 任务". The client
/// proposes a transfer, the server records it in `STAGING`, and the manifest pages follow.
///
/// ## The two rules that make this more than an insert
///
/// **The direction.** §7: "客户端仅可提议 `client_to_server`；服务端发送由本地创建". A
/// client asking for `server_to_client` is refused with `DIRECTION_FORBIDDEN` rather than
/// having a transfer quietly created in the wrong direction.
///
/// **The request id.** §9: "每次操作持久化请求摘要和结果；相同 ID 不同参数拒绝
/// `REQUEST_ID_CONFLICT`". This is not bookkeeping that can be added later: without it a
/// client whose response was lost retries, and the server has no way to tell that retry from
/// a second transfer. So the effect and the idempotency record are written in **one
/// transaction** by [IdempotencyRepository.executeAtomically] - the only arrangement in which
/// the record and the effect cannot disagree, which is `AGENTS.md` §2 rule 6 applied to
/// idempotency.
///
/// ## Why a client-proposed identifier needs care
///
/// §7 lists `transferId` as a request field, so the client chooses it. A *different* request
/// id can therefore arrive carrying a transfer id that already exists, which is a different
/// situation from a retry and has no `requestId`-shaped answer:
///
/// * the stored declaration is **identical** - the client lost its request id and is
///   re-proposing the same transfer. Succeeding without touching storage is the honest
///   outcome, and §6 endorses the same idea for a re-sent manifest page ("重传相同页返回成功").
/// * the stored declaration **differs** - the identifier is being reused for a different
///   transfer, which is refused as `INVALID_STATE` (409). Overwriting would destroy a task
///   another transfer may still be using.
///
/// ## What this handler deliberately does not do
///
/// It does not store `fileCount` or `totalBytes`. They are the client's **declaration**, and
/// §6 makes the sealed manifest the authority for what a transfer actually contains; §7's
/// `GET /offers` reads its summary from there. They are validated against §5's limits and are
/// part of the request digest, so a retry that changes them is a conflict.
///
/// It does not enforce §6's 30-minute staging window, accept a manifest page, or seal. Those
/// are the next endpoints.
library;

import 'package:nearsend/core/network/control_authorization.dart';
import 'package:nearsend/core/network/control_message.dart';
import 'package:nearsend/core/protocol/api_responses.dart';
import 'package:nearsend/core/protocol/api_routes.dart';
import 'package:nearsend/core/protocol/idempotency.dart';
import 'package:nearsend/core/protocol/protocol_exception.dart';
import 'package:nearsend/core/protocol/transfer_creation_request.dart';
import 'package:nearsend/core/protocol/transfer_state.dart';
import 'package:nearsend/core/storage/chunk_repository.dart';
import 'package:nearsend/core/storage/idempotency_repository.dart';
import 'package:nearsend/core/storage/transfer_repository.dart';

/// The `POST /transfers` use case.
class TransferCreationEndpoint {
  TransferCreationEndpoint({
    required this.idempotency,
    required this.transfers,
    required this.tasks,
    this.protocolMajor = 1,
    this.protocolMinor = 0,
    int Function()? now,
  }) : now = now ?? _systemNow;

  /// §9's durable record of request ids, written in the same transaction as the effect.
  final IdempotencyRepository idempotency;

  /// Reads back what a transfer was created with.
  final TransferRepository transfers;

  /// Inserts the task row. §7's creation is the first write a transfer ever gets.
  final ChunkRepository tasks;

  /// The protocol version a created transfer is registered under.
  final int protocolMajor;
  final int protocolMinor;

  /// Clock injection, so a test does not depend on wall time.
  final int Function() now;

  static int _systemNow() => DateTime.now().millisecondsSinceEpoch;

  /// The closure the pipeline stores under the `createTransfer` route name.
  ///
  /// A method rather than a field so the endpoint keeps a stable identity: the pipipeline
  /// holds a function, and this way there is one place that knows how a request becomes
  /// this use case's arguments.
  Future<ControlResponse> handler(
    ControlRequest request,
    MatchedApiRequest matched,
    ControlAuthorized authorization,
  ) async {
    final Map<String, Object?> body = request.decodeJsonBody(
      scope: 'the transfer creation request',
    );
    return handle(body: body, authorization: authorization, request: request);
  }

  /// Handles one `POST /transfers`.
  ControlResponse handle({
    required Map<String, Object?> body,
    required ControlAuthorized authorization,
    required ControlRequest request,
  }) {
    final TransferCreationRequest creation = TransferCreationRequest.parse(
      body,
    );
    // §7: a client may only propose client_to_server.
    creation.assertClientMayPropose();

    final IdempotencyExecution execution = idempotency.executeAtomically(
      scope: RequestScope(
        transferId: creation.transferId,
        operation: ProtocolOperation.createTransfer,
        credentialFingerprint: credentialFingerprintOf(request),
      ),
      requestId: creation.requestId,
      requestDigest: creation.requestDigest,
      // No write generation exists yet: §8 allocates one at the first resume, and a
      // transfer being created has nothing to write. 0 is what "not yet allocated" means
      // everywhere else in the storage layer.
      leaseEpoch: 0,
      effect: () => _createStagingTransfer(creation, now()),
    );

    switch (execution.kind) {
      case IdempotencyExecutionKind.executed:
      case IdempotencyExecutionKind.replayed:
        // §9: a retry gets the stored result and the effect did not run again. The status is
        // the same 201 the first call answered, because that is what was stored and a client
        // that lost the first response cannot tell the difference.
        return ControlResponse.json(
          status: 201,
          body: _resultFor(creation, execution),
        );

      case IdempotencyExecutionKind.inFlight:
        // §9: "当前 requestId 尚在处理中返回 202，客户端退避轮询或同 ID 重试". §7 fixes no
        // body for this route's 202, so only the state already implied by creation is
        // reported rather than inventing a progress shape.
        return ControlResponse.json(
          status: 202,
          body: TransferCreated(
            transferId: creation.transferId,
            state: TransferState.staging,
          ).toJson(),
        );

      case IdempotencyExecutionKind.conflict:
        throw ProtocolViolation(
          ProtocolErrorCode.requestIdConflict,
          'requestId ${creation.requestId} was already used for transfer '
          '${creation.transferId} with different parameters',
        );
    }
  }

  /// The effect: record the transfer in `STAGING`, or verify it is already recorded.
  ///
  /// Runs inside the idempotency transaction, so it must not open one itself.
  Map<String, Object?> _createStagingTransfer(
    TransferCreationRequest creation,
    int nowMillis,
  ) {
    final TransferDeclaration? existing = transfers.readDeclaration(
      creation.transferId,
    );

    if (existing != null) {
      final bool identical =
          existing.direction == creation.direction.wireValue &&
          existing.manifestDigest == creation.manifestDigest &&
          existing.protocolMajor == protocolMajor &&
          existing.protocolMinor == protocolMinor;
      if (!identical) {
        throw ProtocolViolation(
          ProtocolErrorCode.invalidState,
          'transfer ${creation.transferId} already exists with a different declaration; a '
          'client-proposed identifier may not be reused for another transfer',
        );
      }
      // Identical: the client re-proposed the same transfer, most likely because it lost
      // the response. Nothing is written and the answer is the one the first call gave.
    } else {
      tasks.registerTask(
        taskId: creation.transferId,
        role: 'receiver',
        direction: creation.direction.wireValue,
        state: TransferState.staging.name,
        protocolMajor: protocolMajor,
        protocolMinor: protocolMinor,
        manifestDigest: creation.manifestDigest,
        nowMillis: nowMillis,
      );
    }

    return TransferCreated(
      transferId: creation.transferId,
      state: TransferState.staging,
    ).toJson();
  }

  /// The §7 response body, from the stored result when there is one.
  Map<String, Object?> _resultFor(
    TransferCreationRequest creation,
    IdempotencyExecution execution,
  ) {
    final Map<String, Object?>? stored = execution.result;
    if (stored == null) {
      return TransferCreated(
        transferId: creation.transferId,
        state: TransferState.staging,
      ).toJson();
    }
    // Parsed rather than passed through: a stored body this build can no longer read was
    // written by another version, and returning it unchecked would put an unvalidated body
    // on the wire.
    return TransferCreated.parse(stored).toJson();
  }
}
