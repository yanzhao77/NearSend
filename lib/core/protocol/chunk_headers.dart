/// The chunk request and response rules of `docs/protocol/v1.0-draft1.md` §8.
///
/// §8 fixes a small set of rules with an unusually large blast radius:
///
/// > 要求 Content-Type: application/octet-stream、**单一 Content-Length**；不支持
/// > Transfer-Encoding，不允许压缩，拒绝 Content-Length/Transfer-Encoding 同时出现。
/// > body 长度必须等于该块预期长度，**末尾额外数据拒绝并关闭连接**。
/// > 任务相关请求头：Authorization: Bearer taskAccessToken、X-LFT-Lease-Epoch、
/// > X-LFT-Manifest-Digest。服务端 GET 返回 Content-Length 和 X-LFT-Chunk-SHA256；
/// > **接收者仍以冻结清单为权威**。
///
/// These are the framing rules that request smuggling lives in: a message whose length two
/// hops disagree about is a message that can be split into two. So they are decided here,
/// as a pure function over the headers a request arrived with, rather than inside an HTTP
/// handler where the decision would be tangled with reading the body - and, more to the
/// point, where it could not be tested without a socket.
///
/// ## What "single Content-Length" has to mean in a header map
///
/// A header map cannot hold the same name twice, so a repeated header arrives either as two
/// entries that differ only in case, or as one value with the two joined by a comma. Both
/// are refused here, because both are how a peer says "there are two lengths" - and the
/// second is exactly the classic disagreement between two parsers.
///
/// ## The frozen manifest wins
///
/// §8 keeps the response's `X-LFT-Chunk-SHA256` advisory: the receiver verifies against the
/// frozen manifest either way. [ChunkGetResponseHeaders.agreesWithManifest] reports whether
/// the peer's claim matched, for diagnostics - and deliberately does not turn a
/// disagreement into a refusal, because refusing on the advisory field would hand a peer
/// the power to fail a download it could not otherwise affect.
library;

import 'package:nearsend/core/protocol/protocol_exception.dart';
import 'package:nearsend/core/protocol/protocol_validation.dart';
import 'package:nearsend/core/protocol/wire_error.dart';

/// The media type §8 requires for a chunk body.
const String chunkContentType = 'application/octet-stream';

/// The header carrying the write generation (§8).
const String leaseEpochHeader = 'X-LFT-Lease-Epoch';

/// The header binding a chunk to the manifest it belongs to (§8).
const String manifestDigestHeader = 'X-LFT-Manifest-Digest';

/// The advisory digest a chunk `GET` returns (§8).
const String chunkSha256Header = 'X-LFT-Chunk-SHA256';

/// The prefix this project owns in the header space.
const String _headerPrefix = 'x-lft-';

/// The validated headers of a chunk `PUT`.
class ChunkPutHeaders {
  const ChunkPutHeaders({
    required this.contentLength,
    required this.taskAccessToken,
    required this.leaseEpoch,
    required this.manifestDigest,
  });

  /// The declared body length, which must equal the expected chunk length.
  final int contentLength;

  /// The task access token from `Authorization: Bearer`.
  final String taskAccessToken;

  /// The write generation the sender believes it holds.
  final int leaseEpoch;

  /// The manifest the chunk belongs to.
  final String manifestDigest;

  /// Reads and validates the headers a chunk `PUT` carried.
  ///
  /// Throws [ProtocolViolation] for anything §8 does not allow. The check is complete
  /// before any of the body is read, so a message that fails framing is never partly
  /// processed.
  static ChunkPutHeaders parse(Map<String, String> headers) {
    final Map<String, String> lowered = _lowercaseHeaders(headers);

    // --- Framing first: a message whose length is ambiguous must not be read at all. ---
    if (lowered.containsKey('transfer-encoding')) {
      throw const ProtocolViolation(
        ProtocolErrorCode.invalidField,
        'a chunk request must not carry Transfer-Encoding',
      );
    }
    final String? encoding = lowered['content-encoding'];
    if (encoding != null && encoding.toLowerCase() != 'identity') {
      throw ProtocolViolation(
        ProtocolErrorCode.invalidField,
        'a chunk request must not be compressed',
      );
    }

    final String? contentType = lowered['content-type'];
    if (contentType == null) {
      throw const ProtocolViolation(
        ProtocolErrorCode.invalidField,
        'a chunk request must declare Content-Type: $chunkContentType',
      );
    }
    if (contentType.toLowerCase() != chunkContentType) {
      throw ProtocolViolation(
        ProtocolErrorCode.invalidField,
        'a chunk request must use Content-Type: $chunkContentType',
      );
    }

    final String? length = lowered['content-length'];
    if (length == null) {
      throw const ProtocolViolation(
        ProtocolErrorCode.invalidField,
        'a chunk request must declare exactly one Content-Length',
      );
    }
    if (length.contains(',')) {
      // Two joined lengths are two answers to one question, which is how two hops come to
      // disagree about where a message ends.
      throw const ProtocolViolation(
        ProtocolErrorCode.invalidField,
        'a chunk request must carry a single Content-Length',
      );
    }
    final int contentLength = _parseContentLength(length);

    // --- Identity and generation. ---
    final String taskAccessToken = BearerHeader.parse(lowered['authorization']);

    final String? epoch = lowered[leaseEpochHeader.toLowerCase()];
    if (epoch == null) {
      throw const ProtocolViolation(
        ProtocolErrorCode.invalidField,
        'a chunk request must carry $leaseEpochHeader',
      );
    }
    final int leaseEpoch = parseDecimalString(epoch, leaseEpochHeader);

    final String? digest = lowered[manifestDigestHeader.toLowerCase()];
    if (digest == null) {
      throw const ProtocolViolation(
        ProtocolErrorCode.invalidField,
        'a chunk request must carry $manifestDigestHeader',
      );
    }
    sha256HexToBytes(digest, manifestDigestHeader);

    _rejectUnknownProjectHeaders(lowered);

    return ChunkPutHeaders(
      contentLength: contentLength,
      taskAccessToken: taskAccessToken,
      leaseEpoch: leaseEpoch,
      manifestDigest: digest,
    );
  }

  @override
  String toString() => 'ChunkPutHeaders($contentLength B, epoch $leaseEpoch)';
}

/// The headers a chunk `GET` returns (§8).
class ChunkGetResponseHeaders {
  const ChunkGetResponseHeaders({
    required this.contentLength,
    required this.chunkSha256,
  });

  /// The number of bytes the body will carry.
  final int contentLength;

  /// The peer's claim about the chunk's digest.
  ///
  /// **Advisory.** §8: "接收者仍以冻结清单为权威", so this value never decides whether the
  /// bytes are accepted - it is compared against the manifest's digest and reported.
  final String chunkSha256;

  /// Whether the peer's claim agrees with the frozen manifest.
  ///
  /// A false result is **not** a reason to refuse the response: the bytes are verified
  /// against the manifest either way. It exists so diagnostics can show that the peer said
  /// something different, which is worth knowing and not worth trusting.
  bool agreesWithManifest(String frozenFileSha256) =>
      chunkSha256.toLowerCase() == frozenFileSha256.toLowerCase();

  /// Builds the response headers §8 lists.
  Map<String, String> toHeaders() => <String, String>{
    'Content-Length': contentLength.toString(),
    chunkSha256Header: chunkSha256,
  };

  /// Reads the headers of a chunk `GET` response.
  static ChunkGetResponseHeaders parse(Map<String, String> headers) {
    final Map<String, String> lowered = _lowercaseHeaders(headers);

    final String? digest = lowered[chunkSha256Header.toLowerCase()];
    if (digest == null) {
      throw const ProtocolViolation(
        ProtocolErrorCode.invalidField,
        'a chunk response must carry $chunkSha256Header',
      );
    }
    sha256HexToBytes(digest, chunkSha256Header);

    final String? length = lowered['content-length'];
    if (length == null || length.contains(',')) {
      throw const ProtocolViolation(
        ProtocolErrorCode.invalidField,
        'a chunk response must carry a single Content-Length',
      );
    }

    return ChunkGetResponseHeaders(
      contentLength: _parseContentLength(length),
      chunkSha256: digest,
    );
  }

  @override
  String toString() => 'ChunkGetResponseHeaders($contentLength B)';
}

/// §8: "body 长度必须等于该块预期长度，末尾额外数据拒绝并关闭连接".
///
/// [receivedBytes] is how much the body actually produced and [expectedBytes] what the
/// frozen manifest requires. A short body means the message ended early - possibly because
/// two hops disagreed about the framing - and a long one means bytes were appended after
/// the chunk the sender declared.
///
/// Both are refused with `INVALID_FIELD`: §11 pairs that with "修正请求，不自动原样重试",
/// which is the right instruction for a message whose framing is wrong. Re-sending it
/// unchanged would repeat the same disagreement.
void assertChunkBodyLength({
  required int receivedBytes,
  required int expectedBytes,
}) {
  if (receivedBytes == expectedBytes) {
    return;
  }
  throw ProtocolViolation(
    ProtocolErrorCode.invalidField,
    receivedBytes > expectedBytes
        ? 'the chunk body carried $receivedBytes bytes but the frozen manifest requires '
              '$expectedBytes; trailing data after the chunk is refused and the '
              'connection closed'
        : 'the chunk body carried $receivedBytes bytes but the frozen manifest requires '
              '$expectedBytes',
  );
}

/// Parses a `Content-Length` per HTTP's grammar, which is one or more digits.
///
/// Leading zeros are accepted because HTTP allows them and the value is what matters; the
/// §4 canonical form is a rule about protocol fields, not about this header. The value that
/// comes out is then checked against the manifest by [assertChunkBodyLength].
///
/// The zeros are stripped **before** the range is decided, and the range is decided by
/// [parseNormalizedDigits] rather than by `int.parse`. HTTP puts no bound on the digit
/// count, so `Content-Length: 99999999999999999999999` is a shape this parser accepts and
/// `int.parse` answers with a raw `FormatException` - an unhandled platform error where
/// §8 requires a malformed request to be refused. Stripping first also keeps a long run of
/// leading zeros working, since that is a legal `Content-Length` of the value it wraps.
int _parseContentLength(String value) {
  if (value.isEmpty || !RegExp(r'^[0-9]+$').hasMatch(value)) {
    throw const ProtocolViolation(
      ProtocolErrorCode.invalidField,
      'Content-Length must be one or more digits',
    );
  }
  try {
    return parseNormalizedDigits(stripLeadingZeros(value), 'Content-Length');
  } on ProtocolViolation {
    // §11 pairs a malformed field with INVALID_FIELD, and a length no implementation can
    // hold is a malformed field rather than a wrong decimal elsewhere in the protocol.
    throw const ProtocolViolation(
      ProtocolErrorCode.invalidField,
      'Content-Length is larger than any length this protocol can carry',
    );
  }
}

/// Lowercases header names, refusing two names that differ only in case.
///
/// HTTP field names are case-insensitive, so `Content-Length` and `content-length` are the
/// same field - and a message that carries both is a message with two lengths, which §8
/// refuses. Folding them silently would pick one, and which one a given implementation
/// picks is exactly the disagreement this is meant to prevent.
Map<String, String> _lowercaseHeaders(Map<String, String> headers) {
  final Map<String, String> out = <String, String>{};
  for (final MapEntry<String, String> entry in headers.entries) {
    final String name = entry.key.toLowerCase();
    if (out.containsKey(name)) {
      throw ProtocolViolation(
        ProtocolErrorCode.invalidField,
        'the request carries "$name" more than once',
      );
    }
    out[name] = entry.value.trim();
  }
  return out;
}

/// Refuses an unknown header in the namespace this project owns.
///
/// Headers outside it are ignored: HTTP carries many that have nothing to do with this
/// protocol, so refusing them all would be wrong. The `X-LFT-` prefix is ours, so a
/// parameter one implementation honours and another drops cannot hide there - which is the
/// same reason §4 refuses an undefined JSON field.
void _rejectUnknownProjectHeaders(Map<String, String> lowered) {
  const Set<String> known = <String>{
    'content-type',
    'content-length',
    'content-encoding',
    'transfer-encoding',
    'authorization',
    'x-lft-lease-epoch',
    'x-lft-manifest-digest',
  };
  for (final String name in lowered.keys) {
    if (name.startsWith(_headerPrefix) && !known.contains(name)) {
      throw ProtocolViolation(
        ProtocolErrorCode.invalidField,
        'the request carries an undefined header in this protocol\'s namespace',
      );
    }
  }
}
