import 'package:flutter_test/flutter_test.dart';

import 'package:nearsend/core/protocol/protocol_exception.dart';
import 'package:nearsend/core/protocol/transfer_state.dart';

/// The task and file state machines, §10 plus `SYSTEM_ARCHITECTURE.md` §7.
///
/// Two of these tests exist to make **gaps in the draft executable**: the states whose
/// exit §10 never defines, and the file retry that the product requires but the draft
/// omits. They fail the moment someone changes the table, which is the point - closing a
/// gap should be a deliberate, reviewed act rather than a quiet addition.
void main() {
  group('task machine: the stated happy path', () {
    test('staging through completion is reachable in order', () {
      const List<TransferState> chain = <TransferState>[
        TransferState.staging,
        TransferState.waitingAccept,
        TransferState.ready,
        TransferState.transferring,
        TransferState.verifying,
        TransferState.exporting,
        TransferState.completed,
      ];
      for (int i = 1; i < chain.length; i++) {
        expect(
          TransferStateMachine.canTransition(chain[i - 1], chain[i]),
          isTrue,
          reason: '${chain[i - 1].name} -> ${chain[i].name} must be allowed',
        );
      }
    });

    test('pausing and resuming are reachable', () {
      expect(
        TransferStateMachine.canTransition(
          TransferState.transferring,
          TransferState.pausing,
        ),
        isTrue,
      );
      expect(
        TransferStateMachine.canTransition(
          TransferState.pausing,
          TransferState.paused,
        ),
        isTrue,
      );
      expect(
        TransferStateMachine.canTransition(
          TransferState.paused,
          TransferState.checkingResume,
        ),
        isTrue,
      );
      expect(
        TransferStateMachine.canTransition(
          TransferState.checkingResume,
          TransferState.transferring,
        ),
        isTrue,
      );
    });

    test('recovery goes through the local-check state, never straight to transferring', () {
      // §10 puts CHECKING_RESUME between a resume request and data movement, and the UI
      // spec requires the user to be told that local content is being checked. Skipping
      // it would both violate the protocol and hide the check from the user.
      expect(
        TransferStateMachine.canTransition(
          TransferState.paused,
          TransferState.transferring,
        ),
        isFalse,
      );
      expect(
        TransferStateMachine.canTransition(
          TransferState.interrupted,
          TransferState.transferring,
        ),
        isFalse,
      );
    });
  });

  group('task machine: illegal transitions are refused', () {
    test('the chain cannot be skipped', () {
      const List<List<TransferState>> illegal = <List<TransferState>>[
        <TransferState>[TransferState.staging, TransferState.ready],
        <TransferState>[TransferState.staging, TransferState.transferring],
        <TransferState>[
          TransferState.waitingAccept,
          TransferState.transferring,
        ],
        <TransferState>[TransferState.ready, TransferState.completed],
        <TransferState>[TransferState.transferring, TransferState.completed],
        <TransferState>[TransferState.verifying, TransferState.completed],
        <TransferState>[TransferState.exporting, TransferState.transferring],
        <TransferState>[TransferState.completed, TransferState.transferring],
      ];
      for (final List<TransferState> pair in illegal) {
        expect(
          TransferStateMachine.canTransition(pair[0], pair[1]),
          isFalse,
          reason: '${pair[0].name} -> ${pair[1].name} must not be allowed',
        );
      }
    });

    test('assertTransition throws INVALID_STATE with both state names', () {
      expect(
        () => TransferStateMachine.assertTransition(
          TransferState.staging,
          TransferState.transferring,
        ),
        throwsA(
          isA<ProtocolViolation>()
              .having(
                (ProtocolViolation e) => e.code,
                'code',
                ProtocolErrorCode.invalidState,
              )
              .having(
                (ProtocolViolation e) => e.detail,
                'detail',
                allOf(contains('staging'), contains('transferring')),
              ),
        ),
      );
    });

    test('every non-terminal state can be cancelled', () {
      for (final TransferState state in TransferState.values) {
        if (state == TransferState.cancelled ||
            state == TransferState.completed ||
            state == TransferState.failed ||
            state == TransferState.partiallyCompleted) {
          continue;
        }
        expect(
          TransferStateMachine.canTransition(state, TransferState.cancelled),
          isTrue,
          reason: '§10: 所有状态可本地取消→CANCELLED (${state.name})',
        );
      }
    });

    test('an already finished task cannot be cancelled again', () {
      for (final TransferState state in <TransferState>[
        TransferState.completed,
        TransferState.cancelled,
        TransferState.failed,
        TransferState.partiallyCompleted,
      ]) {
        expect(
          TransferStateMachine.canTransition(state, TransferState.cancelled),
          isFalse,
          reason: '${state.name} is already finished',
        );
      }
    });
  });

  group('task machine: the table is well-formed and sourced', () {
    test('no transition is listed twice', () {
      final Set<String> seen = <String>{};
      for (final TransferTransition transition
          in TransferStateMachine.transitions) {
        expect(
          seen.add('${transition.from.name}->${transition.to.name}'),
          isTrue,
          reason: 'duplicate edge $transition',
        );
      }
    });

    test('every transition explains itself against §10', () {
      for (final TransferTransition transition
          in TransferStateMachine.transitions) {
        expect(
          transition.rationale.trim(),
          isNotEmpty,
          reason: '$transition has no rationale',
        );
        if (transition.source == TransitionSource.stated) {
          expect(
            transition.rationale,
            contains('§10'),
            reason: 'a stated edge must quote §10: $transition',
          );
        }
      }
    });

    test('the table contains both stated and derived edges', () {
      final Set<TransitionSource> sources = TransferStateMachine.transitions
          .map((TransferTransition t) => t.source)
          .toSet();
      expect(sources, contains(TransitionSource.stated));
      expect(
        sources,
        contains(TransitionSource.derived),
        reason:
            'the draft describes several states without naming their sources, so a '
            'purely stated table would be incomplete',
      );
    });

    test('nextStates agrees with canTransition', () {
      for (final TransferState from in TransferState.values) {
        for (final TransferState to in TransferState.values) {
          expect(
            TransferStateMachine.canTransition(from, to),
            TransferStateMachine.nextStates(from).contains(to),
          );
        }
      }
    });
  });

  group('task machine: gaps in the draft are executable', () {
    test('failed and partiallyCompleted have no defined exit at all', () {
      expect(
        TransferStateMachine.statesWithoutDefinedExit,
        <TransferState>{
          TransferState.completed,
          TransferState.cancelled,
          TransferState.failed,
          TransferState.partiallyCompleted,
        },
        reason:
            'completed and cancelled are terminal by design; failed and '
            'partiallyCompleted are terminal only because §10 never says how to leave '
            'them, which blocks V2.1 §16.1 ("retry only the failed items")',
      );
    });

    test(
      'blocked can only be cancelled, which contradicts the documented retry',
      () {
        expect(
          TransferStateMachine.statesThatCanOnlyBeCancelled,
          <TransferState>{TransferState.blocked},
          reason:
              '§11 answers SPACE_INSUFFICIENT with "free space or change location, then '
              'retry"; cancelling is the only escape today, and it discards the recovery '
              'data the user was promised would be kept',
        );
      },
    );

    test('terminality is reported consistently', () {
      for (final TransferState state in TransferState.values) {
        if (TransferStateMachine.deliberatelyTerminal.contains(state)) {
          expect(state.isTerminal, isTrue);
        }
      }
      // failed and partiallyCompleted are reported terminal because nothing leaves them,
      // even though that is a gap rather than an intent.
      expect(TransferState.failed.isTerminal, isTrue);
      expect(TransferState.partiallyCompleted.isTerminal, isTrue);
      expect(TransferState.blocked.isTerminal, isFalse);
      expect(TransferState.transferring.isTerminal, isFalse);
    });

    test('only completed counts as success', () {
      // §10: a queue that finished with unfinished items is not a success, and the UI
      // spec forbids showing completion before verification and export are committed.
      expect(TransferState.completed.isSuccess, isTrue);
      for (final TransferState state in TransferState.values) {
        if (state != TransferState.completed) {
          expect(state.isSuccess, isFalse);
        }
      }
    });
  });

  group('file machine', () {
    test('the forward chain is allowed', () {
      const List<FileState> chain = <FileState>[
        FileState.pending,
        FileState.preparing,
        FileState.transferring,
        FileState.verifying,
        FileState.exporting,
        FileState.completed,
      ];
      for (int i = 1; i < chain.length; i++) {
        expect(
          FileStateMachine.canTransition(chain[i - 1], chain[i]),
          isTrue,
          reason: '${chain[i - 1].name} -> ${chain[i].name}',
        );
      }
    });

    test('a pending file may be skipped', () {
      expect(
        FileStateMachine.canTransition(FileState.pending, FileState.skipped),
        isTrue,
      );
    });

    test('a file in flight cannot jump to completed', () {
      expect(
        FileStateMachine.canTransition(
          FileState.transferring,
          FileState.completed,
        ),
        isFalse,
      );
      expect(
        FileStateMachine.canTransition(
          FileState.verifying,
          FileState.completed,
        ),
        isFalse,
      );
      expect(
        FileStateMachine.canTransition(FileState.pending, FileState.completed),
        isFalse,
      );
    });

    test(
      'every non-terminal file state can fail without touching the others',
      () {
        for (final FileState from in <FileState>[
          FileState.preparing,
          FileState.transferring,
          FileState.verifying,
          FileState.exporting,
        ]) {
          expect(
            FileStateMachine.canTransition(from, FileState.failed),
            isTrue,
            reason: '§10 requires one blocked file not to erase finished ones',
          );
        }
      },
    );

    test('a file state machine violation is INVALID_STATE', () {
      expect(
        () => FileStateMachine.assertTransition(
          FileState.pending,
          FileState.completed,
        ),
        throwsA(
          isA<ProtocolViolation>().having(
            (ProtocolViolation e) => e.code,
            'code',
            ProtocolErrorCode.invalidState,
          ),
        ),
      );
    });

    test('retrying a failed file is not defined by the draft', () {
      expect(
        FileStateMachine.retryOfFailedFilesIsDefined,
        isFalse,
        reason:
            'failed has no outgoing edge, yet V2.1 §16.1 requires retrying only the '
            'failed items of a partly completed queue. Closing this requires a protocol '
            'change, not a code change alone',
      );
      expect(FileStateMachine.nextStates(FileState.failed), isEmpty);
      expect(FileStateMachine.nextStates(FileState.skipped), isEmpty);
      expect(FileStateMachine.nextStates(FileState.completed), isEmpty);
    });

    test('terminal file states report themselves as terminal', () {
      expect(FileState.completed.isTerminal, isTrue);
      expect(FileState.failed.isTerminal, isTrue);
      expect(FileState.skipped.isTerminal, isTrue);
      expect(FileState.transferring.isTerminal, isFalse);
      expect(FileState.pending.isTerminal, isFalse);
    });
  });
}
