import 'package:flutter/material.dart';

import '../models/canvas.dart';
import '../theme/app_theme.dart';
import '../widgets/action_sheet.dart';
import '../widgets/canvas_picker.dart';
import 'canvas_screen.dart';

/// How a new pane is added relative to the others.
enum SplitDir {
  /// Side by side (a vertical divider) — a `Row`.
  sideBySide,

  /// Stacked top/bottom (a horizontal divider) — a `Column`.
  stacked,
}

/// Asks the user which way to split, returning null if dismissed.
Future<SplitDir?> pickSplitDirection(BuildContext context) {
  return showModalBottomSheet<SplitDir>(
    context: context,
    isScrollControlled: true,
    builder: (context) => scrollableSheetBody(
      context,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 8),
          ListTile(
            leading: const Icon(Icons.vertical_split_outlined),
            title: const Text('Vertical split'),
            subtitle: const Text('Side by side'),
            onTap: () => Navigator.pop(context, SplitDir.sideBySide),
          ),
          ListTile(
            leading: const Icon(Icons.horizontal_split_outlined),
            title: const Text('Horizontal split'),
            subtitle: const Text('Top and bottom'),
            onTap: () => Navigator.pop(context, SplitDir.stacked),
          ),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );
}

/// Hosts one or more canvases in a single window (in-app split view). Reusable:
/// the mobile route ([CanvasWorkspaceScreen]) and the desktop shell's main pane
/// both use it.
///
/// With a **single** pane and [soloNonEmbedded] (mobile route) it renders the
/// ordinary non-embedded [CanvasScreen] — same toolbar, bottom-sheet menus and
/// back button as before. Adding a pane switches to a resizable Row/Column of
/// **embedded** canvases (per [SplitDir]), each with its own toolbar and a
/// close-pane button.
class CanvasWorkspace extends StatefulWidget {
  final Canvas initialCanvas;
  final String? initialPageId;

  /// Mobile route: the lone pane is the full non-embedded screen. Desktop: the
  /// lone pane is embedded (the shell provides surrounding chrome).
  final bool soloNonEmbedded;

  /// Called when the primary pane's back button is pressed (mobile pops the
  /// route). Null on desktop, where the shell owns navigation (no back arrow).
  final VoidCallback? onExit;

  /// Forwarded to every pane (desktop uses it to refresh its canvas list).
  final VoidCallback? onCanvasRenamed;

  /// Forwarded to every pane (desktop uses it to collapse its side panes).
  final ValueChanged<bool>? onFullScreenChanged;

  const CanvasWorkspace({
    super.key,
    required this.initialCanvas,
    this.initialPageId,
    this.soloNonEmbedded = false,
    this.onExit,
    this.onCanvasRenamed,
    this.onFullScreenChanged,
  });

  @override
  State<CanvasWorkspace> createState() => _CanvasWorkspaceState();
}

class _Pane {
  final Canvas canvas;
  final String? initialPageId;

  /// Relative size weight along the split axis; adjusted by dragging dividers.
  double flex = 1;

  _Pane(this.canvas, {this.initialPageId});
}

class _CanvasWorkspaceState extends State<CanvasWorkspace> {
  late final List<_Pane> _panes = [
    _Pane(widget.initialCanvas, initialPageId: widget.initialPageId),
  ];

  SplitDir _dir = SplitDir.sideBySide;

  /// A pane can't be dragged below this on-screen size along the split axis.
  static const double _minPaneExtent = 220;

  Future<void> _addPane(Canvas fromCanvas) async {
    final dir = await pickSplitDirection(context);
    if (dir == null || !mounted) return;
    final openIds = {for (final p in _panes) p.canvas.id};
    final canvas = await pickCanvasForPane(
      context,
      excludeIds: openIds,
      startNotebookId: fromCanvas.notebookId,
      startSectionId: fromCanvas.sectionId,
    );
    if (canvas == null || !mounted) return;
    // Two controllers on one canvas would fight over autosave + the id-keyed
    // sync-listener registry — never open the same canvas twice.
    if (openIds.contains(canvas.id)) return;
    setState(() {
      _dir = dir; // a differing pick flips the whole layout's axis
      _panes.add(_Pane(canvas));
    });
  }

  void _closePane(String canvasId) {
    setState(() => _panes.removeWhere((p) => p.canvas.id == canvasId));
  }

  void _resize(int leftIndex, double deltaPx, double extent) {
    if (extent <= 0) return;
    final totalFlex = _panes.fold<double>(0, (s, p) => s + p.flex);
    final minFlex = _minPaneExtent / extent * totalFlex;
    final deltaFlex = deltaPx / extent * totalFlex;
    final a = _panes[leftIndex], b = _panes[leftIndex + 1];
    final na = a.flex + deltaFlex, nb = b.flex - deltaFlex;
    if (na < minFlex || nb < minFlex) return;
    setState(() {
      a.flex = na;
      b.flex = nb;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_panes.length == 1) {
      return _paneScreen(0, embedded: !widget.soloNonEmbedded);
    }

    final palette = Theme.of(context).extension<AppPalette>()!;
    final layout = LayoutBuilder(
      builder: (context, constraints) {
        final horizontal = _dir == SplitDir.sideBySide;
        final extent =
            horizontal ? constraints.maxWidth : constraints.maxHeight;
        final children = <Widget>[];
        for (var i = 0; i < _panes.length; i++) {
          if (i > 0) children.add(_divider(i - 1, extent, palette, horizontal));
          children.add(Expanded(
            flex: (_panes[i].flex * 1000).round(),
            child: _paneScreen(i, embedded: true),
          ));
        }
        return horizontal
            ? Row(children: children)
            : Column(children: children);
      },
    );

    // Desktop embeds the layout directly; the mobile route owns a Scaffold +
    // back handling.
    if (!widget.soloNonEmbedded) return layout;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_panes.length > 1) {
          _closePane(_panes.last.canvas.id);
        } else {
          widget.onExit?.call();
        }
      },
      child: Scaffold(
        backgroundColor: palette.canvas,
        body: SafeArea(child: layout),
      ),
    );
  }

  Widget _paneScreen(int i, {required bool embedded}) {
    final pane = _panes[i];
    final multi = _panes.length > 1;
    return CanvasScreen(
      key: ValueKey('pane-${pane.canvas.id}'),
      canvas: pane.canvas,
      initialPageId: pane.initialPageId,
      embedded: embedded,
      onCanvasRenamed: widget.onCanvasRenamed,
      onFullScreenChanged: widget.onFullScreenChanged,
      onSplitRequested: () => _addPane(pane.canvas),
      // Primary pane shows a back arrow only on the mobile route (to leave the
      // pushed workspace). Secondary panes get a close "×".
      onBack: (multi && i == 0 && widget.soloNonEmbedded) ? widget.onExit : null,
      onClosePane:
          (multi && i > 0) ? () => _closePane(pane.canvas.id) : null,
    );
  }

  Widget _divider(
    int leftIndex,
    double extent,
    AppPalette palette,
    bool horizontal,
  ) {
    return MouseRegion(
      cursor: horizontal
          ? SystemMouseCursors.resizeColumn
          : SystemMouseCursors.resizeRow,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onPanUpdate: (d) => _resize(
            leftIndex, horizontal ? d.delta.dx : d.delta.dy, extent),
        child: horizontal
            ? SizedBox(
                width: 12,
                child: Center(
                  child: Container(width: 1, color: palette.border),
                ),
              )
            : SizedBox(
                height: 12,
                child: Center(
                  child: Container(height: 1, color: palette.border),
                ),
              ),
      ),
    );
  }
}

/// The pushed mobile route: a workspace whose lone pane is the full canvas
/// screen (with a back button), splitting into panes on demand.
class CanvasWorkspaceScreen extends StatelessWidget {
  final Canvas initialCanvas;
  final String? initialPageId;

  const CanvasWorkspaceScreen({
    super.key,
    required this.initialCanvas,
    this.initialPageId,
  });

  @override
  Widget build(BuildContext context) {
    return CanvasWorkspace(
      initialCanvas: initialCanvas,
      initialPageId: initialPageId,
      soloNonEmbedded: true,
      onExit: () => Navigator.of(context).maybePop(),
    );
  }
}
