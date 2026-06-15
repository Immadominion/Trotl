import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:throtl/src/audio/sfx.dart';
import 'package:throtl/src/engine/live_ride_controller.dart';
import 'package:throtl/src/engine/price_feed.dart';
import 'package:throtl/src/engine/ride_controller.dart';
import 'package:throtl/src/screens/arming_screen.dart';
import 'package:throtl/src/screens/countdown_screen.dart';
import 'package:throtl/src/screens/garage_screen.dart';
import 'package:throtl/src/screens/grid_screen.dart';
import 'package:throtl/src/screens/onboarding_screen.dart';
import 'package:throtl/src/screens/paddock_screen.dart';
import 'package:throtl/src/screens/pit_bay_screen.dart';
import 'package:throtl/src/screens/race_screen.dart';
import 'package:throtl/src/screens/results_screen.dart';
import 'package:throtl/src/screens/season_screen.dart';
import 'package:throtl/src/screens/settings_screen.dart';
import 'package:throtl/src/screens/title_screen.dart';
import 'package:throtl/src/util/session_history.dart';
import 'package:throtl/src/wallet/wallet_controller.dart';
import 'package:throtl_core/throtl_core.dart';

/// The screens of the flow (matches the design's board map).
enum ScreenId {
  onboarding,
  title,
  garage,
  grid,
  arming,
  countdown,
  race,
  results,
  pitBay,
  season,
  paddock,
  settings,
}

/// Owns navigation + the ride lifecycle (the one shared [PriceFeed], the active
/// [RideController], the last [SessionStats]) and wires every screen's callbacks.
/// Mirrors the design's `GFlowApp`.
class GameShell extends StatefulWidget {
  const GameShell({this.showOnboarding = false, super.key});

  /// First launch (intro not yet seen) → open the onboarding before the title.
  final bool showOnboarding;

  @override
  State<GameShell> createState() => _GameShellState();
}

class _GameShellState extends State<GameShell> with WidgetsBindingObserver {
  ScreenId _screen = ScreenId.title;

  late final PriceFeed _feed;
  RideEngine? _ride;
  SessionStats? _stats;

  int _fuelUsd6 = 250 * 1000000; // $250 default stake
  int _marketId = 0; // selected market (SOL default)
  int _maxLevBps = 50000; // 5x downforce default (editable on the grid)
  int _gripBandBps = 250;

  /// Dev aid: `--dart-define=THROTL_START=garage` boots straight to a screen (for
  /// responsive screenshotting). Empty default ⇒ no effect in normal builds.
  static const _debugStart = String.fromEnvironment('THROTL_START');

  @override
  void initState() {
    super.initState();
    if (widget.showOnboarding) _screen = ScreenId.onboarding;
    if (_debugStart.isNotEmpty) {
      _screen = ScreenId.values.firstWhere(
        (s) => s.name == _debugStart,
        orElse: () => _screen,
      );
    }
    _feed = FlashPriceFeed()..start();
    WidgetsBinding.instance.addObserver(this);
    // App-open ambience — the menu loop plays under every non-race screen.
    unawaited(music.startMenuLoop());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(music.stopLoop());
    sfx.engineStop();
    _ride?.dispose();
    _feed.dispose();
    super.dispose();
  }

  /// Pause all continuous audio when the app leaves the foreground (no more
  /// YouTube-style background music / engine drone), and resume + re-read funds
  /// when it comes back (the balance can change while you're in your wallet app).
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        music.resumeLoop();
        sfx.resumeEngine();
        final wallet = context.read<WalletController>();
        if (wallet.isConnected) unawaited(wallet.refreshBalances());
      case AppLifecycleState.inactive:
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
      case AppLifecycleState.detached:
        music.pauseLoop();
        sfx.pauseEngine();
    }
  }

  void _go(ScreenId s) => setState(() => _screen = s);

  Future<void> _finishOnboarding() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('onboarding_seen', true);
    if (mounted) _go(ScreenId.title);
  }

  RideConfig _buildConfig() => RideConfig(
    fuelUsd6: _fuelUsd6,
    maxLevBps: _maxLevBps,
    lossFloor6: -(_fuelUsd6 * 0.8).round(),
    marketId: _marketId,
    bandBps: _gripBandBps,
  );

  void _arm(int fuelUsd6, int marketId, int maxLevBps) {
    setState(() {
      _fuelUsd6 = fuelUsd6;
      _marketId = marketId;
      _maxLevBps = maxLevBps;
    });
    final wallet = context.read<WalletController>();
    if (wallet.isConnected) {
      // LIVE: do ALL the signing FIRST (the wallet popup happens on the Arming
      // screen, before the 3·2·1) so the countdown is pure showmanship over a
      // ride that's already armed on-chain. A REAL ride: owner-signed
      // init+delegate via MWA, gasless session-key ticks. The Flash settlement
      // venue is real only when go-live is armed; otherwise simulated — no funds.
      _ride?.dispose();
      final ride = LiveRideController(
        wallet: wallet,
        network: wallet.network,
        config: _buildConfig(),
      )..start();
      setState(() {
        _ride = ride;
        _screen = ScreenId.arming;
      });
    } else {
      // PRACTICE: nothing to sign — straight to the countdown; the local engine
      // is built when the lights go out.
      _ride?.dispose();
      _ride = null;
      _go(ScreenId.countdown);
    }
  }

  // Live ride armed (owner signed, status → riding) — run the countdown.
  void _armed() => _go(ScreenId.countdown);

  // Arming failed or cancelled — tear the ride down and return to the grid.
  void _armAbort() {
    _ride?.dispose();
    _ride = null;
    _go(ScreenId.grid);
  }

  void _startRace() {
    final existing = _ride;
    unawaited(music.startRaceLoop());
    if (existing is LiveRideController) {
      // Live ride already armed on the Arming screen — just enter the arena.
      setState(() => _screen = ScreenId.race);
      return;
    }
    // Practice: build the local engine against the synthetic feed (always works).
    _ride?.dispose();
    final ride = RideController(feed: _feed, config: _buildConfig())..start();
    setState(() {
      _ride = ride;
      _screen = ScreenId.race;
    });
  }

  void _pitIn(SessionStats stats) {
    _ride?.stop();
    sfx.engineStop();
    // Back to menus → swap the race track out for the ambient loop.
    unawaited(music.startMenuLoop());
    if (stats.realized6 >= 0) {
      sfx.pitWin();
    } else {
      sfx.pitLoss();
    }
    // Record the ride in the real Paddock history (practice + live, tagged).
    unawaited(
      SessionHistoryStore.record(
        RaceSession(
          tsMs: DateTime.now().millisecondsSinceEpoch,
          pnl6: stats.realized6,
          ticks: stats.ticks,
          peakLev: stats.peakLev,
          live: _ride is LiveRideController,
        ),
      ),
    );
    setState(() {
      _stats = stats;
      _screen = ScreenId.results;
    });
  }

  void _setGrip(int bps) => setState(() => _gripBandBps = bps);

  Widget _current() {
    switch (_screen) {
      case ScreenId.onboarding:
        return OnboardingScreen(onFinish: _finishOnboarding);
      case ScreenId.title:
        return TitleScreen(
          feed: _feed,
          onConnect: () => _go(ScreenId.garage),
        );
      case ScreenId.garage:
        return GarageScreen(
          onRace: () => _go(ScreenId.grid),
          onPitBay: () => _go(ScreenId.pitBay),
          onSeason: () => _go(ScreenId.season),
          onPaddock: () => _go(ScreenId.paddock),
          onSettings: () => _go(ScreenId.settings),
        );
      case ScreenId.grid:
        return GridScreen(
          maxLevBps: _maxLevBps,
          onArm: _arm,
          onBack: () => _go(ScreenId.garage),
        );
      case ScreenId.arming:
        return ArmingScreen(
          engine: _ride! as LiveRideController,
          onReady: _armed,
          onAbort: _armAbort,
        );
      case ScreenId.countdown:
        return CountdownScreen(onDone: _startRace);
      case ScreenId.race:
        return RaceScreen(ride: _ride!, onPitIn: _pitIn);
      case ScreenId.results:
        return ResultsScreen(
          stats:
              _stats ??
              const SessionStats(
                realized6: 0,
                ticks: 0,
                bestStreak: 0,
                peakLev: 0,
                winRate: 0,
              ),
          engine: _ride, // drives the live settle card (flatten → commit → undelegate → close)
          onReplay: () => _go(ScreenId.grid),
          onClaim: () => _go(ScreenId.garage),
          onPaddock: () => _go(ScreenId.paddock),
        );
      case ScreenId.pitBay:
        return PitBayScreen(
          gripBandBps: _gripBandBps,
          onGrip: _setGrip,
          onBack: () => _go(ScreenId.garage),
          onRace: () => _go(ScreenId.grid),
        );
      case ScreenId.season:
        return SeasonScreen(
          onBack: () => _go(ScreenId.garage),
          onRace: () => _go(ScreenId.grid),
        );
      case ScreenId.paddock:
        return PaddockScreen(
          onBack: () => _go(ScreenId.garage),
          onRace: () => _go(ScreenId.grid),
        );
      case ScreenId.settings:
        return SettingsScreen(onBack: () => _go(ScreenId.garage));
    }
  }

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: const Color(0xFF0D163A),
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 240),
        child: KeyedSubtree(key: ValueKey(_screen), child: _current()),
      ),
    );
  }
}
