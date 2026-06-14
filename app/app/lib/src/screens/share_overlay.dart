import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:throtl/src/audio/sfx.dart';
import 'package:throtl/src/engine/ride_controller.dart';
import 'package:throtl/src/theme/tokens.dart';
import 'package:throtl/src/util/format.dart';
import 'package:throtl/src/widgets/car_sprite.dart';
import 'package:throtl/src/widgets/chunky.dart';
import 'package:throtl/src/widgets/throtl_logo.dart';

/// In-app share overlay shown over Results — a large legible receipt + share
/// actions. Ports the design's `GShareOverlay`. The on-screen preview is the
/// portrait [ReceiptStub] (big enough to read); the exported social artifact is
/// the 1080×1080 landscape [ShareCard].
class ShareOverlay extends StatefulWidget {
  const ShareOverlay({
    required this.win,
    required this.stats,
    required this.carAsset,
    required this.tint,
    required this.onClose,
    super.key,
  });

  final bool win;
  final SessionStats stats;
  final String carAsset;
  final Color tint;
  final VoidCallback onClose;

  @override
  State<ShareOverlay> createState() => _ShareOverlayState();
}

class _ShareOverlayState extends State<ShareOverlay> {
  String? _toast;
  Timer? _toastT;

  String get _caption => widget.win
      ? 'Just banked ${fmtMoney6(widget.stats.realized6)} on @throtlHQ 🏁 held '
            'SOL-PERP in my hand — the chart is the track. Race at throtl.fun'
      : 'Flicked the eject on @throtlHQ — flattened in one tick, no liquidation '
            '🛟 your thumb is the stop-loss. Race at throtl.fun';

  void _flash(String msg) {
    setState(() => _toast = msg);
    _toastT?.cancel();
    _toastT = Timer(const Duration(milliseconds: 1600), () {
      if (mounted) setState(() => _toast = null);
    });
  }

  Future<void> _copy(String msg) async {
    await Clipboard.setData(ClipboardData(text: _caption));
    sfx.notify();
    _flash(msg);
  }

  @override
  void dispose() {
    _toastT?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    // Fill the available width (clamped) so the receipt reads large on a phone
    // yet never overflows on a narrow or very wide screen.
    final cardW = (MediaQuery.sizeOf(context).width - 40).clamp(280.0, 460.0);
    return ColoredBox(
      color: const Color(0xD1080A12),
      child: Material(
        type: MaterialType.transparency,
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 22),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'SHARE YOUR RECEIPT',
                  style: displayStyle(size: 20, color: p.white, letterSpacing: 1.6).copyWith(
                    shadows: [Shadow(color: p.ink, offset: const Offset(0, 2))],
                  ),
                ),
                const SizedBox(height: 16),
                // big, legible portrait receipt
                SizedBox(
                  width: cardW,
                  height: cardW * ReceiptStub.kHeight / ReceiptStub.kWidth,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(24),
                      boxShadow: [BoxShadow(color: p.ink, offset: const Offset(0, 10))],
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(24),
                      child: FittedBox(
                        child: SizedBox(
                          width: ReceiptStub.kWidth,
                          height: ReceiptStub.kHeight,
                          child: ReceiptStub(win: widget.win, stats: widget.stats),
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 18),
                SizedBox(
                  width: cardW,
                  child: Row(
                    children: [
                      Expanded(
                        child: ChunkyButton(
                          label: 'SHARE TO X',
                          color: p.cyan,
                          sfxName: 'confirm',
                          onTap: () => _copy('Caption copied — paste into X'),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: ChunkyButton(
                          label: 'COPY CAPTION',
                          color: p.green,
                          sfxName: 'open',
                          onTap: () => _copy('Caption copied'),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                SizedBox(
                  width: cardW,
                  child: ChunkyButton(
                    label: 'DONE',
                    color: p.purple,
                    sfxName: 'back',
                    onTap: widget.onClose,
                  ),
                ),
                if (_toast != null) ...[
                  const SizedBox(height: 14),
                  ChunkyToast(text: _toast!),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The cream receipt stub — stamp, the big realized number, the streamed-stat
/// rows, the onchain-proof block + QR. Designed in a 660×980 portrait box; shown
/// large on-screen and reused (constrained narrower) inside [ShareCard].
class ReceiptStub extends StatelessWidget {
  const ReceiptStub({required this.win, required this.stats, super.key});

  /// Native design size of the standalone portrait receipt.
  static const double kWidth = 660;
  static const double kHeight = 980;

  final bool win;
  final SessionStats stats;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final accent = win ? p.green : p.red;
    final accentDeep = win ? p.greenDeep : p.redDeep;
    final stamp = win ? 'WIN' : 'EJECT';
    final pct = stats.realized6 / (250 * 1000000) * 100;
    final secs = (stats.ticks * 0.18).clamp(0, 599).round();
    final time =
        '${(secs ~/ 60).toString().padLeft(2, '0')}:'
        '${(secs % 60).toString().padLeft(2, '0')}';

    return Container(
      padding: const EdgeInsets.fromLTRB(44, 40, 44, 36),
      decoration: BoxDecoration(
        color: p.cream,
        border: Border.all(color: p.ink, width: 5),
        borderRadius: BorderRadius.circular(26),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
                decoration: BoxDecoration(
                  color: accent,
                  border: Border.all(color: p.ink, width: 3),
                  borderRadius: BorderRadius.circular(100),
                ),
                child: Text(
                  win ? 'SETTLED ✓' : 'FLATTENED ✓',
                  style: displayStyle(size: 19, color: p.white).copyWith(shadows: const []),
                ),
              ),
              Text(
                'RACE RECEIPT\nSOL-PERP SPEEDWAY',
                textAlign: TextAlign.right,
                style: bodyStyle(size: 17, color: p.inkSoft, weight: FontWeight.w800),
              ),
            ],
          ),
          const SizedBox(height: 26),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Transform(
                transform: Matrix4.skewX(-0.12),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 5),
                  decoration: BoxDecoration(
                    gradient: candy(accent),
                    border: Border.all(color: p.ink, width: 4),
                    borderRadius: BorderRadius.circular(14),
                    boxShadow: [BoxShadow(color: p.ink, offset: const Offset(0, 5))],
                  ),
                  child: Transform(
                    transform: Matrix4.skewX(0.12),
                    child: Text(
                      stamp,
                      style: displayStyle(
                        size: 36,
                        color: p.white,
                        shadowDy: 3,
                      ).copyWith(shadows: const []),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 16),
              Flexible(
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Text(
                      '${pct >= 0 ? '+' : '−'}${pct.abs().toStringAsFixed(1)}% · '
                      '${stats.peakLev.toStringAsFixed(1)}× peak',
                      style: bodyStyle(size: 20, color: p.inkSoft, weight: FontWeight.w800),
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              fmtMoney6(stats.realized6),
              style: displayStyle(size: 110, color: accentDeep).copyWith(shadows: const []),
            ),
          ),
          Text(
            'realized · settled self-custodial on Flash Trade',
            style: bodyStyle(size: 18, color: p.inkSoft, weight: FontWeight.w800),
          ),
          const SizedBox(height: 22),
          for (final row in [
            ('TICKS STREAMED', groupInt(stats.ticks)),
            ('BEST COMBO', '×${stats.bestStreak}'),
            ('PEAK BOOST', '${stats.peakLev.toStringAsFixed(1)}×'),
            ('TIME IN SEAT', time),
            ('WIN RATE', '${stats.winRate}%'),
          ])
            Padding(
              padding: const EdgeInsets.only(bottom: 14),
              child: Row(
                children: [
                  Text(
                    row.$1,
                    style: bodyStyle(size: 19, color: p.inkSoft, weight: FontWeight.w800),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Container(height: 2, color: shade(p.ink, 0.55)),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    row.$2,
                    style: displayStyle(size: 23, color: p.ink).copyWith(shadows: const []),
                  ),
                ],
              ),
            ),
          const Spacer(),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'ONCHAIN PROOF · MAGICBLOCK ER',
                      style: bodyStyle(
                        size: 15,
                        color: p.inkSoft,
                        weight: FontWeight.w800,
                        letterSpacing: 1,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      win ? '5gKx9…fQz4' : '5gKx2…xW9d',
                      style: displayStyle(size: 19, color: p.ink).copyWith(shadows: const []),
                    ),
                    const SizedBox(height: 12),
                    SizedBox(
                      width: 280,
                      height: 44,
                      child: CustomPaint(painter: _BarcodePainter(p.ink)),
                    ),
                    const SizedBox(height: 14),
                    Text(
                      'throtl.fun',
                      style: displayStyle(
                        size: 26,
                        color: accentDeep,
                        letterSpacing: 1,
                      ).copyWith(shadows: const []),
                    ),
                    Text(
                      '@throtlHQ · race the chart',
                      style: bodyStyle(size: 16, color: p.inkSoft, weight: FontWeight.w800),
                    ),
                  ],
                ),
              ),
              Column(
                children: [
                  SizedBox(
                    width: 138,
                    height: 138,
                    child: CustomPaint(painter: _QrPainter(p.ink)),
                  ),
                  const SizedBox(height: 7),
                  Text(
                    'SCAN TO RACE',
                    style: displayStyle(
                      size: 14,
                      color: p.inkSoft,
                      letterSpacing: 1,
                    ).copyWith(shadows: const []),
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// The 1080×1080 shareable receipt — a cream stub on a themed speedway with the
/// car. Ports the design's `GShareCard` (rebranded). Render scaled via FittedBox.
class ShareCard extends StatelessWidget {
  const ShareCard({
    required this.win,
    required this.stats,
    required this.carAsset,
    required this.tint,
    super.key,
  });

  final bool win;
  final SessionStats stats;
  final String carAsset;
  final Color tint;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final head = win ? 'DIAMOND THUMBS.' : 'EJECTED. STILL STANDING.';
    final sub = win
        ? 'Held SOL-PERP in my hand and banked it — no order book, just my thumb.'
        : 'Flicked the throttle, flattened in one tick. No liquidation. Lived to trade again.';

    return SizedBox(
      width: 1080,
      height: 1080,
      child: Stack(
        children: [
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [p.blueTop, p.blueBot, p.blueDeep],
                  stops: const [0, 0.55, 1],
                ),
              ),
            ),
          ),
          // bottom kerb
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            height: 26,
            child: CustomPaint(painter: _KerbPainter(p.ink)),
          ),
          // LEFT — brand + car + positioning
          Positioned(
            left: 64,
            top: 64,
            bottom: 64,
            width: 392,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    ThrotlLogo(size: 56, color: p.white),
                    const SizedBox(width: 14),
                    StrokeText(
                      'THROTL',
                      strokeColor: p.ink,
                      style: displayStyle(size: 40, color: p.white, letterSpacing: 4),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
                  decoration: BoxDecoration(
                    color: p.yellow,
                    border: Border.all(color: p.ink, width: 3),
                    borderRadius: BorderRadius.circular(10),
                    boxShadow: [BoxShadow(color: p.ink, offset: const Offset(0, 4))],
                  ),
                  child: Text(
                    'THE FIRST ANALOG EXCHANGE',
                    style: displayStyle(
                      size: 15,
                      color: p.ink,
                      letterSpacing: 1.5,
                    ).copyWith(shadows: const []),
                  ),
                ),
                Expanded(
                  child: Center(
                    child: CarSprite(asset: carAsset, tint: tint, height: 320),
                  ),
                ),
                StrokeText(
                  head,
                  strokeColor: p.ink,
                  style: displayStyle(size: 46, color: p.white, shadowDy: 5),
                ),
                const SizedBox(height: 14),
                Text(
                  sub,
                  style:
                      bodyStyle(
                        size: 19,
                        color: const Color(0xF2FFFFFF),
                        weight: FontWeight.w800,
                      ).copyWith(
                        shadows: [Shadow(color: p.ink, offset: const Offset(0, 2))],
                      ),
                ),
              ],
            ),
          ),
          // RIGHT — the receipt stub (native 660×980, scaled to fit the slot)
          Positioned(
            right: 64,
            top: 84,
            bottom: 84,
            width: 484,
            child: FittedBox(
              child: SizedBox(
                width: ReceiptStub.kWidth,
                height: ReceiptStub.kHeight,
                child: ReceiptStub(win: win, stats: stats),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _KerbPainter extends CustomPainter {
  _KerbPainter(this.ink);
  final Color ink;

  @override
  void paint(Canvas canvas, Size size) {
    const seg = 30.0;
    for (var x = 0.0; x < size.width; x += seg * 2) {
      canvas
        ..drawRect(Rect.fromLTWH(x, 0, seg, size.height), Paint()..color = const Color(0xFFE0414C))
        ..drawRect(
          Rect.fromLTWH(x + seg, 0, seg, size.height),
          Paint()..color = const Color(0xFFF3EFE6),
        );
    }
    canvas.drawLine(
      Offset.zero,
      Offset(size.width, 0),
      Paint()
        ..color = ink
        ..strokeWidth = 5,
    );
  }

  @override
  bool shouldRepaint(_KerbPainter oldDelegate) => false;
}

class _BarcodePainter extends CustomPainter {
  _BarcodePainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    var x = 0.0;
    var seed = 7;
    final paint = Paint()..color = color;
    while (x < size.width) {
      seed = (seed * 1103515245 + 12345) & 0x7fffffff;
      final bw = 1.0 + seed % 4;
      final gap = 1.0 + (seed >> 3) % 3;
      canvas.drawRect(Rect.fromLTWH(x, 0, bw, size.height), paint);
      x += bw + gap;
    }
  }

  @override
  bool shouldRepaint(_BarcodePainter oldDelegate) => false;
}

class _QrPainter extends CustomPainter {
  _QrPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    const m = 11;
    final cell = size.width / m;
    final paint = Paint()..color = color;
    canvas.drawRRect(
      RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(8)),
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3,
    );
    bool on(int r, int c) {
      bool finder(int rr, int cc) => rr < 3 && cc < 3;
      if (finder(r, c) || finder(r, m - 1 - c) || finder(m - 1 - r, c)) {
        return r == 0 || r == 2 || c == 0 || c == 2 || (r == 1 && c == 1);
      }
      return (r * 7 + c * 13 + r * c * 3) % 5 < 2;
    }

    for (var r = 0; r < m; r++) {
      for (var c = 0; c < m; c++) {
        if (on(r, c)) {
          canvas.drawRect(
            Rect.fromLTWH(c * cell, r * cell, cell + 0.5, cell + 0.5),
            paint,
          );
        }
      }
    }
  }

  @override
  bool shouldRepaint(_QrPainter oldDelegate) => false;
}
