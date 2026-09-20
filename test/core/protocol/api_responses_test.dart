import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:nearsend/core/protocol/api_responses.dart';
import 'package:nearsend/core/protocol/base64url.dart';
import 'package:nearsend/core/protocol/manifest.dart';
import 'package:nearsend/core/protocol/manifest_page.dart';
import 'package:nearsend/core/protocol/protocol_exception.dart';
import 'package:nearsend/core/protocol/protocol_limits.dart';
import 'package:nearsend/core/protocol/transfer_state.dart';

/// The `/v1` success bodies (§4, §7).
void main() {
  const String transferId = '3f2504e0-4f89-41d3-9a0c-0305e82c3301';
  final String token = encodeBase64UrlNoPadding(
    Uint8List.fromList(List<int>.generate(32, (int i) => i)),
  );

  Matcher refuses = throwsA(isA<ProtocolViolation>());

  Map<String, Object?> offerJson({
    Object? transferIdValue = transferId,
    Object? digest,
    Object? fileCount = 3,
    Object? totalBytes = '100',
  }) => <String, Object?>{
    'transferId': transferIdValue,
    'manifestDigest': digest ?? 'a' * 64,
    'fileCount': fileCount,
    'totalBytes': totalBytes,
  };

  group('§10 state names on the wire', () {
    // The names as §10 writes them. A rename in either place fails here.
    const Map<TransferState, String> documented = <TransferState, String>{
      TransferState.preparing: 'PREPARING',
      TransferState.staging: 'STAGING',
      TransferState.waitingAccept: 'WAITING_ACCEPT',
      TransferState.ready: 'READY',
      TransferState.transferring: 'TRANSFERRING',
      TransferState.pausing: 'PAUSING',
      TransferState.paused: 'PAUSED',
      TransferState.interrupted: 'INTERRUPTED',
      TransferState.checkingResume: 'CHECKING_RESUME',
      TransferState.verifying: 'VERIFYING',
      TransferState.exporting: 'EXPORTING',
      TransferState.completed: 'COMPLETED',
      TransferState.partiallyCompleted: 'PARTIALLY_COMPLETED',
      TransferState.blocked: 'BLOCKED',
      TransferState.failed: 'FAILED',
      TransferState.cancelled: 'CANCELLED',
    };

    test('every state has the name §10 gives it', () {
      expect(documented, hasLength(TransferState.values.length));
      for (final MapEntry<TransferState, String> entry in documented.entries) {
        expect(entry.key.wireName, entry.value);
      }
    });

    test('a wire name parses back to its state', () {
      for (final MapEntry<TransferState, String> entry in documented.entries) {
        expect(TransferState.fromWireName(entry.value), entry.key);
      }
    });

    test('an undefined name parses to null rather than to a default', () {
      expect(TransferState.fromWireName('UNKNOWN'), isNull);
      expect(TransferState.fromWireName('waitingAccept'), isNull);
      expect(TransferState.fromWireName(''), isNull);
    });
  });

  group('acknowledgements', () {
    test('stored round trips', () {
      expect(const StoredAck().toJson(), <String, Object?>{'stored': true});
      expect(
        StoredAck.parse(<String, Object?>{'stored': true}).toJson(),
        <String, Object?>{'stored': true},
      );
    });

    test('stored must be true', () {
      expect(
        () => StoredAck.parse(<String, Object?>{'stored': false}),
        refuses,
      );
      expect(
        () => StoredAck.parse(<String, Object?>{'stored': 'true'}),
        refuses,
      );
      expect(() => StoredAck.parse(<String, Object?>{}), refuses);
    });

    test('stored carries nothing else', () {
      expect(
        () => StoredAck.parse(<String, Object?>{'stored': true, 'extra': 1}),
        refuses,
      );
    });

    test('mirrored round trips and is a separate type', () {
      expect(const MirroredAck().toJson(), <String, Object?>{'mirrored': true});
      expect(
        () => MirroredAck.parse(<String, Object?>{'stored': true}),
        refuses,
        reason:
            '§9 says the server "只更新显示镜像"; answering with stored would claim more '
            'than the server did',
      );
    });
  });

  group('state responses', () {
    test('round trip through the wire name', () {
      expect(
        const StateResponse(TransferState.paused).toJson(),
        <String, Object?>{'state': 'PAUSED'},
      );
      expect(
        StateResponse.parse(<String, Object?>{'state': 'WAITING_ACCEPT'}).state,
        TransferState.waitingAccept,
      );
    });

    test('an undefined state is refused', () {
      expect(
        () => StateResponse.parse(<String, Object?>{'state': 'DONE'}),
        refuses,
      );
      expect(() => StateResponse.parse(<String, Object?>{'state': 3}), refuses);
    });
  });

  group('a created transfer', () {
    test('round trips', () {
      final TransferCreated created = TransferCreated(
        transferId: transferId,
        state: TransferState.staging,
      );
      expect(created.toJson()['state'], 'STAGING');
      expect(TransferCreated.parse(created.toJson()).transferId, transferId);
    });

    test('a transfer id that is not a UUID is refused', () {
      expect(
        () => TransferCreated.parse(<String, Object?>{
          'transferId': 't1',
          'state': 'STAGING',
        }),
        refuses,
      );
    });
  });

  group('an offer (§4 decides which numbers are strings)', () {
    test('fileCount is a JSON number and totalBytes is a decimal string', () {
      final OfferSummary offer = OfferSummary(
        transferId: transferId,
        manifestDigest: 'a' * 64,
        fileCount: 3,
        totalBytes: 100,
      );

      final Map<String, Object?> json = offer.toJson();
      expect(
        json['fileCount'],
        isA<int>(),
        reason: '§4 lists fileCount among the fields that use JSON integers',
      );
      expect(
        json['totalBytes'],
        isA<String>(),
        reason: '§4 lists 字节数 among the fields that use decimal strings',
      );
      expect(json['totalBytes'], '100');
    });

    test('a totalBytes sent as a number is refused', () {
      expect(
        () => OfferSummary.parse(offerJson(totalBytes: 100)),
        refuses,
        reason: 'a peer that wrote a JSON number here is one this build cannot read',
      );
    });

    test('a fileCount sent as a string is refused', () {
      expect(() => OfferSummary.parse(offerJson(fileCount: '3')), refuses);
    });

    test('totalBytes with a leading zero is refused', () {
      expect(() => OfferSummary.parse(offerJson(totalBytes: '0100')), refuses);
    });

    test('a negative totalBytes is refused', () {
      expect(() => OfferSummary.parse(offerJson(totalBytes: '-1')), refuses);
    });

    test('round trips', () {
      final OfferSummary offer = OfferSummary.parse(offerJson());
      expect(offer.fileCount, 3);
      expect(offer.totalBytes, 100);
      expect(OfferSummary.parse(offer.toJson()).transferId, transferId);
    });

    test('the digest and identifier are validated', () {
      expect(() => OfferSummary.parse(offerJson(digest: 'abc')), refuses);
      expect(
        () => OfferSummary.parse(offerJson(transferIdValue: 'nope')),
        refuses,
      );
    });
  });

  group('an offers page', () {
    test('round trips with a cursor and without one', () {
      final OffersPage page = OffersPage(
        offers: <OfferSummary>[OfferSummary.parse(offerJson())],
        nextCursor: 'opaque-1',
      );
      expect(OffersPage.parse(page.toJson()).nextCursor, 'opaque-1');

      final OffersPage end = OffersPage(
        offers: <OfferSummary>[OfferSummary.parse(offerJson())],
      );
      expect(end.toJson()['nextCursor'], isNull);
      expect(OffersPage.parse(end.toJson()).nextCursor, isNull);
    });

    test('an empty page is legitimate', () {
      expect(
        OffersPage.parse(<String, Object?>{
          'offers': <Object?>[],
          'nextCursor': null,
        }).offers,
        isEmpty,
        reason:
            '§6 says an unknown session cannot enumerate offers, so no offers is an '
            'answer rather than an error',
      );
    });

    test('an empty cursor string is refused', () {
      expect(
        () => OffersPage.parse(<String, Object?>{
          'offers': <Object?>[],
          'nextCursor': '',
        }),
        refuses,
        reason: 'null means the end; an empty string would be a second way to say it',
      );
    });

    test('the page cap is 128', () {
      expect(
        OffersPage.parse(<String, Object?>{
          'offers': <Object?>[for (int i = 0; i < 128; i++) offerJson()],
          'nextCursor': null,
        }).offers,
        hasLength(128),
      );
      expect(
        () => OffersPage.parse(<String, Object?>{
          'offers': <Object?>[for (int i = 0; i < 129; i++) offerJson()],
          'nextCursor': null,
        }),
        refuses,
      );
    });

    test('a non-array offers field is refused', () {
      expect(
        () => OffersPage.parse(<String, Object?>{
          'offers': 'x',
          'nextCursor': null,
        }),
        refuses,
      );
    });
  });

  group('a chunk write result (§8)', () {
    test('the counters are decimal strings and the state is a wire value', () {
      final ChunkWriteResult result = ChunkWriteResult(
        index: 7,
        state: ChunkWriteState.verifiedPending,
        leaseEpoch: 3,
        checkpointSeq: 12,
      );

      expect(result.toJson(), <String, Object?>{
        'index': '7',
        'state': 'verified_pending',
        'leaseEpoch': '3',
        'checkpointSeq': '12',
      });
    });

    test('round trips', () {
      final ChunkWriteResult parsed = ChunkWriteResult.parse(<String, Object?>{
        'index': '7',
        'state': 'committed',
        'leaseEpoch': '3',
        'checkpointSeq': '12',
      });
      expect(parsed.index, 7);
      expect(parsed.state, ChunkWriteState.committed);
      expect(parsed.leaseEpoch, 3);
      expect(parsed.checkpointSeq, 12);
    });

    test('only the two §8 states are accepted', () {
      expect(
        ChunkWriteState.parse('verified_pending'),
        ChunkWriteState.verifiedPending,
      );
      expect(ChunkWriteState.parse('committed'), ChunkWriteState.committed);
      for (final Object? bad in <Object?>[
        'pending',
        'verified',
        'COMMITTED',
        1,
        null,
      ]) {
        expect(() => ChunkWriteState.parse(bad), refuses, reason: 'state $bad');
      }
    });

    test('a counter sent as a JSON number is refused', () {
      expect(
        () => ChunkWriteResult.parse(<String, Object?>{
          'index': 7,
          'state': 'committed',
          'leaseEpoch': '3',
          'checkpointSeq': '12',
        }),
        refuses,
      );
    });
  });

  group('a control poll (§7)', () {
    test('round trips', () {
      final ControlPoll poll = ControlPoll(
        commands: <ControlCommand>[
          const ControlCommand(seq: 1, type: ControlCommandType.pause),
          const ControlCommand(seq: 2, type: ControlCommandType.cancel),
        ],
        lastSeq: 2,
      );

      expect(poll.toJson()['lastSeq'], '2');
      final ControlPoll parsed = ControlPoll.parse(poll.toJson());
      expect(
        parsed.commands.map((ControlCommand c) => c.type).toList(),
        <ControlCommandType>[
          ControlCommandType.pause,
          ControlCommandType.cancel,
        ],
      );
    });

    test('no commands is legitimate', () {
      expect(
        ControlPoll.parse(<String, Object?>{
          'commands': <Object?>[],
          'lastSeq': '5',
        }).commands,
        isEmpty,
      );
    });

    test('commands must ascend by seq', () {
      expect(
        () => ControlPoll.parse(<String, Object?>{
          'commands': <Object?>[
            <String, Object?>{'seq': '2', 'type': 'pause'},
            <String, Object?>{'seq': '1', 'type': 'cancel'},
          ],
          'lastSeq': '2',
        }),
        refuses,
        reason: '§7 says命令重复按 seq 幂等, which needs the sequence to be ordered',
      );
      expect(
        () => ControlPoll.parse(<String, Object?>{
          'commands': <Object?>[
            <String, Object?>{'seq': '1', 'type': 'pause'},
            <String, Object?>{'seq': '1', 'type': 'cancel'},
          ],
          'lastSeq': '1',
        }),
        refuses,
      );
    });

    test('an unknown command type is refused', () {
      expect(
        () => ControlPoll.parse(<String, Object?>{
          'commands': <Object?>[
            <String, Object?>{'seq': '1', 'type': 'resume'},
          ],
          'lastSeq': '1',
        }),
        refuses,
      );
    });

    test('lastSeq must cover the commands it describes', () {
      expect(
        () => ControlPoll.parse(<String, Object?>{
          'commands': <Object?>[
            <String, Object?>{'seq': '3', 'type': 'pause'},
          ],
          'lastSeq': '1',
        }),
        refuses,
      );
    });
  });

  group('credentials appear in exactly two responses', () {
    test('the authorisation grant carries two secrets', () {
      final AuthorizationGrant grant = AuthorizationGrant(
        taskResumeSecret: token,
        completionQuerySecret: token,
      );
      expect(grant, isA<TokenBearingResponse>());
      expect(grant.credentialFields, <String>{
        'taskResumeSecret',
        'completionQuerySecret',
      });
      expect(grant.toString(), isNot(contains(token)));
      expect(AuthorizationGrant.parse(grant.toJson()).taskResumeSecret, token);
    });

    test('a secret of the wrong shape is refused', () {
      expect(
        () => AuthorizationGrant.parse(<String, Object?>{
          'taskResumeSecret': 'short',
          'completionQuerySecret': token,
        }),
        refuses,
      );
      expect(
        () => AuthorizationGrant.parse(<String, Object?>{
          'taskResumeSecret': '$token=',
          'completionQuerySecret': token,
        }),
        refuses,
      );
    });

    test('the resume grant carries the task access token', () {
      final ResumeGranted granted = ResumeGranted(
        taskAccessToken: token,
        leaseEpoch: 4,
        checkpointSeq: 9,
        state: TransferState.ready,
      );
      expect(granted, isA<TokenBearingResponse>());
      expect(granted.credentialFields, <String>{'taskAccessToken'});
      expect(granted.toString(), isNot(contains(token)));
      expect(granted.toJson()['leaseEpoch'], '4');
      expect(granted.toJson()['checkpointSeq'], '9');
      expect(granted.toJson()['state'], 'READY');
    });

    test('no other body is marked as carrying one', () {
      // §7: "成功体中的 token 字段只出现在专门授权/恢复响应". This is the check that keeps
      // that true as bodies are added: a token reaching any of these fails here.
      expect(const StoredAck(), isNot(isA<TokenBearingResponse>()));
      expect(const MirroredAck(), isNot(isA<TokenBearingResponse>()));
      expect(
        const StateResponse(TransferState.paused),
        isNot(isA<TokenBearingResponse>()),
      );
      expect(
        const ResumeChecking(),
        isNot(isA<TokenBearingResponse>()),
        reason: 'the 202 form is a state, not a grant',
      );
      expect(
        OffersPage(offers: <OfferSummary>[OfferSummary.parse(offerJson())]),
        isNot(isA<TokenBearingResponse>()),
      );
      expect(
        const ChunkWriteResult(
          index: 0,
          state: ChunkWriteState.committed,
          leaseEpoch: 1,
          checkpointSeq: 1,
        ),
        isNot(isA<TokenBearingResponse>()),
      );
      expect(
        const ControlPoll(commands: <ControlCommand>[], lastSeq: 0),
        isNot(isA<TokenBearingResponse>()),
      );
    });
  });

  group('the two resume forms (§7)', () {
    test('the 202 form is a state and nothing else', () {
      expect(const ResumeChecking().toJson(), <String, Object?>{
        'state': 'CHECKING_RESUME',
      });
      expect(
        ResumeResponse.parse(<String, Object?>{
          'state': 'CHECKING_RESUME',
        }, accepted: false),
        isA<ResumeChecking>(),
      );
    });

    test('the 202 form refuses any other state', () {
      expect(
        () => ResumeChecking.parse(<String, Object?>{'state': 'READY'}),
        refuses,
      );
    });

    test('the 202 form refuses a token', () {
      expect(
        () => ResumeChecking.parse(<String, Object?>{
          'state': 'CHECKING_RESUME',
          'taskAccessToken': token,
        }),
        refuses,
        reason:
            '§11 says a user confirmation must not occupy a long request; a token here '
            'would be a credential handed out before the work finished',
      );
    });

    test('the 200 form round trips', () {
      final ResumeGranted granted = ResumeGranted(
        taskAccessToken: token,
        leaseEpoch: 1,
        checkpointSeq: 2,
        state: TransferState.transferring,
      );
      final ResumeResponse parsed = ResumeResponse.parse(
        granted.toJson(),
        accepted: true,
      );
      expect(parsed, isA<ResumeGranted>());
      expect((parsed as ResumeGranted).leaseEpoch, 1);
    });

    test('the 200 form refuses a token of the wrong shape', () {
      expect(
        () => ResumeGranted.parse(<String, Object?>{
          'taskAccessToken': 'nope',
          'expiresInSeconds': 1800,
          'leaseEpoch': '1',
          'checkpointSeq': '1',
          'state': 'READY',
        }),
        refuses,
      );
    });

    test('the 200 form refuses an undefined state', () {
      expect(
        () => ResumeGranted.parse(<String, Object?>{
          'taskAccessToken': token,
          'expiresInSeconds': 1800,
          'leaseEpoch': '1',
          'checkpointSeq': '1',
          'state': 'RESUMED',
        }),
        refuses,
      );
    });

    test('the 200 form refuses a non-positive expiry', () {
      for (final Object? expires in <Object?>[0, -1]) {
        expect(
          () => ResumeGranted.parse(<String, Object?>{
            'taskAccessToken': token,
            'expiresInSeconds': expires,
            'leaseEpoch': '1',
            'checkpointSeq': '1',
            'state': 'READY',
          }),
          refuses,
          reason: 'expiresInSeconds $expires',
        );
      }
    });

    test('the default expiry is the value §7 fixes', () {
      expect(
        ResumeGranted(
          taskAccessToken: token,
          leaseEpoch: 1,
          checkpointSeq: 1,
          state: TransferState.ready,
        ).expiresInSeconds,
        ProtocolLimits.sessionAccessTokenTtlSeconds,
      );
    });
  });

  group('nextIndex (§7 adds it to §6\'s page)', () {
    ManifestFile entry(int n) => ManifestFile(
      fileId: '00000000-0000-4000-8000-${n.toString().padLeft(12, '0')}',
      relativePath: 'file-$n.bin',
      sizeBytes: 4,
      chunkSizeBytes: ProtocolLimits.chunkSizeBytes,
      chunkCount: 1,
      fileSha256: 'b' * 64,
      chunkManifestDigest: 'c' * 64,
    );

    /// Two entries starting at 128, so the index after the page is 130.
    ManifestFilePage page() => ManifestFilePage(
      manifestDigest: 'a' * 64,
      startIndex: 128,
      items: <ManifestFile>[entry(0), entry(1)],
    );

    test('null means the end of the manifest', () {
      expect(
        ApiResponses.nextIndex(<String, Object?>{'nextIndex': null}, page()),
        isNull,
      );
    });

    test('a nextIndex that does not continue this page is refused', () {
      expect(
        () => ApiResponses.nextIndex(<String, Object?>{
          'nextIndex': '999',
        }, page()),
        refuses,
        reason:
            'a nextIndex that does not continue this page would leave a gap no later page '
            'could fill',
      );
    });

    test('a nextIndex with a leading zero is refused', () {
      expect(
        () => ApiResponses.nextIndex(<String, Object?>{
          'nextIndex': '0130',
        }, page()),
        refuses,
      );
    });

    test('a nextIndex sent as a JSON number is refused', () {
      expect(
        () =>
            ApiResponses.nextIndex(<String, Object?>{'nextIndex': 130}, page()),
        refuses,
        reason: '§7 writes it as "null 或十进制字符串"',
      );
    });

    test('the index after the page is returned', () {
      expect(
        ApiResponses.nextIndex(<String, Object?>{'nextIndex': '130'}, page()),
        130,
      );
    });
  });
}
