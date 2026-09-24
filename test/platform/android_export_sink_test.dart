import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:nearsend/core/storage/export_service.dart';
import 'package:nearsend/core/storage/local_file_layer.dart';
import 'package:nearsend/platform/android_export_sink.dart';
import 'package:nearsend/platform/android_file_gateway.dart';

void main() {
  late Directory root;
  late LocalStagingLayout layout;

  setUp(() async {
    root = Directory.systemTemp.createTempSync('nearsend-saf-export-');
    layout = LocalStagingLayout(root);
    await layout.prepare();
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  test('streams ordered staging chunks to one SAF document', () async {
    const String fileId = '00000000-0000-4000-8000-0000000000f1';
    final StagingFileSink staging = StagingFileSink(layout);
    await staging.writeVerifyAndSync(
      fileId: fileId,
      index: 0,
      offsetBytes: 0,
      bytes: Uint8List.fromList(<int>[1, 2, 3]),
    );
    await staging.writeVerifyAndSync(
      fileId: fileId,
      index: 1,
      offsetBytes: 3,
      bytes: Uint8List.fromList(<int>[4, 5]),
    );
    final InMemoryFileGateway gateway = InMemoryFileGateway();
    final AndroidDocumentExportSink sink = AndroidDocumentExportSink(
      layout: layout,
      gateway: gateway,
      staging: staging,
    );

    final ExportCommitResult result = await sink.commit(
      fileId: fileId,
      targetRef: 'content://provider/tree/root',
      safePath: 'payload.bin',
    );

    final AndroidDirectoryEntry created =
        gateway.directories['content://provider/tree/root']!.single;
    expect(gateway.written[created.uri], <int>[1, 2, 3, 4, 5]);
    expect(result.atomic, isFalse);
  });

  test('a failed SAF write removes only its uncommitted document', () async {
    const String fileId = '00000000-0000-4000-8000-0000000000f2';
    final StagingFileSink staging = StagingFileSink(layout);
    await staging.writeVerifyAndSync(
      fileId: fileId,
      index: 0,
      offsetBytes: 0,
      bytes: Uint8List.fromList(<int>[1]),
    );
    final _FailingGateway gateway = _FailingGateway();
    final AndroidDocumentExportSink sink = AndroidDocumentExportSink(
      layout: layout,
      gateway: gateway,
    );

    await expectLater(
      sink.commit(
        fileId: fileId,
        targetRef: 'content://provider/tree/root',
        safePath: 'payload.bin',
      ),
      throwsA(anything),
    );
    expect(gateway.directories['content://provider/tree/root'], isEmpty);
    expect(layout.fileDirectory(fileId).existsSync(), isTrue);
  });
}

class _FailingGateway extends InMemoryFileGateway {
  @override
  Future<void> writeChunk({
    required String uri,
    required int offset,
    required Uint8List bytes,
  }) async {
    throw const PlatformFileFailure('injected write failure');
  }
}
