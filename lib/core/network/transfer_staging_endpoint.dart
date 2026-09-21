/// The staging lifecycle endpoints: `PUT /transfers/{id}/manifest` and
/// `POST /transfers/{id}/seal`.
///
/// §6:
///
/// > 客户端为发送者：`POST /transfers` 创建 staging 任务；**分批 `PUT` 文件页和块页**；
/// > **`POST /seal`**；服务端验证所有页与总摘要后展示接收确认。
///
/// The hard parts are already built and tested: `ManifestPage` validates a page's shape and
/// §5.1's path and size bounds, `ManifestStaging` stores by index so a duplicate page cannot
/// inflate the count, refuses an overlapping range whose content differs, and seals in §6's
/// order with the total digest last. What this file adds is the part that could not exist
/// until there was an endpoint: finding the right staging for the transfer in the path,
/// applying §6's thirty-minute window, and turning a seal into a durable state change.
///
/// ## Two rules worth stating
///
/// **A re-sent page is a success, not an error.** §6: "重传相同页返回成功". A client whose
/// response was lost has no way to know the page arrived, so `stored` and `alreadyStored`
/// both answer `200 {stored:true}`. Answering an error to the second would make a lost
/// response unrecoverable, which is the failure §6 is written to avoid.
///
/// **The seal is idempotent by request id, and by content.** §9 makes a repeated `requestId`
/// replay the stored result, and `ManifestStaging.seal` returns the same frozen manifest when
/// called twice. The second matters because the seal's effect is partly in memory: if the
/// database transaction fails after the manifest is frozen, a retry must still be able to
/// finish rather than finding a manifest it can no longer seal.
library;

import 'package:nearsend/core/network/control_authorization.dart';
import 'package:nearsend/core/network/control_message.dart';
import 'package:nearsend/core/network/control_pipeline.dart';
import 'package:nearsend/core/network/manifest_staging_registry.dart';
import 'package:nearsend/core/protocol/api_responses.dart';
import 'package:nearsend/core/protocol/api_routes.dart';
import 'package:nearsend/core/protocol/idempotency.dart';
import 'package:nearsend/core/protocol/manifest_page.dart';
import 'package:nearsend/core/protocol/manifest_staging.dart';
import 'package:nearsend/core/protocol/protocol_exception.dart';
import 'package:nearsend/core/protocol/transfer_seal_request.dart';
import 'package:nearsend/core/protocol/transfer_state.dart';
import 'package:nearsend/core/storage/idempotency_repository.dart';
import 'package:nearsend/core/storage/transfer_repository.dart';

/// The staging use cases.
class TransferStagingEndpoint {
  TransferStagingEndpoint({
    required this.idempotency,
    required this.transfers,
    required this.staging,
    int Function()? now,
  }) : now = now ?? _systemNow;

  /// §9's durable record of request ids, for the seal.
  final IdempotencyRepository idempotency;

  /// Moves the task to `WAITING_ACCEPT` once the manifest is frozen.
  final TransferRepository transfers;

  /// Finds the staging for the transfer in the path.
  final ManifestStagingRegistry staging;

  /// Clock injection.
  final int Function() now;

  static int _systemNow() => DateTime.now().millisecondsSinceEpoch;

  /// `PUT /transfers/{id}/manifest`.
  ///
  /// Takes the page and the transfer id; the pipeline has already validated the path and the
  /// credential, so this does not re-check either.
  ControlResponse putManifest({
    required String transferId,
    required Map<String, Object?> body,
  }) {
    final ManifestPage page = ManifestPage.parse(body);
    // §6's re-send rule: both outcomes are a success, because the page is accounted for
    // either way and a client with a lost response cannot tell them apart.
    staging.addPage(transferId, page, nowMillis: now());

    return ControlResponse.json(status: 200, body: const StoredAck().toJson());
  }

  /// `POST /transfers/{id}/seal`.
  ControlResponse seal({
    required String transferId,
    required Map<String, Object?> body,
    required ControlRequest request,
  }) {
    final TransferSealRequest sealRequest = TransferSealRequest.parse(body);
    final IdempotencyExecution execution = idempotency.executeAtomically(
      scope: RequestScope(
        transferId: transferId,
        operation: ProtocolOperation.seal,
        credentialFingerprint: credentialFingerprintOf(request),
      ),
      requestId: sealRequest.requestId,
      requestDigest: sealRequest.requestDigest,
      // No write generation yet: §8 allocates one at the first resume, and sealing is a
      // conclusion about the manifest rather than a write to a file.
      leaseEpoch: 0,
      effect: () {
        final ManifestStaging target = staging.stagingFor(transferId);
        // §7: "摘要失败422". The digest in the body is the client's claim; the one the
        // transfer was created with is the authority. Checked here rather than before the
        // idempotency lookup so that §9's rules still see the request first: a retry that
        // reuses the request id with a different digest is a *conflict*, and a fresh request
        // whose digest disagrees with the declaration is a manifest mismatch. Checking it
        // earlier would report every id reuse as the second of those.
        if (sealRequest.manifestDigest != target.manifestDigest) {
          throw const ProtocolViolation(
            ProtocolErrorCode.manifestMismatch,
            'the seal names a different manifest digest than the transfer declared',
          );
        }

        // §6's order lives in `seal`: gaps, duplicate file ids, chunk records, and the total
        // digest last. A failure here throws `MANIFEST_MISMATCH` and the transaction rolls
        // back, so the task stays in `STAGING` and the client may add more pages and retry -
        // §6: "不能进入 WAITING_ACCEPT".
        target.seal();
        transfers.transitionTask(
          taskId: transferId,
          to: TransferState.waitingAccept,
        );
        return StateResponse(TransferState.waitingAccept).toJson();
      },
    );

    switch (execution.kind) {
      case IdempotencyExecutionKind.executed:
      case IdempotencyExecutionKind.replayed:
        staging.release(transferId, StagingReleaseReason.sealed);
        return ControlResponse.json(status: 200, body: _sealedBody(execution));

      case IdempotencyExecutionKind.inFlight:
        // §9: a request id still being processed answers 202. The task is still staging as
        // far as this response knows, so that is what it reports rather than a state the
        // server has not committed.
        return ControlResponse.json(
          status: 202,
          body: StateResponse(TransferState.staging).toJson(),
        );

      case IdempotencyExecutionKind.conflict:
        throw ProtocolViolation(
          ProtocolErrorCode.requestIdConflict,
          'requestId ${sealRequest.requestId} was already used for sealing '
          '$transferId with a different manifest digest',
        );
    }
  }

  /// The §7 seal body, from the stored result when there is one.
  Map<String, Object?> _sealedBody(IdempotencyExecution execution) {
    final Map<String, Object?>? stored = execution.result;
    if (stored == null) {
      return StateResponse(TransferState.waitingAccept).toJson();
    }
    // Parsed rather than passed through, for the same reason as the creation endpoint: a
    // stored body this build cannot read was written by another version.
    return StateResponse.parse(stored).toJson();
  }

  /// The pipeline closures, keyed by route name by the assembling code.
  Map<String, ControlHandler> handlers() => <String, ControlHandler>{
    ApiRoutes.putManifest.name:
        (
          ControlRequest request,
          MatchedApiRequest matched,
          ControlAuthorized authorization,
        ) async => putManifest(
          transferId: _requireTransfer(matched),
          body: request.decodeJsonBody(scope: 'the manifest page'),
        ),
    ApiRoutes.seal.name:
        (
          ControlRequest request,
          MatchedApiRequest matched,
          ControlAuthorized authorization,
        ) async => seal(
          transferId: _requireTransfer(matched),
          body: request.decodeJsonBody(scope: 'the seal request'),
          request: request,
        ),
  };

  /// The transfer in the path. §7 puts `{id}` on both routes, and the router has already
  /// validated it as a canonical UUID.
  static String _requireTransfer(MatchedApiRequest matched) {
    final String? transferId = matched.transferId;
    if (transferId == null) {
      // Unreachable for these templates; refusing rather than sending `null` to the storage
      // layer keeps a route-table mistake from becoming a confusing storage error.
      throw const ProtocolViolation(
        ProtocolErrorCode.notFound,
        'the route carries no transfer id',
      );
    }
    return transferId;
  }
}
