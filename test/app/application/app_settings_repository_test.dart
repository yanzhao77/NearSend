import 'package:flutter_test/flutter_test.dart';

import 'package:nearsend/app/application/app_settings_repository.dart';
import 'package:nearsend/core/storage/near_send_database.dart';
import 'package:nearsend/core/storage/storage_schema.dart';
import 'package:nearsend/platform/storage_location.dart';

void main() {
  late NearSendDatabase database;

  setUp(() {
    database = NearSendDatabase.open(path: NearSendDatabase.inMemoryPath);
  });

  tearDown(() => database.close());

  test('persists only non-secret settings', () {
    final AppSettingsRepository repository = AppSettingsRepository(
      database,
      now: () => 42,
    );
    repository.write(
      const AppSettings(
        deviceName: '办公室电脑',
        defaultReceiveLocation: StorageLocationRef(
          kind: StorageLocationKind.androidDocumentTree,
          opaqueValue: 'content://provider/tree/receive',
          displayName: 'Downloads',
          permissionState: StoragePermissionState.granted,
        ),
        themePreference: AppThemePreference.dark,
        reduceMotion: true,
      ),
    );

    final AppSettings restored = repository.read();
    expect(restored.deviceName, '办公室电脑');
    expect(
      restored.defaultReceiveLocation,
      const StorageLocationRef(
        kind: StorageLocationKind.androidDocumentTree,
        opaqueValue: 'content://provider/tree/receive',
        displayName: 'Downloads',
      ),
      reason: 'runtime permission observations are not persisted as promises',
    );
    expect(restored.themePreference, AppThemePreference.dark);
    expect(restored.reduceMotion, isTrue);

    final rows = database.db.select(
      'SELECT setting_key FROM ${StorageSchema.appSettingsTable} ORDER BY setting_key;',
    );
    expect(
      [for (final row in rows) row['setting_key']],
      containsAll(<String>[
        'device_name',
        'default_receive_location',
        'theme_preference',
        'reduce_motion',
      ]),
    );
    expect(rows.length, 4);
    expect(
      database.db.select(
        "SELECT name FROM sqlite_master WHERE name LIKE '%token%' OR name LIKE '%private%';",
      ),
      isEmpty,
      reason:
          'credentials and private keys do not belong in the settings schema',
    );
  });

  test('clearing the default location removes the stored value', () {
    final AppSettingsRepository repository = AppSettingsRepository(database);
    repository.write(
      const AppSettings(
        defaultReceiveLocation: StorageLocationRef(
          kind: StorageLocationKind.nativeDirectory,
          opaqueValue: '/tmp/location',
          displayName: 'location',
        ),
      ),
    );
    repository.write(const AppSettings());

    expect(repository.read().defaultReceiveLocation, isNull);
  });

  test('migrates a legacy path value to versioned JSON on read', () {
    database.db.execute(
      'INSERT INTO ${StorageSchema.appSettingsTable} '
      '(setting_key, setting_value, updated_at) VALUES (?, ?, ?);',
      <Object?>['default_receive_location', '/legacy/Downloads', 1],
    );
    final AppSettings settings = AppSettingsRepository(database).read();

    expect(
      settings.defaultReceiveLocation?.kind,
      StorageLocationKind.nativeDirectory,
    );
    expect(settings.defaultReceiveLocation?.opaqueValue, '/legacy/Downloads');
    final String stored =
        database.db.select(
              'SELECT setting_value FROM ${StorageSchema.appSettingsTable} '
              'WHERE setting_key = ?;',
              <Object?>['default_receive_location'],
            ).single['setting_value']
            as String;
    expect(stored, startsWith('{'));
  });

  test('preserves malformed location data and asks for repair', () {
    database.db.execute(
      'INSERT INTO ${StorageSchema.appSettingsTable} '
      '(setting_key, setting_value, updated_at) VALUES (?, ?, ?);',
      <Object?>[
        'default_receive_location',
        '{"schemaVersion":999,"kind":"nativeDirectory"}',
        1,
      ],
    );
    final AppSettings settings = AppSettingsRepository(database).read();

    expect(settings.defaultReceiveLocation, isNull);
    expect(settings.defaultReceiveLocationNeedsRepair, isTrue);
    expect(
      database.db.select(
        'SELECT setting_value FROM ${StorageSchema.appSettingsTable} '
        'WHERE setting_key = ?;',
        <Object?>['default_receive_location'],
      ).single['setting_value'],
      '{"schemaVersion":999,"kind":"nativeDirectory"}',
    );
  });
}
