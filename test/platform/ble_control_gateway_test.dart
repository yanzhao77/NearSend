import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:nearsend/core/network/ble_control_frame.dart';
import 'package:nearsend/platform/ble_control_gateway.dart';

void main() {
  const String localId = '11111111-1111-4111-8111-111111111111';

  test('advertisement is fixed-size, non-secret and strictly decoded', () {
    final BlePublication publication = BlePublication.fromInstanceId(localId);
    final Uint8List encoded = publication.advertisement.encode();
    final BleAdvertisement? decoded = BleAdvertisement.tryDecode(encoded);

    expect(encoded, hasLength(BleAdvertisement.encodedBytes));
    expect(decoded, isNotNull);
    expect(decoded!.protocolMajor, 1);
    expect(decoded.isProtocolCompatible, isTrue);
    expect(decoded.instanceTag, publication.instanceTag);
    expect(encoded.toString(), isNot(contains('token')));
    expect(
      BleAdvertisement.tryDecode(Uint8List.fromList(<int>[...encoded, 0])),
      isNull,
    );
    final Uint8List badFlags = Uint8List.fromList(encoded)..[3] = 1;
    expect(BleAdvertisement.tryDecode(badFlags), isNull);
  });

  test(
    'gateway suppresses self candidates and reassembles inbound frames',
    () async {
      final _FakeBleAdapter adapter = _FakeBleAdapter();
      final BleControlGateway gateway = BleControlGateway(adapter: adapter);
      final BlePublication publication = BlePublication.fromInstanceId(localId);
      final List<BleControlEvent> events = <BleControlEvent>[];
      final StreamSubscription<BleControlEvent> subscription = gateway.events
          .listen(events.add);

      await gateway.start(publication);
      adapter.session.add(
        BlePlatformPeerDiscovered(
          peerId: 'self',
          advertisement: publication.advertisement,
          rssi: -30,
        ),
      );
      final BleAdvertisement remote = BleAdvertisement(
        protocolMajor: 1,
        protocolMinor: 0,
        instanceTag: Uint8List.fromList(<int>[2, 2, 2, 2, 2, 2]),
      );
      adapter.session.add(
        BlePlatformPeerDiscovered(
          peerId: 'peer-a',
          advertisement: remote,
          rssi: -55,
        ),
      );
      adapter.session.add(const BlePlatformPeerConnected('peer-a'));
      final List<Uint8List> frames = fragmentBleControlMessage(
        BleControlMessage(
          type: BleControlMessageType.bootstrap,
          sessionTag: 2,
          sequence: 0,
          payload: Uint8List.fromList(List<int>.generate(40, (int i) => i)),
        ),
        maximumFrameBytes: 20,
      );
      for (final Uint8List frame in frames) {
        adapter.session.add(BlePlatformFrameReceived('peer-a', frame));
      }
      await pumpEventQueue();

      expect(events.whereType<BlePeerDiscovered>(), hasLength(1));
      expect(events.whereType<BlePeerConnected>(), hasLength(1));
      final BleMessageReceived message = events
          .whereType<BleMessageReceived>()
          .single;
      expect(message.peerId, 'peer-a');
      expect(message.message.payload, hasLength(40));

      await gateway.stop();
      await subscription.cancel();
      expect(adapter.session.stops, 1);
    },
  );

  test(
    'gateway fragments outbound messages and increments sequence after send',
    () async {
      final _FakeBleAdapter adapter = _FakeBleAdapter(maximumFrameBytes: 20);
      final BleControlGateway gateway = BleControlGateway(adapter: adapter);
      await gateway.start(BlePublication.fromInstanceId(localId));

      await gateway.send(
        'peer-a',
        type: BleControlMessageType.control,
        payload: Uint8List(9),
      );
      await gateway.send(
        'peer-a',
        type: BleControlMessageType.acknowledgment,
        payload: Uint8List.fromList(<int>[1]),
      );

      expect(adapter.session.sentFrames, hasLength(4));
      expect(
        BleControlFrame.decode(adapter.session.sentFrames.first).sequence,
        0,
      );
      expect(
        BleControlFrame.decode(adapter.session.sentFrames.last).sequence,
        1,
      );
      await gateway.stop();
    },
  );

  test(
    'gateway reports malformed peer data without closing the session',
    () async {
      final _FakeBleAdapter adapter = _FakeBleAdapter();
      final BleControlGateway gateway = BleControlGateway(adapter: adapter);
      final List<BleControlEvent> events = <BleControlEvent>[];
      final StreamSubscription<BleControlEvent> subscription = gateway.events
          .listen(events.add);
      await gateway.start(BlePublication.fromInstanceId(localId));

      adapter.session.add(
        BlePlatformFrameReceived('peer-a', Uint8List.fromList(<int>[1, 2, 3])),
      );
      await pumpEventQueue();

      expect(events.whereType<BleControlIssue>(), hasLength(1));
      expect(gateway.isRunning, isTrue);
      await gateway.stop();
      await subscription.cancel();
    },
  );

  test(
    'concurrent sends are serialized per peer without interleaved fragments',
    () async {
      final _FakeBleAdapter adapter = _FakeBleAdapter(
        maximumFrameBytes: 20,
        sendDelay: const Duration(milliseconds: 1),
      );
      final BleControlGateway gateway = BleControlGateway(adapter: adapter);
      await gateway.start(BlePublication.fromInstanceId(localId));

      await Future.wait(<Future<void>>[
        gateway.send(
          'peer-a',
          type: BleControlMessageType.control,
          payload: Uint8List(9),
        ),
        gateway.send(
          'peer-a',
          type: BleControlMessageType.acknowledgment,
          payload: Uint8List(9),
        ),
      ]);

      expect(
        adapter.session.sentFrames.map(
          (Uint8List frame) => BleControlFrame.decode(frame).sequence,
        ),
        <int>[0, 0, 0, 1, 1, 1],
      );
      await gateway.stop();
    },
  );

  test(
    'concurrent start shares one platform session and stop is idempotent',
    () async {
      final _FakeBleAdapter adapter = _FakeBleAdapter(delayStart: true);
      final BleControlGateway gateway = BleControlGateway(adapter: adapter);
      final BlePublication publication = BlePublication.fromInstanceId(localId);

      final Future<void> first = gateway.start(publication);
      final Future<void> second = gateway.start(publication);
      adapter.completeStart();
      await Future.wait(<Future<void>>[first, second]);
      expect(adapter.starts, 1);

      await gateway.stop();
      await gateway.stop();
      expect(adapter.session.stops, 1);
    },
  );
}

class _FakeBleAdapter implements BlePlatformAdapter {
  _FakeBleAdapter({
    this.delayStart = false,
    int maximumFrameBytes = 20,
    Duration sendDelay = Duration.zero,
  }) : session = _FakeBleSession(maximumFrameBytes, sendDelay);

  final bool delayStart;
  final _FakeBleSession session;
  final Completer<void> _startCompleter = Completer<void>();
  int starts = 0;

  @override
  Future<bool> requestAuthorization() async => true;

  @override
  Future<BlePlatformSession> start(BlePublication publication) async {
    starts++;
    if (delayStart) await _startCompleter.future;
    return session;
  }

  void completeStart() => _startCompleter.complete();
}

class _FakeBleSession implements BlePlatformSession {
  _FakeBleSession(this.frameBytes, this.sendDelay);

  final int frameBytes;
  final Duration sendDelay;
  final StreamController<BlePlatformEvent> _events =
      StreamController<BlePlatformEvent>.broadcast();
  final List<Uint8List> sentFrames = <Uint8List>[];
  int stops = 0;

  @override
  Stream<BlePlatformEvent> get events => _events.stream;

  void add(BlePlatformEvent event) => _events.add(event);

  @override
  Future<void> connect(String peerId) async {}

  @override
  Future<int> maximumFrameBytes(String peerId) async => frameBytes;

  @override
  Future<void> sendFrame(String peerId, Uint8List frame) async {
    if (sendDelay != Duration.zero) await Future<void>.delayed(sendDelay);
    sentFrames.add(Uint8List.fromList(frame));
  }

  @override
  Future<void> stop() async {
    stops++;
  }
}
