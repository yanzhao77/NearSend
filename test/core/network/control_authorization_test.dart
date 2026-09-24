import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:nearsend/core/network/control_authorization.dart';
import 'package:nearsend/core/network/control_message.dart';
import 'package:nearsend/core/network/task_ownership.dart';
import 'package:nearsend/core/protocol/api_routes.dart';
import 'package:nearsend/core/protocol/base64url.dart';
import 'package:nearsend/core/protocol/protocol_exception.dart';
import 'package:nearsend/core/protocol/transfer_direction.dart';

/// §7's authorisation decisions.
///
/// Two of these carry more weight than the rest, because they are the ones a plausible
/// implementation gets wrong:
///
/// * **A valid token for the wrong transfer answers `404`, not `403`.** §7 says "任务查询对
///   无权限资源统一 404", and a `403` would confirm the transfer exists. This is asserted for
///   every credential kind that is transfer-scoped.
/// * **A direction violation answers `403`.** `AGENTS.md` §5 requires the operation direction
///   to be verified on every file request, so this is mandatory rather than optional, and it
///   must not be confused with the resource rule above.
void main() {
  const String taskId = '11111111-2222-4333-8444-555555555555';
  const String otherTaskId = '99999999-8888-4777-8666-555555555555';

  /// A canonical 43-character token, built rather than hand-written so it cannot be a
  /// near-miss that `BearerHeader` would refuse for the wrong reason.
  String tokenFor(int seed) =>
      encodeBase64UrlNoPadding(Uint8List.fromList(List<int>.filled(32, seed)));

  final String sessionToken = tokenFor(0x11);
  final String taskToken = tokenFor(0x22);
  final String otherTaskToken = tokenFor(0x33);
  final String unknownToken = tokenFor(0x99);

  final Map<String, ControlGrant> grants = <String, ControlGrant>{
    sessionToken: const SessionGrant(peerId: 'peer-a'),
    taskToken: TaskGrant(
      transferId: taskId,
      direction: TransferDirection.clientToServer,
    ),
    otherTaskToken: TaskGrant(
      transferId: taskId,
      direction: TransferDirection.serverToClient,
    ),
  };

  ControlRequest requestWith(String? authorization) => ControlRequest(
    method: HttpMethod.post,
    target: '/v1/transfers/$taskId/pause',
    headers: authorization == null
        ? const <String, String>{}
        : <String, String>{'authorization': authorization},
  );

  ControlAuthorization decide({
    required ApiRoute route,
    String? authorization,
    String? transferId = taskId,
    Map<String, ControlGrant>? overrides,
    TaskOwnership ownership = const NoTaskOwnership(),
  }) {
    final Map<String, ControlGrant> table = overrides ?? grants;
    return ControlAuthorizer(
      _MapAuthenticator(table),
      ownership: ownership,
    ).authorize(
      request: requestWith(authorization),
      route: route,
      transferId: transferId,
      nowMillis: 0,
    );
  }

  /// An ownership table, so a session can be scoped to the tasks it is bound to.
  TaskOwnership owns(Map<String, TaskOwner> table) => _MapOwnership(table);

  final TaskOwner sessionOwnsTask = TaskOwner(
    peerId: 'peer-a',
    direction: TransferDirection.serverToClient,
  );

  Matcher deniedWith(ProtocolErrorCode code) =>
      isA<ControlDenied>().having((ControlDenied d) => d.code, 'code', code);

  group('the §7 table', () {
    test('covers every route and nothing else', () {
      expect(ControlAuthTable.assertCoversEveryRoute, returnsNormally);
      expect(
        ControlAuthTable.byRouteName.length,
        ApiRoutes.all.length,
        reason: '§7 lists nineteen rows and each needs a requirement',
      );
    });

    test('a route without a requirement fails loudly, it does not become anonymous', () {
      // The failure direction matters: a default of "no credential needed" would turn a new
      // endpoint into an open one.
      const ApiRoute unlisted = ApiRoute(
        name: 'notInTheTable',
        method: HttpMethod.get,
        template: '/v1/not-in-the-table',
      );
      expect(
        () => ControlAuthTable.forRoute(unlisted),
        throwsA(isA<ProtocolViolation>()),
      );
    });

    test('pair is the stated exception to the bearer rule', () {
      expect(
        ControlAuthTable.forRoute(ApiRoutes.pair).credential,
        ControlCredential.none,
      );
      expect(decide(route: ApiRoutes.pair), isA<ControlAuthorized>());
    });

    test(
      'resume does not demand a bearer, or a first resume could never happen',
      () {
        expect(
          ControlAuthTable.forRoute(ApiRoutes.resume).credential,
          ControlCredential.resumeBodySecret,
        );
        final ControlAuthorization decision = decide(route: ApiRoutes.resume);
        expect(
          decision,
          isA<ControlAuthorized>(),
          reason: '§7: resume 使用 taskResumeSecret 专用请求体；初次 resume 无须旧会话令牌',
        );
      },
    );

    test(
      'every other route refuses a request with no Authorization header',
      () {
        for (final ApiRoute route in ApiRoutes.all) {
          if (route.name == 'pair' || route.name == 'resume') {
            continue;
          }
          expect(
            decide(route: route),
            deniedWith(ProtocolErrorCode.authExpired),
            reason: '§7: 除 pair 外均需要有效 Bearer (${route.name})',
          );
        }
      },
    );
  });

  group('rejecting a bad credential', () {
    test('a malformed Authorization header is a 401', () {
      expect(
        decide(route: ApiRoutes.pause, authorization: 'Basic abc'),
        deniedWith(ProtocolErrorCode.authExpired),
      );
    });

    test(
      'an unknown or expired token is a 401, and the reason is not finer',
      () {
        // Unknown, expired, revoked and re-paired all answer the same way; a finer answer
        // would tell the caller which of them it was.
        expect(
          decide(route: ApiRoutes.pause, authorization: 'Bearer $unknownToken'),
          deniedWith(ProtocolErrorCode.authExpired),
        );
      },
    );

    test('a token the authority rejects for any reason is one answer', () {
      final ControlAuthorizer authorizer = ControlAuthorizer(
        const RejectingAuthenticator(),
      );
      final ControlAuthorization decision = authorizer.authorize(
        request: requestWith('Bearer $taskToken'),
        route: ApiRoutes.pause,
        transferId: taskId,
        nowMillis: 0,
      );
      expect(decision, deniedWith(ProtocolErrorCode.authExpired));
    });
  });

  group('transfer scoping uses 404, not 403', () {
    test('a task token for another transfer answers NOT_FOUND', () {
      final ControlAuthorization decision = decide(
        route: ApiRoutes.pause,
        authorization: 'Bearer $taskToken',
        transferId: otherTaskId,
      );

      expect(decision, deniedWith(ProtocolErrorCode.notFound));
      expect(
        (decision as ControlDenied).code.httpStatus,
        404,
        reason:
            '§7: 任务查询对无权限资源统一 404 - a 403 would confirm the transfer exists '
            'and let a caller enumerate ids',
      );
    });

    test(
      'a completion-query credential for another transfer answers NOT_FOUND',
      () {
        final Map<String, ControlGrant> table = <String, ControlGrant>{
          taskToken: const CompletionQueryGrant(transferId: taskId),
        };
        expect(
          decide(
            route: ApiRoutes.status,
            authorization: 'Bearer $taskToken',
            transferId: otherTaskId,
            overrides: table,
          ),
          deniedWith(ProtocolErrorCode.notFound),
        );
      },
    );

    test('a completion-query credential reaches only the status route', () {
      final Map<String, ControlGrant> table = <String, ControlGrant>{
        taskToken: const CompletionQueryGrant(transferId: taskId),
      };
      expect(
        decide(
          route: ApiRoutes.status,
          authorization: 'Bearer $taskToken',
          overrides: table,
        ),
        isA<ControlAuthorized>(),
      );
      expect(
        decide(
          route: ApiRoutes.getManifest,
          authorization: 'Bearer $taskToken',
          overrides: table,
        ),
        deniedWith(ProtocolErrorCode.notFound),
      );
    });

    test('a task token is too narrow for a route that asks for a session', () {
      // §7 asks for 会话身份 on offers. A task token is a different, narrower thing, so it
      // is refused rather than promoted.
      expect(
        decide(route: ApiRoutes.offers, authorization: 'Bearer $taskToken'),
        deniedWith(ProtocolErrorCode.notFound),
      );
    });

    test('a session reaches a session route', () {
      expect(
        decide(route: ApiRoutes.offers, authorization: 'Bearer $sessionToken'),
        isA<ControlAuthorized>(),
      );
      expect(
        decide(
          route: ApiRoutes.authorization,
          authorization: 'Bearer $sessionToken',
        ),
        isA<ControlAuthorized>(),
      );
    });

    test(
      'a session does not reach a transfer-scoped route without a binding',
      () {
        // The default ownership table owns nothing, so this stays the conservative answer: a
        // session identity that is not bound to the transfer must not reach its routes.
        final ControlAuthorization decision = decide(
          route: ApiRoutes.pause,
          authorization: 'Bearer $sessionToken',
        );
        expect(decision, deniedWith(ProtocolErrorCode.notFound));
      },
    );

    test('a session whose peer owns the transfer reaches its routes', () {
      // §7's `decision` row is transfer-scoped and §3 issues the task token only *after* the
      // decision, so without this a client receiver could never decide at all.
      final ControlAuthorization decision = decide(
        route: ApiRoutes.decision,
        authorization: 'Bearer $sessionToken',
        ownership: owns(<String, TaskOwner>{taskId: sessionOwnsTask}),
      );
      expect(decision, isA<ControlAuthorized>());
    });

    test('only the bound session may read file metadata before acceptance', () {
      expect(
        decide(
          route: ApiRoutes.getManifest,
          authorization: 'Bearer $sessionToken',
          ownership: owns(<String, TaskOwner>{taskId: sessionOwnsTask}),
        ),
        isA<ControlAuthorized>(),
        reason: 'the receiver needs the bounded file pages to persist its output plan before deciding',
      );
      expect(
        decide(
          route: ApiRoutes.getManifest,
          authorization: 'Bearer $sessionToken',
        ),
        deniedWith(ProtocolErrorCode.notFound),
        reason: 'an unrelated session must not enumerate a transfer manifest',
      );
    });

    test('a session bound to a different peer is refused as if absent', () {
      // Same answer as a transfer that does not exist, so the status cannot be used to learn
      // which transfers exist or who owns them.
      final ControlAuthorization decision = decide(
        route: ApiRoutes.decision,
        authorization: 'Bearer $sessionToken',
        ownership: owns(<String, TaskOwner>{
          taskId: TaskOwner(
            peerId: 'peer-b',
            direction: TransferDirection.serverToClient,
          ),
        }),
      );
      expect(decision, deniedWith(ProtocolErrorCode.notFound));
    });

    test('a session whose task runs the wrong direction is 403, not 404', () {
      // The resource exists and this peer owns it, so the honest answer is that this operation
      // does not belong to the task's direction - `AGENTS.md` §5 makes that a mandatory check,
      // and the mapping must not have opened a path around it.
      final ControlAuthorization decision = decide(
        route: ApiRoutes.decision,
        authorization: 'Bearer $sessionToken',
        ownership: owns(<String, TaskOwner>{
          taskId: TaskOwner(
            peerId: 'peer-a',
            direction: TransferDirection.clientToServer,
          ),
        }),
      );
      expect(decision, deniedWith(ProtocolErrorCode.directionForbidden));
    });

    test('a binding for another transfer does not widen the session', () {
      final ControlAuthorization decision = decide(
        route: ApiRoutes.decision,
        authorization: 'Bearer $sessionToken',
        ownership: owns(<String, TaskOwner>{otherTaskId: sessionOwnsTask}),
      );
      expect(decision, deniedWith(ProtocolErrorCode.notFound));
    });

    test(
      'status accepts a session, a task token, or a completion-query token',
      () {
        expect(
          decide(
            route: ApiRoutes.status,
            authorization: 'Bearer $sessionToken',
            // §7 lists a session among the credentials `status` accepts, and the session is
            // scoped to the transfers it is bound to - so the ownership table is what makes
            // this session's answer an authorisation rather than a guess.
            ownership: owns(<String, TaskOwner>{taskId: sessionOwnsTask}),
          ),
          isA<ControlAuthorized>(),
        );
        expect(
          decide(route: ApiRoutes.status, authorization: 'Bearer $taskToken'),
          isA<ControlAuthorized>(),
        );
        expect(
          decide(
            route: ApiRoutes.status,
            authorization: 'Bearer $sessionToken',
          ),
          deniedWith(ProtocolErrorCode.notFound),
          reason:
              'without a binding the session must not reach another peer task, so the '
              'mapping cannot be bypassed by naming a transfer id',
        );
      },
    );
  });

  group('the operation direction is verified', () {
    test('a chunk upload requires client_to_server', () {
      expect(
        decide(route: ApiRoutes.putChunk, authorization: 'Bearer $taskToken'),
        isA<ControlAuthorized>(),
      );
      expect(
        decide(
          route: ApiRoutes.putChunk,
          authorization: 'Bearer $otherTaskToken',
        ),
        deniedWith(ProtocolErrorCode.directionForbidden),
      );
    });

    test('a chunk download requires server_to_client', () {
      expect(
        decide(
          route: ApiRoutes.getChunk,
          authorization: 'Bearer $otherTaskToken',
        ),
        isA<ControlAuthorized>(),
      );
      expect(
        decide(route: ApiRoutes.getChunk, authorization: 'Bearer $taskToken'),
        deniedWith(ProtocolErrorCode.directionForbidden),
      );
    });

    test('a direction violation is 403, not 404', () {
      // The two rules must not be conflated: the resource exists and the caller may see it,
      // but this operation is not part of this direction.
      final ControlAuthorization decision = decide(
        route: ApiRoutes.putChunk,
        authorization: 'Bearer $otherTaskToken',
      );
      expect((decision as ControlDenied).code.httpStatus, 403);
      expect(decision.code, ProtocolErrorCode.directionForbidden);
    });

    test('the checkpoint mirror is reported by the client receiver only', () {
      expect(
        decide(
          route: ApiRoutes.checkpoint,
          authorization: 'Bearer $otherTaskToken',
        ),
        isA<ControlAuthorized>(),
        reason: '§7: 仅 client 接收者汇报，server 只更新显示镜像',
      );
      expect(
        decide(route: ApiRoutes.checkpoint, authorization: 'Bearer $taskToken'),
        deniedWith(ProtocolErrorCode.directionForbidden),
      );
    });

    test('the acceptance decision belongs to the client receiver', () {
      expect(
        decide(
          route: ApiRoutes.decision,
          authorization: 'Bearer $otherTaskToken',
        ),
        isA<ControlAuthorized>(),
      );
      expect(
        decide(route: ApiRoutes.decision, authorization: 'Bearer $taskToken'),
        deniedWith(ProtocolErrorCode.directionForbidden),
      );
    });

    test('routes §7 gives no direction to accept either one', () {
      // pause, cancel, complete, control and controlReceipt are not direction-specific: the
      // local side must be able to stop its own work without depending on the peer.
      for (final String name in <String>[
        'pause',
        'cancel',
        'complete',
        'control',
        'controlReceipt',
      ]) {
        final ApiRoute route = ApiRoutes.all.firstWhere(
          (ApiRoute r) => r.name == name,
        );
        expect(
          ControlAuthTable.forRoute(route).direction,
          isNull,
          reason: '$name should carry no direction requirement',
        );
        for (final String token in <String>[taskToken, otherTaskToken]) {
          expect(
            decide(route: route, authorization: 'Bearer $token'),
            isA<ControlAuthorized>(),
            reason: '$name must accept both directions',
          );
        }
      }
    });

    test(
      'a direction requirement with the right transfer is the only way through',
      () {
        // Both halves have to hold: the transfer must match *and* the direction must be right.
        expect(
          decide(route: ApiRoutes.putChunk, authorization: 'Bearer $taskToken'),
          isA<ControlAuthorized>(),
        );
      },
    );
  });

  group('the denial reason stays local', () {
    test('it explains the rule for diagnostics', () {
      final ControlAuthorization decision = decide(
        route: ApiRoutes.putChunk,
        authorization: 'Bearer $otherTaskToken',
      );
      expect(
        (decision as ControlDenied).why,
        contains('client_to_server'),
        reason: 'the local reason should say which §7 rule refused',
      );
    });

    test('a denial never carries a reason into the wire body', () {
      // Asserted at the pipeline level too; here it is the property of the value itself:
      // why is a field, and the response is built from the code alone.
      final ControlDenied denial = decide(
        route: ApiRoutes.putChunk,
        authorization: 'Bearer $otherTaskToken',
      ) as ControlDenied;
      expect(denial.toString(), contains('DIRECTION_FORBIDDEN'));
      expect(denial.why, isNotEmpty);
    });
  });
}

/// Resolves tokens from a fixed map, so a test states grants rather than setting up storage.
class _MapAuthenticator implements ControlAuthenticator {
  const _MapAuthenticator(this.grants);

  final Map<String, ControlGrant> grants;

  @override
  ControlGrant? authenticate({required String token, required int nowMillis}) =>
      grants[token];
}

/// Resolves owners from a fixed map, for the same reason.
class _MapOwnership implements TaskOwnership {
  const _MapOwnership(this.owners);

  final Map<String, TaskOwner> owners;

  @override
  TaskOwner? ownerOf(String transferId) => owners[transferId];
}
