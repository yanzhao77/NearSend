import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:nearsend/app/node_runtime.dart';
import 'package:nearsend/app/node_session.dart';
import 'package:nearsend/core/security/installation_identity.dart';
import 'package:nearsend/platform/android_file_gateway.dart';
import 'package:nearsend/platform/mdns_discovery_gateway.dart';

/// The application's node, as the connection screen sees it.
///
/// Every screen in this project existed and was tested; what was missing was a lifetime, and a
/// lifetime needs a **state** before it needs a widget: "still starting", "ready" and "could not
/// start" are three different things to show a user, and the failure cases below are the ones worth
/// pinning, because each one otherwise degrades into an empty connection screen with no explanation.
void main() {
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('nearsend-session-');
  });

  tearDown(() {
    if (root.existsSync()) {
      root.deleteSync(recursive: true);
    }
  });

  String directory() => '${root.path}${Platform.pathSeparator}app';

  test(
    'a started session publishes connection information and a pin',
    () async {
      final NodeSession session = NodeSession(
        resolveDirectory: () async => directory(),
        candidateAddresses: const <String>['127.0.0.1'],
      );
      final List<NodePhase> phases = <NodePhase>[];
      session.addListener(() => phases.add(session.phase));

      expect(session.phase, NodePhase.stopped);
      expect(session.payload, isNull);

      await session.start();

      expect(session.phase, NodePhase.ready);
      expect(session.isReady, isTrue);
      expect(session.node, isNotNull);
      final String pin = session.payload!.serverFingerprint;
      expect(
        pin,
        matches(RegExp(r'^[0-9a-f]{64}$')),
        reason: '§2 fixes the pin as 64 lowercase hex characters',
      );
      expect(
        session.payload!.candidates.single.port,
        session.node!.server.boundPort,
        reason:
            'the payload is issued after the socket binds, so the address it publishes is one a '
            'peer can actually reach',
      );
      expect(
        phases.first,
        NodePhase.starting,
        reason:
            'the screen must be able to say "starting" rather than showing an empty code while the '
            'socket binds',
      );
      expect(phases.last, NodePhase.ready);

      await session.stop();
      expect(session.phase, NodePhase.stopped);
    },
  );

  test(
    'starting twice opens one node, and concurrent calls share it',
    () async {
      int opened = 0;
      NodeRuntime open({
        required String directory,
        int port = 0,
        String commonName = 'NearSend',
        AndroidFileGateway? gateway,
        List<String>? candidateAddresses,
        InstallationIdentityProvider identityProvider =
            const EphemeralInstallationIdentityProvider(),
      }) {
        opened++;
        return NodeRuntime(
          directory: directory,
          candidateAddresses: candidateAddresses ?? const <String>['127.0.0.1'],
          identityProvider: identityProvider,
        );
      }

      final NodeSession session = NodeSession(
        resolveDirectory: () async => directory(),
        candidateAddresses: const <String>['127.0.0.1'],
        openRuntime: open,
      );

      // Two callers that do not know about each other - a screen mounting while a first attempt is
      // still resolving its directory - must not produce two identities for one installation.
      await Future.wait(<Future<void>>[session.start(), session.start()]);
      final node = session.node;
      await session.start();

      expect(opened, 1);
      expect(session.node, same(node));
      await session.stop();
    },
  );

  test(
    'a machine with no address is refused in words the user can act on',
    () async {
      final NodeSession session = NodeSession(
        resolveDirectory: () async => directory(),
        candidateAddresses: const <String>[],
      );

      await session.start();

      expect(session.phase, NodePhase.failed);
      expect(session.node, isNull);
      expect(
        session.failureReason,
        NodeSession.noAddressReason,
        reason:
            'a payload has to offer an address; publishing a loopback one would give the user a '
            'code no peer could use, and an empty screen would not say why',
      );
      expect(
        session.failureReason,
        contains('Wi-Fi'),
        reason: 'the remedy belongs in the sentence, not only in the diagnosis',
      );
      await session.stop();
    },
  );

  test(
    'a directory that cannot be resolved fails the start, and can be retried',
    () async {
      bool resolvable = false;
      final NodeSession session = NodeSession(
        resolveDirectory: () async {
          if (!resolvable) {
            throw const PlatformFileFailure('no application directory');
          }
          return directory();
        },
        candidateAddresses: const <String>['127.0.0.1'],
      );

      await session.start();
      expect(session.phase, NodePhase.failed);
      expect(session.failureReason, NodeSession.noDirectoryReason);
      expect(
        session.failureReason,
        isNot(contains('PathNotFoundException')),
        reason:
            'a person cannot act on an exception name, and the diagnosis belongs in the message '
            'the developer reads, not in the one the user does',
      );

      // A failure is a state, not a verdict: the retry below is what the user's "try again" becomes.
      resolvable = true;
      await session.start();
      expect(session.phase, NodePhase.ready);
      expect(session.payload, isNotNull);

      await session.stop();
    },
  );

  test(
    'stopping closes the database rather than leaving a handle behind',
    () async {
      final NodeSession session = NodeSession(
        resolveDirectory: () async => directory(),
        candidateAddresses: const <String>['127.0.0.1'],
      );
      await session.start();
      final String firstPin = session.payload!.serverFingerprint;
      await session.stop();

      expect(session.phase, NodePhase.stopped);
      expect(session.payload, isNull);
      expect(session.node, isNull);

      // A second node over the same directory is the only way to show the first one really closed:
      // on this platform an open SQLite handle makes the file's own cleanup fail, and a node that
      // merely forgot its reference would leave exactly that.
      final NodeSession second = NodeSession(
        resolveDirectory: () async => directory(),
        candidateAddresses: const <String>['127.0.0.1'],
      );
      await second.start();
      final node = second.node!;
      expect(
        node.pin,
        isNot(firstPin),
        reason:
            'the pin is regenerated per launch, which is why the connection screen tells the user '
            'it will change - if this ever starts matching, that note has become a stale warning',
      );
      await second.stop();
    },
  );

  test(
    'mDNS stays off until enabled and then publishes the real endpoint',
    () async {
      final _DiscoveryAdapter adapter = _DiscoveryAdapter();
      final NodeSession session = NodeSession(
        resolveDirectory: () async => directory(),
        candidateAddresses: const <String>['127.0.0.1'],
        discovery: MdnsDiscoveryGateway(adapter: adapter),
      );

      await session.start();

      expect(adapter.publication, isNull);
      await session.setDiscoveryEnabled(true);

      expect(adapter.publication, isNotNull);
      expect(adapter.publication!.port, session.node!.server.boundPort);
      expect(adapter.publication!.instanceId, session.payload!.sessionId);
      expect(session.discoveryFailureReason, isNull);

      await session.stop();
      expect(adapter.session.stops, 1);
    },
  );

  test('mDNS failure is reported without disabling manual pairing', () async {
    final NodeSession session = NodeSession(
      resolveDirectory: () async => directory(),
      candidateAddresses: const <String>['127.0.0.1'],
      discovery: MdnsDiscoveryGateway(adapter: _FailingDiscoveryAdapter()),
    );

    await session.start();

    await session.setDiscoveryEnabled(true);

    expect(session.phase, NodePhase.ready);
    expect(session.payload, isNotNull);
    expect(session.discoveryFailureReason, contains('手动连接'));
    await session.stop();
  });
}

class _DiscoveryAdapter implements MdnsPlatformAdapter {
  final _DiscoverySession session = _DiscoverySession();
  MdnsPublication? publication;

  @override
  Future<MdnsPlatformSession> start(MdnsPublication publication) async {
    this.publication = publication;
    return session;
  }
}

class _FailingDiscoveryAdapter implements MdnsPlatformAdapter {
  @override
  Future<MdnsPlatformSession> start(MdnsPublication publication) async {
    throw StateError('mDNS unavailable');
  }
}

class _DiscoverySession implements MdnsPlatformSession {
  int stops = 0;

  @override
  Stream<MdnsPlatformEvent> get events =>
      const Stream<MdnsPlatformEvent>.empty();

  @override
  Future<void> stop() async {
    stops++;
  }
}
