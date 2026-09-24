import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qr/qr.dart';
import 'package:image/image.dart' as img;

import 'package:nearsend/platform/qr_image_gateway.dart';
import 'package:nearsend/platform/platform_permission_gateway.dart';
import 'package:nearsend/features/pairing/presentation/pairing_qr_widgets.dart';

void main() {
  test('decodes a bounded QR image without logging its content', () async {
    const String text = '{"kind":"test","secret":"not-for-logs"}';
    final QrCode qr = QrCode.fromData(
      data: text,
      errorCorrectLevel: QrErrorCorrectLevel.M,
    );
    final QrImage matrix = QrImage(qr);
    const int scale = 8;
    const int quiet = 4;
    final int width = (matrix.moduleCount + quiet * 2) * scale;
    final img.Image image = img.Image(width: width, height: width);
    img.fill(image, color: img.ColorRgb8(255, 255, 255));
    for (int y = 0; y < matrix.moduleCount; y++) {
      for (int x = 0; x < matrix.moduleCount; x++) {
        if (matrix.isDark(y, x)) {
          img.fillRect(
            image,
            x1: (x + quiet) * scale,
            y1: (y + quiet) * scale,
            x2: (x + quiet + 1) * scale - 1,
            y2: (y + quiet + 1) * scale - 1,
            color: img.ColorRgb8(0, 0, 0),
          );
        }
      }
    }

    expect(await decodeQrImage(Uint8List.fromList(img.encodePng(image))), text);
  });

  test('rejects empty, oversized and non-image input', () async {
    for (final Uint8List bytes in <Uint8List>[
      Uint8List(0),
      Uint8List(qrImageMaxBytes + 1),
      Uint8List.fromList(<int>[1, 2, 3]),
    ]) {
      expect(decodeQrImage(bytes), throwsA(isA<QrImageDecodeException>()));
    }
  });

  testWidgets('image import checks file access before opening the picker', (
    tester,
  ) async {
    final _PermissionGateway permissions = _PermissionGateway();
    final _QrGateway gateway = _QrGateway();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PairingImageImportButton(
            gateway: gateway,
            permissionGateway: permissions,
            onDecoded: (_) {},
          ),
        ),
      ),
    );

    await tester.tap(find.text('从图片导入'));
    await tester.pump();

    expect(permissions.checks, 1);
    expect(permissions.requests, 1);
    expect(gateway.picks, 0);
    expect(find.textContaining('无法访问系统文件选择器'), findsOneWidget);
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
    return PlatformPermissionState.denied;
  }

  @override
  Future<PlatformPermissionState> request(
    PlatformPermissionKind permission,
  ) async {
    requests++;
    return PlatformPermissionState.denied;
  }
}

class _QrGateway implements QrImageGateway {
  int picks = 0;

  @override
  Future<Uint8List?> pickImage() async {
    picks++;
    return null;
  }
}
