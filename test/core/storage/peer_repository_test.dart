import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

import 'package:nearsend/core/storage/near_send_database.dart';
import 'package:nearsend/core/storage/peer_repository.dart';
import 'package:nearsend/core/storage/storage_failure.dart';

/// Peer trust and user authorisation.
///
/// The behaviour worth protecting is the fingerprint change: it must be *reported*, never
/// silently absorbed. A repository that updated the stored fingerprint on first contact
/// would let anyone who can take over a peer's address inherit that peer's authorisation,
/// which is precisely what `AGENTS.md` §5 forbids.
void main() {
  late Directory dir;
  late NearSendDatabase database;
  late PeerRepository peers;

  const String peerId = '00000000-0000-4000-8000-0000000000a1';
  const String fingerprintA =
      'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
  const String fingerprintB =
      'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

  setUp(() {
    dir = Directory.systemTemp.createTempSync('nearsend-peers-');
    database = NearSendDatabase.open(
      path: '${dir.path}${Platform.pathSeparator}peers.db',
    );
    peers = PeerRepository(database);
  });

  tearDown(() {
    database.close();
    if (dir.existsSync()) {
      dir.deleteSync(recursive: true);
    }
  });

  group('trust evaluation', () {
    test('a peer that was never paired is unknown', () {
      expect(
        peers.trustFor(peerId: peerId, identityFingerprint: fingerprintA),
        PeerTrust.unknown,
      );
      expect(peers.storedFingerprint(peerId), isNull);
    });

    test('an authorised peer is authorised', () {
      peers.recordUserAuthorization(
        peerId: peerId,
        identityFingerprint: fingerprintA,
        displayName: 'Pixel',
      );
      expect(
        peers.trustFor(peerId: peerId, identityFingerprint: fingerprintA),
        PeerTrust.authorized,
      );
      expect(peers.storedFingerprint(peerId), fingerprintA);
    });

    test('a revoked peer is reported as revoked, not unknown', () {
      peers.recordUserAuthorization(
        peerId: peerId,
        identityFingerprint: fingerprintA,
      );
      peers.revoke(peerId);

      expect(
        peers.trustFor(peerId: peerId, identityFingerprint: fingerprintA),
        PeerTrust.revoked,
        reason:
            '"we revoked this device" and "we have never seen it" need different UI, '
            'so the identity is kept',
      );
      expect(peers.storedFingerprint(peerId), fingerprintA);
    });

    test('revoking an unknown peer is refused', () {
      expect(
        () => peers.revoke(peerId),
        throwsA(isA<StorageException>()),
        reason: 'revoking nothing would silently report success',
      );
    });
  });

  group('fingerprint change', () {
    test('a changed fingerprint is reported and not stored', () {
      peers.recordUserAuthorization(
        peerId: peerId,
        identityFingerprint: fingerprintA,
      );

      expect(
        peers.trustFor(peerId: peerId, identityFingerprint: fingerprintB),
        PeerTrust.fingerprintChanged,
      );
      expect(
        peers.storedFingerprint(peerId),
        fingerprintA,
        reason:
            'evaluating trust must not silently adopt the presented fingerprint; only '
            'an explicit user authorisation may change it',
      );
      expect(
        peers.trustFor(peerId: peerId, identityFingerprint: fingerprintA),
        PeerTrust.authorized,
        reason: 'evaluating a mismatch left the peer exactly as it was',
      );
    });

    test('a fingerprint change needs a fresh user authorisation', () {
      peers.recordUserAuthorization(
        peerId: peerId,
        identityFingerprint: fingerprintA,
      );
      expect(
        peers.trustFor(peerId: peerId, identityFingerprint: fingerprintB),
        PeerTrust.fingerprintChanged,
      );

      peers.recordUserAuthorization(
        peerId: peerId,
        identityFingerprint: fingerprintB,
      );
      expect(
        peers.trustFor(peerId: peerId, identityFingerprint: fingerprintB),
        PeerTrust.authorized,
      );
      expect(peers.storedFingerprint(peerId), fingerprintB);
    });

    test('a revoked peer presenting a new fingerprint needs re-pairing', () {
      peers.recordUserAuthorization(
        peerId: peerId,
        identityFingerprint: fingerprintA,
      );
      peers.revoke(peerId);

      expect(
        peers.trustFor(peerId: peerId, identityFingerprint: fingerprintB),
        PeerTrust.fingerprintChanged,
        reason:
            'the reinstall path: the same address with a new identity must re-pair, even '
            'though the peer was previously authorised',
      );
    });

    test('authorisation keeps a display name when a later call omits it', () {
      peers.recordUserAuthorization(
        peerId: peerId,
        identityFingerprint: fingerprintA,
        displayName: 'Pixel',
      );
      peers.recordUserAuthorization(
        peerId: peerId,
        identityFingerprint: fingerprintA,
      );

      final Row row = database.db.select(
        'SELECT display_name FROM peers WHERE peer_id = ?;',
        <Object?>[peerId],
      ).first;
      expect(row['display_name'], 'Pixel');
    });
  });

  group('seen tracking', () {
    test('touch does not change authorisation', () {
      peers.recordUserAuthorization(
        peerId: peerId,
        identityFingerprint: fingerprintA,
      );
      peers.revoke(peerId);
      peers.touch(peerId);

      expect(
        peers.trustFor(peerId: peerId, identityFingerprint: fingerprintA),
        PeerTrust.revoked,
        reason: 'merely seeing a device again must not re-authorise it',
      );
    });
  });

  group('storage shape', () {
    test('the peers table holds no token, key or secret column', () {
      final List<String> columns = <String>[
        for (final Row row in database.db.select('PRAGMA table_info(peers);'))
          row['name'] as String,
      ];

      expect(columns, <String>[
        'peer_id',
        'display_name',
        'identity_fingerprint',
        'authorized',
        'last_seen_at',
      ]);
      for (final String column in columns) {
        expect(
          column.contains('token') ||
              column.contains('secret') ||
              column.contains('key') ||
              column.contains('password'),
          isFalse,
          reason:
              'AGENTS.md §5 keeps credentials in platform secure storage; a column here '
              'would put one in a plain SQLite table',
        );
      }
    });
  });
}
