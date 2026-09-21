import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:nearsend/app/node_runtime.dart';
import 'package:nearsend/core/protocol/protocol_limits.dart';

/// The application's node lifetime.
///
/// This is the piece the remaining work was missing: every screen existed and was tested, but
/// nothing in `lib/app/` ever opened a node, so the selection screen had no sending session to call.
/// These cases pin the two decisions that matter - when a node is open, and what happens when there
/// is no network to publish an address for.
void main() {
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('nearsend-runtime-');
  });

  tearDown(() {
    if (root.existsSync()) {
      root.deleteSync(recursive: true);
    }
  });

  NodeRuntime runtime({List<String>? candidates}) => NodeRuntime(
    directory: '${root.path}${Platform.pathSeparator}app',
    candidateAddresses: candidates ?? const <String>['127.0.0.1'],
  );

  test('a started runtime holds a node and publishes a payload', () async {
    final NodeRuntime subject = runtime();
    expect(subject.isRunning, isFalse);
    expect(subject.node, isNull);

    final node = await subject.start();

    expect(subject.isRunning, isTrue);
    expect(subject.node, same(node));
    expect(
      node.pin,
      hasLength(ProtocolLimits.sha256HexLength),
      reason: '§2 fixes the pin as 64 lowercase hex characters',
    );
    expect(
      node.payload,
      isNotNull,
      reason:
          '§3s payload is what the connection screen shows; a started node that published '
          'nothing would give the user nothing to compare',
    );
    expect(
      node.payload!.candidates.single.port,
      node.server.boundPort,
      reason:
          'the payload is issued after the socket binds, so its candidate names the port that '
          'is actually listening',
    );

    await subject.stop();
    expect(subject.isRunning, isFalse);
  });

  test(
    'starting twice returns the same node rather than a second identity',
    () async {
      final NodeRuntime subject = runtime();
      final first = await subject.start();
      final second = await subject.start();

      expect(
        second,
        same(first),
        reason:
            'two nodes on one database would be two identities for one installation, and the '
            'second would silently invalidate the payload the first published - the same hazard '
            '§3 names for a re-issued QR code',
      );
      expect(second.pin, first.pin);

      await subject.stop();
    },
  );

  test('stopping twice is safe', () async {
    final NodeRuntime subject = runtime();
    await subject.start();
    await subject.stop();
    await subject.stop();
    expect(subject.isRunning, isFalse);
  });

  test(
    'a second runtime over the same directory works after the first closes',
    () async {
      // What a restart looks like. The pin is expected to differ: identity persistence is an open
      // item, and this asserts the honest consequence rather than pretending otherwise.
      final NodeRuntime first = runtime();
      final node = await first.start();
      final String firstPin = node.pin;
      await first.stop();

      final NodeRuntime second = runtime();
      final restarted = await second.start();
      expect(
        restarted.pin,
        isNot(firstPin),
        reason:
            'the node mints a fresh identity each time it opens, which is exactly why the '
            'connection screen tells the user the pin will change - if this ever starts matching, '
            'that note has become a stale warning and must be removed with it',
      );
      await second.stop();
    },
  );

  test(
    'a runtime with no address refuses to start rather than publishing nothing',
    () async {
      final NodeRuntime subject = runtime(candidates: const <String>[]);

      await expectLater(
        subject.start(),
        throwsA(isA<StateError>()),
        reason:
            '§3s payload has to offer an address; a node reachable only on loopback would publish '
            'a QR code no peer on the network could use',
      );
      expect(subject.isRunning, isFalse);
    },
  );

  test('candidate addresses are read from the interfaces when none are given', () async {
    final List<String> addresses = await NodeRuntime.lanAddresses();
    for (final String address in addresses) {
      expect(
        address.startsWith('127.'),
        isFalse,
        reason: 'loopback is not reachable from the other device',
      );
      expect(
        address.startsWith('169.254.'),
        isFalse,
        reason:
            'a link-local address means no DHCP answer, not a usable address',
      );
    }
    // An empty list is a legitimate answer on a machine with no network, so nothing is asserted
    // about its length; what is asserted is that whatever comes back is usable.
  });
}
