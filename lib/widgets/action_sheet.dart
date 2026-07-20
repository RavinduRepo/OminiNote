import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

/// Fraction of the screen height a modal bottom sheet may grow to before its
/// content scrolls — keeps sheets bottom-anchored (not full-screen) while
/// still fitting short screens. Pair the helpers below with
/// `showModalBottomSheet(isScrollControlled: true, ...)`.
const double kSheetMaxHeightFactor = 0.9;

/// Wraps fixed (non-list) modal-sheet [child] so it scrolls instead of
/// overflowing on short screens: SafeArea + a height cap + a scroll view.
Widget scrollableSheetBody(BuildContext context, {required Widget child}) {
  return SafeArea(
    child: ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * kSheetMaxHeightFactor,
      ),
      child: SingleChildScrollView(child: child),
    ),
  );
}

/// Like [scrollableSheetBody] but for sheets that already own a scrollable
/// (e.g. a `Flexible` + `ListView`): SafeArea + a height cap, no outer scroll
/// view (which would fight the inner one).
Widget cappedSheetBody(BuildContext context, {required Widget child}) {
  return SafeArea(
    child: ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * kSheetMaxHeightFactor,
      ),
      child: child,
    ),
  );
}

/// Shows [builder]'s content as a **bottom sheet on mobile**, or a **top-right
/// dropdown panel on desktop** — so desktop menus "drop" from the top like the
/// ⋯ overflow menu instead of sliding up from the bottom (the bottom-sheet look
/// felt out of place with a mouse). [desktop] defaults to a width heuristic
/// (≥840, matching the app's auto-layout breakpoint); pass it explicitly where
/// a more precise signal exists (e.g. `CanvasScreen.embedded`). Mirrors
/// [showModalBottomSheet]'s `Future<T?>` — the builder's context is under the
/// route either way, so its `Navigator.pop(context, value)` works unchanged.
Future<T?> showAdaptiveMenu<T>(
  BuildContext context, {
  required WidgetBuilder builder,
  bool? desktop,
}) {
  final isDesktop = desktop ?? MediaQuery.of(context).size.width >= 840;
  if (!isDesktop) {
    return showModalBottomSheet<T>(
      context: context,
      isScrollControlled: true,
      builder: builder,
    );
  }
  final theme = Theme.of(context);
  final palette = theme.extension<AppPalette>()!;
  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: true,
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    barrierColor: Colors.black.withValues(alpha: 0.06),
    transitionDuration: const Duration(milliseconds: 150),
    pageBuilder: (ctx, _, _) {
      final h = MediaQuery.of(ctx).size.height;
      return SafeArea(
        child: Align(
          alignment: Alignment.topRight,
          child: Padding(
            padding: const EdgeInsets.only(top: 54, right: 12),
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: 380, maxHeight: h * 0.82),
              child: Material(
                color: theme.colorScheme.surface,
                elevation: 8,
                clipBehavior: Clip.antiAlias,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(kRadius + 2),
                  side: BorderSide(color: palette.border),
                ),
                child: builder(ctx),
              ),
            ),
          ),
        ),
      );
    },
    transitionBuilder: (ctx, anim, _, child) {
      final curved = CurvedAnimation(parent: anim, curve: Curves.easeOutCubic);
      return FadeTransition(
        opacity: curved,
        child: ScaleTransition(
          alignment: Alignment.topRight,
          scale: Tween<double>(begin: 0.97, end: 1.0).animate(curved),
          child: child,
        ),
      );
    },
  );
}

/// A [PopupMenuItem] with a leading icon (desktop menus, to match the mobile
/// action sheets). Pass [color] (e.g. the theme error color) to tint a
/// destructive item.
PopupMenuItem<String> iconMenuItem(
  String value,
  IconData icon,
  String label, {
  Color? color,
}) {
  return PopupMenuItem<String>(
    value: value,
    child: Row(
      children: [
        Icon(icon, size: 18, color: color),
        const SizedBox(width: 10),
        Text(label, style: color == null ? null : TextStyle(color: color)),
      ],
    ),
  );
}

/// One row in an [showActionSheet]. [destructive] renders it in the error color.
class ActionSheetItem {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool destructive;

  const ActionSheetItem({
    required this.icon,
    required this.label,
    required this.onTap,
    this.destructive = false,
  });
}

/// A styled mobile action sheet (the redesign's kebab menus): a bottom sheet
/// with a grab handle and a list of icon+label actions. It renders as a plain
/// edge-to-edge sheet using the theme's own background + shape — the SAME look
/// as the "+" (Add) sheet and every other modal sheet — so there's a single
/// sheet outline, not the floating-card-inside-a-sheet double border it used
/// to draw. Tapping an item dismisses the sheet, then runs its callback (after
/// the pop, so any dialog it opens isn't dismissed with it).
Future<void> showActionSheet(
  BuildContext context, {
  required List<ActionSheetItem> items,
  String? title,
}) {
  return showModalBottomSheet<void>(
    context: context,
    // Let the sheet grow to its content (capped + scrolled internally below);
    // without this the sheet is capped at ~half-screen and a long menu
    // overflows instead of scrolling.
    isScrollControlled: true,
    builder: (sheetContext) {
      final palette = Theme.of(sheetContext).extension<AppPalette>()!;
      return scrollableSheetBody(
        sheetContext,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 10),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  margin: const EdgeInsets.only(top: 2, bottom: 8),
                  decoration: BoxDecoration(
                    color: palette.border,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              if (title != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 2, 12, 8),
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      color: palette.textDim,
                    ),
                  ),
                ),
              for (final item in items)
                _SheetButton(item: item, palette: palette),
            ],
          ),
        ),
      );
    },
  );
}

class _SheetButton extends StatelessWidget {
  final ActionSheetItem item;
  final AppPalette palette;

  const _SheetButton({required this.item, required this.palette});

  @override
  Widget build(BuildContext context) {
    final color = item.destructive
        ? Theme.of(context).colorScheme.error
        : Theme.of(context).colorScheme.onSurface;
    return InkWell(
      onTap: () {
        Navigator.of(context).pop();
        item.onTap();
      },
      borderRadius: BorderRadius.circular(kRadius),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 12),
        child: Row(
          children: [
            Icon(item.icon,
                size: 20, color: item.destructive ? color : palette.textDim),
            const SizedBox(width: 14),
            Text(item.label, style: TextStyle(fontSize: 15, color: color)),
          ],
        ),
      ),
    );
  }
}
