import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nearsend/platform/platform_identity_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const MethodChannel channel = MethodChannel(
    MethodChannelSecureIdentityStore.channelName,
  );

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test(
    'read returns the protected platform value without logging it',
    () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) async {
            expect(call.method, 'readIdentity');
            expect(call.arguments, isNull);
            return 'encrypted-payload';
          });

      expect(
        await MethodChannelSecureIdentityStore().readIdentity(),
        'encrypted-payload',
      );
    },
  );

  test('write sends one value and refuses an empty payload', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
          expect(call.method, 'writeIdentity');
          expect(call.arguments, <String, Object>{'value': 'identity-payload'});
          return null;
        });
    final MethodChannelSecureIdentityStore store =
        MethodChannelSecureIdentityStore();

    await store.writeIdentity('identity-payload');
    await expectLater(store.writeIdentity(''), throwsA(isA<ArgumentError>()));
  });
}
