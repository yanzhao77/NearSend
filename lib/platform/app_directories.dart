/// Where this application keeps its own files, on each platform.
///
/// `AGENTS.md` §9 puts a platform's own storage behind an adapter rather than letting application
/// code assume a path exists, and the node's database is exactly such a case: it has to live in a
/// location the application owns, that the user did not choose, and that another application cannot
/// read. There is no Dart API that answers "where may I write my private data" - `Directory.system
/// Temp` answers a different question (a cache the system may clear, and on some platforms a shared
/// one), and putting a SQLite database in a shared temporary directory would be both a durability
/// and a privacy decision made by accident.
///
/// ## Why it is not a dependency
///
/// `path_provider` answers this question and is the obvious candidate. It is not used here because
/// adding it would put a plugin's platform code into the two build paths this project must be able
/// to verify, and the answer on the two platforms in scope is short: on Android the application's
/// own `filesDir` over the channel `MainActivity` already serves, and on Windows the
/// `%LOCALAPPDATA%` directory this project already owns a folder in. A dependency whose whole
/// contribution is four lines is a liability rather than a saving - `AGENTS.md` §5 asks for a
/// stated purpose, and this file states it instead.
///
/// ## What it deliberately does not do
///
/// It does not create the directory, and it does not fall back to a shared location when the
/// private one cannot be determined. Creating is the caller's step (the node creates its root), and
/// a silent fallback would be a database in a place the user never agreed to - so a platform that
/// cannot answer gets a failure, and the node records it as a failed start rather than starting
/// somewhere else.
library;

import 'dart:io';

import 'package:flutter/services.dart';

import 'package:nearsend/platform/android_file_gateway.dart';

/// Resolves the directory this application owns on the current platform.
class AppDirectories {
  AppDirectories({MethodChannel? channel, this.environment, this.isAndroid})
    : _channel = channel ?? const MethodChannel(channelName);

  /// The channel `MainActivity` serves. One definition per side; a rename on either shows up as a
  /// missing-plugin failure on the first call rather than as silence.
  static const String channelName = MethodChannelAndroidFileGateway.channelName;

  /// The method Android answers with its `filesDir`.
  static const String androidMethod = 'applicationDirectory';

  /// The folder name used under a desktop data directory.
  static const String applicationFolderName = 'NearSend';

  final MethodChannel _channel;

  /// The environment to read, or null to read the process's own.
  ///
  /// Injectable so a test can state `%LOCALAPPDATA%` rather than depend on the machine it runs on.
  final Map<String, String>? environment;

  /// Whether to take the Android path, or null to ask the platform.
  ///
  /// Injectable for the same reason: the Android branch has to be exercisable from a desktop test
  /// host, which is where this project's tests run.
  final bool? isAndroid;

  /// The directory the application owns, as an absolute path.
  ///
  /// Throws [PlatformFileFailure] when the platform cannot name one, which the caller must record
  /// as a failure to start rather than work around.
  Future<String> resolve() async {
    if (isAndroid ?? Platform.isAndroid) {
      final Object? path = await _channel.invokeMethod<Object?>(androidMethod);
      if (path is! String || path.isEmpty) {
        throw const PlatformFileFailure(
          'the platform reported no application directory',
        );
      }
      return path;
    }

    final Map<String, String> resolvedEnvironment =
        environment ?? Platform.environment;
    // `LOCALAPPDATA` first: it is per-machine and never roams, which is right for a database and
    // a staging area. `APPDATA` is the roaming one and is only a fallback, because a roaming
    // profile would carry a device's transfer state to another machine.
    final String? base = _firstNonEmpty(<String?>[
      resolvedEnvironment['LOCALAPPDATA'],
      resolvedEnvironment['APPDATA'],
    ]);
    if (base == null) {
      throw const PlatformFileFailure(
        'no application data directory is defined for this platform',
      );
    }
    return '$base${Platform.pathSeparator}$applicationFolderName';
  }

  static String? _firstNonEmpty(List<String?> values) {
    for (final String? value in values) {
      if (value != null && value.isNotEmpty) {
        return value;
      }
    }
    return null;
  }
}
