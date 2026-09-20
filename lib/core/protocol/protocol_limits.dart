/// Numeric and size limits fixed by `docs/protocol/v1.0-draft1.md`.
///
/// These are protocol version parameters, not tunable application settings:
/// §5 fixes the chunk size for v1.0, and §5/§6 fix the paging and count limits.
/// Changing any of them requires new test vectors and a compatibility note, so
/// they live in one place that is easy to find and hard to edit by accident.
library;

abstract final class ProtocolLimits {
  /// Logical chunk size for protocol v1.0, fixed at 4 MiB (§5).
  ///
  /// It is the unit used by `chunkCount = ceil(sizeBytes / chunkSizeBytes)` and by
  /// `offset = index * chunkSizeBytes` (§8).
  static const int chunkSizeBytes = 4194304;

  /// Maximum files in one transfer (§5).
  static const int maxFilesPerTransfer = 10000;

  /// Maximum chunks in one transfer (§5).
  static const int maxChunksPerTransfer = 1048576;

  /// Relative path length bounds, measured in UTF-8 bytes (§5.1).
  static const int minPathBytes = 1;
  static const int maxPathBytes = 1024;

  /// Largest value a decimal string may carry: 2^63 - 1 (§4).
  static const int maxDecimalValue = 9223372036854775807;

  /// Longest permitted decimal string: `0`, or a non-zero digit plus 18 more
  /// digits (§4).
  static const int maxDecimalDigits = 19;

  /// Maximum files in one manifest page (§6).
  static const int filePageLimit = 128;

  /// Maximum chunk records in one manifest page (§6).
  static const int chunkPageLimit = 1024;

  /// Maximum control-body size in bytes (§4).
  static const int controlBodyMaxBytes = 1048576;

  /// Highest protocol minor version this implementation understands (§3).
  static const int protocolMajor = 1;
  static const int protocolMinor = 0;

  /// Number of bytes in a decoded UUID.
  static const int uuidBytes = 16;

  /// Number of bytes in a raw SHA-256 digest.
  static const int sha256Bytes = 32;

  /// Characters in the lowercase hexadecimal form of a SHA-256 digest.
  static const int sha256HexLength = 64;
}
