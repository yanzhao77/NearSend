/// The `POST /v1/pair` body, `docs/protocol/v1.0-draft1.md` §3 and §4.
///
/// Request: `{requestId, sessionId, pairToken, clientLabel, protocolMajor, protocolMinor}`.
/// Success returns
/// `{sessionAccessToken, expiresInSeconds:1800, protocolMajor:1, protocolMinor:0, capabilities:[...]}`.
///
/// ## What is deliberately not decided here
///
/// §3 writes the response's capability list as `capabilities:[...]` and never enumerates
/// a single identifier. `AGENTS.md` §3 forbids settling an unresolved protocol detail by
/// preference, so this file reuses [CapabilitySet] from T02-02 - which implements the
/// bounded value type and no vocabulary - rather than inventing one. The gap is
/// registered in `docs/PROJECT_LEDGER.md` §5.
///
/// ## The token never goes in a URL
///
/// §3: "令牌不放 URL". There is no builder here that produces a URL or a query string,
/// and the request body is the only place a token is ever written, so the rule is not
/// something a caller has to remember.
library;

import 'package:nearsend/core/protocol/base64url.dart';
import 'package:nearsend/core/protocol/protocol_exception.dart';
import 'package:nearsend/core/protocol/protocol_limits.dart';
import 'package:nearsend/core/protocol/protocol_validation.dart';
import 'package:nearsend/core/protocol/protocol_version.dart';

/// The `POST /v1/pair` request body.
class PairRequest {
  const PairRequest({
    required this.requestId,
    required this.sessionId,
    required this.pairToken,
    required this.clientLabel,
    this.protocolMajor = ProtocolLimits.protocolMajor,
    this.protocolMinor = ProtocolLimits.protocolMinor,
  });

  /// Canonical lowercase UUID (§9 makes `requestId` a canonical UUID).
  final String requestId;

  /// The session the QR code named.
  final String sessionId;

  /// The one-time token, in its canonical unpadded base64url spelling (§4).
  final String pairToken;

  /// A label shown to the receiving user.
  ///
  /// §3 bounds it at 128 UTF-8 bytes and states plainly that it is **not** an identity.
  /// It is never used to authorise anything.
  final String clientLabel;

  final int protocolMajor;
  final int protocolMinor;

  static const Set<String> _allowedKeys = <String>{
    'requestId',
    'sessionId',
    'pairToken',
    'clientLabel',
    'protocolMajor',
    'protocolMinor',
  };

  /// Parses and validates a request body.
  static PairRequest parse(Map<String, Object?> json) {
    rejectUnknownKeys(json, _allowedKeys, 'the pairing request');

    final String requestId = _requireCanonicalUuid(
      json,
      'requestId',
      'the pairing request',
    );
    final String sessionId = _requireCanonicalUuid(
      json,
      'sessionId',
      'the pairing request',
    );

    final Object? token = requireField(
      json,
      'pairToken',
      'the pairing request',
    );
    decodeBase64UrlNoPaddingExact(
      token,
      'pairToken',
      expectedBytes: ProtocolLimits.pairTokenBytes,
    );

    final String clientLabel = _parseClientLabel(
      requireField(json, 'clientLabel', 'the pairing request'),
    );

    final int major = parseJsonInteger(
      requireField(json, 'protocolMajor', 'the pairing request'),
      'protocolMajor',
    );
    final int minor = parseJsonInteger(
      requireField(json, 'protocolMinor', 'the pairing request'),
      'protocolMinor',
    );

    return PairRequest(
      requestId: requestId,
      sessionId: sessionId,
      pairToken: token! as String,
      clientLabel: clientLabel,
      protocolMajor: major,
      protocolMinor: minor,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'requestId': requestId,
    'sessionId': sessionId,
    'pairToken': pairToken,
    'clientLabel': clientLabel,
    'protocolMajor': protocolMajor,
    'protocolMinor': protocolMinor,
  };

  /// Never renders the token: a request body reaches logs and crash reports.
  @override
  String toString() =>
      'PairRequest($requestId, session $sessionId, "$clientLabel", '
      '$protocolMajor.$protocolMinor)';
}

/// The `POST /v1/pair` success body.
class PairResponse {
  const PairResponse({
    required this.sessionAccessToken,
    required this.capabilities,
    this.expiresInSeconds = ProtocolLimits.sessionAccessTokenTtlSeconds,
    this.protocolMajor = ProtocolLimits.protocolMajor,
    this.protocolMinor = ProtocolLimits.protocolMinor,
  });

  /// A 32-byte session access token, in its canonical unpadded base64url spelling.
  ///
  /// §3 sends it as `Authorization: Bearer` on later requests and never in a URL.
  final String sessionAccessToken;

  /// What the server advertises. See the library comment: the vocabulary is undefined.
  final CapabilitySet capabilities;

  /// §3 fixes this at 1800 seconds.
  final int expiresInSeconds;

  final int protocolMajor;
  final int protocolMinor;

  static const Set<String> _allowedKeys = <String>{
    'sessionAccessToken',
    'expiresInSeconds',
    'protocolMajor',
    'protocolMinor',
    'capabilities',
  };

  static PairResponse parse(Map<String, Object?> json) {
    rejectUnknownKeys(json, _allowedKeys, 'the pairing response');

    final Object? token = requireField(
      json,
      'sessionAccessToken',
      'the pairing response',
    );
    decodeBase64UrlNoPaddingExact(
      token,
      'sessionAccessToken',
      expectedBytes: ProtocolLimits.accessTokenBytes,
    );

    final int expires = parseJsonInteger(
      requireField(json, 'expiresInSeconds', 'the pairing response'),
      'expiresInSeconds',
    );
    if (expires <= 0) {
      throw const ProtocolViolation(
        ProtocolErrorCode.invalidField,
        'expiresInSeconds must be positive',
      );
    }

    return PairResponse(
      sessionAccessToken: token! as String,
      expiresInSeconds: expires,
      protocolMajor: parseJsonInteger(
        requireField(json, 'protocolMajor', 'the pairing response'),
        'protocolMajor',
      ),
      protocolMinor: parseJsonInteger(
        requireField(json, 'protocolMinor', 'the pairing response'),
        'protocolMinor',
      ),
      capabilities: CapabilitySet.fromJson(
        requireField(json, 'capabilities', 'the pairing response'),
        'the pairing response',
      ),
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'sessionAccessToken': sessionAccessToken,
    'expiresInSeconds': expiresInSeconds,
    'protocolMajor': protocolMajor,
    'protocolMinor': protocolMinor,
    'capabilities': capabilities.toJson(),
  };

  /// Never renders the access token.
  @override
  String toString() =>
      'PairResponse($protocolMajor.$protocolMinor, '
      '${capabilities.length} capabilities, expires in ${expiresInSeconds}s)';
}

String _requireCanonicalUuid(
  Map<String, Object?> json,
  String field,
  String scope,
) {
  final Object? value = requireField(json, field, scope);
  uuidToBytes(value, field);
  return value! as String;
}

/// §3 bounds the label and says it is shown, not trusted.
String _parseClientLabel(Object? value) {
  if (value is! String) {
    throw const ProtocolViolation(
      ProtocolErrorCode.invalidField,
      'clientLabel must be a string',
    );
  }
  if (value.isEmpty) {
    throw const ProtocolViolation(
      ProtocolErrorCode.invalidField,
      'clientLabel must not be empty',
    );
  }
  for (final int unit in value.codeUnits) {
    if (unit < 0x20 || unit == 0x7F) {
      throw const ProtocolViolation(
        ProtocolErrorCode.invalidField,
        'clientLabel must not contain control characters',
      );
    }
  }
  final int bytes = utf8BytesOf(value);
  if (bytes > ProtocolLimits.clientLabelMaxBytes) {
    throw ProtocolViolation(
      ProtocolErrorCode.invalidField,
      'clientLabel is $bytes bytes, over the '
      '${ProtocolLimits.clientLabelMaxBytes} byte limit',
    );
  }
  return value;
}
