import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

const int networkCandidateLimit = 8;
const Duration networkProbeTimeout = Duration(seconds: 3);

enum NetworkBootstrapFailure {
  unsupported,
  permissionDenied,
  systemBusy,
  userCancelled,
  timedOut,
  unavailable,
  invalidResponse,
}

class NetworkBootstrapException implements Exception {
  const NetworkBootstrapException(this.failure);

  final NetworkBootstrapFailure failure;

  @override
  String toString() => 'NetworkBootstrapException(${failure.name})';
}

class NetworkBootstrapCapabilities {
  const NetworkBootstrapCapabilities({
    required this.canHostLocalOnlyHotspot,
    required this.canJoinWifi,
    required this.joinRequiresSystemApproval,
  });

  const NetworkBootstrapCapabilities.unavailable()
    : canHostLocalOnlyHotspot = false,
      canJoinWifi = false,
      joinRequiresSystemApproval = true;

  final bool canHostLocalOnlyHotspot;
  final bool canJoinWifi;
  final bool joinRequiresSystemApproval;
}

enum WifiSecurity { wpa2, wpa3 }

/// An in-memory lease for a platform-created local-only network.
///
/// The passphrase must only cross an already authenticated control channel or
/// a user-visible short-lived QR flow. It is deliberately omitted from
/// [toString] and has no serialization API.
class LocalOnlyHotspotLease {
  LocalOnlyHotspotLease({
    required this.leaseId,
    required this.ssid,
    required this.passphrase,
    required this.security,
  }) {
    _validateLeaseId(leaseId);
    _validateSsid(ssid);
    _validatePassphrase(passphrase);
  }

  final String leaseId;
  final String ssid;
  final String passphrase;
  final WifiSecurity security;

  @override
  String toString() =>
      'LocalOnlyHotspotLease(leaseId=$leaseId, security=${security.name})';
}

class JoinedWifiLease {
  JoinedWifiLease({required this.leaseId, required this.networkHandle}) {
    _validateLeaseId(leaseId);
    if (networkHandle < 0) {
      throw const FormatException('network handle must be non-negative');
    }
  }

  final String leaseId;
  final int networkHandle;

  @override
  String toString() => 'JoinedWifiLease(leaseId=$leaseId)';
}

abstract interface class PlatformNetworkGateway {
  Future<NetworkBootstrapCapabilities> capabilities();

  Future<LocalOnlyHotspotLease> startLocalOnlyHotspot();

  Future<void> stopLocalOnlyHotspot(String leaseId);

  Future<JoinedWifiLease> joinWifi({
    required String ssid,
    required String passphrase,
    required WifiSecurity security,
  });

  Future<void> releaseJoinedWifi(String leaseId);

  Future<void> openWifiSettings();
}

class UnavailablePlatformNetworkGateway implements PlatformNetworkGateway {
  const UnavailablePlatformNetworkGateway();

  @override
  Future<NetworkBootstrapCapabilities> capabilities() async =>
      const NetworkBootstrapCapabilities.unavailable();

  @override
  Future<JoinedWifiLease> joinWifi({
    required String ssid,
    required String passphrase,
    required WifiSecurity security,
  }) => throw const NetworkBootstrapException(
    NetworkBootstrapFailure.unsupported,
  );

  @override
  Future<void> openWifiSettings() async {}

  @override
  Future<void> releaseJoinedWifi(String leaseId) async {}

  @override
  Future<LocalOnlyHotspotLease> startLocalOnlyHotspot() =>
      throw const NetworkBootstrapException(
        NetworkBootstrapFailure.unsupported,
      );

  @override
  Future<void> stopLocalOnlyHotspot(String leaseId) async {}
}

class MethodChannelPlatformNetworkGateway implements PlatformNetworkGateway {
  MethodChannelPlatformNetworkGateway({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(channelName);

  static const String channelName = 'com.nearsend.app/network';

  final MethodChannel _channel;

  @override
  Future<NetworkBootstrapCapabilities> capabilities() async {
    final Map<Object?, Object?> value = _map(
      await _invoke<Object?>('capabilities'),
    );
    return NetworkBootstrapCapabilities(
      canHostLocalOnlyHotspot: _bool(value, 'canHostLocalOnlyHotspot'),
      canJoinWifi: _bool(value, 'canJoinWifi'),
      joinRequiresSystemApproval: _bool(value, 'joinRequiresSystemApproval'),
    );
  }

  @override
  Future<LocalOnlyHotspotLease> startLocalOnlyHotspot() async {
    final Map<Object?, Object?> value = _map(
      await _invoke<Object?>('startLocalOnlyHotspot'),
    );
    return LocalOnlyHotspotLease(
      leaseId: _string(value, 'leaseId'),
      ssid: _string(value, 'ssid'),
      passphrase: _string(value, 'passphrase'),
      security: _security(_string(value, 'security')),
    );
  }

  @override
  Future<void> stopLocalOnlyHotspot(String leaseId) async {
    _validateLeaseId(leaseId);
    await _invoke<void>('stopLocalOnlyHotspot', <String, Object?>{
      'leaseId': leaseId,
    });
  }

  @override
  Future<JoinedWifiLease> joinWifi({
    required String ssid,
    required String passphrase,
    required WifiSecurity security,
  }) async {
    _validateSsid(ssid);
    _validatePassphrase(passphrase);
    final Map<Object?, Object?> value = _map(
      await _invoke<Object?>('joinWifi', <String, Object?>{
        'ssid': ssid,
        'passphrase': passphrase,
        'security': security.name,
      }),
    );
    return JoinedWifiLease(
      leaseId: _string(value, 'leaseId'),
      networkHandle: _int(value, 'networkHandle'),
    );
  }

  @override
  Future<void> releaseJoinedWifi(String leaseId) async {
    _validateLeaseId(leaseId);
    await _invoke<void>('releaseJoinedWifi', <String, Object?>{
      'leaseId': leaseId,
    });
  }

  @override
  Future<void> openWifiSettings() => _invoke<void>('openWifiSettings');

  Future<T?> _invoke<T>(String method, [Object? arguments]) async {
    try {
      return await _channel.invokeMethod<T>(method, arguments);
    } on PlatformException catch (error) {
      throw NetworkBootstrapException(_failureFor(error.code));
    } on MissingPluginException {
      throw const NetworkBootstrapException(
        NetworkBootstrapFailure.unsupported,
      );
    }
  }
}

class NetworkCandidate {
  const NetworkCandidate({required this.host, required this.port});

  final String host;
  final int port;
}

enum NetworkPathKind { existingNetwork, bootstrapRequired, unavailable }

class NetworkPathDecision {
  const NetworkPathDecision._(this.kind, this.candidate);

  const NetworkPathDecision.existing(NetworkCandidate candidate)
    : this._(NetworkPathKind.existingNetwork, candidate);

  const NetworkPathDecision.bootstrapRequired()
    : this._(NetworkPathKind.bootstrapRequired, null);

  const NetworkPathDecision.unavailable()
    : this._(NetworkPathKind.unavailable, null);

  final NetworkPathKind kind;
  final NetworkCandidate? candidate;
}

typedef AuthenticatedEndpointProbe = Future<bool> Function(
  NetworkCandidate candidate,
);

/// Selects a path only after an authenticated endpoint probe.
///
/// SSID equality, ping and BLE connectivity are intentionally absent: none of
/// them proves that the candidate is the already authenticated NearSend peer.
class NetworkPathSelector {
  const NetworkPathSelector({this.probeTimeout = networkProbeTimeout});

  final Duration probeTimeout;

  Future<NetworkPathDecision> select({
    required List<NetworkCandidate> candidates,
    required AuthenticatedEndpointProbe probe,
    required bool bootstrapSupported,
  }) async {
    if (candidates.length > networkCandidateLimit) {
      throw const FormatException('too many network candidates');
    }
    for (final NetworkCandidate candidate in candidates) {
      _validateCandidate(candidate);
      try {
        if (await probe(candidate).timeout(probeTimeout)) {
          return NetworkPathDecision.existing(candidate);
        }
      } on TimeoutException {
        // A timed-out candidate is unreachable; the next bounded candidate is
        // still safe to try because the probe itself authenticates the peer.
      } on Object {
        // Transport failure is not identity success and does not become one.
      }
    }
    return bootstrapSupported
        ? const NetworkPathDecision.bootstrapRequired()
        : const NetworkPathDecision.unavailable();
  }
}

void _validateCandidate(NetworkCandidate candidate) {
  if (candidate.host.isEmpty ||
      candidate.host.length > 255 ||
      candidate.port < 1 ||
      candidate.port > 65535 ||
      !_isLocalAddress(candidate.host)) {
    throw const FormatException('invalid network candidate');
  }
}

bool _isLocalAddress(String host) {
  final String addressText = host.contains('%')
      ? host.substring(0, host.indexOf('%'))
      : host;
  final InternetAddress? address = InternetAddress.tryParse(addressText);
  if (address == null || address.isLoopback || address.isMulticast) {
    return false;
  }
  final List<int> bytes = address.rawAddress;
  if (address.type == InternetAddressType.IPv4) {
    return bytes[0] == 10 ||
        (bytes[0] == 172 && bytes[1] >= 16 && bytes[1] <= 31) ||
        (bytes[0] == 192 && bytes[1] == 168) ||
        (bytes[0] == 169 && bytes[1] == 254);
  }
  return (bytes[0] & 0xfe) == 0xfc ||
      (bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80);
}

void _validateLeaseId(String value) {
  final RegExp uuid = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
  );
  if (!uuid.hasMatch(value)) throw const FormatException('invalid lease id');
}

void _validateSsid(String value) {
  final int byteLength = utf8.encode(value).length;
  if (byteLength < 1 || byteLength > 32 || value.contains('\u0000')) {
    throw const FormatException('invalid SSID');
  }
}

void _validatePassphrase(String value) {
  if (value.length < 8 ||
      value.length > 63 ||
      value.codeUnits.any((int unit) => unit < 0x20 || unit > 0x7e)) {
    throw const FormatException('invalid Wi-Fi passphrase');
  }
}

Map<Object?, Object?> _map(Object? value) {
  if (value is! Map) throw const FormatException('invalid platform response');
  return value.cast<Object?, Object?>();
}

String _string(Map<Object?, Object?> value, String key) {
  final Object? result = value[key];
  if (result is! String || result.isEmpty) {
    throw const FormatException('invalid platform response');
  }
  return result;
}

bool _bool(Map<Object?, Object?> value, String key) {
  final Object? result = value[key];
  if (result is! bool) throw const FormatException('invalid platform response');
  return result;
}

int _int(Map<Object?, Object?> value, String key) {
  final Object? result = value[key];
  if (result is! int) throw const FormatException('invalid platform response');
  return result;
}

WifiSecurity _security(String value) => switch (value) {
  'wpa2' => WifiSecurity.wpa2,
  'wpa3' => WifiSecurity.wpa3,
  _ => throw const FormatException('unsupported Wi-Fi security'),
};

NetworkBootstrapFailure _failureFor(String code) => switch (code) {
  'NS-NETWORK-PERMISSION' => NetworkBootstrapFailure.permissionDenied,
  'NS-NETWORK-BUSY' => NetworkBootstrapFailure.systemBusy,
  'NS-NETWORK-CANCELLED' => NetworkBootstrapFailure.userCancelled,
  'NS-NETWORK-TIMEOUT' => NetworkBootstrapFailure.timedOut,
  'NS-NETWORK-UNSUPPORTED' => NetworkBootstrapFailure.unsupported,
  'NS-NETWORK-UNAVAILABLE' => NetworkBootstrapFailure.unavailable,
  _ => NetworkBootstrapFailure.invalidResponse,
};
