import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:throtl/src/audio/sfx.dart';
import 'package:throtl/src/theme/theme_controller.dart';
import 'package:throtl/src/theme/tokens.dart';
import 'package:throtl/src/util/responsive.dart';
import 'package:throtl/src/wallet/wallet_controller.dart';
import 'package:throtl/src/widgets/balance_pill.dart';
import 'package:throtl/src/widgets/car_turntable.dart';
import 'package:throtl/src/widgets/chunky.dart';
import 'package:throtl/src/widgets/fund_coach.dart';
import 'package:throtl/src/widgets/fund_sheet.dart';

/// 01 · Garage (home) — car showroom, gear tiles, tracks, season. The design's
/// `GGarageScreen`. Car selection lives in the [ThemeController].
class GarageScreen extends StatefulWidget {
  const GarageScreen({
    required this.onRace,
    required this.onPitBay,
    required this.onSeason,
    required this.onPaddock,
    required this.onSettings,
    super.key,
  });

  final VoidCallback onRace;
  final VoidCallback onPitBay;
  final VoidCallback onSeason;
  final VoidCallback onPaddock;
  final VoidCallback onSettings;

  @override
  State<GarageScreen> createState() => _GarageScreenState();
}

class _GarageScreenState extends State<GarageScreen> {
  String? _toast;
  Timer? _toastT;
  final GlobalKey _fundKey = GlobalKey();
  bool _showCoach = false;

  @override
  void initState() {
    super.initState();
    unawaited(_maybeShowCoach());
  }

  /// Show the fund spotlight once — the first time a connected player lands on the
  /// home hub. Cancellable; either way it never shows twice.
  Future<void> _maybeShowCoach() async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool('fund_coach_seen') ?? false) return;
    if (!mounted) return;
    if (!context.read<WalletController>().isConnected) return;
    // let the header lay out so the spotlight can find the +
    await Future<void>.delayed(const Duration(milliseconds: 480));
    if (!mounted) return;
    await prefs.setBool('fund_coach_seen', true);
    if (mounted) setState(() => _showCoach = true);
  }

  void _lockToast(String name) {
    sfx.notify();
    setState(() => _toast = '$name UNLOCKS IN SEASON 2');
    _toastT?.cancel();
    _toastT = Timer(
      const Duration(milliseconds: 1800),
      () {
        if (mounted) setState(() => _toast = null);
      },
    );
  }

  @override
  void dispose() {
    _toastT?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final theme = context.watch<ThemeController>();
    final wallet = context.watch<WalletController>();
    return Stack(
      children: [
        GameScaffold(
          bottomBar: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: ChunkyButton(
                      label: 'SEASON',
                      color: p.purple,
                      onTap: widget.onSeason,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    flex: 2,
                    child: ChunkyButton(
                      label: 'START RACE',
                      color: p.orange,
                      big: true,
                      onTap: widget.onRace,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: ChunkyButton(
                      label: 'PIT BAY',
                      color: p.green,
                      onTap: widget.onPitBay,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              // Ride-mode status (the actual switch lives in Settings). Practice =
              // fake funds vs the real mainnet market; Live = real funds on mainnet.
              GestureDetector(
                onTap: () {
                  sfx.open();
                  widget.onSettings();
                },
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      wallet.isConnected ? Icons.bolt : Icons.videogame_asset_outlined,
                      size: 13,
                      color: p.white,
                    ),
                    const SizedBox(width: 5),
                    Flexible(
                      child: Text(
                        wallet.isConnected
                            ? 'LIVE · MAINNET · ${wallet.ownerShort}'
                            : 'PRACTICE · fake funds vs the real market',
                        textAlign: TextAlign.center,
                        style: bodyStyle(size: 10, color: p.white, weight: FontWeight.w800)
                            .copyWith(
                              shadows: [Shadow(color: p.ink, offset: const Offset(0, 1.5))],
                            ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          child: Stack(
            children: [
              if (context.isWide) _wideBody(p, theme, wallet) else _phoneBody(p, theme, wallet),
              if (_toast != null)
                Align(
                  alignment: const Alignment(0, 0.75),
                  child: ChunkyToast(text: _toast!),
                ),
            ],
          ),
        ),
        if (_showCoach)
          FundCoach(
            targetKey: _fundKey,
            onFund: () {
              setState(() => _showCoach = false);
              unawaited(showFundSheet(context));
            },
            onDismiss: () => setState(() => _showCoach = false),
          ),
      ],
    );
  }

  // ── shared pieces (used by both the phone column and the wide two-pane) ──
  Widget _header(ThrotlPalette p, WalletController wallet) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const BannerPlate(kicker: 'SEASON 1 · RARE+', title: 'HOME'),
        Row(
          children: [
            _iconButton(p, Icons.settings, widget.onSettings),
            const SizedBox(width: 8),
            // Tap the coin = your race history; long-press = reload.
            BalancePill(onHistory: widget.onPaddock),
            if (wallet.isConnected) ...[
              const SizedBox(width: 8),
              _fundButton(p),
            ],
          ],
        ),
      ],
    );
  }

  Widget _tracks(ThrotlPalette p) {
    return FittedBox(
      fit: BoxFit.scaleDown,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _trackChip(p, 'SOL SPEEDWAY', on: true),
          const SizedBox(width: 8),
          _trackChip(p, 'BTC SUMMIT', on: false),
          const SizedBox(width: 8),
          _trackChip(p, 'ETH CIRCUIT', on: false),
        ],
      ),
    );
  }

  Widget _stats(ThrotlPalette p) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        StatPill(
          icon: Icon(Icons.bolt, color: p.white, size: 16),
          value: '5x MAX',
          color: p.purple,
        ),
        const SizedBox(width: 14),
        StatPill(
          icon: Icon(Icons.shield, color: p.white, size: 15),
          value: '±250BPS',
          color: p.cyan,
        ),
      ],
    );
  }

  Widget _xpBar() {
    return GestureDetector(
      onTap: widget.onSeason,
      child: const ChunkyBar(
        frac: 0.62,
        height: 22,
        label: 'PILOT LV 4 · 248/400 XP',
      ),
    );
  }

  Widget _phoneBody(ThrotlPalette p, ThemeController theme, WalletController wallet) {
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _header(p, wallet),
          const SizedBox(height: 4),
          _carStage(p, theme),
          const SizedBox(height: 22),
          _tracks(p),
          const SizedBox(height: 16),
          _stats(p),
          const SizedBox(height: 14),
          _xpBar(),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  /// Wide (iPad landscape / desktop): header on top, then the car SHOWCASE fills
  /// the left and a controls panel (tracks · stats · XP) sits on the right — the
  /// garage uses the whole landscape instead of a tall centred column.
  Widget _wideBody(ThrotlPalette p, ThemeController theme, WalletController wallet) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _header(p, wallet),
        const SizedBox(height: 10),
        Expanded(
          child: TwoPane(
            primary: _carShowcase(p, theme),
            secondary: Center(
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _gearGrid(p),
                    const SizedBox(height: 24),
                    _tracks(p),
                    const SizedBox(height: 22),
                    _stats(p),
                    const SizedBox(height: 22),
                    _xpBar(),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// Wide-screen car showcase — the ‹ › swap arrows flank the car, which is
  /// vertically centred at a comfortable size, with the name label below. (The
  /// gear tiles move to the right panel via [_gearGrid] so the car reads clean.)
  Widget _carShowcase(ThrotlPalette p, ThemeController theme) {
    return Column(
      children: [
        Expanded(
          child: Row(
            children: [
              _arrow(p, '‹', () => context.read<ThemeController>().cycleCar(-1)),
              Expanded(
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 340),
                    child: CarTurntable(src: theme.car.glb, poster: theme.car.side),
                  ),
                ),
              ),
              _arrow(p, '›', () => context.read<ThemeController>().cycleCar(1)),
            ],
          ),
        ),
        const SizedBox(height: 4),
        _carName(p, theme),
        const SizedBox(height: 4),
      ],
    );
  }

  Widget _carName(ThrotlPalette p, ThemeController theme) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 3),
      decoration: BoxDecoration(
        color: const Color(0x9E0D163A),
        border: Border.all(color: p.ink, width: 2),
        borderRadius: BorderRadius.circular(100),
      ),
      child: Text(
        '↺  ${theme.car.name.toUpperCase()}',
        style: bodyStyle(size: 9, color: p.white, weight: FontWeight.w800, letterSpacing: 0.8),
      ),
    );
  }

  /// The four gear tiles as a centred grid for the wide layout's right panel.
  Widget _gearGrid(ThrotlPalette p) {
    return Wrap(
      spacing: 14,
      runSpacing: 14,
      alignment: WrapAlignment.center,
      children: [
        GearTile(icon: Icons.bolt, label: 'ER ENGINE', color: p.yellow, onTap: widget.onPitBay),
        GearTile(
          icon: Icons.local_fire_department,
          label: 'FLASH BOOST',
          color: p.orange,
          onTap: widget.onPitBay,
        ),
        GearTile(
          icon: Icons.trip_origin,
          label: 'GRIP ±250BPS',
          color: p.cyan,
          onTap: widget.onPitBay,
        ),
        GearTile(icon: Icons.lock, label: 'NITRO · LV 8', onTap: widget.onPitBay),
      ],
    );
  }

  Widget _carStage(ThrotlPalette p, ThemeController theme, {bool fill = false}) {
    final stack = Stack(
      clipBehavior: Clip.none,
      children: [
        // the 3D car, spinning on its turntable — inset between the top and
        // bottom gear-tile rows so the car reads clearly (the tiles frame it,
        // they don't crowd it). A horizontal drag spins it; vertical scrolls.
        Positioned(
          left: 0,
          right: 0,
          top: 26,
          bottom: 34,
          child: CarTurntable(
            src: theme.car.glb,
            poster: theme.car.side,
          ),
        ),
        Positioned(
          top: 2,
          left: 0,
          child: GearTile(
            icon: Icons.bolt,
            label: 'ER ENGINE',
            color: p.yellow,
            onTap: widget.onPitBay,
          ),
        ),
        Positioned(
          top: 2,
          right: 0,
          child: GearTile(
            icon: Icons.local_fire_department,
            label: 'FLASH BOOST',
            color: p.orange,
            onTap: widget.onPitBay,
          ),
        ),
        // GRIP / NITRO dropped to the very bottom corners — clear of the car
        Positioned(
          bottom: 0,
          left: 0,
          child: GearTile(
            icon: Icons.trip_origin,
            label: 'GRIP ±250BPS',
            color: p.cyan,
            onTap: widget.onPitBay,
          ),
        ),
        Positioned(
          bottom: 0,
          right: 0,
          child: GearTile(
            icon: Icons.lock,
            label: 'NITRO · LV 8',
            onTap: widget.onPitBay,
          ),
        ),
        Positioned(
          left: 2,
          top: 0,
          bottom: 0,
          child: Center(
            child: _arrow(p, '‹', () => context.read<ThemeController>().cycleCar(-1)),
          ),
        ),
        Positioned(
          right: 2,
          top: 0,
          bottom: 0,
          child: Center(child: _arrow(p, '›', () => context.read<ThemeController>().cycleCar(1))),
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 4,
          child: Center(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 3),
              decoration: BoxDecoration(
                color: const Color(0x9E0D163A),
                border: Border.all(color: p.ink, width: 2),
                borderRadius: BorderRadius.circular(100),
              ),
              child: Text(
                '↺  ${theme.car.name.toUpperCase()}',
                style: bodyStyle(
                  size: 9,
                  color: p.white,
                  weight: FontWeight.w800,
                  letterSpacing: 0.8,
                ),
              ),
            ),
          ),
        ),
      ],
    );
    return fill ? SizedBox.expand(child: stack) : SizedBox(height: 300, child: stack);
  }

  Widget _arrow(ThrotlPalette p, String glyph, VoidCallback onTap) {
    return GestureDetector(
      onTap: () {
        sfx.swap();
        onTap();
      },
      child: Container(
        width: 38,
        height: 38,
        decoration: BoxDecoration(
          color: p.white,
          border: Border.all(color: p.ink, width: 3),
          borderRadius: BorderRadius.circular(12),
          boxShadow: hardShadow(p.ink, dy: 3),
        ),
        child: Center(
          child: Text(
            glyph,
            style: displayStyle(size: 20, color: p.ink).copyWith(shadows: const []),
          ),
        ),
      ),
    );
  }

  Widget _trackChip(ThrotlPalette p, String label, {required bool on}) {
    return GestureDetector(
      onTap: on ? null : () => _lockToast(label),
      child: Opacity(
        opacity: on ? 1 : 0.6,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
          decoration: BoxDecoration(
            color: on ? p.green : const Color(0x800D163A),
            border: Border.all(color: p.ink, width: 2.5),
            borderRadius: BorderRadius.circular(100),
            boxShadow: hardShadow(p.ink, dy: 3),
          ),
          child: Text(
            label,
            style: displayStyle(size: 10, color: p.white, letterSpacing: 0.8).copyWith(
              shadows: [Shadow(color: p.ink.withValues(alpha: 0.35), offset: const Offset(0, 1.5))],
            ),
          ),
        ),
      ),
    );
  }

  Widget _iconButton(ThrotlPalette p, IconData icon, VoidCallback onTap) {
    return GestureDetector(
      onTap: () {
        sfx.open();
        onTap();
      },
      child: Container(
        width: 38,
        height: 38,
        decoration: BoxDecoration(
          color: const Color(0x800D163A),
          border: Border.all(color: p.ink, width: 3),
          borderRadius: BorderRadius.circular(11),
          boxShadow: hardShadow(p.ink, dy: 3),
        ),
        child: Icon(icon, color: p.white, size: 20),
      ),
    );
  }

  /// The home funding entry — a chunky "+" beside the balance pill. The first-run
  /// [FundCoach] spotlights this exact button via [_fundKey].
  Widget _fundButton(ThrotlPalette p) {
    return GestureDetector(
      key: _fundKey,
      onTap: () {
        sfx.confirm();
        unawaited(showFundSheet(context));
      },
      child: Container(
        width: 38,
        height: 38,
        decoration: BoxDecoration(
          gradient: candy(p.green),
          border: Border.all(color: p.ink, width: 3),
          borderRadius: BorderRadius.circular(11),
          boxShadow: hardShadow(p.ink, dy: 3),
        ),
        child: Icon(Icons.add, color: p.white, size: 22),
      ),
    );
  }
}
