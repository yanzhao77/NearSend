import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nearsend/platform/android_file_gateway.dart';
import 'package:nearsend/platform/app_directories.dart';

/// Where the node is allowed to keep its database.
///
/// This looks like four lines of path joining and is not: the directory is the one place in this
/// application that has to be private, persistent and not chosen by the user, and both of the
/// failure modes below end with a **refusal** rather than a fallback, because a database written to
/// a shared or cache location is a durability and privacy decision nobody made on purpose.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('desktop', () {
    test('uses the per-machine data directory, not the roaming one', () async {
      final AppDirectories subject = AppDirectories(
        isAndroid: false,
        environment: <String, String>{
          'LOCALAPPDATA': r'C:\Users\someone\AppData\Local',
          'APPDATA': r'C:\Users\someone\AppData\Roaming',
        },
      );

      expect(
        await subject.resolve(),
        '${r'C:\Users\someone\AppData\Local'}${Platform.pathSeparator}'
        '${AppDirectories.applicationFolderName}',
        reason:
            'a roaming profile would carry one machine\'s transfer state to another, which is '
            'the wrong thing for a database and a staging area',
      );
    });

    test(
      'falls back to the roaming directory when there is no local one',
      () async {
        final AppDirectories subject = AppDirectories(
          isAndroid: false,
          environment: <String, String>{
            'APPDATA': '${Platform.pathSeparator}roaming',
          },
        );

        expect(
          await subject.resolve(),
          '${Platform.pathSeparator}roaming${Platform.pathSeparator}'
          '${AppDirectories.applicationFolderName}',
        );
      },
    );

    test('refuses when the platform names no data directory', () async {
      final AppDirectories subject = AppDirectories(
        isAndroid: false,
        environment: const <String, String>{},
      );

      await expectLater(
        subject.resolve(),
        throwsA(isA<PlatformFileFailure>()),
        reason:
            'a fallback to a temporary or shared directory would be a private database in a '
            'place the user never agreed to',
      );
    });
  });

  group('android', () {
    const MethodChannel channel = MethodChannel(
      'nearsend.test/app-directories',
    );

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    void answerWith(Object? value) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) async {
            expect(
              call.method,
              AppDirectories.androidMethod,
              reason:
                  'the method name is one half of a contract whose other half is a `when` branch '
                  'in Kotlin; a rename on one side is a silent no-op on the other',
            );
            return value;
          });
    }

    test('takes the application directory the platform reports', () async {
      answerWith('/data/user/0/com.nearsend.app/files');
      final AppDirectories subject = AppDirectories(
        channel: channel,
        isAndroid: true,
      );

      expect(await subject.resolve(), '/data/user/0/com.nearsend.app/files');
    });

    test('refuses when the platform answers with nothing', () async {
      answerWith(null);
      final AppDirectories subject = AppDirectories(
        channel: channel,
        isAndroid: true,
      );

      await expectLater(
        subject.resolve(),
        throwsA(isA<PlatformFileFailure>()),
        reason:
            'an empty answer is not a directory, and treating it as one would put the database '
            'at the filesystem root',
      );
    });

    test('refuses when the platform answers with an empty string', () async {
      answerWith('');
      final AppDirectories subject = AppDirectories(
        channel: channel,
        isAndroid: true,
      );

      await expectLater(subject.resolve(), throwsA(isA<PlatformFileFailure>()));
    });
  });

  test('the channel name is the one MainActivity serves', () {
    expect(
      AppDirectories.channelName,
      MethodChannelAndroidFileGateway.channelName,
      reason:
          'the application directory travels over the channel the file adapter already uses, so '
          'there is one definition rather than two that can drift',
    );
  });
}
