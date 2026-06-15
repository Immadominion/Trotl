import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:throtl/src/audio/sfx.dart';
import 'package:throtl/src/theme/tokens.dart';
import 'package:throtl/src/widgets/chunky.dart';

/// First-run spotlight that lands a new player on funding. Blurs + greys the home,
/// lifts the "+" fund button into focus with a glow + arrow + "Fund account to get
/// started", and is cancellable (Skip, or tap the dimmed area). Shown once — the
/// parent owns the seen-flag and the actions.
///
/// Positions itself over the real "+" by measuring [targetKey] after layout, so it
/// stays glued to the button wherever the header puts it.
class FundCoach extends StatefulWidget {
  const FundCoach({
    required this.targetKey,
    required this.onFund,
    required this.onDismiss,
    super.key,
  });

  /// GlobalKey on the real "+" button in the header.
  final GlobalKey targetKey;

  /// Player tapped the highlighted "+" or "Fund now".
  final VoidCallback onFund;

  /// Player skipped (Skip button or tapped the dimmed background).
  final VoidCallback onDismiss;

  @override
  State<FundCoach> createState() => _FundCoachState();
}

class _FundCoachState extends State<FundCoach> {
  Rect? _target;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _measure());
  }

  void _measure() {
    final ctx = widget.targetKey.currentContext;
    final box = ctx?.findRenderObject() as RenderBox?;
    final self = context.findRenderObject() as RenderBox?;
    if (box == null || self == null || !box.attached || !self.attached) return;
    final topLeft = box.localToGlobal(Offset.zero, ancestor: self);
    if (!mounted) return;
    setState(() => _target = topLeft & box.size);
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final t = _target;
    return Material(
      type: MaterialType.transparency,
      child: Stack(
        children: [
          // Blur + grey scrim. Tapping the dimmed area cancels.
          Positioned.fill(
            child: GestureDetector(
              onTap: () {
                sfx.back();
                widget.onDismiss();
              },
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 4, sigmaY: 4),
                child: const ColoredBox(color: Color(0xB3101A33)),
              ),
            ),
          ),
          if (t != null) ..._spotlight(p, t),
          // Cancel
          Positioned(
            top: 12,
            left: 14,
            child: GestureDetector(
              onTap: () {
                sfx.back();
                widget.onDismiss();
              },
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                decoration: BoxDecoration(
                  color: const Color(0x59000000),
                  borderRadius: BorderRadius.circular(100),
                  border: Border.all(color: p.white.withValues(alpha: 0.4), width: 1.5),
                ),
                child: Text(
                  'Skip',
                  style: bodyStyle(size: 12.5, color: p.white, weight: FontWeight.w800),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _spotlight(ThrotlPalette p, Rect t) {
    return [
      // Glow ring behind the lifted "+".
      Positioned(
        left: t.left - 9,
        top: t.top - 9,
        width: t.width + 18,
        height: t.height + 18,
        child: IgnorePointer(
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              boxShadow: [BoxShadow(color: p.green, blurRadius: 28, spreadRadius: 2)],
            ),
          ),
        ),
      ),
      // A crisp, tappable copy of the "+" floating above the blur.
      Positioned(
        left: t.left,
        top: t.top,
        width: t.width,
        height: t.height,
        child: GestureDetector(
          onTap: () {
            sfx.confirm();
            widget.onFund();
          },
          child: Container(
            decoration: BoxDecoration(
              gradient: candy(p.green),
              border: Border.all(color: p.ink, width: 3),
              borderRadius: BorderRadius.circular(11),
              boxShadow: hardShadow(p.ink, dy: 3),
            ),
            child: Icon(Icons.add, color: p.white, size: 22),
          ),
        ),
      ),
      // Callout under the button: arrow + text + Fund now.
      Positioned(
        right: 14,
        top: t.bottom + 12,
        child: _callout(p, t),
      ),
    ];
  }

  Widget _callout(ThrotlPalette p, Rect t) {
    return IgnorePointer(
      ignoring: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        mainAxisSize: MainAxisSize.min,
        children: [
          // Arrow pointing up to the "+" (roughly under its centre).
          Padding(
            padding: EdgeInsets.only(right: (t.width / 2 - 8).clamp(0.0, 60.0)),
            child: Text(
              '▲',
              style: displayStyle(size: 20, color: p.green).copyWith(shadows: const []),
            ),
          ),
          Container(
            constraints: const BoxConstraints(maxWidth: 236),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: p.paper,
              border: Border.all(color: p.ink, width: 3),
              borderRadius: BorderRadius.circular(14),
              boxShadow: hardShadow(p.ink, dy: 4),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Fund account to get started',
                  style: displayStyle(size: 15, color: p.ink).copyWith(shadows: const []),
                ),
                const SizedBox(height: 5),
                Text(
                  'Add USDC fuel to ride for real money. Tap the + above — any amount '
                  r'from $11.',
                  style: bodyStyle(size: 11.5, color: shade(p.ink, 0.3)),
                ),
                const SizedBox(height: 10),
                GestureDetector(
                  onTap: () {
                    sfx.confirm();
                    widget.onFund();
                  },
                  child: Text(
                    'Fund now →',
                    style: displayStyle(size: 13, color: p.greenDeep).copyWith(shadows: const []),
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
