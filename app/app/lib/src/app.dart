import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:throtl/src/game_shell.dart';
import 'package:throtl/src/theme/theme_controller.dart';
import 'package:throtl/src/theme/tokens.dart';
import 'package:throtl/src/wallet/wallet_controller.dart';

/// Root of the Throtl cockpit. Provides the [ThemeController] + [WalletController].
/// The game fills the REAL viewport at every size — phone, iPad (portrait and
/// landscape) and desktop browser — and each screen adapts via the responsive
/// `GameScaffold` (no fake phone frame; the app sees the true MediaQuery).
class ThrotlApp extends StatelessWidget {
  const ThrotlApp({
    required this.themeController,
    required this.walletController,
    this.showOnboarding = false,
    super.key,
  });

  final ThemeController themeController;
  final WalletController walletController;
  final bool showOnboarding;

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<ThemeController>.value(value: themeController),
        ChangeNotifierProvider<WalletController>.value(value: walletController),
      ],
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        title: 'Throtl',
        theme: ThemeData(fontFamily: kFontBody, useMaterial3: true),
        home: GameShell(showOnboarding: showOnboarding),
      ),
    );
  }
}
