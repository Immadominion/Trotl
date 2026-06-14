import 'dart:math' as math;

import 'package:flutter/widgets.dart';

/// A showroom hero car — the pre-rendered 3D side sprite, floated with a gentle
/// bob over a soft contact shadow and an optional livery glow. Used on the
/// title, results and share screens (the garage uses the spinning
/// `CarTurntable`; the race uses the grounded `RaceCar`). Aspect-agnostic:
/// `BoxFit.contain` fits any model — an F1 or a fire truck — without distortion.
class CarSprite extends StatefulWidget {
  const CarSprite({
    required this.asset,
    this.tint,
    this.height = 160,
    this.widthFactor = 1,
    super.key,
  });

  final String asset;
  final Color? tint;

  /// Box height the car floats within.
  final double height;

  /// Fraction of the available width the car may occupy.
  final double widthFactor;

  @override
  State<CarSprite> createState() => _CarSpriteState();
}

class _CarSpriteState extends State<CarSprite> with SingleTickerProviderStateMixin {
  late final AnimationController _bob = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2000),
  )..repeat();

  @override
  void dispose() {
    _bob.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final h = widget.height;
    return SizedBox(
      height: h,
      child: LayoutBuilder(
        builder: (context, c) {
          final boxW = c.maxWidth.isFinite ? c.maxWidth : h * 3;
          final w = boxW * widget.widthFactor;
          return Stack(
            alignment: Alignment.bottomCenter,
            clipBehavior: Clip.none,
            children: [
              // livery glow — brand presence without recolouring the sprite
              // (wide soft ELLIPSE — BoxShape.circle collapses a wide box to a dot)
              if (widget.tint != null)
                Positioned(
                  bottom: h * 0.08,
                  child: Container(
                    width: w * 0.6,
                    height: h * 0.22,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.all(Radius.elliptical(w * 0.3, h * 0.11)),
                      boxShadow: [
                        BoxShadow(
                          color: widget.tint!.withValues(alpha: 0.4),
                          blurRadius: 34,
                          spreadRadius: 2,
                        ),
                      ],
                    ),
                  ),
                ),
              // soft contact shadow — a wide flat ellipse
              Positioned(
                bottom: h * 0.055,
                child: Container(
                  width: w * 0.52,
                  height: h * 0.085,
                  decoration: BoxDecoration(
                    color: const Color(0x4D16307E),
                    borderRadius: BorderRadius.all(Radius.elliptical(w * 0.26, h * 0.043)),
                  ),
                ),
              ),
              AnimatedBuilder(
                animation: _bob,
                builder: (context, _) {
                  final bob = math.sin(_bob.value * 2 * math.pi) * 3.0;
                  return Transform.translate(
                    offset: Offset(0, -bob - h * 0.07),
                    child: SizedBox(
                      width: w,
                      height: h * 0.88,
                      child: Image.asset(
                        widget.asset,
                        fit: BoxFit.contain,
                        alignment: Alignment.bottomCenter,
                        filterQuality: FilterQuality.high,
                      ),
                    ),
                  );
                },
              ),
            ],
          );
        },
      ),
    );
  }
}
