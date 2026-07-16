import 'package:flutter/material.dart';
import '../../canvas/canvas_controller.dart';
import '../../theme/app_theme.dart';
import 'tool_option_rows.dart';

/// The text tool's style controls, pinned to the bottom of the screen as a
/// single scrollable line instead of the old fixed top-of-canvas panel.
/// Sits above the on-screen keyboard when one is showing, else at the
/// physical bottom of the screen — one rule (`viewInsets.bottom` vs.
/// `padding.bottom`) covers every platform without branching.
///
/// Visible only while actively editing a text box or one is lasso-selected
/// (`isEditingText || selectionIsTextOnly` — unchanged from the exception
/// clause `buildToolContextRow` always had). Retargeting from editing one
/// text box straight to another must never flicker this bar off and back on
/// — that's handled upstream in `_handleTextTap`'s commit-then-start pairing
/// (`canvas_screen.dart`), which keeps `isEditingTextNotifier` true across
/// the whole retarget within a single synchronous call; this widget just
/// needs to avoid its own re-keying (no `AnimatedSwitcher`/`ValueKey` tied to
/// which element is being edited — only the shown/hidden boolean matters).
class TextBottomBar extends StatelessWidget {
  final CanvasController controller;

  const TextBottomBar({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([
        controller.isEditingTextNotifier,
        controller.hasSelectionNotifier,
        controller.chromeContentTick,
      ]),
      builder: (context, _) {
        final show = controller.isEditingText || controller.selectionIsTextOnly;
        // Must resolve to a Positioned even when hidden — a non-positioned
        // child (SizedBox.shrink) in the canvas Stack collapses the Stack
        // (which the body Column doesn't stretch) to width 0, blanking the
        // whole canvas. See LassoFloatingMenu for the same guard.
        if (!show) {
          return const Positioned(
            left: 0,
            top: 0,
            child: SizedBox.shrink(),
          );
        }

        final theme = Theme.of(context);
        final palette = theme.extension<AppPalette>()!;
        final mq = MediaQuery.of(context);
        final bottom = mq.viewInsets.bottom > 0
            ? mq.viewInsets.bottom
            : mq.padding.bottom;

        return Positioned(
          left: 0,
          right: 0,
          bottom: bottom,
          child: Material(
            color: theme.colorScheme.surface,
            elevation: 6,
            child: Container(
              decoration: BoxDecoration(
                border: Border(top: BorderSide(color: palette.border)),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: buildTextStyleRow(context, controller, palette),
            ),
          ),
        );
      },
    );
  }
}
