import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:throtl/src/app.dart';
import 'package:throtl/src/audio/sfx.dart';
import 'package:throtl/src/chain/network.dart';
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
  // NOTE: INTERNET is an install-time permission (already in AndroidManifest) — it is
  // NOT requestable at runtime, and a DNS failure is a device-network issue, not a
  // permission. On-device MWA needs no camera (that's only for desktop QR pairing).
  // Pick a working RPC before anything reads the chain — a non-resolving endpoint
  // (e.g. a Helius dedicated subdomain on Starlink) self-heals to a reachable one.
  await resolveRpc();
  final prefs = await SharedPreferences.getInstance();
  final seenOnboarding = prefs.getBool('onboarding_seen') ?? false;
  final theme = ThemeController(prefs);
  final wallet = WalletController();
  await sfx.init(enabled: theme.sfxOn);
  await music.init(enabled: theme.musicOn);
  runApp(
    ThrotlApp(
      themeController: theme,
      walletController: wallet,
      showOnboarding: !seenOnboarding,
    ),
  );
}
