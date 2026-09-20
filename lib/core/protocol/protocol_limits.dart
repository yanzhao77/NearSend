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

  /// Maximum nesting depth of a control body (§4).
  ///
  /// The limit is enforced *while* scanning rather than after parsing, so a hostile body
  /// cannot turn the parser itself into a stack overflow.
  static const int maxJsonDepth = 16;

  /// Maximum length of an error `message` on the wire (§7).
  ///
  /// §7 requires the message to carry no secret and no full local path; bounding it also
  /// stops a peer from using the field as a channel.
  static const int wireMessageMaxBytes = 256;

  /// How long a staging proposal may stay incomplete (§6).
  ///
  /// §6: "首次收到内容后 30 分钟 staging 未完成则清理并撤销该提议；不影响已经冻结的任务".
  /// The window runs from the first content, not from the offer, so a proposal nobody
  /// started uploading does not expire underneath a client that is still deciding.
  static const int stagingTimeoutSeconds = 1800;

  /// Highest protocol minor version this implementation understands (§3).
  static const int protocolMajor = 1;
  static const int protocolMinor = 0;

  /// Number of bytes in a decoded UUID.
  static const int uuidBytes = 16;

  /// Number of bytes in a raw SHA-256 digest.
  static const int sha256Bytes = 32;

  /// Characters in the lowercase hexadecimal form of a SHA-256 digest.
  static const int sha256HexLength = 64;

  // --- Pairing (§3). These are protocol values, not application settings. ---

  /// Maximum size of the pairing QR payload, in UTF-8 bytes (§3).
  static const int pairingQrMaxBytes = 4096;

  /// Maximum candidate addresses in one pairing QR code (§3).
  static const int pairingCandidatesMax = 8;

  /// Number of random bytes in a pairing token (§3).
  static const int pairTokenBytes = 32;

  /// Characters in the unpadded base64url form of [pairTokenBytes] (§4).
  ///
  /// 32 bytes encode to 43 characters: ceil(32 / 3) * 4 = 44 with one `=` of padding,
  /// which §4 removes.
  static const int pairTokenChars = 43;

  /// Number of random bytes in a session access token (§3).
  static const int accessTokenBytes = 32;

  /// Lifetime of a pairing token, in seconds (§3).
  ///
  /// §3 also says `expiresInSeconds` in the QR code is only a hint and the server's
  /// state decides, so this is the value the issuer enforces rather than one the
  /// scanner may rely on.
  static const int pairTokenTtlSeconds = 300;

  /// Lifetime of a session access token, in seconds (§3).
  static const int sessionAccessTokenTtlSeconds = 1800;

  /// Maximum length of `clientLabel`, in UTF-8 bytes (§3).
  ///
  /// It is shown to a person and is explicitly not an identity, so it is bounded but
  /// never trusted.
  static const int clientLabelMaxBytes = 128;

  /// Highest port number a candidate may carry (§3).
  static const int maxPort = 65535;
}
