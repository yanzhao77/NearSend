/// The pairing handshake: comparing the server's identity before releasing a credential.
///
/// `docs/protocol/v1.0-draft1.md` §2 states the rule this file exists to make structural:
///
/// > 采用每连接隔离的信任上下文；**必须在发送令牌、HTTP 请求及文件内容之前完成指纹比对**。
/// > 即使证书受系统 CA 信任也必须比对 pin，不能只在"不可信证书回调"中比对。
///
/// A rule that says "compare before you send" is easy to write down and easy to get wrong,
/// because the failure is invisible: an implementation that sends the token first still
/// works against an honest server. So the token is not a field here. It is reachable only
/// through [PairingHandshake.pairingToken], and that getter refuses until the certificate
/// comparison has succeeded. There is no ordering for a caller to remember.
///
/// ## What the fingerprint is, exactly
///
/// §2: `fingerprint = SHA-256(服务端叶证书完整 DER)`, lowercase 64 hex. It is **not** the
/// digest of the PEM text and **not** the digest of the Subject Public Key Info. Both
/// alternatives have the same shape as the right answer, so getting this wrong produces a
/// plausible-looking pin that simply never matches - or, worse, one that matches the wrong
/// thing. [serverFingerprintOf] takes DER and nothing else, so the distinction is made at
/// the type of the argument.
///
/// ## Why the comparison is not constant-time
///
/// The fingerprint is published in the QR code the user is scanning. It is not a secret,
/// so a timing side channel on the comparison reveals nothing that the attacker did not
/// already have. Writing a hand-rolled constant-time comparison here would be inventing
/// cryptographic code to solve a problem this design does not have, which `AGENTS.md` §5
/// rules out.
library;

import 'package:crypto/crypto.dart';

import 'package:nearsend/core/protocol/protocol_exception.dart';
import 'package:nearsend/core/protocol/protocol_validation.dart';
import 'package:nearsend/core/security/pairing_payload.dart';

/// The protocol fingerprint of a leaf certificate: SHA-256 of its full DER encoding (§2).
///
/// The parameter type is `List<int>` rather than `String` deliberately: there is no
/// overload that accepts PEM text, so passing the wrong thing is a compile error rather
/// than a pin that never matches.
String serverFingerprintOf(List<int> leafCertificateDer) {
  if (leafCertificateDer.isEmpty) {
    throw const ProtocolViolation(
      ProtocolErrorCode.invalidField,
      'the leaf certificate encoding is empty',
    );
  }
  return bytesToSha256Hex(sha256.convert(leafCertificateDer).bytes);
}

/// The result of comparing a presented certificate against the pin.
enum PairingCertificateVerdict {
  /// The presented certificate is the one the QR code named.
  trusted,

  /// The presented certificate is not the one the QR code named.
  fingerprintMismatch,
}

/// One connection's pairing trust context (§2).
///
/// Scoped to a single connection on purpose: §2 requires the trust context to be
/// per-connection, so a context is not reusable after a failure and a new connection
/// needs a new one. Reusing one would carry a verdict across connection boundaries, which
/// is exactly the state §2 keeps out of the design.
class PairingHandshake {
  PairingHandshake({required this.payload});

  /// What the user scanned.
  final PairingPayload payload;

  bool _verified = false;
  bool _closed = false;

  /// Whether the pin comparison has succeeded on this connection.
  bool get isVerified => _verified;

  /// Whether this connection is finished and must not be used or reused.
  ///
  /// §2 closes the connection on a failed comparison rather than continuing with a
  /// warning, so a mismatch is terminal for this context.
  bool get isClosed => _closed;

  /// Whether the credential may be released.
  bool get mayReleaseCredentials => _verified && !_closed;

  /// Compares the presented leaf certificate against the pin from the QR code.
  ///
  /// Takes the certificate as DER because that is what §2 digests. The caller is expected
  /// to have obtained it from the TLS layer of *this* connection, after the handshake and
  /// before sending anything; §2 forbids skipping the comparison because a system CA
  /// already trusted the chain, so there is no argument or flag here that expresses
  /// "already trusted".
  ///
  /// A mismatch closes the context permanently and returns
  /// [PairingCertificateVerdict.fingerprintMismatch]. Throwing on a repeat call is
  /// deliberate: continuing to negotiate on a connection whose peer failed its identity
  /// check is how a retry loop becomes an attack.
  ///
  /// The invariant is "closed unless the comparison explicitly returned trusted", so an
  /// unusable encoding closes the connection too. A certificate the TLS layer could not
  /// produce is still a peer whose identity was not established, and leaving the context
  /// open would mean the state after a failed attempt is something a caller has to reason
  /// about.
  PairingCertificateVerdict verifyServerCertificate(
    List<int> leafCertificateDer,
  ) {
    if (_closed) {
      throw const ProtocolViolation(
        ProtocolErrorCode.pairRejected,
        'this pairing connection is closed',
      );
    }

    final String presented;
    try {
      presented = serverFingerprintOf(leafCertificateDer);
    } on ProtocolViolation {
      _closed = true;
      _verified = false;
      rethrow;
    }

    if (presented != payload.serverFingerprint.toLowerCase()) {
      _closed = true;
      _verified = false;
      return PairingCertificateVerdict.fingerprintMismatch;
    }

    _verified = true;
    return PairingCertificateVerdict.trusted;
  }

  /// The one-time pairing token, for the `POST /v1/pair` body.
  ///
  /// Refuses until the certificate has been compared and matched. This is the whole point
  /// of the class: §2 requires the comparison to happen before the token is sent, and a
  /// caller that has not done it cannot obtain the token at all.
  ///
  /// The token is returned as the canonical unpadded base64url text of §4, which is what
  /// the request body carries. It is never placed in a URL (§3).
  String get pairingToken {
    if (_closed) {
      throw const ProtocolViolation(
        ProtocolErrorCode.pairRejected,
        'this pairing connection is closed; the pairing token is not available',
      );
    }
    if (!_verified) {
      throw const ProtocolViolation(
        ProtocolErrorCode.pairRejected,
        'the server certificate has not been compared against the pairing '
        'fingerprint; the pairing token must not be sent before that comparison',
      );
    }
    return payload.pairToken;
  }

  /// Closes the connection without a comparison, for a user cancellation or a timeout.
  void abandon() {
    _closed = true;
    _verified = false;
  }
}
