import 'dart:io';
import 'dart:typed_data';

import 'package:nearsend/platform/android_file_gateway.dart';

/// Where a sender's bytes come from, as one port both a path and a SAF URI can satisfy.
///
/// ## Why this exists
///
/// `AGENTS.md` §9: "Android SAF URI、iOS 安全作用域资源和 Windows 存储句柄通过平台存储适配层处理，
/// **不得假设它们都是普通磁盘路径**". The sending path was written against `dart:io`'s `File`, which a
/// `content://` URI is not, so a device could receive but never send. This is the seam that removes
/// that assumption: planning reads [length] and then [readAt], which is all a manifest needs, and
/// neither a path nor a document provider has to be privileged over the other.
///
/// ## Why it is offset-based rather than a stream
///
/// §5.2's and §5.3's digests are computed over **fixed-length chunks** at known offsets, and §8
/// re-reads a specific chunk when a resume asks for it. An offset-addressed port expresses both, and
/// it makes the memory bound explicit: [readAt] returns at most the length asked for, and the caller
/// asks for one protocol chunk. A stream would leave "how much is in flight" to whoever consumes it,
/// which is the property `AGENTS.md` §2 rule 4 is about.
///
/// ## The one thing implementers must get right
///
/// [readAt] must return **fewer** bytes when the source ends, never a padded buffer. §5.3 fixes each
/// chunk's length, so padding produces a chunk that fails its digest with nothing in the diagnostic
/// to say why.
abstract class SourceBytes {
  /// A display handle for diagnostics.
  ///
  /// **Never** put a path or a URI here: §7 keeps a full local path out of an error body and
  /// `AGENTS.md` §5 keeps user file locations out of diagnostics. "file" and "saf" are all a
  /// diagnostic needs, and all it is allowed to have.
  String get diagnosticLabel;

  /// The source's length in bytes.
  Future<int> length();

  /// Reads at most [length] bytes at [offset].
  ///
  /// Shorter means the source ended.
  Future<Uint8List> readAt({required int offset, required int length});
}

/// A source that is a real file, on any platform that has paths.
class FileSourceBytes implements SourceBytes {
  FileSourceBytes(this.file);

  final File file;

  /// A display handle for diagnostics. **Never** put this in an error body: §7 keeps a full local
  /// path out of one, and `AGENTS.md` §5 keeps user file locations out of diagnostics.
  @override
  String get diagnosticLabel => 'file';

  @override
  Future<int> length() => file.length();

  @override
  Future<Uint8List> readAt({required int offset, required int length}) async {
    if (length <= 0) {
      return Uint8List(0);
    }
    final RandomAccessFile handle = await file.open();
    try {
      await handle.setPosition(offset);
      final Uint8List buffer = Uint8List(length);
      int filled = 0;
      while (filled < length) {
        // A single read may return less than asked for even mid-file, so this loops; treating a
        // short read as end-of-file would silently truncate a chunk.
        final int read = await handle.readInto(buffer, filled, length - filled);
        if (read <= 0) {
          break;
        }
        filled += read;
      }
      return filled == length
          ? buffer
          : Uint8List.sublistView(buffer, 0, filled);
    } finally {
      await handle.close();
    }
  }
}

/// A source that is a SAF document.
///
/// The channel already reads by offset with a bounded buffer, so this adapter adds nothing but the
/// port: the rule about not buffering the file lives in `MainActivity`, and this is where the caller
/// hands it a length it chose rather than one the file has.
class SafSourceBytes implements SourceBytes {
  SafSourceBytes({
    required this.gateway,
    required this.uri,
    required this.providerReportedSize,
  });

  final AndroidFileGateway gateway;

  /// The opaque document URI. Never rendered.
  final String uri;

  /// What the provider said, or null when it would not say.
  ///
  /// Null is kept as null through to [length] failing rather than being replaced by a guess: §5.2
  /// hashes the size into the manifest, so an invented one describes a different file, and the
  /// honest thing is to say the length is unknown.
  final int? providerReportedSize;

  @override
  String get diagnosticLabel => 'saf';

  @override
  Future<int> length() async {
    final int? size = providerReportedSize;
    if (size == null) {
      throw const PlatformFileFailure(
        'the provider did not report a size, and the manifest needs the real one',
      );
    }
    return size;
  }

  @override
  Future<Uint8List> readAt({required int offset, required int length}) =>
      gateway.readChunk(uri: uri, offset: offset, length: length);
}
