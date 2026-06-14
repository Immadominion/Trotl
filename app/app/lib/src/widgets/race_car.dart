import 'dart:math' as math;

import 'package:flutter/widgets.dart';

/// The car as it drives the road — the pre-rendered 3D side sprite, grouped
/// with its **own** contact shadow, livery ground-glow and nitro exhaust, then
/// rotated as one unit around the wheel-contact point. Because the whole group
/// shares that pivot, the wheels never leave the asphalt on any grade and the
/// exhaust always trails from the rear wheel — the smoke is a property of the
/// car, not a loose overlay. Place it so its bottom-centre sits on the road.
class RaceCar extends StatelessWidget {
  const RaceCar({
    required this.asset,
    required this.aspect,
    required this.width,
    required this.slope,
    required this.exposure,
    required this.nitro,
    required this.nitroColor,
    required this.ink,
    required this.panic,
    required this.bob,
    required this.pulse,
    super.key,
  });

  final String asset;

  /// width / height of the sprite — sizes the car without distortion.
  final double aspect;

  /// On-road display width (px).
  final double width;

  /// Road grade (radians). The car pitches to match it.
  final double slope;

  /// Signed throttle deflection (-1..1) — adds a little attitude.
  final double exposure;

  /// Nitro intensity (0..1) — exhaust length / brightness.
  final double nitro;
  final Color nitroColor;
  final Color ink;

  /// Spin-out — a quick shake.
  final bool panic;

  /// Vertical bob (px) from the scene loop.
  final double bob;

  /// 0..1 nitro flicker phase from the scene loop.
  final double pulse;

  @override
  Widget build(BuildContext context) {
    final h = width / aspect;
    final boost = exposure.abs();
    // attitude: match the road grade, plus a hair of nose-lift on long /
    // nose-dip on short. Negative = counter-clockwise = right (nose) up.
    final panicWobble = panic ? math.sin(pulse * 2 * math.pi * 6) * 0.05 : 0.0;
    final angle = -slope - exposure * 0.05 + panicWobble;

    final trailLen = 34 + nitro * 66;

    return Transform.rotate(
      angle: angle,
      alignment: Alignment.bottomCenter,
      child: SizedBox(
        width: width,
        height: h,
        child: Stack(
          clipBehavior: Clip.none,
          alignment: Alignment.bottomCenter,
          children: [
            // livery ground-glow while levered (green long / red short) — a wide
            // soft ELLIPSE (BoxShape.circle would collapse a wide box to a dot)
            if (boost > 0.04)
              Positioned(
                bottom: h * 0.02,
                child: Container(
                  width: width * 0.72,
                  height: h * 0.22,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.all(Radius.elliptical(width * 0.36, h * 0.11)),
                    boxShadow: [
                      BoxShadow(
                        color: nitroColor.withValues(alpha: 0.5 * boost),
                        blurRadius: 26,
                        spreadRadius: 1,
                      ),
                    ],
                  ),
                ),
              ),
            // contact shadow — a wide flat ellipse sitting under the wheels
            Positioned(
              bottom: h * 0.05,
              child: Container(
                width: width * 0.62,
                height: h * 0.12,
                decoration: BoxDecoration(
                  color: ink.withValues(alpha: 0.30),
                  borderRadius: BorderRadius.all(Radius.elliptical(width * 0.31, h * 0.06)),
                ),
              ),
            ),
            // nitro exhaust — trails left from the rear wheel, at hub height
            if (nitro > 0.02)
              Positioned(
                left: width * 0.14 - trailLen,
                bottom: h * 0.22,
                child: _Trail(
                  len: trailLen,
                  color: nitroColor,
                  nitro: nitro,
                  pulse: pulse,
                ),
              ),
            // the car, lifted by the bob (exact aspect box → no distortion)
            Positioned.fill(
              child: Transform.translate(
                offset: Offset(0, -bob),
                child: Image.asset(
                  asset,
                  fit: BoxFit.fill,
                  filterQuality: FilterQuality.high,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Trail extends StatelessWidget {
  const _Trail({
    required this.len,
    required this.color,
    required this.nitro,
    required this.pulse,
  });

  final double len;
  final Color color;
  final double nitro;
  final double pulse;

  @override
  Widget build(BuildContext context) {
    // two streaks pulsing slightly out of phase, fading from the tail into a
    // hot yellow tip nearest the car
    final flick = 0.86 + math.sin(pulse * 2 * math.pi) * 0.12;
    Widget bar(double thickness, double phase) {
      final w = len * (0.86 + math.sin((pulse + phase) * 2 * math.pi) * 0.14);
      return Container(
        width: w,
        height: thickness,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(100),
          gradient: LinearGradient(
            colors: [
              const Color(0x00000000),
              color,
              const Color(0xFFFFF0B0),
            ],
            stops: const [0, 0.58, 1],
          ),
          boxShadow: [
            BoxShadow(color: color.withValues(alpha: 0.85 * nitro), blurRadius: 11),
          ],
        ),
      );
    }

    return Opacity(
      opacity: (0.62 + nitro * 0.38) * flick,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          bar(9 + nitro * 4, 0),
          const SizedBox(height: 4),
          bar(5 + nitro * 3, 0.4),
        ],
      ),
    );
  }
}
