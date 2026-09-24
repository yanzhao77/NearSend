import 'dart:convert';
import 'dart:typed_data';

import 'package:nearsend/core/protocol/base64url.dart';
import 'package:nearsend/core/protocol/json_body.dart';
import 'package:nearsend/core/protocol/protocol_exception.dart';
import 'package:nearsend/core/security/pairing_payload.dart';
import 'package:nearsend/core/security/tls_identity.dart';

const String bootstrapPairingKind = 'nearsend-bootstrap';
const int bootstrapPairingFormatVersion = 1;
const int bootstrapPairingMaxBytes = 4096;
const int bootstrapPairingMaxLifetimeSeconds = 120;

enum BootstrapPairingMode { reachableNetwork, networkBootstrap }

sealed class ScannedPairingPayload {
  const ScannedPairingPayload();

  factory ScannedPairingPayload.parse(String source) {
    final Uint8List bytes = Uint8List.fromList(utf8.encode(source));
    if (bytes.isEmpty || bytes.length > bootstrapPairingMaxBytes) {
      throw const ProtocolViolation(
        ProtocolErrorCode.invalidField,
        'the scanned pairing payload has an invalid size',
      );
    }
    final Map<String, Object?> object = decodeControlBody(
      bytes,
      scope: 'the scanned pairing payload',
    );
    return switch (object['kind']) {
      pairingKind => LegacyScannedPairingPayload(PairingPayload.parse(source)),
      bootstrapPairingKind => BootstrapPairingPayload._parse(object),
      _ => throw const ProtocolViolation(
        ProtocolErrorCode.invalidField,
        'the scanned payload kind is not supported',
      ),
    };
  }
}

class LegacyScannedPairingPayload extends ScannedPairingPayload {
  const LegacyScannedPairingPayload(this.pairing);

  final PairingPayload pairing;
}

class BootstrapWifiOffer {
  BootstrapWifiOffer({
    required this.ssid,
    required this.passphrase,
    required this.security,
  }) {
    final int ssidBytes = utf8.encode(ssid).length;
    if (ssidBytes < 1 || ssidBytes > 32 || ssid.contains('\u0000')) {
      _invalid('bootstrap SSID is invalid');
    }
    if (passphrase.length < 8 ||
        passphrase.length > 63 ||
        passphrase.codeUnits.any((int unit) => unit < 0x20 || unit > 0x7e)) {
      _invalid('bootstrap passphrase is invalid');
    }
    if (security != 'wpa2' && security != 'wpa3') {
      _invalid('bootstrap Wi-Fi security is unsupported');
    }
  }

  static const Set<String> _keys = <String>{'ssid', 'passphrase', 'security'};

  final String ssid;
  final String passphrase;
  final String security;

  Map<String, Object?> toJson() => <String, Object?>{
    'ssid': ssid,
    'passphrase': passphrase,
    'security': security,
  };

  static BootstrapWifiOffer parse(Object? value) {
    if (value is! Map<String, Object?> || !_hasExactKeys(value, _keys)) {
      _invalid('bootstrap Wi-Fi offer fields are invalid');
    }
    return BootstrapWifiOffer(
      ssid: _string(value, 'ssid'),
      passphrase: _string(value, 'passphrase'),
      security: _string(value, 'security'),
    );
  }

  @override
  String toString() => 'BootstrapWifiOffer(security=$security)';
}

class BootstrapPairingPayload extends ScannedPairingPayload {
  BootstrapPairingPayload({
    required this.mode,
    required this.pairing,
    required Uint8List identityPublicKey,
    required this.deviceId,
    required this.invitationRole,
    this.wifi,
  }) : identityPublicKey = Uint8List.fromList(identityPublicKey) {
    _validate();
  }

  static const Set<String> _keys = <String>{
    'kind',
    'formatVersion',
    'mode',
    'invitationRole',
    'deviceId',
    'identityPublicKey',
    'pairing',
    'wifi',
  };

  final BootstrapPairingMode mode;
  final PairingPayload pairing;
  final Uint8List identityPublicKey;
  final String deviceId;
  final String invitationRole;
  final BootstrapWifiOffer? wifi;

  void _validate() {
    final String derivedId;
    try {
      derivedId = deviceIdForPublicKey(identityPublicKey);
    } on Object {
      _invalid('bootstrap identity key is invalid');
    }
    if (derivedId != deviceId || invitationRole != 'host') {
      _invalid('bootstrap identity binding is invalid');
    }
    if (pairing.expiresInSeconds > bootstrapPairingMaxLifetimeSeconds) {
      _invalid('bootstrap invitation lifetime is too long');
    }
    if ((mode == BootstrapPairingMode.networkBootstrap) != (wifi != null)) {
      _invalid('bootstrap mode and Wi-Fi offer do not match');
    }
  }

  String encode() => jsonEncode(<String, Object?>{
    'kind': bootstrapPairingKind,
    'formatVersion': bootstrapPairingFormatVersion,
    'mode': mode.name,
    'invitationRole': invitationRole,
    'deviceId': deviceId,
    'identityPublicKey': encodeBase64UrlNoPadding(identityPublicKey),
    'pairing': pairing.toJson(),
    'wifi': wifi?.toJson(),
  });

  static BootstrapPairingPayload _parse(Map<String, Object?> value) {
    if (!_hasExactKeys(value, _keys) ||
        value['formatVersion'] != bootstrapPairingFormatVersion) {
      _invalid('bootstrap payload fields or version are invalid');
    }
    final Object? pairingValue = value['pairing'];
    if (pairingValue is! Map<String, Object?>) {
      _invalid('bootstrap pairing value is invalid');
    }
    final String modeText = _string(value, 'mode');
    final BootstrapPairingMode mode = switch (modeText) {
      'reachableNetwork' => BootstrapPairingMode.reachableNetwork,
      'networkBootstrap' => BootstrapPairingMode.networkBootstrap,
      _ => throw const ProtocolViolation(
        ProtocolErrorCode.invalidField,
        'bootstrap mode is unsupported',
      ),
    };
    final Object? encodedKey = value['identityPublicKey'];
    final Uint8List publicKey = _decodeIdentityKey(encodedKey);
    return BootstrapPairingPayload(
      mode: mode,
      pairing: PairingPayload.parse(jsonEncode(pairingValue)),
      identityPublicKey: publicKey,
      deviceId: _string(value, 'deviceId'),
      invitationRole: _string(value, 'invitationRole'),
      wifi: value['wifi'] == null
          ? null
          : BootstrapWifiOffer.parse(value['wifi']),
    );
  }

  @override
  String toString() =>
      'BootstrapPairingPayload(mode=${mode.name}, deviceId=$deviceId)';
}

Uint8List _decodeIdentityKey(Object? value) {
  if (value is! String ||
      value.isEmpty ||
      value.length > 344 ||
      value.contains('=')) {
    _invalid('bootstrap identity key encoding is invalid');
  }
  try {
    final Uint8List decoded = base64Url.decode(base64Url.normalize(value));
    if (decoded.isEmpty ||
        decoded.length > 256 ||
        encodeBase64UrlNoPadding(decoded) != value) {
      _invalid('bootstrap identity key encoding is invalid');
    }
    return decoded;
  } on ProtocolViolation {
    rethrow;
  } on Object {
    _invalid('bootstrap identity key encoding is invalid');
  }
}

String _string(Map<String, Object?> value, String key) {
  final Object? field = value[key];
  if (field is! String || field.isEmpty) {
    _invalid('bootstrap string field is invalid');
  }
  return field;
}

bool _hasExactKeys(Map<String, Object?> value, Set<String> expected) {
  final Set<String> actual = value.keys.toSet();
  return actual.difference(expected).isEmpty &&
      expected.difference(actual).isEmpty;
}

Never _invalid(String message) =>
    throw ProtocolViolation(ProtocolErrorCode.invalidField, message);
