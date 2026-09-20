/// Field-level validation shared by the canonical encoders.
///
/// Implements the value rules from `docs/protocol/v1.0-draft1.md` §4: decimal
/// strings, canonical lowercase UUIDs and lowercase hexadecimal SHA-256 digests.
/// Each rule is enforced in one place so that the manifest encoder, the chunk
/// encoder and later the API layer cannot disagree about what is legal.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:nearsend/core/protocol/protocol_exception.dart';
import 'package:nearsend/core/protocol/protocol_limits.dart';

/// The UTF-8 byte length of [value].
///
/// §3, §4 and §5.1 all express their limits in UTF-8 bytes rather than characters, and a
/// character count would let a name of multi-byte characters pass a limit it exceeds.
int utf8BytesOf(String value) => utf8.encode(value).length;

/// `0|[1-9][0-9]{0,18}`, value range `0..2^63-1` (§4).
///
/// Signs, exponents, leading zeros, whitespace and JSON numbers are all rejected:
/// §4 makes these fields decimal **strings** precisely so that a language's
/// number formatting cannot change the bytes on the wire.
final RegExp _decimalPattern = RegExp(r'^(?:0|[1-9][0-9]{0,18})$');

/// Canonical lowercase UUID, `8-4-4-4-12` hexadecimal (§4).
final RegExp _uuidPattern = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
);

/// Lowercase hexadecimal SHA-256 (§4).
final RegExp _sha256HexPattern = RegExp(r'^[0-9a-f]{64}$');

/// Parses a protocol decimal string into an [int].
///
/// [field] names the field for diagnostics only; it never carries user content.
int parseDecimalString(Object? value, String field) {
  if (value is! String) {
    throw ProtocolViolation(
      ProtocolErrorCode.invalidDecimal,
      '$field must be a decimal string, got ${value.runtimeType}',
    );
  }
  if (!_decimalPattern.hasMatch(value)) {
    throw ProtocolViolation(
      ProtocolErrorCode.invalidDecimal,
      '$field is not a valid decimal string',
    );
  }
  if (value.length > ProtocolLimits.maxDecimalDigits) {
    throw ProtocolViolation(
      ProtocolErrorCode.invalidDecimal,
      '$field exceeds ${ProtocolLimits.maxDecimalDigits} digits',
    );
  }
  final int parsed = int.parse(value);
  if (parsed > ProtocolLimits.maxDecimalValue) {
    throw ProtocolViolation(
      ProtocolErrorCode.invalidDecimal,
      '$field exceeds the signed 64-bit range',
    );
  }
  return parsed;
}

/// Parses a JSON integer field such as `chunkSizeBytes` or `fileCount` (§4).
///
/// Booleans are rejected explicitly: in JSON-derived Dart maps a `bool` is not an
/// `int`, but a defensive check documents that the distinction is intentional.
int parseJsonInteger(Object? value, String field) {
  if (value is! int) {
    throw ProtocolViolation(
      ProtocolErrorCode.invalidField,
      '$field must be a JSON integer, got ${value.runtimeType}',
    );
  }
  if (value < 0) {
    throw ProtocolViolation(
      ProtocolErrorCode.invalidField,
      '$field must not be negative',
    );
  }
  return value;
}

/// Validates a canonical lowercase UUID and returns its 16 raw bytes.
///
/// §5.2 encodes UUIDs as 16 bytes in standard network order, so the textual form
/// must be parsed rather than hashed.
Uint8List uuidToBytes(Object? value, String field) {
  if (value is! String || !_uuidPattern.hasMatch(value)) {
    throw ProtocolViolation(
      ProtocolErrorCode.invalidField,
      '$field must be a canonical lowercase UUID',
    );
  }
  final String hex = value.replaceAll('-', '');
  final Uint8List out = Uint8List(ProtocolLimits.uuidBytes);
  for (int i = 0; i < out.length; i++) {
    out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

/// Validates a lowercase hexadecimal SHA-256 and returns its 32 raw bytes.
Uint8List sha256HexToBytes(Object? value, String field) {
  if (value is! String || !_sha256HexPattern.hasMatch(value)) {
    throw ProtocolViolation(
      ProtocolErrorCode.invalidField,
      '$field must be 64 lowercase hexadecimal characters',
    );
  }
  final Uint8List out = Uint8List(ProtocolLimits.sha256Bytes);
  for (int i = 0; i < out.length; i++) {
    out[i] = int.parse(value.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

/// Renders raw digest bytes as the protocol's lowercase hexadecimal form.
String bytesToSha256Hex(List<int> bytes) {
  final StringBuffer buffer = StringBuffer();
  for (final int byte in bytes) {
    buffer.write(byte.toRadixString(16).padLeft(2, '0'));
  }
  return buffer.toString();
}

/// Reads [field] from a decoded JSON object, rejecting a missing key.
///
/// §4 requires unknown fields to be rejected rather than ignored, so callers also
/// use [rejectUnknownKeys] to check the exact key set.
Object? requireField(Map<String, Object?> json, String field, String scope) {
  if (!json.containsKey(field)) {
    throw ProtocolViolation(
      ProtocolErrorCode.invalidField,
      '$scope is missing required field $field',
    );
  }
  return json[field];
}

/// Rejects keys that the specification does not define for this object (§4).
void rejectUnknownKeys(
  Map<String, Object?> json,
  Set<String> allowed,
  String scope,
) {
  for (final String key in json.keys) {
    if (!allowed.contains(key)) {
      throw ProtocolViolation(
        ProtocolErrorCode.invalidField,
        '$scope contains undefined field $key',
      );
    }
  }
}

/// Renders a non-negative count as a protocol decimal string (§4).
///
/// The counterpart to [parseDecimalString], and validating rather than a bare `toString`
/// for the same reason the parser exists: §4 makes these fields strings so that a
/// language's number formatting cannot change the bytes, and a negative or oversized value
/// has no legal encoding at all.
String encodeDecimalString(int value, String field) {
  if (value < 0) {
    throw ProtocolViolation(
      ProtocolErrorCode.invalidDecimal,
      '$field must not be negative',
    );
  }
  if (value > ProtocolLimits.maxDecimalValue) {
    throw ProtocolViolation(
      ProtocolErrorCode.invalidDecimal,
      '$field exceeds the signed 64-bit range',
    );
  }
  return value.toString();
}

/// `chunkCount = ceil(sizeBytes / chunkSizeBytes)`, with zero size giving zero
/// chunks (§5).
int chunkCountForSize(int sizeBytes, int chunkSizeBytes) {
  if (sizeBytes < 0 || chunkSizeBytes <= 0) {
    throw ProtocolViolation(
      ProtocolErrorCode.invalidField,
      'size and chunk size must be non-negative, chunk size positive',
    );
  }
  if (sizeBytes == 0) {
    return 0;
  }
  return (sizeBytes + chunkSizeBytes - 1) ~/ chunkSizeBytes;
}

/// Byte length of chunk [index] in a file of [sizeBytes] (§5, §5.3).
///
/// The final chunk is short; the specification states that its length is derived
/// from the file size, so it is never taken from the peer's claim.
int chunkLengthForIndex(int sizeBytes, int chunkSizeBytes, int index) {
  final int chunkCount = chunkCountForSize(sizeBytes, chunkSizeBytes);
  if (index < 0 || index >= chunkCount) {
    throw ProtocolViolation(
      ProtocolErrorCode.invalidField,
      'chunk index $index is outside 0..${chunkCount - 1}',
    );
  }
  final int offset = index * chunkSizeBytes;
  final int remaining = sizeBytes - offset;
  return remaining < chunkSizeBytes ? remaining : chunkSizeBytes;
}

/// Byte offset of chunk [index], computed with an explicit range check (§8).
///
/// §8 forbids accepting an arbitrary offset from the peer; the offset is derived
/// from the index so that a malicious index cannot address outside the file.
int chunkOffsetForIndex(int sizeBytes, int chunkSizeBytes, int index) {
  chunkLengthForIndex(sizeBytes, chunkSizeBytes, index);
  return index * chunkSizeBytes;
}
