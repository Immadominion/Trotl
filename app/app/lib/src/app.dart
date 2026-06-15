import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:throtl/src/game_shell.dart';
import 'package:throtl/src/theme/theme_controller.dart';
import 'package:throtl/src/theme/tokens.dart';
import 'package:throtl/src/wallet/wallet_controller.dart';
import 'package:throtl/src/widgets/web_shell.dart';

/// Root of the Throtl cockpit. Provides the [ThemeController] + [WalletController]
/// and presents the game shell (full-bleed on mobile; a responsive web cabinet —
/// branded hero beside the full-height game — on the web, via [WebShell]).
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
        home: WebShell(child: GameShell(showOnboarding: showOnboarding)),
      ),
    );
  }
}
