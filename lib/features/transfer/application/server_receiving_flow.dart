import 'package:flutter/foundation.dart';

import 'package:nearsend/core/network/task_authorization_endpoint.dart';
import 'package:nearsend/core/protocol/manifest.dart';
import 'package:nearsend/core/protocol/transfer_direction.dart';
import 'package:nearsend/core/protocol/transfer_state.dart';
import 'package:nearsend/core/storage/space_plan.dart';
import 'package:nearsend/core/storage/transfer_repository.dart';
import 'package:nearsend/core/transfer/transfer_engine.dart';
import 'package:nearsend/features/transfer/application/transfer_flow.dart';
import 'package:nearsend/features/transfer/presentation/transfer_progress.dart';

/// An offer this device was asked to accept, as its own user sees it.
///
/// The declaration is what the proposing client sent when it created the transfer, so a screen can
/// describe the offer before deciding anything and without reading a manifest it has not accepted.
class ServerOffer {
  const ServerOffer({
    required this.transferId,
    required this.manifestDigest,
    required this.direction,
    this.fileCount = 0,
    this.totalBytes = 0,
  });

  final String transferId;

  /// The digest §6 makes the acceptance commit to.
  ///
  /// Nullable because the declaration holds what the creating client sent, and a task whose manifest
  /// was never sealed has none - which is exactly a task nobody can accept yet.
  final String? manifestDigest;

  /// The role this device plays, as the creating client declared it.
  final TransferDirection? direction;

  /// How many files the sealed manifest declares, and how many bytes in total.
  ///
  /// Both come from the sealed manifest rather than from the declaration, because §6 makes the
  /// manifest the authority for them - an offer built from anything else would be describing a
  /// different transfer than the one the user is being asked to accept.
  final int fileCount;
  final int totalBytes;

  @override
  String toString() => 'ServerOffer($transferId, ${direction?.wireValue})';
}

/// Receiving a transfer on the side that was asked for it (§6, server side).
///
/// ## Why this exists next to [ReceivingFlow]
///
/// The two are the same job from opposite ends of §7's roles. `ReceivingFlow` is a **client**
/// answering an offer the peer listed: it asks, decides, and pulls. This one is the **server**: a
/// client proposed a transfer *to this node*, the row is already in this node's own database, and
/// the bytes will arrive whether or not anybody is watching. So there is nothing to ask and nothing
/// to pull - the only two things this side has to do are decide, and finish.
///
/// ## What it deliberately does not do
///
/// It does not measure free space and it does not invent a location. §6 makes the acceptance a
/// commitment to a digest, a destination and a space estimate, and all three belong to the caller -
/// the first two are the user's answers and the third is a platform measurement this layer has no
/// way to take honestly. So [accept] takes a [ReceiverStorageContext] and passes it on.
///
/// It also does not send anything to the peer: §10's completion message is the **receiver's**, and
/// for `client_to_server` this node *is* the receiver - so it writes the task's own state and stops.
class ServerReceivingFlow extends ChangeNotifier {
  ServerReceivingFlow({
    required this.engine,
    required this.now,
    this.commitPollInterval = const Duration(milliseconds: 500),
    this.commitTimeout = const Duration(seconds: 300),
  });

  final TransferEngine engine;

  /// The clock, injected so a test can state timestamps instead of racing them.
  final int Function() now;

  /// How often this side asks whether the chunks have all arrived.
  final Duration commitPollInterval;

  /// How long it waits for them before giving up.
  final Duration commitTimeout;

  /// Said when the peer stopped before every chunk was committed.
  static const String interruptedReason = '对方没有传完就中断了。已提交的块保留在本机，可以稍后继续。';

  /// Said when a file failed its whole-file check.
  static const String failedVerificationReason = '收到的文件没有通过整文件校验，因此没有保存。';

  ServerReceivePhase _phase = ServerReceivePhase.waiting;
  List<ServerOffer> _pending = const <ServerOffer>[];
  String? _failureReason;
  TransferFlow? _flow;
  final List<String> _savedPaths = <String>[];
  int _currentIndex = 0;
  int _fileCount = 0;
  SpaceVerdict? _spaceVerdict;

  ServerReceivePhase get phase => _phase;

  /// What the space plan said about the transfer being received, once one has been measured.
  ///
  /// Exposed rather than swallowed because two of its three answers are things a user must be told:
  /// `unknown` means nobody measured the volumes, and a screen that showed it as a pass would be
  /// claiming a check that never happened.
  SpaceVerdict? get spaceVerdict => _spaceVerdict;

  /// What this device is being asked to accept, from its own database.
  List<ServerOffer> get pending => List<ServerOffer>.unmodifiable(_pending);

  String? get failureReason => _failureReason;

  TransferProgress? get progress => _flow?.progress;

  List<String> get savedPaths => List<String>.unmodifiable(_savedPaths);

  int get currentFileNumber => _flow == null ? 0 : _currentIndex + 1;

  int get fileCount => _fileCount;

  bool get isBusy =>
      _phase == ServerReceivePhase.receiving ||
      _phase == ServerReceivePhase.verifying;

  /// Reads what is waiting for this device's answer.
  ///
  /// §6's route for a client's view of offers is `GET /v1/offers`; this device is a server and its
  /// client may be asleep, so the question is asked of its own rows.
  Future<List<ServerOffer>> refresh() async {
    if (_disposed) {
      return const <ServerOffer>[];
    }
    final List<ServerOffer> found = <ServerOffer>[];
    for (final String transferId in engine.transfers.taskIdsInState(
      TransferState.waitingAccept,
    )) {
      final TransferDeclaration? declaration = engine.transfers.readDeclaration(
        transferId,
      );
      if (declaration == null) {
        continue;
      }
      // The same three conditions §7's `GET /v1/offers` applies to a client's view, because a
      // server's own user and its client must not be offered different things: the task must be
      // waiting for a decision, a **sealed** manifest must exist, and it must be the manifest the
      // declaration names. A transfer whose pages are still arriving is one that cannot be accepted
      // yet - §6 makes the seal the moment an offer becomes an offer - and listing it here would let
      // the user commit to a digest with nothing behind it.
      final FrozenManifest? frozen = engine.staging.frozenManifest(transferId);
      if (frozen == null ||
          frozen.manifestDigest != declaration.manifestDigest) {
        continue;
      }
      found.add(
        ServerOffer(
          transferId: transferId,
          manifestDigest: frozen.manifestDigest,
          direction: TransferDirection.fromWireValue(declaration.direction),
          fileCount: frozen.fileCount,
          totalBytes: frozen.totalBytes,
        ),
      );
    }
    _pending = found;
    if (_phase == ServerReceivePhase.waiting) {
      _notify();
    }
    return _pending;
  }

  /// Accepts [offer] and waits for the bytes to arrive, then verifies and saves them.
  ///
  /// [context] carries the space estimate and the volume identifiers the caller measured, and
  /// [targetRef] is where the files are written - the destination the user named.
  Future<bool> accept(
    ServerOffer offer, {
    required ReceiverStorageContext context,
    String? targetRef,
  }) async {
    if (isBusy) {
      return false;
    }
    _failureReason = null;
    _savedPaths.clear();
    _currentIndex = 0;
    _phase = ServerReceivePhase.accepting;
    _notify();

    try {
      // §6's space pre-check, run **before** the acceptance rather than after it: the engine's
      // `acceptLocally` persists the decision and the estimate but does not refuse a shortfall, so a
      // caller that skipped this would commit to a transfer that provably cannot fit. Only a
      // *proven* shortfall stops it - an unmeasurable volume is reported as unknown and left to the
      // user, because refusing on "we could not check" would refuse transfers that fit.
      final SpacePlan plan = const SpacePlanner().plan(
        files: <FileSpaceRequest>[
          for (final ManifestFile file in _manifestOf(offer))
            FileSpaceRequest(
              fileId: file.fileId,
              sizeBytes: file.sizeBytes,
              stagingVolume: context.stagingVolume,
              exportVolume: context.exportVolume,
              stagingAlreadyAllocatedBytes: 0,
            ),
        ],
        availability: context.availability,
        volumeForDatabase: context.databaseVolume,
      );
      _spaceVerdict = plan.verdict;
      if (plan.verdict == SpaceVerdict.insufficient) {
        throw const ServerReceiveRefused('空间不足：已按暂存与导出的峰值计算，需要先清理或更换保存位置。');
      }

      // §6: the acceptance is this device's, and it persists the digest, the location and the space
      // estimate together.
      engine.acceptLocally(transferId: offer.transferId, context: context);
      _phase = ServerReceivePhase.receiving;
      _notify();

      final List<String> files = engine.transfers.fileIds(offer.transferId);
      _fileCount = files.length;
      _flow = TransferFlow.unknownTotal(atMillis: now());

      final Stopwatch waited = Stopwatch()..start();
      while (!_allCommitted(files)) {
        if (waited.elapsed > commitTimeout) {
          throw const ServerReceiveRefused(interruptedReason);
        }
        final TransferState state = engine.transfers.taskState(
          offer.transferId,
        );
        if (state == TransferState.cancelled || state == TransferState.failed) {
          throw const ServerReceiveRefused(interruptedReason);
        }
        _flow?.applyReportedBytes(
          engine.tasks.committedBytesForTask(offer.transferId),
          atMillis: now(),
        );
        _notify();
        await Future<void>.delayed(commitPollInterval);
      }

      // Every chunk is committed, so the bytes are on this disk - and only now is there anything to
      // verify. §10's whole-file check is what decides whether they are the file the digest names.
      _phase = ServerReceivePhase.verifying;
      _flow?.applyTaskState(TransferState.verifying, atMillis: now());
      _notify();

      for (int index = 0; index < files.length; index++) {
        _currentIndex = index;
        _notify();
        final ReceivedFileOutcome outcome = await engine.finishFile(
          fileId: files[index],
          targetRef: targetRef,
        );
        if (outcome.verification.wholeFileDigestMatches != true) {
          throw const ServerReceiveRefused(failedVerificationReason);
        }
        final String? savedPath = outcome.savedPath;
        if (savedPath != null) {
          _savedPaths.add(savedPath);
        }
      }

      _advanceTaskToCompleted(offer.transferId);
      _flow?.applyCompleted(atMillis: now());
      _phase = ServerReceivePhase.saved;
      _notify();
      return true;
    } on Object catch (error) {
      _failureReason = error is ServerReceiveRefused
          ? error.detail
          : interruptedReason;
      _flow?.applyFailure(_failureReason!, atMillis: now());
      _phase = ServerReceivePhase.failed;
      _notify();
      return false;
    }
  }

  /// The sealed manifest's files, which is what the space plan has to be built from.
  ///
  /// From the frozen manifest rather than from the declaration: §6 makes the manifest the authority
  /// on sizes, and a plan built from anything else would be measuring a different transfer.
  List<ManifestFile> _manifestOf(ServerOffer offer) =>
      engine.staging.frozenManifest(offer.transferId)?.files ??
      const <ManifestFile>[];

  /// Whether every chunk of every file of the transfer has been committed.
  ///
  /// Asked of this device's own chunk rows, never of a byte counter: §9 makes those rows the only
  /// authority on what has arrived, and a figure the peer reported is a mirror of something this
  /// side cannot check.
  bool _allCommitted(List<String> files) {
    if (files.isEmpty) {
      return false;
    }
    for (final String fileId in files) {
      if (engine.tasks.missingChunkIndices(fileId).isNotEmpty) {
        return false;
      }
    }
    return true;
  }

  /// Walks the task's own state to its end, one defined edge at a time.
  ///
  /// Every step goes through `transitionTask`, so an edge the state machine does not define is
  /// refused rather than written - and a transfer that is already there stops rather than being
  /// moved backwards.
  void _advanceTaskToCompleted(String transferId) {
    for (final TransferState next in <TransferState>[
      TransferState.verifying,
      TransferState.exporting,
      TransferState.completed,
    ]) {
      if (engine.transfers.taskState(transferId) == TransferState.completed) {
        return;
      }
      try {
        engine.transfers.transitionTask(taskId: transferId, to: next);
      } on Object {
        // An edge this state machine does not define is not something to invent here: the bytes are
        // already verified and saved, and the state is the protocol's bookkeeping of that.
      }
    }
  }

  void _notify() {
    // A screen's poll can outlive the flow it asks by a frame; notifying then would be a crash in
    // debug and a silent no-op in release, so it is refused in both the same way.
    if (!_disposed) {
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  bool _disposed = false;
}

/// Where a server-side receive is.
enum ServerReceivePhase {
  /// Nothing has been proposed to this device.
  waiting,

  /// Something has, and this device is deciding.
  accepting,

  /// Accepted; the peer is sending chunks.
  receiving,

  /// Every chunk is here and the files are being verified and saved.
  verifying,

  /// Every file was verified and saved.
  saved,

  /// Stopped, with a reason the user can act on.
  failed,
}

/// A refusal raised by this layer rather than by the protocol.
class ServerReceiveRefused implements Exception {
  const ServerReceiveRefused(this.detail);

  final String detail;

  @override
  String toString() => 'ServerReceiveRefused($detail)';
}
