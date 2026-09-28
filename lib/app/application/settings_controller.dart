import 'package:flutter/foundation.dart';

import 'package:nearsend/app/application/app_settings_repository.dart';
import 'package:nearsend/platform/storage_location.dart';

class SettingsController extends ChangeNotifier {
  AppSettingsRepository? _repository;
  String _defaultDeviceName = 'NearSend';
  AppSettings _settings = const AppSettings();
  Object? _error;

  AppSettings get settings => _settings;
  Object? get error => _error;
  bool get isPersisted => _repository != null;

  void attach(
    AppSettingsRepository? repository, {
    String defaultDeviceName = 'NearSend',
  }) {
    _repository = repository;
    _defaultDeviceName = defaultDeviceName;
    if (repository == null) {
      _settings = const AppSettings();
      _error = null;
    } else {
      _read();
    }
    notifyListeners();
  }

  void update(AppSettings settings) {
    _settings = settings;
    _error = null;
    final AppSettingsRepository? repository = _repository;
    if (repository != null) {
      try {
        repository.write(settings);
      } on Object catch (error) {
        _error = error;
      }
    }
    notifyListeners();
  }

  void updateDeviceName(String value) =>
      update(_settings.copyWith(deviceName: value, deviceNameIsCustom: true));

  void updateDefaultReceiveLocation(StorageLocationRef? value) => update(
    value == null
        ? _settings.copyWith(clearDefaultReceiveLocation: true)
        : _settings.copyWith(defaultReceiveLocation: value),
  );

  void _read() {
    try {
      _settings = _repository!.read(defaultDeviceName: _defaultDeviceName);
      _error = null;
    } on Object catch (error) {
      _error = error;
    }
  }
}
