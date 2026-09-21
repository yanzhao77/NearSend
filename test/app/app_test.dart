import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nearsend/app/app.dart';
import 'package:nearsend/app/node_session.dart';
import 'package:nearsend/app/peer_session.dart';
import 'package:nearsend/features/transfer/presentation/transfer_pages.dart';
import 'package:nearsend/platform/android_file_gateway.dart';

/// The application, assembled: a node with a lifetime and a connection screen showing it.
///
/// The gap this closes is not a screen - every screen existed and was tested - but a lifetime:
/// nothing in `lib/app/` ever opened a node, so the connection screen showed a placeholder and the
/// file selection screen had no session to send through. The cases below are about what a user can
/// now see is **this device**, and about the states where it must not pretend.
void main() {
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('nearsend-app-');
  });

  tearDown(() {
    if (root.existsSync()) {
      root.deleteSync(recursive: true);
    }
  });

  NodeSession session() => NodeSession(
    resolveDirectory: () async => '${root.path}${Platform.pathSeparator}app',
    candidateAddresses: const <String>['127.0.0.1'],
  );

  /// Waits for [condition] while letting real work - a socket closing, a database handle being
  /// released - actually run.
  ///
  /// A widget test runs its body in a zone where timers are virtual, so a node's real I/O cannot
  /// finish inside it; `runAsync` is the one place real time passes, and a pump afterwards is what
  /// lets the framework deliver the result to the code waiting on it.
  Future<void> settle(WidgetTester tester, bool Function() condition) async {
    for (int attempt = 0; attempt < 40 && !condition(); attempt++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
    }
  }

  testWidgets('the connection screen shows the running node\'s own pin', (
    tester,
  ) async {
    final NodeSession node = session();
    final PeerSession peer = PeerSession();

    // Opened before the widget mounts, because opening it needs real I/O and the widget would
    // otherwise start it inside a zone where that cannot finish.
    await tester.runAsync(() => node.start());
    expect(node.phase, NodePhase.ready);

    await tester.pumpWidget(NearSendApp(session: node, peer: peer));
    await tester.pump();
    await tester.tap(find.text('发送文件'));
    await tester.pumpAndSettle();

    final String pin = node.payload!.serverFingerprint;
    expect(
      find.text(pin),
      findsOneWidget,
      reason:
          'the pin a peer must compare against has to be this device\'s real one, not a '
          'placeholder and not an empty state',
    );
    expect(
      find.text('127.0.0.1:${node.node!.server.boundPort}'),
      findsOneWidget,
      reason:
          'the published address has to name the port that is listening, or the peer is handed '
          'an address nothing answers on',
    );
    expect(
      find.textContaining('无法跨重启保留'),
      findsOneWidget,
      reason:
          'identity persistence is an open item, so a user must be told this pin will change; '
          'without that note the screen says something about their peer that is not true',
    );

    // Unmounting is what ends the application: the widget owns the session, so the node is closed
    // and the database released without any other caller having to remember to do it.
    await tester.pumpWidget(const SizedBox());
    await settle(tester, () => node.phase == NodePhase.stopped);
    expect(
      node.phase,
      NodePhase.stopped,
      reason:
          'a session handed to the application is the application\'s to close; a node left '
          'listening after the frame that owned it is gone has no owner at all',
    );
  });

  testWidgets('a build with no node says so rather than showing a fake pin', (
    tester,
  ) async {
    await tester.pumpWidget(const NearSendApp());
    await tester.tap(find.text('发送文件'));
    await tester.pumpAndSettle();

    expect(find.text(ConnectionPage.emptySessionNote), findsOneWidget);
  });

  testWidgets('a node that could not start states the reason', (tester) async {
    final NodeSession node = NodeSession(
      resolveDirectory: () async {
        throw const PlatformFileFailure('no application directory');
      },
      candidateAddresses: const <String>['127.0.0.1'],
    );
    await tester.pumpWidget(NearSendApp(session: node, peer: PeerSession()));
    await node.start();
    await tester.pump();

    await tester.tap(find.text('发送文件'));
    await tester.pumpAndSettle();

    expect(find.text(NodeSession.noDirectoryReason), findsOneWidget);
    expect(
      find.text(ConnectionPage.emptySessionNote),
      findsNothing,
      reason:
          '"nothing published yet" and "this device could not open its own files" are different '
          'answers, and the first would send the user looking for a fault in the other device',
    );
  });
}
