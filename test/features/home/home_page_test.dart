import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nearsend/app/application/radar_controller.dart';
import 'package:nearsend/features/home/presentation/home_page.dart';

/// T12-04 acceptance for the real home shell.
void main() {
  Future<void> pumpHomePage(WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(home: HomePage()));
  }

  testWidgets('renders both primary actions', (tester) async {
    await pumpHomePage(tester);

    expect(find.text('发送文件'), findsAtLeastNWidgets(1));
    expect(find.text('接收文件'), findsAtLeastNWidgets(1));
    expect(find.byType(FilledButton), findsNWidgets(2));
  });

  testWidgets(
    'primary actions are enabled and explain the completion boundary',
    (tester) async {
      await pumpHomePage(tester);

      for (final FilledButton button in tester.widgetList<FilledButton>(
        find.byType(FilledButton),
      )) {
        expect(
          button.onPressed,
          isNotNull,
          reason: 'the primary actions open the real connection flow',
        );
      }

      final Finder completionNote = find.text(HomePage.remainingWorkNote);
      await tester.scrollUntilVisible(completionNote, 300);
      expect(completionNote, findsOneWidget);
    },
  );

  testWidgets('explains that no internet is required but a local link is', (
    tester,
  ) async {
    await pumpHomePage(tester);

    expect(find.text(HomePage.emptyStateExplanation), findsOneWidget);
  });

  testWidgets(
    'states plainly that the user-facing transfer flow is not integrated',
    (tester) async {
      await pumpHomePage(tester);

      expect(find.text(HomePage.baselineNotice), findsOneWidget);
    },
  );

  testWidgets(
    'does not render a continue-task action while none is recoverable',
    (tester) async {
      await pumpHomePage(tester);

      expect(find.text('继续任务'), findsNothing);
    },
  );

  testWidgets('Wi-Fi and Bluetooth forward independent enable requests', (
    tester,
  ) async {
    bool? wifiRequested;
    bool? bluetoothRequested;
    await tester.pumpWidget(
      MaterialApp(
        home: HomePage(
          onWifiReadyChanged: (bool value) => wifiRequested = value,
          onBluetoothReadyChanged: (bool value) => bluetoothRequested = value,
        ),
      ),
    );

    final Finder wifiSwitch = find.byKey(
      const ValueKey<String>('wifi-discovery-switch'),
    );
    final Finder bluetoothSwitch = find.byKey(
      const ValueKey<String>('bluetooth-discovery-switch'),
    );
    await tester.scrollUntilVisible(wifiSwitch, 300);
    expect(tester.widget<SwitchListTile>(wifiSwitch).value, isFalse);
    await tester.tap(wifiSwitch);
    expect(wifiRequested, isTrue);
    expect(bluetoothRequested, isNull);

    await tester.scrollUntilVisible(bluetoothSwitch, 300);
    expect(tester.widget<SwitchListTile>(bluetoothSwitch).value, isFalse);
    await tester.tap(bluetoothSwitch);
    expect(bluetoothRequested, isTrue);
  });

  testWidgets('only verified ready devices render a green status semantic', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: HomePage(
          bluetoothPhase: RadarReadinessPhase.ready,
          bluetoothDevices: <RadarDevice>[
            RadarDevice(
              id: 'candidate',
              name: '未经验证的候选设备',
              detail: '蓝牙候选',
              isKnown: false,
              isReady: false,
              isRevoked: false,
            ),
          ],
          pairedDevices: <RadarDevice>[
            RadarDevice(
              id: 'verified',
              name: '已验证设备',
              detail: 'Windows',
              isKnown: true,
              isReady: true,
              isRevoked: false,
            ),
          ],
        ),
      ),
    );

    await tester.scrollUntilVisible(find.text('已验证设备'), 300);
    final Text verifiedName = tester.widget<Text>(find.text('已验证设备'));
    expect(verifiedName.semanticsLabel, '已验证设备，已实时验证并就绪');
    expect(find.text('未经验证的候选设备'), findsOneWidget);
    expect(find.byIcon(Icons.devices_outlined), findsOneWidget);
  });

  testWidgets('long peer names fit a narrow viewport', (tester) async {
    tester.view.physicalSize = const Size(320, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      const MaterialApp(
        home: HomePage(
          wifiPhase: RadarReadinessPhase.ready,
          wifiDevices: <RadarDevice>[
            RadarDevice(
              id: 'long',
              name: '这是一台名称非常非常长但仍然必须在窄屏中安全换行显示的 Windows 设备',
              detail: '局域网候选 · 2 个地址',
              isKnown: false,
              isReady: false,
              isRevoked: false,
            ),
          ],
        ),
      ),
    );

    await tester.scrollUntilVisible(find.textContaining('这是一台名称'), 300);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Wi-Fi and Bluetooth lists show names and forward the device', (
    tester,
  ) async {
    RadarDevice? selected;
    const RadarDevice wifi = RadarDevice(
      id: 'wifi-peer',
      name: '书房电脑',
      detail: 'windows · 局域网候选 · 1 个地址',
      isKnown: false,
      isReady: false,
      isRevoked: false,
    );
    const RadarDevice bluetooth = RadarDevice(
      id: 'ble-peer',
      name: '客厅手机',
      detail: '蓝牙候选',
      isKnown: false,
      isReady: false,
      isRevoked: false,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: HomePage(
          wifiPhase: RadarReadinessPhase.ready,
          wifiDevices: <RadarDevice>[wifi],
          bluetoothPhase: RadarReadinessPhase.ready,
          bluetoothDevices: <RadarDevice>[bluetooth],
          onRadarDevicePressed: (RadarDevice device) => selected = device,
        ),
      ),
    );

    await tester.scrollUntilVisible(find.text('书房电脑'), 300);
    await tester.tap(find.text('书房电脑'));
    expect(selected, same(wifi));

    await tester.scrollUntilVisible(find.text('客厅手机'), 300);
    await tester.ensureVisible(find.text('客厅手机'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('客厅手机'));
    expect(selected, same(bluetooth));
  });

  testWidgets('split discovery sections fit narrow 200 percent text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      const MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(textScaler: TextScaler.linear(2)),
          child: HomePage(
            wifiPhase: RadarReadinessPhase.ready,
            wifiDevices: <RadarDevice>[
              RadarDevice(
                id: 'wifi-peer',
                name: '名称很长的局域网 Windows 设备',
                detail: 'windows · 局域网候选 · 2 个地址',
                isKnown: false,
                isReady: false,
                isRevoked: false,
              ),
            ],
            bluetoothPhase: RadarReadinessPhase.ready,
            bluetoothDevices: <RadarDevice>[
              RadarDevice(
                id: 'ble-peer',
                name: '名称很长的蓝牙 Android 设备',
                detail: '蓝牙候选',
                isKnown: false,
                isReady: false,
                isRevoked: false,
              ),
            ],
          ),
        ),
      ),
    );

    await tester.scrollUntilVisible(find.text('蓝牙设备'), 300);
    expect(find.text('Wi-Fi 局域网连接'), findsOneWidget);
    expect(find.text('蓝牙连接'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
