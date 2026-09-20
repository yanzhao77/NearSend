/// The pairing QR code, `docs/protocol/v1.0-draft1.md` §3 and §4.
///
/// This is the first thing a client parses from an untrusted source, and everything it
/// carries is used to decide where to connect and what identity to trust. So it is parsed
/// strictly: §4 requires unknown fields to be **rejected**, not ignored, and every value
/// here is checked against its documented shape rather than loosely coerced.
///
/// ## What this layer does and does not decide
///
/// It decides whether a QR payload is *well formed*: the right fields, the right
/// encodings, addresses that carry no scheme, credentials, path or query, and a token
/// that is the canonical spelling of 32 bytes.
///
/// It does **not** decide whether an address is reachable, whether a host is really on
/// the local link, or whether the server is who it claims - those are the socket layer's
/// and [PairingHandshake]'s jobs. §3 also says candidate selection must not bypass the
/// pin, so choosing a candidate from this list never substitutes for verifying the
/// fingerprint.
library;

import 'dart:convert';

import 'package:nearsend/core/protocol/base64url.dart';
import 'package:nearsend/core/protocol/protocol_exception.dart';
import 'package:nearsend/core/protocol/protocol_limits.dart';
import 'package:nearsend/core/protocol/protocol_validation.dart';

/// The value `kind` must carry (§3).
const String pairingKind = 'lft-pair';

/// One address the client may try.
class PairingCandidate {
  const PairingCandidate({required this.host, required this.port});

  /// A bare interface address: no scheme, no credentials, no path, no query (§3).
  final String host;

  final int port;

  Map<String, Object?> toJson() => <String, Object?>{
    'host': host,
    'port': port,
  };

  @override
  bool operator ==(Object other) =>
      other is PairingCandidate && other.host == host && other.port == port;

  @override
  int get hashCode => Object.hash(host, port);

  @override
  String toString() => 'PairingCandidate($host:$port)';
}

/// The validated contents of a pairing QR code.
class PairingPayload {
  const PairingPayload({
    required this.serverFingerprint,
    required this.sessionId,
    required this.candidates,
    required this.pairToken,
    required this.expiresInSeconds,
    this.protocolMajor = ProtocolLimits.protocolMajor,
    this.protocolMinor = ProtocolLimits.protocolMinor,
  });

  /// The pin: SHA-256 of the server's leaf certificate DER, lowercase hex (§2).
  final String serverFingerprint;

  /// Canonical lowercase UUID (§3, §4).
  final String sessionId;

  /// Addresses to try, in order. Never a substitute for verifying the pin (§3).
  final List<PairingCandidate> candidates;

  /// The one-time pairing token, as the canonical unpadded base64url spelling (§4).
  ///
  /// Held as text because that is what the payload carries; [pairTokenBytes] decodes it
  /// when the raw bytes are needed.
  final String pairToken;

  /// The server's hint for how long the token lives (§3).
  ///
  /// A hint only: §3 says the server's state decides, so a client must not use this as
  /// an expiry it can rely on.
  final int expiresInSeconds;

  final int protocolMajor;
  final int protocolMinor;

  static const Set<String> _allowedKeys = <String>{
    'kind',
    'protocolMajor',
    'protocolMinor',
    'serverFingerprint',
    'sessionId',
    'candidates',
    'pairToken',
    'expiresInSeconds',
  };

  static const Set<String> _candidateKeys = <String>{'host', 'port'};

  /// The pairing token as raw bytes.
  List<int> get pairTokenBytes => decodeBase64UrlNoPaddingExact(
    pairToken,
    'pairToken',
    expectedBytes: ProtocolLimits.pairTokenBytes,
  );

  /// Parses and validates a scanned pairing payload.
  ///
  /// Throws [ProtocolViolation] for anything the specification does not allow. A
  /// malformed payload is never partially accepted, because a partially accepted
  /// payload is how a scan of something else turns into a connection to somewhere else.
  static PairingPayload parse(String qrText) {
    final int byteLength = utf8BytesOf(qrText);
    if (byteLength > ProtocolLimits.pairingQrMaxBytes) {
      throw ProtocolViolation(
        ProtocolErrorCode.invalidField,
        'the pairing payload is $byteLength bytes, over the '
        '${ProtocolLimits.pairingQrMaxBytes} byte limit',
      );
    }

    final Object? decoded;
    try {
      decoded = jsonDecode(qrText);
    } on FormatException {
      throw const ProtocolViolation(
        ProtocolErrorCode.invalidField,
        'the pairing payload is not valid JSON',
      );
    }

    if (decoded is! Map<String, Object?>) {
      throw const ProtocolViolation(
        ProtocolErrorCode.invalidField,
        'the pairing payload must be a JSON object',
      );
    }

    rejectUnknownKeys(decoded, _allowedKeys, 'the pairing payload');

    final Object? kind = requireField(decoded, 'kind', 'the pairing payload');
    if (kind != pairingKind) {
      throw const ProtocolViolation(
        ProtocolErrorCode.invalidField,
        'kind is not a pairing payload',
      );
    }

    final int major = parseJsonInteger(
      requireField(decoded, 'protocolMajor', 'the pairing payload'),
      'protocolMajor',
    );
    final int minor = parseJsonInteger(
      requireField(decoded, 'protocolMinor', 'the pairing payload'),
      'protocolMinor',
    );

    // The digest is validated as a digest rather than as a string: §2 defines the pin as
    // SHA-256 of the leaf certificate DER, so a PEM digest or an SPKI digest is a
    // different value of the same shape and would silently be the wrong pin.
    final Object? fingerprint = requireField(
      decoded,
      'serverFingerprint',
      'the pairing payload',
    );
    sha256HexToBytes(fingerprint, 'serverFingerprint');

    final Object? sessionId = requireField(
      decoded,
      'sessionId',
      'the pairing payload',
    );
    uuidToBytes(sessionId, 'sessionId');

    final List<PairingCandidate> candidates = _parseCandidates(
      requireField(decoded, 'candidates', 'the pairing payload'),
    );

    final Object? token = requireField(
      decoded,
      'pairToken',
      'the pairing payload',
    );
    decodeBase64UrlNoPaddingExact(
      token,
      'pairToken',
      expectedBytes: ProtocolLimits.pairTokenBytes,
    );

    final int expires = parseJsonInteger(
      requireField(decoded, 'expiresInSeconds', 'the pairing payload'),
      'expiresInSeconds',
    );
    if (expires <= 0) {
      throw const ProtocolViolation(
        ProtocolErrorCode.invalidField,
        'expiresInSeconds must be positive',
      );
    }

    return PairingPayload(
      protocolMajor: major,
      protocolMinor: minor,
      serverFingerprint: fingerprint! as String,
      sessionId: sessionId! as String,
      candidates: candidates,
      pairToken: token! as String,
      expiresInSeconds: expires,
    );
  }

  /// Renders the payload back to the exact JSON form the scanner parses.
  ///
  /// Present so the issuer and the scanner can be tested against each other: a QR code
  /// this project produces must be one this project accepts.
  String encode() => jsonEncode(toJson());

  Map<String, Object?> toJson() => <String, Object?>{
    'kind': pairingKind,
    'protocolMajor': protocolMajor,
    'protocolMinor': protocolMinor,
    'serverFingerprint': serverFingerprint,
    'sessionId': sessionId,
    'candidates': <Object?>[
      for (final PairingCandidate candidate in candidates) candidate.toJson(),
    ],
    'pairToken': pairToken,
    'expiresInSeconds': expiresInSeconds,
  };

  static List<PairingCandidate> _parseCandidates(Object? value) {
    if (value is! List) {
      throw const ProtocolViolation(
        ProtocolErrorCode.invalidField,
        'candidates must be an array',
      );
    }
    if (value.isEmpty) {
      throw const ProtocolViolation(
        ProtocolErrorCode.invalidField,
        'candidates must carry at least one address',
      );
    }
    if (value.length > ProtocolLimits.pairingCandidatesMax) {
      throw ProtocolViolation(
        ProtocolErrorCode.invalidField,
        'candidates carries ${value.length} addresses, over the '
        '${ProtocolLimits.pairingCandidatesMax} limit',
      );
    }

    final List<PairingCandidate> out = <PairingCandidate>[];
    for (final Object? entry in value) {
      if (entry is! Map<String, Object?>) {
        throw const ProtocolViolation(
          ProtocolErrorCode.invalidField,
          'each candidate must be a JSON object',
        );
      }
      rejectUnknownKeys(entry, _candidateKeys, 'a candidate');

      final String host = _parseHost(
        requireField(entry, 'host', 'a candidate'),
      );
      final int port = parseJsonInteger(
        requireField(entry, 'port', 'a candidate'),
        'port',
      );
      if (port < 1 || port > ProtocolLimits.maxPort) {
        throw ProtocolViolation(
          ProtocolErrorCode.invalidField,
          'port must be 1..${ProtocolLimits.maxPort}',
        );
      }
      out.add(PairingCandidate(host: host, port: port));
    }
    return List<PairingCandidate>.unmodifiable(out);
  }

  /// Requires a bare interface address.
  ///
  /// §3 says the field is the address itself and forbids credentials, path and query from
  /// being mixed into it. The check is lexical and deliberately explicit about the shapes
  /// it refuses, because every one of them is a way a scan can be steered somewhere the
  /// user did not intend: `https://host/x?t=` carries a scheme and a path, `user@host`
  /// carries credentials, and a trailing `/` carries a path.
  ///
  /// Whether the address is reachable, or is really on the local link, is not decidable
  /// here and is not claimed.
  static String _parseHost(Object? value) {
    if (value is! String) {
      throw const ProtocolViolation(
        ProtocolErrorCode.invalidField,
        'a candidate host must be a string',
      );
    }
    if (value.isEmpty) {
      throw const ProtocolViolation(
        ProtocolErrorCode.invalidField,
        'a candidate host must not be empty',
      );
    }

    for (final int unit in value.codeUnits) {
      if (unit <= 0x20 || unit == 0x7F) {
        throw const ProtocolViolation(
          ProtocolErrorCode.invalidField,
          'a candidate host must not contain whitespace or control characters',
        );
      }
    }
    for (final String forbidden in <String>[
      '://',
      '/',
      '\\',
      '?',
      '#',
      '@',
      '[',
      ']',
    ]) {
      if (value.contains(forbidden)) {
        throw const ProtocolViolation(
          ProtocolErrorCode.invalidField,
          'a candidate host must be a bare address, with no scheme, credentials, '
          'path or query',
        );
      }
    }

    if (value.contains(':')) {
      _assertLooksLikeIpv6(value);
    } else {
      _assertLooksLikeIpv4(value);
    }
    return value;
  }

  static void _assertLooksLikeIpv4(String value) {
    final List<String> parts = value.split('.');
    if (parts.length != 4) {
      throw const ProtocolViolation(
        ProtocolErrorCode.invalidField,
        'a candidate host must be an IPv4 or IPv6 address',
      );
    }
    for (final String part in parts) {
      if (part.isEmpty || part.length > 3) {
        throw const ProtocolViolation(
          ProtocolErrorCode.invalidField,
          'a candidate host is not a valid IPv4 address',
        );
      }
      if (!RegExp(r'^[0-9]+$').hasMatch(part)) {
        throw const ProtocolViolation(
          ProtocolErrorCode.invalidField,
          'a candidate host is not a valid IPv4 address',
        );
      }
      if (part.length > 1 && part.startsWith('0')) {
        throw const ProtocolViolation(
          ProtocolErrorCode.invalidField,
          'a candidate host has a leading zero in an IPv4 octet',
        );
      }
      if (int.parse(part) > 255) {
        throw const ProtocolViolation(
          ProtocolErrorCode.invalidField,
          'a candidate host has an IPv4 octet above 255',
        );
      }
    }
  }

  /// A structural check for IPv6, with an optional zone for a link-local address.
  ///
  /// This is not a full address parser and does not claim to be: it rejects the shapes
  /// that are not an address at all, and leaves the authoritative decision to the socket
  /// layer, which is the only place that can make it.
  static void _assertLooksLikeIpv6(String value) {
    final String address = value.contains('%')
        ? value.substring(0, value.indexOf('%'))
        : value;
    final String? zone = value.contains('%')
        ? value.substring(value.indexOf('%') + 1)
        : null;

    if (zone != null) {
      if (zone.isEmpty || !RegExp(r'^[A-Za-z0-9_.-]+$').hasMatch(zone)) {
        throw const ProtocolViolation(
          ProtocolErrorCode.invalidField,
          'a candidate host has an invalid IPv6 zone identifier',
        );
      }
    }

    if (!RegExp(r'^[0-9A-Fa-f:]+$').hasMatch(address)) {
      throw const ProtocolViolation(
        ProtocolErrorCode.invalidField,
        'a candidate host is not a valid IPv6 address',
      );
    }
    // At most one `::` elision, and never a single stray colon at an end.
    if ('::'.allMatches(address).length > 1) {
      throw const ProtocolViolation(
        ProtocolErrorCode.invalidField,
        'a candidate host has more than one IPv6 elision',
      );
    }
    if (address.startsWith(':') && !address.startsWith('::')) {
      throw const ProtocolViolation(
        ProtocolErrorCode.invalidField,
        'a candidate host is not a valid IPv6 address',
      );
    }
    if (address.endsWith(':') && !address.endsWith('::')) {
      throw const ProtocolViolation(
        ProtocolErrorCode.invalidField,
        'a candidate host is not a valid IPv6 address',
      );
    }
    final List<String> groups = address.split(':');
    for (final String group in groups) {
      if (group.length > 4) {
        throw const ProtocolViolation(
          ProtocolErrorCode.invalidField,
          'a candidate host has an IPv6 group longer than four digits',
        );
      }
    }
  }
}
