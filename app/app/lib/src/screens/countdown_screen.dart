import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:throtl/src/audio/sfx.dart';
import 'package:throtl/src/widgets/chunky.dart';

/// The 3·2·1·SEND IT arming countdown (the design's `GCountdown`).
class CountdownScreen extends StatefulWidget {
  const CountdownScreen({required this.onDone, super.key});

  final VoidCallback onDone;

  @override
  State<CountdownScreen> createState() => _CountdownScreenState();
}

class _CountdownScreenState extends State<CountdownScreen> {
  int _n = 3;
  Timer? _t;
  bool _alive = true;

  @override
  void initState() {
    super.initState();
    _step(3);
  }

  void _step(int v) {
    if (!_alive) return;
    setState(() => _n = v);
    if (v > 0) {
      sfx.countBeep();
      _t = Timer(const Duration(milliseconds: 750), () => _step(v - 1));
    } else {
      sfx.countGo();
      _t = Timer(const Duration(milliseconds: 650), () {
        if (_alive) widget.onDone();
      });
    }
  }

  @override
  void dispose() {
    _alive = false;
    _t?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final label = _n > 0 ? '$_n' : 'SEND IT!';
    final col = _n > 0 ? p.white : p.yellow;
    return GameScaffold(
      child: Stack(
        alignment: Alignment.center,
        children: [
          // F1 5-light start gantry
          Align(
            alignment: const Alignment(0, -0.45),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (var i = 0; i < 5; i++)
                  Container(
                    margin: const EdgeInsets.symmetric(horizontal: 5),
                    width: 22,
                    height: 22,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: p.red,
                      border: Border.all(color: p.ink, width: 3),
                      boxShadow: [
                        BoxShadow(color: p.ink, offset: const Offset(0, 3)),
                        BoxShadow(color: p.red, blurRadius: 14),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 320),
                transitionBuilder: (child, anim) => ScaleTransition(
                  scale: Tween<double>(begin: 2.2, end: 1).animate(
                    CurvedAnimation(parent: anim, curve: Curves.easeOut),
                  ),
                  child: FadeTransition(opacity: anim, child: child),
                ),
                child: StrokeText(
                  label,
                  key: ValueKey(_n),
                  strokeColor: p.ink,
                  style: displayStyle(
                    size: _n > 0 ? 150 : 64,
                    color: col,
                    shadowDy: 6,
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Text(
                _n > 0 ? 'LIGHTS OUT' : 'GO GO GO',
                style: displayStyle(size: 13, color: p.white, letterSpacing: 3.9).copyWith(
                  shadows: [Shadow(color: p.ink, offset: const Offset(0, 2))],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
