import 'package:flutter/widgets.dart';
import 'package:throtl/src/theme/tokens.dart';
import 'package:throtl/src/widgets/chunky.dart';

/// One pilot row in the season leaderboard.
@immutable
class _Pilot {
  const _Pilot(this.rank, this.name, this.streak, this.pnl);

  final int rank;
  final String name;
  final int streak;
  final String pnl;
}

const List<_Pilot> _rows = [
  _Pilot(1, 'vroomVWAP', 23, r'+$4,812'),
  _Pilot(2, '0xSenna', 19, r'+$3,977'),
  _Pilot(3, 'lev_lap', 31, r'+$3,140'),
  _Pilot(4, 'tickmaestro', 12, r'+$2,605'),
  _Pilot(5, 'shortstack.sol', 17, r'+$2,212'),
];

/// The Season leaderboard screen — ranked pilots by realized PnL per $ staked,
/// the player's own rank card, and a CTA to climb. Mirrors the design's
/// `GSeasonScreen`.
class SeasonScreen extends StatelessWidget {
  const SeasonScreen({required this.onBack, required this.onRace, super.key});

  final VoidCallback onBack;
  final VoidCallback onRace;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return GameScaffold(
      bodyScrolls: true,
      bottomBar: Row(
        children: [
          Expanded(
            flex: 2,
            child: ChunkyButton(
              label: 'BACK',
              color: p.purple,
              onTap: onBack,
              sfxName: 'back',
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            flex: 3,
            child: ChunkyButton(
              label: 'CLIMB · START RACE',
              color: p.orange,
              onTap: onRace,
              big: true,
            ),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: BannerPlate(
                  kicker: 'SEASON 1 · 12 DAYS LEFT',
                  title: 'LEADERBOARD',
                  color: p.purple,
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(top: 14),
                child: StatPill(
                  icon: const CoinIcon(size: 18),
                  value: '1,204',
                  color: p.yellow,
                ),
              ),
            ],
          ),
          const SizedBox(height: 11),
          _YourRankCard(palette: p),
          const SizedBox(height: 11),
          for (final pilot in _rows) ...[
            _PilotRow(pilot: pilot, palette: p),
            if (pilot != _rows.last) const SizedBox(height: 8),
          ],
          const SizedBox(height: 11),
          ChunkyCard(
            color: const Color(0xFFFFF1D6),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: Text(
              r'Ranked by realized PnL per $ staked — not size. '
              'Top 100 pilots split the season SKR pool.',
              style: bodyStyle(
                size: 11.5,
                color: shade(p.ink, 0.2),
                weight: FontWeight.w800,
                height: 1.5,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The player's own purple gradient rank card.
class _YourRankCard extends StatelessWidget {
  const _YourRankCard({required this.palette});

  final ThrotlPalette palette;

  @override
  Widget build(BuildContext context) {
    final p = palette;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        gradient: candy(p.purple, lighten: 0.25, mid: 0.7),
        border: Border.all(color: p.ink, width: 3),
        borderRadius: BorderRadius.circular(18),
        boxShadow: hardShadow(p.ink),
      ),
      child: Row(
        children: [
          Text(
            '#42',
            style: displayStyle(size: 30, color: p.white, shadowDy: 3),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'YOU · PILOT LV 4',
                  style: displayStyle(size: 14, color: p.white, shadowDy: 2),
                ),
                const SizedBox(height: 5),
                ChunkyBar(
                  frac: 0.62,
                  color: p.green,
                  height: 14,
                  label: '248/400 XP',
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                r'+$214',
                style: displayStyle(size: 16, color: p.white, shadowDy: 2),
              ),
              Text(
                'BEST COMBO ×9',
                style: bodyStyle(
                  size: 9.5,
                  color: const Color(0xD9FFFFFF),
                  weight: FontWeight.w800,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// A single cream leaderboard row with a colored rank badge.
class _PilotRow extends StatelessWidget {
  const _PilotRow({required this.pilot, required this.palette});

  final _Pilot pilot;
  final ThrotlPalette palette;

  @override
  Widget build(BuildContext context) {
    final p = palette;
    final badge = switch (pilot.rank) {
      1 => p.yellow,
      2 => const Color(0xFFD7DCE6),
      3 => const Color(0xFFE8A04C),
      _ => p.creamDim,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
      decoration: BoxDecoration(
        color: p.cream,
        border: Border.all(color: p.ink, width: 3),
        borderRadius: BorderRadius.circular(14),
        boxShadow: hardShadow(p.ink, dy: 4),
      ),
      child: Row(
        children: [
          Container(
            width: 30,
            height: 30,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: badge,
              border: Border.all(color: p.ink, width: 2.5),
              borderRadius: BorderRadius.circular(9),
            ),
            child: Text(
              '${pilot.rank}',
              style: displayStyle(size: 14, color: p.ink, shadowDy: 0),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              pilot.name,
              style: displayStyle(size: 14, color: p.ink, shadowDy: 0),
            ),
          ),
          const SizedBox(width: 12),
          Text(
            '×${pilot.streak}',
            style: bodyStyle(
              size: 11,
              color: p.inkSoft,
              weight: FontWeight.w800,
            ),
          ),
          const SizedBox(width: 12),
          SizedBox(
            width: 74,
            child: Text(
              pilot.pnl,
              textAlign: TextAlign.right,
              style: displayStyle(size: 14, color: p.greenDeep, shadowDy: 0),
            ),
          ),
        ],
      ),
    );
  }
}
