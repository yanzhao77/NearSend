import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:nearsend/core/network/control_authorization.dart';
import 'package:nearsend/core/network/control_message.dart';
import 'package:nearsend/core/network/control_pipeline.dart';
import 'package:nearsend/core/protocol/api_routes.dart';
import 'package:nearsend/core/protocol/base64url.dart';
import 'package:nearsend/core/protocol/protocol_exception.dart';
import 'package:nearsend/core/protocol/transfer_direction.dart';

/// §7's pipeline: match, authorise, dispatch, and answer with a §7 error body.
///
/// The point of the pipeline is that **every** outcome is a response. A stage that threw
/// would push the decision onto the transport, where the §7 body is not available and the
/// natural mistake is to drop the connection - which tells the peer less and the log more.
void main() {
  const String taskId = '11111111-2222-4333-8444-555555555555';
  const String fileId = 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee';

  final String taskToken = encodeBase64UrlNoPadding(
    Uint8List.fromList(List<int>.filled(32, 0x22)),
  );

  final String sessionToken = encodeBase64UrlNoPadding(
    Uint8List.fromList(List<int>.filled(32, 0x11)),
  );

  ControlPipeline pipelineWith(
    Map<String, ControlHandler> handlers, {
    ControlAuthenticator? authenticator,
  }) => ControlPipeline(
    authenticator:
        authenticator ??
        _MapAuthenticator(<String, ControlGrant>{
          sessionToken: const SessionGrant(peerId: 'peer-a'),
          taskToken: TaskGrant(
            transferId: taskId,
            direction: TransferDirection.clientToServer,
          ),
        }),
    handlers: handlers,
    now: () => 1000,
  );

  ControlRequest get(
    String target, {
    Map<String, String>? headers,
    String? token,
  }) => ControlRequest(
    method: HttpMethod.get,
    target: target,
    headers: <String, String>{
      if (token != null) 'authorization': 'Bearer $token',
      ...?headers,
    },
  );

  ControlRequest post(
    String target, {
    Map<String, Object?>? body,
    String? token,
  }) => ControlRequest(
    method: HttpMethod.post,
    target: target,
    headers: <String, String>{
      if (token != null) 'authorization': 'Bearer $token',
    },
    body: body == null
        ? null
        : Uint8List.fromList(utf8.encode(jsonEncode(body))),
  );

  group('a request that never reaches a handler', () {
    test('a path no route answers is NOT_FOUND', () async {
      final ControlResponse response = await pipelineWith(
        const <String, ControlHandler>{},
      ).handle(get('/v1/nothing-here'));

      expect(response.status, 404);
      expect(response.decodeError().code, ProtocolErrorCode.notFound);
    });

    test('a path outside the §7 prefix is NOT_FOUND', () async {
      final ControlResponse response = await pipelineWith(
        const <String, ControlHandler>{},
      ).handle(get('/api/v1/offers'));
      expect(response.status, 404);
    });

    test(
      'a percent-encoded target is INVALID_PATH before anything else',
      () async {
        final ControlResponse response = await pipelineWith(
          const <String, ControlHandler>{},
        ).handle(get('/v1/transfers/%2e%2e/pause'));
        expect(response.status, 400);
        expect(response.decodeError().code, ProtocolErrorCode.invalidPath);
      },
    );

    test('a dot segment is INVALID_PATH', () async {
      final ControlResponse response = await pipelineWith(
        const <String, ControlHandler>{},
      ).handle(get('/v1/transfers/../pause'));
      expect(response.decodeError().code, ProtocolErrorCode.invalidPath);
    });

    test('an unknown query parameter is INVALID_FIELD', () async {
      final ControlResponse response = await pipelineWith(
        const <String, ControlHandler>{},
      ).handle(get('/v1/offers?bogus=1'));
      expect(response.status, 400);
      expect(response.decodeError().code, ProtocolErrorCode.invalidField);
    });

    test('a non-canonical identifier is INVALID_FIELD', () async {
      final ControlResponse response = await pipelineWith(
        const <String, ControlHandler>{},
      ).handle(get('/v1/transfers/ABC/manifest?kind=files'));
      expect(response.status, 400);
    });

    test('an unknown method on a known path is NOT_FOUND, not 405', () async {
      // §11's table has no 405, and §7 already answers unknown resources with 404 without
      // confirming which endpoints exist.
      final ControlResponse response = await pipelineWith(
        const <String, ControlHandler>{},
      ).handle(post('/v1/offers'));
      expect(response.status, 404);
      expect(response.decodeError().code, ProtocolErrorCode.notFound);
    });

    test(
      'a syntactically bad target is answered 400 even with no credential',
      () async {
        // The shape of a path is public; §7's 统一 404 protects resources, not syntax. So
        // validation answers first, and it does not leak whether a credential would have
        // been needed.
        final ControlResponse response = await pipelineWith(
          const <String, ControlHandler>{},
        ).handle(get('/v1/transfers/%2F/pause'));
        expect(response.status, 400);
        expect(response.decodeError().code, ProtocolErrorCode.invalidPath);
      },
    );
  });

  group('authorisation runs before the handler', () {
    test('a bearer route with no Authorization header is 401 and the handler never runs', () async {
      bool ran = false;
      final ControlPipeline pipeline = pipelineWith(<String, ControlHandler>{
        'pause':
            (
              ControlRequest request,
              MatchedApiRequest matched,
              ControlAuthorized authorization,
            ) async {
              ran = true;
              return ControlResponse.json(
                status: 200,
                body: <String, Object?>{'state': 'PAUSED'},
              );
            },
      });

      final ControlResponse response = await pipeline.handle(
        post('/v1/transfers/$taskId/pause'),
      );

      expect(response.status, 401);
      expect(response.decodeError().code, ProtocolErrorCode.authExpired);
      expect(ran, isFalse, reason: '任何环节失败都不执行后续文件操作');
    });

    test(
      'a token the authority rejects is 401 even when well formed',
      () async {
        final ControlPipeline pipeline = pipelineWith(<String, ControlHandler>{
          'pause':
              (
                ControlRequest request,
                MatchedApiRequest matched,
                ControlAuthorized authorization,
              ) async => ControlResponse.json(
                status: 200,
                body: <String, Object?>{'state': 'PAUSED'},
              ),
        }, authenticator: const RejectingAuthenticator());

        final ControlResponse response = await pipeline.handle(
          post('/v1/transfers/$taskId/pause', token: taskToken),
        );
        expect(response.status, 401);
      },
    );

    test('pair needs no credential and reaches its handler', () async {
      final ControlPipeline pipeline = pipelineWith(<String, ControlHandler>{
        'pair':
            (
              ControlRequest request,
              MatchedApiRequest matched,
              ControlAuthorized authorization,
            ) async => ControlResponse.json(
              status: 200,
              body: <String, Object?>{'paired': true},
            ),
      });

      final ControlResponse response = await pipeline.handle(
        post('/v1/pair', body: <String, Object?>{'pairToken': 'x'}),
      );
      expect(response.status, 200);
      expect(response.decodeJsonBody()['paired'], true);
    });

    test('the pipeline passes its clock to the authority', () async {
      final _RecordingAuthenticator recorder = _RecordingAuthenticator();
      final ControlPipeline pipeline = pipelineWith(
        <String, ControlHandler>{},
        authenticator: recorder,
      );
      await pipeline.handle(
        post('/v1/transfers/$taskId/pause', token: taskToken),
      );
      expect(recorder.lastNowMillis, 1000);
      expect(recorder.lastToken, taskToken);
    });

    test('the handler receives the authorisation that was accepted', () async {
      // §9's idempotency scope is "同一任务＋操作＋当前恢复凭证", so a handler has to be able
      // to see which credential was accepted. A grant never carries the secret, which is why
      // the result is passed rather than the token.
      ControlAuthorized? seen;
      final ControlPipeline pipeline = pipelineWith(<String, ControlHandler>{
        'pause':
            (
              ControlRequest request,
              MatchedApiRequest matched,
              ControlAuthorized authorization,
            ) async {
              seen = authorization;
              return ControlResponse.json(
                status: 200,
                body: <String, Object?>{'state': 'PAUSED'},
              );
            },
      });

      await pipeline.handle(
        post('/v1/transfers/$taskId/pause', token: taskToken),
      );

      expect(seen, isNotNull);
      expect(seen!.grant, isA<TaskGrant>());
      expect((seen!.grant! as TaskGrant).transferId, taskId);
    });
  });

  group('dispatching to a handler', () {
    test(
      'an unregistered route is NOT_FOUND and reports what it serves',
      () async {
        final ControlPipeline pipeline = pipelineWith(<String, ControlHandler>{
          'pair':
              (
                ControlRequest request,
                MatchedApiRequest matched,
                ControlAuthorized authorization,
              ) async =>
                  ControlResponse.json(status: 200, body: <String, Object?>{}),
        });

        expect(pipeline.servedRoutes, <String>{'pair'});
        final ControlResponse response = await pipeline.handle(
          get('/v1/offers', token: sessionToken),
        );
        expect(response.status, 404);
        expect(
          response.decodeError().code,
          ProtocolErrorCode.notFound,
          reason:
              'the credential was fine, so this 404 is the missing handler rather than '
              'authorisation',
        );
      },
    );

    test(
      'the handler receives the matched request with typed parameters',
      () async {
        MatchedApiRequest? seen;
        final ControlPipeline pipeline = pipelineWith(<String, ControlHandler>{
          'getManifest':
              (
                ControlRequest request,
                MatchedApiRequest matched,
                ControlAuthorized authorization,
              ) async {
                seen = matched;
                return ControlResponse.json(
                  status: 200,
                  body: <String, Object?>{'fileCount': 0},
                );
              },
        });

        final ControlResponse response = await pipeline.handle(
          get(
            '/v1/transfers/$taskId/manifest?kind=chunks&fileId=$fileId&limit=7',
            token: taskToken,
          ),
        );

        expect(response.status, 200);
        expect(seen, isNotNull);
        expect(seen!.route.name, 'getManifest');
        expect(seen!.transferId, taskId);
        expect(seen!.fileId, fileId);
        expect(seen!.manifestKind(), ManifestPageKind.chunks);
        expect(
          seen!.pageLimit(),
          7,
          reason:
              'the handler never re-parses the target; it is already validated',
        );
      },
    );

    test('the handler response is returned as built', () async {
      final ControlPipeline pipeline = pipelineWith(<String, ControlHandler>{
        'pair':
            (
              ControlRequest request,
              MatchedApiRequest matched,
              ControlAuthorized authorization,
            ) async => ControlResponse.json(
              status: 201,
              body: <String, Object?>{'state': 'STAGING'},
            ),
      });

      final ControlResponse response = await pipeline.handle(post('/v1/pair'));
      expect(response.status, 201);
      expect(response.decodeJsonBody()['state'], 'STAGING');
    });

    test('a handler protocol violation becomes its own §11 answer', () async {
      final ControlPipeline pipeline = pipelineWith(<String, ControlHandler>{
        'pause':
            (
              ControlRequest request,
              MatchedApiRequest matched,
              ControlAuthorized authorization,
            ) async {
              throw const ProtocolViolation(
                ProtocolErrorCode.invalidState,
                'the task is not in a state that can be paused',
              );
            },
      });

      final ControlResponse response = await pipeline.handle(
        post('/v1/transfers/$taskId/pause', token: taskToken),
      );

      expect(response.status, 409);
      expect(response.decodeError().code, ProtocolErrorCode.invalidState);
      expect(
        response.decodeJsonBody()['message'],
        ProtocolErrorCode.invalidState.messageKey,
        reason: 'the local explanation is for diagnostics and must not reach the peer',
      );
    });

    test('a 429 from a handler keeps its Retry-After', () async {
      final ControlPipeline pipeline = pipelineWith(<String, ControlHandler>{
        'pause':
            (
              ControlRequest request,
              MatchedApiRequest matched,
              ControlAuthorized authorization,
            ) async => ControlResponse.error(
              ProtocolErrorCode.rateLimited,
              retryAfterSeconds: 7,
            ),
      });

      final ControlResponse response = await pipeline.handle(
        post('/v1/transfers/$taskId/pause', token: taskToken),
      );
      expect(response.status, 429);
      expect(response.headers['retry-after'], '7');
      expect(response.decodeError().retryable, isTrue);
    });
  });

  group('every answer is uncacheable and shaped like §7', () {
    test(
      'success and failure both carry no-store and a control content type',
      () async {
        final ControlPipeline pipeline = pipelineWith(<String, ControlHandler>{
          'pair':
              (
                ControlRequest request,
                MatchedApiRequest matched,
                ControlAuthorized authorization,
              ) async => ControlResponse.json(
                status: 200,
                body: <String, Object?>{'paired': true},
              ),
        });

        final List<ControlResponse> responses = <ControlResponse>[
          await pipeline.handle(post('/v1/pair')),
          await pipeline.handle(get('/v1/nothing-here')),
          await pipeline.handle(get('/v1/transfers/%2F/pause')),
          await pipeline.handle(post('/v1/transfers/$taskId/pause')),
          await pipeline.handle(get('/v1/offers')),
        ];

        for (final ControlResponse response in responses) {
          expect(response.headers['cache-control'], 'no-store');
          expect(response.headers['content-type'], controlContentType);
        }
      },
    );

    test('an error body echoes the requestId the peer supplied', () async {
      const String requestId = '11111111-2222-4333-8444-555555555555';
      final ControlPipeline pipeline = pipelineWith(
        const <String, ControlHandler>{},
        authenticator: const RejectingAuthenticator(),
      );

      final ControlResponse response = await pipeline.handle(
        post(
          '/v1/transfers/$taskId/pause',
          body: <String, Object?>{'requestId': requestId},
          token: taskToken,
        ),
      );

      expect(response.status, 401);
      expect(
        response.decodeError().requestId,
        requestId,
        reason:
            '§9 makes requestId the correlation handle, so an error that cannot be '
            'correlated is hard to act on',
      );
    });

    test('an unreadable body yields no requestId but still an error', () async {
      final ControlPipeline pipeline = pipelineWith(
        const <String, ControlHandler>{},
        authenticator: const RejectingAuthenticator(),
      );

      final ControlResponse response = await pipeline.handle(
        ControlRequest(
          method: HttpMethod.post,
          target: '/v1/transfers/$taskId/pause',
          headers: <String, String>{'authorization': 'Bearer $taskToken'},
          body: Uint8List.fromList(<int>[0xFF, 0xFE]),
        ),
      );

      expect(response.status, 401);
      expect(response.decodeError().requestId, isNull);
    });

    test('a requestId that is not a canonical UUID is not echoed', () async {
      final ControlPipeline pipeline = pipelineWith(
        const <String, ControlHandler>{},
        authenticator: const RejectingAuthenticator(),
      );

      final ControlResponse response = await pipeline.handle(
        post(
          '/v1/transfers/$taskId/pause',
          body: <String, Object?>{'requestId': 'not-a-uuid'},
          token: taskToken,
        ),
      );
      expect(response.decodeError().requestId, isNull);
    });
  });
}

/// An authority that resolves tokens from a fixed map.
class _MapAuthenticator implements ControlAuthenticator {
  const _MapAuthenticator(this.grants);

  final Map<String, ControlGrant> grants;

  @override
  ControlGrant? authenticate({required String token, required int nowMillis}) =>
      grants[token];
}

/// An authority that records what the pipeline asked it, so the seam is observable.
class _RecordingAuthenticator implements ControlAuthenticator {
  String? lastToken;
  int? lastNowMillis;

  @override
  ControlGrant? authenticate({required String token, required int nowMillis}) {
    lastToken = token;
    lastNowMillis = nowMillis;
    return null;
  }
}
