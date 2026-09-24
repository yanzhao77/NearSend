import 'dart:io';

import 'package:flutter/material.dart';

import 'package:nearsend/app/app.dart';
import 'package:nearsend/app/node_session.dart';
import 'package:nearsend/app/peer_session.dart';
import 'package:nearsend/core/security/installation_identity.dart';
import 'package:nearsend/platform/android_file_gateway.dart';
import 'package:nearsend/platform/app_directories.dart';
import 'package:nearsend/platform/ble_control_gateway.dart';
import 'package:nearsend/platform/mdns_discovery_gateway.dart';
import 'package:nearsend/platform/platform_storage_gateway.dart';
import 'package:nearsend/platform/platform_identity_store.dart';
import 'package:nearsend/platform/platform_file_actions.dart';

/// Starts the application, with this device's node behind it.
///
/// Binding happens before `runApp` because the Android channel that answers "where may this
/// application keep its own files" is a platform channel, and a channel call before the binding
/// exists has no messenger to travel over.
///
/// The node itself is **not** opened here. Resolving the directory is allowed to fail - a platform
/// that cannot name one must not be worked around - and a failure at this point would leave the
/// application with no window and no explanation. So the resolver is handed to the session, which
/// starts the node after the first frame and publishes the failure as a state the connection screen
/// can state.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // The gateway is Android's, and only Android's: it is what turns a `content://` document into
  // bytes. Every other platform's files are paths, and passing a gateway there would route them
  // through a channel that does not answer.
  final AndroidFileGateway? gateway = Platform.isAndroid
      ? MethodChannelAndroidFileGateway()
      : null;
  final PlatformStorageGateway? storageGateway = Platform.isAndroid
      ? MethodChannelAndroidStorageGateway()
      : Platform.isWindows
      ? MethodChannelWindowsStorageGateway()
      : null;
  final InstallationIdentityProvider identityProvider =
      Platform.isAndroid || Platform.isWindows
      ? SecureInstallationIdentityProvider(MethodChannelSecureIdentityStore())
      : const EphemeralInstallationIdentityProvider();

  runApp(
    NearSendApp(
      session: NodeSession(
        resolveDirectory: AppDirectories().resolve,
        gateway: gateway,
        identityProvider: identityProvider,
        discovery: MdnsDiscoveryGateway(),
      ),
      peer: PeerSession(),
      storageGateway: storageGateway,
      bleGateway: Platform.isAndroid || Platform.isWindows
          ? BleControlGateway()
          : null,
      fileActions: Platform.isAndroid || Platform.isWindows
          ? MethodChannelPlatformFileActions(
              supportsReveal: Platform.isWindows || Platform.isAndroid,
            )
          : const UnavailablePlatformFileActions(),
    ),
  );
}
