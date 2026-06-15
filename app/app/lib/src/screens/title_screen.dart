import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';
import 'package:throtl/src/engine/price_feed.dart';
import 'package:throtl/src/screens/connect_sheet.dart';
import 'package:throtl/src/theme/theme_controller.dart';
import 'package:throtl/src/theme/tokens.dart';
import 'package:throtl/src/util/responsive.dart';
import 'package:throtl/src/widgets/car_sprite.dart';
import 'package:throtl/src/widgets/chunky.dart';
import 'package:throtl/src/widgets/throtl_logo.dart';

/// 00 · Title — the attract screen (the design's `GTitleScreen`, rebranded).
class TitleScreen extends StatefulWidget {
  const TitleScreen({required this.feed, required this.onConnect, super.key});

  final PriceFeed feed;
  final VoidCallback onConnect;

  @override
  State<TitleScreen> createState() => _TitleScreenState();
}

class _TitleScreenState extends State<TitleScreen> with SingleTickerProviderStateMixin {
  static const _lines = [
    'Orders are dead. Hold the market in your hand — the chart is the track.',
    'Thumb on the throttle. Leverage is wheel speed. Release to coast flat.',
    'Stream ticks onchain at 30ms. Settle self-custodial on Flash Trade.',
  ];

  late final AnimationController _bob = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 3200),
  )..repeat(reverse: true);
  Timer? _rotate;
  int _line = 0;

  @override
  void initState() {
    super.initState();
    _rotate = Timer.periodic(const Duration(milliseconds: 3600), (_) {
      if (mounted) setState(() => _line = (_line + 1) % _lines.length);
    });
  }

  @override
  void dispose() {
    _bob.dispose();
    _rotate?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final theme = context.watch<ThemeController>();
    return GameScaffold(
      fillWidth: true,
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
      bottomBar: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 540),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: double.infinity,
                child: ChunkyButton(
                  label: 'CONNECT WALLET',
                  color: p.orange,
                  big: true,
                  sfxName: 'confirm',
                  onTap: () async {
                    final ok = await showConnectSheet(context);
                    if (ok && mounted) widget.onConnect();
                  },
                ),
              ),
              const SizedBox(height: 9),
              Text(
                'Seed Vault · Mobile Wallet Adapter',
                style: bodyStyle(size: 11, color: p.white).copyWith(
                  shadows: [Shadow(color: p.ink, offset: const Offset(0, 1.5))],
                ),
              ),
              const SizedBox(height: 12),
              Wrap(
                alignment: WrapAlignment.center,
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final c in const ['MAGICBLOCK ER', 'FLASH TRADE', 'SEEKER']) _chip(p, c),
                ],
              ),
            ],
          ),
        ),
      ),
      child: context.isWide ? _wideChild(p, theme) : _phoneChild(p, theme),
    );
  }

  /// Phone / portrait: the attract column — ticker, brand, tagline, car.
  Widget _phoneChild(ThrotlPalette p, ThemeController theme) {
    return Column(
      children: [
        _ticker(p),
        const Spacer(flex: 3),
        _logo(p),
        const SizedBox(height: 10),
        _wordmark(p),
        const SizedBox(height: 12),
        _badge(p),
        const Spacer(),
        _taglineText(p),
        const SizedBox(height: 4),
        _car(theme, height: 132),
        const Spacer(flex: 2),
      ],
    );
  }

  /// Wide (iPad landscape / desktop): the car beside the brand block — a proper
  /// landscape hero instead of one tall centred column.
  Widget _wideChild(ThrotlPalette p, ThemeController theme) {
    return Column(
      children: [
        _ticker(p),
        Expanded(
          child: Row(
            children: [
              Expanded(child: Center(child: _car(theme, height: 240))),
              Expanded(
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _logo(p),
                      const SizedBox(height: 12),
                      _wordmark(p),
                      const SizedBox(height: 14),
                      _badge(p),
                      const SizedBox(height: 22),
                      _taglineText(p),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _logo(ThrotlPalette p) {
    return AnimatedBuilder(
      animation: _bob,
      builder: (context, child) =>
          Transform.translate(offset: Offset(0, -7 * _bob.value), child: child),
      child: ThrotlLogo(size: 96, color: p.white),
    );
  }

  Widget _wordmark(ThrotlPalette p) {
    return StrokeText(
      'THROTL',
      strokeColor: p.ink,
      style: displayStyle(size: 50, color: p.white, letterSpacing: 5),
    );
  }

  Widget _badge(ThrotlPalette p) {
    return Transform.rotate(
      angle: -0.035,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
        decoration: BoxDecoration(
          color: p.yellow,
          border: Border.all(color: p.ink, width: 3),
          borderRadius: BorderRadius.circular(10),
          boxShadow: hardShadow(p.ink, dy: 4),
        ),
        child: Text(
          'THE FIRST ANALOG EXCHANGE',
          style: displayStyle(
            size: 13,
            color: p.ink,
            letterSpacing: 1.6,
          ).copyWith(shadows: const []),
        ),
      ),
    );
  }

  Widget _taglineText(ThrotlPalette p) {
    return SizedBox(
      height: 42,
      child: Center(
        child: Text(
          _lines[_line],
          key: ValueKey(_line),
          textAlign: TextAlign.center,
          style: bodyStyle(size: 14, color: p.white).copyWith(
            shadows: [Shadow(color: p.ink, offset: const Offset(0, 1.5))],
          ),
        ),
      ),
    );
  }

  Widget _car(ThemeController theme, {required double height}) {
    return CarSprite(
      asset: theme.car.asset,
      tint: theme.tint,
      height: height,
      widthFactor: 0.72,
    );
  }

  Widget _ticker(ThrotlPalette p) {
    return ListenableBuilder(
      listenable: widget.feed,
      builder: (context, _) {
        final up = widget.feed.priceE9 >= widget.feed.prevE9;
        return Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Flexible(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: _pill(
                  p,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 7,
                        height: 7,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: p.green,
                          boxShadow: [BoxShadow(color: p.green, blurRadius: 8)],
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        widget.feed.label,
                        style: displayStyle(
                          size: 10,
                          color: p.white,
                          letterSpacing: 1.2,
                        ).copyWith(shadows: const []),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Flexible(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerRight,
                child: _pill(
                  p,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'SOL-PERP ',
                        style: bodyStyle(size: 9, color: p.white, weight: FontWeight.w800),
                      ),
                      Text(
                        '\$${widget.feed.ui.toStringAsFixed(2)} ${up ? '▲' : '▼'}',
                        style: displayStyle(
                          size: 12,
                          color: up ? p.green : p.red,
                        ).copyWith(shadows: const []),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _pill(ThrotlPalette p, {required Widget child}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 4),
      decoration: BoxDecoration(
        color: const Color(0x800D163A),
        border: Border.all(color: p.ink, width: 2.5),
        borderRadius: BorderRadius.circular(100),
      ),
      child: child,
    );
  }

  Widget _chip(ThrotlPalette p, String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
      decoration: BoxDecoration(
        color: const Color(0x800D163A),
        border: Border.all(color: p.ink, width: 2.5),
        borderRadius: BorderRadius.circular(100),
      ),
      child: Text(
        label,
        style: displayStyle(size: 9, color: p.white, letterSpacing: 1).copyWith(shadows: const []),
      ),
    );
  }
}
