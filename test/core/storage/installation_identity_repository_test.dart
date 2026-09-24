import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

import 'package:nearsend/core/security/installation_identity.dart';
import 'package:nearsend/core/security/tls_identity.dart';
import 'package:nearsend/core/storage/installation_identity_repository.dart';
import 'package:nearsend/core/storage/near_send_database.dart';
import 'package:nearsend/core/storage/storage_schema.dart';

void main() {
  late Directory root;
  late NearSendDatabase database;

  setUp(() {
    root = Directory.systemTemp.createTempSync('nearsend-identity-metadata-');
    database = NearSendDatabase.open(
      path: '${root.path}${Platform.pathSeparator}identity.db',
    );
  });

  tearDown(() {
    database.close();
    root.deleteSync(recursive: true);
  });

  test('public metadata is inserted once and never contains a private key', () {
    final DeviceIdentity identity = generateDeviceIdentity();
    final InstallationIdentityMetadataRepository repository =
        InstallationIdentityMetadataRepository(database, now: () => 42);

    repository.ensureMatches(identity);
    repository.ensureMatches(identity);

    final Row row = database.db
        .select('SELECT * FROM ${StorageSchema.localIdentityTable};')
        .single;
    expect(row['device_id'], identity.deviceId);
    expect(row['public_key'], isNotEmpty);
    expect(row['key_reference'], 'platform-secure-identity-v1');
    expect(row['created_at'], 42);
    expect(
      row.values.any(
        (Object? value) => value.toString().contains(
          identity.privateKeyPkcs8Der.take(12).join(','),
        ),
      ),
      isFalse,
    );
  });

  test(
    'metadata probe distinguishes an upgraded database from a bound one',
    () {
      final String path = '${root.path}${Platform.pathSeparator}identity.db';
      expect(
        InstallationIdentityMetadataRepository.existsAtPath(path),
        isFalse,
      );

      InstallationIdentityMetadataRepository(database)
          .ensureMatches(generateDeviceIdentity());

      expect(InstallationIdentityMetadataRepository.existsAtPath(path), isTrue);
    },
  );

  test('a different secure identity cannot adopt the existing database', () {
    final InstallationIdentityMetadataRepository repository =
        InstallationIdentityMetadataRepository(database);
    repository.ensureMatches(generateDeviceIdentity());

    expect(
      () => repository.ensureMatches(generateDeviceIdentity()),
      throwsA(isA<IdentityRecoveryRequired>()),
    );
  });
}
