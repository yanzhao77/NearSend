/// The authorisation half of §6 and §7: `decision`, `authorization`,
/// `authorization/receipt` and `resume`.
///
/// ## The order these four exist in, and why it cannot be shortened
///
/// §3:
///
/// > 会话认证只允许提议/查看该会话下的待授权任务，不能读取任意文件。**用户接受任务后服务端生成该
/// > 任务的客户端恢复密钥并持久化验证材料**；通过受认证的 `/authorization` 交付，客户端安全保存后
/// > 发送 receipt。……**初次授权交付完成后也调用 `/resume` 建立首个有效任务访问令牌和写入世代，
/// > 再进入 READY**；READY 不意味着可以绕过世代检查。
///
/// So the sequence is decision → authorization → receipt → resume → READY, and each step exists
/// because the next one needs something only it can produce. §6 adds the two constraints on the
/// decision: nothing may touch the receiver's bytes before it, and accepting commits to a digest,
/// a save location and a space estimate.
///
/// ## Where the space check happens, and what the endpoint can honestly know
///
/// §6 puts the space pre-check at acceptance and §11 pairs `SPACE_INSUFFICIENT` (507) with
/// "user frees space or changes location, then retry". §8 requires the plan to carry per-volume
/// explanations rather than a boolean, and §16.1 that an unverifiable volume is reported as
/// unknown rather than folded into a pass.
///
/// A server deciding for `server_to_client` is **not** the receiver, so it cannot measure the
/// client's volumes. Rather than invent numbers, the check runs against a
/// [ReceiverStorageContext] that only exists when this process really is the receiver
/// (`client_to_server`, or the client's own local decision). When there is no context the
/// server records the decision and the digest, and the estimate belongs to the decider - which
/// is the only party that can produce one.
///
/// ## Idempotency
///
/// §9 makes every one of these a `requestId`-scoped operation, and the effect and its record
/// commit together through [IdempotencyRepository]. That is not bookkeeping: a client whose
/// response was lost retries, and without the record the server would take the retry for a
/// second approval or allocate a second write generation.
library;

import 'package:nearsend/core/network/control_authorization.dart';
import 'package:nearsend/core/network/control_message.dart';
import 'package:nearsend/core/network/control_pipeline.dart';
import 'package:nearsend/core/network/manifest_staging_registry.dart';
import 'package:nearsend/core/protocol/api_responses.dart';
import 'package:nearsend/core/protocol/api_routes.dart';
import 'package:nearsend/core/protocol/idempotency.dart';
import 'package:nearsend/core/protocol/manifest.dart';
import 'package:nearsend/core/protocol/protocol_exception.dart';
import 'package:nearsend/core/protocol/protocol_validation.dart';
import 'package:nearsend/core/protocol/task_decision_request.dart';
import 'package:nearsend/core/protocol/transfer_resume_request.dart';
import 'package:nearsend/core/protocol/transfer_state.dart';
import 'package:nearsend/core/security/credential_fingerprint.dart';
import 'package:nearsend/core/storage/chunk_repository.dart';
import 'package:nearsend/core/storage/idempotency_repository.dart';
import 'package:nearsend/core/storage/receiver_mirror_repository.dart';
import 'package:nearsend/core/storage/space_plan.dart';
import 'package:nearsend/core/storage/task_authorization_repository.dart';
import 'package:nearsend/core/storage/task_credential_repository.dart';
import 'package:nearsend/core/storage/transfer_repository.dart';

/// What this process knows about its own storage, when it is the receiver.
///
/// Absent means "this process is not the receiver", which is the `server_to_client` case: the
/// server is the sender, and the volumes that matter are on the other device.
class ReceiverStorageContext {
  const ReceiverStorageContext({
    required this.stagingVolume,
    required this.exportVolume,
    required this.databaseVolume,
    required this.availability,
    this.saveLocationRef,
  });

  /// Where the transfer's staging copy is written.
  final VolumeId stagingVolume;

  /// Where the user's copy will be written.
  final VolumeId exportVolume;

  /// Where this task's rows are written.
  final VolumeId databaseVolume;

  /// What the platform reports for each volume. A volume absent from this map is treated as
  /// unknown, never as empty.
  final Map<VolumeId, VolumeAvailability> availability;

  /// An opaque handle for the chosen save location.
  ///
  /// Never a full local path: §7 keeps one out of an error body and `AGENTS.md` §5 keeps user
  /// file locations out of logs and diagnostics. Resolving it is the platform adapter's job.
  final String? saveLocationRef;
}

/// The decision, authorisation and resume use cases.
class TaskAuthorizationEndpoint {
  TaskAuthorizationEndpoint({
    required this.idempotency,
    required this.transfers,
    required this.tasks,
    required this.staging,
    required this.authorizations,
    required this.credentials,
    required this.mirror,
    this.receiverContext,
    this.planner = const SpacePlanner(),
    int Function()? now,
  }) : now = now ?? _systemNow;

  /// §9's durable record of request ids.
  final IdempotencyRepository idempotency;

  /// Task state transitions and file state.
  final TransferRepository transfers;

  /// The task's write generation and checkpoint sequence.
  final ChunkRepository tasks;

  /// The frozen manifest, which §6 makes the authority for what a transfer contains.
  final ManifestStagingRegistry staging;

  /// The persisted approval.
  final TaskAuthorizationRepository authorizations;

  /// The task's resume and completion-query secrets.
  final TaskCredentialRepository credentials;

  /// The sender's mirror of a client receiver's reported position.
  final ReceiverMirrorRepository mirror;

  /// This process's storage facts, when it is the receiver. See [ReceiverStorageContext].
  final ReceiverStorageContext? Function(String transferId)? receiverContext;

  /// Builds the explained space plan §8 requires.
  final SpacePlanner planner;

  /// Clock injection.
  final int Function() now;

  static int _systemNow() => DateTime.now().millisecondsSinceEpoch;

  /// `POST /transfers/{id}/decision`.
  ControlResponse decision({
    required String transferId,
    required Map<String, Object?> body,
    required ControlRequest request,
  }) {
    final TaskDecisionRequest decision = TaskDecisionRequest.parse(body);

    final IdempotencyExecution execution = idempotency.executeAtomically(
      scope: RequestScope(
        transferId: transferId,
        operation: ProtocolOperation.decision,
        credentialFingerprint: credentialFingerprintOf(request),
      ),
      requestId: decision.requestId,
      requestDigest: decision.requestDigest,
      leaseEpoch: tasks.leaseEpoch(transferId),
      effect: () => _decide(transferId, decision),
    );

    return _answered(execution, transferId);
  }

  /// The effect behind the decision.
  Map<String, Object?> _decide(
    String transferId,
    TaskDecisionRequest decision,
  ) {
    // §6 makes the sealed manifest the authority for what was offered, so a decision about a
    // transfer that has not been sealed has nothing to be about.
    final FrozenManifest? frozen = staging.frozenManifest(transferId);
    if (frozen == null) {
      throw const ProtocolViolation(
        ProtocolErrorCode.invalidState,
        'the transfer has no frozen manifest, so there is nothing to decide',
      );
    }
    if (decision.manifestDigest != frozen.manifestDigest) {
      throw const ProtocolViolation(
        ProtocolErrorCode.manifestMismatch,
        'the decision names a different manifest digest than the frozen manifest',
      );
    }

    final TransferState current = transfers.taskState(transferId);
    if (current != TransferState.waitingAccept) {
      throw const ProtocolViolation(
        ProtocolErrorCode.invalidState,
        'a decision is only meaningful while the task is in WAITING_ACCEPT',
      );
    }

    if (!decision.isAccept) {
      authorizations.recordDecision(
        transferId: transferId,
        manifestDigest: frozen.manifestDigest,
        decision: TransferDecision.rejected,
      );
      // §10 gives every state a local cancel edge, and a refusal is a cancel with a reason.
      transfers.transitionTask(taskId: transferId, to: TransferState.cancelled);
      staging.release(transferId, StagingReleaseReason.cancelled);
      credentials.revokeAll(transferId);
      return StateResponse(TransferState.cancelled).toJson();
    }

    final ReceiverStorageContext? context = receiverContext?.call(transferId);
    final SpaceEstimateSnapshot? estimate = context == null
        ? null
        : _estimateSpace(frozen, context);

    // §6 requires the space pre-check at acceptance, and §11 pairs SPACE_INSUFFICIENT with
    // "free space or change the save location". Unknown is deliberately **not** refused here:
    // §16.1 wants the risk surfaced to the person deciding, and this endpoint *is* that
    // decision, so the unknown case is persisted as part of the estimate the user approved.
    if (estimate != null && estimate.verdict == SpaceVerdict.insufficient) {
      throw ProtocolViolation(
        ProtocolErrorCode.spaceInsufficient,
        'the receiver cannot hold this transfer: ${estimate.requiredBytes} B required',
      );
    }

    authorizations.recordDecision(
      transferId: transferId,
      manifestDigest: frozen.manifestDigest,
      decision: TransferDecision.accepted,
      saveLocationRef: context?.saveLocationRef,
      spaceEstimate: estimate,
    );

    // §3: "用户接受任务后服务端生成该任务的客户端恢复密钥并持久化验证材料". Minted here rather
    // than at `/authorization` so the delivery endpoint has nothing to decide, and so a crash
    // between the two cannot leave an approved task with no credentials.
    credentials.issueSecrets(transferId);

    transfers.transitionTask(taskId: transferId, to: TransferState.ready);
    return StateResponse(TransferState.ready).toJson();
  }

  /// Plans the transfer's space needs from the frozen manifest and the platform's readings.
  SpaceEstimateSnapshot _estimateSpace(
    FrozenManifest frozen,
    ReceiverStorageContext context,
  ) {
    final SpacePlan plan = planner.plan(
      files: <FileSpaceRequest>[
        for (final ManifestFile file in frozen.files)
          FileSpaceRequest(
            fileId: file.fileId,
            sizeBytes: file.sizeBytes,
            stagingVolume: context.stagingVolume,
            exportVolume: context.exportVolume,
            // Nothing has been allocated yet at the moment of acceptance, and §16.2 forbids
            // substituting `sizeBytes` for a real allocation reading, so this stays 0 rather
            // than being guessed.
            stagingAlreadyAllocatedBytes: 0,
          ),
      ],
      availability: context.availability,
      volumeForDatabase: context.databaseVolume,
    );
    return SpaceEstimateSnapshot.of(plan);
  }

  /// `GET /transfers/{id}/authorization`.
  ///
  /// §7 requires it to be a session-authenticated route and §3 makes it the only delivery path
  /// for the two secrets. Re-delivery is idempotent while the client has not confirmed storage,
  /// which is what stops a lost response from being unrecoverable; after the receipt the
  /// plaintext is gone and this refuses rather than minting a replacement.
  ControlResponse authorization({required String transferId}) {
    final TaskAuthorizationRecord? record = authorizations.read(transferId);
    if (record == null || !record.isAccepted) {
      // Absent and rejected answer the same way: §7's "任务查询对无权限资源统一 404" and §6's
      // "只有接收方能接受" both point at not confirming whether an approval exists.
      throw const ProtocolViolation(
        ProtocolErrorCode.notFound,
        'no accepted transfer with that id is deliverable to this session',
      );
    }

    final IssuedTaskSecrets secrets = credentials.issueSecrets(transferId);
    return ControlResponse.json(
      status: 200,
      body: AuthorizationGrant(
        taskResumeSecret: secrets.taskResumeSecret,
        completionQuerySecret: secrets.completionQuerySecret,
      ).toJson(),
    );
  }

  /// `POST /transfers/{id}/authorization/receipt`.
  ControlResponse authorizationReceipt({
    required String transferId,
    required Map<String, Object?> body,
    required ControlRequest request,
  }) {
    final AuthorizationReceiptRequest receipt =
        AuthorizationReceiptRequest.parse(body);

    final IdempotencyExecution execution = idempotency.executeAtomically(
      scope: RequestScope(
        transferId: transferId,
        operation: ProtocolOperation.authorizationReceipt,
        credentialFingerprint: credentialFingerprintOf(request),
      ),
      requestId: receipt.requestId,
      requestDigest: receipt.requestDigest,
      leaseEpoch: tasks.leaseEpoch(transferId),
      effect: () {
        authorizations.recordReceipt(transferId);
        credentials.recordReceipt(transferId);
        return const StoredAck().toJson();
      },
    );

    return _answered(execution, transferId);
  }

  /// `POST /transfers/{id}/resume`.
  ///
  /// §7 makes this the one route whose credential is a body-borne secret and whose first call
  /// carries no session token, so the pipeline does not demand a bearer. Verification is this
  /// method's job: §9 says "`taskResumeSecret` 由原服务端验证，绑定原任务和方向".
  ControlResponse resume({
    required String transferId,
    required Map<String, Object?> body,
  }) {
    final TransferResumeRequest resume = TransferResumeRequest.parse(body);

    if (!credentials.resumeSecretMatches(transferId, resume.taskResumeSecret)) {
      // One answer for "wrong secret", "no such task" and "not approved": a finer answer would
      // let a caller probe which transfer ids exist and which have been approved.
      throw const ProtocolViolation(
        ProtocolErrorCode.resumeRejected,
        'the task resume secret does not match this task',
      );
    }

    final IdempotencyExecution execution = idempotency.executeAtomically(
      scope: RequestScope(
        transferId: transferId,
        operation: ProtocolOperation.resume,
        // §9 scopes a request id to "当前恢复凭证"; the scope stores a fingerprint, never the
        // secret, so a re-pairing cannot silently match an older request id.
        credentialFingerprint: credentialFingerprint(resume.taskResumeSecret),
      ),
      requestId: resume.requestId,
      requestDigest: resume.requestDigest,
      leaseEpoch: tasks.leaseEpoch(transferId),
      effect: () => _grantResume(transferId, resume),
    );

    if (execution.kind == IdempotencyExecutionKind.replayed) {
      // §9: "同一恢复 requestId 重试不得再次递增 epoch；**若后续恢复已创建更高 epoch**，则旧
      // requestId 返回 STALE_RESUME_REQUEST，**不返回可写的旧令牌**".
      //
      // The distinction that matters is whether the generation now in force is the one *this*
      // request allocated. Comparing against the stored result rather than against "any change"
      // is what makes an ordinary retry replay instead of being refused: the first call stores
      // the epoch it allocated, so a retry of that same call finds it equal and succeeds, while
      // a request whose generation has since been superseded finds it lower and is refused
      // before it can hand back a revoked token.
      final Object? storedEpoch = execution.result?['leaseEpoch'];
      final int current = tasks.leaseEpoch(transferId);
      final int granted = storedEpoch == null
          ? current
          : parseDecimalString(storedEpoch, 'leaseEpoch');
      if (granted < current) {
        throw ProtocolViolation(
          ProtocolErrorCode.staleResumeRequest,
          'a newer resume has already allocated write generation $current',
        );
      }
    }

    return _answered(execution, transferId, resumeAccepted: true);
  }

  /// The effect behind a resume: allocate the generation and hand out the token.
  Map<String, Object?> _grantResume(
    String transferId,
    TransferResumeRequest resume,
  ) {
    final TransferState current = transfers.taskState(transferId);
    if (current == TransferState.cancelled ||
        current == TransferState.completed ||
        current == TransferState.failed) {
      throw const ProtocolViolation(
        ProtocolErrorCode.taskCancelled,
        'a terminal task cannot be resumed',
      );
    }

    final FrozenManifest? frozen = staging.frozenManifest(transferId);
    if (frozen == null || frozen.manifestDigest != resume.manifestDigest) {
      throw const ProtocolViolation(
        ProtocolErrorCode.manifestMismatch,
        'the resume names a different manifest digest than the frozen manifest',
      );
    }

    // §7: "client 接收时必带已恢复的 receiverState". The direction decides which side this
    // process is: for server_to_client the *client* is the receiver, so the report is required;
    // for client_to_server this process is the receiver and its own rows are the truth.
    final bool clientIsReceiver =
        transfers.readDeclaration(transferId)!.direction == 'server_to_client';
    if (clientIsReceiver && resume.receiverState == null) {
      throw const ProtocolViolation(
        ProtocolErrorCode.invalidField,
        'a client receiver must report its recovered state when resuming',
      );
    }

    final ReceiverState? reported = resume.receiverState;
    if (reported != null) {
      // The receiver is the authority (§2 rule 5), so its report is *mirrored*, never adopted:
      // nothing here writes a chunk row or a checkpoint sequence from it.
      mirror.record(
        transferId: transferId,
        leaseEpoch: reported.leaseEpoch,
        checkpointSeq: reported.checkpointSeq,
        committedBytes: reported.committedBytes,
      );
    }

    if (current == TransferState.paused ||
        current == TransferState.interrupted) {
      transfers.transitionTask(
        taskId: transferId,
        to: TransferState.checkingResume,
      );
    }

    // §8's resume hand-over: revoke the current generation and allocate the next one. The
    // in-process write fence is drained first when there is one; the caller that owns a
    // `WriteFence` uses `revokeAndAdvanceLeaseAfterWritesStop` instead. This endpoint has no
    // in-flight writes of its own - it is the control plane - so it advances directly, and
    // §8's "等待旧写入停止" belongs to the data-plane caller that does.
    final int epoch = tasks.revokeAndAdvanceLease(transferId);

    final TransferState next =
        transfers.taskState(transferId) == TransferState.checkingResume
        ? TransferState.ready
        : current;
    if (transfers.taskState(transferId) == TransferState.checkingResume) {
      transfers.transitionTask(taskId: transferId, to: TransferState.ready);
    }

    final IssuedTaskAccessToken token = credentials.issueTaskAccessToken(
      transferId,
      leaseEpoch: epoch,
    );

    return ResumeGranted(
      taskAccessToken: token.token,
      leaseEpoch: epoch,
      checkpointSeq: tasks.checkpointSeq(transferId),
      state: next,
    ).toJson();
  }

  /// The pipeline closures, keyed by route name by the assembling code.
  Map<String, ControlHandler> handlers() => <String, ControlHandler>{
    ApiRoutes.decision.name:
        (
          ControlRequest request,
          MatchedApiRequest matched,
          ControlAuthorized authorization,
        ) async => decision(
          transferId: _requireTransfer(matched),
          body: request.decodeJsonBody(scope: 'the decision request'),
          request: request,
        ),
    ApiRoutes.authorization.name: (
      ControlRequest request,
      MatchedApiRequest matched,
      ControlAuthorized authorization,
    ) async => this.authorization(transferId: _requireTransfer(matched)),
    ApiRoutes.authorizationReceipt.name:
        (
          ControlRequest request,
          MatchedApiRequest matched,
          ControlAuthorized authorization,
        ) async => authorizationReceipt(
          transferId: _requireTransfer(matched),
          body: request.decodeJsonBody(scope: 'the authorization receipt'),
          request: request,
        ),
    ApiRoutes.resume.name:
        (
          ControlRequest request,
          MatchedApiRequest matched,
          ControlAuthorized authorization,
        ) async => resume(
          transferId: _requireTransfer(matched),
          body: request.decodeJsonBody(scope: 'the resume request'),
        ),
  };

  /// Turns an idempotency outcome into §7's response.
  ControlResponse _answered(
    IdempotencyExecution execution,
    String transferId, {
    bool resumeAccepted = false,
  }) {
    switch (execution.kind) {
      case IdempotencyExecutionKind.executed:
      case IdempotencyExecutionKind.replayed:
        break;
      case IdempotencyExecutionKind.inFlight:
        // §7 makes the resume's in-flight answer a 202 in CHECKING_RESUME; the other three
        // endpoints have no 202 body of their own, so they report the state already implied.
        if (resumeAccepted) {
          return ControlResponse.json(
            status: 202,
            body: const ResumeChecking().toJson(),
          );
        }
        return ControlResponse.json(
          status: 202,
          // §7 fixes no 202 body for the other three routes, so the state the task is actually
          // in is reported rather than a progress shape being invented for them.
          body: StateResponse(transfers.taskState(transferId)).toJson(),
        );
      case IdempotencyExecutionKind.conflict:
        throw const ProtocolViolation(
          ProtocolErrorCode.requestIdConflict,
          'this requestId was already used for this operation with different parameters',
        );
    }

    final Map<String, Object?>? stored = execution.result;
    if (stored == null) {
      return ControlResponse.json(
        status: 200,
        body: StateResponse(transfers.taskState(transferId)).toJson(),
      );
    }

    // Parsed rather than passed through, for the same reason as the creation endpoint: a stored
    // body this build cannot read was written by another version.
    if (resumeAccepted || stored.containsKey('taskAccessToken')) {
      return ControlResponse.json(
        status: 200,
        body: ResumeGranted.parse(stored).toJson(),
      );
    }
    if (stored.containsKey('stored')) {
      return ControlResponse.json(
        status: 200,
        body: StoredAck.parse(stored).toJson(),
      );
    }
    return ControlResponse.json(
      status: 200,
      body: StateResponse.parse(stored).toJson(),
    );
  }

  static String _requireTransfer(MatchedApiRequest matched) {
    final String? transferId = matched.transferId;
    if (transferId == null) {
      throw const ProtocolViolation(
        ProtocolErrorCode.notFound,
        'the route carries no transfer id',
      );
    }
    return transferId;
  }
}
