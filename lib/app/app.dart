import 'package:flutter/material.dart';

import 'package:nearsend/app/theme/design_tokens.dart';
import 'package:nearsend/core/security/pairing_payload.dart';
import 'package:nearsend/features/about/presentation/about_page.dart';
import 'package:nearsend/features/home/presentation/home_page.dart';
import 'package:nearsend/features/transfer/presentation/transfer_pages.dart';

/// NearSend application root.
///
/// Owns only cross-cutting presentation concerns: theme, routing and the
/// localized app title. No business rule may live here — see
/// `docs/architecture/SYSTEM_ARCHITECTURE.md` §3.
///
/// ## Why the connection route takes an argument
///
/// `docs/ui/UI_UX_SPEC.md` §4 gives send and receive the same first step from the user's point of
/// view - establish a connection - and different wording for it. So one route serves both and is
/// told which, rather than two near-identical pages that would drift.
class NearSendApp extends StatelessWidget {
  const NearSendApp({super.key, this.pairingPayload});

  /// The payload this device publishes, when the application has opened a session.
  ///
  /// Optional and null by default: opening a session needs a running node, and this widget must
  /// not pretend to have one. The connection screen says so when it is null rather than drawing an
  /// empty code.
  final PairingPayload? pairingPayload;

  static const String homeRoute = '/';
  static const String aboutRoute = '/about';
  static const String connectRoute = '/connect';
  static const String transferRoute = '/transfer';

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'NearSend',
      debugShowCheckedModeBanner: false,
      theme: buildNearSendTheme(Brightness.light),
      darkTheme: buildNearSendTheme(Brightness.dark),
      themeMode: ThemeMode.system,
      initialRoute: homeRoute,
      routes: <String, WidgetBuilder>{
        homeRoute: (_) => const HomePage(),
        aboutRoute: (_) => const AboutPage(),
        connectRoute: (_) => ConnectionPage(
          payload: pairingPayload is PairingPayload ? pairingPayload : null,
        ),
      },
    );
  }
}
