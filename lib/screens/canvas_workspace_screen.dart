import 'package:flutter/material.dart';

import '../models/canvas.dart';
import '../theme/app_theme.dart';
import '../widgets/canvas_picker.dart';
import 'canvas_screen.dart';

/// Hosts one or more canvases side by side (in-app split view), so you can work
/// on several at once. This is what the mobile flow pushes when opening a
/// canvas.
///
/// With a **single** pane it renders the ordinary [CanvasScreen] (non-embedded:
/// same app bar, bottom-sheet menus, and back button as before) plus an "Open
/// canvas alongside" action — so the common case is unchanged. Adding a pane
/// switches to a resizable Row of **embedded** canvases, each with its own
/// toolbar and a close-pane button.
class CanvasWorkspaceScreen extends StatefulWidget {
  final Canvas initialCanvas;
  final String? initialPageId;

  const CanvasWorkspaceScreen({
    super.key,
    required this.initialCanvas,
    this.initialPageId,
  });

  @override
  State<CanvasWorkspaceScreen> createState() => _CanvasWorkspaceScreenState();
}

class _Pane {
  final Canvas canvas;
  final String? initialPageId;

  /// Relative width weight (draggable dividers will adjust this); starts equal.
  double flex = 1;

  _Pane(this.canvas, {this.initialPageId});
}

class _CanvasWorkspaceScreenState extends State<CanvasWorkspaceScreen> {
  late final List<_Pane> _panes = [
    _Pane(widget.initialCanvas, initialPageId: widget.initialPageId),
  ];

  /// Minimum on-screen width for a pane before the row starts to scroll.
  static const double _minPaneWidth = 300;

  Future<void> _addPane() async {
    final openIds = {for (final p in _panes) p.canvas.id};
    final canvas = await pickCanvasForPane(context, excludeIds: openIds);
    if (canvas == null || !mounted) return;
    // Guard against a double-add of the same canvas (two controllers on one
    // canvas would fight over autosave/sync).
    if (openIds.contains(canvas.id)) return;
    setState(() => _panes.add(_Pane(canvas)));
  }

  void _closePane(String canvasId) {
    setState(() => _panes.removeWhere((p) => p.canvas.id == canvasId));
  }

  @override
  Widget build(BuildContext context) {
    // Single pane → the ordinary canvas screen, plus the split action. Byte-for-
    // byte today's behavior for the common case (mobile menus, back button).
    if (_panes.length == 1) {
      final p = _panes.first;
      return CanvasScreen(
        key: ValueKey('solo-${p.canvas.id}'),
        canvas: p.canvas,
        initialPageId: p.initialPageId,
        onSplitRequested: _addPane,
      );
    }

    final palette = Theme.of(context).extension<AppPalette>()!;
    return PopScope(
      // System back closes the last-added pane first; only pops the whole
      // workspace once a single pane remains (that pane owns its own back).
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_panes.length > 1) {
          _closePane(_panes.last.canvas.id);
        } else {
          Navigator.of(context).maybePop();
        }
      },
      child: Scaffold(
        backgroundColor: palette.canvas,
        body: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final needed = _minPaneWidth * _panes.length;
              final scroll = needed > constraints.maxWidth;
              final row = Row(
                mainAxisSize: scroll ? MainAxisSize.min : MainAxisSize.max,
                children: [
                  for (var i = 0; i < _panes.length; i++) ...[
                    if (i > 0) _divider(palette),
                    _paneWidget(i, scroll),
                  ],
                ],
              );
              if (!scroll) return row;
              return SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: SizedBox(
                  // Give each pane the min width when scrolling.
                  width: needed + (_panes.length - 1),
                  child: row,
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _paneWidget(int i, bool scroll) {
    final pane = _panes[i];
    final screen = CanvasScreen(
      key: ValueKey('pane-${pane.canvas.id}'),
      canvas: pane.canvas,
      initialPageId: pane.initialPageId,
      embedded: true,
      onSplitRequested: _addPane,
      // Primary pane shows a back arrow (leaves the workspace); the rest show a
      // close-pane "×".
      onBack: i == 0 ? () => Navigator.of(context).maybePop() : null,
      onClosePane: i == 0 ? null : () => _closePane(pane.canvas.id),
    );
    if (scroll) return SizedBox(width: _minPaneWidth, child: screen);
    return Expanded(flex: (pane.flex * 1000).round(), child: screen);
  }

  Widget _divider(AppPalette palette) => Container(
        width: 1,
        color: palette.border,
      );
}
