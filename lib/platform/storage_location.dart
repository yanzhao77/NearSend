import 'dart:convert';

enum StorageLocationKind {
  nativeDirectory('nativeDirectory'),
  androidDocumentTree('androidDocumentTree'),
  appPrivate('appPrivate');

  const StorageLocationKind(this.wireName);

  final String wireName;

  static StorageLocationKind parse(String value) => switch (value) {
    'nativeDirectory' => StorageLocationKind.nativeDirectory,
    'androidDocumentTree' => StorageLocationKind.androidDocumentTree,
    'appPrivate' => StorageLocationKind.appPrivate,
    _ => throw const FormatException('unsupported storage location kind'),
  };
}

enum StoragePermissionState {
  unknown('unknown'),
  granted('granted'),
  denied('denied'),
  unavailable('unavailable');

  const StoragePermissionState(this.wireName);

  final String wireName;

  static StoragePermissionState parse(String value) => switch (value) {
    'unknown' => StoragePermissionState.unknown,
    'granted' => StoragePermissionState.granted,
    'denied' => StoragePermissionState.denied,
    'unavailable' => StoragePermissionState.unavailable,
    _ => throw const FormatException('unsupported storage permission state'),
  };
}

/// A versioned reference to a platform-owned receive location.
///
/// [opaqueValue] is interpreted only by the matching platform adapter. In
/// particular, an Android document-tree URI is not a filesystem path.
class StorageLocationRef {
  const StorageLocationRef({
    required this.kind,
    required this.opaqueValue,
    required this.displayName,
    this.permissionState = StoragePermissionState.unknown,
    this.schemaVersion = currentSchemaVersion,
  });

  static const int currentSchemaVersion = 1;

  final int schemaVersion;
  final StorageLocationKind kind;
  final String opaqueValue;
  final String displayName;

  /// Runtime observation only. It is intentionally omitted from persisted JSON.
  final StoragePermissionState permissionState;

  StorageLocationRef withPermissionState(StoragePermissionState value) =>
      StorageLocationRef(
        schemaVersion: schemaVersion,
        kind: kind,
        opaqueValue: opaqueValue,
        displayName: displayName,
        permissionState: value,
      );

  String toPersistedValue() => jsonEncode(<String, Object>{
    'schemaVersion': schemaVersion,
    'kind': kind.wireName,
    'opaqueValue': opaqueValue,
    'displayName': displayName,
  });

  static StorageLocationRef fromPersistedValue(String value) {
    final String trimmed = value.trim();
    if (trimmed.isEmpty) {
      throw const FormatException('storage location is empty');
    }
    if (!trimmed.startsWith('{')) {
      return StorageLocationRef(
        kind: StorageLocationKind.nativeDirectory,
        opaqueValue: trimmed,
        displayName: _legacyDisplayName(trimmed),
      );
    }

    final Object? decoded = jsonDecode(trimmed);
    if (decoded is! Map<String, Object?>) {
      throw const FormatException('storage location must be a JSON object');
    }
    const Set<String> fields = <String>{
      'schemaVersion',
      'kind',
      'opaqueValue',
      'displayName',
    };
    if (decoded.keys.toSet().difference(fields).isNotEmpty ||
        fields.difference(decoded.keys.toSet()).isNotEmpty) {
      throw const FormatException(
        'storage location fields do not match schema',
      );
    }
    final Object? version = decoded['schemaVersion'];
    final Object? kind = decoded['kind'];
    final Object? opaqueValue = decoded['opaqueValue'];
    final Object? displayName = decoded['displayName'];
    if (version != currentSchemaVersion ||
        kind is! String ||
        opaqueValue is! String ||
        opaqueValue.trim().isEmpty ||
        displayName is! String ||
        displayName.trim().isEmpty) {
      throw const FormatException('storage location contains invalid values');
    }
    return StorageLocationRef(
      kind: StorageLocationKind.parse(kind),
      opaqueValue: opaqueValue,
      displayName: displayName,
    );
  }

  static StorageLocationRef fromPlatformValue(Object? value) {
    if (value is! Map) {
      throw const FormatException('platform storage location is not a map');
    }
    final Map<Object?, Object?> map = value.cast<Object?, Object?>();
    final Object? kind = map['kind'];
    final Object? opaqueValue = map['opaqueValue'];
    final Object? displayName = map['displayName'];
    final Object? permissionState = map['permissionState'];
    if (kind is! String ||
        opaqueValue is! String ||
        opaqueValue.trim().isEmpty ||
        displayName is! String ||
        displayName.trim().isEmpty ||
        permissionState is! String) {
      throw const FormatException('platform storage location is incomplete');
    }
    return StorageLocationRef(
      kind: StorageLocationKind.parse(kind),
      opaqueValue: opaqueValue,
      displayName: displayName,
      permissionState: StoragePermissionState.parse(permissionState),
    );
  }

  static String _legacyDisplayName(String value) {
    final List<String> segments = value
        .split(RegExp(r'[\\/]+'))
        .where((String segment) => segment.isNotEmpty)
        .toList();
    return segments.isEmpty ? '已迁移的保存位置' : segments.last;
  }

  @override
  bool operator ==(Object other) =>
      other is StorageLocationRef &&
      other.schemaVersion == schemaVersion &&
      other.kind == kind &&
      other.opaqueValue == opaqueValue &&
      other.displayName == displayName &&
      other.permissionState == permissionState;

  @override
  int get hashCode => Object.hash(
    schemaVersion,
    kind,
    opaqueValue,
    displayName,
    permissionState,
  );

  @override
  String toString() => 'StorageLocationRef(${kind.wireName}, $displayName)';
}
