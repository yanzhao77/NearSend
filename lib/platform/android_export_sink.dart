import 'dart:io';
import 'dart:typed_data';

import 'package:nearsend/core/storage/export_service.dart';
import 'package:nearsend/core/storage/local_file_layer.dart';
import 'package:nearsend/core/storage/storage_failure.dart';
import 'package:nearsend/platform/android_file_gateway.dart';

class AndroidRoutingExportSink implements ExportSink {
  AndroidRoutingExportSink({required this.local, required this.documents});

  final ExportSink local;
  final ExportSink documents;

  ExportSink _for(String targetRef) =>
      targetRef.startsWith('content://') ? documents : local;

  @override
  Future<TargetInventory> inventory({required String targetRef}) =>
      _for(targetRef).inventory(targetRef: targetRef);

  @override
  Future<ExportCommitResult> commit({
    required String fileId,
    required String targetRef,
    required String safePath,
  }) =>
      _for(targetRef)
          .commit(fileId: fileId, targetRef: targetRef, safePath: safePath);

  @override
  Future<void> deleteStaging({required String fileId}) =>
      local.deleteStaging(fileId: fileId);
}

/// Streams verified staging chunks into a document created under a SAF tree.
class AndroidDocumentExportSink implements ExportSink {
  AndroidDocumentExportSink({
    required this.layout,
    required this.gateway,
    this.staging,
  });

  final LocalStagingLayout layout;
  final AndroidFileGateway gateway;
  final StagingFileSink? staging;

  @override
  Future<TargetInventory> inventory({required String targetRef}) async {
    try {
      final List<AndroidDirectoryEntry> entries = await gateway.listDirectory(
        treeUri: targetRef,
      );
      return TargetInventory.known(<TargetEntry>[
        for (final AndroidDirectoryEntry entry in entries)
          TargetEntry(path: entry.displayName, sizeBytes: entry.sizeBytes),
      ]);
    } on Object {
      return TargetInventory.unknown();
    }
  }

  @override
  Future<ExportCommitResult> commit({
    required String fileId,
    required String targetRef,
    required String safePath,
  }) async {
    if (safePath.isEmpty ||
        safePath.contains('/') ||
        safePath.contains(r'\') ||
        safePath == '.' ||
        safePath == '..') {
      throw StorageException(
        StorageFailureCode.manifestMismatch,
        'the SAF export name must be one plain file name',
      );
    }
    final Directory parts = layout.fileDirectory(fileId);
    if (!parts.existsSync()) {
      throw StorageException(
        StorageFailureCode.commitFailed,
        'the staging chunks are unavailable for SAF export',
      );
    }

    String? createdUri;
    try {
      final PickedDocument target = await gateway.createDocument(
        treeUri: targetRef,
        displayName: safePath,
      );
      createdUri = target.uri;
      if (target.displayName != safePath) {
        throw const PlatformFileFailure(
          'the provider changed the requested file name',
        );
      }
      await gateway.beginWrite(uri: createdUri);
      int offset = 0;
      for (final File part in _orderedParts(parts)) {
        final RandomAccessFile input = await part.open();
        try {
          while (true) {
            final Uint8List bytes = await input.read(256 * 1024);
            if (bytes.isEmpty) break;
            await gateway.writeChunk(
              uri: createdUri,
              offset: offset,
              bytes: bytes,
            );
            offset += bytes.length;
          }
        } finally {
          await input.close();
        }
      }
      await gateway.endWrite(uri: createdUri);
      return ExportCommitResult(atomic: false, createdTargetRef: target.uri);
    } on Object catch (error) {
      if (createdUri != null) {
        try {
          await gateway.abortWrite(uri: createdUri);
        } on Object {
          // Cleanup is limited to the uncommitted document created by this call.
        }
      }
      throw StorageException(
        StorageFailureCode.commitFailed,
        'writing the verified file through SAF failed',
        cause: error,
      );
    }
  }

  @override
  Future<void> deleteStaging({required String fileId}) async {
    await (staging ?? StagingFileSink(layout)).deleteStaging(fileId);
  }

  static List<File> _orderedParts(Directory parts) {
    final List<MapEntry<int, File>> indexed = <MapEntry<int, File>>[];
    for (final FileSystemEntity entity in parts.listSync(followLinks: false)) {
      if (entity is! File) continue;
      final String name = entity.uri.pathSegments.last;
      if (!name.endsWith('.part')) continue;
      final int? index = int.tryParse(name.substring(0, name.length - 5));
      if (index == null) {
        throw StorageException(
          StorageFailureCode.commitFailed,
          'unexpected entry in staging during SAF export',
        );
      }
      indexed.add(MapEntry<int, File>(index, entity));
    }
    indexed.sort(
      (MapEntry<int, File> a, MapEntry<int, File> b) => a.key.compareTo(b.key),
    );
    return <File>[for (final MapEntry<int, File> item in indexed) item.value];
  }
}
