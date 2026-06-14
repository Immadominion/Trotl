import 'package:flutter/widgets.dart';
import 'package:throtl/src/engine/ride_controller.dart';
import 'package:throtl/src/theme/tokens.dart';
import 'package:throtl/src/widgets/chunky.dart';

/// The analog control: drag up to lever long, down to short, release to coast
/// flat, fast down-flick to spin out. Drives the real [RideController].
///
/// The gesture surface is built ONCE and the knob is driven by [ValueNotifier]s
/// + the ride listenable, so neither the ride's per-tick notifications nor the
/// drag itself ever rebuild the `GestureDetector` — the pan can never get
/// interrupted or "stuck".
class ThrottleRail extends StatefulWidget {
  const ThrottleRail({required this.ride, super.key});

  final RideEngine ride;

  @override
  State<ThrottleRail> createState() => _ThrottleRailState();
}

class _ThrottleRailState extends State<ThrottleRail> {
  final ValueNotifier<double> _local = ValueNotifier<double>(0);
  final ValueNotifier<bool> _active = ValueNotifier<bool>(false);

  @override
  void dispose() {
    _local.dispose();
    _active.dispose();
    super.dispose();
  }

  void _update(Offset pos, double h) {
    final mid = h / 2;
    var v = (mid - pos.dy) / (h / 2 - 16);
    v = v.clamp(-1.0, 1.0);
    if (v.abs() < 0.05) v = 0;
    _local.value = v;
    widget.ride.setThrottle(v);
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Column(
      children: [
        _cap(p, 'LONG'),
        const SizedBox(height: 6),
        Expanded(
          child: LayoutBuilder(
            builder: (context, c) {
              final h = c.maxHeight;
              return GestureDetector(
                behavior: HitTestBehavior.opaque,
                onPanStart: (d) {
                  _active.value = true;
                  _update(d.localPosition, h);
                },
                onPanUpdate: (d) => _update(d.localPosition, h),
                onPanEnd: (d) {
                  _active.value = false;
                  if (d.velocity.pixelsPerSecond.dy > 1400) {
                    widget.ride.spinOut();
                  } else {
                    widget.ride.release();
                  }
                },
                child: Center(
                  child: SizedBox(
                    width: 38,
                    height: double.infinity,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: const Color(0x8C0D163A),
                        border: Border.all(color: p.ink, width: 3),
                        borderRadius: BorderRadius.circular(100),
                        boxShadow: [BoxShadow(color: p.ink, offset: const Offset(0, 3))],
                      ),
                      child: Stack(
                        alignment: Alignment.center,
                        clipBehavior: Clip.none,
                        children: [
                          Positioned(top: 10, child: _tri(p.green, up: true)),
                          Positioned(bottom: 10, child: _tri(p.red, up: false)),
                          Positioned(
                            top: h / 2 - 1.5,
                            left: 5,
                            right: 5,
                            child: Container(
                              height: 3,
                              decoration: BoxDecoration(
                                color: const Color(0x59FFFFFF),
                                borderRadius: BorderRadius.circular(2),
                              ),
                            ),
                          ),
                          // knob — the only part that rebuilds (drag + coast),
                          // leaving the gesture surface above it untouched
                          Positioned.fill(
                            child: ListenableBuilder(
                              listenable: Listenable.merge([_local, _active, widget.ride]),
                              builder: (context, _) {
                                final active = _active.value;
                                final exposure = active
                                    ? _local.value
                                    : widget.ride.snapshot.throttle;
                                final pct = (1 - exposure) / 2;
                                final col = exposure > 0
                                    ? p.green
                                    : exposure < 0
                                    ? p.red
                                    : p.yellow;
                                return Stack(
                                  clipBehavior: Clip.none,
                                  children: [
                                    Positioned(
                                      top: (pct * h).clamp(28.0, h - 28) - 28,
                                      left: -14,
                                      child: _knob(p, col, active: active),
                                    ),
                                  ],
                                );
                              },
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
        const SizedBox(height: 6),
        _cap(p, 'SHORT'),
      ],
    );
  }

  Widget _cap(ThrotlPalette p, String label) {
    return Text(
      label,
      style: displayStyle(size: 11, color: p.white, letterSpacing: 1).copyWith(
        shadows: [Shadow(color: p.ink, offset: const Offset(0, 1.5))],
      ),
    );
  }

  Widget _knob(ThrotlPalette p, Color col, {required bool active}) {
    return Container(
      width: 66,
      height: 54,
      decoration: BoxDecoration(
        gradient: candy(col, lighten: 0.4),
        border: Border.all(color: p.ink, width: 3),
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(color: p.ink, offset: const Offset(0, 4), spreadRadius: 3),
          BoxShadow(color: shade(col, -0.45), offset: const Offset(0, 4)),
          if (active) BoxShadow(color: col, blurRadius: 22),
        ],
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          for (var i = 0; i < 3; i++)
            Container(
              margin: const EdgeInsets.symmetric(vertical: 2),
              width: 26,
              height: 4,
              decoration: BoxDecoration(
                color: const Color(0x4D000000),
                borderRadius: BorderRadius.circular(3),
              ),
            ),
        ],
      ),
    );
  }

  Widget _tri(Color color, {required bool up}) {
    return CustomPaint(
      size: const Size(16, 11),
      painter: _TriPainter(color, up: up),
    );
  }
}

class _TriPainter extends CustomPainter {
  _TriPainter(this.color, {required this.up});
  final Color color;
  final bool up;

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path();
    if (up) {
      path
        ..moveTo(size.width / 2, 0)
        ..lineTo(0, size.height)
        ..lineTo(size.width, size.height)
        ..close();
    } else {
      path
        ..moveTo(0, 0)
        ..lineTo(size.width, 0)
        ..lineTo(size.width / 2, size.height)
        ..close();
    }
    canvas.drawPath(path, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_TriPainter oldDelegate) => oldDelegate.color != color;
}
