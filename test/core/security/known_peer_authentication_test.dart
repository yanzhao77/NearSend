import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:nearsend/core/security/known_peer_authentication.dart';
import 'package:nearsend/core/security/tls_identity.dart';
import 'package:nearsend/core/storage/near_send_database.dart';
import 'package:nearsend/core/storage/peer_repository.dart';

void main() {
  late Directory directory;
  late NearSendDatabase database;
  late PeerRepository peers;
  late DeviceIdentity verifierIdentity;
  late DeviceIdentity proverIdentity;
  late int now;

  const String oldTlsPin =
      'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
  const String currentTlsPin =
      'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

  setUp(() {
    directory = Directory.systemTemp.createTempSync('nearsend-peer-auth-');
    database = NearSendDatabase.open(
      path: '${directory.path}${Platform.pathSeparator}peer-auth.db',
    );
    now = 1000;
    peers = PeerRepository(database, now: () => now);
    verifierIdentity = generateDeviceIdentity();
    proverIdentity = generateDeviceIdentity();
    peers.recordUserAuthorization(
      peerId: proverIdentity.deviceId,
      identityFingerprint: oldTlsPin,
      identityPublicKey: base64.encode(proverIdentity.publicKeyDer),
      displayName: 'Peer',
      platform: 'android',
    );
  });

  tearDown(() {
    database.close();
    directory.deleteSync(recursive: true);
  });

  KnownPeerAuthenticator auth(DeviceIdentity identity) =>
      KnownPeerAuthenticator(
        localIdentity: identity,
        peers: peers,
        clock: () => now,
      );

  test(
    'fresh challenge and proof bind identity, readiness and current TLS pin',
    () {
      final KnownPeerAuthenticator verifier = KnownPeerAuthenticator(
        localIdentity: verifierIdentity,
        peers: peers,
        clock: () => now,
      );
      final KnownPeerAuthenticator prover = KnownPeerAuthenticator(
        localIdentity: proverIdentity,
        peers: peers,
        clock: () => now,
      );

      final KnownPeerChallenge challenge = KnownPeerChallenge.decode(
        verifier.issueChallenge(proverIdentity.deviceId).encode(),
      );
      final KnownPeerProof proof = KnownPeerProof.decode(
        prover
            .createProof(challenge, tlsFingerprint: currentTlsPin, ready: true)
            .encode(),
      );
      final VerifiedPeerSession session = verifier.verifyProof(proof);

      expect(session.peerId, proverIdentity.deviceId);
      expect(session.tlsFingerprint, currentTlsPin);
      expect(session.isFreshAt(now), isTrue);
      expect(session.isFreshAt(session.expiresAtMillis), isFalse);
      expect(peers.storedFingerprint(proverIdentity.deviceId), currentTlsPin);
      expect(peers.find(proverIdentity.deviceId)!.lastVerifiedAt, now);
      expect(challenge.toString(), isNot(contains('challenge')));
      expect(proof.toString(), isNot(contains('signature')));
      expect(proof.toString(), isNot(contains('publicKey')));
    },
  );

  test('a proof can authenticate presence without claiming ready', () {
    final KnownPeerAuthenticator verifier = auth(verifierIdentity);
    final KnownPeerAuthenticator prover = auth(proverIdentity);
    final KnownPeerChallenge challenge = verifier.issueChallenge(
      proverIdentity.deviceId,
    );
    final VerifiedPeerSession session = verifier.verifyProof(
      prover.createProof(
        challenge,
        tlsFingerprint: currentTlsPin,
        ready: false,
      ),
    );

    expect(session.ready, isFalse);
    expect(session.isFreshAt(now), isFalse);
  });

  test('a tampered proof fails and consumes its one-time challenge', () {
    final KnownPeerAuthenticator verifier = auth(verifierIdentity);
    final KnownPeerAuthenticator prover = auth(proverIdentity);
    final KnownPeerChallenge challenge = verifier.issueChallenge(
      proverIdentity.deviceId,
    );
    final KnownPeerProof valid = prover.createProof(
      challenge,
      tlsFingerprint: currentTlsPin,
      ready: true,
    );
    final Uint8List changedSignature = Uint8List.fromList(valid.signature)
      ..[0] ^= 1;
    final KnownPeerProof tampered = KnownPeerProof(
      transactionId: valid.transactionId,
      publicKeyDer: valid.publicKeyDer,
      tlsFingerprint: valid.tlsFingerprint,
      ready: valid.ready,
      signature: changedSignature,
    );

    expect(
      () => verifier.verifyProof(tampered),
      throwsA(_failure(KnownPeerAuthenticationFailure.invalidProof)),
    );
    expect(
      () => verifier.verifyProof(valid),
      throwsA(_failure(KnownPeerAuthenticationFailure.replayedChallenge)),
    );
    expect(peers.storedFingerprint(proverIdentity.deviceId), oldTlsPin);
  });

  test('a valid proof cannot be replayed', () {
    final KnownPeerAuthenticator verifier = auth(verifierIdentity);
    final KnownPeerAuthenticator prover = auth(proverIdentity);
    final KnownPeerProof proof = prover.createProof(
      verifier.issueChallenge(proverIdentity.deviceId),
      tlsFingerprint: currentTlsPin,
      ready: true,
    );

    expect(verifier.verifyProof(proof).peerId, proverIdentity.deviceId);
    expect(
      () => verifier.verifyProof(proof),
      throwsA(_failure(KnownPeerAuthenticationFailure.replayedChallenge)),
    );
  });

  test('readiness and TLS pin are covered by the signature', () {
    final KnownPeerAuthenticator verifier = auth(verifierIdentity);
    final KnownPeerAuthenticator prover = auth(proverIdentity);
    final KnownPeerChallenge readyChallenge = verifier.issueChallenge(
      proverIdentity.deviceId,
    );
    final KnownPeerProof readyProof = prover.createProof(
      readyChallenge,
      tlsFingerprint: currentTlsPin,
      ready: true,
    );
    expect(
      () => verifier.verifyProof(
        KnownPeerProof(
          transactionId: readyProof.transactionId,
          publicKeyDer: readyProof.publicKeyDer,
          tlsFingerprint: readyProof.tlsFingerprint,
          ready: false,
          signature: readyProof.signature,
        ),
      ),
      throwsA(_failure(KnownPeerAuthenticationFailure.invalidProof)),
    );

    final KnownPeerChallenge pinChallenge = verifier.issueChallenge(
      proverIdentity.deviceId,
    );
    final KnownPeerProof pinProof = prover.createProof(
      pinChallenge,
      tlsFingerprint: currentTlsPin,
      ready: true,
    );
    expect(
      () => verifier.verifyProof(
        KnownPeerProof(
          transactionId: pinProof.transactionId,
          publicKeyDer: pinProof.publicKeyDer,
          tlsFingerprint: oldTlsPin,
          ready: pinProof.ready,
          signature: pinProof.signature,
        ),
      ),
      throwsA(_failure(KnownPeerAuthenticationFailure.invalidProof)),
    );
  });

  test('proof cannot substitute another long-term identity', () {
    final KnownPeerAuthenticator verifier = auth(verifierIdentity);
    final DeviceIdentity impostorIdentity = generateDeviceIdentity();
    final KnownPeerAuthenticator impostor = auth(impostorIdentity);
    final KnownPeerChallenge challenge = verifier.issueChallenge(
      proverIdentity.deviceId,
    );

    expect(
      () => impostor.createProof(
        challenge,
        tlsFingerprint: currentTlsPin,
        ready: true,
      ),
      throwsA(_failure(KnownPeerAuthenticationFailure.identityMismatch)),
    );
  });

  test('a reflected challenge cannot be proved by its verifier', () {
    final KnownPeerAuthenticator verifier = auth(verifierIdentity);
    final KnownPeerChallenge challenge = verifier.issueChallenge(
      proverIdentity.deviceId,
    );

    expect(
      () => verifier.createProof(
        challenge,
        tlsFingerprint: currentTlsPin,
        ready: true,
      ),
      throwsA(_failure(KnownPeerAuthenticationFailure.identityMismatch)),
    );
  });

  test('expiry and revocation both fail closed', () {
    final KnownPeerAuthenticator verifier = auth(verifierIdentity);
    final KnownPeerAuthenticator prover = auth(proverIdentity);
    final KnownPeerChallenge expiredChallenge = verifier.issueChallenge(
      proverIdentity.deviceId,
    );
    final KnownPeerProof expiredProof = prover.createProof(
      expiredChallenge,
      tlsFingerprint: currentTlsPin,
      ready: true,
    );
    now += knownPeerChallengeTtl.inMilliseconds;
    expect(
      () => verifier.verifyProof(expiredProof),
      throwsA(_failure(KnownPeerAuthenticationFailure.expiredChallenge)),
    );

    now += 1;
    final KnownPeerChallenge revokedChallenge = verifier.issueChallenge(
      proverIdentity.deviceId,
    );
    final KnownPeerProof revokedProof = prover.createProof(
      revokedChallenge,
      tlsFingerprint: currentTlsPin,
      ready: true,
    );
    peers.revoke(proverIdentity.deviceId);
    expect(
      () => verifier.verifyProof(revokedProof),
      throwsA(_failure(KnownPeerAuthenticationFailure.revokedPeer)),
    );
  });

  test('unknown, revoked and keyless peers cannot receive a challenge', () {
    final KnownPeerAuthenticator verifier = auth(verifierIdentity);
    expect(
      () => verifier.issueChallenge(generateDeviceIdentity().deviceId),
      throwsA(_failure(KnownPeerAuthenticationFailure.unknownPeer)),
    );

    peers.revoke(proverIdentity.deviceId);
    expect(
      () => verifier.issueChallenge(proverIdentity.deviceId),
      throwsA(_failure(KnownPeerAuthenticationFailure.revokedPeer)),
    );
  });

  test('pending challenges are bounded and expired entries are reclaimed', () {
    final KnownPeerAuthenticator verifier = auth(verifierIdentity);
    for (int index = 0; index < knownPeerMaxPendingChallenges; index++) {
      verifier.issueChallenge(proverIdentity.deviceId);
    }
    expect(verifier.pendingChallengeCount, knownPeerMaxPendingChallenges);
    expect(
      () => verifier.issueChallenge(proverIdentity.deviceId),
      throwsA(_failure(KnownPeerAuthenticationFailure.invalidMessage)),
    );

    now += knownPeerChallengeTtl.inMilliseconds;
    verifier.issueChallenge(proverIdentity.deviceId);
    expect(verifier.pendingChallengeCount, 1);
  });

  test(
    'wire decoders reject extra fields, truncation and oversized values',
    () {
      final KnownPeerAuthenticator verifier = auth(verifierIdentity);
      final KnownPeerChallenge challenge = verifier.issueChallenge(
        proverIdentity.deviceId,
      );
      final Map<String, Object?> json = jsonDecode(
        utf8.decode(challenge.encode()),
      );
      json['extra'] = true;

      expect(
        () => KnownPeerChallenge.decode(
          Uint8List.fromList(utf8.encode(jsonEncode(json))),
        ),
        throwsA(_failure(KnownPeerAuthenticationFailure.invalidMessage)),
      );
      expect(
        () => KnownPeerChallenge.decode(Uint8List.fromList(<int>[0x7b])),
        throwsA(_failure(KnownPeerAuthenticationFailure.invalidMessage)),
      );
      expect(
        () => KnownPeerProof.decode(Uint8List(2049)),
        throwsA(_failure(KnownPeerAuthenticationFailure.invalidMessage)),
      );
      expect(
        () => KnownPeerProof(
          transactionId: challenge.transactionId,
          publicKeyDer: Uint8List.fromList(<int>[1, 2, 3]),
          tlsFingerprint: currentTlsPin,
          ready: true,
          signature: Uint8List(64),
        ),
        throwsA(_failure(KnownPeerAuthenticationFailure.invalidMessage)),
      );
      expect(
        () => auth(proverIdentity)
            .createProof(challenge, tlsFingerprint: 'not-a-pin', ready: true),
        throwsA(_failure(KnownPeerAuthenticationFailure.invalidMessage)),
      );
    },
  );
}

Matcher _failure(KnownPeerAuthenticationFailure code) =>
    isA<KnownPeerAuthenticationException>().having(
      (KnownPeerAuthenticationException error) => error.code,
      'code',
      code,
    );
