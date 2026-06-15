import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:throtl/src/audio/sfx.dart';
import 'package:throtl/src/theme/theme_controller.dart';
import 'package:throtl/src/theme/tokens.dart';
import 'package:throtl/src/widgets/chunky.dart';

/// First-launch intro — top hero panel + a bottom sheet that rounds over the top
/// (the inverted-aura layout), in our chunky design. Three crossfading pages, then
/// "Get Started". Shown once; [onFinish] flips the seen-flag and enters the app.
///
/// Copy here is PLACEHOLDER — edit `_kickers` / `_heads` / `_bodies` to taste.
class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({required this.onFinish, super.key});

  final VoidCallback onFinish;

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  int _i = 0;
  static const _n = 3;

  static const _kickers = ['REAL MONEY · YOUR KEYS', 'TRADE BY RACING', 'WIN OR PIT OUT'];
  static const _heads = ['Drive the\nmarket.', 'Throttle is\nyour leverage.', 'Cash out\nanytime.'];
  static const _bodies = [
    'Throtl turns live SOL-perp price action into a hill-climb race on a MagicBlock ephemeral rollup. Your wallet, your funds — self-custodial the whole way.',
    'Lever up to go long, down to short. The road pitches with the market: bank your gains by easing off, or flick down to spin out before a loss runs.',
    'Fuel up with USDC, ride for real, and withdraw to your wallet whenever you want. Throtl never holds your funds.',
  ];
  static const List<IconData> _icons = [Icons.show_chart, Icons.speed, Icons.savings];

  void _next() {
    if (_i < _n - 1) {
      sfx.swap();
      setState(() => _i++);
    } else {
      sfx.confirm();
      widget.onFinish();
    }
  }

  void _skip() {
    sfx.back();
    widget.onFinish();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final theme = context.watch<ThemeController>();
    final accents = [p.orange, p.green, p.cyan];
    final accent = accents[_i];
    return Material(
      type: MaterialType.transparency,
      child: ColoredBox(
        color: p.ink,
        child: SafeArea(
          bottom: false,
          child: Column(
            children: [
              // ── TOP HERO ──
              Expanded(
                flex: 58,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 350),
                  width: double.infinity,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [shade(accent, 0.18), shade(accent, -0.28)],
                    ),
                  ),
                  child: Center(
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 350),
                      switchInCurve: Curves.easeOutCubic,
                      child: _hero(p, accent, theme),
                    ),
                  ),
                ),
              ),
              // ── BOTTOM SHEET (rounds over the hero) ──
              Expanded(
                flex: 54,
                child: Transform.translate(
                  offset: const Offset(0, -26),
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.fromLTRB(26, 28, 26, 18),
                    decoration: BoxDecoration(
                      color: p.paper,
                      borderRadius: const BorderRadius.vertical(top: Radius.circular(30)),
                      border: Border.all(color: p.ink, width: 3),
                      boxShadow: hardShadow(p.ink, dy: 6),
                    ),
                    child: Column(
                      children: [
                        Expanded(
                          child: AnimatedSwitcher(
                            duration: const Duration(milliseconds: 320),
                            switchInCurve: Curves.easeOutCubic,
                            child: Column(
                              key: ValueKey(_i),
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Text(
                                  _kickers[_i],
                                  style: displayStyle(
                                    size: 11,
                                    color: accent,
                                    letterSpacing: 1.2,
                                  ).copyWith(shadows: const []),
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  _heads[_i],
                                  style: displayStyle(
                                    size: 30,
                                    color: p.ink,
                                  ).copyWith(shadows: const []),
                                ),
                                const SizedBox(height: 12),
                                Text(
                                  _bodies[_i],
                                  style: bodyStyle(
                                    size: 13.5,
                                    color: shade(p.ink, 0.25),
                                    height: 1.5,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        _controls(p, accent),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _hero(ThrotlPalette p, Color accent, ThemeController theme) {
    // "Drive the market" shows the player's actual car; the others a themed badge.
    if (_i == 0) {
      return Padding(
        key: const ValueKey('car'),
        padding: const EdgeInsets.symmetric(horizontal: 30),
        child: Image.asset(theme.car.side, fit: BoxFit.contain),
      );
    }
    return Container(
      key: ValueKey(_i),
      width: 150,
      height: 150,
      decoration: BoxDecoration(
        color: p.white,
        shape: BoxShape.circle,
        border: Border.all(color: p.ink, width: 4),
        boxShadow: hardShadow(p.ink, dy: 7),
      ),
      child: Icon(_icons[_i], size: 74, color: accent),
    );
  }

  Widget _controls(ThrotlPalette p, Color accent) {
    if (_i == _n - 1) {
      return ChunkyButton(
        label: 'GET STARTED',
        color: accent,
        big: true,
        sfxName: 'confirm',
        onTap: _next,
      );
    }
    return Row(
      children: [
        SizedBox(
          width: 56,
          child: GestureDetector(
            onTap: _skip,
            child: Text(
              'Skip',
              style: bodyStyle(size: 13, color: shade(p.ink, 0.4), weight: FontWeight.w800),
            ),
          ),
        ),
        Expanded(
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: List.generate(_n, (j) {
              final on = j == _i;
              return AnimatedContainer(
                duration: const Duration(milliseconds: 220),
                margin: const EdgeInsets.symmetric(horizontal: 3),
                width: on ? 22 : 8,
                height: 8,
                decoration: BoxDecoration(
                  color: on ? accent : p.creamDim,
                  borderRadius: BorderRadius.circular(100),
                  border: Border.all(color: p.ink, width: 1.5),
                ),
              );
            }),
          ),
        ),
        SizedBox(
          width: 56,
          child: Align(
            alignment: Alignment.centerRight,
            child: GestureDetector(
              onTap: _next,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                decoration: BoxDecoration(
                  gradient: candy(accent),
                  border: Border.all(color: p.ink, width: 3),
                  borderRadius: BorderRadius.circular(12),
                  boxShadow: hardShadow(p.ink, dy: 3),
                ),
                child: Text(
                  '›',
                  style: displayStyle(size: 18, color: p.white).copyWith(shadows: const []),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
