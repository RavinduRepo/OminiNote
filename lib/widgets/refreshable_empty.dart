import 'package:flutter/material.dart';

/// Wraps a non-scrolling child (an empty-state placeholder) in an
/// always-scrollable viewport, so a [RefreshIndicator] above it can still be
/// pulled when there's no list to scroll.
class RefreshableEmpty extends StatelessWidget {
  final Widget child;

  const RefreshableEmpty({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: constraints.maxHeight),
          child: child,
        ),
      ),
    );
  }
}
