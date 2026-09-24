import 'package:flutter_test/flutter_test.dart';

import 'package:nearsend/platform/storage_location.dart';

void main() {
  test('round trips persisted fields without persisting permission state', () {
    const StorageLocationRef location = StorageLocationRef(
      kind: StorageLocationKind.androidDocumentTree,
      opaqueValue: 'content://provider/tree/primary%3ADownload',
      displayName: 'Download',
      permissionState: StoragePermissionState.granted,
    );

    expect(
      StorageLocationRef.fromPersistedValue(location.toPersistedValue()),
      const StorageLocationRef(
        kind: StorageLocationKind.androidDocumentTree,
        opaqueValue: 'content://provider/tree/primary%3ADownload',
        displayName: 'Download',
      ),
    );
  });

  test('rejects unknown versions and extra fields', () {
    expect(
      () => StorageLocationRef.fromPersistedValue(
        '{"schemaVersion":2,"kind":"appPrivate",'
        '"opaqueValue":"/private","displayName":"Private"}',
      ),
      throwsFormatException,
    );
    expect(
      () => StorageLocationRef.fromPersistedValue(
        '{"schemaVersion":1,"kind":"appPrivate",'
        '"opaqueValue":"/private","displayName":"Private","token":"x"}',
      ),
      throwsFormatException,
    );
  });
}
