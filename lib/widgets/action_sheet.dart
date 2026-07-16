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

/// A styled mobile action sheet (the redesign's kebab menus): a floating,
/// rounded card sliding up from the bottom with a grab handle and a list of
/// icon+label actions. Tapping an item dismisses the sheet, then runs its
/// callback (after the pop, so any dialog it opens isn't dismissed with it).
Future<void> showActionSheet(
  BuildContext context, {
  required List<ActionSheetItem> items,
  String? title,
}) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withValues(alpha: 0.45),
    // Let the sheet grow to its content (capped + scrolled internally below);
    // without this the sheet is capped at ~half-screen and a long menu
    // overflows instead of scrolling.
    isScrollControlled: true,
    builder: (sheetContext) {
      final theme = Theme.of(sheetContext);
      final palette = theme.extension<AppPalette>()!;
      return SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
          child: Container(
            decoration: BoxDecoration(
              color: theme.colorScheme.surface,
              borderRadius: BorderRadius.circular(kRadius + 8),
              border: Border.all(color: palette.border),
            ),
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
                // Scrollable + height-capped so a long menu on a short screen
                // never overflows.
                ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: MediaQuery.of(sheetContext).size.height * 0.6,
                  ),
                  child: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (final item in items)
                          _SheetButton(item: item, palette: palette),
                      ],
                    ),
                  ),
                ),
              ],
            ),
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
