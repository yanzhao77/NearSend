/// Transfer and per-file state machines, `docs/protocol/v1.0-draft1.md` §10 and
/// `docs/architecture/SYSTEM_ARCHITECTURE.md` §7.
///
/// ## Why transitions are annotated
///
/// §10 describes the machine in prose and only states *entry* into several states:
/// it says "network loss goes to INTERRUPTED" without saying from where, and it never
/// says how BLOCKED, FAILED or PARTIALLY_COMPLETED are left. Those are not details a
/// protocol may leave to each implementation, because two peers with different exit
/// rules will disagree about whether a task is still resumable.
///
/// So every edge below carries a [TransitionSource]: either it is literally in §10, or
/// it is a documented derivation needed to connect two stated pieces. Anything that is
/// neither is **absent**, and the absence is made executable by
/// [TransferStateMachine.statesWithoutDefinedExit] and asserted in the tests, rather
/// than being quietly filled in.
library;

import 'package:nearsend/core/protocol/protocol_exception.dart';

/// Where a transition's authority comes from.
enum TransitionSource {
  /// Written directly in §10.
  stated,

  /// Needed to connect two stated facts; the derivation is explained where used.
  derived,

  /// Required by another project document but absent from the protocol draft. Present
  /// only where the machine would otherwise be unusable, and registered as a gap.
  crossDocument,
}

/// A single allowed transition.
class TransferTransition {
  const TransferTransition(this.from, this.to, this.source, this.rationale);

  final TransferState from;
  final TransferState to;
  final TransitionSource source;

  /// Why this edge exists, quoting §10 where it is stated.
  final String rationale;

  @override
  String toString() => '${from.name} -> ${to.name} (${source.name})';
}

/// Task-level states.
///
/// `docs/architecture/SYSTEM_ARCHITECTURE.md` §7 also proposes friendlier domain names
/// (`draft`, `preparing`, `awaiting_connection`, ...). The protocol's §10 names are the
/// wire authority, so they are used here; mapping to display language belongs to the
/// UI layer.
enum TransferState {
  /// Sender-local preparation. §10: no network data transfer before the manifest is
  /// frozen.
  preparing,

  /// An offer exists and its manifest is being uploaded; not yet accepted.
  staging,

  /// Manifest sealed and complete; waiting for the receiver's decision.
  waitingAccept,

  /// Accepted and authorised; a write generation exists.
  ready,

  /// Chunks are moving.
  transferring,

  /// A pause has been requested; in-flight chunks are settling.
  pausing,

  /// Paused with a durable checkpoint.
  paused,

  /// The link dropped. Distinct from `paused` so recovery can be distinguished from a
  /// user action.
  interrupted,

  /// Recovery is underway: local committed chunks are being re-checked. §10 requires
  /// the UI to say so rather than implying a fresh start.
  checkingResume,

  /// All chunks are committed; the whole-file digest is being recomputed.
  verifying,

  /// Verification passed; results are being written to the user's location.
  exporting,

  /// Every selected file is verified and its export is committed.
  completed,

  /// Queue processing finished with some files still incomplete.
  partiallyCompleted,

  /// Blocked on something outside the protocol: permissions, space, a changed source.
  blocked,

  /// Unrecoverable protocol error.
  failed,

  /// Cancelled locally.
  cancelled;

  /// States from which no further transfer work happens.
  ///
  /// `completed` and `cancelled` are legitimately terminal. `failed`,
  /// `partiallyCompleted` and `blocked` are terminal **only because the draft does not
  /// define how to leave them** - see
  /// [TransferStateMachine.statesWithoutDefinedExit].
  bool get isTerminal =>
      this == completed ||
      this == cancelled ||
      this == failed ||
      this == partiallyCompleted;

  /// Whether chunks may be moving or about to move.
  bool get isActive =>
      this == transferring || this == pausing || this == checkingResume;

  /// Whether the task reached a state a user would call finished.
  bool get isSuccess => this == completed;

  /// The name §10 and §7 use for this state on the wire.
  ///
  /// The draft writes states in UPPER_SNAKE (`WAITING_ACCEPT`, `CHECKING_RESUME`) while
  /// Dart convention makes the constants camelCase. Deriving the wire name from the
  /// constant instead of listing it in a second table means the two cannot drift: a
  /// renamed constant changes both, and there is no table to forget to update.
  String get wireName {
    final StringBuffer out = StringBuffer();
    for (int i = 0; i < name.length; i++) {
      final int unit = name.codeUnitAt(i);
      if (unit >= 0x41 && unit <= 0x5A) {
        if (i > 0) {
          out.write('_');
        }
        out.writeCharCode(unit);
      } else {
        out.writeCharCode(unit - 0x20);
      }
    }
    return out.toString();
  }

  /// Parses a wire state name, or returns null when §10 does not define it.
  ///
  /// Null rather than a default: a state this build does not know is not something to
  /// guess at, because guessing wrong is how two peers disagree about whether a task is
  /// still resumable.
  static TransferState? fromWireName(String value) {
    for (final TransferState state in TransferState.values) {
      if (state.wireName == value) {
        return state;
      }
    }
    return null;
  }
}

/// The task state machine.
abstract final class TransferStateMachine {
  /// Every allowed edge, each with its authority.
  ///
  /// Ordered for readability, not for execution.
  static final List<TransferTransition> transitions = <TransferTransition>[
    // --- The happy path, stated verbatim in §10. ---
    _t(
      TransferState.staging,
      TransferState.waitingAccept,
      TransitionSource.stated,
      '§10: STAGING→WAITING_ACCEPT',
    ),
    _t(
      TransferState.waitingAccept,
      TransferState.ready,
      TransitionSource.stated,
      '§10: WAITING_ACCEPT→READY',
    ),
    _t(
      TransferState.ready,
      TransferState.transferring,
      TransitionSource.stated,
      '§10: READY→TRANSFERRING',
    ),
    _t(
      TransferState.transferring,
      TransferState.verifying,
      TransitionSource.stated,
      '§10: TRANSFERRING→VERIFYING',
    ),
    _t(
      TransferState.verifying,
      TransferState.exporting,
      TransitionSource.stated,
      '§10: VERIFYING→EXPORTING',
    ),
    _t(
      TransferState.exporting,
      TransferState.completed,
      TransitionSource.stated,
      '§10: EXPORTING→COMPLETED',
    ),

    // --- Pause, stated verbatim. ---
    _t(
      TransferState.transferring,
      TransferState.pausing,
      TransitionSource.stated,
      '§10: TRANSFERRING→PAUSING→PAUSED',
    ),
    _t(
      TransferState.pausing,
      TransferState.paused,
      TransitionSource.stated,
      '§10: TRANSFERRING→PAUSING→PAUSED',
    ),

    // --- Recovery, stated as CHECKING_RESUME→READY/TRANSFERRING. The draft does not
    // name which states may enter CHECKING_RESUME; PAUSED and INTERRUPTED are the two
    // states a task can be waiting in when the user retries, so those edges are
    // derived. A task in READY or TRANSFERRING does not need a resume. ---
    _t(
      TransferState.paused,
      TransferState.checkingResume,
      TransitionSource.derived,
      '§10 gives 恢复→CHECKING_RESUME without naming the source state; PAUSED is the '
      'state a user resumes from',
    ),
    _t(
      TransferState.interrupted,
      TransferState.checkingResume,
      TransitionSource.derived,
      '§10 gives 恢复→CHECKING_RESUME without naming the source state; INTERRUPTED is '
      'the state a dropped link leaves behind',
    ),
    _t(
      TransferState.checkingResume,
      TransferState.ready,
      TransitionSource.stated,
      '§10: 恢复→CHECKING_RESUME→READY/TRANSFERRING',
    ),
    _t(
      TransferState.checkingResume,
      TransferState.transferring,
      TransitionSource.stated,
      '§10: 恢复→CHECKING_RESUME→READY/TRANSFERRING',
    ),

    // --- Preparation to staging. §10 calls PREPARING sender-local and starts the
    // transfer machine at STAGING, so the join between them is derived. ---
    _t(
      TransferState.preparing,
      TransferState.staging,
      TransitionSource.derived,
      '§10: PREPARING is sender-local and the transfer machine starts at STAGING; the '
      'join is not written out',
    ),

    // --- Interruption. §10 gives 网络断开→INTERRUPTED without naming the sources.
    // READY and TRANSFERRING are limited to states where a link is actually in use. ---
    _t(
      TransferState.ready,
      TransferState.interrupted,
      TransitionSource.derived,
      '§10: 网络断开→INTERRUPTED, source states not enumerated',
    ),
    _t(
      TransferState.transferring,
      TransferState.interrupted,
      TransitionSource.derived,
      '§10: 网络断开→INTERRUPTED, source states not enumerated',
    ),

    // --- Blocking. §10 gives 缺权限/空间/源变化→BLOCKED without naming the sources. ---
    _t(
      TransferState.ready,
      TransferState.blocked,
      TransitionSource.derived,
      '§10: 缺权限/空间/源变化→BLOCKED, source states not enumerated',
    ),
    _t(
      TransferState.transferring,
      TransferState.blocked,
      TransitionSource.derived,
      '§10: 缺权限/空间/源变化→BLOCKED, source states not enumerated',
    ),

    // --- Unrecoverable failure. §10 gives 不可恢复协议错误→FAILED without naming the
    // sources; any active state can encounter one. ---
    for (final TransferState from in <TransferState>[
      TransferState.preparing,
      TransferState.staging,
      TransferState.waitingAccept,
      TransferState.ready,
      TransferState.transferring,
      TransferState.pausing,
      TransferState.paused,
      TransferState.interrupted,
      TransferState.checkingResume,
      TransferState.verifying,
      TransferState.exporting,
    ])
      _t(
        from,
        TransferState.failed,
        TransitionSource.derived,
        '§10: 不可恢复协议错误→FAILED, source states not enumerated',
      ),

    // --- Queue end with leftovers. §10 gives 队列处理结束但有未完成项→
    // PARTIALLY_COMPLETED without naming the sources. ---
    for (final TransferState from in <TransferState>[
      TransferState.ready,
      TransferState.transferring,
      TransferState.paused,
      TransferState.interrupted,
      TransferState.verifying,
      TransferState.exporting,
    ])
      _t(
        from,
        TransferState.partiallyCompleted,
        TransitionSource.derived,
        '§10: 队列处理结束但有未完成项→PARTIALLY_COMPLETED, sources not enumerated',
      ),

    // --- Cancellation. §10: 所有状态可本地取消→CANCELLED. ---
    for (final TransferState from in TransferState.values)
      if (from != TransferState.cancelled &&
          from != TransferState.completed &&
          from != TransferState.failed &&
          from != TransferState.partiallyCompleted)
        _t(
          from,
          TransferState.cancelled,
          TransitionSource.stated,
          '§10: 所有状态可本地取消→CANCELLED',
        ),
  ];

  /// States that cannot be left by any defined transition.
  ///
  /// `completed` and `cancelled` belong here by design. `failed` and
  /// `partiallyCompleted` are here **because §10 never defines how to leave them**, and
  /// that is a genuine problem: the product requires retrying only the failed items of a
  /// partially completed queue
  /// (`docs/跨平台离线文件互传系统技术方案_V2.1.md` §16.1), which is impossible if those
  /// states have no exit at all.
  ///
  /// This list is asserted in the tests, so closing the gap requires deliberately
  /// changing both this file and its test.
  static Set<TransferState> get statesWithoutDefinedExit {
    final Set<TransferState> sources = _bySource.keys.toSet();
    return TransferState.values
        .where((TransferState state) => !sources.contains(state))
        .toSet();
  }

  /// States whose **only** exit is cancellation.
  ///
  /// A different and equally serious gap. `blocked` is entered for a missing permission,
  /// missing space or a changed source, and §11 answers `SPACE_INSUFFICIENT` with "free
  /// space or change location, then retry" - which is unreachable if the only way out of
  /// `blocked` is to cancel. Cancelling also discards the recovery data the user was
  /// told would be preserved.
  static Set<TransferState> get statesThatCanOnlyBeCancelled => TransferState
      .values
      .where(
        (TransferState state) =>
            nextStates(state).length == 1 &&
            nextStates(state).contains(TransferState.cancelled),
      )
      .toSet();

  /// States that no transition may leave, by design rather than by omission.
  static const Set<TransferState> deliberatelyTerminal = <TransferState>{
    TransferState.completed,
    TransferState.cancelled,
  };

  /// Whether [to] is reachable from [from] by a defined transition.
  static bool canTransition(TransferState from, TransferState to) =>
      _bySource[from]?.containsKey(to) ?? false;

  /// Throws unless the transition is defined.
  ///
  /// Callers must use this rather than assigning states directly: §10 requires every
  /// status change to be triggered by a defined event, and an undefined transition is
  /// exactly how two peers drift apart.
  static void assertTransition(TransferState from, TransferState to) {
    if (!canTransition(from, to)) {
      throw ProtocolViolation(
        ProtocolErrorCode.invalidState,
        'transition ${from.name} -> ${to.name} is not defined by §10',
      );
    }
  }

  /// The transitions defined out of [from].
  static Set<TransferState> nextStates(TransferState from) =>
      _bySource[from]?.keys.toSet() ?? const <TransferState>{};

  static final Map<TransferState, Map<TransferState, TransferTransition>>
  _bySource = _index();

  static Map<TransferState, Map<TransferState, TransferTransition>> _index() {
    final Map<TransferState, Map<TransferState, TransferTransition>> index =
        <TransferState, Map<TransferState, TransferTransition>>{};
    for (final TransferTransition transition in transitions) {
      final Map<TransferState, TransferTransition> targets =
          index[transition.from] ??= <TransferState, TransferTransition>{};
      if (targets.containsKey(transition.to)) {
        throw StateError(
          'duplicate transition ${transition.from.name} -> '
          '${transition.to.name}; the table must stay unambiguous',
        );
      }
      targets[transition.to] = transition;
    }
    return index;
  }

  static TransferTransition _t(
    TransferState from,
    TransferState to,
    TransitionSource source,
    String rationale,
  ) => TransferTransition(from, to, source, rationale);
}

/// Per-file states, `SYSTEM_ARCHITECTURE.md` §7 and §10's partial-completion rules.
///
/// Deliberately separate from the task machine: §10 requires one blocked file not to
/// erase finished ones, which is only expressible if file state is tracked per file.
enum FileState {
  /// Queued, not started.
  pending,

  /// Being scanned and hashed on the sender, or its sink being prepared.
  preparing,

  /// Chunks moving.
  transferring,

  /// All chunks committed; the whole-file digest is being recomputed for this file.
  verifying,

  /// Verified; being written to the user's location.
  exporting,

  /// Verified and its export is committed.
  completed,

  /// This file failed; other files continue.
  failed,

  /// The user or a policy skipped this file.
  skipped;

  bool get isTerminal => this == completed || this == failed || this == skipped;
}

/// The per-file state machine.
abstract final class FileStateMachine {
  /// Allowed file transitions.
  ///
  /// The forward chain matches the task chain's per-file meaning. The `-> failed` edges
  /// follow from §10's requirement that a single blocked file must not erase completed
  /// ones, which presupposes a per-file failure state.
  static final Map<FileState, Set<FileState>>
  transitions = <FileState, Set<FileState>>{
    FileState.pending: <FileState>{FileState.preparing, FileState.skipped},
    FileState.preparing: <FileState>{FileState.transferring, FileState.failed},
    FileState.transferring: <FileState>{FileState.verifying, FileState.failed},
    FileState.verifying: <FileState>{FileState.exporting, FileState.failed},
    FileState.exporting: <FileState>{FileState.completed, FileState.failed},
    FileState.completed: const <FileState>{},
    FileState.failed: const <FileState>{},
    FileState.skipped: const <FileState>{},
  };

  static bool canTransition(FileState from, FileState to) =>
      transitions[from]?.contains(to) ?? false;

  static void assertTransition(FileState from, FileState to) {
    if (!canTransition(from, to)) {
      throw ProtocolViolation(
        ProtocolErrorCode.invalidState,
        'file transition ${from.name} -> ${to.name} is not defined',
      );
    }
  }

  /// The states reachable from [from].
  static Set<FileState> nextStates(FileState from) =>
      transitions[from] ?? const <FileState>{};

  /// Whether the protocol draft defines a way to retry a failed file.
  ///
  /// It does not: `FileState.failed` has no outgoing edge. That collides with the
  /// product requirement to retry only the failed items of a partially completed queue
  /// (`docs/跨平台离线文件互传系统技术方案_V2.1.md` §16.1), and with §10's promise that
  /// a partially completed task can continue. The gap is registered in
  /// `docs/PROJECT_LEDGER.md` §5 and asserted here so it cannot be forgotten.
  static const bool retryOfFailedFilesIsDefined = false;
}
