import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';

import 'package:nearsend/core/network/ble_control_frame.dart';
import 'package:nearsend/core/protocol/protocol_limits.dart';
import 'package:nearsend/core/protocol/protocol_validation.dart';

const String nearSendBleServiceUuid = '8ebd4f7a-7f6a-4a2c-9b42-f19d716cb001';
const String nearSendBleControlCharacteristicUuid =
    '8ebd4f7a-7f6a-4a2c-9b42-f19d716cb002';
const String bleDiscoveryCapability = 'discovery.ble.v1';

class BlePublication {
  BlePublication({required this.instanceId, required Uint8List instanceTag})
    : instanceTag = Uint8List.fromList(instanceTag) {
    uuidToBytes(instanceId, 'BLE instance id');
    if (instanceTag.length != BleAdvertisement.instanceTagBytes) {
      throw ArgumentError.value(instanceTag.length, 'instanceTag.length');
    }
  }

  factory BlePublication.fromInstanceId(String instanceId) {
    final Uint8List bytes = uuidToBytes(instanceId, 'BLE instance id');
    return BlePublication(
      instanceId: instanceId,
      instanceTag: Uint8List.sublistView(
        bytes,
        0,
        BleAdvertisement.instanceTagBytes,
      ),
    );
  }

  final String instanceId;
  final Uint8List instanceTag;

  int get controlSessionTag =>
      ByteData.sublistView(instanceTag).getUint32(0, Endian.big);

  BleAdvertisement get advertisement => BleAdvertisement(
    protocolMajor: ProtocolLimits.protocolMajor,
    protocolMinor: ProtocolLimits.protocolMinor,
    instanceTag: instanceTag,
  );
}

class BleAdvertisement {
  BleAdvertisement({
    required this.protocolMajor,
    required this.protocolMinor,
    required Uint8List instanceTag,
  }) : instanceTag = Uint8List.fromList(instanceTag) {
    if (protocolMajor < 0 ||
        protocolMajor > 255 ||
        protocolMinor < 0 ||
        protocolMinor > 255 ||
        instanceTag.length != instanceTagBytes) {
      throw ArgumentError('Invalid BLE advertisement metadata');
    }
  }

  static const int instanceTagBytes = 6;
  static const int encodedBytes = 10;
  static const int _formatVersion = 1;

  final int protocolMajor;
  final int protocolMinor;
  final Uint8List instanceTag;

  bool get isProtocolCompatible =>
      protocolMajor == ProtocolLimits.protocolMajor;

  Uint8List encode() => Uint8List.fromList(<int>[
    _formatVersion,
    protocolMajor,
    protocolMinor,
    0,
    ...instanceTag,
  ]);

  static BleAdvertisement? tryDecode(Uint8List bytes) {
    if (bytes.length != encodedBytes ||
        bytes[0] != _formatVersion ||
        bytes[3] != 0) {
      return null;
    }
    return BleAdvertisement(
      protocolMajor: bytes[1],
      protocolMinor: bytes[2],
      instanceTag: Uint8List.sublistView(bytes, 4),
    );
  }
}

sealed class BleControlEvent {
  const BleControlEvent();
}

class BlePeerDiscovered extends BleControlEvent {
  const BlePeerDiscovered({
    required this.peerId,
    required this.advertisement,
    required this.rssi,
  });

  final String peerId;
  final BleAdvertisement advertisement;
  final int rssi;
}

class BlePeerConnected extends BleControlEvent {
  const BlePeerConnected(this.peerId);

  final String peerId;
}

class BlePeerDisconnected extends BleControlEvent {
  const BlePeerDisconnected(this.peerId);

  final String peerId;
}

class BleMessageReceived extends BleControlEvent {
  const BleMessageReceived(this.peerId, this.message);

  final String peerId;
  final BleControlMessage message;
}

class BleControlIssue extends BleControlEvent {
  const BleControlIssue(this.code, {this.peerId});

  final String code;
  final String? peerId;
}

sealed class BlePlatformEvent {
  const BlePlatformEvent();
}

class BlePlatformPeerDiscovered extends BlePlatformEvent {
  const BlePlatformPeerDiscovered({
    required this.peerId,
    required this.advertisement,
    required this.rssi,
  });

  final String peerId;
  final BleAdvertisement advertisement;
  final int rssi;
}

class BlePlatformPeerConnected extends BlePlatformEvent {
  const BlePlatformPeerConnected(this.peerId);

  final String peerId;
}

class BlePlatformPeerDisconnected extends BlePlatformEvent {
  const BlePlatformPeerDisconnected(this.peerId);

  final String peerId;
}

class BlePlatformFrameReceived extends BlePlatformEvent {
  const BlePlatformFrameReceived(this.peerId, this.frame);

  final String peerId;
  final Uint8List frame;
}

class BlePlatformIssue extends BlePlatformEvent {
  const BlePlatformIssue(this.code, {this.peerId});

  final String code;
  final String? peerId;
}

abstract interface class BlePlatformSession {
  Stream<BlePlatformEvent> get events;

  Future<void> connect(String peerId);

  Future<int> maximumFrameBytes(String peerId);

  Future<void> sendFrame(String peerId, Uint8List frame);

  Future<void> stop();
}

abstract interface class BlePlatformAdapter {
  Future<bool> requestAuthorization();

  Future<BlePlatformSession> start(BlePublication publication);
}

class BleControlGateway {
  BleControlGateway({BlePlatformAdapter? adapter})
    : _adapter = adapter ?? BluetoothLowEnergyPlatformAdapter();

  final BlePlatformAdapter _adapter;
  final StreamController<BleControlEvent> _events =
      StreamController<BleControlEvent>.broadcast();
  final BleControlReassembler _reassembler = BleControlReassembler();
  final Map<String, int> _nextSequences = <String, int>{};
  final Map<String, Future<void>> _sendTails = <String, Future<void>>{};

  BlePlatformSession? _session;
  StreamSubscription<BlePlatformEvent>? _subscription;
  Future<void>? _startAttempt;
  BlePublication? _publication;

  Stream<BleControlEvent> get events => _events.stream;

  bool get isRunning => _session != null;

  Future<bool> requestAuthorization() => _adapter.requestAuthorization();

  Future<void> start(BlePublication publication) {
    if (_session != null) return Future<void>.value();
    final Future<void>? pending = _startAttempt;
    if (pending != null) return pending;
    final Future<void> attempt = _start(publication);
    _startAttempt = attempt;
    return attempt;
  }

  Future<void> _start(BlePublication publication) async {
    try {
      final BlePlatformSession session = await _adapter.start(publication);
      _publication = publication;
      _session = session;
      _subscription = session.events.listen(
        _handlePlatformEvent,
        onError: (Object _) =>
            _events.add(const BleControlIssue('ble.eventStreamFailed')),
      );
    } finally {
      _startAttempt = null;
    }
  }

  Future<void> connect(String peerId) async {
    final BlePlatformSession? session = _session;
    if (session == null) throw StateError('BLE control gateway is not running');
    await session.connect(peerId);
  }

  Future<void> send(
    String peerId, {
    required BleControlMessageType type,
    required Uint8List payload,
  }) {
    final Future<void> previous = _sendTails[peerId] ?? Future<void>.value();
    late final Future<void> current;
    current = () async {
      try {
        await previous;
      } on Object {
        // A failed message consumes its sequence. A newer message can replace
        // the peer's bounded partial assembly without mixing fragments.
      }
      await _sendNow(peerId, type: type, payload: payload);
    }();
    _sendTails[peerId] = current;
    return current.whenComplete(() {
      if (identical(_sendTails[peerId], current)) {
        _sendTails.remove(peerId);
      }
    });
  }

  Future<void> _sendNow(
    String peerId, {
    required BleControlMessageType type,
    required Uint8List payload,
  }) async {
    final BlePlatformSession? session = _session;
    final BlePublication? publication = _publication;
    if (session == null || publication == null) {
      throw StateError('BLE control gateway is not running');
    }
    final int sequence = _nextSequences[peerId] ?? 0;
    if (sequence > 0xffff) {
      throw StateError('BLE control sequence exhausted; reconnect required');
    }
    _nextSequences[peerId] = sequence + 1;
    final BleControlMessage message = BleControlMessage(
      type: type,
      sessionTag: publication.controlSessionTag,
      sequence: sequence,
      payload: payload,
    );
    final int maximumFrameBytes = await session.maximumFrameBytes(peerId);
    final List<Uint8List> frames = fragmentBleControlMessage(
      message,
      maximumFrameBytes: maximumFrameBytes.clamp(
        bleControlFrameHeaderBytes + 1,
        bleControlMaxFrameBytes,
      ),
    );
    for (final Uint8List frame in frames) {
      await session.sendFrame(peerId, frame);
    }
  }

  void _handlePlatformEvent(BlePlatformEvent event) {
    switch (event) {
      case BlePlatformPeerDiscovered():
        final BlePublication? publication = _publication;
        if (publication != null &&
            !_sameBytes(
              event.advertisement.instanceTag,
              publication.instanceTag,
            )) {
          _events.add(
            BlePeerDiscovered(
              peerId: event.peerId,
              advertisement: event.advertisement,
              rssi: event.rssi,
            ),
          );
        }
      case BlePlatformPeerConnected():
        _events.add(BlePeerConnected(event.peerId));
      case BlePlatformPeerDisconnected():
        _reassembler.removePeer(event.peerId);
        _nextSequences.remove(event.peerId);
        _events.add(BlePeerDisconnected(event.peerId));
      case BlePlatformFrameReceived():
        try {
          final BleControlMessage? message = _reassembler.add(
            event.peerId,
            event.frame,
          );
          if (message != null) {
            _events.add(BleMessageReceived(event.peerId, message));
          }
        } on BleControlProtocolException catch (error) {
          _events.add(
            BleControlIssue(
              'ble.protocol.${error.code.name}',
              peerId: event.peerId,
            ),
          );
        }
      case BlePlatformIssue():
        _events.add(BleControlIssue(event.code, peerId: event.peerId));
    }
  }

  Future<void> stop() async {
    final Future<void>? pending = _startAttempt;
    if (pending != null) await pending;
    final BlePlatformSession? session = _session;
    _session = null;
    _publication = null;
    await _subscription?.cancel();
    _subscription = null;
    _reassembler.clear();
    _nextSequences.clear();
    _sendTails.clear();
    if (session != null) await session.stop();
  }

  static bool _sameBytes(Uint8List first, Uint8List second) {
    if (first.length != second.length) return false;
    for (int index = 0; index < first.length; index++) {
      if (first[index] != second[index]) return false;
    }
    return true;
  }
}

class BlePlatformFailure implements Exception {
  const BlePlatformFailure(this.code);

  final String code;

  @override
  String toString() => 'BlePlatformFailure($code)';
}

class BluetoothLowEnergyPlatformAdapter implements BlePlatformAdapter {
  BluetoothLowEnergyPlatformAdapter({
    CentralManager? centralManager,
    PeripheralManager? peripheralManager,
  }) : _centralManager = centralManager ?? CentralManager(),
       _peripheralManager = peripheralManager ?? PeripheralManager();

  final CentralManager _centralManager;
  final PeripheralManager _peripheralManager;

  @override
  Future<bool> requestAuthorization() async {
    if (!Platform.isAndroid) return true;
    final bool central = await _centralManager.authorize();
    final bool peripheral = await _peripheralManager.authorize();
    return central && peripheral;
  }

  @override
  Future<BlePlatformSession> start(BlePublication publication) async {
    if (!Platform.isAndroid && !Platform.isWindows) {
      throw const BlePlatformFailure('ble.platformUnsupported');
    }
    if (_centralManager.state != BluetoothLowEnergyState.poweredOn ||
        _peripheralManager.state != BluetoothLowEnergyState.poweredOn) {
      throw BlePlatformFailure(
        _centralManager.state == BluetoothLowEnergyState.unauthorized ||
                _peripheralManager.state == BluetoothLowEnergyState.unauthorized
            ? 'ble.unauthorized'
            : 'ble.unavailable',
      );
    }
    return _BluetoothLowEnergyPlatformSession.start(
      centralManager: _centralManager,
      peripheralManager: _peripheralManager,
      publication: publication,
    );
  }
}

class _BluetoothLowEnergyPlatformSession implements BlePlatformSession {
  _BluetoothLowEnergyPlatformSession(
    this._centralManager,
    this._peripheralManager,
    this._publication,
  );

  static final UUID _serviceUuid = UUID.fromString(nearSendBleServiceUuid);
  static final UUID _characteristicUuid = UUID.fromString(
    nearSendBleControlCharacteristicUuid,
  );

  final CentralManager _centralManager;
  final PeripheralManager _peripheralManager;
  final BlePublication _publication;
  final StreamController<BlePlatformEvent> _events =
      StreamController<BlePlatformEvent>.broadcast();
  final List<StreamSubscription<Object?>> _subscriptions =
      <StreamSubscription<Object?>>[];
  final Map<String, Peripheral> _discovered = <String, Peripheral>{};
  final Map<String, _ConnectedPeripheral> _connectedPeripherals =
      <String, _ConnectedPeripheral>{};
  final Map<String, Central> _subscribedCentrals = <String, Central>{};
  final Set<String> _connectedPeerIds = <String>{};

  late final GATTCharacteristic _localCharacteristic;
  late final GATTService _localService;
  bool _stopped = false;

  static Future<_BluetoothLowEnergyPlatformSession> start({
    required CentralManager centralManager,
    required PeripheralManager peripheralManager,
    required BlePublication publication,
  }) async {
    final _BluetoothLowEnergyPlatformSession session =
        _BluetoothLowEnergyPlatformSession(
          centralManager,
          peripheralManager,
          publication,
        );
    try {
      await session._start();
      return session;
    } on Object {
      await session.stop();
      rethrow;
    }
  }

  @override
  Stream<BlePlatformEvent> get events => _events.stream;

  Future<void> _start() async {
    _localCharacteristic = GATTCharacteristic.mutable(
      uuid: _characteristicUuid,
      properties: const <GATTCharacteristicProperty>[
        GATTCharacteristicProperty.write,
        GATTCharacteristicProperty.notify,
        GATTCharacteristicProperty.indicate,
      ],
      permissions: const <GATTCharacteristicPermission>[
        GATTCharacteristicPermission.write,
      ],
      descriptors: const <GATTDescriptor>[],
    );
    _localService = GATTService(
      uuid: _serviceUuid,
      isPrimary: true,
      includedServices: const <GATTService>[],
      characteristics: <GATTCharacteristic>[_localCharacteristic],
    );

    _subscriptions.add(_centralManager.discovered.listen(_onDiscovered));
    _subscriptions.add(
      _centralManager.characteristicNotified.listen(_onNotified),
    );
    _subscriptions.add(
      _centralManager.connectionStateChanged.listen((event) {
        if (event.state == ConnectionState.disconnected) {
          _removePeer(_peerId(event.peripheral));
        }
      }),
    );
    _subscriptions.add(
      _peripheralManager.characteristicWriteRequested.listen(_onWriteRequested),
    );
    _subscriptions.add(
      _peripheralManager.characteristicNotifyStateChanged.listen(
        _onNotifyStateChanged,
      ),
    );
    if (Platform.isAndroid) {
      _subscriptions.add(
        _peripheralManager.connectionStateChanged.listen((event) {
          if (event.state == ConnectionState.disconnected) {
            _removePeer(_peerId(event.central));
          }
        }),
      );
    }

    await _peripheralManager.removeAllServices();
    await _peripheralManager.addService(_localService);
    await _peripheralManager.startAdvertising(
      Advertisement(
        serviceData: <UUID, Uint8List>{
          _serviceUuid: _publication.advertisement.encode(),
        },
      ),
    );
    // Service-data advertisements carry the UUID but are not consistently
    // returned by platform UUID filters, so parsing remains strict client-side.
    await _centralManager.startDiscovery();
  }

  void _onDiscovered(DiscoveredEventArgs event) {
    Uint8List? bytes;
    try {
      bytes = event.advertisement.serviceData[_serviceUuid];
    } on UnsupportedError {
      return;
    }
    if (bytes == null) return;
    final BleAdvertisement? advertisement = BleAdvertisement.tryDecode(bytes);
    if (advertisement == null) return;
    final String peerId = _peerId(event.peripheral);
    _discovered[peerId] = event.peripheral;
    _events.add(
      BlePlatformPeerDiscovered(
        peerId: peerId,
        advertisement: advertisement,
        rssi: event.rssi,
      ),
    );
  }

  @override
  Future<void> connect(String peerId) async {
    if (_stopped) throw StateError('BLE session is stopped');
    if (_connectedPeripherals.containsKey(peerId)) return;
    final Peripheral? peripheral = _discovered[peerId];
    if (peripheral == null) {
      throw const BlePlatformFailure('ble.peerNotDiscovered');
    }
    await _centralManager.connect(peripheral);
    try {
      final List<GATTService> services = await _centralManager.discoverGATT(
        peripheral,
      );
      final GATTService service = services.singleWhere(
        (GATTService value) => value.uuid == _serviceUuid,
      );
      final GATTCharacteristic characteristic = service.characteristics
          .singleWhere(
            (GATTCharacteristic value) => value.uuid == _characteristicUuid,
          );
      if (!characteristic.properties.contains(
            GATTCharacteristicProperty.write,
          ) ||
          !(characteristic.properties.contains(
                GATTCharacteristicProperty.notify,
              ) ||
              characteristic.properties.contains(
                GATTCharacteristicProperty.indicate,
              ))) {
        throw const BlePlatformFailure('ble.incompatibleGatt');
      }
      await _centralManager.setCharacteristicNotifyState(
        peripheral,
        characteristic,
        state: true,
      );
      _connectedPeripherals[peerId] = _ConnectedPeripheral(
        peripheral,
        characteristic,
      );
      _announceConnected(peerId);
    } on Object {
      await _centralManager.disconnect(peripheral);
      rethrow;
    }
  }

  Future<void> _onWriteRequested(
    GATTCharacteristicWriteRequestedEventArgs event,
  ) async {
    final String peerId = _peerId(event.central);
    if (event.characteristic.uuid != _characteristicUuid ||
        event.request.offset != 0 ||
        event.request.value.isEmpty ||
        event.request.value.length > bleControlMaxFrameBytes) {
      await _peripheralManager.respondWriteRequestWithError(
        event.request,
        error: event.request.offset != 0
            ? GATTError.invalidOffset
            : GATTError.invalidAttributeValueLength,
      );
      return;
    }
    await _peripheralManager.respondWriteRequest(event.request);
    _announceConnected(peerId);
    _events.add(
      BlePlatformFrameReceived(peerId, Uint8List.fromList(event.request.value)),
    );
  }

  void _onNotified(GATTCharacteristicNotifiedEventArgs event) {
    if (event.characteristic.uuid != _characteristicUuid ||
        event.value.isEmpty ||
        event.value.length > bleControlMaxFrameBytes) {
      return;
    }
    _events.add(
      BlePlatformFrameReceived(
        _peerId(event.peripheral),
        Uint8List.fromList(event.value),
      ),
    );
  }

  void _onNotifyStateChanged(
    GATTCharacteristicNotifyStateChangedEventArgs event,
  ) {
    final String peerId = _peerId(event.central);
    if (event.characteristic.uuid != _characteristicUuid) return;
    if (event.state) {
      _subscribedCentrals[peerId] = event.central;
      _announceConnected(peerId);
    } else {
      _subscribedCentrals.remove(peerId);
      _removePeer(peerId);
    }
  }

  @override
  Future<int> maximumFrameBytes(String peerId) async {
    final _ConnectedPeripheral? peripheral = _connectedPeripherals[peerId];
    if (peripheral != null) {
      return _centralManager.getMaximumWriteLength(
        peripheral.peripheral,
        type: GATTCharacteristicWriteType.withResponse,
      );
    }
    final Central? central = _subscribedCentrals[peerId];
    if (central != null) {
      return _peripheralManager.getMaximumNotifyLength(central);
    }
    throw const BlePlatformFailure('ble.peerNotConnected');
  }

  @override
  Future<void> sendFrame(String peerId, Uint8List frame) async {
    if (frame.length <= bleControlFrameHeaderBytes ||
        frame.length > bleControlMaxFrameBytes) {
      throw ArgumentError.value(frame.length, 'frame.length');
    }
    final _ConnectedPeripheral? peripheral = _connectedPeripherals[peerId];
    if (peripheral != null) {
      await _centralManager.writeCharacteristic(
        peripheral.peripheral,
        peripheral.characteristic,
        value: frame,
        type: GATTCharacteristicWriteType.withResponse,
      );
      return;
    }
    final Central? central = _subscribedCentrals[peerId];
    if (central != null) {
      await _peripheralManager.notifyCharacteristic(
        central,
        _localCharacteristic,
        value: frame,
      );
      return;
    }
    throw const BlePlatformFailure('ble.peerNotConnected');
  }

  void _announceConnected(String peerId) {
    if (_connectedPeerIds.add(peerId)) {
      _events.add(BlePlatformPeerConnected(peerId));
    }
  }

  void _removePeer(String peerId) {
    _connectedPeripherals.remove(peerId);
    _subscribedCentrals.remove(peerId);
    if (_connectedPeerIds.remove(peerId)) {
      _events.add(BlePlatformPeerDisconnected(peerId));
    }
  }

  @override
  Future<void> stop() async {
    if (_stopped) return;
    _stopped = true;
    try {
      await _centralManager.stopDiscovery();
    } on Object {
      // Continue releasing the remaining radio and GATT resources.
    }
    try {
      await _peripheralManager.stopAdvertising();
    } on Object {
      // Continue releasing the remaining radio and GATT resources.
    }
    for (final _ConnectedPeripheral peer
        in _connectedPeripherals.values.toList()) {
      try {
        await _centralManager.disconnect(peer.peripheral);
      } on Object {
        // Platform teardown is best effort after discovery has stopped.
      }
    }
    try {
      await _peripheralManager.removeAllServices();
    } on Object {
      // Subscriptions still must be cancelled if GATT cleanup fails.
    }
    for (final StreamSubscription<Object?> subscription
        in _subscriptions.reversed) {
      await subscription.cancel();
    }
    _subscriptions.clear();
    _discovered.clear();
    _connectedPeripherals.clear();
    _subscribedCentrals.clear();
    _connectedPeerIds.clear();
    await _events.close();
  }

  static String _peerId(BluetoothLowEnergyPeer peer) => peer.uuid.toString();
}

class _ConnectedPeripheral {
  const _ConnectedPeripheral(this.peripheral, this.characteristic);

  final Peripheral peripheral;
  final GATTCharacteristic characteristic;
}
