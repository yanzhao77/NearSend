/// Runs on an Android device and transfers real files both ways over the real LAN.
///
/// ## What only a device can answer
///
/// The desktop run proves the protocol and the storage agree with each other. This one asks the
/// questions that have no local answer: whether Android's `X509Certificate.der` produces the same
/// `SHA-256` Windows computed when it generated the certificate, whether its certificate callback
/// runs at the same points, whether a real app can reach this machine at all over Wi-Fi, and
/// whether its file writes land where it thinks they do.
///
/// ## Both directions, and who verifies what
///
/// * **This device sends** (`client_to_server`): it creates the transfer, uploads the manifest and
///   seals it, resumes for a generation, and streams the chunks. The Windows node accepts, writes,
///   verifies and exports; its own report of the digest it saved is compared against this file
///   offline, because the two processes cannot read each other's output.
/// * **This device receives** (`server_to_client`): it lists the offer, decides, fetches its
///   credentials, resumes, reads the frozen manifest, pulls exactly the chunks its own rows say
///   are missing, verifies the whole file and exports it. **This side is fully asserted here**,
///   including the digest of the file on disk against the digest Windows published.
///
/// Both ends generate their bodies from the same formula, so each can state the expected digest
/// without talking to the other.
///
/// Run (Windows node first, then):
///   `flutter test integration_test/android_bidirectional_transfer_test.dart -d <deviceId>`
///   with `--dart-define=NS_LAN_B64=<base64 of the node's JSON line>`
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:nearsend/core/protocol/chunk_manifest.dart';
import 'package:nearsend/core/protocol/manifest.dart';
import 'package:nearsend/core/protocol/protocol_limits.dart';
import 'package:nearsend/core/protocol/transfer_direction.dart';
import 'package:nearsend/core/security/pairing_payload.dart';
import 'package:nearsend/core/storage/local_file_layer.dart';
import 'package:nearsend/core/protocol/transfer_resume_request.dart';
import 'package:nearsend/core/transfer/near_send_node.dart';
import 'package:nearsend/core/transfer/transfer_client.dart';
import 'package:nearsend/core/transfer/transfer_engine.dart';

/// The node's JSON line, base64 encoded.
///
/// Base64 rather than raw JSON: the payload is full of quotes and braces, and every layer between
/// the command line and the compiled test - PowerShell, `flutter test`, the ADB launch - is a
/// chance for those to be mangled. A decoding failure is then a clear failure instead of a payload
/// that is merely different.
const String _lanBase64 = String.fromEnvironment('NS_LAN_B64');

Map<String, Object?> get _lan =>
    (jsonDecode(utf8.decode(base64.decode(_lanBase64))) as Map)
        .cast<String, Object?>();

String _sha(Uint8List bytes) => sha256.convert(bytes).toString();

/// The same deterministic body the Windows node generates, so both ends can state one digest.
Uint8List sample(int length) => Uint8List.fromList(
  List<int>.generate(length, (int i) => (i * 7 + 11) % 251),
);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late NearSendNode device;
  late TransferClient wire;
  late Map<String, Object?> lan;

  setUpAll(() async {
    lan = _lan;
    root = Directory.systemTemp.createTempSync('nearsend-device-');

    // The device is a node too: it has its own database, its own staging and its own engine, which
    // is exactly the shape the product will have. `127.0.0.1` is only a certificate SAN; this node
    // never listens here.
    device = await NearSendNode.open(
      directory: '${root.path}${Platform.pathSeparator}node',
      candidateAddresses: const <String>['127.0.0.1'],
    );

    final Map<String, Object?> payload = (lan['pairingPayload']! as Map)
        .cast<String, Object?>();
    final PairingPayload pairingPayload = PairingPayload.parse(
      jsonEncode(payload),
    );

    wire = TransferClient(
      pin: pairingPayload.serverFingerprint,
      host: lan['host']! as String,
      port: lan['port']! as int,
    );
    await wire.pairFrom(pairingPayload, clientLabel: 'android-device');
  });

  tearDownAll(() async {
    wire.close();
    device.close();
    if (root.existsSync()) {
      root.deleteSync(recursive: true);
    }
  });

  // 4 MiB over Wi-Fi in 4 MiB protocol chunks: the default 30-second budget is a unit-test
  // budget, and the first device run failed on the budget rather than on the transfer.
  test(
    'Android sends a real file to Windows over the LAN',
    timeout: const Timeout(Duration(minutes: 6)),
    () async {
      final Map<String, Object?> inbound = (lan['inbound']! as Map)
          .cast<String, Object?>();
      final String transferId = inbound['transferId']! as String;
      final String fileId = inbound['fileId']! as String;

      final Uint8List body = sample(ProtocolLimits.chunkSizeBytes + 5000);
      final File source = File(
        '${root.path}${Platform.pathSeparator}android-中方文件.bin',
      );
      await source.writeAsBytes(body);

      final OutgoingPlan plan = await device.engine.prepareOutgoing(
        transferId: transferId,
        direction: TransferDirection.clientToServer,
        choices: <OutgoingFileChoice>[
          OutgoingFileChoice(
            fileId: fileId,
            relativePath: 'android-中方文件.bin',
            path: source.path,
          ),
        ],
      );

      await wire.createTransfer(
        transferId: transferId,
        manifestDigest: plan.manifestDigest,
        fileCount: 1,
        totalBytes: body.length,
      );
      await wire.uploadManifest(
        transferId: transferId,
        manifest: plan.manifest,
        pages: device.engine.pagesFor(plan.manifest, plan.files),
      );
      await wire.seal(
        transferId: transferId,
        manifestDigest: plan.manifestDigest,
      );

      // The Windows node accepts on its own watch loop, so this retries rather than racing it: the
      // resume needs the task to be out of STAGING, and a refusal here means "not yet".
      final grant = await _retry(
        () => wire.fetchAuthorization(transferId: transferId),
      );
      final resumed = await _retry(
        () => wire.resume(
          transferId: transferId,
          manifestDigest: plan.manifestDigest,
          taskResumeSecret: grant.taskResumeSecret,
        ),
      );
      expect(resumed.leaseEpoch, greaterThanOrEqualTo(1));

      final SourceFilePlan sourcePlan = device.engine.planFor(
        transferId,
        fileId,
      );
      for (final ChunkRecord chunk in sourcePlan.chunks) {
        final Uint8List bytes = _readChunk(sourcePlan, chunk.index);
        await wire.putChunk(
          transferId: transferId,
          fileId: fileId,
          index: chunk.index,
          bytes: bytes,
          leaseEpoch: resumed.leaseEpoch,
          manifestDigest: plan.manifestDigest,
        );
      }

      expect(
        _sha(body),
        plan.manifest.files.single.fileSha256,
        reason: 'the manifest the device sent describes the bytes it read',
      );
    },
  );

  test(
    'Android receives a real file from Windows over the LAN',
    timeout: const Timeout(Duration(minutes: 6)),
    () async {
      final Map<String, Object?> outbound = (lan['outbound']! as Map)
          .cast<String, Object?>();
      final String transferId = outbound['transferId']! as String;
      final String fileId = outbound['fileId']! as String;
      final String expectedDigest = outbound['fileSha256']! as String;
      final int expectedSize = outbound['sizeBytes']! as int;

      final offers = await _retry(() => wire.offers());
      final offer = offers.firstWhere((o) => o.transferId == transferId);
      expect(
        offer.manifestDigest,
        outbound['manifestDigest'],
        reason: 'the offer names the manifest Windows sealed',
      );
      expect(offer.totalBytes, expectedSize);

      await wire.decide(
        transferId: transferId,
        manifestDigest: offer.manifestDigest,
        accept: true,
      );
      final grant = await _retry(
        () => wire.fetchAuthorization(transferId: transferId),
      );
      final resumed = await _retry(
        () => wire.resume(
          transferId: transferId,
          manifestDigest: offer.manifestDigest,
          taskResumeSecret: grant.taskResumeSecret,
          receiverState: const ReceiverState(
            leaseEpoch: 0,
            checkpointSeq: 0,
            committedBytes: 0,
          ),
        ),
      );

      final FrozenManifest manifest = await wire.readManifest(transferId);
      final ManifestFile file = manifest.files.single;
      final List<ChunkRecord> records = await wire.readChunkRecords(
        transferId: transferId,
        file: file,
      );
      device.engine.registerRemoteManifest(transferId, manifest);
      device.engine.registerRemoteFile(
        transferId: transferId,
        file: file,
        chunks: records,
      );
      // §9: the device is the receiver but Windows allocated the generation, so the device persists
      // it locally before it can commit anything.
      device.tasks.adoptLeaseEpoch(transferId, epoch: resumed.leaseEpoch);

      for (final int index in device.engine.missingChunks(fileId)) {
        final Uint8List bytes = await wire.getChunk(
          transferId: transferId,
          fileId: fileId,
          index: index,
          leaseEpoch: resumed.leaseEpoch,
          manifestDigest: offer.manifestDigest,
        );
        await device.engine.acceptChunk(
          transferId: transferId,
          fileId: fileId,
          index: index,
          bytes: bytes,
          leaseEpoch: resumed.leaseEpoch,
        );
      }
      expect(device.engine.missingChunks(fileId), isEmpty);

      final Directory exports = Directory(
        '${root.path}${Platform.pathSeparator}exports',
      );
      final ReceivedFileOutcome outcome = await device.engine.finishFile(
        fileId: fileId,
        targetRef: exports.path,
      );
      expect(
        outcome.verification.wholeFileDigestMatches,
        isTrue,
        reason: 'the whole-file digest is recomputed over the bytes this device wrote',
      );
      expect(outcome.verification.verifiedBytes, expectedSize);

      final List<File> written = exports
          .listSync(recursive: true)
          .whereType<File>()
          .where((File f) => !f.path.endsWith('.nearsend-part'))
          .toList();
      expect(written, hasLength(1));
      expect(
        _sha(Uint8List.fromList(written.single.readAsBytesSync())),
        expectedDigest,
        reason:
            'the file on Android storage hashes to the file Windows sent - the assertion that '
            'makes this a real transfer rather than a plausible one',
      );

      await wire.reportCheckpoint(
        transferId: transferId,
        manifestDigest: offer.manifestDigest,
        leaseEpoch: resumed.leaseEpoch,
        checkpointSeq: device.tasks.checkpointSeq(transferId),
        committedBytes: device.tasks.committedBytesForTask(transferId),
      );
      await wire.complete(
        transferId: transferId,
        fileId: fileId,
        leaseEpoch: resumed.leaseEpoch,
        saved: true,
        fileSha256: file.fileSha256,
      );
    },
  );
}

/// Runs [attempt] until it succeeds or the budget runs out.
///
/// The Windows node acts on its own watch loop, so a call that arrives before it has finished
/// accepting is refused - correctly. Retrying is what turns that race into a wait instead of a
/// flaky failure.
Future<T> _retry<T>(
  Future<T> Function() attempt, {
  Duration budget = const Duration(seconds: 40),
}) async {
  final Stopwatch clock = Stopwatch()..start();
  Object? last;
  while (clock.elapsed < budget) {
    try {
      return await attempt();
    } on Object catch (error) {
      last = error;
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
  }
  throw StateError('gave up after ${budget.inSeconds}s: $last');
}

/// Reads one chunk of a planned source with a single bounded buffer.
Uint8List _readChunk(SourceFilePlan plan, int index) {
  final RandomAccessFile handle = plan.file.openSync();
  try {
    final ChunkRecord record = plan.chunks[index];
    handle.setPositionSync(index * ProtocolLimits.chunkSizeBytes);
    final Uint8List bytes = Uint8List(record.length);
    int filled = 0;
    while (filled < record.length) {
      final int read = handle.readIntoSync(
        bytes,
        filled,
        record.length - filled,
      );
      if (read <= 0) {
        break;
      }
      filled += read;
    }
    return bytes;
  } finally {
    handle.closeSync();
  }
}
