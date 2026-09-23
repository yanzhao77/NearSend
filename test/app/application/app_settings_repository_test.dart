import 'package:flutter_test/flutter_test.dart';

import 'package:nearsend/app/application/app_settings_repository.dart';
import 'package:nearsend/core/storage/near_send_database.dart';
import 'package:nearsend/core/storage/storage_schema.dart';

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
        defaultReceiveLocation: 'opaque://receive-location',
        themePreference: AppThemePreference.dark,
        reduceMotion: true,
      ),
    );

    final AppSettings restored = repository.read();
    expect(restored.deviceName, '办公室电脑');
    expect(restored.defaultReceiveLocation, 'opaque://receive-location');
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
      const AppSettings(defaultReceiveLocation: 'opaque://location'),
    );
    repository.write(const AppSettings());

    expect(repository.read().defaultReceiveLocation, isNull);
  });
}
