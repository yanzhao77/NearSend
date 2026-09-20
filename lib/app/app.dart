import 'package:flutter/material.dart';

import 'package:nearsend/app/theme/design_tokens.dart';
import 'package:nearsend/features/about/presentation/about_page.dart';
import 'package:nearsend/features/home/presentation/home_page.dart';

/// NearSend application root.
///
/// Owns only cross-cutting presentation concerns: theme, routing and the
/// localized app title. No business rule may live here — see
/// `docs/architecture/SYSTEM_ARCHITECTURE.md` §3.
class NearSendApp extends StatelessWidget {
  const NearSendApp({super.key});

  static const String homeRoute = '/';
  static const String aboutRoute = '/about';

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
      },
    );
  }
}
