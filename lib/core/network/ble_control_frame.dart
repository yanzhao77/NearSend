import 'dart:typed_data';

/// BLE is only a bounded bootstrap/control transport. File bytes never use it.
const int bleControlMaxMessageBytes = 16 * 1024;
const int bleControlMaxFrameBytes = 512;
const int bleControlFrameHeaderBytes = 16;
const int bleControlMaxActivePeers = 16;
const Duration bleControlAssemblyTimeout = Duration(seconds: 15);

enum BleControlMessageType {
  bootstrap(1),
  bootstrapResponse(2),
  control(3),
  acknowledgment(4),
  abort(5);

  const BleControlMessageType(this.wireValue);

  final int wireValue;

  static BleControlMessageType? fromWire(int value) {
    for (final BleControlMessageType type in values) {
      if (type.wireValue == value) return type;
    }
    return null;
  }
}

enum BleControlProtocolError {
  malformedFrame,
  unsupportedVersion,
  unsupportedType,
  invalidLength,
  invalidFragment,
  unexpectedFragment,
  replayedSequence,
  assemblyExpired,
}

class BleControlProtocolException implements Exception {
  const BleControlProtocolException(this.code);

  final BleControlProtocolError code;

  @override
  String toString() => 'BleControlProtocolException(${code.name})';
}

class BleControlMessage {
  BleControlMessage({
    required this.type,
    required this.sessionTag,
    required this.sequence,
    required Uint8List payload,
  }) : payload = Uint8List.fromList(payload) {
    if (sessionTag < 0 || sessionTag > 0xffffffff) {
      throw ArgumentError.value(sessionTag, 'sessionTag');
    }
    if (sequence < 0 || sequence > 0xffff) {
      throw ArgumentError.value(sequence, 'sequence');
    }
    if (payload.isEmpty || payload.length > bleControlMaxMessageBytes) {
      throw ArgumentError.value(payload.length, 'payload.length');
    }
  }

  final BleControlMessageType type;
  final int sessionTag;
  final int sequence;
  final Uint8List payload;
}

class BleControlFrame {
  BleControlFrame({
    required this.type,
    required this.sessionTag,
    required this.sequence,
    required this.totalLength,
    required this.fragmentIndex,
    required this.fragmentCount,
    required Uint8List payload,
  }) : payload = Uint8List.fromList(payload);

  static const int _magic = 0x4e;
  static const int _version = 1;

  final BleControlMessageType type;
  final int sessionTag;
  final int sequence;
  final int totalLength;
  final int fragmentIndex;
  final int fragmentCount;
  final Uint8List payload;

  Uint8List encode() {
    _validate();
    final Uint8List bytes = Uint8List(
      bleControlFrameHeaderBytes + payload.length,
    );
    final ByteData data = ByteData.sublistView(bytes);
    data.setUint8(0, _magic);
    data.setUint8(1, (_version << 4) | type.wireValue);
    data.setUint32(2, sessionTag, Endian.big);
    data.setUint16(6, sequence, Endian.big);
    data.setUint16(8, totalLength, Endian.big);
    data.setUint16(10, fragmentIndex, Endian.big);
    data.setUint16(12, fragmentCount, Endian.big);
    data.setUint16(14, payload.length, Endian.big);
    bytes.setRange(bleControlFrameHeaderBytes, bytes.length, payload);
    return bytes;
  }

  static BleControlFrame decode(Uint8List bytes) {
    if (bytes.length < bleControlFrameHeaderBytes ||
        bytes.length > bleControlMaxFrameBytes) {
      throw const BleControlProtocolException(
        BleControlProtocolError.malformedFrame,
      );
    }
    final ByteData data = ByteData.sublistView(bytes);
    if (data.getUint8(0) != _magic) {
      throw const BleControlProtocolException(
        BleControlProtocolError.malformedFrame,
      );
    }
    final int versionAndType = data.getUint8(1);
    if (versionAndType >> 4 != _version) {
      throw const BleControlProtocolException(
        BleControlProtocolError.unsupportedVersion,
      );
    }
    final BleControlMessageType? type = BleControlMessageType.fromWire(
      versionAndType & 0x0f,
    );
    if (type == null) {
      throw const BleControlProtocolException(
        BleControlProtocolError.unsupportedType,
      );
    }
    final int payloadLength = data.getUint16(14, Endian.big);
    if (payloadLength != bytes.length - bleControlFrameHeaderBytes) {
      throw const BleControlProtocolException(
        BleControlProtocolError.invalidLength,
      );
    }
    final BleControlFrame frame = BleControlFrame(
      type: type,
      sessionTag: data.getUint32(2, Endian.big),
      sequence: data.getUint16(6, Endian.big),
      totalLength: data.getUint16(8, Endian.big),
      fragmentIndex: data.getUint16(10, Endian.big),
      fragmentCount: data.getUint16(12, Endian.big),
      payload: Uint8List.sublistView(bytes, bleControlFrameHeaderBytes),
    );
    frame._validate();
    return frame;
  }

  void _validate() {
    if (sessionTag < 0 ||
        sessionTag > 0xffffffff ||
        sequence < 0 ||
        sequence > 0xffff ||
        totalLength < 1 ||
        totalLength > bleControlMaxMessageBytes) {
      throw const BleControlProtocolException(
        BleControlProtocolError.invalidLength,
      );
    }
    if (fragmentCount < 1 ||
        fragmentIndex < 0 ||
        fragmentIndex >= fragmentCount ||
        payload.isEmpty ||
        payload.length > totalLength ||
        bleControlFrameHeaderBytes + payload.length > bleControlMaxFrameBytes) {
      throw const BleControlProtocolException(
        BleControlProtocolError.invalidFragment,
      );
    }
  }
}

List<Uint8List> fragmentBleControlMessage(
  BleControlMessage message, {
  required int maximumFrameBytes,
}) {
  if (maximumFrameBytes <= bleControlFrameHeaderBytes ||
      maximumFrameBytes > bleControlMaxFrameBytes) {
    throw ArgumentError.value(maximumFrameBytes, 'maximumFrameBytes');
  }
  final int capacity = maximumFrameBytes - bleControlFrameHeaderBytes;
  final int count = (message.payload.length + capacity - 1) ~/ capacity;
  final List<Uint8List> frames = <Uint8List>[];
  for (int index = 0; index < count; index++) {
    final int start = index * capacity;
    final int end = (start + capacity).clamp(0, message.payload.length);
    frames.add(
      BleControlFrame(
        type: message.type,
        sessionTag: message.sessionTag,
        sequence: message.sequence,
        totalLength: message.payload.length,
        fragmentIndex: index,
        fragmentCount: count,
        payload: Uint8List.sublistView(message.payload, start, end),
      ).encode(),
    );
  }
  return frames;
}

class BleControlReassembler {
  BleControlReassembler({
    this.timeout = bleControlAssemblyTimeout,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final Duration timeout;
  final DateTime Function() _clock;
  final Map<String, _PeerAssemblyState> _peers = <String, _PeerAssemblyState>{};

  int get bufferedBytes => _peers.values.fold<int>(
    0,
    (int total, _PeerAssemblyState state) =>
        total + (state.assembly?.bytes.length ?? 0),
  );

  BleControlMessage? add(String peerId, Uint8List encodedFrame) {
    if (peerId.isEmpty || peerId.length > 128) {
      throw const BleControlProtocolException(
        BleControlProtocolError.malformedFrame,
      );
    }
    final BleControlFrame frame = BleControlFrame.decode(encodedFrame);
    final DateTime now = _clock();
    _expire(now);

    if (!_peers.containsKey(peerId) &&
        _peers.length >= bleControlMaxActivePeers) {
      throw const BleControlProtocolException(
        BleControlProtocolError.invalidFragment,
      );
    }
    _PeerAssemblyState state = _peers.putIfAbsent(
      peerId,
      _PeerAssemblyState.new,
    );
    if (state.sessionTag != frame.sessionTag) {
      state = _PeerAssemblyState(sessionTag: frame.sessionTag);
      _peers[peerId] = state;
    }
    if (frame.sequence <= state.lastCompletedSequence) {
      throw const BleControlProtocolException(
        BleControlProtocolError.replayedSequence,
      );
    }

    _Assembly? assembly = state.assembly;
    if (assembly == null) {
      if (frame.fragmentIndex != 0) {
        throw const BleControlProtocolException(
          BleControlProtocolError.unexpectedFragment,
        );
      }
      assembly = _Assembly.fromFrame(frame, now);
      state.assembly = assembly;
    } else if (frame.fragmentIndex == 0 && frame.sequence > assembly.sequence) {
      // A newer message explicitly abandons a partial message left by a
      // failed link write. Restarting the same sequence is still rejected.
      assembly = _Assembly.fromFrame(frame, now);
      state.assembly = assembly;
    } else if (!assembly.matches(frame) ||
        frame.fragmentIndex != assembly.nextFragmentIndex) {
      state.assembly = null;
      throw const BleControlProtocolException(
        BleControlProtocolError.unexpectedFragment,
      );
    }

    if (assembly.bytes.length + frame.payload.length > assembly.totalLength) {
      state.assembly = null;
      throw const BleControlProtocolException(
        BleControlProtocolError.invalidLength,
      );
    }
    assembly.bytes.add(frame.payload);
    assembly.nextFragmentIndex++;

    if (assembly.nextFragmentIndex != assembly.fragmentCount) return null;
    final Uint8List payload = assembly.bytes.takeBytes();
    state.assembly = null;
    if (payload.length != assembly.totalLength) {
      throw const BleControlProtocolException(
        BleControlProtocolError.invalidLength,
      );
    }
    state.lastCompletedSequence = frame.sequence;
    return BleControlMessage(
      type: frame.type,
      sessionTag: frame.sessionTag,
      sequence: frame.sequence,
      payload: payload,
    );
  }

  void removePeer(String peerId) => _peers.remove(peerId);

  void clear() => _peers.clear();

  void _expire(DateTime now) {
    bool expired = false;
    for (final _PeerAssemblyState state in _peers.values) {
      final _Assembly? assembly = state.assembly;
      if (assembly != null && now.difference(assembly.startedAt) > timeout) {
        state.assembly = null;
        expired = true;
      }
    }
    if (expired) {
      throw const BleControlProtocolException(
        BleControlProtocolError.assemblyExpired,
      );
    }
  }
}

class _PeerAssemblyState {
  _PeerAssemblyState({this.sessionTag});

  int? sessionTag;
  int lastCompletedSequence = -1;
  _Assembly? assembly;
}

class _Assembly {
  _Assembly({
    required this.type,
    required this.sessionTag,
    required this.sequence,
    required this.totalLength,
    required this.fragmentCount,
    required this.startedAt,
  });

  factory _Assembly.fromFrame(BleControlFrame frame, DateTime now) => _Assembly(
    type: frame.type,
    sessionTag: frame.sessionTag,
    sequence: frame.sequence,
    totalLength: frame.totalLength,
    fragmentCount: frame.fragmentCount,
    startedAt: now,
  );

  final BleControlMessageType type;
  final int sessionTag;
  final int sequence;
  final int totalLength;
  final int fragmentCount;
  final DateTime startedAt;
  final BytesBuilder bytes = BytesBuilder(copy: false);
  int nextFragmentIndex = 0;

  bool matches(BleControlFrame frame) =>
      type == frame.type &&
      sessionTag == frame.sessionTag &&
      sequence == frame.sequence &&
      totalLength == frame.totalLength &&
      fragmentCount == frame.fragmentCount;
}
