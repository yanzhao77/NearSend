import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nearsend/app/app.dart';
import 'package:nearsend/app/application/pairing_coordinator.dart';
import 'package:nearsend/core/protocol/base64url.dart';
import 'package:nearsend/core/security/bootstrap_pairing_payload.dart';
import 'package:nearsend/core/security/pairing_payload.dart';
import 'package:nearsend/features/pairing/presentation/connection_surfaces.dart';
import 'package:nearsend/features/pairing/presentation/pairing_qr_widgets.dart';
import 'package:nearsend/platform/platform_network_gateway.dart';
import 'package:nearsend/platform/platform_permission_gateway.dart';
import 'package:nearsend/platform/qr_image_gateway.dart';

void pairingTest(String name, Future<void> Function(WidgetTester) body) {
  testWidgets(name, (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      await body(tester);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}

void main() {
  PairingPayload payload() => PairingPayload(
    serverFingerprint: 'a' * 64,
    sessionId: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
    candidates: const [PairingCandidate(host: '127.0.0.1', port: 8443)],
    pairToken: encodeBase64UrlNoPadding(Uint8List(32)),
    expiresInSeconds: 120,
  );

  Future<void> openScanner(
    WidgetTester tester,
    _Permission permission, {
    Object? result,
  }) async {
    await tester.pumpWidget(
      NearSendApp(
        permissionGateway: permission,
        cameraScannerPageBuilder: (_) => Scaffold(
          appBar: AppBar(title: const Text('专用扫描器')),
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => Navigator.of(context).pop<Object?>(result),
              child: const Text('扫描结束'),
            ),
          ),
        ),
      ),
    );
    await tester.ensureVisible(find.text('扫一扫连接设备'));
    await tester.tap(find.text('扫一扫连接设备'));
    await tester.pumpAndSettle();
  }

  pairingTest(
    'home opens a scanner directly, cancellation returns to home without a form',
    (tester) async {
      final permission = _Permission(PlatformPermissionState.granted);
      await openScanner(tester, permission);
      expect(find.text('专用扫描器'), findsOneWidget);
      expect(find.byType(AdvancedConnectionPage), findsNothing);
      expect(find.byType(TextField), findsNothing);
      await tester.tap(find.text('扫描结束'));
      await tester.pumpAndSettle();
      expect(find.byType(NavigationBar), findsOneWidget);
      expect(find.byType(AlertDialog), findsNothing);
      await tester.tap(find.text('扫一扫连接设备'));
      await tester.pumpAndSettle();
      expect(permission.checks, 4);
      await tester.pageBack();
      await tester.pumpAndSettle();
    },
  );

  pairingTest('permission is requested and re-read before opening camera', (
    tester,
  ) async {
    final permission = _Permission(
      PlatformPermissionState.denied,
      grantOnRequest: true,
    );
    await openScanner(tester, permission);
    expect(permission.requests, 1);
    expect(permission.checks, 2);
    expect(find.text('专用扫描器'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
  });

  pairingTest('permission refusal returns one message without opening camera', (
    tester,
  ) async {
    await openScanner(tester, _Permission(PlatformPermissionState.denied));
    expect(find.text('专用扫描器'), findsNothing);
    expect(find.byType(AlertDialog), findsOneWidget);
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
  });

  pairingTest(
    'scanner failure returns one message and leaves no hidden pairing page',
    (tester) async {
      await openScanner(
        tester,
        _Permission(PlatformPermissionState.granted),
        result: const PairingScanFailure('二维码已失效'),
      );
      await tester.tap(find.text('扫描结束'));
      await tester.pumpAndSettle();
      expect(find.text('二维码已失效'), findsOneWidget);
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.byType(AdvancedConnectionPage), findsNothing);
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();
      expect(find.text('专用扫描器'), findsNothing);
    },
  );

  pairingTest('invalid scanned payload is refused with no connection or form', (
    tester,
  ) async {
    await openScanner(
      tester,
      _Permission(PlatformPermissionState.granted),
      result: 'invalid',
    );
    await tester.tap(find.text('扫描结束'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.byType(PairingProgressDialog), findsNothing);
    expect(find.byType(TextField), findsNothing);
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
  });

  pairingTest(
    'advanced page strictly parses and returns after confirmed connection',
    (tester) async {
      ScannedPairingPayload? captured;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => AdvancedConnectionPage(
                      onConnect: (_, value) async {
                        captured = value;
                        return true;
                      },
                      failureReason: () => null,
                    ),
                  ),
                ),
                child: const Text('打开高级入口'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开高级入口'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'invalid');
      await tester.pump();
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull,
      );
      await tester.enterText(find.byType(TextField), payload().encode());
      await tester.pump();
      await tester.tap(find.text('连接'));
      await tester.pumpAndSettle();
      expect(captured, isA<LegacyScannedPairingPayload>());
      expect(find.byType(AdvancedConnectionPage), findsNothing);
    },
  );

  pairingTest('advanced failure stays editable without a second error modal', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: AdvancedConnectionPage(
          onConnect: (_, _) async => false,
          failureReason: () => '设备身份验证失败',
        ),
      ),
    );
    await tester.enterText(find.byType(TextField), payload().encode());
    await tester.pump();
    await tester.tap(find.text('连接'));
    await tester.pumpAndSettle();
    expect(find.text('设备身份验证失败'), findsOneWidget);
    expect(find.byType(AlertDialog), findsNothing);
    expect(tester.widget<TextField>(find.byType(TextField)).enabled, isTrue);
  });

  pairingTest(
    'closing advanced page while connecting does not pop another route on completion',
    (tester) async {
      final done = Completer<bool>();
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => AdvancedConnectionPage(
                      onConnect: (_, _) => done.future,
                      failureReason: () => null,
                    ),
                  ),
                ),
                child: const Text('主页'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('主页'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), payload().encode());
      await tester.pump();
      await tester.tap(find.text('连接'));
      await tester.pump();
      await tester.pageBack();
      await tester.pumpAndSettle();
      done.complete(true);
      await tester.pumpAndSettle();
      expect(find.text('主页'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  pairingTest(
    'established but stale device card keeps disconnect without a pairing form',
    (tester) async {
      bool disconnected = false;
      await tester.pumpWidget(
        MaterialApp(
          home: ConnectedDeviceCard(
            name: '手机',
            status: '已建立授权会话 · 当前可达性待确认',
            activeTasks: 0,
            onDisconnect: () => disconnected = true,
          ),
        ),
      );
      expect(find.byType(TextField), findsNothing);
      expect(find.text('重新扫码配对'), findsNothing);
      await tester.tap(find.text('断开连接'));
      await tester.pump();
      expect(disconnected, isTrue);
    },
  );

  pairingTest('history card offers pairing but never a fake disconnect', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: ConnectedDeviceCard(
          name: '历史手机',
          status: '历史配对设备 · 当前离线',
          activeTasks: 0,
          onPair: () {},
        ),
      ),
    );
    expect(find.text('断开连接'), findsNothing);
    expect(find.text('重新扫码配对'), findsOneWidget);
  });

  pairingTest('progress reflects real stage and supports cancellation', (
    tester,
  ) async {
    final coordinator = PairingCoordinator(
      peer: null,
      network: const UnavailablePlatformNetworkGateway(),
    );
    bool cancelled = false;
    await tester.pumpWidget(
      MaterialApp(
        home: PairingProgressDialog(
          coordinator: coordinator,
          onCancel: () => cancelled = true,
        ),
      ),
    );
    expect(find.byType(TextField), findsNothing);
    await tester.tap(find.text('取消连接'));
    await tester.pump();
    expect(cancelled, isTrue);
    await tester.pumpWidget(const SizedBox());
    coordinator.dispose();
  });

  pairingTest('large fonts and long device names do not overflow device card', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(
            size: Size(320, 600),
            textScaler: TextScaler.linear(2),
          ),
          child: Scaffold(
            body: SizedBox(
              width: 320,
              child: ConnectedDeviceCard(
                name: '很长的设备名称' * 10,
                status: '已建立授权会话 · 当前可达性待确认',
                activeTasks: 10,
                onDisconnect: () {},
                onCheck: () {},
              ),
            ),
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
  });

  pairingTest(
    'Windows imports directly, cancellation leaves the home navigation intact',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      final image = _ImageGateway();
      await tester.pumpWidget(
        NearSendApp(
          qrImageGateway: image,
          permissionGateway: _Permission(PlatformPermissionState.granted),
        ),
      );
      await tester.ensureVisible(find.text('导入二维码连接设备'));
      await tester.tap(find.text('导入二维码连接设备'));
      await tester.pumpAndSettle();
      expect(image.picks, 1);
      expect(find.byType(NavigationRail), findsOneWidget);
      expect(find.byType(AdvancedConnectionPage), findsNothing);
      expect(find.text('扫一扫连接设备'), findsNothing);
    },
  );

  pairingTest(
    'Windows invalid image reports one error without opening a form',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      await tester.pumpWidget(
        NearSendApp(
          qrImageGateway: _ImageGateway(bytes: Uint8List(10)),
          permissionGateway: _Permission(PlatformPermissionState.granted),
        ),
      );
      await tester.ensureVisible(find.text('导入二维码连接设备'));
      await tester.tap(find.text('导入二维码连接设备'));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();
    },
  );
}

class _Permission implements PlatformPermissionGateway {
  _Permission(this.state, {this.grantOnRequest = false});
  PlatformPermissionState state;
  final bool grantOnRequest;
  int checks = 0;
  int requests = 0;
  @override
  Future<PlatformPermissionState> check(
    PlatformPermissionKind permission,
  ) async {
    checks++;
    return state;
  }

  @override
  Future<PlatformPermissionState> request(
    PlatformPermissionKind permission,
  ) async {
    requests++;
    if (grantOnRequest) state = PlatformPermissionState.granted;
    return state;
  }
}

class _ImageGateway implements QrImageGateway {
  _ImageGateway({this.bytes});
  final Uint8List? bytes;
  int picks = 0;
  @override
  Future<Uint8List?> pickImage() async {
    picks++;
    return bytes;
  }
}
