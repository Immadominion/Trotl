import 'package:flutter/widgets.dart';

/// Breakpoints + helpers so screens adapt consistently. The cutoffs match
/// `GameScaffold`'s content cap: phones stay portrait; from [wideBreakpoint] up
/// (iPad landscape, desktop) screens switch to a landscape two-pane / grid layout
/// that actually uses the horizontal space.
const double wideBreakpoint = 900;
const double tabletBreakpoint = 600;

extension ResponsiveContext on BuildContext {
  Size get _mq => MediaQuery.sizeOf(this);

  /// Enough horizontal room for a landscape two-pane layout (iPad landscape,
  /// desktop) — vs a phone or a portrait tablet.
  bool get isWide => _mq.width >= wideBreakpoint;

  /// A roomy screen (tablet+), where content can breathe even in portrait.
  bool get isTablet => _mq.width >= tabletBreakpoint;

  double get screenW => _mq.width;
  double get screenH => _mq.height;
}

/// A responsive split for wide screens: [primary] beside [secondary]. Use inside
/// an [Expanded]/bounded area so both panes fill the height.
class TwoPane extends StatelessWidget {
  const TwoPane({
    required this.primary,
    required this.secondary,
    this.primaryFlex = 3,
    this.secondaryFlex = 2,
    this.gap = 22,
    super.key,
  });

  final Widget primary;
  final Widget secondary;
  final int primaryFlex;
  final int secondaryFlex;
  final double gap;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(flex: primaryFlex, child: primary),
        SizedBox(width: gap),
        Expanded(flex: secondaryFlex, child: secondary),
      ],
    );
  }
}
