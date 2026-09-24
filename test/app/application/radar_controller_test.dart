import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nearsend/core/security/pairing_service.dart';

import 'package:nearsend/app/application/radar_controller.dart';
import 'package:nearsend/core/security/known_peer_authentication.dart';
import 'package:nearsend/core/storage/near_send_database.dart';
import 'package:nearsend/core/storage/peer_repository.dart';
import 'package:nearsend/platform/ble_control_gateway.dart';
import 'package:nearsend/platform/mdns_discovery_gateway.dart';

void main() {
  test(
    'QR pairs appear without discovery and lose readiness after last activity',
    () {
      final radar = RadarController();
      addTearDown(radar.dispose);
      radar.syncQrSessions(const [
        PairedClientPresence(sessionId: 'qr', label: 'Phone', isRecent: true),
      ]);
      expect(radar.pairedDevices.single.name, 'Phone');
      expect(radar.pairedDevices.single.isReady, isTrue);
      expect(radar.wifiDevices, isEmpty);
      expect(radar.bluetoothDevices, isEmpty);
      radar.syncQrSessions(const [
        PairedClientPresence(sessionId: 'qr', label: 'Phone', isRecent: false),
      ]);
      expect(radar.pairedDevices.single.isReady, isFalse);
      radar.syncQrSessions(const []);
      expect(radar.pairedDevices, isEmpty);
    },
  );

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
      ..markWifiReady();
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
          displayName: '客厅电脑',
          platform: 'windows',
        ),
      ),
    );

    expect(radar.wifiDevices.single.isKnown, isFalse);
    expect(radar.wifiDevices.single.isReady, isFalse);
    expect(radar.wifiDevices.single.name, '客厅电脑');
    expect(radar.wifiDevices.single.platform, 'windows');
    expect(radar.wifiDevices.single.connectionDetail, '192.168.1.2:8443');
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
      ..markWifiReady();

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
    expect(radar.pairedDevices.single.isReady, isTrue);

    now = 31000;
    expect(radar.pairedDevices.single.isReady, isFalse);
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
      ..markWifiReady();
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

    radar.markWifiOff();
    expect(radar.pairedDevices.single.isReady, isFalse);
    radar.markWifiReady();
    expect(radar.pairedDevices.single.isReady, isFalse);
    radar.revoke(peerId);
    expect(radar.pairedDevices.single.isRevoked, isTrue);
    expect(radar.pairedDevices.single.isReady, isFalse);
  });

  test('starts off and BLE advertisements remain unverified candidates', () {
    final RadarController radar = RadarController(clock: () => now)
      ..attach(peers);

    expect(radar.wifiPhase, RadarReadinessPhase.off);
    expect(radar.bluetoothPhase, RadarReadinessPhase.off);
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
        displayName: '附近手机',
      ),
    );
    expect(radar.bluetoothDevices, isEmpty);

    radar.markBluetoothStarting();
    radar.handleBle(
      BlePeerDiscovered(
        peerId: 'platform-peer',
        advertisement: BleAdvertisement(
          protocolMajor: 1,
          protocolMinor: 0,
          instanceTag: Uint8List.fromList(<int>[1, 2, 3, 4, 5, 6]),
        ),
        rssi: -50,
        displayName: '附近手机',
      ),
    );
    expect(radar.bluetoothDevices.single.detail, '蓝牙候选');
    expect(radar.bluetoothDevices.single.name, '附近手机');
    expect(radar.bluetoothDevices.single.isReady, isFalse);
  });

  test('matching mDNS and BLE candidates stay in their transport lists', () {
    final RadarController radar = RadarController(clock: () => now)
      ..attach(peers)
      ..markWifiReady()
      ..markBluetoothReady();
    radar.handleBle(
      BlePeerDiscovered(
        peerId: 'platform-peer',
        advertisement: BleAdvertisement(
          protocolMajor: 1,
          protocolMinor: 0,
          instanceTag: Uint8List.fromList(<int>[
            0xaa,
            0xaa,
            0xaa,
            0xaa,
            0xaa,
            0xaa,
          ]),
        ),
        rssi: -50,
      ),
    );
    radar.handleMdns(
      const MdnsPeerUpserted(
        MdnsDiscoveredPeer(
          serviceName: 'NearSend-aaaaaaaa',
          instanceId: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
          protocolMajor: 1,
          protocolMinor: 0,
          capabilities: <String>{mdnsDiscoveryCapability},
          addresses: <String>['fe80::1234%wlan0'],
          port: 8443,
          displayName: '客厅手机',
          platform: 'android',
        ),
      ),
    );

    expect(radar.wifiDevices.single.name, '客厅手机');
    expect(
      radar.wifiDevices.single.connectionDetail,
      '[fe80::1234%wlan0]:8443',
    );
    expect(radar.bluetoothDevices.single.name, '未命名蓝牙设备');
  });

  test('turning Wi-Fi off does not clear active Bluetooth candidates', () {
    final RadarController radar = RadarController(clock: () => now)
      ..attach(peers)
      ..markWifiReady()
      ..markBluetoothReady();
    radar.handleBle(
      BlePeerDiscovered(
        peerId: 'platform-peer',
        advertisement: BleAdvertisement(
          protocolMajor: 1,
          protocolMinor: 0,
          instanceTag: Uint8List.fromList(<int>[1, 2, 3, 4, 5, 6]),
        ),
        rssi: -50,
        displayName: '蓝牙手机',
      ),
    );

    radar.markWifiOff();

    expect(radar.wifiReady, isFalse);
    expect(radar.bluetoothReady, isTrue);
    expect(radar.bluetoothDevices.single.name, '蓝牙手机');
  });
}
