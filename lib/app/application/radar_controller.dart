import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:nearsend/core/security/known_peer_authentication.dart';
import 'package:nearsend/core/security/pairing_service.dart';
import 'package:nearsend/core/storage/peer_repository.dart';
import 'package:nearsend/platform/ble_control_gateway.dart';
import 'package:nearsend/platform/mdns_discovery_gateway.dart';

enum RadarReadinessPhase { off, starting, ready, stopping, error }

class RadarDevice {
  const RadarDevice({
    required this.id,
    required this.name,
    required this.detail,
    required this.isKnown,
    required this.isReady,
    required this.isRevoked,
    this.platform = '平台未知',
    this.discoveryMethod = '发现方式未知',
    this.connectionDetail,
  });

  final String id;
  final String name;
  final String detail;
  final bool isKnown;
  final bool isReady;
  final bool isRevoked;
  final String platform;
  final String discoveryMethod;
  final String? connectionDetail;
}

class RadarController extends ChangeNotifier {
  RadarController({int Function()? clock})
    : _clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch);

  final int Function() _clock;
  final Map<String, MdnsDiscoveredPeer> _mdns = <String, MdnsDiscoveredPeer>{};
  final Map<String, _BleCandidate> _ble = <String, _BleCandidate>{};
  final Map<String, VerifiedPeerSession> _verified =
      <String, VerifiedPeerSession>{};
  PeerRepository? _peers;
  List<RadarDevice> _qrDevices = const [];

  /// QR sessions are display-only and never create a persistent trust record.
  void syncQrSessions(
    List<PairedClientPresence> incoming, {
    RadarDevice? outgoing,
  }) {
    final next = <RadarDevice>[
      for (final client in incoming)
        RadarDevice(
          id: 'qr-in:${client.sessionId}',
          name: client.label.isEmpty ? '扫码连接设备' : client.label,
          detail: '二维码配对 · 本次会话',
          isKnown: true,
          isReady: client.isRecent,
          isRevoked: false,
          discoveryMethod: '二维码配对',
        ),
      ?outgoing,
    ];
    if (next.length == _qrDevices.length &&
        List.generate(
          next.length,
          (i) =>
              next[i].id == _qrDevices[i].id &&
              next[i].name == _qrDevices[i].name &&
              next[i].isReady == _qrDevices[i].isReady,
        ).every((same) => same)) {
      return;
    }
    _qrDevices = next;
    notifyListeners();
  }

  RadarReadinessPhase _wifiPhase = RadarReadinessPhase.off;
  RadarReadinessPhase _bluetoothPhase = RadarReadinessPhase.off;
  String? _wifiFailureReason;
  String? _bluetoothFailureReason;
  Timer? _expiryTimer;

  RadarReadinessPhase get wifiPhase => _wifiPhase;

  RadarReadinessPhase get bluetoothPhase => _bluetoothPhase;

  bool get wifiReady => _wifiPhase == RadarReadinessPhase.ready;

  bool get bluetoothReady => _bluetoothPhase == RadarReadinessPhase.ready;

  bool get ready => wifiReady || bluetoothReady;

  bool get wifiBusy => _isBusy(_wifiPhase);

  bool get bluetoothBusy => _isBusy(_bluetoothPhase);

  String? get wifiFailureReason => _wifiFailureReason;

  String? get bluetoothFailureReason => _bluetoothFailureReason;

  void attach(PeerRepository peers) {
    _peers = peers;
    notifyListeners();
  }

  void markWifiStarting() => _setWifiPhase(RadarReadinessPhase.starting);

  void markWifiReady() => _setWifiPhase(RadarReadinessPhase.ready);

  void markWifiStopping() => _setWifiPhase(RadarReadinessPhase.stopping);

  void markWifiError(String reason) {
    _wifiFailureReason = reason;
    _setWifiPhase(RadarReadinessPhase.error, clearFailure: false);
  }

  void markWifiOff() {
    _mdns.clear();
    if (_bluetoothPhase == RadarReadinessPhase.off) {
      _clearProofs();
    }
    _setWifiPhase(RadarReadinessPhase.off);
  }

  void markBluetoothStarting() =>
      _setBluetoothPhase(RadarReadinessPhase.starting);

  void markBluetoothReady() => _setBluetoothPhase(RadarReadinessPhase.ready);

  void markBluetoothStopping() =>
      _setBluetoothPhase(RadarReadinessPhase.stopping);

  void markBluetoothError(String reason) {
    _bluetoothFailureReason = reason;
    _setBluetoothPhase(RadarReadinessPhase.error, clearFailure: false);
  }

  void markBluetoothOff() {
    _ble.clear();
    if (_wifiPhase == RadarReadinessPhase.off) {
      _clearProofs();
    }
    _setBluetoothPhase(RadarReadinessPhase.off);
  }

  void _setWifiPhase(RadarReadinessPhase value, {bool clearFailure = true}) {
    if (_wifiPhase == value && (!clearFailure || _wifiFailureReason == null)) {
      return;
    }
    _wifiPhase = value;
    if (clearFailure) _wifiFailureReason = null;
    notifyListeners();
  }

  void _setBluetoothPhase(
    RadarReadinessPhase value, {
    bool clearFailure = true,
  }) {
    if (_bluetoothPhase == value &&
        (!clearFailure || _bluetoothFailureReason == null)) {
      return;
    }
    _bluetoothPhase = value;
    if (clearFailure) _bluetoothFailureReason = null;
    notifyListeners();
  }

  void _clearProofs() {
    _verified.clear();
    _expiryTimer?.cancel();
    _expiryTimer = null;
  }

  void handleMdns(MdnsDiscoveryEvent event) {
    if (_wifiPhase == RadarReadinessPhase.off ||
        _wifiPhase == RadarReadinessPhase.stopping) {
      return;
    }
    switch (event) {
      case MdnsPeerUpserted():
        _mdns[event.peer.serviceName] = event.peer;
      case MdnsPeerLost():
        _mdns.remove(event.serviceName);
      case MdnsDiscoveryIssue():
        return;
    }
    notifyListeners();
  }

  void handleBle(BleControlEvent event) {
    if (_bluetoothPhase == RadarReadinessPhase.off ||
        _bluetoothPhase == RadarReadinessPhase.stopping) {
      return;
    }
    switch (event) {
      case BlePeerDiscovered():
        _ble[event.peerId] = _BleCandidate(
          advertisement: event.advertisement,
          seenAtMillis: _clock(),
          displayName: event.displayName,
        );
        _scheduleExpiry();
      case BlePeerDisconnected():
        _ble.remove(event.peerId);
      case BlePeerConnected() || BleMessageReceived() || BleControlIssue():
        return;
    }
    notifyListeners();
  }

  void recordVerified(VerifiedPeerSession session) {
    if (!ready) return;
    final PeerRecord? peer = _peers?.find(session.peerId);
    if (peer?.trust != PeerTrust.authorized) return;
    _verified[session.peerId] = session;
    _scheduleExpiry();
    notifyListeners();
  }

  void revoke(String peerId) {
    _peers?.revoke(peerId);
    _verified.remove(peerId);
    notifyListeners();
  }

  List<RadarDevice> get pairedDevices {
    final int now = _clock();
    final List<RadarDevice> out = <RadarDevice>[..._qrDevices];
    for (final PeerRecord peer in _peers?.history() ?? const <PeerRecord>[]) {
      final VerifiedPeerSession? verified = _verified[peer.peerId];
      out.add(
        RadarDevice(
          id: peer.peerId,
          name: peer.displayName ?? '已配对设备',
          detail: peer.platform ?? '平台未知',
          isKnown: true,
          isReady:
              ready &&
              peer.trust == PeerTrust.authorized &&
              verified != null &&
              verified.isFreshAt(now),
          isRevoked: peer.trust == PeerTrust.revoked,
          platform: peer.platform ?? '平台未知',
          discoveryMethod: '配对历史',
        ),
      );
    }
    return List<RadarDevice>.unmodifiable(out);
  }

  List<RadarDevice> get bluetoothDevices {
    final int now = _clock();
    final List<RadarDevice> out = <RadarDevice>[];
    for (final MapEntry<String, _BleCandidate> entry in _ble.entries) {
      if (entry.value.isFreshAt(now)) {
        out.add(
          RadarDevice(
            id: entry.key,
            name: entry.value.displayName ?? '未命名蓝牙设备',
            detail: '蓝牙候选',
            isKnown: false,
            isReady: false,
            isRevoked: false,
            discoveryMethod: '蓝牙发现',
          ),
        );
      }
    }
    return List<RadarDevice>.unmodifiable(out);
  }

  List<RadarDevice> get wifiDevices {
    final List<RadarDevice> out = <RadarDevice>[];
    for (final MdnsDiscoveredPeer peer in _mdns.values) {
      out.add(
        RadarDevice(
          id: peer.instanceId,
          name: peer.displayName ?? '未命名设备',
          detail:
              '${peer.platform ?? '平台未知'} · 局域网候选 · ${peer.addresses.length} 个地址',
          isKnown: false,
          isReady: false,
          isRevoked: false,
          platform: peer.platform ?? '平台未知',
          discoveryMethod: '局域网发现',
          connectionDetail: peer.addresses
              .map((String address) => _formatEndpoint(address, peer.port))
              .join('、'),
        ),
      );
    }
    return List<RadarDevice>.unmodifiable(out);
  }

  List<RadarDevice> get devices => List<RadarDevice>.unmodifiable(<RadarDevice>[
    ...pairedDevices,
    ...wifiDevices,
    ...bluetoothDevices,
  ]);

  void _scheduleExpiry() {
    _expiryTimer?.cancel();
    _expiryTimer = Timer(const Duration(seconds: 30), () {
      final int now = _clock();
      _ble.removeWhere(
        (String _, _BleCandidate candidate) => !candidate.isFreshAt(now),
      );
      _verified.removeWhere(
        (String _, VerifiedPeerSession session) => !session.isFreshAt(now),
      );
      notifyListeners();
      if (_ble.isNotEmpty || _verified.isNotEmpty) _scheduleExpiry();
    });
  }

  @override
  void dispose() {
    _expiryTimer?.cancel();
    super.dispose();
  }
}

bool _isBusy(RadarReadinessPhase phase) =>
    phase == RadarReadinessPhase.starting ||
    phase == RadarReadinessPhase.stopping;

String _formatEndpoint(String address, int port) =>
    address.contains(':') ? '[$address]:$port' : '$address:$port';

class _BleCandidate {
  const _BleCandidate({
    required this.advertisement,
    required this.seenAtMillis,
    this.displayName,
  });

  final BleAdvertisement advertisement;
  final int seenAtMillis;
  final String? displayName;

  bool isFreshAt(int nowMillis) => nowMillis - seenAtMillis < 30000;
}
