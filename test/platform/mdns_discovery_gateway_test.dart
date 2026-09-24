import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:nearsend/platform/mdns_discovery_gateway.dart';

void main() {
  const String localId = '11111111-1111-4111-8111-111111111111';
  const String remoteId = '22222222-2222-4222-8222-222222222222';

  test('publication exposes only bounded non-secret discovery metadata', () {
    final MdnsPublication publication = MdnsPublication(
      instanceId: localId,
      port: 8443,
      deviceName: '书房电脑',
      platform: 'windows',
    );

    expect(publication.serviceName, 'NearSend-11111111');
    expect(publication.attributes.keys, <String>{
      'maj',
      'min',
      'iid',
      'caps',
      'dn',
      'pf',
    });
    expect(publication.attributes['iid'], localId);
    expect(publication.attributes['caps'], mdnsDiscoveryCapability);
    expect(publication.attributes['dn'], '书房电脑');
    expect(publication.attributes['pf'], 'windows');
    expect(publication.attributes.toString(), isNot(contains('token')));
    expect(publication.attributes.toString(), isNot(contains('fingerprint')));
  });

  test('resolved service parsing bounds and filters candidate addresses', () {
    final MdnsDiscoveredPeer? peer = MdnsDiscoveredPeer.tryParse(
      MdnsWireService(
        name: 'NearSend-peer',
        port: 9443,
        hostAddresses: const <String>[
          '127.0.0.1',
          '192.168.1.4',
          '192.168.1.4',
          'fe80::1234%en0',
          '224.0.0.251',
          'ff02::fb',
        ],
        attributes: const <String, String>{
          'maj': '1',
          'min': '0',
          'iid': remoteId,
          'caps': 'discovery.mdns.v1,transfer.https.v1',
          'dn': '客厅手机',
          'pf': 'android',
        },
      ),
    );

    expect(peer, isNotNull);
    expect(peer!.addresses, <String>['192.168.1.4', 'fe80::1234%en0']);
    expect(peer.capabilities, contains(mdnsDiscoveryCapability));
    expect(peer.displayName, '客厅手机');
    expect(peer.platform, 'android');
    expect(peer.isProtocolCompatible, isTrue);
  });

  test(
    'malformed untrusted TXT data is ignored rather than partially used',
    () {
      MdnsWireService service(Map<String, String> attributes) =>
          MdnsWireService(
            name: 'NearSend-peer',
            port: 9443,
            hostAddresses: const <String>['192.168.1.4'],
            attributes: attributes,
          );

      expect(
        MdnsDiscoveredPeer.tryParse(
          service(const <String, String>{
            'maj': '01',
            'min': '0',
            'iid': remoteId,
          }),
        ),
        isNull,
      );
      expect(
        MdnsDiscoveredPeer.tryParse(
          service(const <String, String>{
            'maj': '1',
            'min': '0',
            'iid': remoteId,
            'caps': mdnsDiscoveryCapability,
            'dn': 'bad\nname',
            'pf': 'android',
          }),
        ),
        isNull,
      );
      expect(
        MdnsDiscoveredPeer.tryParse(
          service(const <String, String>{
            'maj': '1',
            'min': '0',
            'iid': remoteId,
            'caps': 'transfer.https.v1',
          }),
        ),
        isNull,
      );
      expect(
        MdnsDiscoveredPeer.tryParse(
          service(const <String, String>{
            'maj': '1',
            'min': '0',
            'iid': 'not-a-uuid',
          }),
        ),
        isNull,
      );
      expect(
        MdnsDiscoveredPeer.tryParse(
          service(const <String, String>{
            'maj': '1',
            'min': '0',
            'iid': remoteId,
            'caps': 'valid,valid',
          }),
        ),
        isNull,
      );
    },
  );

  test(
    'gateway suppresses self discovery and withdraws platform resources',
    () async {
      final _FakeAdapter adapter = _FakeAdapter();
      final MdnsDiscoveryGateway gateway = MdnsDiscoveryGateway(
        adapter: adapter,
      );
      final List<MdnsDiscoveryEvent> events = <MdnsDiscoveryEvent>[];
      final StreamSubscription<MdnsDiscoveryEvent> subscription = gateway.events
          .listen(events.add);

      await gateway.start(MdnsPublication(instanceId: localId, port: 8443));
      adapter.session.add(_upsert(localId));
      adapter.session.add(_upsert(remoteId));
      adapter.session.add(const MdnsPlatformLost('NearSend-peer'));
      await pumpEventQueue();

      expect(adapter.starts, 1);
      expect(events, hasLength(2));
      expect((events.first as MdnsPeerUpserted).peer.instanceId, remoteId);
      expect((events.last as MdnsPeerLost).serviceName, 'NearSend-peer');

      await gateway.stop();
      await subscription.cancel();
      expect(adapter.session.stops, 1);
      expect(gateway.isRunning, isFalse);
    },
  );

  test('concurrent start calls share one platform session', () async {
    final _FakeAdapter adapter = _FakeAdapter(delayStart: true);
    final MdnsDiscoveryGateway gateway = MdnsDiscoveryGateway(adapter: adapter);
    final MdnsPublication publication = MdnsPublication(
      instanceId: localId,
      port: 8443,
    );

    final Future<void> first = gateway.start(publication);
    final Future<void> second = gateway.start(publication);
    adapter.completeStart();
    await Future.wait(<Future<void>>[first, second]);

    expect(adapter.starts, 1);
    await gateway.stop();
  });
}

MdnsPlatformUpsert _upsert(String instanceId) => MdnsPlatformUpsert(
  MdnsWireService(
    name: 'NearSend-peer',
    port: 9443,
    hostAddresses: const <String>['192.168.1.4'],
    attributes: <String, String>{
      'maj': '1',
      'min': '0',
      'iid': instanceId,
      'caps': mdnsDiscoveryCapability,
    },
  ),
);

class _FakeAdapter implements MdnsPlatformAdapter {
  _FakeAdapter({this.delayStart = false});

  final bool delayStart;
  final _FakeSession session = _FakeSession();
  final Completer<void> _startCompleter = Completer<void>();
  int starts = 0;

  @override
  Future<MdnsPlatformSession> start(MdnsPublication publication) async {
    starts++;
    if (delayStart) await _startCompleter.future;
    return session;
  }

  void completeStart() => _startCompleter.complete();
}

class _FakeSession implements MdnsPlatformSession {
  final StreamController<MdnsPlatformEvent> _events =
      StreamController<MdnsPlatformEvent>.broadcast();
  int stops = 0;

  @override
  Stream<MdnsPlatformEvent> get events => _events.stream;

  void add(MdnsPlatformEvent event) => _events.add(event);

  @override
  Future<void> stop() async {
    stops++;
  }
}
