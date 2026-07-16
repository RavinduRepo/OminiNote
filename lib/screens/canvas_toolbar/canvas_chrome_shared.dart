import 'package:flutter/material.dart';
import '../../canvas/canvas_controller.dart';
import '../../theme/app_theme.dart';

/// The 5 tools, in the order they're always presented.
const List<CanvasTool> kCanvasToolOrder = [
  CanvasTool.pen,
  CanvasTool.highlighter,
  CanvasTool.shape,
  CanvasTool.eraser,
  CanvasTool.lasso,
  CanvasTool.text,
];

IconData iconForTool(CanvasTool tool) => switch (tool) {
  CanvasTool.pen => Icons.draw_outlined,
  CanvasTool.highlighter => Icons.highlight_outlined,
  CanvasTool.shape => Icons.category_outlined,
  CanvasTool.eraser => Icons.auto_fix_normal_outlined,
  CanvasTool.lasso => Icons.gesture,
  CanvasTool.text => Icons.text_fields,
};

String labelForTool(CanvasTool tool) => switch (tool) {
  CanvasTool.pen => 'Pen',
  CanvasTool.highlighter => 'Highlighter',
  CanvasTool.shape => 'Shapes',
  CanvasTool.eraser => 'Eraser',
  CanvasTool.lasso => 'Lasso select',
  CanvasTool.text => 'Text',
};

/// [tbBtn]'s fixed width — kept as one constant so [AdaptiveToolbarRow]'s
/// arithmetic width estimate can't silently drift out of sync with it.
const double kTbBtnWidth = 38.0;

/// [tbDivider]'s fixed width (1px line + 6px margin on each side).
const double kTbDividerWidth = 13.0;

/// A compact toolbar icon button (used by the desktop app-bar toolbar row).
Widget tbBtn(IconData icon, String tooltip, VoidCallback? onPressed) =>
    IconButton(
      icon: Icon(icon, size: 20),
      tooltip: tooltip,
      visualDensity: VisualDensity.compact,
      constraints: const BoxConstraints(minWidth: kTbBtnWidth, minHeight: 44),
      padding: EdgeInsets.zero,
      onPressed: onPressed,
    );

/// A vertical divider between groups of toolbar buttons.
Widget tbDivider(AppPalette palette) => Container(
  width: 1,
  height: 20,
  margin: const EdgeInsets.symmetric(horizontal: 6),
  color: palette.border,
);

/// A single tool's tappable icon — used both in the normal toolbar's tool
/// row and the full-screen floating control (collapsed icon + picker row).
class ToolIconButton extends StatelessWidget {
  final CanvasTool tool;
  final bool active;
  final VoidCallback onTap;

  const ToolIconButton({
    super.key,
    required this.tool,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final palette = Theme.of(context).extension<AppPalette>()!;
    return Tooltip(
      message: labelForTool(tool),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(kRadius),
        child: Container(
          width: 40,
          height: 40,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: active ? palette.accentSoft : null,
            borderRadius: BorderRadius.circular(kRadius),
          ),
          child: Icon(
            iconForTool(tool),
            size: 20,
            color: active ? palette.accent : null,
          ),
        ),
      ),
    );
  }
}

/// Elevated, bordered container full-screen's floating controls sit in —
/// legible over any page content underneath.
class FloatingPanel extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;

  const FloatingPanel({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(8),
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = theme.extension<AppPalette>()!;
    return Material(
      color: theme.colorScheme.surface,
      elevation: 6,
      borderRadius: BorderRadius.circular(kRadius + 6),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(kRadius + 6),
          border: Border.all(color: palette.border),
        ),
        padding: padding,
        child: child,
      ),
    );
  }
}

/// A small floating action button used for full-screen's exit control.
class FloatingIconButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  const FloatingIconButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = theme.extension<AppPalette>()!;
    return FloatingPanel(
      padding: EdgeInsets.zero,
      child: Tooltip(
        message: tooltip,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(kRadius + 6),
          child: SizedBox(
            width: 40,
            height: 40,
            child: Icon(icon, size: 20, color: palette.textDim),
          ),
        ),
      ),
    );
  }
}
