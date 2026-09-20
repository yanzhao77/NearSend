/// Canonical base64url without padding, `docs/protocol/v1.0-draft1.md` §4.
///
/// §4 fixes three things about the encoding that a general-purpose decoder does not
/// give you for free:
///
/// * the alphabet is base64**url**, so `-` and `_` rather than `+` and `/`;
/// * no `=` padding, and 32 bytes is therefore exactly 43 characters;
/// * **decoding and re-encoding must produce the same string**. That last rule is the
///   one worth a dedicated decoder: unpadded base64 has spare low bits in its final
///   character, so several distinct strings decode to the same bytes. Two peers that
///   each accept a different spelling of the same token would disagree about the bytes
///   they are comparing, and a value that is used as a credential is exactly where that
///   must not happen.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:nearsend/core/protocol/protocol_exception.dart';

/// The unpadded base64url alphabet.
final RegExp _base64UrlPattern = RegExp(r'^[A-Za-z0-9_-]+$');

/// Encodes [bytes] as unpadded base64url.
String encodeBase64UrlNoPadding(List<int> bytes) =>
    base64Url.encode(bytes).replaceAll('=', '');

/// Decodes [value] and requires it to be the canonical spelling of [_expectedBytes].
///
/// [field] names the field for diagnostics only; it never carries the value itself,
/// because a token must not reach a log or an error message.
Uint8List decodeBase64UrlNoPaddingExact(
  Object? value,
  String field, {
  required int expectedBytes,
}) {
  if (value is! String) {
    throw ProtocolViolation(
      ProtocolErrorCode.invalidField,
      '$field must be a base64url string, got ${value.runtimeType}',
    );
  }
  if (value.contains('=')) {
    throw ProtocolViolation(
      ProtocolErrorCode.invalidField,
      '$field must not be padded',
    );
  }
  if (value.isEmpty || !_base64UrlPattern.hasMatch(value)) {
    throw ProtocolViolation(
      ProtocolErrorCode.invalidField,
      '$field is not unpadded base64url',
    );
  }

  final Uint8List decoded;
  try {
    decoded = base64Url.decode(base64Url.normalize(value));
  } on FormatException {
    // Deliberately without the codec's message: no path may echo a credential, even
    // in a diagnostic string.
    throw ProtocolViolation(
      ProtocolErrorCode.invalidField,
      '$field is not valid base64url',
    );
  }

  if (decoded.length != expectedBytes) {
    throw ProtocolViolation(
      ProtocolErrorCode.invalidField,
      '$field must decode to $expectedBytes bytes, got ${decoded.length}',
    );
  }

  if (encodeBase64UrlNoPadding(decoded) != value) {
    throw ProtocolViolation(
      ProtocolErrorCode.invalidField,
      '$field is not the canonical spelling of those bytes',
    );
  }

  return decoded;
}
