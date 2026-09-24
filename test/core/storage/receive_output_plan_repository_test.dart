import 'package:flutter_test/flutter_test.dart';

import 'package:nearsend/core/protocol/protocol_exception.dart';
import 'package:nearsend/core/storage/export_naming.dart';
import 'package:nearsend/core/storage/near_send_database.dart';
import 'package:nearsend/core/storage/receive_output_plan_repository.dart';

void main() {
  late NearSendDatabase database;
  late ReceiveOutputPlanRepository repository;

  const String transferId = '00000000-0000-4000-8000-0000000000a1';
  const String fileId = '00000000-0000-4000-8000-0000000000f1';

  setUp(() {
    database = NearSendDatabase.open(path: NearSendDatabase.inMemoryPath);
    repository = ReceiveOutputPlanRepository(database, now: () => 42);
  });

  tearDown(() => database.close());

  ReceiveOutputChoice choice({String name = 'renamed.txt'}) =>
      ReceiveOutputChoice(
        fileId: fileId,
        originalPath: 'sender/frozen.txt',
        selectedName: name,
      );

  test('persists a local name without rewriting the original path', () {
    final List<ReceiveOutputPlan> plans = repository.create(
      transferId: transferId,
      choices: <ReceiveOutputChoice>[choice()],
      targetRef: 'content://provider/tree/downloads',
    );

    expect(plans.single.originalPath, 'sender/frozen.txt');
    expect(plans.single.selectedName, 'renamed.txt');
    expect(plans.single.state, ReceiveOutputState.planned);
    expect(plans.single.conflictPolicy, NameConflictPolicy.autoRename);
  });

  test('an identical create is idempotent but a changed mapping conflicts', () {
    repository.create(
      transferId: transferId,
      choices: <ReceiveOutputChoice>[choice()],
      targetRef: '/exports',
    );
    expect(
      () => repository.create(
        transferId: transferId,
        choices: <ReceiveOutputChoice>[choice()],
        targetRef: '/exports',
      ),
      returnsNormally,
    );
    expect(
      () => repository.create(
        transferId: transferId,
        choices: <ReceiveOutputChoice>[choice(name: 'different.txt')],
        targetRef: '/exports',
      ),
      throwsA(isA<ProtocolViolation>()),
    );
  });

  test('rejects path traversal, nested paths and Windows reserved names', () {
    for (final String invalid in <String>[
      '../escape.txt',
      'a/b.txt',
      'CON.txt',
    ]) {
      expect(
        () => repository.create(
          transferId: transferId,
          choices: <ReceiveOutputChoice>[choice(name: invalid)],
          targetRef: '/exports',
        ),
        throwsA(isA<ProtocolViolation>()),
        reason: invalid,
      );
    }
  });

  test('records exporting, failed retry and the final created handle', () {
    repository.create(
      transferId: transferId,
      choices: <ReceiveOutputChoice>[choice()],
      targetRef: 'content://provider/tree/downloads',
    );
    repository.markExporting(transferId, fileId);
    repository.markFailed(transferId, fileId);
    repository.markExporting(transferId, fileId);
    repository.markSaved(
      transferId: transferId,
      fileId: fileId,
      finalName: 'renamed (1).txt',
      finalTargetRef: 'content://provider/document/7',
    );

    final ReceiveOutputPlan saved = repository.read(transferId, fileId)!;
    expect(saved.state, ReceiveOutputState.saved);
    expect(saved.finalName, 'renamed (1).txt');
    expect(saved.finalTargetRef, 'content://provider/document/7');
  });
}
