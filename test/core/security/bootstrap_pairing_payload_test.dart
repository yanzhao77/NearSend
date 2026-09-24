import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:nearsend/core/protocol/base64url.dart';
import 'package:nearsend/core/protocol/protocol_exception.dart';
import 'package:nearsend/core/security/bootstrap_pairing_payload.dart';
import 'package:nearsend/core/security/pairing_payload.dart';
import 'package:nearsend/core/security/tls_identity.dart';

void main() {
  final DeviceIdentity identity = generateDeviceIdentity();
  final String token = encodeBase64UrlNoPadding(Uint8List(32));

  PairingPayload pairing({int expires = 120}) => PairingPayload(
    serverFingerprint: 'a' * 64,
    sessionId: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
    candidates: const <PairingCandidate>[
      PairingCandidate(host: '192.168.1.2', port: 8443),
    ],
    pairToken: token,
    expiresInSeconds: expires,
  );

  BootstrapPairingPayload payload({
    BootstrapPairingMode mode = BootstrapPairingMode.reachableNetwork,
    BootstrapWifiOffer? wifi,
  }) => BootstrapPairingPayload(
    mode: mode,
    pairing: pairing(),
    identityPublicKey: identity.publicKeyDer,
    deviceId: identity.deviceId,
    invitationRole: 'host',
    wifi: wifi,
  );

  test('reachable bootstrap round trips through the common dispatcher', () {
    final ScannedPairingPayload decoded = ScannedPairingPayload.parse(
      payload().encode(),
    );

    expect(decoded, isA<BootstrapPairingPayload>());
    final BootstrapPairingPayload bootstrap =
        decoded as BootstrapPairingPayload;
    expect(bootstrap.deviceId, identity.deviceId);
    expect(bootstrap.wifi, isNull);
  });

  test('network bootstrap carries secured in-memory Wi-Fi credentials', () {
    final BootstrapPairingPayload decoded = ScannedPairingPayload.parse(
      payload(
        mode: BootstrapPairingMode.networkBootstrap,
        wifi: BootstrapWifiOffer(
          ssid: 'NearSend-1234',
          passphrase: 'eight-or-more',
          security: 'wpa2',
        ),
      ).encode(),
    ) as BootstrapPairingPayload;

    expect(decoded.wifi!.ssid, 'NearSend-1234');
    expect(decoded.wifi!.passphrase, 'eight-or-more');
    expect(decoded.wifi.toString(), isNot(contains('NearSend-1234')));
    expect(decoded.wifi.toString(), isNot(contains('eight-or-more')));
    expect(decoded.toString(), isNot(contains(token)));
  });

  test('legacy lft-pair continues through its original parser', () {
    final ScannedPairingPayload decoded = ScannedPairingPayload.parse(
      pairing(expires: 300).encode(),
    );
    expect(decoded, isA<LegacyScannedPairingPayload>());
  });

  test('duplicate and extra fields are rejected before dispatch', () {
    final String encoded = payload().encode();
    expect(
      () => ScannedPairingPayload.parse(
        encoded.replaceFirst(
          '"formatVersion":1',
          '"formatVersion":1,"formatVersion":1',
        ),
      ),
      throwsA(isA<ProtocolViolation>()),
    );

    final Map<String, Object?> object =
        jsonDecode(encoded) as Map<String, Object?>;
    object['extra'] = true;
    expect(
      () => ScannedPairingPayload.parse(jsonEncode(object)),
      throwsA(isA<ProtocolViolation>()),
    );
  });

  test('identity substitution and non-canonical keys are rejected', () {
    final Map<String, Object?> object =
        jsonDecode(payload().encode()) as Map<String, Object?>;
    object['deviceId'] = 'b' * 64;
    expect(
      () => ScannedPairingPayload.parse(jsonEncode(object)),
      throwsA(isA<ProtocolViolation>()),
    );

    object['deviceId'] = identity.deviceId;
    object['identityPublicKey'] = '${object['identityPublicKey']}=';
    expect(
      () => ScannedPairingPayload.parse(jsonEncode(object)),
      throwsA(isA<ProtocolViolation>()),
    );
  });

  test('mode, hotspot security and lifetime fail closed', () {
    expect(
      () => payload(mode: BootstrapPairingMode.networkBootstrap),
      throwsA(isA<ProtocolViolation>()),
    );
    expect(
      () => BootstrapWifiOffer(
        ssid: 'NearSend',
        passphrase: 'eight-or-more',
        security: 'open',
      ),
      throwsA(isA<ProtocolViolation>()),
    );
    expect(
      () => BootstrapPairingPayload(
        mode: BootstrapPairingMode.reachableNetwork,
        pairing: pairing(expires: 121),
        identityPublicKey: identity.publicKeyDer,
        deviceId: identity.deviceId,
        invitationRole: 'host',
      ),
      throwsA(isA<ProtocolViolation>()),
    );
  });

  test('unknown kind, oversized payload and malformed JSON are rejected', () {
    for (final String source in <String>[
      '{"kind":"unknown"}',
      '{',
      'x' * (bootstrapPairingMaxBytes + 1),
    ]) {
      expect(
        () => ScannedPairingPayload.parse(source),
        throwsA(isA<ProtocolViolation>()),
      );
    }
  });
}
