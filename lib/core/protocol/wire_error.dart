/// The error body and credential header, `docs/protocol/v1.0-draft1.md` §7 and §11.
///
/// §7 fixes the body: `{code,message,retryable,requestId?}`, with the requirement that
/// "message 不含密钥或完整本地路径". §7 also says a control response must carry
/// `Cache-Control: no-store`, and that all IDs are parsed and validated before use.
///
/// ## Why `message` is not free text
///
/// A rule that says "do not put a secret in the message" relies on every future caller
/// remembering it, and the failure is invisible until a token turns up in a log. So
/// [WireError.of] does not accept a message at all: it writes the code's stable
/// [ProtocolErrorCode.messageKey], which comes from a closed set of constants. Nothing a
/// caller passes can reach the field, so nothing a caller passes can leak through it.
///
/// A *received* message is different: a peer may send any text. It is bounded and checked
/// for control characters, and it is never rendered without being treated as untrusted
/// input. The parser does not try to guess whether it contains a secret - a heuristic
/// there would be a false comfort.
///
/// ## Why `retryable` is checked rather than trusted
///
/// The body carries `retryable` even though §11's table already decides it per code. A
/// peer that sent `retryable: true` with `CHUNK_HASH_MISMATCH` would be inviting a client
/// to retry a corrupt block forever. So the parsed value must agree with the code's
/// documented behaviour, and a disagreement is a protocol violation rather than something
/// to prefer one way or the other.
library;

import 'package:nearsend/core/protocol/base64url.dart';
import 'package:nearsend/core/protocol/protocol_exception.dart';
import 'package:nearsend/core/protocol/protocol_limits.dart';
import 'package:nearsend/core/protocol/protocol_validation.dart';

/// The `{code, message, retryable, requestId?}` body of §7.
class WireError {
  const WireError({
    required this.code,
    required this.message,
    required this.retryable,
    this.requestId,
  });

  /// Builds the body for [code], with the code's own message key.
  ///
  /// There is deliberately no parameter for free text: see the library comment.
  factory WireError.of(ProtocolErrorCode code, {String? requestId}) =>
      WireError(
        code: code,
        message: code.messageKey,
        retryable: code.retryable,
        requestId: requestId,
      );

  /// Builds the body from a local error, keeping the request it belongs to.
  factory WireError.from(ProtocolError error, {String? requestId}) =>
      WireError.of(error.code, requestId: requestId);

  final ProtocolErrorCode code;

  /// The code's stable message key on responses this build writes; whatever a peer sent
  /// on responses it reads.
  final String message;

  /// Must equal [ProtocolErrorCode.retryable] for [code].
  final bool retryable;

  /// The request this error answers, when the peer supplied one.
  final String? requestId;

  /// The HTTP status §11 pairs with [code].
  int get httpStatus => code.httpStatus;

  static const Set<String> _allowedKeys = <String>{
    'code',
    'message',
    'retryable',
    'requestId',
  };

  /// Parses a received error body.
  static WireError parse(Map<String, Object?> json) {
    rejectUnknownKeys(json, _allowedKeys, 'the error body');

    final Object? rawCode = requireField(json, 'code', 'the error body');
    if (rawCode is! String) {
      throw const ProtocolViolation(
        ProtocolErrorCode.invalidField,
        'the error body code must be a string',
      );
    }
    final ProtocolErrorCode? code = ProtocolErrorCode.fromWireCode(rawCode);
    if (code == null) {
      throw const ProtocolViolation(
        ProtocolErrorCode.invalidField,
        'the error body carries an unknown code',
      );
    }

    final Object? rawMessage = requireField(json, 'message', 'the error body');
    if (rawMessage is! String) {
      throw const ProtocolViolation(
        ProtocolErrorCode.invalidField,
        'the error body message must be a string',
      );
    }
    _assertSafeMessage(rawMessage);

    final Object? rawRetryable = requireField(
      json,
      'retryable',
      'the error body',
    );
    if (rawRetryable is! bool) {
      throw const ProtocolViolation(
        ProtocolErrorCode.invalidField,
        'the error body retryable must be a boolean',
      );
    }
    if (rawRetryable != code.retryable) {
      throw ProtocolViolation(
        ProtocolErrorCode.invalidField,
        'the error body claims retryable=$rawRetryable for ${code.wireCode}, which '
        '§11 does not make retryable',
      );
    }

    String? requestId;
    if (json.containsKey('requestId')) {
      final Object? raw = json['requestId'];
      uuidToBytes(raw, 'requestId');
      requestId = raw! as String;
    }

    return WireError(
      code: code,
      message: rawMessage,
      retryable: rawRetryable,
      requestId: requestId,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'code': code.wireCode,
    'message': message,
    'retryable': retryable,
    if (requestId != null) 'requestId': requestId,
  };

  /// Whether the same request may be sent again unchanged.
  bool get isRetryable => retryable;

  @override
  String toString() =>
      'WireError(${code.wireCode}, $httpStatus, retryable=$retryable'
      '${requestId == null ? '' : ', requestId=$requestId'})';
}

/// §7 bounds the message and forbids credentials and full local paths in it.
///
/// The checks here are the ones that can be made mechanically. They do not prove the
/// absence of a secret - only never writing one does - and the library comment says so
/// rather than implying otherwise.
void _assertSafeMessage(String message) {
  for (final int unit in message.codeUnits) {
    if (unit < 0x20 || unit == 0x7F) {
      throw const ProtocolViolation(
        ProtocolErrorCode.invalidField,
        'the error body message must not contain control characters',
      );
    }
  }
  final int bytes = utf8BytesOf(message);
  if (bytes > ProtocolLimits.wireMessageMaxBytes) {
    throw ProtocolViolation(
      ProtocolErrorCode.invalidField,
      'the error body message is $bytes bytes, over the '
      '${ProtocolLimits.wireMessageMaxBytes} byte limit',
    );
  }
}

/// The `Authorization` header of §7, which carries a bearer token and nothing else.
///
/// §3 is explicit that a token must not appear in a URL, and §7 carries it as
/// `Authorization: Bearer <token>`. There is no parser here for a token in a query
/// string, so no code path can read one from there.
abstract final class BearerHeader {
  /// The scheme name, matched case-insensitively as HTTP requires.
  static const String scheme = 'Bearer';

  /// Returns the token from [headerValue], or throws.
  ///
  /// A missing header, a different scheme, padding, extra whitespace or a token of the
  /// wrong length are all refused. Being strict here matters more than usual: an accepted
  /// near-miss is a credential that one implementation treats as present and another as
  /// absent.
  static String parse(String? headerValue) {
    if (headerValue == null) {
      throw const ProtocolViolation(
        ProtocolErrorCode.authExpired,
        'no Authorization header was supplied',
      );
    }

    const String separator = ' ';
    final int space = headerValue.indexOf(separator);
    if (space == -1) {
      throw const ProtocolViolation(
        ProtocolErrorCode.authExpired,
        'the Authorization header carries no scheme and token',
      );
    }

    final String schemeName = headerValue.substring(0, space);
    if (schemeName.toLowerCase() != scheme.toLowerCase()) {
      throw const ProtocolViolation(
        ProtocolErrorCode.authExpired,
        'the Authorization header does not use the Bearer scheme',
      );
    }

    final String token = headerValue.substring(space + 1);
    if (token.isEmpty) {
      throw const ProtocolViolation(
        ProtocolErrorCode.authExpired,
        'the Authorization header carries an empty token',
      );
    }
    if (token.contains(' ') || token.contains('\t')) {
      throw const ProtocolViolation(
        ProtocolErrorCode.authExpired,
        'the Authorization header carries more than a scheme and a token',
      );
    }

    decodeBase64UrlNoPaddingExact(
      token,
      'the bearer token',
      expectedBytes: ProtocolLimits.accessTokenBytes,
    );
    return token;
  }

  /// Whether [headerValue] carries a token this build would accept.
  static bool isWellFormed(String? headerValue) {
    try {
      parse(headerValue);
      return true;
    } on ProtocolViolation {
      return false;
    }
  }
}

/// `Retry-After`, which §11 attaches to 429.
///
/// §11: "按 Retry-After（秒）退避", so only the delta-seconds form is accepted. The
/// HTTP-date form is refused rather than parsed: an offline device's clock is exactly the
/// kind of thing the protocol does not trust elsewhere, and a client that mis-read a date
/// would either hammer the peer or wait far too long.
abstract final class RetryAfterHeader {
  /// Parses [headerValue] into a whole number of seconds, or null when absent.
  static int? parse(String? headerValue) {
    if (headerValue == null) {
      return null;
    }
    if (!RegExp(r'^[0-9]{1,9}$').hasMatch(headerValue)) {
      throw const ProtocolViolation(
        ProtocolErrorCode.invalidField,
        'Retry-After must be a whole number of seconds',
      );
    }
    return int.parse(headerValue);
  }

  /// Refuses a 429 that carries no usable delay.
  ///
  /// §11 makes the backoff the prescribed behaviour for 429, and a limit without a delay
  /// leaves a client with nothing to obey.
  static int requireFor(ProtocolErrorCode code, String? headerValue) {
    if (code != ProtocolErrorCode.rateLimited) {
      throw const ProtocolViolation(
        ProtocolErrorCode.invalidField,
        'only RATE_LIMITED carries Retry-After',
      );
    }
    final int? seconds = parse(headerValue);
    if (seconds == null || seconds <= 0) {
      throw const ProtocolViolation(
        ProtocolErrorCode.invalidField,
        'a RATE_LIMITED response must carry a positive Retry-After',
      );
    }
    return seconds;
  }
}
