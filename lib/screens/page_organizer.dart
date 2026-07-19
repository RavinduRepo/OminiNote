import 'package:flutter/material.dart';
import '../canvas/canvas_controller.dart';
import '../canvas/page_thumbnail.dart';
import '../theme/app_theme.dart';

/// A drag-reorder view of a canvas's pages that mirrors the canvas's exact
/// structure: rows stacked vertically, and a horizontal (multi-page) row shows
/// its pages side by side. Press-and-hold a page to move it — drop it into a
/// gap **between rows** to make it its own row, or into a gap **within a row**
/// to join that horizontal row. Tapping a page jumps to it; each page keeps its
/// existing actions (duplicate, copy, delete) via its ⋮ menu.
class PageOrganizer extends StatefulWidget {
  final CanvasController controller;
  final void Function(String pageId) onJump;

  const PageOrganizer({
    super.key,
    required this.controller,
    required this.onJump,
  });

  @override
  State<PageOrganizer> createState() => _PageOrganizerState();
}

class _PageOrganizerState extends State<PageOrganizer> {
  static const double _cellW = 118;

  // A persistent controller (not one created per build) so the always-on
  // scrollbar thumb can be drag-scrubbed straight to the bottom of a
  // thousands-of-pages list — the default platform scrollbar is invisible on
  // touch, which is exactly what made this unreachable on mobile.
  final _scrollController = ScrollController();

  CanvasController get controller => widget.controller;

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  // ── Drop handlers (operate on a fresh copy of the row structure) ──────────

  (int, int)? _locate(List<List<String>> rows, String pageId) {
    for (var r = 0; r < rows.length; r++) {
      final c = rows[r].indexOf(pageId);
      if (c != -1) return (r, c);
    }
    return null;
  }

  void _dropAsNewRow(String pageId, int gapIndex) {
    final rows = controller.pageRows;
    final at = _locate(rows, pageId);
    if (at == null) return;
    rows[at.$1].removeAt(at.$2);
    rows.insert(gapIndex, [pageId]);
    controller.setPageRows(rows);
  }

  void _dropIntoRow(String pageId, int rowIndex, int colIndex) {
    final rows = controller.pageRows;
    final at = _locate(rows, pageId);
    if (at == null) return;
    var col = colIndex;
    rows[at.$1].removeAt(at.$2);
    if (at.$1 == rowIndex && at.$2 < col) col -= 1;
    rows[rowIndex].insert(col.clamp(0, rows[rowIndex].length), pageId);
    controller.setPageRows(rows);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Organize pages'),
        titleSpacing: 4,
        leadingWidth: 40,
        leading: IconButton(
          padding: EdgeInsets.zero,
          icon: const Icon(kBackIcon),
          tooltip: 'Back',
          onPressed: () => Navigator.of(context).pop(),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.undo),
            tooltip: 'Undo',
            onPressed: controller.canUndo ? () => controller.undo() : null,
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: controller,
        builder: (context, _) {
          final palette = Theme.of(context).extension<AppPalette>()!;
          final rows = controller.pageRows;
          // Explicit, always-visible, draggable thumb — the platform default
          // (Scrollbar via ScrollConfiguration) only shows on desktop/web, so
          // touch had no way to jump straight to the bottom of a
          // thousands-of-pages list. Slightly thicker than Material's default
          // (~8px) without turning it into its own UI element.
          return Scrollbar(
            controller: _scrollController,
            thumbVisibility: true,
            interactive: true,
            thickness: 10,
            radius: const Radius.circular(6),
            child: SingleChildScrollView(
              controller: _scrollController,
              padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var r = 0; r <= rows.length; r++) ...[
                    _RowGap(
                      palette: palette,
                      onAccept: (pageId) => _dropAsNewRow(pageId, r),
                    ),
                    if (r < rows.length)
                      _RowStrip(
                        controller: controller,
                        palette: palette,
                        cellWidth: _cellW,
                        rowIndex: r,
                        pageIds: rows[r],
                        onJump: (pageId) {
                          Navigator.pop(context);
                          widget.onJump(pageId);
                        },
                        onDropIntoRow: _dropIntoRow,
                      ),
                  ],
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

/// A thin drop zone between rows — dropping a page here makes it its own row.
class _RowGap extends StatelessWidget {
  final AppPalette palette;
  final void Function(String pageId) onAccept;

  const _RowGap({required this.palette, required this.onAccept});

  @override
  Widget build(BuildContext context) {
    return DragTarget<String>(
      onAcceptWithDetails: (d) => onAccept(d.data),
      builder: (context, candidate, _) {
        final hover = candidate.isNotEmpty;
        return Container(
          height: hover ? 22 : 12,
          margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
          decoration: BoxDecoration(
            color: hover ? palette.accent : Colors.transparent,
            borderRadius: BorderRadius.circular(999),
          ),
        );
      },
    );
  }
}

/// One canvas row rendered as a horizontal strip of page cells, with drop gaps
/// between cells so a page can join the row at any column.
class _RowStrip extends StatelessWidget {
  final CanvasController controller;
  final AppPalette palette;
  final double cellWidth;
  final int rowIndex;
  final List<String> pageIds;
  final void Function(String pageId) onJump;
  final void Function(String pageId, int rowIndex, int colIndex) onDropIntoRow;

  const _RowStrip({
    required this.controller,
    required this.palette,
    required this.cellWidth,
    required this.rowIndex,
    required this.pageIds,
    required this.onJump,
    required this.onDropIntoRow,
  });

  @override
  Widget build(BuildContext context) {
    // The flat page number of each page = pages before this row + column.
    final rows = controller.pageRows;
    var baseNumber = 1;
    for (var r = 0; r < rowIndex; r++) {
      baseNumber += rows[r].length;
    }

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var c = 0; c < pageIds.length; c++) ...[
            _ColGap(
              palette: palette,
              onAccept: (pageId) => onDropIntoRow(pageId, rowIndex, c),
            ),
            SizedBox(
              width: cellWidth,
              child: _PageCell(
                controller: controller,
                palette: palette,
                pageId: pageIds[c],
                number: baseNumber + c,
                onJump: () => onJump(pageIds[c]),
              ),
            ),
          ],
          _ColGap(
            palette: palette,
            onAccept: (pageId) =>
                onDropIntoRow(pageId, rowIndex, pageIds.length),
          ),
        ],
      ),
    );
  }
}

/// A narrow drop zone between/around cells within a row.
class _ColGap extends StatelessWidget {
  final AppPalette palette;
  final void Function(String pageId) onAccept;

  const _ColGap({required this.palette, required this.onAccept});

  @override
  Widget build(BuildContext context) {
    return DragTarget<String>(
      onAcceptWithDetails: (d) => onAccept(d.data),
      builder: (context, candidate, _) {
        final hover = candidate.isNotEmpty;
        return Container(
          width: hover ? 16 : 8,
          height: 150,
          margin: const EdgeInsets.symmetric(vertical: 8),
          decoration: BoxDecoration(
            color: hover ? palette.accent : Colors.transparent,
            borderRadius: BorderRadius.circular(999),
          ),
        );
      },
    );
  }
}

class _PageCell extends StatelessWidget {
  final CanvasController controller;
  final AppPalette palette;
  final String pageId;
  final int number;
  final VoidCallback onJump;

  const _PageCell({
    required this.controller,
    required this.palette,
    required this.pageId,
    required this.number,
    required this.onJump,
  });

  @override
  Widget build(BuildContext context) {
    final page = controller.pages[pageId];
    if (page == null) return const SizedBox.shrink();
    final isPdf = page.source != null;

    final thumb = Container(
      margin: const EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(
        border: Border.all(color: palette.border),
        boxShadow: const [
          BoxShadow(
            color: Color(0x14000000),
            blurRadius: 6,
            offset: Offset(0, 2),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: AspectRatio(
        aspectRatio: page.width / page.height,
        child: Stack(
          fit: StackFit.expand,
          children: [
            PageThumbnail(
              page: page,
              renderCache: controller.renderCache,
              assetFileOf: controller.assetFileOf,
            ),
            if (isPdf)
              Positioned(
                top: 4,
                left: 4,
                child: Icon(Icons.picture_as_pdf,
                    size: 15, color: Colors.red.shade400),
              ),
            Positioned(
              top: 2,
              right: 2,
              child: _CellMenu(controller: controller, pageId: pageId),
            ),
            Positioned(
              bottom: 4,
              left: 0,
              right: 0,
              child: Center(
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.55),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    '$number',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );

    return LongPressDraggable<String>(
      data: pageId,
      feedback: Material(
        color: Colors.transparent,
        child: Opacity(
          opacity: 0.85,
          child: SizedBox(
            width: 110,
            height: 110 * page.height / page.width,
            child: FittedBox(
              fit: BoxFit.contain,
              child: SizedBox(
                width: page.width,
                height: page.height,
                child: PageThumbnail(
                  page: page,
                  renderCache: controller.renderCache,
                  assetFileOf: controller.assetFileOf,
                ),
              ),
            ),
          ),
        ),
      ),
      childWhenDragging: Opacity(opacity: 0.3, child: thumb),
      child: GestureDetector(onTap: onJump, child: thumb),
    );
  }
}

class _CellMenu extends StatelessWidget {
  final CanvasController controller;
  final String pageId;

  const _CellMenu({required this.controller, required this.pageId});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black.withValues(alpha: 0.4),
      shape: const CircleBorder(),
      child: PopupMenuButton<String>(
        icon: const Icon(Icons.more_vert, size: 16, color: Colors.white),
        padding: EdgeInsets.zero,
        tooltip: 'Page actions',
        onSelected: (action) {
          switch (action) {
            case 'duplicate':
              controller.duplicatePage(pageId);
            case 'copy':
              controller.copyPageToClipboard(pageId);
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Page copied — paste from Add ＋ in any canvas'),
                  behavior: SnackBarBehavior.floating,
                ),
              );
            case 'delete':
              if (!controller.deletePage(pageId)) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text("Can't delete the only page"),
                    behavior: SnackBarBehavior.floating,
                  ),
                );
              }
          }
        },
        itemBuilder: (context) => const [
          PopupMenuItem(value: 'duplicate', child: Text('Duplicate')),
          PopupMenuItem(value: 'copy', child: Text('Copy page')),
          PopupMenuItem(value: 'delete', child: Text('Delete')),
        ],
      ),
    );
  }
}
