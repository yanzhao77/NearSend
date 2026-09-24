import 'dart:convert';
import 'dart:typed_data';

import 'package:nearsend/core/security/tls_identity.dart';

class IdentityRecoveryRequired implements Exception {
  const IdentityRecoveryRequired(this.reason);

  final String reason;

  @override
  String toString() => 'IdentityRecoveryRequired($reason)';
}

/// Versioned secret payload stored as one platform-protected value.
class InstallationIdentity {
  InstallationIdentity({required this.device, required this.tls});

  static const int currentVersion = 1;

  final DeviceIdentity device;
  final TlsIdentity tls;

  String encode() => jsonEncode(<String, Object>{
    'version': currentVersion,
    'devicePublicKey': base64.encode(device.publicKeyDer),
    'devicePrivateKey': base64.encode(device.privateKeyPkcs8Der),
    'tlsCertificate': base64.encode(tls.certificateDer),
    'tlsPrivateKey': base64.encode(tls.privateKeyPkcs8Der),
  });

  static InstallationIdentity decode(String encoded) {
    final Object? value = jsonDecode(encoded);
    if (value is! Map<String, Object?>) {
      throw const FormatException('identity payload must be an object');
    }
    const Set<String> fields = <String>{
      'version',
      'devicePublicKey',
      'devicePrivateKey',
      'tlsCertificate',
      'tlsPrivateKey',
    };
    if (value.keys.toSet().difference(fields).isNotEmpty ||
        fields.difference(value.keys.toSet()).isNotEmpty ||
        value['version'] != currentVersion) {
      throw const FormatException('identity payload schema does not match');
    }
    Uint8List bytes(String field) {
      final Object? text = value[field];
      if (text is! String || text.isEmpty) {
        throw FormatException('$field is missing');
      }
      final Uint8List decoded = base64.decode(text);
      if (decoded.isEmpty) throw FormatException('$field is empty');
      return decoded;
    }

    return InstallationIdentity(
      device: DeviceIdentity(
        publicKeyDer: bytes('devicePublicKey'),
        privateKeyPkcs8Der: bytes('devicePrivateKey'),
      ),
      tls: TlsIdentity(
        certificateDer: bytes('tlsCertificate'),
        privateKeyPkcs8Der: bytes('tlsPrivateKey'),
      ),
    );
  }
}

abstract interface class SecureIdentityStore {
  Future<String?> readIdentity();

  Future<void> writeIdentity(String encodedIdentity);
}

abstract interface class InstallationIdentityProvider {
  bool get isPersistent;

  Future<InstallationIdentity> load({
    required String commonName,
    required List<String> subjectAltNames,
    required bool hasIdentityMetadata,
  });
}

class EphemeralInstallationIdentityProvider
    implements InstallationIdentityProvider {
  const EphemeralInstallationIdentityProvider();

  @override
  bool get isPersistent => false;

  @override
  Future<InstallationIdentity> load({
    required String commonName,
    required List<String> subjectAltNames,
    required bool hasIdentityMetadata,
  }) async => InstallationIdentity(
    device: generateDeviceIdentity(),
    tls: generateTlsIdentity(
      commonName: commonName,
      subjectAltNames: subjectAltNames,
    ),
  );
}

class SecureInstallationIdentityProvider
    implements InstallationIdentityProvider {
  SecureInstallationIdentityProvider(this.store);

  final SecureIdentityStore store;

  @override
  bool get isPersistent => true;

  @override
  Future<InstallationIdentity> load({
    required String commonName,
    required List<String> subjectAltNames,
    required bool hasIdentityMetadata,
  }) async {
    final String? stored;
    try {
      stored = await store.readIdentity();
    } on Object catch (error) {
      throw IdentityRecoveryRequired('secure identity is unavailable: $error');
    }
    if (stored != null) {
      try {
        return InstallationIdentity.decode(stored);
      } on Object catch (error) {
        throw IdentityRecoveryRequired('stored identity is invalid: $error');
      }
    }
    if (hasIdentityMetadata) {
      throw const IdentityRecoveryRequired(
        'the secure identity is missing while identity metadata still exists',
      );
    }
    final InstallationIdentity created = InstallationIdentity(
      device: generateDeviceIdentity(),
      tls: generateTlsIdentity(
        commonName: commonName,
        subjectAltNames: subjectAltNames,
      ),
    );
    try {
      await store.writeIdentity(created.encode());
    } on Object catch (error) {
      throw IdentityRecoveryRequired(
        'secure identity could not be saved: $error',
      );
    }
    return created;
  }
}
