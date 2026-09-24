import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nearsend/platform/platform_network_gateway.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const MethodChannel channel = MethodChannel(
    MethodChannelPlatformNetworkGateway.channelName,
  );

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test(
    'hotspot credentials remain in-memory and are redacted from text',
    () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) async {
            expect(call.method, 'startLocalOnlyHotspot');
            return <String, Object?>{
              'leaseId': 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
              'ssid': 'NearSend-1234',
              'passphrase': 'correct-horse',
              'security': 'wpa2',
            };
          });

      final LocalOnlyHotspotLease lease =
          await MethodChannelPlatformNetworkGateway().startLocalOnlyHotspot();

      expect(lease.ssid, 'NearSend-1234');
      expect(lease.passphrase, 'correct-horse');
      expect(lease.toString(), isNot(contains('NearSend-1234')));
      expect(lease.toString(), isNot(contains('correct-horse')));
    },
  );

  test('join sends credentials only to the platform call', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
          expect(call.method, 'joinWifi');
          expect(call.arguments, <String, Object?>{
            'ssid': 'NearSend-5678',
            'passphrase': 'eight-or-more',
            'security': 'wpa2',
          });
          return <String, Object?>{
            'leaseId': 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
            'networkHandle': 42,
          };
        });

    final JoinedWifiLease lease = await MethodChannelPlatformNetworkGateway()
        .joinWifi(
          ssid: 'NearSend-5678',
          passphrase: 'eight-or-more',
          security: WifiSecurity.wpa2,
        );

    expect(lease.networkHandle, 42);
    expect(lease.toString(), isNot(contains('NearSend-5678')));
  });

  test('platform failures are classified without echoing details', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
          throw PlatformException(
            code: 'NS-NETWORK-PERMISSION',
            message: 'secret should not escape',
          );
        });

    expect(
      MethodChannelPlatformNetworkGateway().startLocalOnlyHotspot(),
      throwsA(
        isA<NetworkBootstrapException>().having(
          (NetworkBootstrapException error) => error.failure,
          'failure',
          NetworkBootstrapFailure.permissionDenied,
        ),
      ),
    );
  });

  test(
    'selector prefers a verified existing endpoint in bounded order',
    () async {
      final List<String> attempted = <String>[];
      final NetworkPathDecision decision = await const NetworkPathSelector()
          .select(
            candidates: const <NetworkCandidate>[
              NetworkCandidate(host: '192.168.1.2', port: 8443),
              NetworkCandidate(host: '192.168.1.3', port: 8443),
            ],
            probe: (NetworkCandidate candidate) async {
              attempted.add(candidate.host);
              return candidate.host.endsWith('.3');
            },
            bootstrapSupported: true,
          );

      expect(decision.kind, NetworkPathKind.existingNetwork);
      expect(decision.candidate!.host, '192.168.1.3');
      expect(attempted, <String>['192.168.1.2', '192.168.1.3']);
    },
  );

  test('selector requests bootstrap only after probes fail', () async {
    final NetworkPathDecision decision = await const NetworkPathSelector()
        .select(
          candidates: const <NetworkCandidate>[
            NetworkCandidate(host: '192.168.1.2', port: 8443),
          ],
          probe: (_) async => false,
          bootstrapSupported: true,
        );

    expect(decision.kind, NetworkPathKind.bootstrapRequired);
  });

  test('selector bounds candidates and per-candidate time', () async {
    expect(
      const NetworkPathSelector().select(
        candidates: List<NetworkCandidate>.filled(
          networkCandidateLimit + 1,
          const NetworkCandidate(host: '192.168.1.2', port: 8443),
        ),
        probe: (_) async => true,
        bootstrapSupported: true,
      ),
      throwsFormatException,
    );

    final NetworkPathDecision timedOut =
        await const NetworkPathSelector(probeTimeout: Duration(milliseconds: 1))
            .select(
              candidates: const <NetworkCandidate>[
                NetworkCandidate(host: '192.168.1.2', port: 8443),
              ],
              probe: (_) => Completer<bool>().future,
              bootstrapSupported: false,
            );
    expect(timedOut.kind, NetworkPathKind.unavailable);
  });

  test('selector refuses public, loopback and malformed candidates', () async {
    for (final String host in <String>[
      '8.8.8.8',
      '127.0.0.1',
      '::1',
      'example.com',
    ]) {
      expect(
        const NetworkPathSelector().select(
          candidates: <NetworkCandidate>[
            NetworkCandidate(host: host, port: 8443),
          ],
          probe: (_) async => true,
          bootstrapSupported: false,
        ),
        throwsFormatException,
        reason: host,
      );
    }
  });
}
