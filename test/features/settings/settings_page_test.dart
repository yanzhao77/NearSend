import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nearsend/app/application/app_settings_repository.dart';
import 'package:nearsend/app/application/settings_controller.dart';
import 'package:nearsend/app/application/space_overview_controller.dart';
import 'package:nearsend/app/theme/design_tokens.dart';
import 'package:nearsend/core/storage/space_plan.dart';
import 'package:nearsend/platform/platform_permission_gateway.dart';
import 'package:nearsend/features/settings/presentation/settings_page.dart';
import 'package:nearsend/platform/platform_storage_gateway.dart';
import 'package:nearsend/platform/storage_location.dart';

void main() {
  const StorageLocationRef oldLocation = StorageLocationRef(
    kind: StorageLocationKind.androidDocumentTree,
    opaqueValue: 'content://provider/tree/old',
    displayName: '旧目录',
  );
  const StorageLocationRef newLocation = StorageLocationRef(
    kind: StorageLocationKind.androidDocumentTree,
    opaqueValue: 'content://provider/tree/new',
    displayName: '新目录',
    permissionState: StoragePermissionState.granted,
  );

  Future<void> pump(
    WidgetTester tester, {
    required SettingsController controller,
    required PlatformStorageGateway gateway,
    PlatformPermissionGateway permissionGateway =
        const MethodChannelPlatformPermissionGateway(),
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildNearSendTheme(Brightness.light),
        routes: <String, WidgetBuilder>{'/about': (_) => const SizedBox()},
        home: SettingsPage(
          controller: controller,
          space: SpaceOverviewController(gateway: gateway),
          permissionGateway: permissionGateway,
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('selected directory is validated before it is persisted', (
    tester,
  ) async {
    final SettingsController controller = SettingsController();
    final _StorageGateway gateway = _StorageGateway(
      picked: newLocation,
      validation: StoragePermissionState.granted,
    );
    await pump(tester, controller: controller, gateway: gateway);

    await tester.tap(find.byTooltip('选择目录'));
    await tester.pump();

    expect(gateway.validated, <StorageLocationRef>[newLocation]);
    expect(controller.settings.defaultReceiveLocation, newLocation);
    expect(find.textContaining('访问权限有效'), findsOneWidget);
  });

  testWidgets('cancelled picker keeps the previous directory', (tester) async {
    final SettingsController controller = SettingsController()
      ..update(const AppSettings(defaultReceiveLocation: oldLocation));
    final _StorageGateway gateway = _StorageGateway(
      validation: StoragePermissionState.granted,
    );
    await pump(tester, controller: controller, gateway: gateway);
    await tester.pump();

    await tester.tap(find.byTooltip('选择目录'));
    await tester.pump();

    expect(controller.settings.defaultReceiveLocation, oldLocation);
  });

  testWidgets('directory access is checked before every picker use', (
    tester,
  ) async {
    final SettingsController controller = SettingsController();
    final _StorageGateway gateway = _StorageGateway(picked: newLocation);
    final _PermissionGateway permissions = _PermissionGateway();
    await pump(
      tester,
      controller: controller,
      gateway: gateway,
      permissionGateway: permissions,
    );

    await tester.tap(find.byTooltip('选择目录'));
    await tester.pump();

    expect(permissions.checks, 1);
    expect(permissions.requests, 0);
  });

  testWidgets('revoked persisted permission shows a repair action', (
    tester,
  ) async {
    final SettingsController controller = SettingsController()
      ..update(const AppSettings(defaultReceiveLocation: oldLocation));
    final _StorageGateway gateway = _StorageGateway(
      validation: StoragePermissionState.denied,
    );
    await pump(tester, controller: controller, gateway: gateway);
    await tester.pump();

    expect(find.text('默认接收位置需要修复'), findsOneWidget);
    expect(find.textContaining('重新选择并授予访问权限'), findsOneWidget);
    expect(find.text('重新选择'), findsOneWidget);
    expect(controller.settings.defaultReceiveLocation, oldLocation);
  });

  testWidgets('malformed legacy location remains visible as repair state', (
    tester,
  ) async {
    final SettingsController controller = SettingsController()
      ..update(const AppSettings(defaultReceiveLocationNeedsRepair: true));
    final _StorageGateway gateway = _StorageGateway();
    await pump(tester, controller: controller, gateway: gateway);

    expect(find.textContaining('原保存位置不可识别'), findsOneWidget);
    expect(find.text('默认接收位置需要修复'), findsOneWidget);
    expect(gateway.validated, isEmpty);
  });

  testWidgets('picker failure does not replace the previous directory', (
    tester,
  ) async {
    final SettingsController controller = SettingsController()
      ..update(const AppSettings(defaultReceiveLocation: oldLocation));
    final _StorageGateway gateway = _StorageGateway(
      validation: StoragePermissionState.granted,
      pickerError: StateError('picker failed'),
    );
    await pump(tester, controller: controller, gateway: gateway);
    await tester.pump();

    await tester.tap(find.byTooltip('选择目录'));
    await tester.pump();

    expect(find.textContaining('原设置保持不变'), findsOneWidget);
    expect(controller.settings.defaultReceiveLocation, oldLocation);
  });
}

class _PermissionGateway implements PlatformPermissionGateway {
  int checks = 0;
  int requests = 0;

  @override
  Future<PlatformPermissionState> check(
    PlatformPermissionKind permission,
  ) async {
    checks++;
    return PlatformPermissionState.scopedSystemPicker;
  }

  @override
  Future<PlatformPermissionState> request(
    PlatformPermissionKind permission,
  ) async {
    requests++;
    return PlatformPermissionState.scopedSystemPicker;
  }
}

class _StorageGateway implements PlatformStorageGateway {
  _StorageGateway({
    this.picked,
    this.validation = StoragePermissionState.granted,
    this.pickerError,
  });

  final StorageLocationRef? picked;
  final StoragePermissionState validation;
  final Object? pickerError;
  final List<StorageLocationRef> validated = <StorageLocationRef>[];

  @override
  String get platformLabel => 'test';

  @override
  bool get supportsDirectorySelection => true;

  @override
  Future<StorageLocationRef?> defaultReceiveLocation() async => picked;

  @override
  Future<StorageMeasurement> measureFreeSpace({
    required StorageLocationRef? location,
  }) async => const StorageMeasurement(
    volume: VolumeId('test'),
    label: '测试目录',
    availability: VolumeAvailability.unknown(),
  );

  @override
  Future<StorageLocationRef?> pickReceiveDirectory() async {
    final Object? error = pickerError;
    if (error != null) throw error;
    return picked;
  }

  @override
  Future<StorageLocationRef> validateReceiveLocation(
    StorageLocationRef location,
  ) async {
    validated.add(location);
    return location.withPermissionState(validation);
  }
}
