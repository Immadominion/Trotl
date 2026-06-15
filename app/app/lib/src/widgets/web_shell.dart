import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:throtl/src/theme/tokens.dart';
import 'package:throtl/src/util/open_url.dart';
import 'package:throtl/src/widgets/chunky.dart';
import 'package:throtl/src/widgets/throtl_logo.dart';

const _apkUrl =
    'https://github.com/Immadominion/Trotl/releases/latest/download/throtl-hackathon-build.apk';
const _demoUrl = 'https://youtu.be/9TNQ2p8RQZk';
const _repoUrl = 'https://github.com/Immadominion/Trotl';

/// The WEB presentation shell. The cockpit is a hand-tuned PORTRAIT game, so on
/// the web we don't reflow it — we present it like a web-native product:
///   • wide screens → a two-pane "cabinet": a branded hero beside the live game,
///     which fills the full height (no tiny phone in a black void).
///   • narrow / phone-web → the game frameless, filling the whole viewport.
///   • off the web → passthrough (mobile is already full-bleed).
/// The game is given its device size via a [MediaQuery] override + [FittedBox] so
/// it scales crisply without ever clipping, and its gamification is preserved.
class WebShell extends StatelessWidget {
  const WebShell({required this.child, super.key});

  final Widget child;

  // Logical portrait device the cockpit is designed against.
  static const double _w = 402;
  static const double _h = 874;

  @override
  Widget build(BuildContext context) {
    if (!kIsWeb) return child;
    return LayoutBuilder(
      builder: (context, c) {
        final wide = c.maxWidth >= 920;
        final game = _GamePane(child: child);
        const bg = BoxDecoration(
          gradient: RadialGradient(
            center: Alignment(-0.1, -0.4),
            radius: 1.3,
            colors: [Color(0xFF16224F), Color(0xFF0B1130), Color(0xFF070B22)],
            stops: [0, 0.6, 1],
          ),
        );
        if (!wide) {
          return DecoratedBox(decoration: bg, child: Center(child: game));
        }
        return DecoratedBox(
          decoration: bg,
          child: Row(
            children: [
              const Expanded(flex: 6, child: _HeroPanel()),
              Expanded(flex: 5, child: game),
            ],
          ),
        );
      },
    );
  }
}

/// The game, given its device size and scaled to fill its pane (never clipped).
class _GamePane extends StatelessWidget {
  const _GamePane({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    return Padding(
      padding: const EdgeInsets.all(18),
      child: FittedBox(
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(38),
            boxShadow: const [
              BoxShadow(color: Color(0x88000000), blurRadius: 44, spreadRadius: 4),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(38),
            child: SizedBox(
              width: WebShell._w,
              height: WebShell._h,
              child: MediaQuery(
                data: media.copyWith(
                  size: const Size(WebShell._w, WebShell._h),
                  padding: EdgeInsets.zero,
                  viewPadding: EdgeInsets.zero,
                  viewInsets: EdgeInsets.zero,
                ),
                child: child,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The branded left pane on wide screens — what Throtl is + how to get it.
class _HeroPanel extends StatelessWidget {
  const _HeroPanel();

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Material(
      type: MaterialType.transparency,
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 56, vertical: 40),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    ThrotlLogo(size: 64, color: p.yellow),
                    const SizedBox(width: 14),
                    Text(
                      'THROTL',
                      style: displayStyle(size: 40, color: p.white, letterSpacing: 3)
                          .copyWith(shadows: const []),
                    ),
                  ],
                ),
                const SizedBox(height: 22),
                Text(
                  'The first analog exchange.',
                  style: displayStyle(size: 34, color: p.yellow)
                      .copyWith(shadows: const [], height: 1.05),
                ),
                const SizedBox(height: 14),
                Text(
                  'Hold the market in your hand. Your live exposure follows your finger '
                  'at ~30 ms on a MagicBlock Ephemeral Rollup, mirrored into real, '
                  'self-custodied Flash Trade positions. Race the chart — and the trade '
                  'is real.',
                  style: bodyStyle(size: 15.5, color: const Color(0xDDE6ECFF), height: 1.5),
                ),
                const SizedBox(height: 18),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _chip(p, 'MAINNET'),
                    _chip(p, 'SELF-CUSTODIAL'),
                    _chip(p, 'GASLESS ER TICKS'),
                  ],
                ),
                const SizedBox(height: 26),
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    ChunkyButton(
                      label: 'GET THE ANDROID APP',
                      color: p.orange,
                      big: true,
                      onTap: () => openUrl(_apkUrl),
                    ),
                    ChunkyButton(
                      label: 'WATCH THE DEMO',
                      color: p.purple,
                      onTap: () => openUrl(_demoUrl),
                    ),
                    ChunkyButton(
                      label: 'GITHUB',
                      color: p.blueDeep,
                      onTap: () => openUrl(_repoUrl),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                Text(
                  'Play right here → connect a browser wallet to go live, or ride in '
                  'practice with no wallet.',
                  style: bodyStyle(size: 13, color: const Color(0x99CCD6FF)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _chip(ThrotlPalette p, String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: const Color(0x1AFFFFFF),
        borderRadius: BorderRadius.circular(100),
        border: Border.all(color: const Color(0x33FFFFFF), width: 1.5),
      ),
      child: Text(
        label,
        style: displayStyle(size: 11, color: p.white, letterSpacing: 1)
            .copyWith(shadows: const []),
      ),
    );
  }
}
