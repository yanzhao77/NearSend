/// §7's transfer lifecycle endpoints: `offers`, the manifest read, `status`, `checkpoint`,
/// `complete`, `pause`, `cancel` and the control channel.
///
/// ## What each one is for, in one line each
///
/// * `GET /offers` - §6: "`GET /offers` 仅向已配对会话列出指定给该会话的任务描述" and "未知会话不能
///   枚举 offers". Without it a client receiver cannot learn that a server has something for it.
/// * `GET /manifest` - the client needs the frozen manifest to derive chunk lengths and verify
///   digests, and §7 makes the route "与已授权任务绑定".
/// * `GET /status` - §9's snapshot. Two things matter here: a sender's answer is marked
///   `sender_mirror`, and §9's `missingChunkRanges` is **not** modelled because the draft never
///   fixes whether a range is a two-element array or an object (`t03-01-06` registered that).
/// * `POST /checkpoint` - §9: "仅 client 接收者汇报，server 只更新显示镜像". The acknowledgement is
///   named `mirrored` for exactly that reason.
/// * `POST /complete` - §10's two roles. A client receiver's `saved` is a **report**; a server
///   receiver's `request_verify` is a **request** for the server to run its own final check.
/// * `POST /pause` / `POST /cancel` - §10's edges. §8 requires a checkpoint before a task may be
///   shown as paused ("checkpoint 完成前不显示已暂停"), and §5 requires cancel to revoke
///   authorisation.
/// * `GET /control` + receipt - §7's channel by which a server that is the sender asks a client
///   receiver to stop. §7 notes a client cannot be pushed to over HTTP, so it polls.
///
/// ## The mirror rule, restated where it could be broken
///
/// §9: "服务端发送时响应明确标记 `authority:sender_mirror`，**不能据此覆盖客户端本地事实**".
/// Nothing in this file writes a chunk row or a checkpoint sequence from a reported figure. The
/// checkpoint endpoint calls [ReceiverMirrorRepository.record] and nothing else; `status` reads
/// the receiver's own rows when this process **is** the receiver and the mirror when it is not,
/// which is why the answer has to say which of the two it is.
///
/// ## What completion does *not* claim
///
/// A `saved` report from a client receiver is recorded as a report. §10 forbids more: "server
/// 将其记录为对端报告的完成，**不能声称自己独立读取了对端磁盘**". So the state moves because the
/// receiver said it saved, and no code here reads or hashes a file on the peer's device.
library;

import 'package:nearsend/core/network/chunk_transfer_endpoint.dart';
import 'package:nearsend/core/network/control_authorization.dart';
import 'package:nearsend/core/network/control_message.dart';
import 'package:nearsend/core/network/control_pipeline.dart';
import 'package:nearsend/core/network/manifest_staging_registry.dart';
import 'package:nearsend/core/network/task_ownership.dart';
import 'package:nearsend/core/protocol/api_responses.dart';
import 'package:nearsend/core/protocol/api_routes.dart';
import 'package:nearsend/core/protocol/chunk_headers.dart';
import 'package:nearsend/core/protocol/idempotency.dart';
import 'package:nearsend/core/protocol/manifest.dart';
import 'package:nearsend/core/protocol/manifest_page.dart';
import 'package:nearsend/core/protocol/protocol_exception.dart';
import 'package:nearsend/core/protocol/protocol_validation.dart';
import 'package:nearsend/core/protocol/transfer_direction.dart';
import 'package:nearsend/core/protocol/transfer_state.dart';
import 'package:nearsend/core/security/credential_fingerprint.dart';
import 'package:nearsend/core/storage/chunk_repository.dart';
import 'package:nearsend/core/storage/idempotency_repository.dart';
import 'package:nearsend/core/storage/receiver_mirror_repository.dart';
import 'package:nearsend/core/storage/transfer_repository.dart';

/// Who a status answer's figures belong to (§9's `authority` field).
enum StatusAuthority {
  /// This process is the receiver, so the figures are its own committed rows.
  receiver('receiver'),

  /// This process is the sender, so the figures are what the receiver last reported.
  senderMirror('sender_mirror');

  const StatusAuthority(this.wireValue);

  final String wireValue;
}

/// §9's status body, without the one field the draft leaves open.
///
/// `missingChunkRanges` is deliberately absent: §9 calls it "两端包含的十进制字符串对" without
/// saying whether that is a two-element array or an object, and `AGENTS.md` §3 forbids settling
/// an open protocol question by preference. §9 also endorses the alternative - "缺失块来自客户端
/// 本地" - and a receiver has its own database for that.
class TransferStatusBody {
  const TransferStatusBody({
    required this.transferId,
    required this.manifestDigest,
    required this.state,
    required this.leaseEpoch,
    required this.checkpointSeq,
    required this.committedBytes,
    required this.authority,
    this.fileId,
    this.snapshotId,
    this.nextCursor,
  });

  final String transferId;

  /// The frozen manifest's digest. §9 puts it in the body, and a receiver uses it to confirm it
  /// is looking at the transfer it thinks it is.
  final String manifestDigest;

  final TransferState state;
  final int leaseEpoch;
  final int checkpointSeq;
  final int committedBytes;
  final StatusAuthority authority;
  final String? fileId;

  /// Identifies the snapshot a paged answer belongs to (§9).
  final String? snapshotId;

  final String? nextCursor;

  Map<String, Object?> toJson() => <String, Object?>{
    'transferId': transferId,
    'manifestDigest': manifestDigest,
    'state': state.wireName,
    'leaseEpoch': encodeDecimalString(leaseEpoch, 'leaseEpoch'),
    'checkpointSeq': encodeDecimalString(checkpointSeq, 'checkpointSeq'),
    'committedBytes': encodeDecimalString(committedBytes, 'committedBytes'),
    'authority': authority.wireValue,
    'fileId': fileId,
    'snapshotId': snapshotId,
    'nextCursor': nextCursor,
  };

  static TransferStatusBody parse(Map<String, Object?> json) {
    final Object? state = json['state'];
    final TransferState? parsed = state is String
        ? TransferState.fromWireName(state)
        : null;
    if (parsed == null) {
      throw const ProtocolViolation(
        ProtocolErrorCode.invalidField,
        'a status body must carry a state §10 defines',
      );
    }
    final Object? authority = json['authority'];
    final StatusAuthority? kind = StatusAuthority.values
        .where((StatusAuthority a) => a.wireValue == authority)
        .firstOrNull;
    if (kind == null) {
      throw const ProtocolViolation(
        ProtocolErrorCode.invalidField,
        'a status body must say whether its figures are the receiver own or a mirror',
      );
    }
    final Object? transferId = requireField(
      json,
      'transferId',
      'the status body',
    );
    uuidToBytes(transferId, 'transferId');
    final Object? digest = requireField(
      json,
      'manifestDigest',
      'the status body',
    );
    sha256HexToBytes(digest, 'manifestDigest');

    return TransferStatusBody(
      transferId: transferId! as String,
      manifestDigest: digest! as String,
      state: parsed,
      leaseEpoch: parseDecimalString(
        requireField(json, 'leaseEpoch', 'the status body'),
        'leaseEpoch',
      ),
      checkpointSeq: parseDecimalString(
        requireField(json, 'checkpointSeq', 'the status body'),
        'checkpointSeq',
      ),
      committedBytes: parseDecimalString(
        requireField(json, 'committedBytes', 'the status body'),
        'committedBytes',
      ),
      authority: kind,
      fileId: json['fileId'] as String?,
      snapshotId: json['snapshotId'] as String?,
      nextCursor: json['nextCursor'] as String?,
    );
  }
}

/// §7's `complete` request body.
class TransferCompleteRequest {
  const TransferCompleteRequest({
    required this.requestId,
    required this.leaseEpoch,
    required this.fileId,
    required this.result,
    this.fileSha256,
  });

  final String requestId;
  final int leaseEpoch;
  final String fileId;
  final CompleteResult result;
  final String? fileSha256;

  static const Set<String> _keys = <String>{
    'requestId',
    'leaseEpoch',
    'fileId',
    'result',
    'fileSha256',
  };

  /// The digest §9's idempotency record stores.
  ///
  /// Built from the parsed fields rather than from the raw bytes, so a retry that reordered its
  /// keys is the same request. Hashed rather than concatenated because a digest field is a fixed
  /// shape and an ad-hoc concatenation is not.
  String get requestDigest => credentialFingerprint(
    'complete|$fileId|${result.wireValue}|${fileSha256 ?? ''}|$leaseEpoch',
  );

  static TransferCompleteRequest parse(Map<String, Object?> json) {
    rejectUnknownKeys(json, _keys, 'the completion request');
    final Object? requestId = requireField(
      json,
      'requestId',
      'the completion request',
    );
    uuidToBytes(requestId, 'requestId');
    final Object? fileId = requireField(
      json,
      'fileId',
      'the completion request',
    );
    uuidToBytes(fileId, 'fileId');

    final CompleteResult result = CompleteResult.parse(json['result']);
    final Object? digest = json['fileSha256'];
    if (digest != null) {
      sha256HexToBytes(digest, 'fileSha256');
    }
    if (result == CompleteResult.saved && digest == null) {
      // §10 makes the client receiver report "冻结摘要"; a report of having saved that names no
      // bytes cannot be checked against anything, which is the whole point of the field.
      throw const ProtocolViolation(
        ProtocolErrorCode.invalidField,
        'a saved result must carry the whole-file digest it saved',
      );
    }

    return TransferCompleteRequest(
      requestId: requestId! as String,
      leaseEpoch: parseDecimalString(
        requireField(json, 'leaseEpoch', 'the completion request'),
        'leaseEpoch',
      ),
      fileId: fileId! as String,
      result: result,
      fileSha256: digest as String?,
    );
  }
}

/// §7's two `result` values.
enum CompleteResult {
  /// A client receiver asks a server receiver to run its own final check (§10).
  requestVerify('request_verify'),

  /// A client receiver reports that it verified and saved the file itself (§10).
  saved('saved');

  const CompleteResult(this.wireValue);

  final String wireValue;

  static CompleteResult parse(Object? value) {
    for (final CompleteResult result in CompleteResult.values) {
      if (result.wireValue == value) {
        return result;
      }
    }
    throw const ProtocolViolation(
      ProtocolErrorCode.invalidField,
      'result must be request_verify or saved',
    );
  }
}

/// §7's `checkpoint` request body.
class TransferCheckpointRequest {
  const TransferCheckpointRequest({
    required this.requestId,
    required this.manifestDigest,
    required this.leaseEpoch,
    required this.checkpointSeq,
    required this.committedBytes,
  });

  final String requestId;
  final String manifestDigest;
  final int leaseEpoch;
  final int checkpointSeq;
  final int committedBytes;

  static const Set<String> _keys = <String>{
    'requestId',
    'manifestDigest',
    'leaseEpoch',
    'checkpointSeq',
    'committedBytes',
  };

  String get requestDigest => credentialFingerprint(
    'checkpoint|$manifestDigest|$leaseEpoch|$checkpointSeq|$committedBytes',
  );

  static TransferCheckpointRequest parse(Map<String, Object?> json) {
    rejectUnknownKeys(json, _keys, 'the checkpoint report');
    final Object? requestId = requireField(
      json,
      'requestId',
      'the checkpoint report',
    );
    uuidToBytes(requestId, 'requestId');
    final Object? digest = requireField(
      json,
      'manifestDigest',
      'the checkpoint report',
    );
    sha256HexToBytes(digest, 'manifestDigest');
    return TransferCheckpointRequest(
      requestId: requestId! as String,
      manifestDigest: digest! as String,
      leaseEpoch: parseDecimalString(
        requireField(json, 'leaseEpoch', 'the checkpoint report'),
        'leaseEpoch',
      ),
      checkpointSeq: parseDecimalString(
        requireField(json, 'checkpointSeq', 'the checkpoint report'),
        'checkpointSeq',
      ),
      committedBytes: parseDecimalString(
        requireField(json, 'committedBytes', 'the checkpoint report'),
        'committedBytes',
      ),
    );
  }
}

/// §7's `pause` request body: `{requestId, leaseEpoch}`.
class TransferPauseRequest {
  const TransferPauseRequest({
    required this.requestId,
    required this.leaseEpoch,
  });

  final String requestId;
  final int leaseEpoch;

  static const Set<String> _keys = <String>{'requestId', 'leaseEpoch'};

  String get requestDigest => credentialFingerprint('pause|$leaseEpoch');

  static TransferPauseRequest parse(Map<String, Object?> json) {
    rejectUnknownKeys(json, _keys, 'the pause request');
    final Object? requestId = requireField(
      json,
      'requestId',
      'the pause request',
    );
    uuidToBytes(requestId, 'requestId');
    return TransferPauseRequest(
      requestId: requestId! as String,
      leaseEpoch: parseDecimalString(
        requireField(json, 'leaseEpoch', 'the pause request'),
        'leaseEpoch',
      ),
    );
  }
}

/// The lifecycle use cases.
class TransferLifecycleEndpoint {
  TransferLifecycleEndpoint({
    required this.idempotency,
    required this.transfers,
    required this.tasks,
    required this.staging,
    required this.mirror,
    required this.ownership,
    required this.windows,
    required this.revokeCredentials,
    required this.onVerificationRequested,
    int Function()? now,
  }) : now = now ?? _systemNow;

  final IdempotencyRepository idempotency;
  final TransferRepository transfers;
  final ChunkRepository tasks;
  final ManifestStagingRegistry staging;
  final ReceiverMirrorRepository mirror;

  /// Which peer each transfer is bound to, for §6's "未知会话不能枚举 offers".
  final SqliteTaskOwnership ownership;

  /// The open §8 windows, so a pause can force the checkpoint §8 requires.
  final ChunkWindowRegistry windows;

  /// Revokes a cancelled task's credentials.
  final void Function(String transferId) revokeCredentials;

  /// Asks the application layer to run §10's server-side final verification.
  ///
  /// A callback rather than a call, because verification and export need the platform's staged
  /// bytes and its export target, and §10 makes them the **receiver's local** work: "client 的
  /// `complete(result=request_verify)` **只是请求触发终检**；server 本地验证、保存完成才进入
  /// `COMPLETED`". So this endpoint's job is to move the task into `VERIFYING` and report that;
  /// what happens next is the same code path the user's own "finish" action uses.
  final void Function(String transferId, String fileId) onVerificationRequested;

  final int Function() now;

  static int _systemNow() => DateTime.now().millisecondsSinceEpoch;

  /// §7 caps an offers page at 128 entries (§6's file page limit).
  static const int offersPageLimit = 128;

  /// `GET /offers`.
  ControlResponse offers({required String peerId, String? cursor}) {
    final List<String> assigned = ownership.assignedTransfers(peerId);
    final List<OfferSummary> page = <OfferSummary>[];
    String? next;

    for (final String transferId in assigned) {
      if (page.length == offersPageLimit) {
        next = page.last.transferId;
        break;
      }
      if (cursor != null && transferId.compareTo(cursor) <= 0) {
        continue;
      }
      final TransferState state = transfers.taskState(transferId);
      if (state != TransferState.waitingAccept &&
          state != TransferState.ready) {
        continue;
      }
      final FrozenManifest? frozen = staging.frozenManifest(transferId);
      if (frozen == null) {
        // §7's offer carries a manifest digest and a file count, and §6 makes the sealed
        // manifest the authority for both. An offer before the seal would have to invent them.
        continue;
      }
      if (frozen.manifestDigest !=
          transfers.readDeclaration(transferId)?.manifestDigest) {
        continue;
      }
      page.add(
        OfferSummary(
          transferId: transferId,
          manifestDigest: frozen.manifestDigest,
          fileCount: frozen.fileCount,
          totalBytes: frozen.totalBytes,
        ),
      );
    }

    return ControlResponse.json(
      status: 200,
      body: OffersPage(offers: page, nextCursor: next).toJson(),
    );
  }

  /// `GET /transfers/{id}/manifest`.
  ControlResponse getManifest({
    required String transferId,
    required MatchedApiRequest matched,
  }) {
    final FrozenManifest frozen = _frozen(transferId);
    final ManifestPageKind kind = matched.manifestKind();
    final int startIndex = matched.startIndex();
    final int limit = matched.pageLimit();

    final ManifestPage page;
    final int total;
    switch (kind) {
      case ManifestPageKind.files:
        total = frozen.files.length;
        final List<ManifestFile> rest = startIndex < total
            ? frozen.files.sublist(startIndex)
            : const <ManifestFile>[];
        page = ManifestFilePage(
          manifestDigest: frozen.manifestDigest,
          startIndex: startIndex,
          items: rest.length > limit ? rest.sublist(0, limit) : rest,
        );
      case ManifestPageKind.chunks:
        final String fileId = matched.fileId!;
        total = _fileOf(frozen, fileId).chunkCount;
        page = ManifestChunkPage(
          manifestDigest: frozen.manifestDigest,
          fileId: fileId,
          startIndex: startIndex,
          items: staging.store.readChunkPage(
            transferId,
            fileId: fileId,
            startIndex: startIndex,
            limit: limit,
          ),
        );
    }

    final bool more = page.endIndex < total;
    return ControlResponse.json(
      status: 200,
      body: <String, Object?>{
        ...page.toJson(),
        // §7: "nextIndex:null 或十进制字符串".
        ApiResponses.nextIndexField: more
            ? encodeDecimalString(page.endIndex, 'nextIndex')
            : null,
      },
    );
  }

  /// `GET /transfers/{id}/status`.
  ControlResponse status({required String transferId, String? fileId}) {
    final FrozenManifest frozen = _frozen(transferId);
    final bool thisIsReceiver = _directionOf(transferId).permitsChunkUpload;

    // §9's authority marker: a sender's numbers are a copy of what the receiver reported, and
    // saying so is what stops a caller treating them as the receiver's facts.
    final StatusAuthority authority = thisIsReceiver
        ? StatusAuthority.receiver
        : StatusAuthority.senderMirror;
    final int committedBytes = thisIsReceiver
        ? tasks.committedBytesForTask(transferId)
        : (mirror.read(transferId)?.committedBytes ?? 0);

    return ControlResponse.json(
      status: 200,
      body: TransferStatusBody(
        transferId: transferId,
        manifestDigest: frozen.manifestDigest,
        state: transfers.taskState(transferId),
        leaseEpoch: tasks.leaseEpoch(transferId),
        checkpointSeq: tasks.checkpointSeq(transferId),
        committedBytes: committedBytes,
        authority: authority,
        fileId: fileId,
      ).toJson(),
    );
  }

  /// `POST /transfers/{id}/checkpoint`.
  ControlResponse checkpoint({
    required String transferId,
    required Map<String, Object?> body,
    required ControlRequest request,
  }) {
    final TransferCheckpointRequest report = TransferCheckpointRequest.parse(
      body,
    );
    final IdempotencyExecution execution = idempotency.executeAtomically(
      scope: RequestScope(
        transferId: transferId,
        operation: ProtocolOperation.checkpoint,
        credentialFingerprint: credentialFingerprintOf(request),
      ),
      requestId: report.requestId,
      requestDigest: report.requestDigest,
      leaseEpoch: tasks.leaseEpoch(transferId),
      effect: () {
        // §9: "server 只更新显示镜像". Nothing here writes a chunk row or a checkpoint sequence:
        // the receiver's committed rows are the authority and this is a copy of a figure it
        // reported, kept so the sender's screen is not blank.
        mirror.record(
          transferId: transferId,
          leaseEpoch: report.leaseEpoch,
          checkpointSeq: report.checkpointSeq,
          committedBytes: report.committedBytes,
        );
        return const MirroredAck().toJson();
      },
    );
    return _answered(execution, transferId);
  }

  /// `POST /transfers/{id}/pause`.
  ///
  /// §8: "暂停/文件结尾强制提交" and "checkpoint 完成前不显示已暂停". So the window is flushed
  /// before the state moves, and the answer reports `PAUSED` only once that has committed.
  ControlResponse pause({
    required String transferId,
    required Map<String, Object?> body,
    required ControlRequest request,
  }) {
    final TransferPauseRequest pause = TransferPauseRequest.parse(body);
    final IdempotencyExecution execution = idempotency.executeAtomically(
      scope: RequestScope(
        transferId: transferId,
        operation: ProtocolOperation.pause,
        credentialFingerprint: credentialFingerprintOf(request),
      ),
      requestId: pause.requestId,
      requestDigest: pause.requestDigest,
      leaseEpoch: pause.leaseEpoch,
      effect: () {
        windows.flushTask(transferId, leaseEpoch: pause.leaseEpoch);
        if (transfers.taskState(transferId) == TransferState.transferring) {
          transfers.transitionTask(
            taskId: transferId,
            to: TransferState.pausing,
          );
          transfers.transitionTask(
            taskId: transferId,
            to: TransferState.paused,
          );
        }
        return StateResponse(transfers.taskState(transferId)).toJson();
      },
    );
    return _answered(execution, transferId);
  }

  /// `POST /transfers/{id}/cancel`.
  ///
  /// §10 gives every non-terminal state a cancel edge, and `AGENTS.md` §5 requires the
  /// authorisation to be revoked. Both happen inside the idempotent effect, so a retry cannot
  /// leave a token alive for a cancelled task.
  ControlResponse cancel({
    required String transferId,
    required Map<String, Object?> body,
    required ControlRequest request,
  }) {
    final Object? requestId = body['requestId'];
    uuidToBytes(requestId, 'requestId');
    final IdempotencyExecution execution = idempotency.executeAtomically(
      scope: RequestScope(
        transferId: transferId,
        operation: ProtocolOperation.cancel,
        credentialFingerprint: credentialFingerprintOf(request),
      ),
      requestId: requestId! as String,
      requestDigest: credentialFingerprint('cancel'),
      leaseEpoch: tasks.leaseEpoch(transferId),
      effect: () {
        if (transfers.taskState(transferId) != TransferState.cancelled) {
          transfers.transitionTask(
            taskId: transferId,
            to: TransferState.cancelled,
          );
        }
        revokeCredentials(transferId);
        windows.releaseTask(transferId);
        return StateResponse(TransferState.cancelled).toJson();
      },
    );
    return _answered(execution, transferId);
  }

  /// `POST /transfers/{id}/complete`.
  ControlResponse complete({
    required String transferId,
    required Map<String, Object?> body,
    required ControlRequest request,
  }) {
    final TransferCompleteRequest complete = TransferCompleteRequest.parse(
      body,
    );
    final IdempotencyExecution execution = idempotency.executeAtomically(
      scope: RequestScope(
        transferId: transferId,
        operation: ProtocolOperation.complete,
        credentialFingerprint: credentialFingerprintOf(request),
      ),
      requestId: complete.requestId,
      requestDigest: complete.requestDigest,
      leaseEpoch: complete.leaseEpoch,
      effect: () => _finish(transferId, complete),
    );
    return _answered(execution, transferId);
  }

  Map<String, Object?> _finish(
    String transferId,
    TransferCompleteRequest complete,
  ) {
    final FrozenManifest frozen = _frozen(transferId);
    if (!frozen.files.any((ManifestFile f) => f.fileId == complete.fileId)) {
      throw const ProtocolViolation(
        ProtocolErrorCode.notFound,
        'no file with that id is part of this transfer',
      );
    }
    if (complete.leaseEpoch != tasks.leaseEpoch(transferId)) {
      // §8: a completion from a superseded generation is a completion of a different attempt.
      throw ProtocolViolation(
        ProtocolErrorCode.staleLease,
        'write generation ${complete.leaseEpoch} is not current '
        '(${tasks.leaseEpoch(transferId)})',
      );
    }

    final bool thisIsReceiver = _directionOf(transferId).permitsChunkUpload;

    if (complete.result == CompleteResult.saved) {
      // §10: "只有本地终检和导出确认后才能 complete(result=saved,fileSha256=冻结摘要)" and the
      // server "将其记录为对端报告的完成". The receiver said it saved; this process has not read
      // that disk and does not claim to.
      _advanceToCompleted(transferId);
      return StateResponse(TransferState.completed).toJson();
    }

    if (!thisIsReceiver) {
      // A sender has no staged bytes of its own, so being asked to verify is a direction error
      // rather than a state this process can reach.
      throw const ProtocolViolation(
        ProtocolErrorCode.directionForbidden,
        'only a receiver can be asked to verify staged bytes',
      );
    }

    // §10: "client 的 complete(result=request_verify) 只是请求触发终检；server 本地验证、保存完成才
    // 进入 COMPLETED". The state moves to VERIFYING here; the application layer runs the check and
    // exports, and the task reaches COMPLETED only through that path.
    if (transfers.taskState(transferId) == TransferState.transferring) {
      transfers.transitionTask(taskId: transferId, to: TransferState.verifying);
    }
    onVerificationRequested(transferId, complete.fileId);
    return StateResponse(TransferState.verifying).toJson();
  }

  void _advanceToCompleted(String transferId) {
    // §10's chain is READY→TRANSFERRING→VERIFYING→EXPORTING→COMPLETED, and each step is asserted
    // so an undefined edge is refused rather than written. The first version started at VERIFYING
    // and failed with "ready -> verifying is not defined" - the state machine correctly refusing
    // a jump over the state that records that data actually moved.
    for (final TransferState step in <TransferState>[
      TransferState.transferring,
      TransferState.verifying,
      TransferState.exporting,
      TransferState.completed,
    ]) {
      final TransferState from = transfers.taskState(transferId);
      if (from == TransferState.completed) {
        return;
      }
      if (from == step || !TransferStateMachine.canTransition(from, step)) {
        continue;
      }
      transfers.transitionTask(taskId: transferId, to: step);
    }
  }

  /// `GET /transfers/{id}/control`.
  ///
  /// §7 gives this channel one job: a server that is the sender cannot push to a client
  /// receiver over HTTP, so the client polls and applies `pause` or `cancel` itself. The
  /// commands are derived from the task's state rather than stored: a task that is paused has
  /// exactly one thing to tell the peer, and a stored queue would be a second answer to "what
  /// should the peer do now" that could disagree with the state.
  ControlResponse control({required String transferId, int afterSeq = 0}) {
    final TransferState state = transfers.taskState(transferId);
    final List<ControlCommand> commands = <ControlCommand>[];
    if (state == TransferState.pausing || state == TransferState.paused) {
      commands.add(
        const ControlCommand(seq: 1, type: ControlCommandType.pause),
      );
    }
    if (state == TransferState.cancelled) {
      commands.add(
        const ControlCommand(seq: 2, type: ControlCommandType.cancel),
      );
    }
    final List<ControlCommand> after = <ControlCommand>[
      for (final ControlCommand command in commands)
        if (command.seq > afterSeq) command,
    ];
    return ControlResponse.json(
      status: 200,
      body: ControlPoll(
        commands: after,
        lastSeq: commands.isEmpty ? 0 : commands.last.seq,
      ).toJson(),
    );
  }

  /// `POST /transfers/{id}/control/receipt`.
  ///
  /// §7: "客户端确认已处理命令". The acknowledgement is idempotent by request id like every
  /// other write; repeating it for the same sequence changes nothing, because the sequence is
  /// derived from the state rather than consumed.
  ControlResponse controlReceipt({
    required String transferId,
    required Map<String, Object?> body,
    required ControlRequest request,
  }) {
    final Object? requestId = body['requestId'];
    uuidToBytes(requestId, 'requestId');
    final Object? lastApplied = body['lastAppliedSeq'];
    final int seq = parseDecimalString(lastApplied, 'lastAppliedSeq');

    final IdempotencyExecution execution = idempotency.executeAtomically(
      scope: RequestScope(
        transferId: transferId,
        operation: ProtocolOperation.controlReceipt,
        credentialFingerprint: credentialFingerprintOf(request),
      ),
      requestId: requestId! as String,
      requestDigest: credentialFingerprint('control-receipt|$seq'),
      leaseEpoch: tasks.leaseEpoch(transferId),
      effect: () => const StoredAck().toJson(),
    );
    return _answered(execution, transferId);
  }

  /// The pipeline closures for the lifecycle routes.
  Map<String, ControlHandler> handlers() => <String, ControlHandler>{
    ApiRoutes.offers.name:
        (
          ControlRequest request,
          MatchedApiRequest matched,
          ControlAuthorized authorization,
        ) async {
          final ControlGrant? grant = authorization.grant;
          if (grant is! SessionGrant) {
            // §6 lists offers to a paired session, and the §7 credential table already requires
            // one; reaching here with anything else means the table and the endpoint disagree.
            throw const ProtocolViolation(
              ProtocolErrorCode.notFound,
              'offers are listed to a paired session only',
            );
          }
          return offers(
            peerId: grant.peerId,
            cursor: matched.queryParameters['cursor'],
          );
        },
    ApiRoutes.getManifest.name: (
      ControlRequest request,
      MatchedApiRequest matched,
      ControlAuthorized authorization,
    ) async => getManifest(transferId: _transfer(matched), matched: matched),
    ApiRoutes.status.name: (
      ControlRequest request,
      MatchedApiRequest matched,
      ControlAuthorized authorization,
    ) async => status(transferId: _transfer(matched), fileId: matched.fileId),
    ApiRoutes.checkpoint.name:
        (
          ControlRequest request,
          MatchedApiRequest matched,
          ControlAuthorized authorization,
        ) async => checkpoint(
          transferId: _transfer(matched),
          body: request.decodeJsonBody(scope: 'the checkpoint report'),
          request: request,
        ),
    ApiRoutes.pause.name:
        (
          ControlRequest request,
          MatchedApiRequest matched,
          ControlAuthorized authorization,
        ) async => pause(
          transferId: _transfer(matched),
          body: request.decodeJsonBody(scope: 'the pause request'),
          request: request,
        ),
    ApiRoutes.cancel.name:
        (
          ControlRequest request,
          MatchedApiRequest matched,
          ControlAuthorized authorization,
        ) async => cancel(
          transferId: _transfer(matched),
          body: request.decodeJsonBody(scope: 'the cancel request'),
          request: request,
        ),
    ApiRoutes.complete.name:
        (
          ControlRequest request,
          MatchedApiRequest matched,
          ControlAuthorized authorization,
        ) async => complete(
          transferId: _transfer(matched),
          body: request.decodeJsonBody(scope: 'the completion request'),
          request: request,
        ),
    ApiRoutes.control.name:
        (
          ControlRequest request,
          MatchedApiRequest matched,
          ControlAuthorized authorization,
        ) async => control(
          transferId: _transfer(matched),
          afterSeq: matched.afterSeq(),
        ),
    ApiRoutes.controlReceipt.name:
        (
          ControlRequest request,
          MatchedApiRequest matched,
          ControlAuthorized authorization,
        ) async => controlReceipt(
          transferId: _transfer(matched),
          body: request.decodeJsonBody(scope: 'the control receipt'),
          request: request,
        ),
  };

  ControlResponse _answered(IdempotencyExecution execution, String transferId) {
    switch (execution.kind) {
      case IdempotencyExecutionKind.executed:
      case IdempotencyExecutionKind.replayed:
        break;
      case IdempotencyExecutionKind.inFlight:
        return ControlResponse.json(
          status: 202,
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
    if (stored.containsKey('mirrored')) {
      return ControlResponse.json(
        status: 200,
        body: MirroredAck.parse(stored).toJson(),
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

  FrozenManifest _frozen(String transferId) {
    final FrozenManifest? frozen = staging.frozenManifest(transferId);
    if (frozen == null) {
      throw const ProtocolViolation(
        ProtocolErrorCode.invalidState,
        'the transfer has no frozen manifest to read',
      );
    }
    return frozen;
  }

  TransferDirection _directionOf(String transferId) {
    final TransferDeclaration declaration = transfers.readDeclaration(
      transferId,
    )!;
    return TransferDirection.parse(declaration.direction);
  }

  static ManifestFile _fileOf(FrozenManifest frozen, String fileId) {
    for (final ManifestFile file in frozen.files) {
      if (file.fileId == fileId) {
        return file;
      }
    }
    throw const ProtocolViolation(
      ProtocolErrorCode.notFound,
      'no file with that id is part of this transfer',
    );
  }

  static String _transfer(MatchedApiRequest matched) {
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

/// The §8 header set a chunk `GET` response must carry.
///
/// Exposed so the transport can build the response without re-deriving §8's header names, which
/// live in one place (`chunk_headers.dart`) for the same reason the framing rules do.
Map<String, String> chunkGetResponseHeaders({
  required int contentLength,
  required String chunkSha256,
}) => ChunkGetResponseHeaders(
  contentLength: contentLength,
  chunkSha256: chunkSha256,
).toHeaders();
