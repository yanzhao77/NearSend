import 'package:flutter/foundation.dart';

import 'package:nearsend/core/protocol/transfer_direction.dart';
import 'package:nearsend/core/protocol/transfer_state.dart';
import 'package:nearsend/core/storage/near_send_database.dart';
import 'package:nearsend/core/storage/storage_schema.dart';
import 'package:nearsend/core/storage/storage_state_codec.dart';

enum TaskOverviewStatus {
  active,
  paused,
  recoverable,
  completed,
  partial,
  failed,
}

class TaskOverview {
  const TaskOverview({
    required this.taskId,
    required this.direction,
    required this.state,
    required this.status,
    required this.peerName,
    required this.fileCount,
    required this.totalBytes,
    required this.committedBytes,
    this.observedSentBytes,
    required this.createdAtMillis,
    required this.updatedAtMillis,
  });

  final String taskId;
  final TransferDirection direction;
  final TransferState state;
  final TaskOverviewStatus status;
  final String? peerName;
  final int fileCount;
  final int totalBytes;
  final int committedBytes;

  /// A live sender observation, kept separate from durable receiver bytes.
  final int? observedSentBytes;
  final int createdAtMillis;
  final int updatedAtMillis;

  bool get isRecoverable =>
      status == TaskOverviewStatus.recoverable ||
      status == TaskOverviewStatus.paused;

  double? get progress => totalBytes <= 0
      ? null
      : ((observedSentBytes ?? committedBytes) / totalBytes).clamp(0.0, 1.0);
}

class TaskFileOverview {
  const TaskFileOverview({
    required this.fileId,
    required this.relativePath,
    required this.sizeBytes,
    required this.state,
    required this.committedBytes,
    required this.chunkCount,
    this.exportResult,
    this.targetUri,
    this.savedPath,
    this.finalTargetRef,
  });

  final String fileId;
  final String relativePath;
  final int sizeBytes;
  final FileState state;
  final int committedBytes;
  final int chunkCount;
  final String? exportResult;
  final String? targetUri;
  final String? savedPath;
  final String? finalTargetRef;

  double? get progress =>
      sizeBytes <= 0 ? null : (committedBytes / sizeBytes).clamp(0.0, 1.0);

  bool get isFailed => state == FileState.failed || exportResult == 'failed';
  bool get isSaved => state == FileState.completed && exportResult == 'saved';
}

class TaskDetail {
  const TaskDetail({required this.task, required this.files});

  final TaskOverview task;
  final List<TaskFileOverview> files;

  int get failedFileCount =>
      files.where((TaskFileOverview file) => file.isFailed).length;
}

class SavedIncomingFileOverview {
  const SavedIncomingFileOverview({
    required this.fileName,
    required this.sizeBytes,
    required this.destination,
  });

  final String fileName;
  final int sizeBytes;
  final String destination;
}

enum TaskCatalogFilter { all, active, paused, recoverable, completed, failed }

/// Read model for task pages. It has no write path and never derives progress from byte counters
/// such as `receivedBytes` or `writtenBytes`; committed chunk rows are the only progress source.
class TaskCatalogController extends ChangeNotifier {
  NearSendDatabase? _database;
  List<TaskOverview> _tasks = const <TaskOverview>[];
  final Set<String> _hiddenTaskIds = <String>{};
  final Map<String, int> _observedSentBytes = <String, int>{};
  final Set<String> _confirmedOutgoingCompletions = <String>{};
  Object? _error;

  List<TaskOverview> get tasks => List.unmodifiable(_tasks);
  Object? get error => _error;
  bool get hasRecoverableTasks =>
      _tasks.any((TaskOverview task) => task.isRecoverable);

  List<SavedIncomingFileOverview> get savedIncomingFiles {
    final NearSendDatabase? database = _database;
    if (database == null) return const <SavedIncomingFileOverview>[];
    final rows = database.db.select(
      '''
SELECT f.relative_path, f.size_bytes, e.target_uri, e.saved_path,
       o.final_target_ref
FROM tasks t
JOIN files f ON f.task_id = t.task_id
JOIN exports e ON e.file_id = f.file_id
LEFT JOIN ${StorageSchema.receiveOutputPlansTable} o
  ON o.file_id = f.file_id AND o.transfer_id = f.task_id
WHERE t.direction = ? AND f.export_state = 'completed' AND e.result = 'saved'
ORDER BY t.updated_at DESC, f.rowid DESC;
''',
      <Object?>[TransferDirection.clientToServer.wireValue],
    );
    return List<SavedIncomingFileOverview>.unmodifiable(
      <SavedIncomingFileOverview>[
        for (final row in rows) _savedFileFromRow(row),
      ],
    );
  }

  static SavedIncomingFileOverview _savedFileFromRow(dynamic row) {
    final String relativePath = row['relative_path'] as String;
    final String savedPath = row['saved_path'] as String? ?? relativePath;
    final String? targetUri = row['target_uri'] as String?;
    return SavedIncomingFileOverview(
      fileName: savedPath,
      sizeBytes: row['size_bytes'] as int,
      destination:
          row['final_target_ref'] as String? ??
          _joinLocation(targetUri, savedPath),
    );
  }

  static String _joinLocation(String? targetUri, String savedPath) {
    if (targetUri == null || targetUri.isEmpty) return savedPath;
    final String separator = targetUri.contains('\\') ? '\\' : '/';
    final String trimmed = targetUri.endsWith('/') || targetUri.endsWith('\\')
        ? targetUri.substring(0, targetUri.length - 1)
        : targetUri;
    return '$trimmed$separator$savedPath';
  }

  void attach(NearSendDatabase? database) {
    _database = database;
    refresh();
  }

  void refresh() {
    final NearSendDatabase? database = _database;
    if (database == null) {
      _tasks = const <TaskOverview>[];
      _error = null;
      notifyListeners();
      return;
    }
    try {
      _tasks = _read(
        database,
        _observedSentBytes,
        _confirmedOutgoingCompletions,
      );
      _error = null;
    } on Object catch (error) {
      _tasks = const <TaskOverview>[];
      _error = error;
    }
    notifyListeners();
  }

  void reportOutgoingProgress(String taskId, int bytes) {
    if (_observedSentBytes[taskId] == bytes) return;
    _observedSentBytes[taskId] = bytes;
    refresh();
  }

  /// Only an authenticated receiver completion may set this display status.
  void reportOutgoingCompleted(String taskId) {
    if (_confirmedOutgoingCompletions.add(taskId)) refresh();
  }

  List<TaskOverview> filtered(TaskCatalogFilter filter) {
    return <TaskOverview>[
      for (final TaskOverview task in _tasks)
        if (!_hiddenTaskIds.contains(task.taskId) && _matches(task, filter))
          task,
    ];
  }

  /// Hides the task rows that currently exist without deleting durable task data.
  ///
  /// New tasks remain visible. Hidden rows stay hidden across refreshes for this app
  /// session and reappear after the controller is recreated (for example, on restart).
  void clearDisplayedTasks() {
    _hiddenTaskIds.addAll(_tasks.map((TaskOverview task) => task.taskId));
    notifyListeners();
  }

  TaskDetail? detail(String taskId) {
    final NearSendDatabase? database = _database;
    if (database == null) return null;
    TaskOverview? task;
    for (final TaskOverview candidate in _tasks) {
      if (candidate.taskId == taskId) {
        task = candidate;
        break;
      }
    }
    if (task == null) return null;
    final rows = database.db.select(
      '''
SELECT
  f.file_id,
  f.relative_path,
  f.size_bytes,
  f.export_state,
  f.chunk_count,
  (SELECT COALESCE(SUM(c.length_bytes), 0) FROM chunks c
    WHERE c.file_id = f.file_id AND c.state = 'committed') AS committed_bytes,
  e.target_uri,
  e.result AS export_result,
  e.${StorageSchema.exportsSavedPathColumn} AS saved_path,
  o.final_target_ref
FROM files f
LEFT JOIN exports e ON e.file_id = f.file_id
LEFT JOIN ${StorageSchema.receiveOutputPlansTable} o
  ON o.file_id = f.file_id AND o.transfer_id = f.task_id
WHERE f.task_id = ?
ORDER BY f.rowid;
''',
      <Object?>[taskId],
    );
    return TaskDetail(
      task: task,
      files: <TaskFileOverview>[
        for (final row in rows)
          TaskFileOverview(
            fileId: row['file_id'] as String,
            relativePath: row['relative_path'] as String,
            sizeBytes: row['size_bytes'] as int,
            state: StorageStateCodec.decodeFile(
              row['export_state'] as String,
              fileId: row['file_id'] as String,
            ),
            committedBytes: row['committed_bytes'] as int,
            chunkCount: row['chunk_count'] as int,
            exportResult: row['export_result'] as String?,
            targetUri: row['target_uri'] as String?,
            savedPath: row['saved_path'] as String?,
            finalTargetRef: row['final_target_ref'] as String?,
          ),
      ],
    );
  }

  static List<TaskOverview> _read(
    NearSendDatabase database,
    Map<String, int> observedSentBytes,
    Set<String> confirmedOutgoingCompletions,
  ) {
    final rows = database.db.select('''
SELECT
  t.task_id,
  t.direction,
  t.state,
  t.created_at,
  t.updated_at,
  (
    SELECT p.display_name
    FROM task_assignments a
    LEFT JOIN peers p ON p.peer_id = a.peer_id
    WHERE a.transfer_id = t.task_id
    LIMIT 1
  ) AS peer_name,
  COALESCE(NULLIF((SELECT COUNT(*) FROM files f WHERE f.task_id = t.task_id), 0),
    NULLIF((SELECT COUNT(*) FROM ${StorageSchema.manifestFilesTable} mf
      WHERE mf.transfer_id = t.task_id), 0),
    (SELECT COUNT(*) FROM ${StorageSchema.taskSourcesTable} s
      WHERE s.transfer_id = t.task_id), 0) AS file_count,
  COALESCE((SELECT SUM(f.size_bytes) FROM files f WHERE f.task_id = t.task_id),
    (SELECT SUM(mf.size_bytes) FROM ${StorageSchema.manifestFilesTable} mf
      WHERE mf.transfer_id = t.task_id),
    (SELECT SUM(s.size_bytes) FROM ${StorageSchema.taskSourcesTable} s
      WHERE s.transfer_id = t.task_id), 0) AS total_bytes,
  (SELECT m.committed_bytes FROM ${StorageSchema.taskReceiverMirrorTable} m
    WHERE m.transfer_id = t.task_id) AS mirrored_bytes,
  (
    SELECT COALESCE(SUM(c.length_bytes), 0)
    FROM files f
    JOIN chunks c ON c.file_id = f.file_id
    WHERE f.task_id = t.task_id AND c.state = 'committed'
  ) AS committed_bytes
FROM tasks t
ORDER BY t.updated_at DESC, t.task_id DESC;
''');

    return <TaskOverview>[
      for (final row in rows)
        _fromRow(
          row,
          observedSentBytes[row['task_id'] as String],
          confirmedOutgoingCompletions.contains(row['task_id'] as String),
        ),
    ];
  }

  static TaskOverview _fromRow(
    dynamic row,
    int? observedBytes,
    bool confirmedOutgoingCompletion,
  ) {
    final String taskId = row['task_id'] as String;
    final TransferDirection? direction = TransferDirection.fromWireValue(
      row['direction'] as String,
    );
    if (direction == null) {
      throw StateError('task $taskId has an unknown direction');
    }
    final TransferState state = StorageStateCodec.decodeTransfer(
      row['state'] as String,
      taskId: taskId,
    );
    return TaskOverview(
      taskId: taskId,
      direction: direction,
      state: state,
      status: confirmedOutgoingCompletion
          ? TaskOverviewStatus.completed
          : _statusFor(state),
      peerName: row['peer_name'] as String?,
      fileCount: row['file_count'] as int,
      totalBytes: row['total_bytes'] as int,
      committedBytes: row['committed_bytes'] as int,
      observedSentBytes: observedBytes ?? row['mirrored_bytes'] as int?,
      createdAtMillis: row['created_at'] as int,
      updatedAtMillis: row['updated_at'] as int,
    );
  }

  static TaskOverviewStatus _statusFor(TransferState state) => switch (state) {
    TransferState.preparing ||
    TransferState.staging ||
    TransferState.waitingAccept ||
    TransferState.ready ||
    TransferState.transferring ||
    TransferState.pausing ||
    TransferState.checkingResume ||
    TransferState.verifying ||
    TransferState.exporting => TaskOverviewStatus.active,
    TransferState.paused => TaskOverviewStatus.paused,
    TransferState.interrupted ||
    TransferState.blocked => TaskOverviewStatus.recoverable,
    TransferState.completed => TaskOverviewStatus.completed,
    TransferState.partiallyCompleted => TaskOverviewStatus.partial,
    TransferState.failed ||
    TransferState.cancelled => TaskOverviewStatus.failed,
  };

  static bool _matches(TaskOverview task, TaskCatalogFilter filter) =>
      switch (filter) {
        TaskCatalogFilter.all => true,
        TaskCatalogFilter.active => task.status == TaskOverviewStatus.active,
        TaskCatalogFilter.paused => task.status == TaskOverviewStatus.paused,
        TaskCatalogFilter.recoverable =>
          task.status == TaskOverviewStatus.recoverable,
        TaskCatalogFilter.completed =>
          task.status == TaskOverviewStatus.completed,
        TaskCatalogFilter.failed =>
          task.status == TaskOverviewStatus.failed ||
              task.status == TaskOverviewStatus.partial,
      };
}
