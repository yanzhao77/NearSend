import 'package:flutter_test/flutter_test.dart';

import 'package:nearsend/core/security/installation_identity.dart';
import 'package:nearsend/core/security/tls_identity.dart';

void main() {
  test('an identity round trips without changing either stable identifier', () {
    final InstallationIdentity original = InstallationIdentity(
      device: generateDeviceIdentity(),
      tls: generateTlsIdentity(
        commonName: 'NearSend',
        subjectAltNames: const <String>['192.0.2.1'],
      ),
    );

    final InstallationIdentity decoded = InstallationIdentity.decode(
      original.encode(),
    );

    expect(decoded.device.deviceId, original.device.deviceId);
    expect(decoded.tls.pin, original.tls.pin);
    expect(
      decoded.device.privateKeyPkcs8Der,
      original.device.privateKeyPkcs8Der,
    );
    expect(decoded.tls.privateKeyPkcs8Der, original.tls.privateKeyPkcs8Der);
    expect(original.toString(), isNot(contains('PRIVATE')));
    expect(original.device.toString(), isNot(contains('PRIVATE')));
  });

  test('a malformed or unknown identity schema is rejected', () {
    expect(
      () => InstallationIdentity.decode('{}'),
      throwsA(isA<FormatException>()),
    );
    expect(
      () => InstallationIdentity.decode('{"version":2}'),
      throwsA(isA<FormatException>()),
    );
  });

  test(
    'first launch creates once and later launches reuse the identity',
    () async {
      final _MemoryStore store = _MemoryStore();
      final SecureInstallationIdentityProvider provider =
          SecureInstallationIdentityProvider(store);

      final InstallationIdentity first = await provider.load(
        commonName: 'NearSend',
        subjectAltNames: const <String>['192.0.2.1'],
        hasIdentityMetadata: false,
      );
      final InstallationIdentity second = await provider.load(
        commonName: 'Renamed device',
        subjectAltNames: const <String>['198.51.100.2'],
        hasIdentityMetadata: true,
      );

      expect(store.writes, 1);
      expect(second.device.deviceId, first.device.deviceId);
      expect(second.tls.pin, first.tls.pin);
    },
  );

  test(
    'missing secure identity beside identity metadata fails closed',
    () async {
      final SecureInstallationIdentityProvider provider =
          SecureInstallationIdentityProvider(_MemoryStore());

      await expectLater(
        provider.load(
          commonName: 'NearSend',
          subjectAltNames: const <String>['192.0.2.1'],
          hasIdentityMetadata: true,
        ),
        throwsA(isA<IdentityRecoveryRequired>()),
      );
    },
  );

  test('corrupt secure identity is not silently replaced', () async {
    final _MemoryStore store = _MemoryStore()..value = '{not-json';
    final SecureInstallationIdentityProvider provider =
        SecureInstallationIdentityProvider(store);

    await expectLater(
      provider.load(
        commonName: 'NearSend',
        subjectAltNames: const <String>['192.0.2.1'],
        hasIdentityMetadata: true,
      ),
      throwsA(isA<IdentityRecoveryRequired>()),
    );
    expect(store.writes, 0);
  });
}

class _MemoryStore implements SecureIdentityStore {
  String? value;
  int writes = 0;

  @override
  Future<String?> readIdentity() async => value;

  @override
  Future<void> writeIdentity(String encodedIdentity) async {
    writes++;
    value = encodedIdentity;
  }
}
