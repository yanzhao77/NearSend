// Runs a real NearSend node on the LAN so a device can transfer against it.
//
// This exists for the questions no local test can answer: whether Android's TLS stack agrees
// with Windows about a certificate's DER, whether a real device can reach this machine at all,
// whether its file access and its durability behave the same way, and how long a real
// 4 MiB-chunked transfer over Wi-Fi actually takes. Every piece here is the **real** one - the
// node, the endpoints, the storage, the transport - so what the device proves is about the
// product rather than about a mock.
//
// ## How it is driven
//
// It acts on its own, by watching its own database, because there is no second process to talk
// to: the device test runs on the phone and cannot read this process's stdout. So the sequence
// is fixed up front and printed once as a single JSON line:
//
//   1. open a pairing session the caller chose, and stage an outgoing transfer bound to it
//      (`server_to_client`: this node sends, the device receives);
//   2. wait for the device to create its own transfer (`client_to_server`), accept it, and let
//      the device upload;
//   3. verify and export whatever arrived, print the digests it computed, and exit.
//
// The scratch directory must be outside the repository: the TLS private key is written to a
// file because `dart:io` needs one there, and `AGENTS.md` §5 keeps key material out of Git.
//
// Run:
//   dart run tooling/spikes/lan_server/main.dart --out=<scratch dir> [--port=18443]
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'package:nearsend/core/protocol/protocol_limits.dart';
import 'package:nearsend/core/protocol/transfer_direction.dart';
import 'package:nearsend/core/protocol/transfer_state.dart';
import 'package:nearsend/core/network/task_authorization_endpoint.dart';
import 'package:nearsend/core/security/pairing_payload.dart';
import 'package:nearsend/core/storage/space_plan.dart';
import 'package:nearsend/core/transfer/near_send_node.dart';
import 'package:nearsend/core/transfer/transfer_engine.dart';

/// The transfer the device will create and upload (this node receives it).
const String inboundTransferId = '11111111-2222-4333-8444-555555555555';
const String inboundFileId = '00000000-0000-4000-8000-000000000001';

/// The transfer this node creates for the device (this node sends it).
const String outboundTransferId = '22222222-3333-4444-8555-666666666666';
const String outboundFileId = '00000000-0000-4000-8000-000000000002';

/// A session id chosen here rather than generated, so the outgoing transfer can be bound to it
/// before the device has paired. §3 lets the caller supply one.
const String sessionId = '33333333-4444-4555-8666-777777777777';

Future<void> main(List<String> args) async {
  final Map<String, String> options = <String, String>{
    for (final String arg in args)
      if (arg.startsWith('--') && arg.contains('='))
        arg.substring(2, arg.indexOf('=')): arg.substring(arg.indexOf('=') + 1),
  };
  final String? scratch = options['out'];
  if (scratch == null) {
    stderr.writeln('--out=<scratch dir outside the repository> is required');
    exit(2);
  }
  final int port = int.parse(options['port'] ?? '18443');
  final String host = options['host'] ?? await _firstLanAddress();

  final Directory root = Directory(scratch);
  if (!root.existsSync()) {
    root.createSync(recursive: true);
  }

  final NearSendNode node = await NearSendNode.open(
    directory: '${root.path}${Platform.pathSeparator}node',
    candidateAddresses: <String>[host],
    port: port,
  );
  await node.start();

  // §3's payload is what the device scans; the session id is fixed so the outgoing transfer can
  // be bound to it below, before the device exists.
  final PairingPayload payload = node.openPairingSession(sessionId: sessionId);

  final Uint8List outboundBytes = _sample(ProtocolLimits.chunkSizeBytes + 5000);
  final File outboundFile = File(
    '${root.path}${Platform.pathSeparator}outbound-中文文件名.bin',
  );
  outboundFile.writeAsBytesSync(outboundBytes);

  final OutgoingPlan outbound = await node.engine.prepareOutgoing(
    transferId: outboundTransferId,
    direction: TransferDirection.serverToClient,
    peerId: sessionId,
    choices: <OutgoingFileChoice>[
      OutgoingFileChoice(
        fileId: outboundFileId,
        relativePath: 'outbound-中文文件名.bin',
        path: outboundFile.path,
      ),
    ],
  );

  final Directory exports = Directory(
    '${root.path}${Platform.pathSeparator}exports',
  );
  exports.createSync(recursive: true);

  // One line, because the caller parses this and passes it to a device test.
  stdout.writeln(
    jsonEncode(<String, Object?>{
      'kind': 'nearsend-lan-node',
      'host': host,
      'port': node.server.boundPort,
      'pin': payload.serverFingerprint,
      'sessionId': payload.sessionId,
      'pairToken': payload.pairToken,
      'pairingPayload': payload.toJson(),
      'outbound': <String, Object?>{
        'transferId': outboundTransferId,
        'fileId': outboundFileId,
        'manifestDigest': outbound.manifestDigest,
        'sizeBytes': outboundBytes.length,
        'fileSha256': sha256.convert(outboundBytes).toString(),
      },
      'inbound': <String, Object?>{
        'transferId': inboundTransferId,
        'fileId': inboundFileId,
      },
    }),
  );
  await stdout.flush();

  bool acceptedInbound = false;
  bool reportedInbound = false;
  bool reportedOutbound = false;
  final Stopwatch clock = Stopwatch()..start();

  while (clock.elapsed < const Duration(minutes: 10)) {
    await Future<void>.delayed(const Duration(milliseconds: 400));

    if (!acceptedInbound) {
      final TransferState? state = _stateOf(node, inboundTransferId);
      if (state == TransferState.waitingAccept) {
        node.engine.acceptLocally(
          transferId: inboundTransferId,
          context: ReceiverStorageContext(
            stagingVolume: const VolumeId('staging'),
            exportVolume: const VolumeId('internal'),
            databaseVolume: const VolumeId('internal'),
            availability: <VolumeId, VolumeAvailability>{
              const VolumeId('staging'): const VolumeAvailability.known(
                1 << 40,
              ),
              const VolumeId('internal'): const VolumeAvailability.known(
                1 << 40,
              ),
            },
            saveLocationRef: exports.path,
          ),
        );
        acceptedInbound = true;
        stdout.writeln(
          jsonEncode(<String, Object?>{'kind': 'accepted-inbound'}),
        );
        await stdout.flush();
      }
    }

    if (acceptedInbound && !reportedInbound) {
      if (node.tasks.isFullyCommitted(inboundFileId)) {
        final ReceivedFileOutcome outcome = await node.engine.finishFile(
          fileId: inboundFileId,
          targetRef: exports.path,
        );
        final List<File> written = exports
            .listSync(recursive: true)
            .whereType<File>()
            .where((File f) => !f.path.endsWith('.nearsend-part'))
            .toList();
        final File received = written.firstWhere(
          (File f) => !f.uri.pathSegments.last.startsWith('outbound-'),
          orElse: () => written.first,
        );
        stdout.writeln(
          jsonEncode(<String, Object?>{
            'kind': 'inbound-complete',
            'verifiedBytes': outcome.verification.verifiedBytes,
            'wholeFileDigestMatches':
                outcome.verification.wholeFileDigestMatches,
            'savedPath': received.path,
            'savedSha256': sha256
                .convert(received.readAsBytesSync())
                .toString(),
            'exportSaved': outcome.export?.isSaved ?? false,
          }),
        );
        await stdout.flush();
        reportedInbound = true;
      }
    }

    if (!reportedOutbound) {
      final TransferState? state = _stateOf(node, outboundTransferId);
      if (state == TransferState.completed) {
        stdout.writeln(
          jsonEncode(<String, Object?>{
            'kind': 'outbound-complete',
            'mirroredBytes':
                node.mirror.read(outboundTransferId)?.committedBytes ?? 0,
          }),
        );
        await stdout.flush();
        reportedOutbound = true;
      }
    }

    if (reportedInbound && reportedOutbound) {
      stdout.writeln(jsonEncode(<String, Object?>{'kind': 'done'}));
      await stdout.flush();
      break;
    }
  }

  await node.stop();
  node.close();
  exit(0);
}

TransferState? _stateOf(NearSendNode node, String transferId) {
  try {
    return node.transfers.taskState(transferId);
  } on Object {
    // Not created yet: the device has not proposed it. Reported as absent rather than as an
    // error, because "the peer has not started" is the normal state of the first iterations.
    return null;
  }
}

/// A deterministic body, so both ends can state the same expected digest.
Uint8List _sample(int length) => Uint8List.fromList(
  List<int>.generate(length, (int i) => (i * 7 + 11) % 251),
);

/// The first non-loopback IPv4 address, which is what the QR code should offer.
Future<String> _firstLanAddress() async {
  for (final NetworkInterface interface in await NetworkInterface.list(
    type: InternetAddressType.IPv4,
  )) {
    for (final InternetAddress address in interface.addresses) {
      if (!address.isLoopback && !address.address.startsWith('169.254.')) {
        return address.address;
      }
    }
  }
  return '127.0.0.1';
}
