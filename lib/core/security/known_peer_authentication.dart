import 'dart:convert';
import 'dart:typed_data';

import 'package:nearsend/core/protocol/base64url.dart';
import 'package:nearsend/core/protocol/canonical_writer.dart';
import 'package:nearsend/core/protocol/protocol_limits.dart';
import 'package:nearsend/core/protocol/protocol_validation.dart';
import 'package:nearsend/core/security/pairing_token.dart';
import 'package:nearsend/core/security/tls_identity.dart';
import 'package:nearsend/core/storage/peer_repository.dart';

const Duration knownPeerChallengeTtl = Duration(seconds: 30);
const Duration knownPeerPresenceTtl = Duration(seconds: 30);
const int knownPeerMaxPendingChallenges = 16;

enum KnownPeerAuthenticationFailure {
  unknownPeer,
  revokedPeer,
  missingPublicKey,
  identityMismatch,
  invalidMessage,
  expiredChallenge,
  replayedChallenge,
  invalidProof,
}

class KnownPeerAuthenticationException implements Exception {
  const KnownPeerAuthenticationException(this.code);

  final KnownPeerAuthenticationFailure code;

  @override
  String toString() => 'KnownPeerAuthenticationException(${code.name})';
}

class KnownPeerChallenge {
  KnownPeerChallenge({
    required this.transactionId,
    required this.verifierDeviceId,
    required this.proverDeviceId,
    required Uint8List challenge,
    this.protocolMajor = ProtocolLimits.protocolMajor,
    this.protocolMinor = ProtocolLimits.protocolMinor,
  }) : challenge = Uint8List.fromList(challenge) {
    _validateMessageField(
      () => uuidToBytes(transactionId, 'peer challenge transaction id'),
    );
    _validateMessageField(
      () => sha256HexToBytes(verifierDeviceId, 'verifier device id'),
    );
    _validateMessageField(
      () => sha256HexToBytes(proverDeviceId, 'prover device id'),
    );
    if (challenge.length != ProtocolLimits.pairTokenBytes ||
        verifierDeviceId == proverDeviceId ||
        protocolMajor < 0 ||
        protocolMajor > 0xffff ||
        protocolMinor < 0 ||
        protocolMinor > 0xffff) {
      throw const KnownPeerAuthenticationException(
        KnownPeerAuthenticationFailure.invalidMessage,
      );
    }
  }

  static const int wireVersion = 1;
  static const Set<String> _keys = <String>{
    'version',
    'transactionId',
    'verifierDeviceId',
    'proverDeviceId',
    'challenge',
    'protocolMajor',
    'protocolMinor',
  };

  final String transactionId;
  final String verifierDeviceId;
  final String proverDeviceId;
  final Uint8List challenge;
  final int protocolMajor;
  final int protocolMinor;

  Uint8List encode() => Uint8List.fromList(
    utf8.encode(
      jsonEncode(<String, Object>{
        'version': wireVersion,
        'transactionId': transactionId,
        'verifierDeviceId': verifierDeviceId,
        'proverDeviceId': proverDeviceId,
        'challenge': encodeBase64UrlNoPadding(challenge),
        'protocolMajor': protocolMajor,
        'protocolMinor': protocolMinor,
      }),
    ),
  );

  static KnownPeerChallenge decode(Uint8List bytes) {
    if (bytes.isEmpty || bytes.length > 1024) {
      throw const KnownPeerAuthenticationException(
        KnownPeerAuthenticationFailure.invalidMessage,
      );
    }
    try {
      final Object? decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is! Map<String, Object?> ||
          decoded.keys.toSet().difference(_keys).isNotEmpty ||
          _keys.difference(decoded.keys.toSet()).isNotEmpty ||
          decoded['version'] != wireVersion) {
        throw const FormatException();
      }
      return KnownPeerChallenge(
        transactionId: decoded['transactionId'] as String,
        verifierDeviceId: decoded['verifierDeviceId'] as String,
        proverDeviceId: decoded['proverDeviceId'] as String,
        challenge: decodeBase64UrlNoPaddingExact(
          decoded['challenge'],
          'peer challenge',
          expectedBytes: ProtocolLimits.pairTokenBytes,
        ),
        protocolMajor: decoded['protocolMajor'] as int,
        protocolMinor: decoded['protocolMinor'] as int,
      );
    } on KnownPeerAuthenticationException {
      rethrow;
    } on Object {
      throw const KnownPeerAuthenticationException(
        KnownPeerAuthenticationFailure.invalidMessage,
      );
    }
  }

  @override
  String toString() =>
      'KnownPeerChallenge($transactionId, $protocolMajor.$protocolMinor)';
}

class KnownPeerProof {
  KnownPeerProof({
    required this.transactionId,
    required Uint8List publicKeyDer,
    required this.tlsFingerprint,
    required this.ready,
    required Uint8List signature,
  }) : publicKeyDer = Uint8List.fromList(publicKeyDer),
       signature = Uint8List.fromList(signature) {
    _validateMessageField(
      () => uuidToBytes(transactionId, 'peer proof transaction id'),
    );
    _validateMessageField(
      () => sha256HexToBytes(tlsFingerprint, 'peer proof TLS fingerprint'),
    );
    if (signature.length != 64 || publicKeyDer.isEmpty) {
      throw const KnownPeerAuthenticationException(
        KnownPeerAuthenticationFailure.invalidMessage,
      );
    }
    _validatedDeviceId(this.publicKeyDer);
  }

  static const int wireVersion = 1;
  static const int maxPublicKeyBytes = 256;
  static const Set<String> _keys = <String>{
    'version',
    'transactionId',
    'publicKey',
    'tlsFingerprint',
    'ready',
    'signature',
  };

  final String transactionId;
  final Uint8List publicKeyDer;
  final String tlsFingerprint;
  final bool ready;
  final Uint8List signature;

  Uint8List encode() => Uint8List.fromList(
    utf8.encode(
      jsonEncode(<String, Object>{
        'version': wireVersion,
        'transactionId': transactionId,
        'publicKey': encodeBase64UrlNoPadding(publicKeyDer),
        'tlsFingerprint': tlsFingerprint,
        'ready': ready,
        'signature': encodeBase64UrlNoPadding(signature),
      }),
    ),
  );

  static KnownPeerProof decode(Uint8List bytes) {
    if (bytes.isEmpty || bytes.length > 2048) {
      throw const KnownPeerAuthenticationException(
        KnownPeerAuthenticationFailure.invalidMessage,
      );
    }
    try {
      final Object? decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is! Map<String, Object?> ||
          decoded.keys.toSet().difference(_keys).isNotEmpty ||
          _keys.difference(decoded.keys.toSet()).isNotEmpty ||
          decoded['version'] != wireVersion ||
          decoded['ready'] is! bool) {
        throw const FormatException();
      }
      final Object? publicKeyText = decoded['publicKey'];
      if (publicKeyText is! String || publicKeyText.length > 344) {
        throw const FormatException();
      }
      final Uint8List publicKey = _decodeBoundedBase64Url(
        publicKeyText,
        maxBytes: maxPublicKeyBytes,
      );
      return KnownPeerProof(
        transactionId: decoded['transactionId'] as String,
        publicKeyDer: publicKey,
        tlsFingerprint: decoded['tlsFingerprint'] as String,
        ready: decoded['ready'] as bool,
        signature: decodeBase64UrlNoPaddingExact(
          decoded['signature'],
          'peer proof signature',
          expectedBytes: 64,
        ),
      );
    } on KnownPeerAuthenticationException {
      rethrow;
    } on Object {
      throw const KnownPeerAuthenticationException(
        KnownPeerAuthenticationFailure.invalidMessage,
      );
    }
  }

  @override
  String toString() => 'KnownPeerProof($transactionId, ready=$ready)';
}

class VerifiedPeerSession {
  const VerifiedPeerSession({
    required this.peerId,
    required this.tlsFingerprint,
    required this.ready,
    required this.verifiedAtMillis,
    required this.expiresAtMillis,
  });

  final String peerId;
  final String tlsFingerprint;
  final bool ready;
  final int verifiedAtMillis;
  final int expiresAtMillis;

  bool isFreshAt(int nowMillis) => ready && nowMillis < expiresAtMillis;
}

class KnownPeerAuthenticator {
  KnownPeerAuthenticator({
    required this.localIdentity,
    required this.peers,
    int Function()? clock,
  }) : _clock = clock ?? _systemNow;

  final DeviceIdentity localIdentity;
  final PeerRepository peers;
  final int Function() _clock;
  final Map<String, _PendingChallenge> _pending = <String, _PendingChallenge>{};

  static int _systemNow() => DateTime.now().millisecondsSinceEpoch;

  int get pendingChallengeCount => _pending.length;

  KnownPeerChallenge issueChallenge(String peerId) {
    _removeExpired();
    final PeerRecord? peer = peers.find(peerId);
    if (peer == null) {
      throw const KnownPeerAuthenticationException(
        KnownPeerAuthenticationFailure.unknownPeer,
      );
    }
    if (peer.trust != PeerTrust.authorized) {
      throw const KnownPeerAuthenticationException(
        KnownPeerAuthenticationFailure.revokedPeer,
      );
    }
    final Uint8List publicKey = _storedPublicKey(peer);
    if (deviceIdForPublicKey(publicKey) != peerId) {
      throw const KnownPeerAuthenticationException(
        KnownPeerAuthenticationFailure.identityMismatch,
      );
    }
    if (_pending.length >= knownPeerMaxPendingChallenges) {
      throw const KnownPeerAuthenticationException(
        KnownPeerAuthenticationFailure.invalidMessage,
      );
    }
    final KnownPeerChallenge challenge = KnownPeerChallenge(
      transactionId: randomUuidV4(),
      verifierDeviceId: localIdentity.deviceId,
      proverDeviceId: peerId,
      challenge: Uint8List.fromList(
        generateSecureRandomBytes(ProtocolLimits.pairTokenBytes),
      ),
    );
    _pending[challenge.transactionId] = _PendingChallenge(
      challenge,
      _clock() + knownPeerChallengeTtl.inMilliseconds,
    );
    return challenge;
  }

  KnownPeerProof createProof(
    KnownPeerChallenge challenge, {
    required String tlsFingerprint,
    required bool ready,
  }) {
    if (challenge.protocolMajor != ProtocolLimits.protocolMajor ||
        challenge.proverDeviceId != localIdentity.deviceId ||
        challenge.verifierDeviceId == localIdentity.deviceId) {
      throw const KnownPeerAuthenticationException(
        KnownPeerAuthenticationFailure.identityMismatch,
      );
    }
    _validateMessageField(
      () => sha256HexToBytes(tlsFingerprint, 'peer proof TLS fingerprint'),
    );
    final Uint8List transcript = _authenticationTranscript(
      challenge,
      tlsFingerprint: tlsFingerprint,
      ready: ready,
    );
    return KnownPeerProof(
      transactionId: challenge.transactionId,
      publicKeyDer: localIdentity.publicKeyDer,
      tlsFingerprint: tlsFingerprint,
      ready: ready,
      signature: localIdentity.signAuthenticationTranscript(transcript),
    );
  }

  VerifiedPeerSession verifyProof(KnownPeerProof proof) {
    final _PendingChallenge? pending = _pending.remove(proof.transactionId);
    if (pending == null) {
      throw const KnownPeerAuthenticationException(
        KnownPeerAuthenticationFailure.replayedChallenge,
      );
    }
    final int now = _clock();
    if (now >= pending.expiresAtMillis) {
      throw const KnownPeerAuthenticationException(
        KnownPeerAuthenticationFailure.expiredChallenge,
      );
    }
    final KnownPeerChallenge challenge = pending.challenge;
    final String peerId = _validatedDeviceId(proof.publicKeyDer);
    if (peerId != challenge.proverDeviceId ||
        challenge.verifierDeviceId != localIdentity.deviceId ||
        challenge.protocolMajor != ProtocolLimits.protocolMajor) {
      throw const KnownPeerAuthenticationException(
        KnownPeerAuthenticationFailure.identityMismatch,
      );
    }
    final PeerRecord? peer = peers.find(peerId);
    if (peer == null || peer.trust != PeerTrust.authorized) {
      throw const KnownPeerAuthenticationException(
        KnownPeerAuthenticationFailure.revokedPeer,
      );
    }
    final Uint8List storedKey = _storedPublicKey(peer);
    if (!_sameBytes(storedKey, proof.publicKeyDer)) {
      throw const KnownPeerAuthenticationException(
        KnownPeerAuthenticationFailure.identityMismatch,
      );
    }
    final Uint8List transcript = _authenticationTranscript(
      challenge,
      tlsFingerprint: proof.tlsFingerprint,
      ready: proof.ready,
    );
    if (!verifyDeviceAuthenticationSignature(
      publicKeyDer: proof.publicKeyDer,
      transcript: transcript,
      signature: proof.signature,
    )) {
      throw const KnownPeerAuthenticationException(
        KnownPeerAuthenticationFailure.invalidProof,
      );
    }
    final String storedText = base64.encode(proof.publicKeyDer);
    if (!peers.recordVerifiedIdentityPresence(
      peerId: peerId,
      identityPublicKey: storedText,
      tlsFingerprint: proof.tlsFingerprint,
    )) {
      throw const KnownPeerAuthenticationException(
        KnownPeerAuthenticationFailure.revokedPeer,
      );
    }
    return VerifiedPeerSession(
      peerId: peerId,
      tlsFingerprint: proof.tlsFingerprint,
      ready: proof.ready,
      verifiedAtMillis: now,
      expiresAtMillis: now + knownPeerPresenceTtl.inMilliseconds,
    );
  }

  void _removeExpired() {
    final int now = _clock();
    _pending.removeWhere(
      (String _, _PendingChallenge value) => now >= value.expiresAtMillis,
    );
  }

  static Uint8List _storedPublicKey(PeerRecord peer) {
    final String? encoded = peer.identityPublicKey;
    if (encoded == null || encoded.isEmpty) {
      throw const KnownPeerAuthenticationException(
        KnownPeerAuthenticationFailure.missingPublicKey,
      );
    }
    try {
      final Uint8List decoded = base64.decode(encoded);
      if (base64.encode(decoded) != encoded) throw const FormatException();
      deviceIdForPublicKey(decoded);
      return decoded;
    } on Object {
      throw const KnownPeerAuthenticationException(
        KnownPeerAuthenticationFailure.missingPublicKey,
      );
    }
  }
}

class _PendingChallenge {
  const _PendingChallenge(this.challenge, this.expiresAtMillis);

  final KnownPeerChallenge challenge;
  final int expiresAtMillis;
}

Uint8List _authenticationTranscript(
  KnownPeerChallenge challenge, {
  required String tlsFingerprint,
  required bool ready,
}) {
  final CanonicalWriter writer = CanonicalWriter()
    ..ascii('NSPEER1')
    ..u8(0)
    ..u16(challenge.protocolMajor)
    ..u16(challenge.protocolMinor)
    ..raw(uuidToBytes(challenge.transactionId, 'peer transaction id'))
    ..raw(sha256HexToBytes(challenge.verifierDeviceId, 'verifier device id'))
    ..raw(sha256HexToBytes(challenge.proverDeviceId, 'prover device id'))
    ..raw(challenge.challenge)
    ..u8(ready ? 1 : 0)
    ..raw(sha256HexToBytes(tlsFingerprint, 'TLS fingerprint'));
  return writer.toBytes();
}

Uint8List _decodeBoundedBase64Url(String value, {required int maxBytes}) {
  if (value.isEmpty || value.contains('=')) {
    throw const FormatException();
  }
  final Uint8List decoded = base64Url.decode(base64Url.normalize(value));
  if (decoded.isEmpty ||
      decoded.length > maxBytes ||
      encodeBase64UrlNoPadding(decoded) != value) {
    throw const FormatException();
  }
  return decoded;
}

bool _sameBytes(List<int> first, List<int> second) {
  if (first.length != second.length) return false;
  int difference = 0;
  for (int index = 0; index < first.length; index++) {
    difference |= first[index] ^ second[index];
  }
  return difference == 0;
}

void _validateMessageField(void Function() validation) {
  try {
    validation();
  } on KnownPeerAuthenticationException {
    rethrow;
  } on Object {
    throw const KnownPeerAuthenticationException(
      KnownPeerAuthenticationFailure.invalidMessage,
    );
  }
}

String _validatedDeviceId(Uint8List publicKeyDer) {
  try {
    return deviceIdForPublicKey(publicKeyDer);
  } on Object {
    throw const KnownPeerAuthenticationException(
      KnownPeerAuthenticationFailure.invalidMessage,
    );
  }
}
