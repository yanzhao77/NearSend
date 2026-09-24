import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:zxing2/qrcode.dart';

const int qrImageMaxBytes = 16 * 1024 * 1024;
const int qrImageMaxPixels = 16 * 1024 * 1024;

class QrImageDecodeException implements Exception {
  const QrImageDecodeException();

  @override
  String toString() => 'QrImageDecodeException';
}

abstract interface class QrImageGateway {
  Future<Uint8List?> pickImage();
}

class MethodChannelQrImageGateway implements QrImageGateway {
  MethodChannelQrImageGateway({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(channelName);

  static const String channelName = 'com.nearsend.app/qr';

  final MethodChannel _channel;

  @override
  Future<Uint8List?> pickImage() async {
    final Uint8List? bytes = await _channel.invokeMethod<Uint8List>(
      'pickImage',
    );
    if (bytes == null) return null;
    if (bytes.isEmpty || bytes.length > qrImageMaxBytes) {
      throw const QrImageDecodeException();
    }
    return bytes;
  }
}

Future<String> decodeQrImage(Uint8List bytes) async {
  if (bytes.isEmpty || bytes.length > qrImageMaxBytes) {
    throw const QrImageDecodeException();
  }
  try {
    return await Isolate.run<String>(() => _decodeQrImage(bytes));
  } on Object {
    throw const QrImageDecodeException();
  }
}

String _decodeQrImage(Uint8List bytes) {
  final img.Image? image = img.decodeImage(bytes);
  if (image == null ||
      image.width < 1 ||
      image.height < 1 ||
      image.width * image.height > qrImageMaxPixels) {
    throw const QrImageDecodeException();
  }
  final Int32List pixels = Int32List(image.width * image.height);
  int offset = 0;
  for (final img.Pixel pixel in image) {
    pixels[offset++] =
        (pixel.a.toInt() << 24) |
        (pixel.r.toInt() << 16) |
        (pixel.g.toInt() << 8) |
        pixel.b.toInt();
  }
  final BinaryBitmap bitmap = BinaryBitmap(
    HybridBinarizer(RGBLuminanceSource(image.width, image.height, pixels)),
  );
  final String text = QRCodeReader().decode(bitmap).text;
  if (text.isEmpty) throw const QrImageDecodeException();
  return text;
}
