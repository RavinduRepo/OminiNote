import 'package:flutter/material.dart';
import '../../canvas/canvas_controller.dart';
import '../../theme/app_theme.dart';
import 'canvas_chrome_shared.dart';
import 'tool_option_rows.dart';

/// The lasso tool's selection actions, floating near the current selection
/// instead of the old fixed top-of-canvas panel. Must be a `Positioned`
/// (direct child of the canvas `Stack`) since it repositions itself off
/// `selectionScreenRect` — screen-space coordinates already relative to that
/// same Stack.
///
/// Hides while the selection is actively being dragged/resized/rotated
/// (`isDraggingSelectionNotifier`) and reappears, repositioned, the moment
/// the gesture ends — deliberately not tracked live, so a drag never costs a
/// rebuild here (the position is only (re)computed at build time, which only
/// happens on an actual visibility-relevant notifier change).
class LassoFloatingMenu extends StatelessWidget {
  final CanvasController controller;

  const LassoFloatingMenu({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([
        controller.toolNotifier,
        controller.hasSelectionNotifier,
        controller.clipboardNotifier,
        controller.isDraggingSelectionNotifier,
      ]),
      builder: (context, _) {
        final show = controller.tool == CanvasTool.lasso &&
            (controller.selection.isNotEmpty ||
                CanvasController.clipboardHasContent) &&
            !controller.isDraggingSelectionNotifier.value;
        // Must resolve to a Positioned even when hidden: a non-positioned
        // child (e.g. SizedBox.shrink) added to the canvas Stack drives the
        // Stack — which the body Column does NOT stretch horizontally — to
        // that child's 0 width, collapsing the whole canvas to width 0.
        if (!show) {
          return const Positioned(
            left: 0,
            top: 0,
            child: SizedBox.shrink(),
          );
        }

        final palette = Theme.of(context).extension<AppPalette>()!;
        final rect = controller.selectionScreenRect;
        const menuHeight = 48.0;
        double top;
        double left;
        if (rect != null) {
          top = rect.top - menuHeight - 8;
          if (top < 0) top = rect.bottom + 8; // flip below if clipped at top
          left = rect.left < 8 ? 8.0 : rect.left;
        } else {
          // Clipboard-only (nothing selected, just a "Paste" offer) — no
          // selection rect to anchor to.
          top = 12;
          left = 12;
        }

        return Positioned(
          left: left,
          top: top,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 340),
            child: FloatingPanel(
              child: buildLassoActionRow(context, controller, palette),
            ),
          ),
        );
      },
    );
  }
}
