import 'package:flutter/material.dart';
import '../../canvas/canvas_controller.dart';
import '../../services/settings_service.dart';
import '../../theme/app_theme.dart';
import 'canvas_chrome_shared.dart';
import 'tool_option_rows.dart';

/// The 4 tool-kinds that get an options popover (pen/highlighter share one
/// content row; shape and eraser have their own). Lasso and text get their
/// own dedicated floating menu / bottom bar instead.
const List<CanvasTool> kPopoverToolKinds = [
  CanvasTool.pen,
  CanvasTool.highlighter,
  CanvasTool.shape,
  CanvasTool.eraser,
];

/// The pen/highlighter/shape/eraser options as a floating card that drops
/// down just under the active tool's icon when you re-tap the already-active
/// tool (`toolOptionsOpen`), or stays open whenever a **pinned** tool is
/// active. Rendered as a plain `Positioned` child of the canvas `Stack`
/// (same layer as the lasso menu / text bar) — deliberately NOT a
/// `CompositedTransformFollower`/`OverlayEntry`, which threw
/// RenderFollowerLayer transform errors and mis-positioned off-screen.
///
/// Always resolves to a `Positioned` (an empty one when hidden) so it can't
/// collapse the Stack to width 0 — see LassoFloatingMenu for that guard.
class ToolOptionsPopover extends StatefulWidget {
  final CanvasController controller;

  const ToolOptionsPopover({super.key, required this.controller});

  @override
  State<ToolOptionsPopover> createState() => _ToolOptionsPopoverState();
}

class _ToolOptionsPopoverState extends State<ToolOptionsPopover> {
  late Set<String> _pinned;

  // Mirrors _CanvasToolbar's layout: 12px left pad + each tool cell is a
  // 40px icon in 2px horizontal padding = 44px. Used to anchor the card
  // roughly under the active tool's icon.
  static const double _toolbarLeftPad = 12.0;
  static const double _toolCell = 44.0;

  @override
  void initState() {
    super.initState();
    _pinned = Set.of(SettingsService().pinnedToolOptionPopovers);
  }

  void _togglePin(CanvasTool kind) {
    final key = kind.name;
    setState(() {
      if (_pinned.contains(key)) {
        _pinned.remove(key);
      } else {
        _pinned.add(key);
      }
    });
    SettingsService().setToolOptionPopoverPinned(key, _pinned.contains(key));
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    return ListenableBuilder(
      listenable: Listenable.merge([
        c.toolNotifier,
        c.toolOptionsOpenNotifier,
        c.chromeContentTick,
      ]),
      builder: (context, _) {
        final kind = c.tool;
        final isPopoverKind = kPopoverToolKinds.contains(kind);
        final pinned = _pinned.contains(kind.name);
        final show = isPopoverKind && (c.toolOptionsOpen || pinned);
        if (!show) {
          return const Positioned(left: 0, top: 0, child: SizedBox.shrink());
        }

        final theme = Theme.of(context);
        final palette = theme.extension<AppPalette>()!;
        final screenW = MediaQuery.of(context).size.width;

        // Anchor under the active tool's icon, then clamp on-screen and cap
        // the width so it never runs off the right edge.
        final index = kCanvasToolOrder.indexOf(kind);
        double left = _toolbarLeftPad + index * _toolCell - 12;
        left = left.clamp(8.0, screenW - 120);
        final maxW = (screenW - left - 8).clamp(140.0, 360.0);

        final row = switch (kind) {
          CanvasTool.pen ||
          CanvasTool.highlighter => buildPenOptionsRow(context, c, palette),
          CanvasTool.shape => buildShapeOptionsRow(context, c, palette),
          CanvasTool.eraser => buildEraserOptionsRow(context, c, palette),
          _ => const SizedBox.shrink(),
        };

        return Positioned(
          left: left,
          top: 4,
          // Swallow pointer-downs so a tap on the card (a swatch, a gap)
          // doesn't fall through to the canvas and close it.
          child: Listener(
            behavior: HitTestBehavior.opaque,
            onPointerDown: (_) {},
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: maxW),
              child: FloatingPanel(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    IconButton(
                      icon: Icon(
                        pinned ? Icons.push_pin : Icons.push_pin_outlined,
                        size: 16,
                      ),
                      tooltip: pinned
                          ? 'Unpin (options hide until you re-tap the tool)'
                          : 'Pin (keep options open while this tool is active)',
                      visualDensity: VisualDensity.compact,
                      constraints:
                          const BoxConstraints(minWidth: 28, minHeight: 28),
                      padding: EdgeInsets.zero,
                      onPressed: () => _togglePin(kind),
                    ),
                    row,
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
