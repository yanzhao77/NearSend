import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nearsend/app/application/pairing_coordinator.dart';
import 'package:nearsend/app/peer_session.dart';
import 'package:nearsend/core/protocol/base64url.dart';
import 'package:nearsend/core/security/bootstrap_pairing_payload.dart';
import 'package:nearsend/core/security/pairing_payload.dart';
import 'package:nearsend/core/security/tls_identity.dart';
import 'package:nearsend/core/transfer/transfer_client.dart';
import 'package:nearsend/platform/platform_network_gateway.dart';

void main() {
  PairingPayload payload() => PairingPayload(
    serverFingerprint: 'a' * 64,
    sessionId: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
    candidates: const [PairingCandidate(host: '127.0.0.1', port: 8443)],
    pairToken: encodeBase64UrlNoPadding(Uint8List(32)),
    expiresInSeconds: 120,
  );

  test('cancelled handshake cannot register a late success or overwrite a new attempt', () async {
    final clients = <_DelayedClient>[];
    final peer = PeerSession(
      openClient:
          ({required pin, required host, required port, onCertificateSeen}) {
            final client = _DelayedClient();
            clients.add(client);
            return client;
          },
    );
    final coordinator = PairingCoordinator(
      peer: peer,
      network: const UnavailablePlatformNetworkGateway(),
    );
    final first = coordinator.connect(
      LegacyScannedPairingPayload(payload()),
      localName: '本机',
    );
    expect(coordinator.isBusy, isTrue);
    coordinator.cancelAttempt();
    expect(peer.phase, PeerPhase.idle);
    final second = coordinator.connect(
      LegacyScannedPairingPayload(payload()),
      localName: '本机',
    );
    clients[1].completion.complete();
    expect(await second, isTrue);
    clients[0].completion.complete();
    expect(await first, isFalse);
    expect(peer.client, same(clients[1]));
    expect(clients[0].closed, isTrue);
    expect(clients[1].closed, isFalse);
    coordinator.dispose();
    peer.dispose();
  });

  test(
    'duplicate attempt is refused and cancellation closes only pending client',
    () async {
      final client = _DelayedClient();
      int opened = 0;
      final peer = PeerSession(
        openClient:
            ({required pin, required host, required port, onCertificateSeen}) {
              opened++;
              return client;
            },
      );
      final coordinator = PairingCoordinator(
        peer: peer,
        network: const UnavailablePlatformNetworkGateway(),
      );
      final attempt = coordinator.connect(
        LegacyScannedPairingPayload(payload()),
        localName: '本机',
      );
      expect(
        await coordinator.connect(
          LegacyScannedPairingPayload(payload()),
          localName: '本机',
        ),
        isFalse,
      );
      expect(opened, 1);
      coordinator.cancelAttempt();
      client.completion.complete();
      expect(await attempt, isFalse);
      expect(peer.client, isNull);
      expect(client.closed, isTrue);
      coordinator.dispose();
      peer.dispose();
    },
  );

  test(
    'disposed peer rejects late handshake without notifying or resurrecting',
    () async {
      final client = _DelayedClient();
      final peer = PeerSession(
        openClient: ({
          required pin,
          required host,
          required port,
          onCertificateSeen,
        }) => client,
      );
      final pending = peer.connect(payload());
      peer.dispose();
      client.completion.complete();
      expect(await pending, isFalse);
      expect(peer.client, isNull);
      expect(client.closed, isTrue);
    },
  );

  test('live connection cannot be silently replaced or cancelled by a new pairing page', () async {
    final client = _DelayedClient()..completion.complete();
    final peer = PeerSession(
      openClient: ({
        required pin,
        required host,
        required port,
        onCertificateSeen,
      }) => client,
    );
    final coordinator = PairingCoordinator(
      peer: peer,
      network: const UnavailablePlatformNetworkGateway(),
    );
    expect(
      await coordinator.connect(
        LegacyScannedPairingPayload(payload()),
        localName: '本机',
      ),
      isTrue,
    );
    coordinator.cancelAttempt();
    expect(client.closed, isFalse);
    expect(
      await coordinator.connect(
        LegacyScannedPairingPayload(payload()),
        localName: '本机',
      ),
      isFalse,
    );
    expect(peer.client, same(client));
    expect(coordinator.reason, contains('先断开'));
    await coordinator.disconnect();
    expect(client.closed, isTrue);
    expect(peer.phase, PeerPhase.idle);
    coordinator.dispose();
    peer.dispose();
  });

  test('network lease returned after cancellation is released without starting TLS', () async {
    final network = _DelayedNetwork();
    int opened = 0;
    final peer = PeerSession(
      openClient:
          ({required pin, required host, required port, onCertificateSeen}) {
            opened++;
            return _DelayedClient();
          },
    );
    final identity = generateDeviceIdentity();
    final bootstrap = BootstrapPairingPayload(
      mode: BootstrapPairingMode.networkBootstrap,
      pairing: payload(),
      identityPublicKey: identity.publicKeyDer,
      deviceId: identity.deviceId,
      invitationRole: 'host',
      wifi: BootstrapWifiOffer(
        ssid: 'NearSend-test',
        passphrase: 'test-passphrase',
        security: 'wpa2',
      ),
    );
    final coordinator = PairingCoordinator(peer: peer, network: network);
    final attempt = coordinator.connect(bootstrap, localName: '本机');
    expect(coordinator.stage, PairingStage.joiningNetwork);
    coordinator.cancelAttempt();
    network.join.complete(
      JoinedWifiLease(
        leaseId: 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
        networkHandle: 1,
      ),
    );
    expect(await attempt, isFalse);
    expect(network.released, ['bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb']);
    expect(opened, 0);
    coordinator.dispose();
    peer.dispose();
  });

  test('network failure is actionable and carries no credentials', () async {
    final peer = PeerSession();
    final identity = generateDeviceIdentity();
    final coordinator = PairingCoordinator(
      peer: peer,
      network: const UnavailablePlatformNetworkGateway(),
    );
    final bootstrap = BootstrapPairingPayload(
      mode: BootstrapPairingMode.networkBootstrap,
      pairing: payload(),
      identityPublicKey: identity.publicKeyDer,
      deviceId: identity.deviceId,
      invitationRole: 'host',
      wifi: BootstrapWifiOffer(
        ssid: 'private-ssid',
        passphrase: 'private-passphrase',
        security: 'wpa2',
      ),
    );
    expect(await coordinator.connect(bootstrap, localName: '本机'), isFalse);
    expect(coordinator.reason, contains('系统 Wi-Fi'));
    expect(coordinator.reason, isNot(contains('private-')));
    coordinator.dispose();
    peer.dispose();
  });
}

class _DelayedClient extends TransferClient {
  _DelayedClient() : super(pin: 'a' * 64, host: '127.0.0.1', port: 8443);
  final completion = Completer<void>();
  bool closed = false;
  @override
  Future<void> pairFrom(
    PairingPayload payload, {
    required String clientLabel,
  }) => completion.future;
  @override
  void close() {
    closed = true;
    super.close();
  }
}

class _DelayedNetwork extends UnavailablePlatformNetworkGateway {
  final join = Completer<JoinedWifiLease>();
  final released = <String>[];
  @override
  Future<JoinedWifiLease> joinWifi({
    required String ssid,
    required String passphrase,
    required WifiSecurity security,
  }) => join.future;
  @override
  Future<void> releaseJoinedWifi(String leaseId) async {
    released.add(leaseId);
  }
}
