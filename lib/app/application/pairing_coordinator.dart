import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:nearsend/app/peer_session.dart';
import 'package:nearsend/core/security/bootstrap_pairing_payload.dart';
import 'package:nearsend/platform/platform_network_gateway.dart';

enum PairingStage { idle, joiningNetwork, verifyingIdentity, connected, failed }

/// Owns one interactive attempt and only the network lease acquired by it.
/// Pages never own the established session or a transfer's lifetime.
class PairingCoordinator extends ChangeNotifier {
  PairingCoordinator({required this.peer, required this.network});

  final PeerSession? peer;
  final PlatformNetworkGateway network;
  PairingStage _stage = PairingStage.idle;
  String? _reason;
  int _generation = 0;
  bool _disposed = false;
  JoinedWifiLease? _lease;

  PairingStage get stage => _stage;
  String? get reason => _reason;
  bool get isBusy =>
      _stage == PairingStage.joiningNetwork ||
      _stage == PairingStage.verifyingIdentity;

  Future<bool> connect(
    ScannedPairingPayload payload, {
    required String localName,
  }) async {
    if (_disposed || isBusy) return false;
    if (peer == null) {
      _set(PairingStage.failed, '本机配对服务尚未就绪，请稍后重试。');
      return false;
    }
    // Replacing a live client would silently terminate transfers on that client.
    if (peer!.isConnected) {
      _set(PairingStage.failed, '请先断开当前连接，再连接另一台设备。');
      return false;
    }
    final int generation = ++_generation;
    bool current() => !_disposed && generation == _generation;
    JoinedWifiLease? acquired;
    try {
      final wifi = payload is BootstrapPairingPayload ? payload.wifi : null;
      if (wifi != null) {
        _set(PairingStage.joiningNetwork);
        acquired = await network.joinWifi(
          ssid: wifi.ssid,
          passphrase: wifi.passphrase,
          security: wifi.security == 'wpa3'
              ? WifiSecurity.wpa3
              : WifiSecurity.wpa2,
        );
        if (!current()) return false;
      }
      _set(PairingStage.verifyingIdentity);
      final pairing = switch (payload) {
        LegacyScannedPairingPayload() => payload.pairing,
        BootstrapPairingPayload() => payload.pairing,
      };
      final bool connected = await peer!.connect(
        pairing,
        displayLabel: localName,
      );
      if (!current()) return false;
      if (!connected) {
        _set(PairingStage.failed, peer!.failureReason ?? '设备连接失败，请重试。');
        return false;
      }
      _lease = acquired;
      acquired = null;
      _set(PairingStage.connected);
      return true;
    } on NetworkBootstrapException catch (error) {
      if (current()) {
        _set(PairingStage.failed, switch (error.failure) {
          NetworkBootstrapFailure.unsupported =>
            '当前平台不支持自动加入网络，请在系统 Wi-Fi 设置中连接后重新扫码。',
          NetworkBootstrapFailure.permissionDenied => '本地网络权限未授予，请检查系统权限。',
          NetworkBootstrapFailure.userCancelled => '已取消加入本地网络。',
          NetworkBootstrapFailure.timedOut => '加入本地网络超时，请重试。',
          _ => '无法加入本地网络，请检查对方热点和系统 Wi-Fi 状态。',
        });
      }
      return false;
    } on Object {
      if (current()) _set(PairingStage.failed, '设备连接失败，请检查本地网络后重试。');
      return false;
    } finally {
      if (acquired != null) await _release(acquired);
    }
  }

  void refuseUnavailableNode() {
    if (!isBusy) _set(PairingStage.failed, '本机节点尚未就绪，请稍后重试。');
  }

  void cancelAttempt() {
    if (!isBusy) return;
    ++_generation;
    peer?.cancelPending();
    _set(PairingStage.idle);
  }

  Future<void> disconnect() async {
    cancelAttempt();
    peer?.disconnect();
    final lease = _lease;
    _lease = null;
    _set(PairingStage.idle);
    if (lease != null) await _release(lease);
  }

  Future<void> _release(JoinedWifiLease lease) async {
    try {
      await network.releaseJoinedWifi(lease.leaseId);
    } on Object {
      // Platform lifecycle cleanup is the fallback; never release another lease.
    }
  }

  void _set(PairingStage stage, [String? reason]) {
    if (_disposed) return;
    _stage = stage;
    _reason = reason;
    notifyListeners();
  }

  @override
  void dispose() {
    cancelAttempt();
    _disposed = true;
    final lease = _lease;
    _lease = null;
    if (lease != null) unawaited(_release(lease));
    super.dispose();
  }
}
