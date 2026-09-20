/// Protocol violations raised while validating or encoding protocol structures.
///
/// The codes are the stable code names from `docs/protocol/v1.0-draft1.md` §11.
/// The full error model — scope, retryability and the safe user-message key — is
/// owned by T02-02. This file defines only what the canonical encoder needs in
/// order to reject input, so that a malformed manifest is never silently encoded.
library;

/// Stable protocol error codes, as they appear on the wire (`§11`).
///
/// Only the subset the canonical encoder can raise is listed; T02-02 extends this
/// with the rest of the model rather than duplicating what is here.
enum ProtocolErrorCode {
  /// 400 — a field is malformed, missing, duplicated or not allowed.
  invalidField('INVALID_FIELD'),

  /// 400 — a decimal string violates `0|[1-9][0-9]{0,18}` or its range.
  invalidDecimal('INVALID_DECIMAL'),

  /// 400 — a relative path violates the rules in §5.1.
  invalidPath('INVALID_PATH'),

  /// 413 — a count or size exceeds the limits in §5.
  resourceLimit('RESOURCE_LIMIT'),

  /// 422 — a recomputed digest does not match the frozen one.
  manifestMismatch('MANIFEST_MISMATCH'),

  /// 422 — a recomputed chunk digest does not match the frozen one.
  chunkHashMismatch('CHUNK_HASH_MISMATCH');

  const ProtocolErrorCode(this.wireCode);

  /// The exact string used in protocol error bodies.
  final String wireCode;
}

/// Thrown when input must be rejected before it can be encoded or trusted.
///
/// Carrying a stable code matters: `AGENTS.md` §5 forbids presenting a raw
/// platform exception as a protocol error, and callers must be able to react to
/// the code rather than parse a message.
class ProtocolViolation implements Exception {
  const ProtocolViolation(this.code, this.detail);

  final ProtocolErrorCode code;

  /// Human-readable context for diagnostics. Must never contain a secret, a
  /// token or the content of a user file.
  final String detail;

  @override
  String toString() => '${code.wireCode}: $detail';
}
