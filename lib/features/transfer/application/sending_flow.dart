import 'dart:io';

import 'package:flutter/foundation.dart';

import 'package:nearsend/core/protocol/api_responses.dart';
import 'package:nearsend/core/protocol/manifest.dart';
import 'package:nearsend/core/protocol/protocol_limits.dart';
import 'package:nearsend/core/protocol/relative_path.dart';
import 'package:nearsend/core/protocol/transfer_direction.dart';
import 'package:nearsend/core/protocol/transfer_state.dart';
import 'package:nearsend/core/security/pairing_service.dart';
import 'package:nearsend/core/storage/receiver_mirror_repository.dart';
import 'package:nearsend/core/transfer/transfer_engine.dart';
import 'package:nearsend/features/transfer/application/file_selection_controller.dart';
import 'package:nearsend/features/transfer/application/sending_session.dart';
import 'package:nearsend/features/transfer/application/transfer_flow.dart';
import 'package:nearsend/features/transfer/presentation/file_selection_page.dart';
import 'package:nearsend/features/transfer/presentation/transfer_progress.dart';

/// The send half of a transfer, from a selection to bytes at the peer.
///
/// ## The step that is easy to leave out
///
/// §6 makes the receiver's decision a real step: only the receiver may accept, and no file byte may
/// move before it does. So after the offer is sealed the sender has something to **wait** for, and
/// the only way to learn that the peer accepted is to ask - `GET /authorization` answers `404` until
/// it has, deliberately, so that nobody can tell whether an approval exists before it does. This
/// class polls that route within a bound and says 等待对方接受 while it does. A sender that skipped
/// the wait and started pushing bytes would be sending into a refusal.
///
/// ## Why the last phase is not 完成
///
/// When the peer has acknowledged every chunk the sender knows the bytes **arrived**. It does not
/// know they were verified against the frozen manifest, that they were saved where the user asked,
/// or that the file survived a sync - those are the receiver's work and the receiver's statement.
/// §7 says it in one line: 下载成功不代表接收端持久化. So the sending side ends at
/// [SendPhase.awaitingVerification], and 完成 is shown by the side that did the verifying.
///
/// ## Progress
///
/// Per file, from the peer's own acknowledgements (see [TransferFlow]): a sender counting bytes
/// handed to a socket would keep climbing while the peer refused every one of them. The chunk
/// length is the protocol's and the last chunk of a file is shorter, so the figure is clamped by the
/// file's frozen length rather than by arithmetic that would overshoot it.
class SendingFlow extends ChangeNotifier {
  SendingFlow({
    required this.session,
    required this.selection,
    required this.now,
    this.mirror,
    this.ownSessionId,
    this.peerHasPaired = _noPeerYet,
    this.peerFetchInterval = const Duration(milliseconds: 500),
    this.peerFetchTimeout = const Duration(seconds: 120),
    this.authorizationPollInterval = const Duration(milliseconds: 750),
    this.authorizationTimeout = const Duration(seconds: 120),
    String Function()? transferIdFactory,
  }) : _transferIdFactory = transferIdFactory ?? randomUuidV4;

  final SendingSession session;

  /// The picker and the report rules, shared with the selection screen so both describe a selection
  /// the same way and a file the picker could not size is withheld by the same rule in both.
  final FileSelectionController selection;

  /// The clock, injected so a test can state timestamps instead of racing them.
  final int Function() now;

  /// What the receiver has reported about this transfer (§9's mirror on the sending side).
  ///
  /// Needed by the offering mode and not by the pushing one: when this device is the **server**, the
  /// peer pulls the bytes, so the only figure this side has is the one the peer sends back. The
  /// mirror is exactly what §9 creates for that.
  final ReceiverMirrorRepository? mirror;

  /// The session this device published, which a peer becomes a client of by pairing with it (§3).
  final String? ownSessionId;

  /// Whether a peer has actually paired with [ownSessionId].
  ///
  /// This is what decides the mode. §6 lists offers to the session a transfer is bound to, so an
  /// offer made as a server is invisible to a peer that never paired with this device - and a sender
  /// that chose that path without asking would be waiting for something the other end cannot see.
  ///
  /// A callback rather than a value because the answer arrives from outside: a peer may pair with
  /// this device after the screen was built, and a decision taken at construction time would be
  /// stale exactly when it matters.
  final bool Function() peerHasPaired;

  static bool _noPeerYet() => false;

  /// How often the offering mode asks whether the peer has taken anything yet.
  final Duration peerFetchInterval;

  /// How long the offering mode waits for the peer to finish before giving up.
  final Duration peerFetchTimeout;

  /// How often the sender asks whether the peer has accepted yet.
  final Duration authorizationPollInterval;

  /// How long the sender waits for that answer before giving up.
  final Duration authorizationTimeout;

  final String Function() _transferIdFactory;

  SendPhase _phase = SendPhase.empty;
  final List<SelectedFile> _files = <SelectedFile>[];
  FileSelectionReport _report = FileSelectionReport.of(const <SelectedFile>[]);
  String? _failureReason;
  TransferFlow? _flow;
  OutgoingPlan? _plan;
  int _currentIndex = 0;
  SendMode _mode = SendMode.push;

  SendPhase get phase => _phase;

  /// How this transfer is being moved: pushed by this device, or offered for the peer to pull.
  SendMode get mode => _mode;

  List<SelectedFile> get files => List<SelectedFile>.unmodifiable(_files);

  FileSelectionReport get report => _report;

  String? get failureReason => _failureReason;

  /// The figures for the file in flight, or null before anything is.
  TransferProgress? get progress => _flow?.progress;

  /// Which file of the transfer is in flight, one-based for display; 0 when none is.
  int get currentFileNumber => _flow == null ? 0 : _currentIndex + 1;

  int get fileCount => _plan?.manifest.files.length ?? _files.length;

  /// The name of the file in flight, taken from the frozen manifest rather than from the selection:
  /// the manifest is what the receiver will write, and a screen showing a different name would be
  /// describing a file that does not exist.
  String? get currentFileName => _plan == null || _flow == null
      ? null
      : _plan!.manifest.files[_currentIndex].relativePath;

  /// Whether a send may be started now.
  bool get canSend => _phase != SendPhase.preparing && _report.canSend;

  /// Opens the platform picker and folds what came back into the selection.
  Future<void> pick() async {
    _merge(await selection.pick());
  }

  /// Adds [paths] to the selection, for a platform whose files are paths.
  ///
  /// A path platform has no picker in this build, so the size comes from the filesystem instead of
  /// from the user; a path that cannot be read becomes a reason the selection cannot be sent rather
  /// than an entry that fails later inside planning with a message about hashing.
  Future<void> addPaths(Iterable<String> paths) async {
    final List<SelectedFile> added = <SelectedFile>[];
    final List<String> problems = <String>[];

    for (final String path in paths) {
      final String name = path.split(RegExp(r'[\\/]')).last;
      if (_files.any((SelectedFile chosen) => chosen.sourceRef == path)) {
        continue;
      }
      final int size;
      try {
        size = await File(path).length();
      } on Object {
        problems.add('无法读取文件：$name');
        continue;
      }
      // §5.1's rules, applied here for the same reason the picker path applies them: a name the
      // wire will refuse should be refused before the user waits for a manifest upload to fail.
      try {
        RelativePathRules.validate(name);
      } on Object {
        problems.add('文件名不符合协议要求：$name');
        continue;
      }
      added.add(
        SelectedFile(
          fileId: (selection.idFactory ?? randomUuidV4)(),
          relativePath: name,
          sizeBytes: size,
          sourceRef: path,
        ),
      );
    }

    _merge(
      FileSelectionReport.of(<SelectedFile>[..._files, ...added]),
      extraProblems: problems,
    );
  }

  /// Empties the selection.
  void clear() {
    _files.clear();
    _report = FileSelectionReport.of(const <SelectedFile>[]);
    _flow = null;
    _plan = null;
    _failureReason = null;
    _currentIndex = 0;
    _notify();
  }

  /// Runs the whole sequence, returning whether the transfer reached the peer.
  ///
  /// Two modes, chosen before anything is proposed. **Pushing** is the client's: this device uploads
  /// a manifest to the peer and sends chunks, and §6 makes the peer's decision a step it waits for.
  /// **Offering** is the server's: this device stages the manifest and lists it to the session the
  /// peer paired with, and the peer pulls - so progress here is whatever the peer reports back, and
  /// the end is not "the bytes left" but "the peer said it saved them".
  ///
  /// Offering is preferred whenever a peer has actually paired with this device, because it is the
  /// one path whose other end exists in this application: the receiving screen answers offers, while
  /// a push needs the peer to accept as a *server*, which this build does not do. Choosing by what
  /// the other end can see is the difference between a transfer and a wait.
  Future<bool> send() async {
    if (!canSend) {
      return false;
    }
    final FileSelectionReport chosen = _report;
    _failureReason = null;
    _set(SendPhase.preparing);

    try {
      return peerHasPaired() && ownSessionId != null
          ? await _offer(chosen)
          : await _push(chosen);
    } on Object catch (error) {
      _failureReason = failureText(error);
      _flow?.applyFailure(_failureReason!, atMillis: now());
      _set(SendPhase.failed);
      return false;
    }
  }

  /// Offers the transfer and waits for the peer to take it (§6, server side).
  Future<bool> _offer(FileSelectionReport chosen) async {
    _mode = SendMode.offer;
    final OutgoingPlan plan = await session.engine.prepareOutgoing(
      transferId: _transferIdFactory(),
      direction: TransferDirection.serverToClient,
      peerId: ownSessionId,
      choices: selection.choicesFor(chosen),
    );
    _plan = plan;
    _flow = TransferFlow.forTotal(
      totalBytes: plan.manifest.totalBytes,
      atMillis: now(),
    );
    _currentIndex = 0;
    _set(SendPhase.offeredToPeer);

    // The other end has to find it, accept it, pull it and save it. Nothing here can be hurried:
    // every step after this one belongs to the peer, and the only figure this side has is the one
    // the peer reports (§9's mirror).
    final Stopwatch waited = Stopwatch()..start();
    while (waited.elapsed < peerFetchTimeout) {
      final ReceiverMirror? reported = mirror?.read(plan.transferId);
      if (reported != null) {
        _flow?.applyReportedBytes(reported.committedBytes, atMillis: now());
        _notify();
      }
      final TransferState state = session.engine.transfers.taskState(
        plan.transferId,
      );
      if (state == TransferState.completed) {
        _flow?.applyCompleted(atMillis: now());
        _set(SendPhase.savedByPeer);
        return true;
      }
      if (state == TransferState.cancelled ||
          state == TransferState.failed ||
          state == TransferState.partiallyCompleted) {
        throw SendingRefused('对方没有完成这次传输（${state.wireName}）。');
      }
      await Future<void>.delayed(peerFetchInterval);
    }
    throw SendingRefused(
      '等待对方取走文件超时（${peerFetchTimeout.inSeconds} 秒）：对方可能还没有连接到本机。',
    );
  }

  /// Pushes the transfer to the peer and waits for its decision (§6, client side).
  Future<bool> _push(FileSelectionReport chosen) async {
    _mode = SendMode.push;
    final OutgoingPlan plan = await session.plan(
      transferId: _transferIdFactory(),
      choices: selection.choicesFor(chosen),
    );
    _plan = plan;
    await session.propose(plan);
    _set(SendPhase.waitingForPeer);

    final ResumeGranted granted = await _awaitAcceptance(plan);
    _set(SendPhase.sending);

    for (int index = 0; index < plan.manifest.files.length; index++) {
      final ManifestFile file = plan.manifest.files[index];
      _currentIndex = index;
      _flow = TransferFlow.forTotal(
        totalBytes: file.sizeBytes,
        atMillis: now(),
      );
      _notify();

      await session.sendFile(
        plan: plan,
        granted: granted,
        fileId: file.fileId,
        onProgress: (int acknowledged, int totalChunks) {
          // The protocol's chunk length rather than the bytes that were sent: §8 makes the frozen
          // manifest the authority on what a chunk is, so the figure is derived from the same
          // lengths the receiver is checking against, and [TransferProgress] clamps the short
          // last chunk to the file's frozen length.
          _flow?.applyChunkAcknowledged(
            acknowledged: acknowledged,
            chunkBytes: ProtocolLimits.chunkSizeBytes,
            atMillis: now(),
          );
          _notify();
        },
      );
      // Deliberately **not** `applyCompleted`: every chunk acknowledged means the bytes reached
      // the peer, not that the file was verified against the frozen manifest and saved. Marking
      // the file complete here would put 已完成 on a sending screen, which is the one word this
      // whole flow is arranged to avoid - the figure instead reads that the bytes of this file are
      // all sent, and the phase stays 传输中 until the transfer moves to its own last state.
      _notify();
    }

    _set(SendPhase.awaitingVerification);
    return true;
  }

  /// Asks whether the peer has accepted, until it has or the bound runs out.
  ///
  /// §6 makes the decision the receiver's own and §7 makes the route answer `404` before it exists,
  /// so waiting is not a workaround for a missing notification - it is the only correct reading of
  /// the protocol. The bound exists because "waiting forever" is not a state a user can be shown.
  Future<ResumeGranted> _awaitAcceptance(OutgoingPlan plan) async {
    final Stopwatch waited = Stopwatch()..start();
    Object? last;
    while (waited.elapsed < authorizationTimeout) {
      try {
        return await session.openWriteGeneration(plan);
      } on Object catch (error) {
        last = error;
      }
      await Future<void>.delayed(authorizationPollInterval);
    }
    throw SendingRefused(
      '等待对方接受超时（${authorizationTimeout.inSeconds} 秒）：对方可能没有确认这次传输。',
      cause: last,
    );
  }

  /// Folds a new report into the selection.
  ///
  /// Keyed by the source reference so choosing the same file twice is one entry rather than two
  /// manifest rows for one user file - which the receiver would write out twice.
  void _merge(
    FileSelectionReport picked, {
    List<String> extraProblems = const <String>[],
  }) {
    final Map<String, SelectedFile> byReference = <String, SelectedFile>{
      for (final SelectedFile file in _files)
        if (file.sourceRef != null) file.sourceRef!: file,
    };
    for (final SelectedFile file in picked.files) {
      final String? reference = file.sourceRef;
      if (reference != null) {
        byReference[reference] = file;
      }
    }
    _files
      ..clear()
      ..addAll(byReference.values);

    final FileSelectionReport base = FileSelectionReport.of(_files);
    _report = FileSelectionReport(
      files: base.files,
      totalBytes: base.totalBytes,
      problems: <String>[
        ...base.problems,
        ...picked.problems,
        ...extraProblems,
      ],
    );
    _flow = null;
    _plan = null;
    _currentIndex = 0;
    _set(_report.canSend ? SendPhase.ready : SendPhase.empty);
  }

  void _set(SendPhase phase) {
    _phase = phase;
    _notify();
  }

  void _notify() => notifyListeners();
}

/// How a sending flow moves the bytes.
enum SendMode {
  /// This device is the client: it proposes to the peer, uploads the manifest and pushes chunks.
  push,

  /// This device is the server: it stages the manifest, lists the offer to the peer's session, and
  /// the peer pulls. §6 has no push, so the peer finds it by asking.
  offer,
}

/// Where a sending flow is.
enum SendPhase {
  /// Nothing sendable is selected.
  empty,

  /// A sendable selection, with nothing started.
  ready,

  /// Reading the sources and building the manifest - the one long local step, and the one §5.2's
  /// digests make unavoidable before the peer hears anything.
  preparing,

  /// The offer is sealed and the peer has not accepted yet (§6).
  waitingForPeer,

  /// The offer is staged and listed to the peer's session; the peer has not taken it yet (§6, server
  /// side). Nothing can be hurried from here - the next move is the peer's.
  offeredToPeer,

  /// The peer accepted; chunks are moving.
  sending,

  /// Every chunk was acknowledged. **Not** 完成: verifying and saving are the receiver's work.
  awaitingVerification,

  /// The peer reported that it verified and saved the file.
  ///
  /// This is the one sending state where the completion is **earned**, because it is not this
  /// device's opinion: the receiver said so through §10's `complete`, and §9's mirror is where the
  /// figure came from.
  savedByPeer,

  /// Stopped, with a reason the user can act on.
  failed,
}

/// A refusal raised by this layer rather than by the protocol.
class SendingRefused implements Exception {
  SendingRefused(this.detail, {this.cause});

  final String detail;

  /// What the peer last said, kept for diagnosis and never rendered as the reason.
  final Object? cause;

  @override
  String toString() => 'SendingRefused($detail)';
}

/// The sentence a failure is shown with.
///
/// Deliberately narrow: a refusal this layer raised already carries words written for a user, and
/// everything else collapses into one sentence, because an exception's text is written for whoever
/// reads logs - and it may name a path or a document id. It says nothing about resuming, because
/// this layer does not resume: `send` starts a transfer, and continuing one is a separate path that
/// needs the receiver's committed rows and its own secret.
String failureText(Object error) =>
    error is SendingRefused ? error.detail : '传输未能完成：连接可能已中断。';
