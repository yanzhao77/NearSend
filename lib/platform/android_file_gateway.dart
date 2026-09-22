/// The Dart side of the Android file-access channel.
///
/// `AGENTS.md` 搂9 puts SAF URIs behind a platform storage adapter rather than letting application
/// code assume they are paths, and 搂4 keeps `lib/platform/` to "绯荤粺 API 鍜岃祫婧愮敓鍛藉懆鏈熼€傞厤锛屼笉澶嶅埗
/// 搴旂敤涓氬姟娴佺▼". So this file speaks the channel's language and nothing else: it does not know what a
/// chunk is for, does not decide what to do with a failure, and does not touch the database.
///
/// ## Why the interface and the channel are separate types
///
/// A widget test cannot run Kotlin, and the interesting behaviour here - refusing to buffer a whole
/// file, reporting an unknown size as unknown rather than zero, turning a missing permission into a
/// failure instead of a duplicate file - is behaviour the *callers* must implement. So the port is
/// an interface with an in-memory test double, and the channel implementation is one binding of it.
library;

import 'package:flutter/services.dart';

/// One document the user picked.
class PickedDocument {
  const PickedDocument({
    required this.uri,
    required this.displayName,
    required this.sizeBytes,
  });

  /// The SAF URI. Opaque: only the platform adapter can turn it into bytes.
  final String uri;

  final String displayName;

  /// The provider's answer, or null when it would not give one.
  ///
  /// **Null and 0 are different.** A provider that reports nothing is not a provider that reported
  /// an empty file, and the caller must not fold the two together: 搂5.2's manifest digest covers
  /// the real size, so a zero here would build a manifest for a file that does not exist.
  final int? sizeBytes;

  @override
  String toString() => 'PickedDocument($displayName)';
}

/// The platform file operations a transfer needs from Android.
abstract class AndroidFileGateway {
  /// Opens the system picker and returns what the user chose.
  ///
  /// An empty list means the user cancelled, which is not an error.
  Future<List<PickedDocument>> pickFiles();

  /// Reads at most [length] bytes at [offset] of [uri].
  ///
  /// A shorter result means the document ended; callers must treat that as a short read rather
  /// than padding it, because 搂5.3's chunk lengths are fixed and a padded chunk would fail its
  /// digest with no explanation of why.
  Future<Uint8List> readChunk({
    required String uri,
    required int offset,
    required int length,
  });

  /// Begins a write to [uri], replacing its content.
  Future<void> beginWrite({required String uri});

  /// Writes [bytes] at [offset].
  Future<void> writeChunk({
    required String uri,
    required int offset,
    required Uint8List bytes,
  });

  /// Ends a write, making it durable.
  ///
  /// Separate from [abortWrite] because the two are different statements: one says the document is
  /// what the sender described, the other says it is not and must not be treated as if it were.
  Future<void> endWrite({required String uri});

  /// Ends a write without claiming the document is complete.
  Future<void> abortWrite({required String uri});
}

/// The channel binding.
class MethodChannelAndroidFileGateway implements AndroidFileGateway {
  MethodChannelAndroidFileGateway({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(channelName);

  /// Matches `MainActivity`'s channel. One definition per side; a typo on either shows up as a
  /// missing-plugin error on the first call rather than as silence.
  static const String channelName = 'com.nearsend.app/files';

  final MethodChannel _channel;

  @override
  Future<List<PickedDocument>> pickFiles() async {
    final Object? result = await _channel.invokeMethod<Object?>('pickFiles');
    if (result is! List) {
      throw const PlatformFileFailure(
        'the picker returned something that is not a list',
      );
    }
    return <PickedDocument>[
      for (final Object? entry in result)
        _documentFrom((entry! as Map).cast<Object?, Object?>()),
    ];
  }

  @override
  Future<Uint8List> readChunk({
    required String uri,
    required int offset,
    required int length,
  }) async {
    final Uint8List? bytes = await _channel.invokeMethod<Uint8List>(
      'readChunk',
      <String, Object?>{'uri': uri, 'offset': offset, 'length': length},
    );
    if (bytes == null) {
      throw const PlatformFileFailure('the provider returned no bytes');
    }
    return bytes;
  }

  @override
  Future<void> beginWrite({required String uri}) async {
    await _channel.invokeMethod<bool>('beginWrite', <String, Object?>{
      'uri': uri,
    });
  }

  @override
  Future<void> writeChunk({
    required String uri,
    required int offset,
    required Uint8List bytes,
  }) async {
    await _channel.invokeMethod<int>('writeChunk', <String, Object?>{
      'uri': uri,
      'offset': offset,
      'bytes': bytes,
    });
  }

  @override
  Future<void> endWrite({required String uri}) async {
    await _channel.invokeMethod<bool>('endWrite', <String, Object?>{
      'uri': uri,
    });
  }

  @override
  Future<void> abortWrite({required String uri}) async {
    await _channel.invokeMethod<bool>('abortWrite', <String, Object?>{
      'uri': uri,
    });
  }

  PickedDocument _documentFrom(Map<Object?, Object?> map) {
    final Object? uri = map['uri'];
    final Object? name = map['name'];
    final Object? size = map['sizeBytes'];
    if (uri is! String || name is! String) {
      throw const PlatformFileFailure(
        'a picked document arrived without a uri and a name',
      );
    }
    return PickedDocument(
      uri: uri,
      displayName: name,
      // A negative value is the channel's way of saying "the provider would not say". It becomes
      // null here so no caller can mistake it for a size.
      sizeBytes: size is int && size >= 0 ? size : null,
    );
  }
}

/// A failure from the platform adapter.
///
/// A distinct type rather than a bare string, so a caller can tell "the provider refused" from "the
/// user cancelled" and from a protocol refusal - three conditions with three different remedies, and
/// only one of which means the transfer is BLOCKED.
class PlatformFileFailure implements Exception {
  const PlatformFileFailure(this.detail);

  /// Deliberately generic: a platform message can carry a document id, and `AGENTS.md` 搂5 keeps user
  /// file locations out of diagnostics.
  final String detail;

  @override
  String toString() => 'PlatformFileFailure($detail)';
}

/// An in-memory gateway, for tests and for a desktop build that has no SAF.
///
/// It is a real implementation of the port rather than a mock that records calls: the tests that use
/// it exercise the same chunk arithmetic and the same "unknown size is not zero" rule the channel
/// binding has to satisfy, which is what makes the interface worth having.
class InMemoryFileGateway implements AndroidFileGateway {
  InMemoryFileGateway({Map<String, Uint8List>? documents})
    : _documents = <String, Uint8List>{...?documents};

  final Map<String, Uint8List> _documents;

  /// Documents the next [pickFiles] will return, in order.
  List<PickedDocument> nextPick = const <PickedDocument>[];

  /// How many bytes were written per URI, so a test can assert the whole file arrived.
  final Map<String, Uint8List> written = <String, Uint8List>{};

  @override
  Future<List<PickedDocument>> pickFiles() async => nextPick;

  @override
  Future<Uint8List> readChunk({
    required String uri,
    required int offset,
    required int length,
  }) async {
    final Uint8List? source = _documents[uri];
    if (source == null) {
      throw const PlatformFileFailure('no such document');
    }
    if (offset >= source.length) {
      return Uint8List(0);
    }
    final int end = offset + length > source.length
        ? source.length
        : offset + length;
    return Uint8List.sublistView(source, offset, end);
  }

  @override
  Future<void> beginWrite({required String uri}) async {
    written[uri] = Uint8List(0);
  }

  @override
  Future<void> writeChunk({
    required String uri,
    required int offset,
    required Uint8List bytes,
  }) async {
    final Uint8List current = written[uri] ?? Uint8List(0);
    final int needed = offset + bytes.length;
    final Uint8List grown = needed > current.length
        ? Uint8List(needed)
        : Uint8List(current.length);
    grown.setRange(0, current.length, current);
    grown.setRange(offset, offset + bytes.length, bytes);
    written[uri] = grown;
  }

  @override
  Future<void> endWrite({required String uri}) async {}

  @override
  Future<void> abortWrite({required String uri}) async {
    written.remove(uri);
  }
}
