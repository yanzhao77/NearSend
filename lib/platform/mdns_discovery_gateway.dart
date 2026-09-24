import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bonsoir/bonsoir.dart';

import 'package:nearsend/core/protocol/protocol_limits.dart';
import 'package:nearsend/core/protocol/protocol_validation.dart';

const String nearSendMdnsServiceType = '_nearsend._tcp';
const String mdnsDiscoveryCapability = 'discovery.mdns.v1';

class MdnsPublication {
  MdnsPublication({required this.instanceId, required this.port}) {
    uuidToBytes(instanceId, 'mDNS instance id');
    if (port < 1 || port > ProtocolLimits.maxPort) {
      throw ArgumentError.value(port, 'port', 'must be 1..65535');
    }
  }

  final String instanceId;
  final int port;

  String get serviceName => 'NearSend-${instanceId.substring(0, 8)}';

  Map<String, String> get attributes => <String, String>{
    'maj': '${ProtocolLimits.protocolMajor}',
    'min': '${ProtocolLimits.protocolMinor}',
    'iid': instanceId,
    'caps': mdnsDiscoveryCapability,
  };
}

class MdnsWireService {
  const MdnsWireService({
    required this.name,
    required this.port,
    required this.hostAddresses,
    required this.attributes,
  });

  final String name;
  final int port;
  final List<String> hostAddresses;
  final Map<String, String> attributes;
}

class MdnsDiscoveredPeer {
  const MdnsDiscoveredPeer({
    required this.serviceName,
    required this.instanceId,
    required this.protocolMajor,
    required this.protocolMinor,
    required this.capabilities,
    required this.addresses,
    required this.port,
  });

  static const int maxAddresses = 16;
  static const int maxCapabilities = 16;

  final String serviceName;
  final String instanceId;
  final int protocolMajor;
  final int protocolMinor;
  final Set<String> capabilities;
  final List<String> addresses;
  final int port;

  bool get isProtocolCompatible =>
      protocolMajor == ProtocolLimits.protocolMajor;

  static MdnsDiscoveredPeer? tryParse(MdnsWireService wire) {
    if (wire.name.isEmpty ||
        utf8.encode(wire.name).length > 255 ||
        wire.name.codeUnits.any((int unit) => unit < 0x20 || unit == 0x7F) ||
        wire.port < 1 ||
        wire.port > ProtocolLimits.maxPort) {
      return null;
    }
    final int? major = _canonicalUnsigned(wire.attributes['maj']);
    final int? minor = _canonicalUnsigned(wire.attributes['min']);
    final String? instanceId = wire.attributes['iid'];
    if (major == null || minor == null || instanceId == null) return null;
    try {
      uuidToBytes(instanceId, 'mDNS instance id');
    } on Object {
      return null;
    }

    final Set<String>? capabilities = _parseCapabilities(
      wire.attributes['caps'],
    );
    if (capabilities == null ||
        !capabilities.contains(mdnsDiscoveryCapability)) {
      return null;
    }

    final List<String> addresses = <String>[];
    for (final String raw in wire.hostAddresses.take(maxAddresses * 2)) {
      if (_isUsableAddress(raw) && !addresses.contains(raw)) {
        addresses.add(raw);
        if (addresses.length == maxAddresses) break;
      }
    }
    if (addresses.isEmpty) return null;

    return MdnsDiscoveredPeer(
      serviceName: wire.name,
      instanceId: instanceId,
      protocolMajor: major,
      protocolMinor: minor,
      capabilities: Set<String>.unmodifiable(capabilities),
      addresses: List<String>.unmodifiable(addresses),
      port: wire.port,
    );
  }

  static int? _canonicalUnsigned(String? value) {
    if (value == null || !RegExp(r'^(0|[1-9][0-9]{0,8})$').hasMatch(value)) {
      return null;
    }
    return int.tryParse(value);
  }

  static Set<String>? _parseCapabilities(String? value) {
    if (value == null || value.isEmpty) return null;
    final List<String> parts = value.split(',');
    if (parts.length > maxCapabilities) return null;
    final Set<String> parsed = <String>{};
    for (final String part in parts) {
      if (!RegExp(r'^[a-z0-9][a-z0-9.-]{0,47}$').hasMatch(part) ||
          !parsed.add(part)) {
        return null;
      }
    }
    return parsed;
  }

  static bool _isUsableAddress(String value) {
    if (value.isEmpty || value.trim() != value) return false;
    final int zoneAt = value.indexOf('%');
    if (zoneAt != value.lastIndexOf('%')) return false;
    final String addressText = zoneAt == -1
        ? value
        : value.substring(0, zoneAt);
    if (zoneAt != -1) {
      final String zone = value.substring(zoneAt + 1);
      if (zone.isEmpty || !RegExp(r'^[A-Za-z0-9_.-]+$').hasMatch(zone)) {
        return false;
      }
    }
    final InternetAddress? address = InternetAddress.tryParse(addressText);
    if (address == null || address.isLoopback) return false;
    final List<int> bytes = address.rawAddress;
    if (bytes.every((int byte) => byte == 0)) return false;
    if (address.type == InternetAddressType.IPv4 && bytes.first >= 224) {
      return false;
    }
    if (address.type == InternetAddressType.IPv6 && bytes.first == 0xFF) {
      return false;
    }
    return true;
  }
}

sealed class MdnsDiscoveryEvent {
  const MdnsDiscoveryEvent();
}

class MdnsPeerUpserted extends MdnsDiscoveryEvent {
  const MdnsPeerUpserted(this.peer);

  final MdnsDiscoveredPeer peer;
}

class MdnsPeerLost extends MdnsDiscoveryEvent {
  const MdnsPeerLost(this.serviceName);

  final String serviceName;
}

class MdnsDiscoveryIssue extends MdnsDiscoveryEvent {
  const MdnsDiscoveryIssue(this.code);

  final String code;
}

sealed class MdnsPlatformEvent {
  const MdnsPlatformEvent();
}

class MdnsPlatformUpsert extends MdnsPlatformEvent {
  const MdnsPlatformUpsert(this.service);

  final MdnsWireService service;
}

class MdnsPlatformLost extends MdnsPlatformEvent {
  const MdnsPlatformLost(this.serviceName);

  final String serviceName;
}

class MdnsPlatformIssue extends MdnsPlatformEvent {
  const MdnsPlatformIssue(this.code);

  final String code;
}

abstract interface class MdnsPlatformSession {
  Stream<MdnsPlatformEvent> get events;

  Future<void> stop();
}

abstract interface class MdnsPlatformAdapter {
  Future<MdnsPlatformSession> start(MdnsPublication publication);
}

class MdnsDiscoveryGateway {
  MdnsDiscoveryGateway({MdnsPlatformAdapter? adapter})
    : _adapter = adapter ?? BonsoirMdnsPlatformAdapter();

  final MdnsPlatformAdapter _adapter;
  final StreamController<MdnsDiscoveryEvent> _events =
      StreamController<MdnsDiscoveryEvent>.broadcast();

  MdnsPlatformSession? _session;
  StreamSubscription<MdnsPlatformEvent>? _subscription;
  Future<void>? _startAttempt;
  String? _localInstanceId;
  final Set<String> _visibleServices = <String>{};

  Stream<MdnsDiscoveryEvent> get events => _events.stream;

  bool get isRunning => _session != null;

  Future<void> start(MdnsPublication publication) {
    if (_session != null) return Future<void>.value();
    final Future<void>? inFlight = _startAttempt;
    if (inFlight != null) return inFlight;
    final Future<void> attempt = _start(publication);
    _startAttempt = attempt;
    return attempt;
  }

  Future<void> _start(MdnsPublication publication) async {
    try {
      final MdnsPlatformSession session = await _adapter.start(publication);
      _localInstanceId = publication.instanceId;
      _session = session;
      _subscription = session.events.listen(
        _handle,
        onError: (Object _) =>
            _events.add(const MdnsDiscoveryIssue('mdns.eventStreamFailed')),
      );
    } finally {
      _startAttempt = null;
    }
  }

  void _handle(MdnsPlatformEvent event) {
    switch (event) {
      case MdnsPlatformUpsert():
        final MdnsDiscoveredPeer? peer = MdnsDiscoveredPeer.tryParse(
          event.service,
        );
        if (peer != null && peer.instanceId != _localInstanceId) {
          _visibleServices.add(peer.serviceName);
          _events.add(MdnsPeerUpserted(peer));
        } else if (_visibleServices.remove(event.service.name)) {
          _events.add(MdnsPeerLost(event.service.name));
        }
      case MdnsPlatformLost():
        if (_visibleServices.remove(event.serviceName)) {
          _events.add(MdnsPeerLost(event.serviceName));
        }
      case MdnsPlatformIssue():
        _events.add(MdnsDiscoveryIssue(event.code));
    }
  }

  Future<void> stop() async {
    final Future<void>? inFlight = _startAttempt;
    if (inFlight != null) await inFlight;
    final StreamSubscription<MdnsPlatformEvent>? subscription = _subscription;
    final MdnsPlatformSession? session = _session;
    _subscription = null;
    _session = null;
    _localInstanceId = null;
    _visibleServices.clear();
    await subscription?.cancel();
    await session?.stop();
  }
}

class BonsoirMdnsPlatformAdapter implements MdnsPlatformAdapter {
  @override
  Future<MdnsPlatformSession> start(MdnsPublication publication) async {
    final BonsoirBroadcast broadcast = BonsoirBroadcast(
      printLogs: false,
      service: BonsoirService(
        name: publication.serviceName,
        type: nearSendMdnsServiceType,
        port: publication.port,
        attributes: publication.attributes,
      ),
    );
    final BonsoirDiscovery discovery = BonsoirDiscovery(
      printLogs: false,
      type: nearSendMdnsServiceType,
    );
    final _BonsoirMdnsPlatformSession session = _BonsoirMdnsPlatformSession(
      broadcast: broadcast,
      discovery: discovery,
    );
    await session.start();
    return session;
  }
}

class _BonsoirMdnsPlatformSession implements MdnsPlatformSession {
  _BonsoirMdnsPlatformSession({
    required this.broadcast,
    required this.discovery,
  });

  final BonsoirBroadcast broadcast;
  final BonsoirDiscovery discovery;
  final StreamController<MdnsPlatformEvent> _events =
      StreamController<MdnsPlatformEvent>();
  final Set<String> _knownServices = <String>{};

  StreamSubscription<BonsoirDiscoveryEvent>? _subscription;
  bool _stopped = false;

  @override
  Stream<MdnsPlatformEvent> get events => _events.stream;

  Future<void> start() async {
    try {
      await broadcast.initialize();
      await discovery.initialize();
      _subscription = discovery.eventStream!.listen(
        _handle,
        onError: (Object _) =>
            _add(const MdnsPlatformIssue('mdns.platformEventFailed')),
      );
      await broadcast.start();
      await discovery.start();
    } on Object {
      await stop();
      rethrow;
    }
  }

  void _handle(BonsoirDiscoveryEvent event) {
    switch (event) {
      case BonsoirDiscoveryServiceFoundEvent():
        _knownServices.add(event.service.name);
        unawaited(_resolve(event.service));
      case BonsoirDiscoveryServiceResolvedEvent():
        if (_knownServices.contains(event.service.name)) {
          _add(MdnsPlatformUpsert(_wire(event.service)));
        }
      case BonsoirDiscoveryServiceUpdatedEvent():
        _knownServices.add(event.service.name);
        if (event.service.hostAddresses.isEmpty) {
          unawaited(_resolve(event.service));
        } else {
          _add(MdnsPlatformUpsert(_wire(event.service)));
        }
      case BonsoirDiscoveryServiceResolveFailedEvent():
        _add(const MdnsPlatformIssue('mdns.resolveFailed'));
      case BonsoirDiscoveryServiceLostEvent():
        _knownServices.remove(event.service.name);
        _add(MdnsPlatformLost(event.service.name));
      case BonsoirDiscoveryStartedEvent() ||
          BonsoirDiscoveryStoppedEvent() ||
          BonsoirDiscoveryUnknownEvent():
        break;
    }
  }

  Future<void> _resolve(BonsoirService service) async {
    try {
      await service.resolve(discovery.serviceResolver);
    } on Object {
      _add(const MdnsPlatformIssue('mdns.resolveFailed'));
    }
  }

  MdnsWireService _wire(BonsoirService service) => MdnsWireService(
    name: service.name,
    port: service.port,
    hostAddresses: service.hostAddresses,
    attributes: service.attributes,
  );

  void _add(MdnsPlatformEvent event) {
    if (!_stopped) _events.add(event);
  }

  @override
  Future<void> stop() async {
    if (_stopped) return;
    _stopped = true;
    await _subscription?.cancel();
    try {
      if (!discovery.isStopped && discovery.isReady) await discovery.stop();
    } on Object {
      // Continue to withdraw the broadcast even if browsing teardown failed.
    }
    try {
      if (!broadcast.isStopped && broadcast.isReady) await broadcast.stop();
    } on Object {
      // Both platform resources have now received their best-effort stop request.
    }
    await _events.close();
  }
}
