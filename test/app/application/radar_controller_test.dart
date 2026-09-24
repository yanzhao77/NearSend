import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:nearsend/app/application/radar_controller.dart';
import 'package:nearsend/core/security/known_peer_authentication.dart';
import 'package:nearsend/core/storage/near_send_database.dart';
import 'package:nearsend/core/storage/peer_repository.dart';
import 'package:nearsend/platform/ble_control_gateway.dart';
import 'package:nearsend/platform/mdns_discovery_gateway.dart';

void main() {
  late Directory directory;
  late NearSendDatabase database;
  late PeerRepository peers;
  late int now;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('nearsend-radar-');
    database = NearSendDatabase.open(path: '${directory.path}/radar.db');
    now = 1000;
    peers = PeerRepository(database, now: () => now);
  });

  tearDown(() {
    database.close();
    directory.deleteSync(recursive: true);
  });

  test('advertisements never produce a ready light', () {
    final RadarController radar = RadarController(clock: () => now)
      ..attach(peers)
      ..markReady();
    radar.handleMdns(
      MdnsPeerUpserted(
        const MdnsDiscoveredPeer(
          serviceName: 'NearSend-candidate',
          instanceId: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
          protocolMajor: 1,
          protocolMinor: 0,
          capabilities: <String>{mdnsDiscoveryCapability},
          addresses: <String>['192.168.1.2'],
          port: 8443,
        ),
      ),
    );

    expect(radar.devices.single.isKnown, isFalse);
    expect(radar.devices.single.isReady, isFalse);
  });

  test('only a fresh ready proof lights an authorized peer', () {
    const String peerId =
        'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
    peers.recordUserAuthorization(
      peerId: peerId,
      identityFingerprint: 'b' * 64,
      displayName: 'Office PC',
    );
    final RadarController radar = RadarController(clock: () => now)
      ..attach(peers)
      ..markReady();

    radar.recordVerified(
      const VerifiedPeerSession(
        peerId: peerId,
        tlsFingerprint:
            'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
        ready: true,
        verifiedAtMillis: 1000,
        expiresAtMillis: 31000,
      ),
    );
    expect(radar.devices.single.isReady, isTrue);

    now = 31000;
    expect(radar.devices.single.isReady, isFalse);
  });

  test('ready off clears proof and revoked peers stay unlit', () {
    const String peerId =
        'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
    peers.recordUserAuthorization(
      peerId: peerId,
      identityFingerprint: 'b' * 64,
    );
    final RadarController radar = RadarController(clock: () => now)
      ..attach(peers)
      ..markReady();
    radar.recordVerified(
      const VerifiedPeerSession(
        peerId: peerId,
        tlsFingerprint:
            'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
        ready: true,
        verifiedAtMillis: 1000,
        expiresAtMillis: 31000,
      ),
    );

    radar.markOff();
    expect(radar.devices.single.isReady, isFalse);
    radar.markReady();
    expect(radar.devices.single.isReady, isFalse);
    radar.revoke(peerId);
    expect(radar.devices.single.isRevoked, isTrue);
    expect(radar.devices.single.isReady, isFalse);
  });

  test('starts off and BLE advertisements remain unverified candidates', () {
    final RadarController radar = RadarController(clock: () => now)
      ..attach(peers);

    expect(radar.phase, RadarReadinessPhase.off);
    expect(radar.ready, isFalse);
    radar.handleBle(
      BlePeerDiscovered(
        peerId: 'platform-peer',
        advertisement: BleAdvertisement(
          protocolMajor: 1,
          protocolMinor: 0,
          instanceTag: Uint8List.fromList(<int>[1, 2, 3, 4, 5, 6]),
        ),
        rssi: -50,
      ),
    );
    expect(radar.devices, isEmpty);

    radar.markStarting();
    radar.handleBle(
      BlePeerDiscovered(
        peerId: 'platform-peer',
        advertisement: BleAdvertisement(
          protocolMajor: 1,
          protocolMinor: 0,
          instanceTag: Uint8List.fromList(<int>[1, 2, 3, 4, 5, 6]),
        ),
        rssi: -50,
      ),
    );
    expect(radar.devices.single.detail, '蓝牙候选');
    expect(radar.devices.single.isReady, isFalse);
  });
}
