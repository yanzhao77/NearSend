/// §8's write fence: one writer per file, and the hand-over a resume must perform.
///
/// ## What the protocol asks for, and why the existing checks were not enough
///
/// §8 line by line:
///
/// > 每文件串行写入；恢复获得相同写入栅栏，先撤销旧会话，等待旧写入停止，再分配新 epoch，
/// > 校验已有数据。只在请求入口检查 epoch 不够，旧请求不得在新世代建立后继续写入。
///
/// The storage layer already refuses a commit that does not present the current
/// generation, and it re-checks that generation *inside* the commit transaction. That makes
/// a superseded write unable to **commit** - but it does not make it unable to **write**.
/// Two gaps remain, and both are about time rather than about the database:
///
/// 1. **Nothing serialised two writers of the same file.** §8's write order puts a file
///    lock immediately after authentication, before any byte is written. Without it two
///    writers interleave their bytes into one staging file, and the loser's bytes are
///    already on disk by the time its commit is refused - so the file no longer matches
///    either writer's intent. The committed-chunk rows would still be correct, which is
///    exactly why this is dangerous: the database would look right while the bytes it
///    describes are not the bytes the winner wrote.
///
/// 2. **`revokeAndAdvanceLease` advanced the generation without waiting.** A write halfway
///    through `writeVerifyAndSync` when a resume allocates the next generation keeps
///    writing into the file that generation is about to use. §8 puts "等待旧写入停止"
///    between revoking the old session and allocating the new epoch precisely so the new
///    generation starts from a file nothing else is touching.
///
/// ## The order this class enforces
///
/// ```
/// refuse further writes for the old generation   (revokeAndDrain, immediately)
/// wait until no writer of it is still running    (revokeAndDrain, awaited)
/// allocate the next generation                   (the caller, on the repository)
/// verify the existing data                       (the caller)
/// ```
///
/// Refusing *before* waiting is the part that is easy to get wrong. If a generation were
/// refused only when it changed, a new old-generation write could start during the wait and
/// the wait would never end.
///
/// ## What an in-flight write is allowed to do
///
/// It is allowed to finish, and its commit is allowed to succeed. That is deliberate:
/// aborting it would leave a half-written staging file for no gain, and §8's next step -
/// "校验已有数据" - is what makes a chunk committed under the old generation safe to keep.
/// The fence guarantees the write *stops*, not that it is undone.
///
/// ## Scope
///
/// This class knows nothing about SQLite. It decides who may write and when a generation
/// stops accepting work; whether a commit lands is the repository's question, and both are
/// needed. Keeping them apart means the ordering above can be tested without a database,
/// while the atomicity guarantees stay where they already are.
library;

import 'dart:async';

import 'package:nearsend/core/storage/storage_failure.dart';

/// A reservation of one file's single write slot.
///
/// Taken through [WriteFence.withFileWrite], which is the only supported way to use it:
/// the method releases the reservation even when the write throws.
class FileWriteReservation {
  /// Positional because the fields are private, and a private *named* parameter is not
  /// legal in Dart. Only [_FileSlot.reserve] constructs one.
  FileWriteReservation._(
    this._slot,
    this._fileId,
    this._registry,
    this._previous,
    this._release,
  );

  final _FileSlot _slot;
  final String _fileId;
  final Map<String, _FileSlot> _registry;

  /// The future that resolves once the previous writer of this file has finished.
  ///
  /// Awaiting it is what makes the write serial: while it is pending this writer holds a
  /// place in the queue but not the file.
  final Future<void> _previous;

  final Completer<void> _release;
  bool _released = false;

  /// Resolves when this writer is allowed to touch the file.
  Future<void> get ready => _previous;

  /// Whether this reservation has been released.
  bool get released => _released;

  /// Hands the file to the next writer in line.
  ///
  /// Idempotent, because it runs in a `finally`: a double release would otherwise let two
  /// queued writers hold the same file at once.
  void release() {
    if (_released) {
      return;
    }
    _released = true;
    _slot.onReleased(_fileId, _registry);
    if (!_release.isCompleted) {
      _release.complete();
    }
  }
}

/// §8's per-file write serialisation and resume hand-over.
///
/// All state is in memory. That is correct rather than a shortcut: the fence arbitrates
/// between writers inside one process, while §8's authority across processes is the
/// committed chunk row plus `lease_epoch`, which live in SQLite. A restarted process has no
/// in-flight writes left to fence.
class WriteFence {
  /// The highest generation refused per task, or absent when none has been revoked.
  ///
  /// Monotonic: a generation is never un-revoked, so a straggling request cannot be
  /// re-admitted by a later resume.
  final Map<String, int> _revokedThrough = <String, int>{};

  /// Writers currently registered per task, including ones still queued for a file slot.
  final Map<String, int> _inFlight = <String, int>{};

  /// Completed when a task's [inFlightWrites] reaches zero.
  final Map<String, Completer<void>> _drained = <String, Completer<void>>{};

  /// One queue per file, keyed by file id.
  final Map<String, _FileSlot> _slots = <String, _FileSlot>{};

  /// Whether [leaseEpoch] may still start new work for [taskId].
  bool accepts({required String taskId, required int leaseEpoch}) {
    final int? revoked = _revokedThrough[taskId];
    return revoked == null || leaseEpoch > revoked;
  }

  /// The highest generation refused for [taskId], or null when none has been revoked.
  int? revokedThrough(String taskId) => _revokedThrough[taskId];

  /// Writers of [taskId] that are running or queued.
  int inFlightWrites(String taskId) => _inFlight[taskId] ?? 0;

  /// Files that currently have a writer holding or waiting for their slot.
  ///
  /// Exposed so a test can assert the registry does not grow with the number of files
  /// written; §5 allows 10,000 files in one transfer.
  int get busyFileCount => _slots.length;

  /// Runs [write] as the only writer of [fileId] under [leaseEpoch].
  ///
  /// Throws [StorageException] with [StorageFailureCode.staleLease] when the generation is
  /// already revoked, and again if it is revoked while this writer waits in line. The
  /// second check is the one that matters: without it a write could pass the check, queue
  /// behind another writer, and then start writing after a resume had taken over.
  Future<T> withFileWrite<T>({
    required String taskId,
    required String fileId,
    required int leaseEpoch,
    required Future<T> Function() write,
  }) async {
    if (!accepts(taskId: taskId, leaseEpoch: leaseEpoch)) {
      throw _stale(taskId, leaseEpoch, 'the generation was already revoked');
    }

    // Registered before the queue rather than after it, so a drain also waits for a queued
    // writer of the old generation. It would refuse itself as soon as it reached the front,
    // but "the old session's work has stopped" has to include work still in its way.
    _beginWrite(taskId);
    final FileWriteReservation reservation = _reserve(fileId);
    try {
      await reservation.ready;
      if (!accepts(taskId: taskId, leaseEpoch: leaseEpoch)) {
        throw _stale(
          taskId,
          leaseEpoch,
          'the generation was revoked while this write waited for $fileId',
        );
      }
      return await write();
    } finally {
      reservation.release();
      _endWrite(taskId);
    }
  }

  /// §8's hand-over: refuse [leaseEpoch] and below, then wait for that task's writers to
  /// stop.
  ///
  /// Returns once no writer of the revoked generations is running or queued, at which point
  /// the caller may allocate the next generation and verify the existing data. It does
  /// **not** allocate the generation itself, because that is a database transaction and
  /// belongs with the rest of the commit path.
  ///
  /// [timeout] bounds the wait. On expiry this throws rather than returning: a caller that
  /// read a timeout as "the writes stopped" would allocate a generation while an old write
  /// was still writing into the file. The generation stays revoked, so the resume can be
  /// retried and no new old-generation work can start in the meantime.
  Future<void> revokeAndDrain({
    required String taskId,
    required int leaseEpoch,
    Duration? timeout,
  }) async {
    final int? previous = _revokedThrough[taskId];
    if (previous == null || leaseEpoch > previous) {
      _revokedThrough[taskId] = leaseEpoch;
    }

    final Future<void> drained = _drain(taskId);
    if (timeout == null) {
      await drained;
      return;
    }
    await drained.timeout(
      timeout,
      onTimeout: () => throw StorageException(
        StorageFailureCode.staleLease,
        'generation $leaseEpoch of task $taskId still had '
        '${inFlightWrites(taskId)} writer(s) after ${timeout.inMilliseconds} ms; '
        'refusing to allocate the next generation',
      ),
    );
  }

  /// Forgets a task's revocation and waiters.
  ///
  /// For tests and for a task that has been discarded. Deliberately not called by the
  /// resume path: a generation must stay revoked for the life of the fence, or a
  /// straggling request could be re-admitted.
  void forget(String taskId) {
    _revokedThrough.remove(taskId);
    _inFlight.remove(taskId);
    final Completer<void>? drained = _drained.remove(taskId);
    if (drained != null && !drained.isCompleted) {
      drained.complete();
    }
  }

  FileWriteReservation _reserve(String fileId) => _slots
      .putIfAbsent(fileId, _FileSlot.new)
      .reserve(fileId: fileId, registry: _slots);

  void _beginWrite(String taskId) {
    _inFlight[taskId] = (_inFlight[taskId] ?? 0) + 1;
  }

  void _endWrite(String taskId) {
    final int remaining = (_inFlight[taskId] ?? 1) - 1;
    if (remaining > 0) {
      _inFlight[taskId] = remaining;
      return;
    }
    _inFlight.remove(taskId);
    final Completer<void>? drained = _drained.remove(taskId);
    if (drained != null && !drained.isCompleted) {
      drained.complete();
    }
  }

  Future<void> _drain(String taskId) {
    if (inFlightWrites(taskId) == 0) {
      return Future<void>.value();
    }
    return _drained.putIfAbsent(taskId, Completer<void>.new).future;
  }

  StorageException _stale(String taskId, int leaseEpoch, String why) =>
      StorageException(
        StorageFailureCode.staleLease,
        'task $taskId refused a write under generation $leaseEpoch: $why',
      );

  @override
  String toString() =>
      'WriteFence(${_slots.length} busy file(s), ${_revokedThrough.length} revoked '
      'generation(s))';
}

/// One file's write queue: a tail future that each writer chains onto.
class _FileSlot {
  /// The future a new writer must await before it owns the file.
  Future<void> _tail = Future<void>.value();

  /// Reservations not yet released, including the one currently holding the file.
  int _pending = 0;

  FileWriteReservation reserve({
    required String fileId,
    required Map<String, _FileSlot> registry,
  }) {
    _pending++;
    final Completer<void> release = Completer<void>();
    final Future<void> previous = _tail;
    _tail = previous.then((_) => release.future);
    return FileWriteReservation._(this, fileId, registry, previous, release);
  }

  void onReleased(String fileId, Map<String, _FileSlot> registry) {
    _pending--;
    // Dropped when the last reservation goes, so the registry is bounded by the number of
    // files being written at once rather than by the number of files ever written - and §5
    // allows 10,000 files in a single transfer.
    if (_pending == 0 && identical(registry[fileId], this)) {
      registry.remove(fileId);
    }
  }
}
