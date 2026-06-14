import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:throtl/src/app.dart';
import 'package:throtl/src/audio/sfx.dart';
import 'package:throtl/src/theme/theme_controller.dart';
import 'package:throtl/src/wallet/wallet_controller.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Portrait-only — the cockpit is a portrait racer; a stray rotation must never
  // recreate the app / drop the wallet session back to the login screen.
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);
  // Request permissions needed for Mobile Wallet Adapter (MWA) to sign transactions
  await Permission.camera.request(); // MWA uses camera for QR code scanning
  await Permission.internet.request(); // Network access for RPC calls
  final prefs = await SharedPreferences.getInstance();
  final theme = ThemeController(prefs);
  final wallet = WalletController();
  await sfx.init(enabled: theme.sfxOn);
  await music.init(enabled: theme.musicOn);
  runApp(ThrotlApp(themeController: theme, walletController: wallet));
}
