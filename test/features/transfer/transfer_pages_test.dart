import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nearsend/app/theme/design_tokens.dart';
import 'package:nearsend/core/security/bootstrap_pairing_payload.dart';
import 'package:nearsend/core/security/pairing_payload.dart';
import 'package:nearsend/core/security/tls_identity.dart';
import 'package:nearsend/features/transfer/presentation/transfer_pages.dart';
import 'package:nearsend/core/protocol/transfer_state.dart';
import 'package:nearsend/features/transfer/presentation/transfer_progress.dart';
import 'package:nearsend/platform/platform_permission_gateway.dart';

/// The transfer screen's figures.
///
/// `docs/ui/UI_UX_SPEC.md` §5 asks for the transferred and total bytes, the speed and the
/// remaining time, and `AGENTS.md` §2 rule 5 forbids deriving recovery from a byte counter. The
/// cases below are about the second constraint as much as the first: what the screen shows when a
/// figure is *not* known, and what it must never show.
void main() {
  group('protocol state to phase', _phaseMappingTests);

  group('progress figures', () {
    test('a fraction needs a known total', () {
      final TransferProgress unknown = TransferProgress.start(
        totalBytes: 0,
        atMillis: 0,
      );
      expect(
        unknown.fraction,
        isNull,
        reason:
            'an unknown total must produce no proportion, so the bar stays indeterminate '
            'instead of sweeping to a completion nobody knows',
      );
      expect(unknown.remainingBytes, isNull);
      expect(unknown.remainingLabel, '估算中');
    });

    test('speed needs two observations', () {
      final TransferProgress one = TransferProgress.start(
        totalBytes: 1000,
        atMillis: 0,
      );
      expect(
        one.bytesPerSecond,
        isNull,
        reason:
            'one sample is not a rate, and showing one would be inventing it',
      );

      final TransferProgress two = one.updated(
        transferredBytes: 500,
        atMillis: 1000,
      );
      expect(two.bytesPerSecond, 500);
      expect(two.speedLabel, '500 B/s');
      expect(two.estimatedSecondsRemaining, 1);
    });

    test('no progress in the window is zero, which is not unknown', () {
      final TransferProgress stalled =
          TransferProgress.start(totalBytes: 1000, atMillis: 0).updated(
            phase: TransferPhase.transferring,
            transferredBytes: 0,
            atMillis: 2000,
          );

      expect(
        stalled.bytesPerSecond,
        0,
        reason:
            'a stalled transfer must say so rather than showing nothing, which would read as '
            '"still measuring"',
      );
      expect(stalled.isStalled, isTrue);
      expect(
        stalled.estimatedSecondsRemaining,
        isNull,
        reason: 'infinity seconds is not a time a person can use',
      );
      expect(stalled.remainingLabel, '已停止（无进展）');
    });

    test('a reported figure beyond the total is clamped, never shown over 100%', () {
      final TransferProgress over = TransferProgress.start(
        totalBytes: 100,
        atMillis: 0,
      ).updated(transferredBytes: 500, atMillis: 10);

      expect(over.transferredBytes, 100);
      expect(
        over.fraction,
        1.0,
        reason:
            'a figure over the manifest total can only come from a disagreement about what '
            'the transfer contains, and the screen must not repeat it as fact',
      );
    });

    test('the phase words distinguish the states a user is waiting on', () {
      expect(TransferPhase.preparing.isActive, isTrue);
      expect(
        TransferPhase.verifying.isActive,
        isTrue,
        reason:
            '校验中 is a disk wait, not a network one, and must be its own state',
      );
      expect(TransferPhase.completed.canInterrupt, isFalse);
      expect(TransferPhase.failed.canInterrupt, isFalse);
      expect(TransferPhase.transferring.canInterrupt, isTrue);
    });

    test(
      'byte formatting uses binary units so two figures on one screen agree',
      () {
        expect(formatBytes(512), '512 B');
        expect(formatBytes(1024), '1.0 KiB');
        expect(formatBytes(4 * 1024 * 1024), '4.0 MiB');
        expect(formatBytes(20 * 1024 * 1024 * 1024), '20 GiB');
      },
    );
  });

  group('transfer screen', () {
    Future<void> pump(WidgetTester tester, TransferProgress progress) =>
        tester.pumpWidget(
          MaterialApp(
            theme: buildNearSendTheme(Brightness.light),
            home: TransferDetailPage(
              progress: progress,
              fileName: 'a.bin',
              onPause: () {},
              onResume: () {},
              onCancel: () {},
              onRetry: () {},
            ),
          ),
        );

    testWidgets('shows the status word and the three figures', (tester) async {
      final TransferProgress progress =
          TransferProgress.start(
            totalBytes: 8 * 1024 * 1024,
            atMillis: 0,
          ).updated(
            phase: TransferPhase.transferring,
            transferredBytes: 4 * 1024 * 1024,
            atMillis: 1000,
          );
      await pump(tester, progress);

      expect(find.text('传输中'), findsOneWidget);
      expect(find.text('4.0 MiB / 8.0 MiB'), findsOneWidget);
      expect(find.text('4.0 MiB/s'), findsOneWidget);
      expect(find.textContaining('约'), findsOneWidget);
    });

    testWidgets('offers pause and cancel while transferring, and no resume', (
      tester,
    ) async {
      final TransferProgress progress = TransferProgress.start(
        totalBytes: 100,
        atMillis: 0,
      ).updated(phase: TransferPhase.transferring);
      await pump(tester, progress);

      expect(find.text('暂停'), findsOneWidget);
      expect(find.text('取消'), findsOneWidget);
      expect(
        find.text('继续'),
        findsNothing,
        reason: 'a control that cannot apply is absent rather than disabled and confusing',
      );
    });

    testWidgets('offers resume when paused and retry when failed', (
      tester,
    ) async {
      await pump(
        tester,
        TransferProgress.start(
          totalBytes: 100,
          atMillis: 0,
        ).updated(phase: TransferPhase.paused),
      );
      expect(find.text('继续'), findsOneWidget);

      await pump(
        tester,
        TransferProgress.start(
          totalBytes: 100,
          atMillis: 0,
        ).updated(phase: TransferPhase.failed, failureReason: '连接已中断'),
      );
      expect(find.text('重试'), findsOneWidget);
      expect(
        find.text('连接已中断'),
        findsOneWidget,
        reason:
            'a failure must say why, and the reason is already a safe sentence',
      );
    });

    testWidgets('an unknown total draws an indeterminate bar', (tester) async {
      await pump(tester, TransferProgress.start(totalBytes: 0, atMillis: 0));
      final LinearProgressIndicator bar = tester
          .widget<LinearProgressIndicator>(
            find.byType(LinearProgressIndicator),
          );
      expect(bar.value, isNull);
    });
  });

  group('connection screen', () {
    testWidgets('says so when this device has published nothing', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildNearSendTheme(Brightness.light),
          home: const ConnectionPage(payload: null),
        ),
      );
      expect(find.text(ConnectionPage.emptySessionNote), findsOneWidget);
    });

    testWidgets('camera permission is requested before opening the scanner', (
      tester,
    ) async {
      final _PermissionGateway permissions = _PermissionGateway(
        checked: PlatformPermissionState.notDetermined,
        requested: PlatformPermissionState.denied,
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: buildNearSendTheme(Brightness.light),
          home: ConnectionPage(
            payload: null,
            enableCameraScanner: true,
            permissionGateway: permissions,
            cameraScannerPageBuilder: (_) =>
                const Scaffold(body: Text('scanner opened')),
          ),
        ),
      );

      await tester.tap(find.text('扫描二维码'));
      await tester.pumpAndSettle();

      expect(permissions.checks, 1);
      expect(permissions.requests, 1);
      expect(find.text('scanner opened'), findsNothing);
      expect(find.text('需要摄像头权限'), findsOneWidget);
      expect(find.textContaining('摄像头权限未授予'), findsOneWidget);
    });

    testWidgets(
      'starts the camera flow when opened from the home scan action',
      (tester) async {
        final _PermissionGateway permissions = _PermissionGateway(
          checked: PlatformPermissionState.granted,
        );
        await tester.pumpWidget(
          MaterialApp(
            theme: buildNearSendTheme(Brightness.light),
            home: ConnectionPage(
              payload: null,
              enableCameraScanner: true,
              startWithCamera: true,
              permissionGateway: permissions,
              cameraScannerPageBuilder: (_) =>
                  const Scaffold(body: Text('scanner opened')),
            ),
          ),
        );

        await tester.pumpAndSettle();

        expect(permissions.checks, 1);
        expect(find.text('scanner opened'), findsOneWidget);
      },
    );

    testWidgets('camera permission is rechecked for every scanner use', (
      tester,
    ) async {
      final _PermissionGateway permissions = _PermissionGateway(
        checked: PlatformPermissionState.granted,
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: buildNearSendTheme(Brightness.light),
          home: ConnectionPage(
            payload: null,
            enableCameraScanner: true,
            permissionGateway: permissions,
            cameraScannerPageBuilder: (_) =>
                const Scaffold(body: Text('scanner opened')),
          ),
        ),
      );

      await tester.tap(find.text('扫描二维码'));
      await tester.pumpAndSettle();
      expect(find.text('scanner opened'), findsOneWidget);
      Navigator.of(tester.element(find.text('scanner opened'))).pop();
      await tester.pumpAndSettle();
      await tester.tap(find.text('扫描二维码'));
      await tester.pumpAndSettle();

      expect(permissions.checks, 2);
      expect(permissions.requests, 0);
      expect(find.text('scanner opened'), findsOneWidget);
    });

    testWidgets('shows the pin, the candidates and the session', (
      tester,
    ) async {
      final PairingPayload payload = PairingPayload.parse(
        '{"kind":"lft-pair","protocolMajor":1,"protocolMinor":0,'
        '"serverFingerprint":"abababababababababababababababababababababababababababababababab",'
        '"sessionId":"11111111-2222-4333-8444-555555555555",'
        '"candidates":[{"host":"192.168.1.5","port":18443}],'
        '"pairToken":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA","expiresInSeconds":300}',
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: buildNearSendTheme(Brightness.light),
          home: ConnectionPage(payload: payload),
        ),
      );

      expect(find.text('ab' * 32), findsOneWidget);
      expect(find.text('192.168.1.5:18443'), findsOneWidget);
      expect(find.text('11111111-2222-4333-8444-555555555555'), findsOneWidget);
      expect(
        find.textContaining('指纹'),
        findsWidgets,
        reason: 'the page must tell the user to compare the fingerprint before connecting',
      );
    });

    testWidgets(
      'persistent platform identity removes only the restart warning',
      (tester) async {
        final PairingPayload payload = PairingPayload.parse(
          '{"kind":"lft-pair","protocolMajor":1,"protocolMinor":0,'
          '"serverFingerprint":"abababababababababababababababababababababababababababababababab",'
          '"sessionId":"11111111-2222-4333-8444-555555555555",'
          '"candidates":[{"host":"192.168.1.5","port":18443}],'
          '"pairToken":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA","expiresInSeconds":300}',
        );
        await tester.pumpWidget(
          MaterialApp(
            theme: buildNearSendTheme(Brightness.light),
            home: ConnectionPage(
              payload: payload,
              persistentLocalIdentity: true,
            ),
          ),
        );

        expect(find.text(ConnectionPage.ephemeralIdentityNote), findsNothing);
        expect(find.text(payload.serverFingerprint), findsOneWidget);
      },
    );

    testWidgets('a pasted payload is parsed by the same strict parser', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildNearSendTheme(Brightness.light),
          home: ConnectionPage(payload: null, onConnect: (_) {}),
        ),
      );

      await tester.enterText(find.byType(TextField), '{"kind":"lft-pair"}');
      await tester.pump();
      expect(
        find.text('连接'),
        findsNothing,
        reason: 'an incomplete payload must not produce a connect button',
      );

      await tester.enterText(
        find.byType(TextField),
        '{"kind":"lft-pair","protocolMajor":1,"protocolMinor":0,'
        '"serverFingerprint":"abababababababababababababababababababababababababababababababab",'
        '"sessionId":"11111111-2222-4333-8444-555555555555",'
        '"candidates":[{"host":"10.0.0.9","port":18443}],'
        '"pairToken":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA","expiresInSeconds":300}',
      );
      await tester.pump();
      expect(find.text('连接'), findsOneWidget);
    });

    testWidgets('bootstrap input uses the network-aware connect callback', (
      tester,
    ) async {
      final DeviceIdentity identity = generateDeviceIdentity();
      final BootstrapPairingPayload bootstrap = BootstrapPairingPayload(
        mode: BootstrapPairingMode.networkBootstrap,
        pairing: PairingPayload.parse(
          '{"kind":"lft-pair","protocolMajor":1,"protocolMinor":0,'
          '"serverFingerprint":"${'ab' * 32}",'
          '"sessionId":"11111111-2222-4333-8444-555555555555",'
          '"candidates":[{"host":"10.0.0.9","port":18443}],'
          '"pairToken":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",'
          '"expiresInSeconds":120}',
        ),
        identityPublicKey: identity.publicKeyDer,
        deviceId: identity.deviceId,
        invitationRole: 'host',
        wifi: BootstrapWifiOffer(
          ssid: 'NearSend-test',
          passphrase: 'eight-or-more',
          security: 'wpa2',
        ),
      );
      BootstrapPairingPayload? connected;
      bool legacyCalled = false;
      await tester.pumpWidget(
        MaterialApp(
          theme: buildNearSendTheme(Brightness.light),
          home: ConnectionPage(
            payload: null,
            onConnect: (_) => legacyCalled = true,
            onConnectBootstrap: (BootstrapPairingPayload value) =>
                connected = value,
          ),
        ),
      );

      await tester.enterText(find.byType(TextField), bootstrap.encode());
      await tester.pump();
      await tester.tap(find.text('连接'));

      expect(legacyCalled, isFalse);
      expect(connected?.deviceId, identity.deviceId);
      expect(connected?.wifi?.ssid, 'NearSend-test');
    });

    testWidgets('a node that is starting is not reported as having none', (
      tester,
    ) async {
      // "still starting" and "did not start" are different answers, and the second sends a user to
      // look for a fault in the other device.
      await tester.pumpWidget(
        MaterialApp(
          theme: buildNearSendTheme(Brightness.light),
          home: const ConnectionPage(payload: null, starting: true),
        ),
      );

      expect(find.text(ConnectionPage.startingNote), findsOneWidget);
      expect(find.text(ConnectionPage.emptySessionNote), findsNothing);
    });

    testWidgets(
      'a node that failed says why instead of showing an empty code',
      (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            theme: buildNearSendTheme(Brightness.light),
            home: const ConnectionPage(
              payload: null,
              unavailableReason: '本机没有可用的局域网地址，无法出示连接信息。请先连接 Wi-Fi。',
            ),
          ),
        );

        expect(find.text('本机没有可用的局域网地址，无法出示连接信息。请先连接 Wi-Fi。'), findsOneWidget);
        expect(find.text(ConnectionPage.emptySessionNote), findsNothing);
      },
    );

    testWidgets(
      'the connect action is absent, with a reason, when there is none',
      (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            theme: buildNearSendTheme(Brightness.light),
            home: const ConnectionPage(payload: null),
          ),
        );
        await tester.enterText(
          find.byType(TextField),
          '{"kind":"lft-pair","protocolMajor":1,"protocolMinor":0,'
          '"serverFingerprint":"abababababababababababababababababababababababababababababababab",'
          '"sessionId":"11111111-2222-4333-8444-555555555555",'
          '"candidates":[{"host":"10.0.0.9","port":18443}],'
          '"pairToken":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA","expiresInSeconds":300}',
        );
        await tester.pump();

        expect(
          find.text('连接'),
          findsNothing,
          reason:
              'a button that cannot act is a placeholder; the page states the gap instead of '
              'offering a control that silently does nothing',
        );
        expect(find.text(ConnectionPage.noConnectorNote), findsOneWidget);
      },
    );

    testWidgets(
      'a connection attempt is shown as it proceeds and when it ends',
      (tester) async {
        Future<void> pump(ConnectionAttempt attempt) => tester.pumpWidget(
          MaterialApp(
            theme: buildNearSendTheme(Brightness.light),
            home: ConnectionPage(
              payload: null,
              onConnect: (_) {},
              connection: attempt,
            ),
          ),
        );

        await pump(
          const ConnectionAttempt(phase: ConnectionAttemptPhase.connecting),
        );
        expect(find.text(ConnectionPage.connectingNote), findsOneWidget);

        await pump(
          const ConnectionAttempt(phase: ConnectionAttemptPhase.connected),
        );
        expect(find.text(ConnectionPage.connectedNote), findsOneWidget);

        await pump(
          ConnectionAttempt(
            phase: ConnectionAttemptPhase.failed,
            reason: '无法连接到对方设备。',
            peerFingerprint: 'cd' * 32,
            pinMismatched: true,
          ),
        );
        expect(find.textContaining('无法连接到对方设备。'), findsOneWidget);
        expect(
          find.textContaining('cd' * 32),
          findsOneWidget,
          reason:
              'a mismatch is the one failure where the user needs the value they are disagreeing '
              'about, and it is not a secret: the peer publishes it in its own payload',
        );
      },
    );

    testWidgets(
      'shows peer metadata as unknown until the fingerprint is verified',
      (tester) async {
        final PairingPayload payload = PairingPayload.parse(
          '{"kind":"lft-pair","protocolMajor":1,"protocolMinor":0,'
          '"serverFingerprint":"abababababababababababababababababababababababababababababababab",'
          '"sessionId":"11111111-2222-4333-8444-555555555555",'
          '"candidates":[{"host":"10.0.0.9","port":18443}],'
          '"pairToken":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA","expiresInSeconds":300}',
        );
        await tester.pumpWidget(
          MaterialApp(
            theme: buildNearSendTheme(Brightness.light),
            home: const ConnectionPage(
              payload: null,
              onConnect: _noopPairing,
              localDeviceName: '本机',
              localPlatform: 'android',
            ),
          ),
        );

        await tester.enterText(
          find.byType(TextField),
          jsonEncode(payload.toJson()),
        );
        await tester.pump();

        expect(find.text('对端设备名称未提供'), findsOneWidget);
        expect(find.text('对端平台未提供'), findsOneWidget);
        expect(find.text('待验证'), findsOneWidget);
        expect(find.text('已验证'), findsNothing);
      },
    );
  });
}

class _PermissionGateway implements PlatformPermissionGateway {
  _PermissionGateway({required this.checked, this.requested});

  final PlatformPermissionState checked;
  final PlatformPermissionState? requested;
  int checks = 0;
  int requests = 0;

  @override
  Future<PlatformPermissionState> check(
    PlatformPermissionKind permission,
  ) async {
    checks++;
    return checked;
  }

  @override
  Future<PlatformPermissionState> request(
    PlatformPermissionKind permission,
  ) async {
    requests++;
    return requested ?? checked;
  }
}

void _noopPairing(PairingPayload _) {}

/// The join between the protocol's task states and the words the screen shows.
///
/// `TransferProgress` had a phase and the engine had a `TransferState`, and nothing connected them,
/// so a screen could only show what its caller guessed. These cases pin the mapping, and the most
/// important ones are the two the protocol explicitly says are **not** failures: §11 pairs `BLOCKED`
/// with "free space or change the location, then retry", and `INTERRUPTED` has a resume as its exit -
/// rendering either as 失败 would tell the user the transfer is over when it is not.
void _phaseMappingTests() {
  test('every task state maps to a phase, and the two recoverable ones are not failures', () {
    expect(phaseForTransferState(TransferState.blocked), TransferPhase.blocked);
    expect(
      phaseForTransferState(TransferState.interrupted),
      TransferPhase.interrupted,
    );
    expect(
      TransferPhase.blocked.label,
      isNot(TransferPhase.failed.label),
      reason: 'a blocked transfer is waiting on the user, not over',
    );
    expect(TransferPhase.interrupted.canInterrupt, isFalse);
    expect(
      TransferPhase.blocked.canInterrupt,
      isFalse,
      reason: '§10 gives blocked a user action as its exit, not a pause',
    );
  });

  test('the states a user cannot tell apart collapse to one word', () {
    expect(
      phaseForTransferState(TransferState.preparing),
      phaseForTransferState(TransferState.staging),
      reason:
          'one is sender-local and the other means pages are arriving, but the user is waiting '
          'either way and which side is working is not actionable',
    );
    expect(phaseForTransferState(TransferState.pausing), TransferPhase.paused);
    expect(
      phaseForTransferState(TransferState.ready),
      TransferPhase.transferring,
      reason:
          '§10 makes READY the first moment a write generation exists, so it is the first moment '
          'a progress bar means anything',
    );
  });

  test(
    'the two states with real work left are distinct from the transfer itself',
    () {
      // §5 wants 校验中 and 保存中 to be told apart from 传输中: they are disk waits, and a user
      // watching a stalled bar deserves to know which one is slow.
      expect(
        phaseForTransferState(TransferState.verifying),
        TransferPhase.verifying,
      );
      expect(
        phaseForTransferState(TransferState.exporting),
        TransferPhase.exporting,
      );
      expect(TransferPhase.verifying.isActive, isTrue);
      expect(TransferPhase.exporting.isActive, isTrue);
    },
  );

  test('a partial completion is reported as a failure rather than as done', () {
    expect(
      phaseForTransferState(TransferState.partiallyCompleted),
      TransferPhase.failed,
      reason:
          'some files are not on the receiver disk; calling that 已完成 is the false completion '
          'AGENTS.md §2 rule 11 forbids',
    );
    expect(
      phaseForTransferState(TransferState.cancelled),
      TransferPhase.failed,
    );
  });

  testWidgets('the published pin says it does not survive a restart', (
    tester,
  ) async {
    // The node mints a fresh TLS identity on every open, so this fingerprint is not the one the
    // next launch shows. Saying so is a T11-02 acceptance criterion, and it is here because
    // without it a person comparing fingerprints with the peer would see a change between two
    // launches and reasonably conclude the wrong thing about the other device.
    final PairingPayload payload = PairingPayload.parse(
      '{"kind":"lft-pair","protocolMajor":1,"protocolMinor":0,'
      '"serverFingerprint":"abababababababababababababababababababababababababababababababab",'
      '"sessionId":"11111111-2222-4333-8444-555555555555",'
      '"candidates":[{"host":"192.168.1.5","port":18443}],'
      '"pairToken":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA","expiresInSeconds":300}',
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: buildNearSendTheme(Brightness.light),
        home: ConnectionPage(payload: payload),
      ),
    );

    expect(
      find.text(ConnectionPage.ephemeralIdentityNote),
      findsOneWidget,
      reason:
          'a pin that changes every launch must say so, or the screen is telling the user '
          'something about their peer that is not true',
    );
    expect(
      ConnectionPage.ephemeralIdentityNote,
      contains('无法跨重启保留'),
      reason: 'and it must say the consequence, not only the mechanism',
    );
  });
}
