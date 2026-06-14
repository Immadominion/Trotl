import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:throtl/src/engine/ride_controller.dart';
import 'package:throtl/src/screens/share_overlay.dart';
import 'package:throtl/src/theme/theme_controller.dart';
import 'package:throtl/src/theme/tokens.dart';
import 'package:throtl/src/util/format.dart';
import 'package:throtl/src/widgets/chunky.dart';

/// 04 · Results — settle, real session stats, and the shareable receipt.
/// Ports the design's `GResultsScreen`.
class ResultsScreen extends StatefulWidget {
  const ResultsScreen({
    required this.stats,
    required this.onReplay,
    required this.onClaim,
    required this.onPaddock,
    this.engine,
    super.key,
  });

  final SessionStats stats;

  /// The live ride engine, so the settle card tracks the real on-chain teardown
  /// (flatten → commit → undelegate → close). Null ⇒ render the settled state.
  final RideEngine? engine;
  final VoidCallback onReplay;
  final VoidCallback onClaim;
  final VoidCallback onPaddock;

  @override
  State<ResultsScreen> createState() => _ResultsScreenState();
}

class _ResultsScreenState extends State<ResultsScreen> {
  bool _share = false;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final theme = context.watch<ThemeController>();
    final st = widget.stats;
    final win = st.realized6 >= 0;
    return Stack(
      children: [
        GameScaffold(
          background: p.paper,
          padding: const EdgeInsets.fromLTRB(18, 18, 18, 18),
          bodyScrolls: true,
          bottomBar: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ChunkyButton(
                label: win ? '📸  FLEX THIS WIN' : '📸  SHARE THE SAVE',
                color: win ? p.green : p.cyan,
                big: true,
                sfxName: 'open',
                onTap: () => setState(() => _share = true),
              ),
              const SizedBox(height: 10),
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: ChunkyButton(
                      label: 'RE-ARM',
                      color: p.purple,
                      sfxName: 'back',
                      onTap: widget.onReplay,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    flex: 2,
                    child: ChunkyButton(
                      label: 'CLAIM & GARAGE',
                      color: p.orange,
                      onTap: widget.onClaim,
                    ),
                  ),
                ],
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Transform.rotate(
                  angle: -0.035,
                  child: BannerPlate(
                    kicker: 'SESSION SETTLED',
                    title: win ? 'RACE COMPLETE!' : 'ROUGH LAP!',
                    color: win ? p.purple : p.red,
                  ),
                ),
              ),
              const SizedBox(height: 18),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const CoinIcon(size: 34),
                  const SizedBox(width: 10),
                  Text(
                    fmtMoney6(st.realized6),
                    style: displayStyle(
                      size: 46,
                      color: win ? p.greenDeep : p.redDeep,
                      shadow: const Color(0x26000000),
                      shadowDy: 3,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 2),
              Center(
                child: Text(
                  'banked this session · settled on Flash Trade',
                  style: bodyStyle(size: 12, color: p.inkSoft, weight: FontWeight.w800),
                ),
              ),
              const SizedBox(height: 18),
              _rowCard(p, 'Ticks streamed', groupInt(st.ticks)),
              const SizedBox(height: 10),
              _rowCard(p, 'Best combo', '×${st.bestStreak}', color: p.purple),
              const SizedBox(height: 10),
              _rowCard(p, 'Peak boost', '${st.peakLev.toStringAsFixed(1)}x', color: p.orangeDeep),
              const SizedBox(height: 10),
              _rowCard(p, 'Win rate', '${st.winRate}%', color: win ? p.greenDeep : p.redDeep),
              const SizedBox(height: 12),
              // The on-chain settle: for a live ride this tracks the real teardown
              // (flatten → commit → undelegate → close); practice settles instantly.
              if (widget.engine == null)
                _settleCard(p, SettlePhase.done, null, null)
              else
                ListenableBuilder(
                  listenable: widget.engine!,
                  builder: (_, _) => _settleCard(
                    p,
                    widget.engine!.settlePhase,
                    widget.engine!.settleNote,
                    widget.engine!.settleSig,
                  ),
                ),
            ],
          ),
        ),
        if (_share)
          Positioned.fill(
            child: ShareOverlay(
              win: win,
              stats: st,
              carAsset: theme.car.asset,
              tint: theme.tint,
              onClose: () => setState(() => _share = false),
            ),
          ),
      ],
    );
  }

  Widget _rowCard(ThrotlPalette p, String label, String value, {Color? color}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
      decoration: BoxDecoration(
        color: p.white,
        border: Border.all(color: p.ink, width: 3),
        borderRadius: BorderRadius.circular(14),
        boxShadow: [BoxShadow(color: p.ink, offset: const Offset(0, 4))],
      ),
      child: Row(
        children: [
          Text(
            label,
            style: bodyStyle(size: 13, color: p.inkSoft, weight: FontWeight.w800),
          ),
          const Spacer(),
          Text(
            value,
            style: displayStyle(size: 17, color: color ?? p.ink).copyWith(shadows: const []),
          ),
        ],
      ),
    );
  }

  /// The settle status pill — busy (spinner + phase), done/settled (green + real sig),
  /// or failed (red + note). Tapping a settled card opens the Paddock explorer.
  Widget _settleCard(ThrotlPalette p, SettlePhase phase, String? note, String? sig) {
    final busy = phase.isBusy || phase == SettlePhase.none;
    final ok = phase.isOk;
    final color = busy ? p.cyan : (ok ? p.green : p.red);
    final sub =
        note ??
        (sig != null
            ? 'close ${_short(sig)} · rent reclaimed to your wallet'
            : busy
            ? 'gasless on the Ephemeral Rollup · you hold the keys'
            : 'self-custodial settlement on Flash Trade');
    return GestureDetector(
      onTap: sig != null ? widget.onPaddock : null,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
        decoration: BoxDecoration(
          color: color,
          border: Border.all(color: p.ink, width: 3),
          borderRadius: BorderRadius.circular(16),
          boxShadow: [BoxShadow(color: p.ink, offset: const Offset(0, 5))],
        ),
        child: Row(
          children: [
            SizedBox(
              width: 26,
              height: 26,
              child: busy
                  ? Padding(
                      padding: const EdgeInsets.all(2),
                      child: CircularProgressIndicator(strokeWidth: 3, color: p.white),
                    )
                  : Icon(ok ? Icons.check_circle : Icons.error, color: p.white, size: 26),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    phase.label,
                    style: displayStyle(size: 13, color: p.white, letterSpacing: 0.6).copyWith(
                      shadows: [
                        Shadow(color: p.ink.withValues(alpha: 0.3), offset: const Offset(0, 2)),
                      ],
                    ),
                  ),
                  Text(
                    sub,
                    style: bodyStyle(
                      size: 10.5,
                      color: const Color(0xF2FFFFFF),
                      weight: FontWeight.w800,
                    ),
                  ),
                ],
              ),
            ),
            if (sig != null)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: p.white,
                  border: Border.all(color: p.ink, width: 2.5),
                  borderRadius: BorderRadius.circular(100),
                ),
                child: Text(
                  '↗',
                  style: displayStyle(size: 10, color: p.ink).copyWith(shadows: const []),
                ),
              ),
          ],
        ),
      ),
    );
  }

  String _short(String s) =>
      s.length <= 8 ? s : '${s.substring(0, 4)}…${s.substring(s.length - 4)}';
}
