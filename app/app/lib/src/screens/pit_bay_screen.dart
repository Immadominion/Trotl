import 'package:flutter/material.dart';
import 'package:throtl/src/audio/sfx.dart';
import 'package:throtl/src/theme/tokens.dart';
import 'package:throtl/src/util/responsive.dart';
import 'package:throtl/src/widgets/chunky.dart';

/// The "Pit Bay" — gear cards that honestly map to real protocol parts.
///
/// Ports the design's `GGearScreen`: an ER engine (the ephemeral rollup), a
/// tunable grip band (hysteresis ±bps), the Flash settlement boost, and a
/// locked cosmetic. Nothing here changes the odds — the honesty note says so.
class PitBayScreen extends StatelessWidget {
  const PitBayScreen({
    required this.gripBandBps,
    required this.onGrip,
    required this.onBack,
    required this.onRace,
    super.key,
  });

  final int gripBandBps;
  final ValueChanged<int> onGrip;
  final VoidCallback onBack;
  final VoidCallback onRace;

  /// The selectable hysteresis bands, in basis points.
  static const List<int> _bands = [100, 250, 500];

  String _gripDesc(int bps) {
    final tail = switch (bps) {
      100 => 'tightest tracking, most settlement txs.',
      250 => 'balanced tracking vs. settlement cost.',
      _ => 'loosest tracking, fewest settlement txs.',
    };
    return 'Hysteresis band ±$bps bps — $tail';
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final erEngine = _GearCard(
      icon: Icons.bolt,
      accent: p.cyan,
      name: 'ER ENGINE',
      description:
          'MagicBlock ephemeral rollup — streams your exposure '
          'onchain every 30–50ms, gasless. This is the car’s engine. '
          'Cannot be unequipped.',
      chip: 'EQUIPPED',
      chipColor: p.green,
    );
    final gripCard = _GripCard(
      bands: _bands,
      selectedBps: gripBandBps,
      onGrip: onGrip,
      description: _gripDesc(gripBandBps),
    );
    final flashBoost = _GearCard(
      icon: Icons.local_fire_department,
      accent: p.orange,
      name: 'FLASH BOOST',
      description:
          'Settlement venue: Flash Trade. Builder-code rebates flow '
          'back to you as coins at the finish line.',
      chip: 'EQUIPPED',
      chipColor: p.green,
    );
    final nitro = _GearCard(
      icon: Icons.lock,
      accent: p.cyan,
      name: 'NITRO TRAIL',
      description:
          'Cosmetic exhaust burst for your spin-outs and wins. Earned, '
          'never bought — unlocks at Pilot LV 8.',
      chip: 'LOCKED · LV 8',
      chipColor: const Color(0xFF5A6072),
      locked: true,
    );
    final honesty = ChunkyCard(
      color: const Color(0xFFFFF1D6),
      child: Text(
        'Gear never changes your odds — skill and the market do. '
        'Upgrades are protocol settings and cosmetics, not pay-to-win.',
        style: bodyStyle(
          size: 11.5,
          color: shade(p.ink, 0.2),
          weight: FontWeight.w800,
          height: 1.5,
        ),
      ),
    );

    return GameScaffold(
      fillWidth: true,
      bodyScrolls: !context.isWide,
      bottomBar: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 600),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                flex: 10,
                child: ChunkyButton(
                  label: 'BACK TO GARAGE',
                  color: p.purple,
                  onTap: onBack,
                  sfxName: 'back',
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                flex: 14,
                child: ChunkyButton(
                  label: 'START RACE',
                  color: p.orange,
                  big: true,
                  onTap: onRace,
                ),
              ),
            ],
          ),
        ),
      ),
      child: context.isWide
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _header(p),
                const SizedBox(height: 11),
                Expanded(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: SingleChildScrollView(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              erEngine,
                              const SizedBox(height: 11),
                              gripCard,
                              const SizedBox(height: 11),
                              honesty,
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(width: 20),
                      Expanded(
                        child: SingleChildScrollView(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              flashBoost,
                              const SizedBox(height: 11),
                              nitro,
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _header(p),
                const SizedBox(height: 11),
                erEngine,
                const SizedBox(height: 11),
                gripCard,
                const SizedBox(height: 11),
                flashBoost,
                const SizedBox(height: 11),
                nitro,
                const SizedBox(height: 11),
                honesty,
              ],
            ),
    );
  }

  Widget _header(ThrotlPalette p) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.only(top: 10),
          child: BannerPlate(kicker: 'PIT BAY', title: 'GEAR'),
        ),
        const Spacer(),
        Padding(
          padding: const EdgeInsets.only(top: 14),
          child: StatPill(icon: const CoinIcon(size: 18), value: '1,204', color: p.yellow),
        ),
      ],
    );
  }
}

/// A small skewed-pill status chip (the design's gear chip).
class _GearChip extends StatelessWidget {
  const _GearChip({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 2),
      decoration: BoxDecoration(
        color: color,
        border: Border.all(color: p.ink, width: 2),
        borderRadius: BorderRadius.circular(100),
      ),
      child: Text(
        label,
        style: displayStyle(
          size: 8.5,
          color: p.white,
          shadow: const Color(0x4D000000),
          letterSpacing: 0.6,
          shadowDy: 1,
        ),
      ),
    );
  }
}

/// The gear name title — chunky display ink text with no drop shadow.
TextStyle _nameStyle(BuildContext context) => displayStyle(
  size: 14,
  color: context.palette.ink,
  letterSpacing: 0.6,
).copyWith(shadows: const []);

/// A static gear card: tile glyph + name/chip + a description line.
class _GearCard extends StatelessWidget {
  const _GearCard({
    required this.icon,
    required this.accent,
    required this.name,
    required this.description,
    required this.chip,
    required this.chipColor,
    this.locked = false,
  });

  final IconData icon;
  final Color accent;
  final String name;
  final String description;
  final String chip;
  final Color chipColor;
  final bool locked;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Opacity(
      opacity: locked ? 0.82 : 1,
      child: ChunkyCard(
        child: Row(
          children: [
            GearTile(icon: icon, color: accent, size: 54),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(name, style: _nameStyle(context)),
                      ),
                      _GearChip(label: chip, color: chipColor),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    description,
                    style: bodyStyle(
                      size: 11,
                      color: shade(p.ink, 0.32),
                      height: 1.45,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The tunable grip card: ±100 / ±250 / ±500 bps band chips report via [onGrip].
class _GripCard extends StatelessWidget {
  const _GripCard({
    required this.bands,
    required this.selectedBps,
    required this.onGrip,
    required this.description,
  });

  final List<int> bands;
  final int selectedBps;
  final ValueChanged<int> onGrip;
  final String description;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return ChunkyCard(
      child: Row(
        children: [
          GearTile(icon: Icons.trip_origin, color: p.cyan, size: 54),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text('GRIP TIRES', style: _nameStyle(context)),
                    ),
                    for (final bps in bands) ...[
                      _BandChip(
                        label: '±$bps',
                        selected: selectedBps == bps,
                        onTap: () {
                          sfx.select();
                          onGrip(bps);
                        },
                      ),
                      if (bps != bands.last) const SizedBox(width: 5),
                    ],
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  description,
                  style: bodyStyle(
                    size: 11,
                    color: shade(p.ink, 0.32),
                    height: 1.45,
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

/// One selectable grip-band chip.
class _BandChip extends StatelessWidget {
  const _BandChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
        decoration: BoxDecoration(
          color: selected ? p.cyan : p.white,
          border: Border.all(color: p.ink, width: 2),
          borderRadius: BorderRadius.circular(100),
        ),
        child: Text(
          label,
          style: selected
              ? displayStyle(
                  size: 9.5,
                  color: p.white,
                  shadow: const Color(0x4D000000),
                  letterSpacing: 0,
                  shadowDy: 1,
                )
              : displayStyle(
                  size: 9.5,
                  color: p.inkSoft,
                  letterSpacing: 0,
                ).copyWith(shadows: const []),
        ),
      ),
    );
  }
}
