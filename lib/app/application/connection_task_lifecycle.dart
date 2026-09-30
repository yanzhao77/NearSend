import 'package:nearsend/core/protocol/transfer_state.dart';
import 'package:nearsend/core/storage/task_credential_repository.dart';
import 'package:nearsend/core/storage/transfer_repository.dart';

/// Ends network access for the selected connection's tasks. Checkpoint rows,
/// resume secrets and successfully exported files are never deleted.
void interruptConnectionTasks({
  required Iterable<String> taskIds,
  required TransferRepository transfers,
  required TaskCredentialRepository credentials,
}) {
  for (final id in taskIds) {
    final state = transfers.taskState(id);
    if (state.isTerminal) continue;
    credentials.revokeAccessToken(id);
    if (TransferStateMachine.canTransition(state, TransferState.interrupted)) {
      transfers.transitionTask(taskId: id, to: TransferState.interrupted);
    } else if (state != TransferState.verifying &&
        state != TransferState.exporting &&
        state != TransferState.paused &&
        state != TransferState.interrupted &&
        TransferStateMachine.canTransition(state, TransferState.failed)) {
      // A proposal not yet accepted has no defined INTERRUPTED edge. Report
      // failure rather than leaving an abandoned offer indefinitely waiting.
      transfers.transitionTask(taskId: id, to: TransferState.failed);
    }
  }
}
