import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:throtl/src/audio/sfx.dart';
import 'package:throtl/src/engine/price_feed.dart';
import 'package:throtl/src/engine/ride_controller.dart';
import 'package:throtl/src/theme/tokens.dart';
import 'package:throtl/src/widgets/chunky.dart';
import 'package:throtl/src/widgets/race_car.dart';

/// The race scene — a clean straight road that PITCHES uphill/downhill with the
/// market (flat market ⇒ flat road), the car driving on it, gauges for the
/// ups/downs, coin pops on winning ticks, and the throttle rail. The hill-climb
/// metaphor the design landed on. 60fps via a [Ticker]; reads the live ride.
class HillScene extends StatefulWidget {
  const HillScene({
    required this.ride,
    required this.feed,
    required this.car,
    required this.tint,
    super.key,
  });

  final RideEngine ride;
  final PriceFeed feed;
  final GameCar car;
  final Color tint;

  @override
  State<HillScene> createState() => _HillSceneState();
}

class _Pop {
  _Pop({required this.value6, required this.loss, required this.t, required this.dx});
  final int value6;
  final bool loss;
  final double t;
  final double dx;
}

/// A bare per-frame repaint signal. The scene's [Ticker] pulses this each frame
/// and ONLY the scene's [AnimatedBuilder] subtree rebuilds — never the whole
/// RaceScreen or the clip/border scaffold. Replaces the old per-frame
/// `setState(() {})`, which rebuilt the entire widget tree 60×/sec.
class _FrameSignal extends ChangeNotifier {
  void pulse() => notifyListeners();
}

class _HillSceneState extends State<HillScene> with SingleTickerProviderStateMixin {
  late final Ticker _ticker = createTicker(_onFrame);
  final _FrameSignal _frameSignal = _FrameSignal();
  final math.Random _rng = math.Random();

  Duration _elapsed = Duration.zero;
  double _inc = 0; // smoothed incline degrees (from price velocity)
  double _vel = 0; // raw recent price velocity (fraction) — drives GRADE %
  double _thr = 0; // smoothed live throttle — leans the road to player input
  double _scroll = 0;
  final List<_Pop> _pops = [];
  int _lastTick = 0;
  int _lastPnl = 0;
  double _lastPopT = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_ticker.start());
    // spin up the analog engine drone for the duration of the race scene
    unawaited(sfx.engineStart());
  }

  @override
  void dispose() {
    sfx.engineStop();
    _ticker.dispose();
    _frameSignal.dispose();
    super.dispose();
  }

  void _onFrame(Duration d) {
    final prevMs = _elapsed.inMicroseconds / 1e6;
    _elapsed = d;
    final nowS = d.inMicroseconds / 1e6;
    final s = widget.ride.snapshot;
    final hist = widget.feed.history;

    // grade = recent price velocity → incline degrees (smoothed)
    if (hist.length >= 4) {
      final tail = hist.length >= 18 ? hist.sublist(hist.length - 18) : hist;
      final first = tail.first.toDouble();
      final vel = first == 0 ? 0.0 : (tail.last - tail.first) / first;
      _vel = vel;
      final target = (vel * 13000).clamp(-24.0, 24.0);
      _inc += (target - _inc) * 0.18;
    }

    // ease the live throttle so the road climbs smoothly with the finger and
    // keeps animating between the 90ms engine steps
    _thr += (s.throttle - _thr) * 0.25;

    // feed the engine drone — pitch + loudness ride the throttle deflection
    final lvl = s.throttle.abs();
    sfx.engineSet(lvl, on: lvl > 0.01);

    // road scroll, faster under load
    final dt = (nowS - prevMs).clamp(0.0, 0.1);
    _scroll += dt * 120 * (1 + s.throttle.abs() * 1.5);

    // coin / smoke pops on PnL change
    if (s.ticks != _lastTick) {
      final delta = s.totalPnl6 - _lastPnl;
      if (!s.position.isFlat && nowS - _lastPopT > 0.26 && delta.abs() > 30000) {
        _pops.add(
          _Pop(value6: delta, loss: delta < 0, t: nowS, dx: _rng.nextDouble() * 50 - 25),
        );
        _lastPopT = nowS;
        if (delta > 0) {
          sfx.coin();
        } else {
          sfx.loss();
        }
      }
      _lastTick = s.ticks;
      _lastPnl = s.totalPnl6;
    }
    _pops.removeWhere((p) => nowS - p.t > 0.9);

    // Was `setState(() {})` — a full-tree rebuild 60×/sec. Now just pulse the
    // signal; the scene's AnimatedBuilder rebuilds in isolation. The ticker is
    // disposed before the signal, so this can never fire after teardown.
    _frameSignal.pulse();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;

    return ClipRRect(
      borderRadius: BorderRadius.circular(18),
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border.all(color: p.ink, width: 3),
          borderRadius: BorderRadius.circular(18),
          boxShadow: [BoxShadow(color: p.ink, offset: const Offset(0, 5))],
        ),
        child: LayoutBuilder(
          builder: (context, c) {
            final w = c.maxWidth;
            final h = c.maxHeight;
            return Stack(
              children: [
                // Static backdrop (sky + grass): built and rastered once, then
                // cached behind its own RepaintBoundary so the per-frame scene
                // on top never forces these gradients to re-paint.
                RepaintBoundary(child: _backdrop(h, p)),
                // The live scene: a single AnimatedBuilder driven by the frame
                // signal, so each 60fps tick rebuilds ONLY this subtree — not
                // RaceScreen, not the clip/border scaffold, not the backdrop.
                // Its RepaintBoundary keeps the animating raster off those layers.
                Positioned.fill(
                  child: RepaintBoundary(
                    child: AnimatedBuilder(
                      animation: _frameSignal,
                      builder: (context, _) => _scene(w, h, p),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  /// The static backdrop — sky gradient + grass apron. Independent of the frame
  /// clock, so it builds once per layout and stays cached behind a boundary.
  Widget _backdrop(double h, ThrotlPalette p) {
    return Stack(
      children: [
        // sky
        const Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color(0xFF6FB7FF), Color(0xFF3E8BFF), Color(0xFF2F6FE0)],
                stops: [0, 0.58, 1],
              ),
            ),
          ),
        ),
        // grass apron
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          height: h * 0.30,
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color(0xFF57B85A), Color(0xFF3E9C45)],
              ),
              border: Border(top: BorderSide(color: p.ink, width: 3)),
            ),
          ),
        ),
      ],
    );
  }

  /// The live scene — everything that moves with the market, the throttle, and
  /// the scene clock. Rebuilt every frame by the [AnimatedBuilder] in [build],
  /// in isolation from the rest of the tree.
  Widget _scene(double w, double h, ThrotlPalette p) {
    final s = widget.ride.snapshot;
    final hist = widget.feed.history;
    final nowS = _elapsed.inMicroseconds / 1e6;

    const cx = 0.44;
    const cy = 0.6;

    final price = s.markE9 / 1e9;
    final up = s.markE9 >= widget.feed.prevE9;
    // the visible grade = market velocity (the chart) + the player's live
    // throttle lean, so dragging the rail immediately pitches the hill
    // (clamped so full lever never tips the road into a wall)
    final incDeg = (_inc + _thr * 14.0).clamp(-28.0, 28.0);
    final incRad = incDeg * math.pi / 180;

    final win = hist.length > 200 ? hist.sublist(hist.length - 200) : hist;
    final lo = win.isEmpty ? 0 : win.reduce(math.min);
    final hi = win.isEmpty ? 1 : win.reduce(math.max);
    final altFrac = hi == lo ? 0.5 : ((s.markE9 - lo) / (hi - lo)).clamp(0.0, 1.0);

    final lev = s.levDisplay;
    final col = s.throttle > 0
        ? p.green
        : s.throttle < 0
        ? p.red
        : p.cyan;
    final side = s.throttle > 0
        ? 'LONG · WINS UPHILL'
        : s.throttle < 0
        ? 'SHORT · WINS DOWNHILL'
        : 'COASTING';
    // nitro exhaust kicks in past ~32% lever; coloured by direction
    final boost = s.throttle.abs();
    final nitro = ((boost - 0.32) / 0.68).clamp(0.0, 1.0);
    final nitroCol = s.throttle > 0
        ? p.green
        : s.throttle < 0
        ? p.red
        : p.cyan;

    // car size scales per model off the race car (= 188px); bob + nitro flicker
    // come from the scene clock so the car feels alive between engine ticks.
    final carW = 188.0 * widget.car.sideScale;
    final carH = carW / widget.car.sideAspect;
    final carBob = math.sin(nowS * 7.5) * 1.6 * (1 + boost * 1.5);
    final pulse = (nowS * 1.8) % 1.0;

    return Stack(
      children: [
        _scenery(w, h),
        // wind / speed lines streaking through the sky — count + speed
        // rise with the throttle (the design's GSpeedLines + gZip)
        Positioned(
          left: 0,
          right: 0,
          top: 0,
          height: cy * h * 0.84,
          child: IgnorePointer(
            child: ClipRect(
              child: CustomPaint(
                painter: _WindPainter(time: nowS, intensity: s.throttle.abs()),
              ),
            ),
          ),
        ),
        // the straight road — rotates around the car's contact point
        // (cx, cy) so the surface under the car never moves: the car is
        // always grounded, on any slope. Box centre = (cx*w, cy*h) and
        // the painter draws the drivable surface at its vertical centre.
        Positioned(
          left: cx * w - w * 0.95,
          top: cy * h - 45,
          width: w * 1.9,
          height: 90,
          child: Transform.rotate(
            angle: -incRad,
            child: CustomPaint(painter: _RoadPainter(_scroll, p.ink)),
          ),
        ),
        // the car + its shadow + nitro exhaust, grouped and grounded:
        // bottom-centre rides the road surface at (cx, cy), wheels glued
        // on any grade. Sized per-model so an F1 and a truck both sit
        // correctly without distortion.
        Positioned(
          left: cx * w - carW / 2,
          top: cy * h - carH + 9,
          width: carW,
          height: carH,
          child: IgnorePointer(
            child: RaceCar(
              asset: widget.car.side,
              aspect: widget.car.sideAspect,
              width: carW,
              slope: incRad,
              exposure: s.throttle,
              nitro: nitro,
              nitroColor: nitroCol,
              ink: p.ink,
              panic: s.panicActive,
              bob: carBob,
              pulse: pulse,
            ),
          ),
        ),
        // price tag
        Positioned(
          left: cx * w - 40,
          top: cy * h + 26,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 2),
            decoration: BoxDecoration(
              color: p.cream,
              border: Border.all(color: p.ink, width: 2.5),
              borderRadius: BorderRadius.circular(9),
            ),
            child: Text(
              '\$${price.toStringAsFixed(2)} ${up ? '▲' : '▼'}',
              style: displayStyle(
                size: 12,
                color: up ? p.greenDeep : p.redDeep,
              ).copyWith(shadows: const []),
            ),
          ),
        ),
        // coin / smoke pops
        for (final pop in _pops)
          Positioned(
            left: cx * w + pop.dx,
            top: cy * h - (pop.loss ? 56 : 86) - (nowS - pop.t) * 30,
            child: Opacity(
              opacity: (1 - (nowS - pop.t) / 0.9).clamp(0.0, 1.0),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (pop.loss)
                    Container(
                      width: 13,
                      height: 13,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: const Color(0xE65A6072),
                        border: Border.all(color: p.ink, width: 2),
                      ),
                    )
                  else
                    const CoinIcon(size: 14),
                  const SizedBox(width: 3),
                  Text(
                    '${pop.loss ? '−' : '+'}\$${(pop.value6.abs() / 1e6).toStringAsFixed(2)}',
                    style:
                        displayStyle(
                          size: 14,
                          color: pop.loss ? const Color(0xFFFFD6D6) : p.white,
                        ).copyWith(
                          shadows: [Shadow(color: p.ink, offset: const Offset(0, 2))],
                        ),
                  ),
                ],
              ),
            ),
          ),
        // leverage plate + grade/alt
        Positioned(top: 12, left: 12, child: _hud(p, lev, side, col, _vel, altFrac)),
        // spin-out stamp
        if (s.panicActive)
          Align(
            alignment: const Alignment(-0.1, -0.2),
            child: Transform.rotate(
              angle: -0.12,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 8),
                decoration: BoxDecoration(
                  color: p.red,
                  border: Border.all(color: p.ink, width: 4),
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [BoxShadow(color: p.ink, offset: const Offset(0, 5))],
                ),
                child: StrokeText(
                  'SPIN-OUT!',
                  strokeColor: p.ink,
                  style: displayStyle(size: 30, color: p.white, shadowDy: 3),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _scenery(double w, double h) {
    const sprites = [
      ('assets/track/grandStand.png', 60.0),
      ('assets/track/treeLarge.png', 40.0),
      ('assets/track/flagCheckers.png', 34.0),
      ('assets/track/lightPostLarge.png', 46.0),
      ('assets/track/grandStandCovered.png', 64.0),
    ];
    final base = h * 0.70;
    final period = w * 0.42;
    final off = _scroll * 0.4 % (period * sprites.length);
    return ClipRect(
      child: Stack(
        children: [
          for (var i = 0; i < sprites.length * 2; i++)
            Positioned(
              bottom: h - base,
              left: i * period - off,
              child: Opacity(
                opacity: 0.85,
                child: Image.asset(
                  sprites[i % sprites.length].$1,
                  width: sprites[i % sprites.length].$2,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _hud(
    ThrotlPalette p,
    double lev,
    String side,
    Color col,
    double vel,
    double altFrac,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Transform(
          transform: Matrix4.skewX(-0.1),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
            decoration: BoxDecoration(
              gradient: candy(col),
              border: Border.all(color: p.ink, width: 3),
              borderRadius: BorderRadius.circular(11),
              boxShadow: [BoxShadow(color: p.ink, offset: const Offset(0, 3.5))],
            ),
            child: Transform(
              transform: Matrix4.skewX(0.1),
              child: Text(
                '${lev >= 0 ? '+' : '−'}${lev.abs().toStringAsFixed(1)}x',
                style: displayStyle(size: 24, color: p.white).copyWith(shadows: const []),
              ),
            ),
          ),
        ),
        const SizedBox(height: 7),
        Text(
          side,
          style: displayStyle(size: 11, color: p.white, letterSpacing: 1.5).copyWith(
            shadows: [Shadow(color: p.ink, offset: const Offset(0, 2))],
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            _miniChip(
              p,
              child: Text(
                '${vel >= 0 ? '⬈' : '⬊'} ${(vel * 100).abs().toStringAsFixed(2)}%  GRADE',
                style: displayStyle(
                  size: 11,
                  color: vel > 0.0005 ? p.green : (vel < -0.0005 ? p.red : p.white),
                ).copyWith(shadows: const []),
              ),
            ),
            const SizedBox(width: 6),
            _miniChip(
              p,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'ALT ',
                    style: bodyStyle(
                      size: 8.5,
                      color: const Color(0xB3FFFFFF),
                      weight: FontWeight.w800,
                    ),
                  ),
                  SizedBox(
                    width: 52,
                    height: 11,
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: [
                        Positioned(
                          left: 0,
                          right: 0,
                          top: 2,
                          height: 7,
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(100),
                            child: Stack(
                              children: [
                                const ColoredBox(color: Color(0x59000000)),
                                FractionallySizedBox(
                                  widthFactor: altFrac,
                                  child: DecoratedBox(
                                    decoration: BoxDecoration(
                                      gradient: LinearGradient(
                                        colors: [shade(p.cyan, -0.2), p.cyan],
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        // yellow position marker riding the fill edge
                        Positioned(
                          left: (altFrac * 52 - 3).clamp(0.0, 49.0),
                          top: 0,
                          child: Container(
                            width: 6,
                            height: 11,
                            decoration: BoxDecoration(
                              color: p.yellow,
                              borderRadius: BorderRadius.circular(2),
                              border: Border.all(color: p.ink, width: 1.5),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    '${(altFrac * 100).round()}',
                    style: displayStyle(size: 11, color: p.white).copyWith(shadows: const []),
                  ),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _miniChip(ThrotlPalette p, {required Widget child}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      decoration: BoxDecoration(
        color: const Color(0x8C0D163A),
        border: Border.all(color: p.ink, width: 2.5),
        borderRadius: BorderRadius.circular(100),
      ),
      child: child,
    );
  }
}

class _RoadPainter extends CustomPainter {
  _RoadPainter(this.scroll, this.ink);
  final double scroll;
  final Color ink;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    // The drivable surface sits at the box's vertical centre — which is the
    // rotation pivot AND the car's contact line — so the car never sinks.
    final surf = size.height / 2;
    final asphalt = Paint()..color = const Color(0xFF494E5B);
    final inkPaint = Paint()
      ..color = ink
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3;
    // asphalt body, hanging below the surface
    final body = Rect.fromLTWH(0, surf, w, 38);
    canvas
      ..drawRect(body, asphalt)
      ..drawLine(Offset(0, surf), Offset(w, surf), inkPaint)
      ..drawLine(Offset(0, surf + 38), Offset(w, surf + 38), inkPaint);
    // red/white racing kerb riding the top surface edge
    const seg = 11.0;
    final kerbOff = -(scroll % (seg * 2));
    for (var x = kerbOff; x < w; x += seg * 2) {
      canvas
        ..drawRect(Rect.fromLTWH(x, surf, seg, 6), Paint()..color = const Color(0xFFE0414C))
        ..drawRect(Rect.fromLTWH(x + seg, surf, seg, 6), Paint()..color = const Color(0xFFF3EFE6));
    }
    // dashed centre line
    const dash = 14.0;
    const period = 30.0;
    final dOff = -(scroll % period);
    final dashPaint = Paint()..color = const Color(0xD9EFEADD);
    for (var x = dOff; x < w; x += period) {
      canvas.drawRect(Rect.fromLTWH(x, surf + 20, dash, 3), dashPaint);
    }
  }

  @override
  bool shouldRepaint(_RoadPainter oldDelegate) => oldDelegate.scroll != scroll;
}

/// Wind / speed lines — white streaks sweeping right→left across the sky, the
/// count and speed scaling with the throttle. Ports the design's `GSpeedLines`
/// + `gZip` keyframe (translateX 110% → −130%, opacity in at 12%).
class _WindPainter extends CustomPainter {
  _WindPainter({required this.time, required this.intensity});
  final double time;
  final double intensity;

  @override
  void paint(Canvas canvas, Size size) {
    if (intensity < 0.15) return;
    final n = (3 + intensity * 5).round();
    final lineW = size.width * 0.5;
    for (var i = 0; i < n; i++) {
      final period = 0.55 - intensity * 0.3 + (i % 3) * 0.1;
      var prog = ((time + i * 0.09) / period) % 1.0;
      if (prog < 0) prog += 1;
      // sweep the streak from off the right edge to off the left edge
      final cx = (1.10 - prog * 2.40) * size.width;
      // fade in by 12%, then fade out to the end
      final op = prog < 0.12 ? prog / 0.12 : 1 - (prog - 0.12) / 0.88;
      final ty = (0.08 + (i * 0.83) % 0.84) * size.height;
      final lineH = 3.0 + (i % 3);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(cx - lineW / 2, ty, lineW, lineH),
          const Radius.circular(3),
        ),
        Paint()..color = const Color(0xFFFFFFFF).withValues(alpha: (op * 0.8).clamp(0.0, 1.0)),
      );
    }
  }

  @override
  bool shouldRepaint(_WindPainter oldDelegate) =>
      oldDelegate.time != time || oldDelegate.intensity != intensity;
}
