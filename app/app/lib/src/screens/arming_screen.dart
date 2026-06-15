import 'dart:async';

import 'package:flutter/material.dart';
import 'package:throtl/src/audio/sfx.dart';
import 'package:throtl/src/engine/live_ride_controller.dart';
import 'package:throtl/src/theme/tokens.dart';
import 'package:throtl/src/widgets/chunky.dart';

/// Shown for a LIVE (wallet-connected) ride between SLIDE-TO-ARM and the 3·2·1
/// countdown. The owner signs here — init+delegate (and, in real-money mode, the
/// Flash session key) — so by the time the lights go out the ride is already
/// armed on-chain. Practice rides skip this screen entirely (nothing to sign).
class ArmingScreen extends StatefulWidget {
  const ArmingScreen({
    required this.engine,
    required this.onReady,
    required this.onAbort,
    super.key,
  });

  final LiveRideController engine;

  /// Ride is armed (status → riding) — start the countdown.
  final VoidCallback onReady;

  /// Arming failed or the user backed out — tear down + return to the grid.
  final VoidCallback onAbort;

  @override
  State<ArmingScreen> createState() => _ArmingScreenState();
}

class _ArmingScreenState extends State<ArmingScreen> {
  bool _advanced = false;
  bool _slow = false;
  Timer? _slowTimer;

  @override
  void initState() {
    super.initState();
    widget.engine.addListener(_onChange);
    _slowTimer = Timer(const Duration(seconds: 40), () {
      if (mounted) setState(() => _slow = true);
    });
    _onChange(); // already armed? (e.g. a very fast path)
  }

  void _onChange() {
    final s = widget.engine.status;
    if (!_advanced && (s == LiveRideStatus.riding || s == LiveRideStatus.degraded)) {
      _advanced = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) widget.onReady();
      });
    }
  }

  @override
  void dispose() {
    widget.engine.removeListener(_onChange);
    _slowTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return ListenableBuilder(
      listenable: widget.engine,
      builder: (context, _) {
        final isError = widget.engine.status == LiveRideStatus.error;
        return GameScaffold(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: BannerPlate(
                  kicker: 'STARTING GRID',
                  title: isError ? 'ARM FAILED' : 'ARMING',
                  color: isError ? p.red : const Color(0xFFA06CF8),
                ),
              ),
              const Spacer(),
              if (isError) _errorBody(p) else _armingBody(p),
              const Spacer(),
              if (isError) ...[
                ChunkyButton(
                  label: 'BACK TO GRID',
                  color: p.orange,
                  big: true,
                  sfxName: 'back',
                  onTap: widget.onAbort,
                ),
              ] else ...[
                Center(
                  child: GestureDetector(
                    onTap: () {
                      sfx.back();
                      widget.onAbort();
                    },
                    child: Padding(
                      padding: const EdgeInsets.all(8),
                      child: Text(
                        'CANCEL',
                        style: displayStyle(
                          size: 13,
                          color: p.white,
                          letterSpacing: 1.6,
                          shadow: p.ink,
                          shadowDy: 1.5,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 6),
            ],
          ),
        );
      },
    );
  }

  Widget _armingBody(ThrotlPalette p) {
    final note = widget.engine.armNote ?? 'Preparing your ride…';
    return Column(
      children: [
        SizedBox(
          width: 54,
          height: 54,
          child: CircularProgressIndicator(strokeWidth: 5, color: p.white),
        ),
        const SizedBox(height: 22),
        Text(
          note,
          textAlign: TextAlign.center,
          style: displayStyle(size: 17, color: p.white, shadow: p.ink, shadowDy: 2),
        ),
        const SizedBox(height: 16),
        ChunkyCard(
          color: const Color(0xFFFFF1D6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                "WHAT YOU'RE SIGNING",
                style: displayStyle(
                  size: 11,
                  color: shade(p.ink, 0.25),
                  letterSpacing: 1.1,
                  shadowDy: 0,
                  shadow: const Color(0x00000000),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'One transaction opens your ride session (init + delegate) and hands '
                'tick-streaming to the rollup. After this your scoped session key streams '
                'ticks gaslessly — no more wallet popups until you settle.',
                style: bodyStyle(size: 11.5, color: shade(p.ink, 0.2), height: 1.5),
              ),
            ],
          ),
        ),
        if (_slow) ...[
          const SizedBox(height: 12),
          Text(
            'Mainnet RPC can be slow — hang tight, or cancel and retry.',
            textAlign: TextAlign.center,
            style: bodyStyle(size: 11, color: p.white, weight: FontWeight.w800).copyWith(
              shadows: [Shadow(color: p.ink, offset: const Offset(0, 1.5))],
            ),
          ),
        ],
      ],
    );
  }

  Widget _errorBody(ThrotlPalette p) {
    return ChunkyCard(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.error, color: p.redDeep, size: 24),
              const SizedBox(width: 8),
              Text(
                "Couldn't arm the ride",
                style: displayStyle(
                  size: 16,
                  color: p.redDeep,
                  shadowDy: 0,
                  shadow: const Color(0x00000000),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            widget.engine.error ?? 'Unknown error.',
            style: bodyStyle(size: 12, color: shade(p.ink, 0.25), height: 1.45),
          ),
        ],
      ),
    );
  }
}
