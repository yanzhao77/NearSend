/// The durable half of §3's task credentials, and the volatile half it deliberately is not.
///
/// ## What §2 and §3 require, and how the two halves split
///
/// §2: "服务端私钥、客户端任务恢复凭证使用平台安全存储。**服务端仅保存恢复密钥验证摘要**；
/// 受限完成查询使用不同的凭证。" `AGENTS.md` §5 adds that a recovery secret must never reach an
/// ordinary SQLite column, a log or a diagnostic.
///
/// So this repository stores **only** a SHA-256 digest of each secret
/// ([credentialFingerprint]). That is enough to verify a secret that is presented and useless
/// to somebody who reads the database. The plaintext exists in exactly one place: a
/// process-local vault, from the moment the grant is minted until the client confirms it
/// stored the secrets.
///
/// ## The consequence, stated rather than hidden
///
/// §3 wants the *same* secret re-delivered on a retry: "未收到 receipt 时保留同一待交付密钥在
/// 安全存储中的密文，以支持幂等重取……**禁止每次重试生成不同密钥**". A digest cannot be turned
/// back into its preimage, so a restart between minting and receipt loses the only copy of the
/// plaintext.
///
/// This build's answer is to **refuse** rather than to mint a second pair:
/// [issueSecrets] throws `INVALID_STATE` when a digest exists, no plaintext is held and no
/// receipt was recorded. Handing out a different secret would silently invalidate whatever the
/// client already saved, and the client has no way to notice. The task then has to be approved
/// again, which is a re-decision the receiver is entitled to make. The alternative that would
/// remove the limitation - keeping the ciphertext under a platform-held key - is a secure
/// storage integration this build does not have, and inventing a weaker store here would be
/// worse than refusing.
library;

import 'package:sqlite3/sqlite3.dart';

import 'package:nearsend/core/protocol/base64url.dart';
import 'package:nearsend/core/protocol/protocol_exception.dart';
import 'package:nearsend/core/protocol/protocol_limits.dart';
import 'package:nearsend/core/security/credential_fingerprint.dart';
import 'package:nearsend/core/security/pairing_token.dart';
import 'package:nearsend/core/storage/near_send_database.dart';
import 'package:nearsend/core/storage/storage_schema.dart';

/// A minted pair of §7 task secrets.
///
/// Deliberately has no `toString` that renders the values: this object is what the
/// authorisation response is built from, and a secret that reaches a log has leaked.
class IssuedTaskSecrets {
  const IssuedTaskSecrets({
    required this.taskResumeSecret,
    required this.completionQuerySecret,
  });

  final String taskResumeSecret;
  final String completionQuerySecret;

  @override
  String toString() => 'IssuedTaskSecrets(two secrets, not rendered)';
}

/// A minted task access token, with the moment it stops being accepted.
class IssuedTaskAccessToken {
  const IssuedTaskAccessToken({
    required this.token,
    required this.expiresAtMillis,
  });

  final String token;
  final int expiresAtMillis;

  @override
  String toString() => 'IssuedTaskAccessToken(expires $expiresAtMillis)';
}

/// What a presented task access token resolves to.
class TaskAccessLookup {
  const TaskAccessLookup({required this.transferId});

  final String transferId;

  @override
  String toString() => 'TaskAccessLookup($transferId)';
}

/// Issues, verifies and revokes a task's credentials.
class TaskCredentialRepository {
  TaskCredentialRepository(this.database, {this.now = _systemNow});

  final NearSendDatabase database;

  /// Clock injection, so expiry is testable without waiting.
  final int Function() now;

  static int _systemNow() => DateTime.now().millisecondsSinceEpoch;

  /// Plaintext secrets that have been minted but not yet confirmed by the client.
  ///
  /// The only place a task secret lives outside platform secure storage, and it is bounded by
  /// [maxPendingSecrets]: §3 wants a retry to receive the same secret, and a digest cannot
  /// serve that. Holding at most a few dozen means a peer cannot grow this by asking for
  /// grants it never confirms.
  final Map<String, IssuedTaskSecrets> _pending = <String, IssuedTaskSecrets>{};

  /// How many undelivered grants may be held at once.
  ///
  /// A transfer that is approved and then abandoned would otherwise pin its secrets for the
  /// life of the process. Evicting the oldest is safe in the direction that matters: an
  /// evicted grant is refused rather than replaced, so nothing is invalidated silently.
  static const int maxPendingSecrets = 64;

  /// Mints the task's resume and completion-query secrets, or re-delivers the pending pair.
  ///
  /// Idempotent while the grant has not been confirmed: §3 forbids minting a different secret
  /// on a retry. See the library comment for what happens when the plaintext is gone.
  IssuedTaskSecrets issueSecrets(String taskId) {
    if (receiptRecorded(taskId)) {
      throw const ProtocolViolation(
        ProtocolErrorCode.invalidState,
        'the credentials for this task were already delivered and confirmed; they are not '
        're-delivered',
      );
    }

    final IssuedTaskSecrets? pending = _pending[taskId];
    if (pending != null) {
      return pending;
    }

    final bool alreadyMinted =
        _readDigest(taskId, StorageSchema.credentialKindResume) != null ||
        _readDigest(taskId, StorageSchema.credentialKindCompletionQuery) !=
            null;
    if (alreadyMinted) {
      // A digest exists and no plaintext does, so this process cannot reproduce what the
      // client may already hold. Minting a second pair would invalidate the first silently.
      throw const ProtocolViolation(
        ProtocolErrorCode.invalidState,
        'the credentials for this task were issued before this process started and cannot '
        'be re-delivered; the task must be approved again',
      );
    }

    final IssuedTaskSecrets minted = IssuedTaskSecrets(
      taskResumeSecret: _newSecret(),
      completionQuerySecret: _newSecret(),
    );
    final int moment = now();
    database.transaction(() {
      _writeDigest(
        taskId,
        StorageSchema.credentialKindResume,
        minted.taskResumeSecret,
        moment,
        expiresAtMillis: null,
      );
      _writeDigest(
        taskId,
        StorageSchema.credentialKindCompletionQuery,
        minted.completionQuerySecret,
        moment,
        expiresAtMillis: null,
      );
    });

    if (_pending.length >= maxPendingSecrets) {
      _pending.remove(_pending.keys.first);
    }
    _pending[taskId] = minted;
    return minted;
  }

  /// The pending pair for [taskId], or null when it is not re-deliverable here.
  IssuedTaskSecrets? pendingSecrets(String taskId) => _pending[taskId];

  /// Whether the client confirmed it stored the credentials.
  bool receiptRecorded(String taskId) =>
      _readDigest(taskId, StorageSchema.credentialKindResume) != null &&
      _readReceipt(taskId);

  /// Records the client's confirmation and drops the plaintext.
  ///
  /// Dropping it is the point: §3 says the recoverable plaintext is removed once the receipt
  /// arrives, and the digest is all that is needed to verify the secret afterwards.
  void recordReceipt(String taskId) {
    if (!_hasCredentialRow(taskId, StorageSchema.credentialKindResume)) {
      throw const ProtocolViolation(
        ProtocolErrorCode.invalidState,
        'no credentials have been issued for this task, so there is no receipt to record',
      );
    }
    database.transaction(() {
      database.db.execute(
        'UPDATE ${StorageSchema.taskAuthorizationsTable} SET receipt_at = ? '
        'WHERE transfer_id = ?;',
        <Object?>[now(), taskId],
      );
    });
    _pending.remove(taskId);
  }

  /// Whether [secret] is the task's resume secret.
  ///
  /// Compares digests, never the secrets themselves, and never renders either.
  bool resumeSecretMatches(String taskId, String secret) =>
      _matches(taskId, StorageSchema.credentialKindResume, secret);

  /// Whether [secret] is the task's completion-query secret.
  bool completionQuerySecretMatches(String taskId, String secret) =>
      _matches(taskId, StorageSchema.credentialKindCompletionQuery, secret);

  /// Resolves a presented completion-query secret, or null when it matches nothing.
  ///
  /// §7's `status` row accepts "受限完成查询令牌", and §9 bounds what it may return: "受限完成凭证
  /// 只返回终态、文件ID及摘要确认，不返回路径、清单、密钥或文件数据". Resolving it here is what
  /// lets that credential be authenticated at all; enforcing the bound is the endpoint's job,
  /// which is why it resolves to its own grant kind rather than to a task token.
  TaskAccessLookup? lookupCompletionQuery(String secret) {
    if (secret.isEmpty) {
      return null;
    }
    final ResultSet rows = database.db.select(
      'SELECT transfer_id FROM ${StorageSchema.taskCredentialsTable} '
      'WHERE kind = ? AND digest = ?;',
      <Object?>[
        StorageSchema.credentialKindCompletionQuery,
        credentialFingerprint(secret),
      ],
    );
    return rows.isEmpty
        ? null
        : TaskAccessLookup(transferId: rows.first['transfer_id'] as String);
  }

  /// Mints a task access token for [taskId] and returns the plaintext once.
  ///
  /// §7 gives the token an 1800-second life, the same as a session token. It is persisted as a
  /// digest so a restart does not force every in-flight task to re-resume, which §9 would
  /// answer by refusing to advance the generation again.
  IssuedTaskAccessToken issueTaskAccessToken(
    String taskId, {
    int? ttlSeconds,
    int? leaseEpoch,
  }) {
    final int ttl = ttlSeconds ?? ProtocolLimits.sessionAccessTokenTtlSeconds;
    final String token = _newSecret();
    final int moment = now();
    final int expiresAt = moment + ttl * 1000;
    database.transaction(() {
      // One live token per task: issuing a new one revokes the previous, so a re-resume does
      // not leave an older token able to write under a superseded generation.
      database.db.execute(
        'DELETE FROM ${StorageSchema.taskCredentialsTable} WHERE transfer_id = ? '
        'AND kind = ?;',
        <Object?>[taskId, StorageSchema.credentialKindTaskAccess],
      );
      _writeDigest(
        taskId,
        StorageSchema.credentialKindTaskAccess,
        token,
        moment,
        expiresAtMillis: expiresAt,
      );
    });
    _lastLeaseEpoch[taskId] = leaseEpoch;
    return IssuedTaskAccessToken(token: token, expiresAtMillis: expiresAt);
  }

  /// The generation a task access token was issued for, when this process issued it.
  ///
  /// §7 makes `leaseEpoch` a property of the resume grant, and §8 requires the generation to
  /// travel with every chunk request. Keeping it next to the token means the authenticator can
  /// hand the authoriser a direction and generation without a second lookup.
  final Map<String, int?> _lastLeaseEpoch = <String, int?>{};

  int? leaseEpochForTokenOwner(String taskId) => _lastLeaseEpoch[taskId];

  /// Resolves a presented token, or null when it is unknown or expired.
  ///
  /// Null covers every rejection the caller must not distinguish between - unknown, expired,
  /// revoked, belonging to a re-approved task - because §7 answers all of them the same way.
  TaskAccessLookup? lookupTaskAccess(String token) {
    if (token.isEmpty) {
      return null;
    }
    final String digest = credentialFingerprint(token);
    final ResultSet rows = database.db.select(
      'SELECT transfer_id, expires_at FROM ${StorageSchema.taskCredentialsTable} '
      'WHERE kind = ? AND digest = ?;',
      <Object?>[StorageSchema.credentialKindTaskAccess, digest],
    );
    if (rows.isEmpty) {
      return null;
    }
    final Row row = rows.first;
    final int? expiresAt = row['expires_at'] as int?;
    if (expiresAt != null && expiresAt <= now()) {
      return null;
    }
    return TaskAccessLookup(transferId: row['transfer_id'] as String);
  }

  /// Removes every credential of [taskId], for a cancel or a terminal failure.
  void revokeAll(String taskId) {
    database.transaction(() {
      database.db.execute(
        'DELETE FROM ${StorageSchema.taskCredentialsTable} WHERE transfer_id = ?;',
        <Object?>[taskId],
      );
    });
    _pending.remove(taskId);
    _lastLeaseEpoch.remove(taskId);
  }

  bool _matches(String taskId, String kind, String secret) {
    final String? stored = _readDigest(taskId, kind);
    if (stored == null) {
      return false;
    }
    return stored == credentialFingerprint(secret);
  }

  bool _readReceipt(String taskId) {
    final ResultSet rows = database.db.select(
      'SELECT receipt_at FROM ${StorageSchema.taskAuthorizationsTable} '
      'WHERE transfer_id = ?;',
      <Object?>[taskId],
    );
    return rows.isNotEmpty && rows.first['receipt_at'] != null;
  }

  bool _hasCredentialRow(String taskId, String kind) =>
      _readDigest(taskId, kind) != null;

  String? _readDigest(String taskId, String kind) {
    final ResultSet rows = database.db.select(
      'SELECT digest FROM ${StorageSchema.taskCredentialsTable} '
      'WHERE transfer_id = ? AND kind = ?;',
      <Object?>[taskId, kind],
    );
    return rows.isEmpty ? null : rows.first['digest'] as String;
  }

  void _writeDigest(
    String taskId,
    String kind,
    String secret,
    int moment, {
    required int? expiresAtMillis,
  }) {
    database.db.execute(
      'INSERT INTO ${StorageSchema.taskCredentialsTable} (transfer_id, kind, digest, '
      'issued_at, expires_at, consumed_at) VALUES (?, ?, ?, ?, ?, NULL) '
      'ON CONFLICT(transfer_id, kind) DO UPDATE SET digest = excluded.digest, '
      'issued_at = excluded.issued_at, expires_at = excluded.expires_at, '
      'consumed_at = NULL;',
      <Object?>[
        taskId,
        kind,
        credentialFingerprint(secret),
        moment,
        expiresAtMillis,
      ],
    );
  }

  /// A 32-byte secret in §4's canonical unpadded base64url form.
  ///
  /// §3 requires at least 128 bits of randomness and §4 fixes the encoding; reusing the pairing
  /// layer's generator keeps one source of platform CSPRNG bytes rather than a second.
  static String _newSecret() => encodeBase64UrlNoPadding(
    generateSecureRandomBytes(ProtocolLimits.accessTokenBytes),
  );
}
