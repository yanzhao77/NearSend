import 'package:flutter_test/flutter_test.dart';

import 'package:nearsend/core/protocol/protocol_exception.dart';

/// Verifies the error model against `docs/protocol/v1.0-draft1.md` §11.
///
/// §7 fixes the wire error body as `{code, message, retryable, requestId?}`, so the
/// `retryable` flag is a contract rather than an implementation detail. The tables here
/// are transcribed from §11 so that a code added, removed or re-classified without a
/// spec change fails the build.
void main() {
  group('§11 code table', () {
    // Status -> the codes §11 lists under it, verbatim.
    const Map<int, List<ProtocolErrorCode>> specByStatus =
        <int, List<ProtocolErrorCode>>{
          400: <ProtocolErrorCode>[
            ProtocolErrorCode.invalidField,
            ProtocolErrorCode.invalidDecimal,
            ProtocolErrorCode.invalidPath,
          ],
          401: <ProtocolErrorCode>[
            ProtocolErrorCode.pairRejected,
            ProtocolErrorCode.authExpired,
            ProtocolErrorCode.resumeRejected,
          ],
          403: <ProtocolErrorCode>[ProtocolErrorCode.directionForbidden],
          404: <ProtocolErrorCode>[ProtocolErrorCode.notFound],
          409: <ProtocolErrorCode>[
            ProtocolErrorCode.staleLease,
            ProtocolErrorCode.requestIdConflict,
            ProtocolErrorCode.snapshotExpired,
            ProtocolErrorCode.invalidState,
            // §9 introduces this one for the resume path; §11's 409 group is where it
            // belongs, since it is a "query state and stop" condition.
            ProtocolErrorCode.staleResumeRequest,
          ],
          410: <ProtocolErrorCode>[
            ProtocolErrorCode.taskExpired,
            ProtocolErrorCode.taskCancelled,
          ],
          413: <ProtocolErrorCode>[
            ProtocolErrorCode.resourceLimit,
            ProtocolErrorCode.bodyTooLarge,
          ],
          422: <ProtocolErrorCode>[
            ProtocolErrorCode.manifestMismatch,
            ProtocolErrorCode.chunkHashMismatch,
            ProtocolErrorCode.sourceChanged,
          ],
          429: <ProtocolErrorCode>[ProtocolErrorCode.rateLimited],
          500: <ProtocolErrorCode>[
            ProtocolErrorCode.storageSyncFailed,
            ProtocolErrorCode.dbCommitFailed,
          ],
          507: <ProtocolErrorCode>[ProtocolErrorCode.spaceInsufficient],
        };

    test('the enum contains exactly the codes the draft defines', () {
      final Set<ProtocolErrorCode> expected = specByStatus.values
          .expand((List<ProtocolErrorCode> codes) => codes)
          .toSet();
      expect(
        ProtocolErrorCode.values.toSet(),
        expected,
        reason:
            'adding or removing a code must be a deliberate change to both this '
            'table and §11',
      );
    });

    test('each code carries the HTTP status §11 pairs it with', () {
      specByStatus.forEach((int status, List<ProtocolErrorCode> codes) {
        for (final ProtocolErrorCode code in codes) {
          expect(
            code.httpStatus,
            status,
            reason: '${code.wireCode} must map to $status',
          );
        }
      });
    });

    test('only the codes §11 says to back off are retryable', () {
      // §11's behaviour column: codes whose response is "retry after a delay" are
      // retryable unchanged. Everything else either needs a corrected request, a new
      // identity, or a human decision - resending it cannot succeed.
      const Set<ProtocolErrorCode> retryable = <ProtocolErrorCode>{
        ProtocolErrorCode.rateLimited, // "按 Retry-After（秒）退避"
        ProtocolErrorCode.storageSyncFailed, // "不确认提交，保留可恢复状态"
        ProtocolErrorCode.dbCommitFailed, // same
      };
      for (final ProtocolErrorCode code in ProtocolErrorCode.values) {
        expect(
          code.retryable,
          retryable.contains(code),
          reason: '${code.wireCode} retryability must match §11',
        );
      }
    });

    test('SPACE_INSUFFICIENT is not auto-retryable even though it is recoverable', () {
      // §11: "用户清理/换位置后重试". Retrying the same request unchanged cannot
      // succeed, so `retryable` is false; the UI must offer the user an action.
      expect(ProtocolErrorCode.spaceInsufficient.retryable, isFalse);
      expect(ProtocolErrorCode.spaceInsufficient.httpStatus, 507);
    });

    test('wire codes are unique and round-trip', () {
      final Set<String> seen = <String>{};
      for (final ProtocolErrorCode code in ProtocolErrorCode.values) {
        expect(
          seen.add(code.wireCode),
          isTrue,
          reason: '${code.wireCode} repeats',
        );
        expect(ProtocolErrorCode.fromWireCode(code.wireCode), code);
      }
      expect(ProtocolErrorCode.fromWireCode('NOT_A_CODE'), isNull);
    });

    test('every code has a stable, non-empty user message key', () {
      final Set<String> keys = <String>{};
      for (final ProtocolErrorCode code in ProtocolErrorCode.values) {
        expect(code.messageKey, startsWith('protocol.'));
        expect(
          keys.add(code.messageKey),
          isTrue,
          reason: 'duplicate message key',
        );
      }
    });
  });

  group('ProtocolError', () {
    test('takes status and retryability from the code', () {
      final ProtocolError error = ProtocolError(
        code: ProtocolErrorCode.staleLease,
        scope: ErrorScope.chunk,
        diagnosticContext: const <String, String>{'chunkIndex': '7'},
      );
      expect(error.httpStatus, 409);
      expect(error.retryable, isFalse);
      expect(error.toString(), contains('STALE_LEASE'));
      expect(error.toString(), contains('chunkIndex=7'));
    });

    test('converts a validation failure without inventing a new code', () {
      const ProtocolViolation violation = ProtocolViolation(
        ProtocolErrorCode.invalidPath,
        'bad path',
      );
      final ProtocolError error = ProtocolError.fromViolation(
        violation,
        scope: ErrorScope.file,
      );
      expect(error.code, ProtocolErrorCode.invalidPath);
      expect(error.scope, ErrorScope.file);
      expect(error.cause, same(violation));
      expect(error.httpStatus, 400);
    });

    test('task-wide failures pause the whole task, file failures do not', () {
      expect(
        ProtocolError(
          code: ProtocolErrorCode.invalidField,
          scope: ErrorScope.task,
        ).pausesWholeTask,
        isTrue,
      );
      expect(
        ProtocolError(
          code: ProtocolErrorCode.notFound,
          scope: ErrorScope.protocol,
        ).pausesWholeTask,
        isTrue,
      );
      // A manifest-level or source-level problem invalidates the whole task even when
      // reported against one file.
      expect(
        ProtocolError(
          code: ProtocolErrorCode.manifestMismatch,
          scope: ErrorScope.file,
        ).pausesWholeTask,
        isTrue,
      );
      expect(
        ProtocolError(
          code: ProtocolErrorCode.sourceChanged,
          scope: ErrorScope.file,
        ).pausesWholeTask,
        isTrue,
      );
      // A single file's read or export failure must let the others continue.
      expect(
        ProtocolError(
          code: ProtocolErrorCode.storageSyncFailed,
          scope: ErrorScope.file,
        ).pausesWholeTask,
        isFalse,
      );
      expect(
        ProtocolError(
          code: ProtocolErrorCode.chunkHashMismatch,
          scope: ErrorScope.chunk,
        ).pausesWholeTask,
        isFalse,
      );
      expect(
        ProtocolError(
          code: ProtocolErrorCode.spaceInsufficient,
          scope: ErrorScope.platform,
        ).pausesWholeTask,
        isFalse,
      );
    });

    test(
      'the rendered form carries no message text, only codes and context',
      () {
        final ProtocolError error = ProtocolError(
          code: ProtocolErrorCode.rateLimited,
          scope: ErrorScope.task,
        );
        final String rendered = error.toString();
        expect(rendered, contains('RATE_LIMITED'));
        expect(rendered, contains('retryable=true'));
        // Nothing resembling a credential or a path may appear. There is no field that
        // could carry one, and this asserts the shape stays that way.
        expect(rendered, isNot(contains('/')));
        expect(rendered, isNot(contains('token')));
      },
    );
  });
}
