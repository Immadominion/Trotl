import 'package:flutter/widgets.dart';

/// On a phone the app is full-bleed; on a wide screen (web/desktop demo) it's
/// framed inside a portrait device bezel so the mobile layout reads correctly.
class PhoneFrame extends StatelessWidget {
  const PhoneFrame({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth > 520;
        if (!wide) return child;
        return ColoredBox(
          color: const Color(0xFF15131F),
          child: Center(
            child: Container(
              width: 402,
              height: 874,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(42),
                border: Border.all(width: 6),
                boxShadow: const [
                  BoxShadow(
                    color: Color(0x80000000),
                    blurRadius: 40,
                    spreadRadius: 4,
                  ),
                ],
              ),
              clipBehavior: Clip.antiAlias,
              child: child,
            ),
          ),
        );
      },
    );
  }
}
