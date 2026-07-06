import 'dart:math' as math;
import 'dart:ui';
import '../models/canvas_page.dart';
import '../models/canvas.dart';

/// Gap between pages, in canvas units (= PDF points). Zero → pages sit flush
/// for a clean continuous document; a hairline border delineates them.
const double kPageGap = 0;

/// Where one page sits in canvas space.
class PageLayout {
  final String pageId;
  final int rowIndex;
  final int colIndex;
  final Rect rect;

  const PageLayout({
    required this.pageId,
    required this.rowIndex,
    required this.colIndex,
    required this.rect,
  });
}

class CanvasLayout {
  final List<PageLayout> pages;
  final Size size;

  const CanvasLayout({required this.pages, required this.size});

  PageLayout? layoutOf(String pageId) {
    for (final l in pages) {
      if (l.pageId == pageId) return l;
    }
    return null;
  }

  /// The page containing [point] (canvas space), or null.
  PageLayout? pageAt(Offset point) {
    for (final l in pages) {
      if (l.rect.contains(point)) return l;
    }
    return null;
  }

  /// The page whose center is nearest to [point] — used for "current page"
  /// when the viewport center sits in a gap.
  PageLayout? nearestPage(Offset point) {
    PageLayout? best;
    var bestDist = double.infinity;
    for (final l in pages) {
      final d = (l.rect.center - point).distanceSquared;
      if (d < bestDist) {
        bestDist = d;
        best = l;
      }
    }
    return best;
  }
}

/// Rows stacked top→down, pages within a row left→right, all left-aligned at
/// x=0 (stable when a row gains horizontal pages — nothing else moves).
CanvasLayout computeLayout(Canvas canvas, Map<String, CanvasPage> pages) {
  final layouts = <PageLayout>[];
  double y = 0;
  double maxWidth = 0;

  for (var r = 0; r < canvas.rows.length; r++) {
    final row = canvas.rows[r];
    double x = 0;
    double rowHeight = 0;

    for (var c = 0; c < row.pageIds.length; c++) {
      final page = pages[row.pageIds[c]];
      if (page == null) continue;
      layouts.add(
        PageLayout(
          pageId: page.id,
          rowIndex: r,
          colIndex: c,
          rect: Rect.fromLTWH(x, y, page.width, page.height),
        ),
      );
      x += page.width + kPageGap;
      rowHeight = math.max(rowHeight, page.height);
    }

    maxWidth = math.max(maxWidth, x - kPageGap);
    y += rowHeight + kPageGap;
  }

  return CanvasLayout(
    pages: layouts,
    size: Size(math.max(maxWidth, 0), math.max(y - kPageGap, 0)),
  );
}
