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
      Scrollable.ensureVisible(
        context,
        alignment: 0.35, // land a bit above centre, comfortable to spot
        duration: const Duration(milliseconds: 320),
        curve: Curves.easeOutCubic,
      );
    });
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
