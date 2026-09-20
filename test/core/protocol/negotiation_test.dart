import 'package:flutter_test/flutter_test.dart';

import 'package:nearsend/core/protocol/protocol_exception.dart';
import 'package:nearsend/core/protocol/protocol_version.dart';

/// Version and capability negotiation, §3 and V2.1 §17.1.
///
/// The draft never enumerates a capability vocabulary, so these tests use synthetic
/// identifiers. That is the point: the algorithm is fully exercised while the vocabulary
/// stays a maintainer decision, and the gap is asserted separately.
void main() {
  CapabilitySet setOf(List<String> ids) =>
      CapabilitySet(ids.map(Capability.parse));

  group('ProtocolVersion', () {
    test('parses a well-formed body and rejects malformed ones', () {
      expect(
        ProtocolVersion.fromJson(<String, Object?>{
          'protocolMajor': 1,
          'protocolMinor': 0,
        }, 'body'),
        const ProtocolVersion(1, 0),
      );

      for (final Map<String, Object?> bad in <Map<String, Object?>>[
        <String, Object?>{'protocolMinor': 0},
        <String, Object?>{'protocolMajor': 1},
        <String, Object?>{'protocolMajor': '1', 'protocolMinor': 0},
        <String, Object?>{'protocolMajor': 1, 'protocolMinor': true},
        <String, Object?>{'protocolMajor': -1, 'protocolMinor': 0},
      ]) {
        expect(
          () => ProtocolVersion.fromJson(bad, 'body'),
          throwsA(
            isA<ProtocolViolation>().having(
              (ProtocolViolation e) => e.code,
              'code',
              ProtocolErrorCode.invalidField,
            ),
          ),
        );
      }
    });

    test('compares major first, then minor', () {
      expect(const ProtocolVersion(1, 2) > const ProtocolVersion(1, 1), isTrue);
      expect(const ProtocolVersion(2, 0) > const ProtocolVersion(1, 9), isTrue);
      expect(
        const ProtocolVersion(1, 0) == const ProtocolVersion(1, 0),
        isTrue,
      );
    });

    test('current matches the limits the encoders use', () {
      expect(ProtocolVersion.current, const ProtocolVersion(1, 0));
    });
  });

  group('Capability and CapabilitySet', () {
    test('accepts bounded printable identifiers', () {
      expect(Capability.parse('resume.v2').id, 'resume.v2');
      expect(Capability.parse('a').id, 'a');
      expect(Capability.parse('x' * Capability.maxIdBytes).id.length, 64);
    });

    test(
      'rejects non-strings, empty, over-long, spaced and control values',
      () {
        for (final Object? bad in <Object?>[
          1,
          null,
          '',
          'x' * (Capability.maxIdBytes + 1),
          'has space',
          'tab\there',
          'newline\nhere',
          'unicode-能力',
        ]) {
          expect(
            () => Capability.parse(bad),
            throwsA(
              isA<ProtocolViolation>().having(
                (ProtocolViolation e) => e.code,
                'code',
                ProtocolErrorCode.invalidField,
              ),
            ),
            reason: '$bad must be rejected',
          );
        }
      },
    );

    test('parsing an array rejects duplicates and non-arrays', () {
      expect(CapabilitySet.fromJson(<Object?>['a', 'b'], 'body').ids, <String>{
        'a',
        'b',
      });
      expect(
        () => CapabilitySet.fromJson(<Object?>['a', 'a'], 'body'),
        throwsA(isA<ProtocolViolation>()),
        reason: 'a repeated entry is a peer inconsistency, not something to fold away',
      );
      expect(
        () => CapabilitySet.fromJson('a', 'body'),
        throwsA(isA<ProtocolViolation>()),
      );
    });

    test(
      'intersection keeps only shared identifiers and serialises sorted',
      () {
        final CapabilitySet shared = setOf(<String>['b', 'a', 'c'])
            .intersection(setOf(<String>['c', 'a']));
        expect(shared.ids, <String>{'a', 'c'});
        expect(shared.toJson(), <String>['a', 'c']);
        expect(shared.length, 2);
      },
    );
  });

  group('negotiation', () {
    test('a major difference is refused outright', () {
      final NegotiationOutcome outcome = ProtocolNegotiation.negotiate(
        local: const ProtocolVersion(1, 0),
        localCapabilities: setOf(<String>['a']),
        remote: const ProtocolVersion(2, 0),
        remoteCapabilities: setOf(<String>['a']),
      );
      expect(outcome.accepted, isFalse);
      expect(outcome.failure, NegotiationFailure.majorVersionMismatch);
      expect(outcome.errorCode, ProtocolErrorCode.invalidField);
    });

    test('a minor difference proceeds, resolving to the lower minor', () {
      final NegotiationOutcome outcome = ProtocolNegotiation.negotiate(
        local: const ProtocolVersion(1, 0),
        localCapabilities: setOf(<String>['a']),
        remote: const ProtocolVersion(1, 5),
        remoteCapabilities: setOf(<String>['a']),
      );
      expect(outcome.accepted, isTrue);
      expect(
        outcome.agreedVersion,
        const ProtocolVersion(1, 0),
        reason:
            'the peer may not implement whatever a higher minor introduced, so the '
            'conservative resolution is the lower minor',
      );
    });

    test('a task requirement absent from the intersection is refused', () {
      final NegotiationOutcome outcome = ProtocolNegotiation.negotiate(
        local: const ProtocolVersion(1, 0),
        localCapabilities: setOf(<String>['a', 'b']),
        remote: const ProtocolVersion(1, 0),
        remoteCapabilities: setOf(<String>['a']),
        requiredCapabilities: <String>{'b', 'c'},
      );
      expect(outcome.accepted, isFalse);
      expect(outcome.failure, NegotiationFailure.missingCapabilities);
      expect(
        outcome.missing,
        <String>['b', 'c'],
        reason: 'the missing set must be sorted and must name every unmet requirement',
      );
    });

    test('a task requirement satisfied by the intersection is accepted', () {
      final NegotiationOutcome outcome = ProtocolNegotiation.negotiate(
        local: const ProtocolVersion(1, 0),
        localCapabilities: setOf(<String>['a', 'b']),
        remote: const ProtocolVersion(1, 0),
        remoteCapabilities: setOf(<String>['b', 'c']),
        requiredCapabilities: <String>{'b'},
      );
      expect(outcome.accepted, isTrue);
      expect(outcome.shared.ids, <String>{'b'});
      expect(outcome.missing, isEmpty);
    });

    test('one-sided capabilities are never treated as shared', () {
      final NegotiationOutcome outcome = ProtocolNegotiation.negotiate(
        local: const ProtocolVersion(1, 0),
        localCapabilities: setOf(<String>['onlyLocal']),
        remote: const ProtocolVersion(1, 0),
        remoteCapabilities: setOf(<String>['onlyRemote']),
      );
      expect(outcome.accepted, isTrue, reason: 'no requirements were stated');
      expect(outcome.shared.isEmpty, isTrue);
    });

    test('the vector-free requirement set is the plain-transfer case', () {
      final NegotiationOutcome outcome = ProtocolNegotiation.negotiate(
        local: ProtocolVersion.current,
        localCapabilities: CapabilitySet(const <Capability>[]),
        remote: ProtocolVersion.current,
        remoteCapabilities: CapabilitySet(const <Capability>[]),
      );
      expect(outcome.accepted, isTrue);
    });
  });

  group('frozen tasks are not modified by an update (§17.1)', () {
    test('same version and chunk size may touch the task', () {
      expect(
        ProtocolNegotiation.mayModifyFrozenTask(
          frozenWith: const ProtocolVersion(1, 0),
          frozenChunkSizeBytes: 4194304,
          now: const ProtocolVersion(1, 0),
          currentChunkSizeBytes: 4194304,
        ),
        isTrue,
      );
    });

    test('a different minor version or chunk size may not', () {
      expect(
        ProtocolNegotiation.mayModifyFrozenTask(
          frozenWith: const ProtocolVersion(1, 0),
          frozenChunkSizeBytes: 4194304,
          now: const ProtocolVersion(1, 1),
          currentChunkSizeBytes: 4194304,
        ),
        isFalse,
      );
      expect(
        ProtocolNegotiation.mayModifyFrozenTask(
          frozenWith: const ProtocolVersion(1, 0),
          frozenChunkSizeBytes: 4194304,
          now: const ProtocolVersion(1, 0),
          currentChunkSizeBytes: 8388608,
        ),
        isFalse,
        reason: 'changing the chunk size would invalidate every frozen digest',
      );
    });
  });
}
