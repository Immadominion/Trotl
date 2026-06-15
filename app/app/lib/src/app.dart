import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:throtl/src/game_shell.dart';
import 'package:throtl/src/theme/theme_controller.dart';
import 'package:throtl/src/theme/tokens.dart';
import 'package:throtl/src/wallet/wallet_controller.dart';
import 'package:throtl/src/widgets/phone_frame.dart';

/// Root of the Throtl cockpit. Provides the [ThemeController] + [WalletController]
/// and frames the game shell (full-bleed on mobile, portrait bezel on a wide
/// web/desktop demo).
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
        home: PhoneFrame(child: GameShell(showOnboarding: showOnboarding)),
      ),
    );
  }
}
