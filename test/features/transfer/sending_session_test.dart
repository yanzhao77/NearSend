import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nearsend/core/network/task_authorization_endpoint.dart';
import 'package:nearsend/core/protocol/api_responses.dart';
import 'package:nearsend/core/protocol/protocol_limits.dart';
import 'package:nearsend/core/security/pairing_payload.dart';
import 'package:nearsend/core/storage/source_bytes.dart';
import 'package:nearsend/core/storage/space_plan.dart';
import 'package:nearsend/core/transfer/near_send_node.dart';
import 'package:nearsend/core/transfer/transfer_client.dart';
import 'package:nearsend/core/transfer/transfer_engine.dart';
import 'package:nearsend/features/transfer/application/sending_session.dart';
import 'package:nearsend/platform/android_file_gateway.dart';

/// The sending session, run against a real server over real TLS.
///
/// The unit tests around it assert the order and the refusal; this one asserts the outcome a user
/// cares about: the bytes reached the receiver's disk and hash to what the sender read. Without it
/// the orchestration would be a claim about method calls rather than about files.
void main() {
  late Directory root;
  late NearSendNode server;
  late NearSendNode client;
  late TransferClient wire;
  late InMemoryFileGateway documents;

  const String fileId = '00000000-0000-4000-8000-000000000001';
  const String transferId = '11111111-2222-4333-8444-555555555555';

  final Uint8List payload = Uint8List.fromList(<int>[
    ...List<int>.generate(
      ProtocolLimits.chunkSizeBytes + 64,
      (int i) => i % 233,
    ),
    ...'会话编排.bin'.codeUnits,
  ]);

  String safUri(String id) => 'content://nearsend.test/$id';

  setUp(() async {
    root = Directory.systemTemp.createTempSync('nearsend-session-');
    documents = InMemoryFileGateway(
      documents: <String, Uint8List>{safUri(fileId): payload},
    );
    SourceBytes resolve(String ref, int size) => ref.startsWith('content://')
        ? SafSourceBytes(
            gateway: documents,
            uri: ref,
            providerReportedSize: size,
          )
        : FileSourceBytes(File(ref));

    server = await NearSendNode.open(
      directory: '${root.path}${Platform.pathSeparator}server',
      candidateAddresses: const <String>['127.0.0.1'],
      sourceResolver: resolve,
    );
    await server.start();
    client = await NearSendNode.open(
      directory: '${root.path}${Platform.pathSeparator}client',
      candidateAddresses: const <String>['127.0.0.1'],
      sourceResolver: resolve,
    );

    final PairingPayload pairingPayload = server.openPairingSession();
    wire = TransferClient(
      pin: pairingPayload.serverFingerprint,
      host: '127.0.0.1',
      port: server.server.boundPort,
    );
    await wire.pairFrom(pairingPayload, clientLabel: 'session-test');
  });

  tearDown(() async {
    wire.close();
    await server.stop();
    server.close();
    client.close();
    if (root.existsSync()) {
      root.deleteSync(recursive: true);
    }
  });

  test('the session takes a chosen document to a file on the receiver', () async {
    final SendingSession session = SendingSession(
      engine: client.engine,
      wire: wire,
    );

    // 1. plan from a document
    final OutgoingPlan plan = await session.plan(
      transferId: transferId,
      choices: <OutgoingFileChoice>[
        OutgoingFileChoice(
          fileId: fileId,
          relativePath: '会话编排.bin',
          source: SafSourceBytes(
            gateway: documents,
            uri: safUri(fileId),
            providerReportedSize: payload.length,
          ),
        ),
      ],
    );

    // 2. propose and seal; nothing may move before the receiver accepts
    await session.propose(plan);
    expect(server.transfers.taskState(transferId).wireName, 'WAITING_ACCEPT');

    // The receiver accepts, which is what a server that is not the addressee does locally.
    final Directory exports = Directory(
      '${root.path}${Platform.pathSeparator}server${Platform.pathSeparator}exports',
    );
    server.engine.acceptLocally(
      transferId: transferId,
      context: ReceiverStorageContext(
        stagingVolume: const VolumeId('staging'),
        exportVolume: const VolumeId('internal'),
        databaseVolume: const VolumeId('internal'),
        availability: <VolumeId, VolumeAvailability>{
          const VolumeId('staging'): const VolumeAvailability.known(1 << 40),
          const VolumeId('internal'): const VolumeAvailability.known(1 << 40),
        },
        saveLocationRef: exports.path,
      ),
    );

    // 4. the generation that makes a chunk acceptable
    final ResumeGranted granted = await session.openWriteGeneration(plan);
    expect(granted.leaseEpoch, greaterThanOrEqualTo(1));

    // 5. the bytes
    final List<int> progress = <int>[];
    final int sent = await session.sendFile(
      plan: plan,
      granted: granted,
      fileId: fileId,
      onProgress: (int acknowledged, int total) {
        progress.add(acknowledged);
        expect(total, plan.manifest.files.single.chunkCount);
      },
    );

    expect(sent, plan.manifest.files.single.chunkCount);
    expect(
      progress,
      List<int>.generate(sent, (int i) => i + 1),
      reason:
          'progress is reported per acknowledged chunk, in order - a sender that reported a '
          'figure ahead of the peer answers would be inventing the receiver state',
    );

    final ReceivedFileOutcome outcome = await server.engine.finishFile(
      fileId: fileId,
      targetRef: exports.path,
    );
    expect(outcome.verification.wholeFileDigestMatches, isTrue);

    final File written = exports
        .listSync(recursive: true)
        .whereType<File>()
        .where((File f) => !f.path.endsWith('.nearsend-part'))
        .single;
    expect(
      sha256.convert(written.readAsBytesSync()).toString(),
      sha256.convert(payload).toString(),
      reason:
          'the session exists so that a chosen document becomes a file at the receiver; this is '
          'the assertion that says it does',
    );
  });
}
