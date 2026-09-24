import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nearsend/core/storage/saved_file_reference.dart';
import 'package:nearsend/platform/platform_file_actions.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const MethodChannel channel = MethodChannel('test.nearsend/files');
  final List<MethodCall> calls = <MethodCall>[];

  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
          calls.add(call);
          return <String, Object?>{'status': 'completed'};
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('open and reveal use the structured platform contract', () async {
    final MethodChannelPlatformFileActions actions =
        MethodChannelPlatformFileActions(channel: channel);

    expect((await actions.open('content://saved/file')).succeeded, isTrue);
    expect((await actions.reveal(r'C:\Saved\file.bin')).succeeded, isTrue);
    expect(calls, <Matcher>[
      isA<MethodCall>()
          .having((MethodCall call) => call.method, 'method', 'openSavedFile')
          .having(
            (MethodCall call) => call.arguments,
            'arguments',
            <String, Object?>{'targetRef': 'content://saved/file'},
          ),
      isA<MethodCall>()
          .having((MethodCall call) => call.method, 'method', 'revealSavedFile')
          .having(
            (MethodCall call) => call.arguments,
            'arguments',
            <String, Object?>{'targetRef': r'C:\Saved\file.bin'},
          ),
    ]);
  });

  test(
    'maps platform statuses and malformed responses without throwing',
    () async {
      final MethodChannelPlatformFileActions actions =
          MethodChannelPlatformFileActions(channel: channel);
      final Map<Object?, Object?> responses = <Object?, Object?>{
        'unsupported': <String, Object?>{'status': 'unsupported'},
        'unavailable': <String, Object?>{'status': 'unavailable'},
        'denied': <String, Object?>{'status': 'permissionDenied'},
        'unknown': <String, Object?>{'status': 'other'},
        'malformed': 'completed',
      };
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) async {
            return responses[(call.arguments
                as Map<Object?, Object?>)['targetRef']];
          });

      expect(
        (await actions.open('unsupported')).status,
        PlatformFileActionStatus.unsupported,
      );
      expect(
        (await actions.open('unavailable')).status,
        PlatformFileActionStatus.unavailable,
      );
      expect(
        (await actions.open('denied')).status,
        PlatformFileActionStatus.permissionDenied,
      );
      expect(
        (await actions.open('unknown')).status,
        PlatformFileActionStatus.failed,
      );
      expect(
        (await actions.open('malformed')).status,
        PlatformFileActionStatus.failed,
      );
    },
  );

  test(
    'maps permission exceptions and missing plugins to structured failures',
    () async {
      final MethodChannelPlatformFileActions actions =
          MethodChannelPlatformFileActions(channel: channel);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) async {
            final String target =
                (call.arguments as Map<Object?, Object?>)['targetRef']!
                    as String;
            if (target == 'denied') {
              throw PlatformException(code: 'NS-FILE-PERMISSION');
            }
            throw MissingPluginException();
          });

      expect(
        (await actions.open('denied')).status,
        PlatformFileActionStatus.permissionDenied,
      );
      expect(
        (await actions.open('missing')).status,
        PlatformFileActionStatus.failed,
      );
    },
  );

  test(
    'rejects blank, control-character and oversized references locally',
    () async {
      final MethodChannelPlatformFileActions actions =
          MethodChannelPlatformFileActions(channel: channel);
      final List<String> invalid = <String>[
        '',
        ' leading',
        'trailing ',
        'content://saved/\nfile',
        'a' * (MethodChannelPlatformFileActions.maxTargetRefBytes + 1),
      ];

      for (final String target in invalid) {
        expect(
          (await actions.open(target)).status,
          PlatformFileActionStatus.unavailable,
        );
      }
      expect(calls, isEmpty);
    },
  );

  test('saved file diagnostics redact the name and target reference', () {
    const SavedFileReference reference = SavedFileReference(
      displayName: 'private-report.txt',
      targetRef: 'content://documents/private-target',
    );

    expect(reference.toString(), 'SavedFileReference(hasTarget=true)');
    expect(reference.toString(), isNot(contains('private-report')));
    expect(reference.toString(), isNot(contains('private-target')));
  });
}
