/// Peer identity and user authorisation.
///
/// The rule this file exists to enforce is from `AGENTS.md` §5 and protocol §9: when a
/// device's identity fingerprint changes, or its credentials are lost, or it is
/// reinstalled, the peer must **re-pair and be authorised by the user again**. Silently
/// trusting a new fingerprint would let anyone who can take over a peer's address inherit
/// its authorisation.
///
/// So [trustFor] does not answer a boolean. It distinguishes "authorised", "never seen",
/// "explicitly revoked" and "**the fingerprint changed**", because the last one has to
/// start a re-pairing flow rather than fail a request.
///
/// ## What is deliberately absent
///
/// There is no column, field or method for a token, key or recovery secret. `AGENTS.md`
/// §5 keeps those in platform secure storage. This table holds a display name, an identity
/// fingerprint and an authorisation flag, and nothing whose value would be dangerous to
/// read.
library;

import 'package:sqlite3/sqlite3.dart';

import 'package:nearsend/core/storage/near_send_database.dart';
import 'package:nearsend/core/storage/storage_failure.dart';

/// How much a peer can be trusted right now.
enum PeerTrust {
  /// No record: this device has never been paired.
  unknown,

  /// The stored fingerprint matches and the user has authorised it.
  authorized,

  /// A record exists but the presented fingerprint differs.
  ///
  /// The caller must start a re-pairing flow and obtain fresh user authorisation. It must
  /// **not** update the stored fingerprint on its own.
  fingerprintChanged,

  /// The user revoked this peer.
  revoked,
}

class PeerRecord {
  const PeerRecord({
    required this.peerId,
    required this.identityFingerprint,
    required this.trust,
    this.displayName,
    this.identityPublicKey,
    this.platform,
    this.pairedAt,
    this.lastSeenAt,
    this.lastVerifiedAt,
  });

  final String peerId;
  final String? displayName;
  final String identityFingerprint;
  final String? identityPublicKey;
  final String? platform;
  final PeerTrust trust;
  final int? pairedAt;
  final int? lastSeenAt;
  final int? lastVerifiedAt;
}

/// Stores peers and their authorisation state.
class PeerRepository {
  PeerRepository(this.database, {this.now = _systemNow});

  final NearSendDatabase database;

  /// Clock injection so tests do not depend on wall time.
  final int Function() now;

  static int _systemNow() => DateTime.now().millisecondsSinceEpoch;

  /// Evaluates the trust a presented [identityFingerprint] deserves.
  ///
  /// Note that a fingerprint mismatch never mutates anything: the caller decides whether
  /// to open a re-pairing flow, and only [recordUserAuthorization] changes stored trust.
  PeerTrust trustFor({
    required String peerId,
    required String identityFingerprint,
  }) {
    final ResultSet rows = database.db.select(
      'SELECT identity_fingerprint, trust_state FROM peers WHERE peer_id = ?;',
      <Object?>[peerId],
    );
    if (rows.isEmpty) {
      return PeerTrust.unknown;
    }

    final Row row = rows.first;
    final String stored = row['identity_fingerprint'] as String;
    if (stored != identityFingerprint) {
      return PeerTrust.fingerprintChanged;
    }
    return row['trust_state'] == 'authorized'
        ? PeerTrust.authorized
        : PeerTrust.revoked;
  }

  /// The fingerprint currently stored for a peer, or null when unknown.
  ///
  /// Exposed so a diagnostics view can show a short identifier; the value is a
  /// certificate digest, not a secret.
  String? storedFingerprint(String peerId) {
    final ResultSet rows = database.db.select(
      'SELECT identity_fingerprint FROM peers WHERE peer_id = ?;',
      <Object?>[peerId],
    );
    return rows.isEmpty ? null : rows.first['identity_fingerprint'] as String;
  }

  /// Records that the **user** authorised this peer at this fingerprint.
  ///
  /// Named for the user's decision on purpose: calling it is an assertion that the user
  /// approved this identity, which is what §5 requires after a fingerprint change. An
  /// implementation that called it automatically on first contact would defeat the rule.
  void recordUserAuthorization({
    required String peerId,
    required String identityFingerprint,
    String? displayName,
    String? identityPublicKey,
    String? platform,
  }) {
    final int moment = now();
    database.transaction(() {
      database.db.execute(
        'INSERT INTO peers (peer_id, display_name, identity_fingerprint, authorized, '
        'last_seen_at, identity_public_key, platform, trust_state, paired_at, '
        'last_verified_at) VALUES (?, ?, ?, 1, ?, ?, ?, \'authorized\', ?, ?) '
        'ON CONFLICT(peer_id) DO UPDATE SET identity_fingerprint = excluded.'
        'identity_fingerprint, identity_public_key = COALESCE(excluded.identity_public_key, '
        'peers.identity_public_key), platform = COALESCE(excluded.platform, peers.platform), '
        'authorized = 1, trust_state = \'authorized\', paired_at = excluded.paired_at, '
        'last_seen_at = excluded.last_seen_at, last_verified_at = excluded.last_verified_at, '
        'display_name = COALESCE(excluded.display_name, peers.display_name);',
        <Object?>[
          peerId,
          displayName,
          identityFingerprint,
          moment,
          identityPublicKey,
          platform,
          moment,
          moment,
        ],
      );
    });
  }

  /// Withdraws authorisation without forgetting the identity.
  ///
  /// The row is kept so that a later presentation of the same fingerprint reports
  /// [PeerTrust.revoked] rather than [PeerTrust.unknown]; the distinction matters because
  /// "we revoked this device" and "we have never seen it" lead to different UI.
  void revoke(String peerId) {
    database.transaction(() {
      database.db.execute(
        "UPDATE peers SET authorized = 0, trust_state = 'revoked', "
        'last_seen_at = ? WHERE peer_id = ?;',
        <Object?>[now(), peerId],
      );
      if (database.db.updatedRows == 0) {
        throw StorageException(
          StorageFailureCode.manifestMismatch,
          'cannot revoke unknown peer $peerId',
        );
      }
    });
  }

  /// Records that a peer was seen, without changing its authorisation.
  void touch(String peerId) {
    database.transaction(() {
      database.db.execute(
        'UPDATE peers SET last_seen_at = ? WHERE peer_id = ?;',
        <Object?>[now(), peerId],
      );
    });
  }

  /// Records a fresh authenticated challenge, never an advertisement or matching name.
  bool recordVerifiedPresence({
    required String peerId,
    required String identityFingerprint,
  }) {
    if (trustFor(peerId: peerId, identityFingerprint: identityFingerprint) !=
        PeerTrust.authorized) {
      return false;
    }
    final int moment = now();
    database.transaction(() {
      database.db.execute(
        'UPDATE peers SET last_seen_at = ?, last_verified_at = ? '
        'WHERE peer_id = ?;',
        <Object?>[moment, moment, peerId],
      );
    });
    return true;
  }

  List<PeerRecord> history() {
    final ResultSet rows = database.db.select(
      'SELECT peer_id, display_name, identity_fingerprint, identity_public_key, '
      'platform, trust_state, paired_at, last_seen_at, last_verified_at FROM peers '
      'ORDER BY COALESCE(last_seen_at, 0) DESC, peer_id;',
    );
    return <PeerRecord>[
      for (final Row row in rows)
        PeerRecord(
          peerId: row['peer_id'] as String,
          displayName: row['display_name'] as String?,
          identityFingerprint: row['identity_fingerprint'] as String,
          identityPublicKey: row['identity_public_key'] as String?,
          platform: row['platform'] as String?,
          trust: row['trust_state'] == 'authorized'
              ? PeerTrust.authorized
              : PeerTrust.revoked,
          pairedAt: row['paired_at'] as int?,
          lastSeenAt: row['last_seen_at'] as int?,
          lastVerifiedAt: row['last_verified_at'] as int?,
        ),
    ];
  }
}
