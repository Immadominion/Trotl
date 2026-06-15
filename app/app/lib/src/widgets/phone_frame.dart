import 'package:flutter/widgets.dart';

/// On a phone the app is full-bleed; on a wide screen (web/desktop demo) the
/// cockpit is rendered at its **native portrait size** and scaled uniformly to
/// fit inside a device bezel.
///
/// WHY scale instead of reflow: the cockpit is a hand-tuned portrait layout (the
/// gamification lives in those exact proportions). Reflowing it for desktop would
/// shred the game feel; pinning a fixed bezel would clip it on any laptop shorter
/// than the device height. So we lay the game out ONCE at [_w]×[_h] and
/// [FittedBox]-scale the whole bezel to whatever space is available — always fully
/// visible, always pixel-correct, never distorted, on a phone-web tab, a short
/// laptop, or a 4K monitor alike. [MediaQuery] is overridden to the frame size so
/// every screen's `MediaQuery.size` reads the device, not the browser window.
class PhoneFrame extends StatelessWidget {
  const PhoneFrame({required this.child, super.key});

  final Widget child;

  /// Logical device size the cockpit is designed against (a tall phone).
  static const double _w = 402;
  static const double _h = 874;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // A real phone (or a narrow phone-web tab) already IS portrait — full-bleed.
        final wide = constraints.maxWidth > 520;
        if (!wide) return child;

        final media = MediaQuery.of(context);
        return ColoredBox(
          color: const Color(0xFF15131F),
          child: Center(
            child: Padding(
              // Breathing room so the bezel never kisses the window edges.
              padding: const EdgeInsets.all(20),
              child: FittedBox(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: const Color(0xFF0D163A),
                    borderRadius: BorderRadius.circular(46),
                    border: Border.all(width: 7, color: const Color(0xFF050409)),
                    boxShadow: const [
                      BoxShadow(color: Color(0x99000000), blurRadius: 48, spreadRadius: 6),
                    ],
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(40),
                    child: SizedBox(
                      width: _w,
                      height: _h,
                      // The cockpit must SEE the device size, not the browser window,
                      // or MediaQuery-based layouts (sheets, coachmarks) mis-measure.
                      child: MediaQuery(
                        data: media.copyWith(
                          size: const Size(_w, _h),
                          padding: EdgeInsets.zero,
                          viewPadding: EdgeInsets.zero,
                          viewInsets: EdgeInsets.zero,
                        ),
                        child: child,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
