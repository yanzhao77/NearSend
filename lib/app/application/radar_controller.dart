import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:nearsend/core/security/known_peer_authentication.dart';
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
  });

  final String id;
  final String name;
  final String detail;
  final bool isKnown;
  final bool isReady;
  final bool isRevoked;
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
  RadarReadinessPhase _phase = RadarReadinessPhase.off;
  String? _failureReason;
  Timer? _expiryTimer;

  RadarReadinessPhase get phase => _phase;

  bool get ready => _phase == RadarReadinessPhase.ready;

  bool get isBusy =>
      _phase == RadarReadinessPhase.starting ||
      _phase == RadarReadinessPhase.stopping;

  String? get failureReason => _failureReason;

  void attach(PeerRepository peers) {
    _peers = peers;
    notifyListeners();
  }

  void markStarting() => _setPhase(RadarReadinessPhase.starting);

  void markReady() => _setPhase(RadarReadinessPhase.ready);

  void markStopping() => _setPhase(RadarReadinessPhase.stopping);

  void markError(String reason) {
    _failureReason = reason;
    _setPhase(RadarReadinessPhase.error, clearFailure: false);
  }

  void markOff() {
    _mdns.clear();
    _ble.clear();
    _verified.clear();
    _expiryTimer?.cancel();
    _expiryTimer = null;
    _setPhase(RadarReadinessPhase.off);
  }

  void _setPhase(RadarReadinessPhase value, {bool clearFailure = true}) {
    if (_phase == value && (!clearFailure || _failureReason == null)) return;
    _phase = value;
    if (clearFailure) _failureReason = null;
    notifyListeners();
  }

  void handleMdns(MdnsDiscoveryEvent event) {
    if (_phase == RadarReadinessPhase.off ||
        _phase == RadarReadinessPhase.stopping) {
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
    if (_phase == RadarReadinessPhase.off ||
        _phase == RadarReadinessPhase.stopping) {
      return;
    }
    switch (event) {
      case BlePeerDiscovered():
        _ble[event.peerId] = _BleCandidate(
          advertisement: event.advertisement,
          seenAtMillis: _clock(),
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

  List<RadarDevice> get devices {
    final int now = _clock();
    final List<RadarDevice> out = <RadarDevice>[];
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
        ),
      );
    }
    for (final MapEntry<String, _BleCandidate> entry in _ble.entries) {
      if (entry.value.isFreshAt(now)) {
        out.add(
          RadarDevice(
            id: entry.key,
            name: '附近设备',
            detail: '蓝牙候选',
            isKnown: false,
            isReady: false,
            isRevoked: false,
          ),
        );
      }
    }
    for (final MdnsDiscoveredPeer peer in _mdns.values) {
      out.add(
        RadarDevice(
          id: peer.instanceId,
          name: '附近设备',
          detail: '局域网候选 · ${peer.addresses.length} 个地址',
          isKnown: false,
          isReady: false,
          isRevoked: false,
        ),
      );
    }
    return List<RadarDevice>.unmodifiable(out);
  }

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

class _BleCandidate {
  const _BleCandidate({
    required this.advertisement,
    required this.seenAtMillis,
  });

  final BleAdvertisement advertisement;
  final int seenAtMillis;

  bool isFreshAt(int nowMillis) => nowMillis - seenAtMillis < 30000;
}
