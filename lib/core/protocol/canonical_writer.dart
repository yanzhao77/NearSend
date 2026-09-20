/// Big-endian byte writer for the canonical digest encodings.
///
/// `docs/protocol/v1.0-draft1.md` §5.2 requires fixed-width, unsigned, big-endian
/// integers and explicitly forbids hashing JSON text or relying on a language's
/// default serialization or host byte order. Bytes are therefore assembled
/// explicitly here rather than via any encoder supplied by the SDK.
library;

import 'dart:typed_data';

/// Assembles the byte sequences that LFTM1 and LFTC1 are defined over.
///
/// Every setter asserts the value range because a silent truncation would produce
/// a digest that is wrong but self-consistent — the most dangerous failure mode
/// for a protocol that exists to detect corruption.
class CanonicalWriter {
  CanonicalWriter();

  final BytesBuilder _builder = BytesBuilder(copy: false);

  /// Bytes written so far.
  int get length => _builder.length;

  /// Writes the ASCII bytes of [value]. Throws if [value] is not ASCII, because
  /// the protocol's prefixes and separators are deliberately ASCII-only.
  void ascii(String value) {
    final int codeUnits = value.length;
    final Uint8List out = Uint8List(codeUnits);
    for (int i = 0; i < codeUnits; i++) {
      final int unit = value.codeUnitAt(i);
      if (unit > 0x7F) {
        throw ArgumentError.value(value, 'value', 'expected ASCII');
      }
      out[i] = unit;
    }
    _builder.add(out);
  }

  /// Writes a single byte. Used for the zero separator after each magic.
  void u8(int value) {
    _checkRange(value, 0xFF, 'u8');
    _builder.addByte(value);
  }

  void u16(int value) {
    _checkRange(value, 0xFFFF, 'u16');
    final Uint8List bytes = Uint8List(2);
    bytes.buffer.asByteData().setUint16(0, value, Endian.big);
    _write(bytes);
  }

  void u32(int value) {
    _checkRange(value, 0xFFFFFFFF, 'u32');
    final Uint8List bytes = Uint8List(4);
    bytes.buffer.asByteData().setUint32(0, value, Endian.big);
    _write(bytes);
  }

  /// Writes an unsigned 64-bit big-endian integer.
  ///
  /// Dart's native `int` is signed 64-bit, so the protocol's `0..2^63-1` range is
  /// fully representable; values above that are rejected by
  /// `protocol_validation.dart` before reaching this writer.
  void u64(int value) {
    if (value < 0) {
      throw ArgumentError.value(value, 'value', 'u64 must be non-negative');
    }
    final Uint8List bytes = Uint8List(8);
    bytes.buffer.asByteData().setUint64(0, value, Endian.big);
    _write(bytes);
  }

  /// Writes [value] verbatim.
  void raw(List<int> value) => _builder.add(value);

  /// Returns the assembled bytes.
  Uint8List toBytes() => _builder.toBytes();

  void _write(Uint8List bytes) => _builder.add(bytes);

  static void _checkRange(int value, int max, String kind) {
    if (value < 0 || value > max) {
      throw ArgumentError.value(value, 'value', 'out of range for $kind');
    }
  }
}
