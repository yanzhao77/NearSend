import 'dart:convert';
import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

import 'package:nearsend/core/security/installation_identity.dart';
import 'package:nearsend/core/security/tls_identity.dart';
import 'package:nearsend/core/storage/near_send_database.dart';
import 'package:nearsend/core/storage/storage_schema.dart';

class InstallationIdentityMetadataRepository {
  InstallationIdentityMetadataRepository(
    this.database, {
    this.now = _systemNow,
  });

  final NearSendDatabase database;
  final int Function() now;

  static int _systemNow() => DateTime.now().millisecondsSinceEpoch;

  /// Whether this database has already been bound to a platform-protected identity.
  ///
  /// A pre-v9 database legitimately has no identity row and must be allowed to create its first
  /// stable identity during upgrade. Once the row exists, a missing secure payload means identity
  /// recovery is required and must not be mistaken for a first launch.
  static bool existsAtPath(String path) {
    if (!File(path).existsSync()) return false;
    final Database database = sqlite3.open(path, mode: OpenMode.readOnly);
    try {
      final ResultSet table = database.select(
        "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ? LIMIT 1;",
        <Object?>[StorageSchema.localIdentityTable],
      );
      if (table.isEmpty) return false;
      return database
          .select(
            'SELECT 1 FROM ${StorageSchema.localIdentityTable} WHERE id = 1 LIMIT 1;',
          )
          .isNotEmpty;
    } finally {
      database.close();
    }
  }

  void ensureMatches(
    DeviceIdentity identity, {
    String keyReference = 'platform-secure-identity-v1',
  }) {
    final ResultSet rows = database.db.select(
      'SELECT device_id, public_key FROM ${StorageSchema.localIdentityTable} '
      'WHERE id = 1;',
    );
    final String publicKey = base64.encode(identity.publicKeyDer);
    if (rows.isEmpty) {
      database.db.execute(
        'INSERT INTO ${StorageSchema.localIdentityTable} '
        '(id, device_id, public_key, key_reference, format_version, created_at) '
        'VALUES (1, ?, ?, ?, ?, ?);',
        <Object?>[
          identity.deviceId,
          publicKey,
          keyReference,
          InstallationIdentity.currentVersion,
          now(),
        ],
      );
      return;
    }
    final Row row = rows.first;
    if (row['device_id'] != identity.deviceId ||
        row['public_key'] != publicKey) {
      throw const IdentityRecoveryRequired(
        'the secure identity does not match the local identity metadata',
      );
    }
  }
}
