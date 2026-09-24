import 'package:nearsend/core/storage/near_send_database.dart';
import 'package:nearsend/core/storage/storage_schema.dart';
import 'package:nearsend/platform/storage_location.dart';

/// The user-editable presentation settings that may be persisted locally.
///
/// This model intentionally has no credential, token, key or file-content field. Pairing and
/// resume secrets are owned by the security/storage layers and are never part of the settings API.
enum AppThemePreference { system, light, dark }

class AppSettings {
  const AppSettings({
    this.deviceName = 'NearSend',
    this.defaultReceiveLocation,
    this.themePreference = AppThemePreference.system,
    this.reduceMotion = false,
    this.defaultReceiveLocationNeedsRepair = false,
  });

  final String deviceName;
  final StorageLocationRef? defaultReceiveLocation;
  final bool defaultReceiveLocationNeedsRepair;
  final AppThemePreference themePreference;
  final bool reduceMotion;

  AppSettings copyWith({
    String? deviceName,
    StorageLocationRef? defaultReceiveLocation,
    bool clearDefaultReceiveLocation = false,
    AppThemePreference? themePreference,
    bool? reduceMotion,
    bool? defaultReceiveLocationNeedsRepair,
  }) {
    return AppSettings(
      deviceName: deviceName ?? this.deviceName,
      defaultReceiveLocation: clearDefaultReceiveLocation
          ? null
          : defaultReceiveLocation ?? this.defaultReceiveLocation,
      themePreference: themePreference ?? this.themePreference,
      reduceMotion: reduceMotion ?? this.reduceMotion,
      defaultReceiveLocationNeedsRepair:
          defaultReceiveLocationNeedsRepair ??
          (defaultReceiveLocation != null || clearDefaultReceiveLocation
              ? false
              : this.defaultReceiveLocationNeedsRepair),
    );
  }
}

/// SQLite-backed storage for non-secret application preferences.
class AppSettingsRepository {
  AppSettingsRepository(this.database, {this.now = _systemNow});

  final NearSendDatabase database;
  final int Function() now;

  static int _systemNow() => DateTime.now().millisecondsSinceEpoch;

  static const String _deviceName = 'device_name';
  static const String _defaultReceiveLocation = 'default_receive_location';
  static const String _themePreference = 'theme_preference';
  static const String _reduceMotion = 'reduce_motion';

  AppSettings read() {
    final Map<String, String> values = <String, String>{};
    final rows = database.db.select(
      'SELECT setting_key, setting_value FROM ${StorageSchema.appSettingsTable};',
    );
    for (final row in rows) {
      final Object? key = row['setting_key'];
      final Object? value = row['setting_value'];
      if (key is String && value is String && _allowedKeys.contains(key)) {
        values[key] = value;
      }
    }

    final String name = values[_deviceName]?.trim() ?? '';
    final AppThemePreference theme = switch (values[_themePreference]) {
      'light' => AppThemePreference.light,
      'dark' => AppThemePreference.dark,
      _ => AppThemePreference.system,
    };
    final String? storedLocation = _nonEmpty(values[_defaultReceiveLocation]);
    StorageLocationRef? location;
    bool locationNeedsRepair = false;
    if (storedLocation != null) {
      try {
        location = StorageLocationRef.fromPersistedValue(storedLocation);
        if (!storedLocation.trim().startsWith('{')) {
          _upsert(_defaultReceiveLocation, location.toPersistedValue(), now());
        }
      } on FormatException {
        locationNeedsRepair = true;
      }
    }
    return AppSettings(
      deviceName: name.isEmpty ? 'NearSend' : name,
      defaultReceiveLocation: location,
      defaultReceiveLocationNeedsRepair: locationNeedsRepair,
      themePreference: theme,
      reduceMotion: values[_reduceMotion] == 'true',
    );
  }

  void write(AppSettings settings) {
    final String deviceName = settings.deviceName.trim();
    if (deviceName.isEmpty) {
      throw ArgumentError.value(
        settings.deviceName,
        'deviceName',
        'must not be empty',
      );
    }
    final String? receiveLocation = settings.defaultReceiveLocation
        ?.toPersistedValue();
    final int moment = now();
    database.transaction(() {
      _upsert(_deviceName, deviceName, moment);
      if (receiveLocation == null) {
        database.db.execute(
          'DELETE FROM ${StorageSchema.appSettingsTable} WHERE setting_key = ?;',
          <Object?>[_defaultReceiveLocation],
        );
      } else {
        _upsert(_defaultReceiveLocation, receiveLocation, moment);
      }
      _upsert(_themePreference, settings.themePreference.name, moment);
      _upsert(_reduceMotion, settings.reduceMotion.toString(), moment);
    });
  }

  static const Set<String> _allowedKeys = <String>{
    _deviceName,
    _defaultReceiveLocation,
    _themePreference,
    _reduceMotion,
  };

  void _upsert(String key, String value, int moment) {
    database.db.execute(
      'INSERT INTO ${StorageSchema.appSettingsTable} '
      '(setting_key, setting_value, updated_at) VALUES (?, ?, ?) '
      'ON CONFLICT(setting_key) DO UPDATE SET setting_value = excluded.setting_value, '
      'updated_at = excluded.updated_at;',
      <Object?>[key, value, moment],
    );
  }

  static String? _nonEmpty(String? value) {
    final String? trimmed = value?.trim();
    return trimmed == null || trimmed.isEmpty ? null : trimmed;
  }
}
