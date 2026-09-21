import 'package:flutter_test/flutter_test.dart';

import 'package:nearsend/core/protocol/transfer_state.dart';
import 'package:nearsend/core/storage/storage_failure.dart';
import 'package:nearsend/core/storage/storage_state_codec.dart';

void main() {
  test('every transfer state round-trips through the one SQLite codec', () {
    for (final TransferState state in TransferState.values) {
      final String stored = StorageStateCodec.encodeTransfer(state);
      expect(
        StorageStateCodec.decodeTransfer(stored, taskId: 'task'),
        state,
      );
    }
  });

  test('wire and SQLite spellings stay separate', () {
    expect(TransferState.waitingAccept.wireName, 'WAITING_ACCEPT');
    expect(
      StorageStateCodec.encodeTransfer(TransferState.waitingAccept),
      'waitingAccept',
    );
    expect(
      () => StorageStateCodec.decodeTransfer(
        TransferState.waitingAccept.wireName,
        taskId: 'task',
      ),
      throwsA(isA<StorageException>()),
    );
  });

  test('every file state round-trips through the same boundary', () {
    for (final FileState state in FileState.values) {
      final String stored = StorageStateCodec.encodeFile(state);
      expect(StorageStateCodec.decodeFile(stored, fileId: 'file'), state);
    }
  });
}
