import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:throtl/src/audio/sfx.dart';
import 'package:throtl/src/theme/theme_controller.dart';
import 'package:throtl/src/theme/tokens.dart';

/// Read the active brand palette (rebuilds on theme change).
extension PaletteX on BuildContext {
  ThrotlPalette get palette => watch<ThemeController>().palette;
}

/// Lilita One display text style with a hard cartoon drop-shadow.
TextStyle displayStyle({
  required double size,
  required Color color,
  Color shadow = const Color(0x66000000),
  double letterSpacing = 0.5,
  double shadowDy = 2.5,
}) {
  return TextStyle(
    fontFamily: kFontDisplay,
    fontSize: size,
    color: color,
    height: 1,
    letterSpacing: letterSpacing,
    shadows: [Shadow(color: shadow, offset: Offset(0, shadowDy))],
  );
}

/// Baloo 2 body style.
TextStyle bodyStyle({
  required double size,
  required Color color,
  FontWeight weight = FontWeight.w700,
  double letterSpacing = 0,
  double height = 1.4,
}) {
  return TextStyle(
    fontFamily: kFontBody,
    fontSize: size,
    color: color,
    fontWeight: weight,
    letterSpacing: letterSpacing,
    height: height,
  );
}

/// Outlined display text (ink stroke under a fill) — the chunky wordmark look.
class StrokeText extends StatelessWidget {
  const StrokeText(
    this.text, {
    required this.style,
    this.strokeColor,
    this.strokeWidth = 1,
    this.textAlign,
    super.key,
  });

  final String text;
  final TextStyle style;
  final Color? strokeColor;
  final double strokeWidth;
  final TextAlign? textAlign;

  @override
  Widget build(BuildContext context) {
    if (strokeColor == null) {
      return Text(text, style: style, textAlign: textAlign);
    }
    // A style with `foreground` set must not also set `color`, so build the
    // stroke layer explicitly rather than via copyWith (which can't clear color).
    final strokeFill = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeJoin = StrokeJoin.round
      ..color = strokeColor!;
    return Stack(
      children: [
        Text(
          text,
          textAlign: textAlign,
          style: TextStyle(
            fontFamily: style.fontFamily,
            fontSize: style.fontSize,
            height: style.height,
            letterSpacing: style.letterSpacing,
            fontWeight: style.fontWeight,
            shadows: style.shadows,
            foreground: strokeFill,
          ),
        ),
        Text(
          text,
          style: style.copyWith(shadows: const []),
          textAlign: textAlign,
        ),
      ],
    );
  }
}

/// Hard cartoon shadow `0 dy 0 ink` (zero-blur, solid).
List<BoxShadow> hardShadow(Color ink, {double dy = 5}) => [
  BoxShadow(color: ink, offset: Offset(0, dy)),
];

/// The bevel "3D block" under a candy button: `0 dy 0 darker, 0 dy 0 spread ink`.
List<BoxShadow> bevelShadow(Color base, Color ink, {double dy = 5}) => [
  BoxShadow(color: ink, offset: Offset(0, dy), spreadRadius: 3),
  BoxShadow(color: shade(base, -0.45), offset: Offset(0, dy)),
];

/// Top-lighter → base candy gradient.
LinearGradient candy(Color base, {double lighten = 0.35, double mid = 0.55}) {
  return LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [shade(base, lighten), base],
    stops: [0, mid],
  );
}

/// Chunky bevel button (the design's `GBtn`). Presses down onto its shadow.
class ChunkyButton extends StatefulWidget {
  const ChunkyButton({
    required this.label,
    required this.color,
    this.onTap,
    this.big = false,
    this.sfxName = 'click',
    this.padding,
    super.key,
  });

  final String label;
  final Color color;
  final VoidCallback? onTap;
  final bool big;
  final String sfxName;
  final EdgeInsets? padding;

  @override
  State<ChunkyButton> createState() => _ChunkyButtonState();
}

class _ChunkyButtonState extends State<ChunkyButton> {
  bool _down = false;

  void _set({required bool down}) => setState(() => _down = down);

  @override
  Widget build(BuildContext context) {
    final ink = context.palette.ink;
    final disabled = widget.onTap == null;
    final bevel = widget.big ? 6.0 : 5.0;
    final dy = _down ? 2.0 : bevel;
    return Opacity(
      opacity: disabled ? 0.55 : 1,
      child: GestureDetector(
        onTapDown: disabled ? null : (_) => _set(down: true),
        onTapCancel: disabled ? null : () => _set(down: false),
        onTapUp: disabled
            ? null
            : (_) {
                _set(down: false);
                sfx.byName(widget.sfxName);
                widget.onTap?.call();
              },
        child: Transform.translate(
          offset: Offset(0, bevel - dy),
          child: Container(
            padding:
                widget.padding ??
                (widget.big
                    ? const EdgeInsets.symmetric(horizontal: 18, vertical: 14)
                    : const EdgeInsets.symmetric(horizontal: 14, vertical: 10)),
            decoration: BoxDecoration(
              gradient: candy(widget.color),
              border: Border.all(color: ink, width: 3),
              borderRadius: BorderRadius.circular(widget.big ? 18 : 14),
              boxShadow: bevelShadow(widget.color, ink, dy: dy),
            ),
            child: Center(
              // scale-to-fit so short labels never wrap on narrow buttons
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: StrokeText(
                  widget.label,
                  textAlign: TextAlign.center,
                  strokeColor: ink,
                  style: displayStyle(
                    size: widget.big ? 21 : 15,
                    color: context.palette.white,
                    shadow: const Color(0x59000000),
                    shadowDy: 2,
                    letterSpacing: 0.6,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Cream card with ink outline + hard shadow (the design's `GCard`).
class ChunkyCard extends StatelessWidget {
  const ChunkyCard({
    required this.child,
    this.color,
    this.padding = const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
    this.radius = 18,
    super.key,
  });

  final Widget child;
  final Color? color;
  final EdgeInsets padding;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: color ?? p.cream,
        border: Border.all(color: p.ink, width: 3),
        borderRadius: BorderRadius.circular(radius),
        boxShadow: hardShadow(p.ink),
      ),
      child: child,
    );
  }
}

/// Skewed banner plate with optional kicker (the design's `GPlate`).
class BannerPlate extends StatelessWidget {
  const BannerPlate({
    required this.title,
    this.kicker,
    this.color,
    super.key,
  });

  final String title;
  final String? kicker;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final base = color ?? p.orange;
    final plate = Transform(
      transform: Matrix4.skewX(-0.14),
      child: Container(
        padding: const EdgeInsets.fromLTRB(22, 7, 22, 6),
        decoration: BoxDecoration(
          gradient: candy(base, lighten: 0.4, mid: 0.6),
          border: Border.all(color: p.ink, width: 3),
          borderRadius: BorderRadius.circular(12),
          boxShadow: hardShadow(p.ink, dy: 4),
        ),
        child: Transform(
          transform: Matrix4.skewX(0.14),
          child: StrokeText(
            title,
            strokeColor: p.ink,
            style: displayStyle(size: 24, color: p.white, letterSpacing: 1.9),
          ),
        ),
      ),
    );
    if (kicker == null) return plate;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Padding(padding: const EdgeInsets.only(top: 10), child: plate),
        Positioned(
          top: -4,
          left: 18,
          child: Transform(
            transform: Matrix4.skewX(-0.14),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
              decoration: BoxDecoration(
                color: p.ink,
                borderRadius: BorderRadius.circular(7),
                border: Border.all(color: p.ink, width: 2),
              ),
              child: Text(
                kicker!,
                style: displayStyle(
                  size: 12,
                  color: p.white,
                  letterSpacing: 1.2,
                ).copyWith(shadows: const []),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Gear tile: dark inset square with an accent glyph (the design's `GTile`).
class GearTile extends StatelessWidget {
  const GearTile({
    required this.icon,
    this.label,
    this.color,
    this.size = 64,
    this.onTap,
    super.key,
  });

  final IconData icon;
  final String? label;
  final Color? color;
  final double size;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final accent = color ?? p.cyan;
    final tile = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: const Color(0x8C0D163A),
        border: Border.all(color: p.ink, width: 3),
        borderRadius: BorderRadius.circular(16),
        boxShadow: hardShadow(p.ink, dy: 3),
      ),
      child: Icon(icon, color: accent, size: size * 0.42),
    );
    return GestureDetector(
      onTap: onTap == null
          ? null
          : () {
              sfx.open();
              onTap!.call();
            },
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          tile,
          if (label != null) ...[
            const SizedBox(height: 4),
            Text(
              label!,
              style: bodyStyle(size: 9, color: p.white, weight: FontWeight.w800, letterSpacing: 0.7)
                  .copyWith(
                    shadows: [Shadow(color: p.ink, offset: const Offset(0, 1.5))],
                  ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Stat pill: a hex icon chip joined to a dark value bar (the design's `GPill`).
class StatPill extends StatelessWidget {
  const StatPill({
    required this.icon,
    required this.value,
    this.color,
    super.key,
  });

  final Widget icon;
  final String value;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final accent = color ?? p.cyan;
    // The dark value bar tucks BEHIND the icon chip's right edge; the icon is
    // drawn last so it's always fully visible (never covered by the pill).
    return Stack(
      alignment: Alignment.centerLeft,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 24),
          child: Container(
            constraints: const BoxConstraints(minWidth: 56),
            padding: const EdgeInsets.fromLTRB(18, 4, 13, 4),
            decoration: BoxDecoration(
              color: const Color(0x990D163A),
              border: Border.all(color: p.ink, width: 2.5),
              borderRadius: BorderRadius.circular(100),
            ),
            child: Text(
              value,
              textAlign: TextAlign.center,
              style: displayStyle(size: 15, color: p.white, shadowDy: 1.5),
            ),
          ),
        ),
        Container(
          width: 34,
          height: 34,
          decoration: BoxDecoration(
            gradient: candy(accent, lighten: 0.3, mid: 1),
            border: Border.all(color: p.ink, width: 2.5),
            borderRadius: BorderRadius.circular(10),
            boxShadow: hardShadow(p.ink, dy: 2.5),
          ),
          child: Center(child: icon),
        ),
      ],
    );
  }
}

/// Progress bar (XP / boost) — the design's `GBar`.
class ChunkyBar extends StatelessWidget {
  const ChunkyBar({
    required this.frac,
    this.color,
    this.height = 16,
    this.label,
    super.key,
  });

  final double frac;
  final Color? color;
  final double height;
  final String? label;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final fill = color ?? p.green;
    return Container(
      height: height,
      decoration: BoxDecoration(
        color: const Color(0x990D163A),
        border: Border.all(color: p.ink, width: 2.5),
        borderRadius: BorderRadius.circular(100),
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [
          FractionallySizedBox(
            widthFactor: frac.clamp(0.0, 1.0),
            child: DecoratedBox(
              decoration: BoxDecoration(gradient: candy(fill, lighten: 0.45, mid: 0.6)),
            ),
          ),
          if (label != null)
            Center(
              child: Text(
                label!,
                style: displayStyle(size: height - 6, color: p.white, shadowDy: 1.5),
              ),
            ),
        ],
      ),
    );
  }
}

/// The game screen scaffold: brand gradient + diagonal stripes (the `GScreen`).
class GameScaffold extends StatelessWidget {
  const GameScaffold({
    required this.child,
    this.background,
    this.bottomBar,
    this.padding = const EdgeInsets.fromLTRB(16, 10, 16, 18),
    this.bottomBarSpacing = 12,
    this.bodyScrolls = false,
    this.fillWidth = false,
    super.key,
  });

  final Widget child;
  final Color? background;

  /// Pinned action area flush to the bottom of the viewport, inside SafeArea.
  /// When null the body fills the whole padded area (legacy behaviour).
  final Widget? bottomBar;
  final EdgeInsets padding;

  /// Gap between the (optionally scrollable) body and the pinned [bottomBar].
  final double bottomBarSpacing;

  /// When true the body is wrapped in a scroll view so tall content can
  /// overflow on short devices while [bottomBar] stays pinned.
  final bool bodyScrolls;

  /// When true the content spans the FULL viewport width (the cockpit / race
  /// scene wants the whole landscape). Otherwise the interactive content is
  /// capped to a device-aware width and CENTRED on the full-bleed background — so
  /// the app fills and adapts on a phone, an iPad (portrait + landscape) and a
  /// desktop browser, instead of being locked to one mobile width.
  final bool fillWidth;

  /// Comfortable content width for [viewportWidth]. Phones go edge to edge;
  /// tablets/desktop centre a wider column (portrait UI stretched far past this
  /// just distorts — the branded background fills the rest).
  static double contentWidthFor(double viewportWidth) {
    if (viewportWidth < 600) return double.infinity; // phones: full width
    if (viewportWidth < 1000) return viewportWidth * 0.82; // iPad portrait / small tablet
    return 760; // large tablet + desktop: a comfortable centred column
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final decoration = background != null
        ? BoxDecoration(color: background)
        : BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [p.blueTop, p.blueBot, p.blueDeep],
              stops: const [0, 0.62, 1],
            ),
          );
    // Material → provides the text/icon ancestor (no yellow double-underlines);
    // SizedBox.expand → fills the viewport even under the AnimatedSwitcher's
    // loose constraints (so the background always covers the whole screen).
    return Material(
      type: MaterialType.transparency,
      child: SizedBox.expand(
        child: DecoratedBox(
          decoration: decoration,
          child: Stack(
            children: [
              Positioned.fill(
                child: IgnorePointer(
                  child: Opacity(
                    opacity: 0.07,
                    child: CustomPaint(painter: _StripePainter()),
                  ),
                ),
              ),
              SafeArea(
                // Centre + cap the content with symmetric padding (NOT Align/Center,
                // which would loosen the height and break the Expanded-based columns
                // like the cockpit). The content keeps a tight (capped width × full
                // height) box, so the layouts fill correctly at any viewport.
                child: LayoutBuilder(
                  builder: (context, c) {
                    final cap = fillWidth ? c.maxWidth : contentWidthFor(c.maxWidth);
                    final side =
                        cap.isFinite && cap < c.maxWidth ? (c.maxWidth - cap) / 2 : 0.0;
                    return Padding(
                      padding: EdgeInsets.symmetric(horizontal: side),
                      child: Padding(
                        padding: padding,
                        child: bottomBar == null
                            ? child
                            : Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  Expanded(
                                    child: bodyScrolls
                                        ? SingleChildScrollView(child: child)
                                        : child,
                                  ),
                                  SizedBox(height: bottomBarSpacing),
                                  bottomBar!,
                                ],
                              ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StripePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0xFFFFFFFF)
      ..strokeWidth = 3;
    const gap = 26.0;
    canvas
      ..save()
      ..clipRect(Offset.zero & size);
    for (var x = -size.height; x < size.width + size.height; x += gap) {
      canvas.drawLine(Offset(x, 0), Offset(x + size.height, size.height), paint);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_StripePainter oldDelegate) => false;
}

/// A spinning coin (the design's `GCoin`).
class CoinIcon extends StatelessWidget {
  const CoinIcon({this.size = 20, super.key});
  final double size;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(size: Size.square(size), painter: _CoinPainter(context.palette));
  }
}

class _CoinPainter extends CustomPainter {
  _CoinPainter(this.p);
  final ThrotlPalette p;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.width / 2;
    canvas
      ..drawCircle(c, r - 1, Paint()..color = p.yellow)
      ..drawCircle(
        c,
        r - 1,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.2
          ..color = p.ink,
      )
      ..drawCircle(
        c,
        r * 0.62,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.8
          ..color = shade(p.yellow, -0.35),
      );
  }

  @override
  bool shouldRepaint(_CoinPainter oldDelegate) => oldDelegate.p != p;
}

/// Chunky toast message (the design's `GToastMsg`).
class ChunkyToast extends StatelessWidget {
  const ChunkyToast({required this.text, super.key});
  final String text;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
      decoration: BoxDecoration(
        color: p.ink,
        borderRadius: BorderRadius.circular(100),
        boxShadow: const [BoxShadow(color: Color(0x59000000), offset: Offset(0, 5))],
      ),
      child: Text(
        text,
        style: displayStyle(
          size: 12,
          color: p.yellow,
          letterSpacing: 1,
        ).copyWith(shadows: const []),
      ),
    );
  }
}
