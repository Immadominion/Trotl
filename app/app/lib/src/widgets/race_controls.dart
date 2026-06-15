import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:throtl/src/engine/ride_controller.dart';
import 'package:throtl/src/theme/tokens.dart';
import 'package:throtl/src/widgets/chunky.dart';

/// Wraps the race scene with keyboard + on-screen D-pad controls, so the game is
/// playable without a touchscreen (web / desktop). Keyboard and buttons drive the
/// SAME [RideEngine] methods the drag rail uses (`setThrottle`/`release`/
/// `spinOut`) through one ramp controller — so all three input paths feel
/// identical and never fight each other.
///
/// Mapping: **W / ↑** ramp toward LONG, **S / ↓** ramp toward SHORT, **release**
/// eases back to coast (banks), **X** spins out. Discrete keys feed an analog
/// throttle by ramping a held direction toward ±1 over ~0.33s, matching the rail.
class RaceControls extends StatefulWidget {
  const RaceControls({required this.ride, required this.child, super.key});

  final RideEngine ride;
  final Widget child;

  @override
  State<RaceControls> createState() => _RaceControlsState();
}

class _RaceControlsState extends State<RaceControls> with SingleTickerProviderStateMixin {
  /// Ramps the held direction toward ±1 while a key/button is down. Linear, full
  /// deflection in ~1/_rampPerSec seconds.
  static const double _rampPerSec = 3;

  late final Ticker _ramp = createTicker(_onRamp);
  Duration _lastTick = Duration.zero;

  // Held inputs, tracked per-source so keyboard and buttons can't cancel each
  // other (e.g. release the W key while still holding the on-screen ▲).
  bool _keyUp = false;
  bool _keyDown = false;
  bool _btnUp = false;
  bool _btnDown = false;

  int _dir = 0; // -1 short, 0 coast, +1 long — the resolved held direction
  double _value = 0; // current ramped throttle, mirrors the engine

  /// Drives the D-pad highlight without rebuilding the whole control surface.
  final ValueNotifier<int> _heldDir = ValueNotifier<int>(0);

  @override
  void initState() {
    super.initState();
    // Focus-independent: a game wants keys whether or not some button stole focus.
    HardwareKeyboard.instance.addHandler(_onKey);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    _ramp.dispose();
    _heldDir.dispose();
    super.dispose();
  }

  bool _onKey(KeyEvent e) {
    final k = e.logicalKey;
    final up = k == LogicalKeyboardKey.keyW || k == LogicalKeyboardKey.arrowUp;
    final down = k == LogicalKeyboardKey.keyS || k == LogicalKeyboardKey.arrowDown;
    final spin = k == LogicalKeyboardKey.keyX;
    if (!up && !down && !spin) return false; // let everything else through

    if (e is KeyDownEvent) {
      if (spin) {
        widget.ride.spinOut();
        _keyUp = false;
        _keyDown = false;
        _recompute();
      } else {
        if (up) _keyUp = true;
        if (down) _keyDown = true;
        _recompute();
      }
    } else if (e is KeyUpEvent) {
      if (up) _keyUp = false;
      if (down) _keyDown = false;
      _recompute();
    }
    return true; // consume down/up/repeat for our keys (no browser scroll, etc.)
  }

  void _btn(int dir, {required bool down}) {
    if (dir > 0) _btnUp = down;
    if (dir < 0) _btnDown = down;
    _recompute();
  }

  /// Resolve the held direction from all sources and start/steer/stop the ramp.
  void _recompute() {
    final up = _keyUp || _btnUp;
    final down = _keyDown || _btnDown;
    final dir = (up == down) ? 0 : (up ? 1 : -1); // both or neither ⇒ coast
    if (dir == _dir) return;
    _dir = dir;
    _heldDir.value = dir;
    if (dir == 0) {
      widget.ride.release(); // let go ⇒ coast/bank, exactly like the rail
    } else {
      _value = widget.ride.snapshot.throttle; // continue from wherever we are
      if (!_ramp.isActive) {
        _lastTick = Duration.zero;
        unawaited(_ramp.start());
      }
    }
  }

  void _onRamp(Duration now) {
    if (_dir == 0) {
      _ramp.stop();
      _lastTick = Duration.zero;
      return;
    }
    final dt = _lastTick == Duration.zero ? 0.0 : (now - _lastTick).inMicroseconds / 1e6;
    _lastTick = now;
    final target = _dir.toDouble();
    final step = _rampPerSec * dt;
    if ((target - _value).abs() <= step) {
      _value = target; // reached full deflection — hold here, stop ticking
      widget.ride.setThrottle(_value);
      _ramp.stop();
      _lastTick = Duration.zero;
    } else {
      _value += target > _value ? step : -step;
      widget.ride.setThrottle(_value);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Stack(
      children: [
        Positioned.fill(child: widget.child),
        // On-screen D-pad: the "direction buttons" for web play. Gated to web so
        // the mobile UI (where the drag rail is the control) stays uncluttered.
        // Mirrors the rail on the opposite edge; hold to ramp, release to bank.
        if (kIsWeb)
          Positioned(
            left: 10,
            bottom: 12,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _holdButton(p, dir: 1),
                const SizedBox(height: 10),
                _holdButton(p, dir: -1),
              ],
            ),
          ),
      ],
    );
  }

  Widget _holdButton(ThrotlPalette p, {required int dir}) {
    final col = dir > 0 ? p.green : p.red;
    final glyph = dir > 0 ? '▲' : '▼';
    return Listener(
      // Pointer events (not GestureDetector) so press-and-hold is instant and
      // never lost to gesture-arena disambiguation.
      onPointerDown: (_) => _btn(dir, down: true),
      onPointerUp: (_) => _btn(dir, down: false),
      onPointerCancel: (_) => _btn(dir, down: false),
      child: ValueListenableBuilder<int>(
        valueListenable: _heldDir,
        builder: (context, held, _) {
          final on = held == dir;
          return Container(
            width: 56,
            height: 52,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              gradient: candy(col, lighten: on ? 0.5 : 0.2),
              border: Border.all(color: p.ink, width: 3),
              borderRadius: BorderRadius.circular(16),
              boxShadow: [
                BoxShadow(color: p.ink, offset: const Offset(0, 4)),
                if (on) BoxShadow(color: col, blurRadius: 18),
              ],
            ),
            child: Text(
              glyph,
              style: displayStyle(size: 22, color: p.white).copyWith(shadows: const []),
            ),
          );
        },
      ),
    );
  }
}
