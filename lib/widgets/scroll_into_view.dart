import 'package:flutter/material.dart';

/// Scrolls itself into view once, right after it is first built — wrapped
/// around a row/card that just started glowing (a search reveal or an
/// internal-link landing), so the highlighted target is actually on screen in
/// a long list. Key it by the glow target so a re-reveal re-triggers.
class ScrollIntoViewOnce extends StatefulWidget {
  final Widget child;
  const ScrollIntoViewOnce({super.key, required this.child});

  @override
  State<ScrollIntoViewOnce> createState() => _ScrollIntoViewOnceState();
}

class _ScrollIntoViewOnceState extends State<ScrollIntoViewOnce> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _revealVertically();
    });
  }

  /// Bring the row into view by scrolling **only the nearest vertical
  /// scrollable** — never any horizontal ancestor.
  ///
  /// `Scrollable.ensureVisible(context)` walks up and scrolls *every* enclosing
  /// `Scrollable`. On mobile each shell tab is nested inside a horizontal
  /// `PageView`, so that default would also command the PageView to reposition
  /// toward the row (via `position.ensureVisible → animateTo`, which the shell's
  /// physics lock cannot block — physics only gates user drags, not programmatic
  /// scrolls), dragging the whole shell sideways onto the adjacent Graph tab.
  /// Scoping to the vertical list keeps the reveal where it belongs and removes
  /// the sideways drift at its source.
  void _revealVertically() {
    final target = context.findRenderObject();
    if (target == null) return;
    BuildContext ctx = context;
    ScrollableState? scrollable = Scrollable.maybeOf(ctx);
    while (scrollable != null) {
      final axis = scrollable.position.axis;
      if (axis == Axis.vertical) {
        scrollable.position.ensureVisible(
          target,
          alignment: 0.35, // land a bit above centre, comfortable to spot
          duration: const Duration(milliseconds: 320),
          curve: Curves.easeOutCubic,
        );
        return; // one vertical list is enough; never reach the outer PageView
      }
      // A horizontal scrollable (the tab PageView): stop before disturbing it.
      if (axis == Axis.horizontal) return;
      ctx = scrollable.context;
      scrollable = Scrollable.maybeOf(ctx);
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
