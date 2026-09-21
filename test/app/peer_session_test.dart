import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:nearsend/app/peer_session.dart';
import 'package:nearsend/core/network/https_control_client.dart';
import 'package:nearsend/core/security/pairing_payload.dart';
import 'package:nearsend/core/transfer/near_send_node.dart';
import 'package:nearsend/core/transfer/transfer_client.dart';

/// The connection to the other device, against a real pinned server.
///
/// ## Why these cases run over a real socket
///
/// The two things this class decides cannot be shown with a stub: that the addresses in a payload
/// are tried **in order** until one answers, and that a fingerprint mismatch stops the attempt
/// rather than moving to the next address. The second is §2's rule, and its evidence is not "the
/// call returned false" but "the peer's one-time token was still unused afterwards" - a wrong pin
/// must never reach the server at all, and only a real server can show that.
void main() {
  late Directory root;
  late NearSendNode server;

  setUp(() async {
    root = Directory.systemTemp.createTempSync('nearsend-peer-');
    server = await NearSendNode.open(
      directory: '${root.path}${Platform.pathSeparator}server',
      candidateAddresses: const <String>['127.0.0.1'],
    );
    await server.start();
  });

  tearDown(() async {
    await server.stop();
    server.close();
    if (root.existsSync()) {
      root.deleteSync(recursive: true);
    }
  });

  /// A payload issued by the server, with the real pin and token unless told otherwise.
  ///
  /// Re-issuing invalidates the previous session's token, which is why each case issues its own and
  /// builds variants from that one rather than from whatever the server last published.
  PairingPayload withCandidates(
    PairingPayload base,
    List<PairingCandidate> candidates, {
    String? fingerprint,
  }) => PairingPayload(
    serverFingerprint: fingerprint ?? base.serverFingerprint,
    sessionId: base.sessionId,
    candidates: candidates,
    pairToken: base.pairToken,
    expiresInSeconds: base.expiresInSeconds,
  );

  const PairingCandidate deadAddress = PairingCandidate(
    host: '127.0.0.1',
    port: 1,
  );

  test('a published payload pairs a real client', () async {
    final PairingPayload payload = server.openPairingSession();
    final PeerSession peer = PeerSession(
      connectTimeout: const Duration(seconds: 5),
    );

    expect(peer.phase, PeerPhase.idle);
    expect(await peer.connect(payload), isTrue);

    expect(peer.phase, PeerPhase.connected);
    expect(peer.isConnected, isTrue);
    expect(
      peer.client!.sessionToken,
      isNotNull,
      reason:
          '§3 issues a session token at pairing; a connection without one could not reach a '
          'single transfer route',
    );
    expect(peer.peer, same(payload));

    peer.dispose();
  });

  test('the addresses are tried in order until one answers', () async {
    int opened = 0;
    final PeerSession peer = PeerSession(
      connectTimeout: const Duration(seconds: 5),
      openClient:
          ({
            required String pin,
            required String host,
            required int port,
            void Function(PinnedConnectionOutcome, String)? onCertificateSeen,
          }) {
            opened++;
            return TransferClient(
              pin: pin,
              host: host,
              port: port,
              onCertificateSeen: onCertificateSeen,
            );
          },
    );
    final PairingPayload base = server.openPairingSession();

    final bool connected = await peer.connect(
      withCandidates(base, <PairingCandidate>[
        deadAddress,
        base.candidates.single,
      ]),
    );

    expect(connected, isTrue);
    expect(
      opened,
      2,
      reason:
          'a device with several interfaces publishes several addresses and only one answers; '
          'giving up after the first would refuse a peer that is reachable',
    );
    peer.dispose();
  });

  test('a fingerprint that does not match stops the attempt', () async {
    int opened = 0;
    final PeerSession peer = PeerSession(
      connectTimeout: const Duration(seconds: 5),
      openClient:
          ({
            required String pin,
            required String host,
            required int port,
            void Function(PinnedConnectionOutcome, String)? onCertificateSeen,
          }) {
            opened++;
            return TransferClient(
              pin: pin,
              host: host,
              port: port,
              onCertificateSeen: onCertificateSeen,
            );
          },
    );
    final PairingPayload genuine = server.openPairingSession();

    final bool connected = await peer.connect(
      withCandidates(
        genuine,
        <PairingCandidate>[
          genuine.candidates.single,
          const PairingCandidate(host: '127.0.0.1', port: 2),
        ],
        // A pin of the right shape that is not this server's.
        fingerprint: '00' * 32,
      ),
    );

    expect(connected, isFalse);
    expect(peer.phase, PeerPhase.failed);
    expect(peer.client, isNull);
    expect(
      peer.pinMismatched,
      isTrue,
      reason:
          'an unreachable peer is worth retrying and a mismatched fingerprint is not, so the two '
          'must not collapse into one failure',
    );
    expect(
      peer.presentedFingerprint,
      server.pin,
      reason:
          'the value the peer actually presented is what lets a person see that the devices '
          'disagree about a certificate rather than that the network failed',
    );
    expect(peer.failureReason, PeerSession.pinMismatchReason);
    expect(
      opened,
      1,
      reason:
          '§3: choosing a candidate must not bypass the pin, and a mismatch is a statement about '
          'the peer identity rather than about that address, so the second address is not asked',
    );

    // The part that makes the claim checkable from the other side: §3's token is one-time, so if
    // the wrong-pin attempt had reached the server this pairing would now be refused. It succeeds,
    // which is what "the connection was closed before any request" means in evidence rather than in
    // prose.
    final PeerSession second = PeerSession(
      connectTimeout: const Duration(seconds: 5),
    );
    expect(await second.connect(genuine), isTrue);
    second.dispose();
    peer.dispose();
  });

  test('a peer that answers nothing is reported as unreachable', () async {
    final PeerSession peer = PeerSession(
      connectTimeout: const Duration(seconds: 5),
    );
    final PairingPayload base = server.openPairingSession();

    final bool connected = await peer.connect(
      withCandidates(base, <PairingCandidate>[deadAddress]),
    );

    expect(connected, isFalse);
    expect(peer.failureReason, PeerSession.unreachableReason);
    expect(
      peer.pinMismatched,
      isFalse,
      reason:
          'no certificate was ever seen, and reporting a fingerprint problem here would send the '
          'user to re-pair over a Wi-Fi problem',
    );
    expect(peer.presentedFingerprint, isNull);
    peer.dispose();
  });

  test('disconnecting drops the client and returns to idle', () async {
    final PeerSession peer = PeerSession(
      connectTimeout: const Duration(seconds: 5),
    );
    final PairingPayload base = server.openPairingSession();
    await peer.connect(
      withCandidates(base, <PairingCandidate>[base.candidates.single]),
    );
    expect(peer.isConnected, isTrue);

    peer.disconnect();

    expect(peer.phase, PeerPhase.idle);
    expect(peer.client, isNull);
    expect(peer.failureReason, isNull);
    peer.dispose();
  });
}
