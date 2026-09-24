/// NearSend's TLS identity: the server's self-signed leaf certificate and its private key.
///
/// ## Why a self-signed certificate is generated at runtime
///
/// `docs/protocol/v1.0-draft1.md` §2 fixes the trust anchor as
/// `SHA-256(服务端叶证书完整 DER)` published in the pairing QR code, and `AGENTS.md` §5
/// forbids private keys in source, logs, or ordinary storage. Those two together leave no
/// room for a shipped certificate: a key committed to the repository is a key every install
/// shares, and there is no Dart API that uses a non-exportable platform key
/// (dart-lang/sdk#42904 is open, and `SecurityContext` exposes only PEM/PKCS#12 bytes).
///
/// So each install generates its own P-256 keypair and self-signs a leaf on first run, and
/// the key bytes go to platform secure storage - never to a plain file.
///
/// ## Why the validity window is deliberately enormous
///
/// An offline device's clock is not trustworthy, and the TLS stack **does** check the
/// validity period during chain validation. A one-year certificate would therefore make an
/// app with a wrong clock unable to connect **to itself**, which is the exact failure §2
/// describes: "不因离线时钟错误改成接受任意证书". The reading taken here is to remove the
/// date from the identity decision rather than to weaken it: the pin is the identity, and
/// the certificate is valid for the whole span a plausible clock can be wrong by
/// (2000-01-01 to 2049-12-31, which is the range UTC time can even express).
///
/// Hostnames are settled the same way and are the reason [subjectAltNames] exists rather
/// than being omitted: if the client reaches the server by an address that is in the
/// certificate, name checking cannot be the thing that decides a connection.
///
/// ## What this file does not do
///
/// It never writes anything to disk. It returns bytes, and the caller is responsible for
/// putting the private key into platform secure storage. There is no `toFile`.
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/api.dart';
import 'package:pointycastle/asn1.dart';
import 'package:pointycastle/digests/sha256.dart';
import 'package:pointycastle/ecc/api.dart';
import 'package:pointycastle/ecc/curves/prime256v1.dart';
import 'package:pointycastle/key_generators/api.dart';
import 'package:pointycastle/key_generators/ec_key_generator.dart';
import 'package:pointycastle/macs/hmac.dart';
import 'package:pointycastle/random/fortuna_random.dart';
import 'package:pointycastle/signers/ecdsa_signer.dart';

import 'package:nearsend/core/protocol/protocol_validation.dart';
import 'package:nearsend/core/security/pairing_trust.dart';

/// Object identifiers this module writes. Named, so no call site carries a dotted string.
const String _oidCommonName = '2.5.4.3';
const String _oidEcPublicKey = '1.2.840.10045.2.1';
const String _oidPrime256v1 = '1.2.840.10045.3.1.7';
const String _oidEcdsaWithSha256 = '1.2.840.10045.4.3.2';
const String _oidSubjectAltName = '2.5.29.17';
const String _oidBasicConstraints = '2.5.29.19';
const String _oidKeyUsage = '2.5.29.15';
const String _oidExtendedKeyUsage = '2.5.29.37';
const String _oidExtendedKeyUsageServerAuth = '1.3.6.1.5.5.7.3.1';

/// The widest window UTC time can express, for the reason in the library comment.
final DateTime _earliestNotBefore = DateTime.utc(2000, 1, 1);
final DateTime _latestNotAfter = DateTime.utc(2049, 12, 31, 23, 59, 59);

/// One install's TLS identity.
///
/// Both encodings are held because they have different consumers and neither is derivable
/// from the other without parsing: [certificateDer] is what the pin is computed over and
/// what the peer receives, and [privateKeyPkcs8Der] is what goes to secure storage.
class TlsIdentity {
  TlsIdentity({required this.certificateDer, required this.privateKeyPkcs8Der});

  /// The leaf certificate, DER encoded. §2 digests exactly these bytes.
  final Uint8List certificateDer;

  /// The P-256 private key in PKCS#8 `PrivateKeyInfo` form.
  final Uint8List privateKeyPkcs8Der;

  /// The protocol pin: `SHA-256(leaf DER)` as lowercase 64 hex (§2).
  ///
  /// Delegates to [serverFingerprintOf] rather than hashing here, so the project keeps one
  /// definition of what a pin is - the same one the QR payload and the pairing handshake use.
  String get pin => serverFingerprintOf(certificateDer);

  /// The certificate as PEM, the form `SecurityContext.useCertificateChainBytes` accepts.
  Uint8List get certificatePem => _pem('CERTIFICATE', certificateDer);

  /// The private key as PEM, the form `SecurityContext.usePrivateKeyBytes` accepts.
  Uint8List get privateKeyPem => _pem('PRIVATE KEY', privateKeyPkcs8Der);

  @override
  String toString() =>
      'TlsIdentity(pin=$pin, certificate=${certificateDer.length}B)';
}

/// The installation's long-term device identity, separate from its TLS leaf.
///
/// The public key and its digest may be persisted as peer metadata. The PKCS#8 private key must
/// only be serialized inside the platform secure-store envelope.
class DeviceIdentity {
  DeviceIdentity({
    required this.publicKeyDer,
    required this.privateKeyPkcs8Der,
  });

  final Uint8List publicKeyDer;
  final Uint8List privateKeyPkcs8Der;

  String get deviceId => bytesToSha256Hex(SHA256Digest().process(publicKeyDer));

  /// Signs a canonical peer-authentication transcript with the installation key.
  ///
  /// The fixed-width `r || s` result avoids accepting multiple DER spellings. A
  /// low-S signature is required so the same proof has one canonical encoding.
  Uint8List signAuthenticationTranscript(Uint8List transcript) {
    final _ParsedDeviceKey key = _parseDeviceKeyPair(
      publicKeyDer,
      privateKeyPkcs8Der,
    );
    final ECSignature generated = _sign(
      transcript,
      key.privateKey,
      secureRandom(),
    );
    final BigInt halfOrder = key.curve.n >> 1;
    final BigInt canonicalS = generated.s > halfOrder
        ? key.curve.n - generated.s
        : generated.s;
    return Uint8List.fromList(<int>[
      ..._fixedLength(generated.r, 32),
      ..._fixedLength(canonicalS, 32),
    ]);
  }

  @override
  String toString() => 'DeviceIdentity(deviceId=$deviceId)';
}

/// Verifies a canonical long-term identity signature from an untrusted peer.
bool verifyDeviceAuthenticationSignature({
  required Uint8List publicKeyDer,
  required Uint8List transcript,
  required Uint8List signature,
}) {
  if (signature.length != 64) return false;
  try {
    final _ParsedPublicDeviceKey key = _parseDevicePublicKey(publicKeyDer);
    final BigInt r = _unsignedBigInt(Uint8List.sublistView(signature, 0, 32));
    final BigInt s = _unsignedBigInt(Uint8List.sublistView(signature, 32));
    if (r <= BigInt.zero ||
        r >= key.curve.n ||
        s <= BigInt.zero ||
        s > (key.curve.n >> 1)) {
      return false;
    }
    final ECDSASigner verifier = ECDSASigner(
      SHA256Digest(),
      HMac(SHA256Digest(), 64),
    )..init(false, PublicKeyParameter<ECPublicKey>(key.publicKey));
    return verifier.verifySignature(transcript, ECSignature(r, s));
  } on Object {
    return false;
  }
}

/// Validates a canonical P-256 public key and returns its stable device ID.
String deviceIdForPublicKey(Uint8List publicKeyDer) {
  _parseDevicePublicKey(publicKeyDer);
  return bytesToSha256Hex(SHA256Digest().process(publicKeyDer));
}

/// Generates a P-256 identity used to recognize an installation across sessions.
DeviceIdentity generateDeviceIdentity() {
  final ECDomainParameters curve = ECCurve_prime256v1();
  final FortunaRandom random = secureRandom();
  final AsymmetricKeyPair<PublicKey, PrivateKey> pair =
      (ECKeyGenerator()..init(
            ParametersWithRandom(ECKeyGeneratorParameters(curve), random),
          ))
          .generateKeyPair();
  final ECPublicKey publicKey = pair.publicKey as ECPublicKey;
  final ECPrivateKey privateKey = pair.privateKey as ECPrivateKey;
  final ECPoint point = publicKey.Q!;
  final Uint8List publicKeyDer = _sequence(<Uint8List>[
    _algorithmIdentifier(_oidEcPublicKey, _oidPrime256v1),
    _bitString(point.getEncoded(false)),
  ]);
  return DeviceIdentity(
    publicKeyDer: publicKeyDer,
    privateKeyPkcs8Der: _pkcs8(privateKey, point),
  );
}

/// Generates a fresh self-signed P-256 identity.
///
/// [subjectAltNames] are the addresses a client is expected to reach this server by. An
/// entry that parses as a dotted-quad IPv4 goes in as an `iPAddress`; anything else goes in
/// as a `dNSName`. Passing none is allowed but not advised: the certificate then carries no
/// name at all, and name checking is left entirely to the pin.
///
/// [commonName] is display-only. It is not an identity - §3 says the same of `clientLabel` -
/// and nothing in the protocol matches on it.
TlsIdentity generateTlsIdentity({
  required String commonName,
  List<String> subjectAltNames = const <String>[],
}) {
  final ECDomainParameters curve = ECCurve_prime256v1();
  final FortunaRandom random = secureRandom();

  final ECKeyGenerator generator = ECKeyGenerator()
    ..init(ParametersWithRandom(ECKeyGeneratorParameters(curve), random));
  final AsymmetricKeyPair<PublicKey, PrivateKey> pair = generator
      .generateKeyPair();
  final ECPublicKey publicKey = pair.publicKey as ECPublicKey;
  final ECPrivateKey privateKey = pair.privateKey as ECPrivateKey;
  final ECPoint point = publicKey.Q!;

  final Uint8List subject = _name(commonName);
  final Uint8List tbsCertificate = _sequence(<Uint8List>[
    // version: [0] EXPLICIT INTEGER 2, i.e. v3. Extensions require v3.
    _explicit(0, _integer(BigInt.from(2))),
    _integer(_randomSerial(random)),
    _algorithmIdentifier(_oidEcdsaWithSha256),
    subject,
    _sequence(<Uint8List>[
      _utcTime(_earliestNotBefore),
      _utcTime(_latestNotAfter),
    ]),
    subject,
    _sequence(<Uint8List>[
      _algorithmIdentifier(_oidEcPublicKey, _oidPrime256v1),
      _bitString(point.getEncoded(false)),
    ]),
    _explicit(3, _sequence(_extensions(subjectAltNames))),
  ]);

  final ECSignature signature = _sign(tbsCertificate, privateKey, random);
  final Uint8List certificate = _sequence(<Uint8List>[
    tbsCertificate,
    _algorithmIdentifier(_oidEcdsaWithSha256),
    _bitString(
      _sequence(<Uint8List>[_integer(signature.r), _integer(signature.s)]),
    ),
  ]);

  return TlsIdentity(
    certificateDer: certificate,
    privateKeyPkcs8Der: _pkcs8(privateKey, point),
  );
}

/// A [FortunaRandom] seeded from the platform CSPRNG.
///
/// `dart:math`'s [Random.secure] is the only entropy source the SDK contract calls
/// cryptographically secure, and pointycastle's generators default to a `SecureRandom` whose
/// seeding this module would otherwise not control. Seeding explicitly is the difference
/// between "the RNG is probably fine" and "the seed came from the platform CSPRNG".
FortunaRandom secureRandom() {
  final Random source = Random.secure();
  final Uint8List seed = Uint8List(32);
  for (int i = 0; i < seed.length; i++) {
    seed[i] = source.nextInt(256);
  }
  return FortunaRandom()..seed(KeyParameter(seed));
}

/// A random 64-bit serial number.
///
/// Never a constant: a serial is how a certificate is identified in a log or a store, and
/// identical serials across installs make two different identities look like one.
BigInt _randomSerial(FortunaRandom random) {
  final Uint8List bytes = Uint8List(8);
  for (int i = 0; i < bytes.length; i++) {
    bytes[i] = random.nextUint8();
  }
  bytes[0] &= 0x7F; // keep it positive
  BigInt value = BigInt.zero;
  for (final int byte in bytes) {
    value = (value << 8) | BigInt.from(byte);
  }
  return value == BigInt.zero ? BigInt.one : value;
}

ECSignature _sign(Uint8List message, ECPrivateKey key, FortunaRandom random) {
  final ECDSASigner signer =
      ECDSASigner(SHA256Digest(), HMac(SHA256Digest(), 64))..init(
        true,
        ParametersWithRandom(PrivateKeyParameter<ECPrivateKey>(key), random),
      );
  return signer.generateSignature(message) as ECSignature;
}

class _ParsedPublicDeviceKey {
  const _ParsedPublicDeviceKey(this.curve, this.publicKey);

  final ECDomainParameters curve;
  final ECPublicKey publicKey;
}

class _ParsedDeviceKey extends _ParsedPublicDeviceKey {
  const _ParsedDeviceKey(super.curve, super.publicKey, this.privateKey);

  final ECPrivateKey privateKey;
}

_ParsedPublicDeviceKey _parseDevicePublicKey(Uint8List encoded) {
  final ASN1Sequence outer = _canonicalSequence(encoded, 'device public key');
  final List<ASN1Object> fields = outer.elements ?? const <ASN1Object>[];
  if (fields.length != 2 ||
      fields[0] is! ASN1Sequence ||
      fields[1] is! ASN1BitString) {
    throw const FormatException('device public key schema does not match');
  }
  _requireP256Algorithm(fields[0] as ASN1Sequence);
  final ASN1BitString pointBits = fields[1] as ASN1BitString;
  final List<int>? pointBytes = pointBits.stringValues;
  if (pointBits.unusedbits != 0 ||
      pointBytes == null ||
      pointBytes.length != 65 ||
      pointBytes.first != 0x04) {
    throw const FormatException(
      'device public key point is not uncompressed P-256',
    );
  }
  final ECDomainParameters curve = ECCurve_prime256v1();
  final ECPoint? point = curve.curve.decodePoint(
    Uint8List.fromList(pointBytes),
  );
  if (point == null || point.isInfinity) {
    throw const FormatException('device public key point is invalid');
  }
  return _ParsedPublicDeviceKey(curve, ECPublicKey(point, curve));
}

_ParsedDeviceKey _parseDeviceKeyPair(
  Uint8List publicKeyDer,
  Uint8List privateKeyDer,
) {
  final _ParsedPublicDeviceKey public = _parseDevicePublicKey(publicKeyDer);
  final ASN1Sequence outer = _canonicalSequence(
    privateKeyDer,
    'device private key',
  );
  final List<ASN1Object> fields = outer.elements ?? const <ASN1Object>[];
  if (fields.length != 3 ||
      fields[0] is! ASN1Integer ||
      (fields[0] as ASN1Integer).integer != BigInt.zero ||
      fields[1] is! ASN1Sequence ||
      fields[2] is! ASN1OctetString) {
    throw const FormatException('device private key schema does not match');
  }
  _requireP256Algorithm(fields[1] as ASN1Sequence);
  final Uint8List? sec1Bytes = (fields[2] as ASN1OctetString).octets;
  if (sec1Bytes == null) {
    throw const FormatException('device private key payload is missing');
  }
  final ASN1Sequence sec1 = _canonicalSequence(sec1Bytes, 'EC private key');
  final List<ASN1Object> sec1Fields = sec1.elements ?? const <ASN1Object>[];
  if (sec1Fields.length != 4 ||
      sec1Fields[0] is! ASN1Integer ||
      (sec1Fields[0] as ASN1Integer).integer != BigInt.one ||
      sec1Fields[1] is! ASN1OctetString ||
      sec1Fields[2].tag != 0xA0 ||
      sec1Fields[3].tag != 0xA1) {
    throw const FormatException('EC private key schema does not match');
  }
  _requireExplicitOid(sec1Fields[2], _oidPrime256v1);
  final ASN1BitString embeddedPublic = _explicitBitString(sec1Fields[3]);
  final Uint8List expectedPoint = public.publicKey.Q!.getEncoded(false);
  if (embeddedPublic.unusedbits != 0 ||
      embeddedPublic.stringValues == null ||
      !_sameBytes(embeddedPublic.stringValues!, expectedPoint)) {
    throw const FormatException('device private and public keys do not match');
  }
  final Uint8List? scalarBytes = (sec1Fields[1] as ASN1OctetString).octets;
  if (scalarBytes == null || scalarBytes.length != 32) {
    throw const FormatException('device private scalar has the wrong length');
  }
  final BigInt scalar = _unsignedBigInt(scalarBytes);
  if (scalar <= BigInt.zero || scalar >= public.curve.n) {
    throw const FormatException('device private scalar is out of range');
  }
  final ECPoint calculated = (public.curve.G * scalar)!;
  if (!_sameBytes(calculated.getEncoded(false), expectedPoint)) {
    throw const FormatException(
      'device private scalar does not match public key',
    );
  }
  return _ParsedDeviceKey(
    public.curve,
    public.publicKey,
    ECPrivateKey(scalar, public.curve),
  );
}

ASN1Sequence _canonicalSequence(Uint8List encoded, String field) {
  try {
    final ASN1Parser parser = ASN1Parser(encoded);
    final ASN1Object parsed = parser.nextObject();
    if (parsed is! ASN1Sequence ||
        parser.hasNext() ||
        !_sameBytes(parsed.encode(), encoded)) {
      throw FormatException('$field is not one canonical DER sequence');
    }
    return parsed;
  } on FormatException {
    rethrow;
  } on Object {
    throw FormatException('$field is not valid DER');
  }
}

void _requireP256Algorithm(ASN1Sequence sequence) {
  final List<ASN1Object> fields = sequence.elements ?? const <ASN1Object>[];
  if (fields.length != 2 ||
      fields[0] is! ASN1ObjectIdentifier ||
      fields[1] is! ASN1ObjectIdentifier ||
      (fields[0] as ASN1ObjectIdentifier).objectIdentifierAsString !=
          _oidEcPublicKey ||
      (fields[1] as ASN1ObjectIdentifier).objectIdentifierAsString !=
          _oidPrime256v1) {
    throw const FormatException('device key algorithm must be P-256');
  }
}

void _requireExplicitOid(ASN1Object object, String expected) {
  final Uint8List? bytes = object.valueBytes;
  if (bytes == null) throw const FormatException('explicit OID is missing');
  final ASN1Parser parser = ASN1Parser(bytes);
  final ASN1Object parsed = parser.nextObject();
  if (parsed is! ASN1ObjectIdentifier ||
      parser.hasNext() ||
      parsed.objectIdentifierAsString != expected) {
    throw const FormatException('explicit OID does not match');
  }
}

ASN1BitString _explicitBitString(ASN1Object object) {
  final Uint8List? bytes = object.valueBytes;
  if (bytes == null) {
    throw const FormatException('explicit bit string is missing');
  }
  final ASN1Parser parser = ASN1Parser(bytes);
  final ASN1Object parsed = parser.nextObject();
  if (parsed is! ASN1BitString || parser.hasNext()) {
    throw const FormatException('explicit value is not one bit string');
  }
  return parsed;
}

BigInt _unsignedBigInt(List<int> bytes) {
  BigInt value = BigInt.zero;
  for (final int byte in bytes) {
    value = (value << 8) | BigInt.from(byte);
  }
  return value;
}

bool _sameBytes(List<int> first, List<int> second) {
  if (first.length != second.length) return false;
  int difference = 0;
  for (int index = 0; index < first.length; index++) {
    difference |= first[index] ^ second[index];
  }
  return difference == 0;
}

List<Uint8List> _extensions(List<String> subjectAltNames) => <Uint8List>[
  _extension(
    _oidKeyUsage,
    critical: true,
    value: _bitString(<int>[0x80]), // digitalSignature
  ),
  _extension(
    _oidExtendedKeyUsage,
    critical: false,
    value: _sequence(<Uint8List>[_oidValue(_oidExtendedKeyUsageServerAuth)]),
  ),
  _extension(
    _oidBasicConstraints,
    critical: true,
    // SEQUENCE { } means cA = FALSE. The certificate is a leaf, and it is still usable as
    // its own trust anchor: the client pins it by fingerprint, not by chaining to it.
    value: _sequence(const <Uint8List>[]),
  ),
  if (subjectAltNames.isNotEmpty)
    _extension(
      _oidSubjectAltName,
      critical: false,
      value: _sequence(<Uint8List>[
        for (final String name in subjectAltNames) _generalName(name),
      ]),
    ),
];

Uint8List _generalName(String name) {
  final Uint8List? address = _ipv4Bytes(name);
  if (address != null) {
    // GeneralName ::= ... iPAddress [7] OCTET STRING
    return _contextPrimitive(7, address);
  }
  // dNSName [2] IA5String
  return _contextPrimitive(2, ascii.encode(name));
}

/// Parses a dotted-quad IPv4 literal, or returns null.
///
/// Leading zeros are refused rather than accepted: some parsers read `010` as octal, so a
/// name that means one thing here and another there is the same disagreement this project
/// refuses elsewhere. `pairing_payload.dart` applies the same rule to QR hosts.
Uint8List? _ipv4Bytes(String text) {
  final List<String> parts = text.split('.');
  if (parts.length != 4) {
    return null;
  }
  final Uint8List out = Uint8List(4);
  for (int i = 0; i < 4; i++) {
    final String part = parts[i];
    if (part.isEmpty ||
        part.length > 3 ||
        !RegExp(r'^[0-9]+$').hasMatch(part)) {
      return null;
    }
    if (part.length > 1 && part.startsWith('0')) {
      return null;
    }
    final int value = int.parse(part);
    if (value > 255) {
      return null;
    }
    out[i] = value;
  }
  return out;
}

Uint8List _extension(
  String oid, {
  required bool critical,
  required Uint8List value,
}) => _sequence(<Uint8List>[
  _oidValue(oid),
  if (critical) _boolean(true),
  _octetString(value),
]);

Uint8List _name(String commonName) => _sequence(<Uint8List>[
  _set(<Uint8List>[
    _sequence(<Uint8List>[_oidValue(_oidCommonName), _utf8String(commonName)]),
  ]),
]);

/// PKCS#8 `PrivateKeyInfo` wrapping a SEC1 `ECPrivateKey`.
Uint8List _pkcs8(ECPrivateKey key, ECPoint point) {
  final int fieldBytes = (point.curve.fieldSize + 7) ~/ 8;
  final Uint8List sec1 = _sequence(<Uint8List>[
    _integer(BigInt.one),
    _octetString(_fixedLength(key.d!, fieldBytes)),
    _explicit(0, _oidValue(_oidPrime256v1)),
    _explicit(1, _bitString(point.getEncoded(false))),
  ]);
  return _sequence(<Uint8List>[
    _integer(BigInt.zero),
    _algorithmIdentifier(_oidEcPublicKey, _oidPrime256v1),
    _octetString(sec1),
  ]);
}

/// A big-endian, zero-padded fixed-width encoding of a scalar.
Uint8List _fixedLength(BigInt value, int length) {
  final Uint8List out = Uint8List(length);
  BigInt remaining = value;
  for (int i = length - 1; i >= 0; i--) {
    out[i] = (remaining & BigInt.from(0xFF)).toInt();
    remaining = remaining >> 8;
  }
  return out;
}

Uint8List _algorithmIdentifier(String oid, [String? parametersOid]) =>
    _sequence(<Uint8List>[
      _oidValue(oid),
      if (parametersOid != null) _oidValue(parametersOid),
    ]);

// ---------------------------------------------------------------------------------------
// DER primitives.
//
// The encoding is under test rather than trusted: `tls_identity_test.dart` re-parses what
// this writes with an independent ASN.1 parser and drives a real TLS handshake with the
// result, so a length or tag mistake fails loudly instead of producing a certificate that
// only some stacks accept.
// ---------------------------------------------------------------------------------------

Uint8List _sequence(List<Uint8List> parts) => _tlv(0x30, _concat(parts));

Uint8List _set(List<Uint8List> parts) => _tlv(0x31, _concat(parts));

Uint8List _integer(BigInt value) => _tlv(0x02, _signedBytes(value));

Uint8List _oidValue(String dotted) => _tlv(0x06, _oidBytes(dotted));

Uint8List _octetString(List<int> value) => _tlv(0x04, value);

Uint8List _utf8String(String value) => _tlv(0x0C, utf8.encode(value));

Uint8List _boolean(bool value) => _tlv(0x01, <int>[value ? 0xFF : 0x00]);

Uint8List _utcTime(DateTime value) => _tlv(0x17, ascii.encode(_utc(value)));

/// `YYMMDDHHMMSSZ`. Seconds are included rather than omitted so two certificates generated
/// in the same minute are still distinguishable by their validity field.
String _utc(DateTime value) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(value.year % 100)}${two(value.month)}${two(value.day)}'
      '${two(value.hour)}${two(value.minute)}${two(value.second)}Z';
}

Uint8List _bitString(List<int> value) => _tlv(0x03, <int>[0x00, ...value]);

/// `[number] EXPLICIT`, i.e. a constructed context tag whose content is [inner] encoded.
Uint8List _explicit(int number, Uint8List inner) => _tlv(0xA0 | number, inner);

/// `[number]` as a primitive, for the GeneralName choices.
Uint8List _contextPrimitive(int number, List<int> value) =>
    _tlv(0x80 | number, value);

Uint8List _tlv(int tag, List<int> value) =>
    Uint8List.fromList(<int>[tag, ..._length(value.length), ...value]);

List<int> _length(int length) {
  if (length < 0x80) {
    return <int>[length];
  }
  final List<int> out = <int>[];
  int remaining = length;
  while (remaining > 0) {
    out.insert(0, remaining & 0xFF);
    remaining >>= 8;
  }
  return <int>[0x80 | out.length, ...out];
}

/// Minimal two's-complement, big-endian, with a leading zero when the top bit is set.
List<int> _signedBytes(BigInt value) {
  if (value == BigInt.zero) {
    return <int>[0];
  }
  final List<int> out = <int>[];
  BigInt remaining = value;
  while (remaining > BigInt.zero) {
    out.insert(0, (remaining & BigInt.from(0xFF)).toInt());
    remaining = remaining >> 8;
  }
  if (out.first & 0x80 != 0) {
    out.insert(0, 0);
  }
  return out;
}

List<int> _oidBytes(String dotted) {
  final List<int> parts = dotted.split('.').map(int.parse).toList();
  if (parts.length < 2) {
    throw ArgumentError.value(dotted, 'dotted', 'an OID needs two components');
  }
  final List<int> out = <int>[parts[0] * 40 + parts[1]];
  for (final int part in parts.skip(2)) {
    final List<int> group = <int>[];
    int remaining = part;
    do {
      group.insert(0, remaining & 0x7F);
      remaining >>= 7;
    } while (remaining > 0);
    for (int i = 0; i < group.length - 1; i++) {
      group[i] |= 0x80;
    }
    out.addAll(group);
  }
  return out;
}

List<int> _concat(List<Uint8List> parts) {
  final BytesBuilder builder = BytesBuilder(copy: false);
  for (final Uint8List part in parts) {
    builder.add(part);
  }
  return builder.takeBytes();
}

Uint8List _pem(String label, List<int> der) {
  final String encoded = base64.encode(der);
  final StringBuffer out = StringBuffer('-----BEGIN $label-----\n');
  for (int i = 0; i < encoded.length; i += 64) {
    out.writeln(encoded.substring(i, min(i + 64, encoded.length)));
  }
  out.write('-----END $label-----\n');
  return Uint8List.fromList(ascii.encode(out.toString()));
}
