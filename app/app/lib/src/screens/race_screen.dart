import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';
import 'package:throtl/src/engine/ride_controller.dart';
import 'package:throtl/src/scene/hill_scene.dart';
import 'package:throtl/src/theme/theme_controller.dart';
import 'package:throtl/src/theme/tokens.dart';
import 'package:throtl/src/util/format.dart';
import 'package:throtl/src/wallet/wallet_controller.dart';
import 'package:throtl/src/widgets/chunky.dart';
import 'package:throtl/src/widgets/race_controls.dart';
import 'package:throtl/src/widgets/throttle_rail.dart';

/// 03 · Race — the centerpiece. The hill-climb scene + live gauges, all driven
/// by the real [RideController]. Ports the design's `GRaceScreen`.
class RaceScreen extends StatelessWidget {
  const RaceScreen({required this.ride, required this.onPitIn, super.key});

  final RideEngine ride;
  final ValueChanged<SessionStats> onPitIn;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final theme = context.watch<ThemeController>();
    final wallet = context.watch<WalletController>();
    // The rollup tag reflects reality: the live cluster when connected, else PRACTICE.
    final netTag = wallet.isConnected ? wallet.network.label : 'PRACTICE';
    return GameScaffold(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // header — rebuilds on ride for the live PnL pill
          ListenableBuilder(
            listenable: ride,
            builder: (context, _) {
              final s = ride.snapshot;
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Expanded(
                    child: BannerPlate(
                      kicker: 'SOL-PERP SPEEDWAY',
                      title: 'MARKET',
                    ),
                  ),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      StatPill(
                        icon: const CoinIcon(size: 18),
                        value: fmtMoney6(s.totalPnl6),
                        color: p.yellow,
                      ),
                      const SizedBox(height: 7),
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: ChunkyButton(
                          label: 'PIT IN ■',
                          color: p.purple,
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                          onTap: () => onPitIn(ride.finish()),
                        ),
                      ),
                    ],
                  ),
                ],
              );
            },
          ),
          const SizedBox(height: 10),
          // scene + throttle live OUTSIDE the ride listener: the scene drives
          // itself at 60fps and the rail manages its own state, so neither is
          // rebuilt by ride notifications — the drag is never interrupted
          Expanded(
            child: RaceControls(
              ride: ride,
              child: Stack(
                children: [
                  Positioned.fill(
                    child: HillScene(
                      ride: ride,
                      feed: ride.feed,
                      car: theme.car,
                      tint: theme.tint,
                    ),
                  ),
                  Positioned(
                    top: 12,
                    right: 8,
                    bottom: 12,
                    width: 74,
                    child: ThrottleRail(ride: ride),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 10),
          // gauges — rebuild on ride
          ListenableBuilder(
            listenable: ride,
            builder: (context, _) {
              final s = ride.snapshot;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _pnlCard(p, s),
                  const SizedBox(height: 8),
                  _ticker(p, s, netTag),
                ],
              );
            },
          ),
          const SizedBox(height: 6),
          Text(
            kIsWeb
                ? 'W/S OR ↑/↓ TO LEVER · RELEASE TO BANK · X TO SPIN OUT'
                : 'HOLD TO LEVER · RELEASE TO BANK · FLICK ↓ TO SPIN OUT',
            textAlign: TextAlign.center,
            style:
                bodyStyle(
                  size: 10.5,
                  color: const Color(0xD9FFFFFF),
                  weight: FontWeight.w800,
                  letterSpacing: 0.6,
                ).copyWith(
                  shadows: [Shadow(color: p.ink, offset: const Offset(0, 1.5))],
                ),
          ),
        ],
      ),
    );
  }

  Widget _pnlCard(ThrotlPalette p, RideSnapshot s) {
    return ChunkyCard(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'OPEN PNL',
                  style: displayStyle(
                    size: 11,
                    color: p.inkSoft,
                    letterSpacing: 1,
                  ).copyWith(shadows: const []),
                ),
                Text(
                  _fmtPnlLive(s.openPnl6),
                  style: displayStyle(
                    size: 26,
                    color: s.openPnl6 > 0
                        ? p.greenDeep
                        : s.openPnl6 < 0
                        ? p.redDeep
                        : p.ink,
                  ).copyWith(shadows: const []),
                ),
                const SizedBox(height: 2),
                // Live position line — reads the REAL snapshot, so FLAT is genuine.
                Text(
                  _positionLine(s),
                  style: bodyStyle(
                    size: 10.5,
                    color: s.position.isFlat ? shade(p.ink, 0.4) : _sideColor(p, s),
                    weight: FontWeight.w800,
                    height: 1.2,
                  ),
                ),
              ],
            ),
          ),
          Container(width: 3, height: 40, color: p.creamDim),
          const SizedBox(width: 12),
          Expanded(
            flex: 2,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'COMBO ×${s.streak}',
                      style: displayStyle(
                        size: 11,
                        color: p.inkSoft,
                        letterSpacing: 0.8,
                      ).copyWith(shadows: const []),
                    ),
                    Text(
                      '${groupInt(s.ticks)} ticks',
                      style: displayStyle(
                        size: 11,
                        color: p.inkSoft,
                        letterSpacing: 0.8,
                      ).copyWith(shadows: const []),
                    ),
                  ],
                ),
                const SizedBox(height: 5),
                ChunkyBar(
                  frac: s.levelFrac,
                  color: p.purple,
                  height: 18,
                  label: 'LV ${s.level}',
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Live open-PnL with sub-cent precision so minute real-time moves are visible —
  /// cents alone round tiny ticks to "$0.00" and look frozen. 2dp once it's ≥ $1.
  String _fmtPnlLive(int usd6) {
    final v = usd6 / 1e6;
    final sign = v > 0
        ? '+'
        : v < 0
        ? '−'
        : '';
    final dp = v.abs() < 1 ? 4 : 2;
    return '$sign\$${v.abs().toStringAsFixed(dp)}';
  }

  /// The live position descriptor under OPEN PNL — read from the REAL ride snapshot
  /// (the on-chain settled position when live, the sim when practising), so "FLAT"
  /// means genuinely no position, never a demo placeholder.
  String _positionLine(RideSnapshot s) {
    final pos = s.position;
    if (pos.isFlat) return 'FLAT · no position';
    final side = pos.side.sign > 0 ? 'LONG' : 'SHORT';
    final size = pos.sizeUsd6 / 1e6;
    final lev = s.levDisplay.abs();
    return '$side · \$${size.toStringAsFixed(2)} · ${lev.toStringAsFixed(1)}×';
  }

  Color _sideColor(ThrotlPalette p, RideSnapshot s) =>
      s.position.side.sign > 0 ? p.greenDeep : p.redDeep;

  Widget _ticker(ThrotlPalette p, RideSnapshot s, String netTag) {
    final rows = s.feed.take(3).toList();
    return ChunkyCard(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      radius: 14,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'LAP TICKER · EPHEMERAL ROLLUP',
                style: displayStyle(
                  size: 9.5,
                  color: p.inkSoft,
                  letterSpacing: 1,
                ).copyWith(shadows: const []),
              ),
              Text(
                netTag,
                style: displayStyle(
                  size: 9.5,
                  color: p.inkSoft,
                  letterSpacing: 1,
                ).copyWith(shadows: const []),
              ),
            ],
          ),
          if (rows.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                'Hold the throttle to start streaming ticks…',
                style: bodyStyle(
                  size: 11,
                  color: shade(p.ink, 0.4),
                ),
              ),
            ),
          for (final f in rows)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: f.settle
                  ? Row(
                      children: [
                        Text(
                          f.panic ? 'SPIN-OUT' : 'BANKED',
                          style: bodyStyle(
                            size: 11,
                            color: f.panic ? p.redDeep : p.purple,
                            weight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            f.sig,
                            style: bodyStyle(
                              size: 11,
                              color: p.inkSoft,
                              weight: FontWeight.w800,
                            ),
                          ),
                        ),
                        Text(
                          fmtMoney6(f.pnl6),
                          style: bodyStyle(
                            size: 11,
                            color: f.pnl6 >= 0 ? p.greenDeep : p.redDeep,
                            weight: FontWeight.w800,
                          ),
                        ),
                      ],
                    )
                  : Row(
                      children: [
                        Text(
                          '#${f.n.toString().padLeft(4, '0')}',
                          style: bodyStyle(
                            size: 11,
                            color: p.inkSoft,
                            weight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            f.sig,
                            style: bodyStyle(
                              size: 11,
                              color: p.inkSoft,
                              weight: FontWeight.w800,
                            ),
                          ),
                        ),
                        Text(
                          '${f.lev >= 0 ? '+' : ''}${f.lev.toStringAsFixed(1)}x',
                          style: bodyStyle(
                            size: 11,
                            color: f.lev >= 0 ? p.greenDeep : p.redDeep,
                            weight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          '${f.ms}ms',
                          style: bodyStyle(
                            size: 11,
                            color: shade(p.ink, 0.4),
                          ),
                        ),
                      ],
                    ),
            ),
        ],
      ),
    );
  }
}
