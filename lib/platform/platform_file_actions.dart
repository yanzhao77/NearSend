import 'dart:convert';

import 'package:flutter/services.dart';

enum PlatformFileActionStatus {
  completed,
  unsupported,
  unavailable,
  permissionDenied,
  failed,
}

class PlatformFileActionResult {
  const PlatformFileActionResult(this.status);

  final PlatformFileActionStatus status;

  bool get succeeded => status == PlatformFileActionStatus.completed;
}

abstract interface class PlatformFileActions {
  bool get supportsOpen;

  bool get supportsReveal;

  Future<PlatformFileActionResult> open(String targetRef);

  Future<PlatformFileActionResult> reveal(String targetRef);
}

class UnavailablePlatformFileActions implements PlatformFileActions {
  const UnavailablePlatformFileActions();

  @override
  bool get supportsOpen => false;

  @override
  bool get supportsReveal => false;

  @override
  Future<PlatformFileActionResult> open(String targetRef) async =>
      const PlatformFileActionResult(PlatformFileActionStatus.unsupported);

  @override
  Future<PlatformFileActionResult> reveal(String targetRef) async =>
      const PlatformFileActionResult(PlatformFileActionStatus.unsupported);
}

class MethodChannelPlatformFileActions implements PlatformFileActions {
  MethodChannelPlatformFileActions({
    MethodChannel? channel,
    this.supportsReveal = true,
  }) : _channel = channel ?? const MethodChannel(channelName);

  static const String channelName = 'com.nearsend.app/files';
  static const int maxTargetRefBytes = 8192;

  final MethodChannel _channel;

  @override
  final bool supportsReveal;

  @override
  bool get supportsOpen => true;

  @override
  Future<PlatformFileActionResult> open(String targetRef) =>
      _invoke('openSavedFile', targetRef);

  @override
  Future<PlatformFileActionResult> reveal(String targetRef) =>
      _invoke('revealSavedFile', targetRef);

  Future<PlatformFileActionResult> _invoke(
    String method,
    String targetRef,
  ) async {
    if (!_isValidRef(targetRef)) {
      return const PlatformFileActionResult(
        PlatformFileActionStatus.unavailable,
      );
    }
    try {
      final Object? value = await _channel.invokeMethod<Object?>(
        method,
        <String, Object?>{'targetRef': targetRef},
      );
      if (value is! Map) {
        return const PlatformFileActionResult(PlatformFileActionStatus.failed);
      }
      final Object? status = value['status'];
      return PlatformFileActionResult(switch (status) {
        'completed' => PlatformFileActionStatus.completed,
        'unsupported' => PlatformFileActionStatus.unsupported,
        'unavailable' => PlatformFileActionStatus.unavailable,
        'permissionDenied' => PlatformFileActionStatus.permissionDenied,
        _ => PlatformFileActionStatus.failed,
      });
    } on PlatformException catch (error) {
      return PlatformFileActionResult(
        error.code == 'NS-FILE-PERMISSION'
            ? PlatformFileActionStatus.permissionDenied
            : PlatformFileActionStatus.failed,
      );
    } on Object {
      return const PlatformFileActionResult(PlatformFileActionStatus.failed);
    }
  }

  static bool _isValidRef(String value) {
    if (value.isEmpty || value.trim() != value) return false;
    if (utf8.encode(value).length > maxTargetRefBytes) return false;
    return !value.codeUnits.any((int unit) => unit < 0x20 || unit == 0x7f);
  }
}

String platformFileActionMessage(
  PlatformFileActionResult result, {
  required bool reveal,
}) => switch (result.status) {
  PlatformFileActionStatus.completed => reveal ? '已在系统中显示文件。' : '已交给系统打开。',
  PlatformFileActionStatus.unsupported =>
    reveal ? '当前平台不支持显示文件位置。' : '当前平台不支持打开该文件。',
  PlatformFileActionStatus.unavailable => '文件或保存位置已不可用。',
  PlatformFileActionStatus.permissionDenied => '保存位置权限已失效，请重新选择或授权。',
  PlatformFileActionStatus.failed => reveal ? '无法显示文件位置。' : '无法打开文件。',
};
