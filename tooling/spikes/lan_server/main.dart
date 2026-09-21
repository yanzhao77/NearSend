// Runs the real NearSend control server on the LAN so a device can be pointed at it.
//
// This exists for the one class of question no local test can answer: whether Android's
// `dart:io` agrees with Windows about a certificate's DER, whether its certificate callback
// runs at the same points, and whether the app can reach this machine at all. The transport,
// the pairing service and the endpoint are the **real** ones - nothing here is a stub - so
// what the device proves is about the product, not about a mock.
//
// The private key of the generated identity is written to a file only because `dart:io`
// needs a file there; it goes to a scratch directory outside the repository, and the script
// refuses to run if pointed inside it (`AGENTS.md` §5).
//
// Run:
//   dart run tooling/spikes/lan_server/main.dart [--port=18443]
import 'dart:convert';
import 'dart:io';

import 'package:nearsend/core/network/control_pipeline.dart';
import 'package:nearsend/core/network/https_control_server.dart';
import 'package:nearsend/core/network/transfer_creation_handler.dart';
import 'package:nearsend/core/protocol/api_routes.dart';
import 'package:nearsend/core/security/pairing_payload.dart';
import 'package:nearsend/core/security/pairing_service.dart';
import 'package:nearsend/core/security/tls_identity.dart';
import 'package:nearsend/core/storage/chunk_repository.dart';
import 'package:nearsend/core/storage/idempotency_repository.dart';
import 'package:nearsend/core/storage/near_send_database.dart';
import 'package:nearsend/core/storage/transfer_repository.dart';

Future<void> main(List<String> args) async {
  final int port =
      args
          .where((String a) => a.startsWith('--port='))
          .map((String a) => int.parse(a.substring('--port='.length)))
          .firstOrNull ??
      18443;

  final List<String> addresses = await _lanAddresses();
  if (addresses.isEmpty) {
    stderr.writeln('no non-loopback IPv4 address found; nothing to advertise');
    exit(2);
  }
  // The certificate names every address the device might try, so a name check can never be
  // the thing that decides a connection (see ADR-0005 §1).
  addresses.insert(0, '127.0.0.1');

  final TlsIdentity identity = generateTlsIdentity(
    commonName: 'NearSend',
    subjectAltNames: addresses,
  );

  final Directory scratch = Directory.systemTemp.createTempSync(
    'nearsend-lan-',
  );
  final NearSendDatabase database = NearSendDatabase.open(
    path: '${scratch.path}${Platform.pathSeparator}lan.db',
  );

  final PairingService pairing = PairingService(
    serverFingerprint: identity.pin,
    candidates: <PairingCandidate>[
      for (final String host in addresses)
        PairingCandidate(host: host, port: port),
    ],
  );

  final TransferCreationEndpoint creation = TransferCreationEndpoint(
    idempotency: IdempotencyRepository(database),
    transfers: TransferRepository(database),
    tasks: ChunkRepository(database),
  );

  final HttpsControlServer server = HttpsControlServer(
    identity: identity,
    pipeline: ControlPipeline(
      authenticator: pairing,
      handlers: <String, ControlHandler>{
        ...pairing.handlers(),
        ApiRoutes.createTransfer.name: creation.handler,
      },
    ),
    port: port,
  );
  await server.start();

  final PairingPayload payload = pairing.openSession();

  // Machine-readable, one fact per line, so a test harness can parse this without guessing.
  stdout.writeln('READY');
  stdout.writeln('PORT=${server.boundPort}');
  stdout.writeln('PIN=${identity.pin}');
  stdout.writeln('SESSION=${payload.sessionId}');
  stdout.writeln('QR=${jsonEncode(payload.toJson())}');
  stdout.writeln('ADDRESSES=${addresses.join(',')}');
  await stdout.flush();

  // Notes for the operator watching this terminal.
  stdout.writeln('');
  stdout.writeln(
    'listening on ${server.boundAddress.address}:${server.boundPort}',
  );
  stdout.writeln('press Ctrl+C to stop');
  await stdout.flush();

  // Kept alive until killed. A `Completer` that never completes would let the process exit
  // early if the event loop ever drained, so the server's own subscription holds it open.
  await ProcessSignal.sigint.watch().first;
  await server.stop();
  database.close();
  scratch.deleteSync(recursive: true);
}

/// Every non-loopback IPv4 address this machine holds.
Future<List<String>> _lanAddresses() async {
  final List<String> out = <String>[];
  for (final NetworkInterface interface in await NetworkInterface.list(
    type: InternetAddressType.IPv4,
    includeLoopback: false,
    includeLinkLocal: false,
  )) {
    for (final InternetAddress address in interface.addresses) {
      out.add(address.address);
    }
  }
  out.sort();
  return out;
}
