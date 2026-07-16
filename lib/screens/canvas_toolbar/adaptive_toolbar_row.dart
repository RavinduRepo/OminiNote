import 'package:flutter/material.dart';

/// A horizontal cluster of toolbar buttons that **right-aligns** when it fits
/// the available width, and falls back to a horizontal scroll when it
/// doesn't — no width estimation.
///
/// A `ConstrainedBox(minWidth: viewport)` forces the content region to be at
/// least the viewport width, and an explicit `Align(centerRight)` pins the
/// (shrink-wrapped) button row to the right edge of that region. When the
/// buttons fit, they hug the right; when they overflow, the region grows past
/// the viewport and the `SingleChildScrollView` scrolls.
class AdaptiveToolbarRow extends StatelessWidget {
  final List<Widget> children;

  const AdaptiveToolbarRow({super.key, required this.children});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          reverse: true, // overflow keeps the trailing (most-used) end in view
          child: ConstrainedBox(
            constraints: BoxConstraints(minWidth: constraints.maxWidth),
            child: Align(
              alignment: Alignment.centerRight,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: children,
              ),
            ),
          ),
        );
      },
    );
  }
}
