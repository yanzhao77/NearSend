import 'package:flutter/services.dart';

import 'package:nearsend/core/security/installation_identity.dart';

class MethodChannelSecureIdentityStore implements SecureIdentityStore {
  MethodChannelSecureIdentityStore({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(channelName);

  static const String channelName = 'com.nearsend.app/secure_identity';

  final MethodChannel _channel;

  @override
  Future<String?> readIdentity() =>
      _channel.invokeMethod<String>('readIdentity');

  @override
  Future<void> writeIdentity(String encodedIdentity) async {
    if (encodedIdentity.isEmpty) {
      throw ArgumentError.value(
        encodedIdentity,
        'encodedIdentity',
        'must not be empty',
      );
    }
    await _channel.invokeMethod<void>('writeIdentity', <String, Object>{
      'value': encodedIdentity,
    });
  }
}
