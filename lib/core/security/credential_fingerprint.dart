/// Turning a credential into something safe to persist.
///
/// §9 scopes a `request_id` to "同一任务＋操作＋**当前恢复凭证**", so the stored scope has to
/// vary with the credential: a request id presented before a re-pairing must not silently
/// match one presented after it. Keeping the credential itself would satisfy that and
/// violate `AGENTS.md` §5, which keeps "恢复密钥、访问令牌及签名凭证" out of ordinary SQLite
/// fields, logs and diagnostics.
///
/// A SHA-256 over the credential resolves the two: the scope distinguishes credentials, and
/// what is stored cannot be turned back into one. The preimage is a 32-byte value (§3), so
/// the digest is not brute-forceable either - this is a fingerprint, not an obfuscation.
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';

/// A stable, non-reversible fingerprint of [credential].
///
/// Returns lowercase hexadecimal, the same shape the protocol uses for every other digest,
/// so a reader cannot mistake it for a secret.
String credentialFingerprint(String credential) {
  if (credential.isEmpty) {
    throw ArgumentError.value(
      credential,
      'credential',
      'an empty credential has no fingerprint to scope on',
    );
  }
  return sha256.convert(utf8.encode(credential)).toString();
}

/// Whether [value] has the shape [credentialFingerprint] produces.
///
/// Used to check a value read back from storage: a scope whose fingerprint is malformed was
/// not written by this code, and comparing it against a freshly computed one would simply
/// never match rather than saying so.
bool looksLikeCredentialFingerprint(String value) =>
    value.length == 64 && RegExp(r'^[0-9a-f]{64}$').hasMatch(value);
