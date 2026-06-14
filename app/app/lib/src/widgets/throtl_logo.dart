import 'package:flutter/widgets.dart';

/// The Throtl swoosh mark, ported from the design's `THROTTLE_LOGO_PATH`
/// (viewBox 240×150). Brand-neutral wing — reused as-is for Throtl.
class ThrotlLogo extends StatelessWidget {
  const ThrotlLogo({this.size = 28, this.color = const Color(0xFFFFFFFF), super.key});

  /// Width; height is `size * 0.625` (the 240×150 aspect).
  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: Size(size, size * 0.625),
      painter: _LogoPainter(color),
    );
  }
}

class _LogoPainter extends CustomPainter {
  _LogoPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..moveTo(12, 30)
      ..cubicTo(56, 62, 88, 68, 120, 68)
      ..cubicTo(152, 68, 184, 62, 228, 30)
      ..cubicTo(198, 60, 164, 72, 140, 92)
      ..cubicTo(129, 101, 124, 108, 120, 120)
      ..cubicTo(116, 108, 111, 101, 100, 92)
      ..cubicTo(76, 72, 42, 60, 12, 30)
      ..close();
    canvas
      ..scale(size.width / 240, size.height / 150)
      ..drawPath(path, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_LogoPainter oldDelegate) => oldDelegate.color != color;
}
