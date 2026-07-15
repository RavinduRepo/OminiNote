import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:perfect_freehand/perfect_freehand.dart';
import '../models/canvas_page.dart';
import '../models/element.dart';
import 'canvas_controller.dart';
import 'canvas_layout.dart';
import 'text_measure.dart';

/// Cached page-local pattern geometry, keyed by (pattern, page size). Lives at
/// module scope so it survives the painter being rebuilt (a new [CanvasPainter]
/// is constructed on every widget rebuild, but repaints reuse the instance);
/// the geometry is a pure function of the key, so sharing it is safe.
final Map<String, Float32List> _patternGeomCache = {};
const int _kPatternGeomCacheMax = 48;

/// Paints the whole canvas: visible pages (background color/pattern or PDF
/// bitmap), their elements, the in-progress stroke/lasso, and screen-space
/// overlays (selection box + handles, over-scroll affordances).
class CanvasPainter extends CustomPainter {
  final CanvasController controller;
  final Color pageBorderColor;
  final Color accentColor;
  final Color canvasTextColor;

  CanvasPainter({
    required this.controller,
    required this.pageBorderColor,
    required this.accentColor,
    required this.canvasTextColor,
  }) : super(repaint: controller);

  /// Set false during a picture recording when an image raster wasn't decoded
  /// yet — keeps that page's cache entry provisional so it re-records once
  /// the raster lands (RenderCache repaints via the controller when it does).
  bool _recordComplete = true;

  @override
  void paint(Canvas canvas, Size size) {
    // Generous cull margin (canvas units) so edge pages aren't dropped.
    final visibleCanvasRect = Rect.fromPoints(
      controller.screenToCanvas(Offset.zero),
      controller.screenToCanvas(Offset(size.width, size.height)),
    ).inflate(300);

    canvas.save();
    canvas.transform(controller.viewportMatrix.storage);

    final allPages = controller.layout.pages;
    for (var i = 0; i < allPages.length; i++) {
      final l = allPages[i];
      if (!l.rect.overlaps(visibleCanvasRect)) continue;
      final page = controller.pages[l.pageId];
      if (page == null) continue;
      _paintPage(canvas, l, page);
      _paintPageNumber(canvas, l.rect, i + 1);
    }

    canvas.restore();

    _paintSelectionOverlay(canvas);
    _paintOverscrollHints(canvas, size);
    _paintScrollbars(canvas, size);
  }

  void _paintPage(Canvas canvas, PageLayout l, CanvasPage page) {
    final rect = l.rect;

    // Solid page background (pages sit flush; a hairline border separates
    // them, so no drop shadow — it would bleed onto neighbours).
    canvas.drawRect(rect, Paint()..color = page.background.color);

    // PDF-backed background bitmap.
    if (page.source != null) {
      final file = controller.assetFileOf(page.source!.assetId);
      final image = controller.renderCache.pdfPageImage(
        file.path,
        page.source!.pageIndex,
        controller.zoom,
      );
      if (image != null) {
        canvas.drawImageRect(
          image,
          Rect.fromLTWH(
            0,
            0,
            image.width.toDouble(),
            image.height.toDouble(),
          ),
          rect,
          Paint()..filterQuality = FilterQuality.medium,
        );
      } else {
        _paintCenteredLabel(canvas, rect, 'Loading…');
      }
    } else {
      _paintPattern(canvas, rect, page.background);
    }

    // Hairline page border.
    canvas.drawRect(
      rect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1 / controller.zoom
        ..color = pageBorderColor,
    );

    // Elements, clipped to the page. Committed elements replay from a cached
    // per-page picture (page-local coords, zoom-independent) — re-recorded
    // only when the controller invalidates the page, not every frame.
    canvas.save();
    canvas.clipRect(rect);
    canvas.translate(rect.left, rect.top);

    final editingId = controller.editingElementId;
    final skipped = editingId != null &&
            page.objects.any((o) => o.id == editingId)
        ? editingId // text overlay open on this page
        : null;
    if (controller.isErasingPage(page.id)) {
      // Active erase gesture: draw the (live, already-reduced) committed
      // elements straight onto the canvas instead of re-recording the page
      // picture on every erased stroke. _commitErase invalidates the cache
      // once at gesture end so the normal cached path resumes next frame.
      for (final el in zOrderedElements(page)) {
        if (el.id == skipped) continue;
        _paintElement(canvas, el);
      }
    } else {
      controller.pictureCache.paint(
        canvas,
        page.id,
        skippedElementId: skipped,
        record: (c) {
          _recordComplete = true;
          for (final el in zOrderedElements(page)) {
            if (el.id == skipped) continue;
            _paintElement(c, el);
          }
          return _recordComplete;
        },
      );
    }

    // In-progress stroke on this page (predefined shape / freehand), or a
    // template's multi-stroke preview.
    if (controller.activeStrokePageId == page.id) {
      if (controller.activeStroke != null) {
        _paintStroke(canvas, controller.activeStroke!);
      }
      for (final s in controller.previewStrokes) {
        _paintStroke(canvas, s);
      }
    }

    // In-progress lasso on this page.
    final lasso = controller.lassoPoints;
    if (lasso != null && lasso.length > 1 && _lassoPageId == page.id) {
      final path = Path()..addPolygon(lasso, false);
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5 / controller.zoom
          ..color = accentColor,
      );
      final closed = Path()..addPolygon(lasso, true);
      canvas.drawPath(
        closed,
        Paint()..color = accentColor.withValues(alpha: 0.08),
      );
    }

    canvas.restore();
  }

  String? get _lassoPageId => controller.gesturePageId;

  /// A soft, screen-only page number at the page's bottom-right (PDF-viewer
  /// style). Sized inversely to zoom so it stays a constant on-screen size, and
  /// never drawn into a PDF export (this is painter-only).
  void _paintPageNumber(Canvas canvas, Rect rect, int number) {
    final zoom = controller.zoom;
    final tp = TextPainter(
      text: TextSpan(
        text: '$number',
        style: TextStyle(
          fontSize: 10 / zoom,
          color: Colors.white,
          fontWeight: FontWeight.w600,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final padX = 6 / zoom, padY = 2 / zoom, margin = 6 / zoom;
    final w = tp.width + padX * 2, h = tp.height + padY * 2;
    final left = rect.right - margin - w;
    final top = rect.bottom - margin - h;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(left, top, w, h),
        Radius.circular(h / 2),
      ),
      Paint()..color = Colors.black.withValues(alpha: 0.42),
    );
    tp.paint(canvas, Offset(left + padX, top + padY));
  }

  void _paintElement(Canvas canvas, CanvasElement el) {
    switch (el) {
      case StrokeElement():
        _paintStroke(canvas, el);
      case TextElement():
        _paintText(canvas, el);
      case ImageElement():
        _paintImage(canvas, el);
      case AttachmentElement():
        _paintAttachment(canvas, el);
    }
  }

  /// The attachment chip: rounded rect, a small "document" glyph with a
  /// folded corner, and the file name. Tap-to-open is handled by the screen.
  void _paintAttachment(Canvas canvas, AttachmentElement el) {
    final r = el.rect;
    canvas.save();
    if (el.rotation != 0) {
      canvas.translate(r.center.dx, r.center.dy);
      canvas.rotate(el.rotation);
      canvas.translate(-r.center.dx, -r.center.dy);
    }

    final rrect = RRect.fromRectAndRadius(r, const Radius.circular(6));
    canvas.drawRRect(rrect, Paint()..color = const Color(0xFFF4F1EA));
    canvas.drawRRect(
      rrect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = const Color(0xFFB9B2A4),
    );

    // Document glyph with folded corner, sized to the chip height.
    final gh = r.height * 0.62;
    final gw = gh * 0.78;
    final gx = r.left + r.height * 0.22;
    final gy = r.center.dy - gh / 2;
    const fold = 0.32;
    final doc = Path()
      ..moveTo(gx, gy)
      ..lineTo(gx + gw * (1 - fold), gy)
      ..lineTo(gx + gw, gy + gh * fold)
      ..lineTo(gx + gw, gy + gh)
      ..lineTo(gx, gy + gh)
      ..close();
    canvas.drawPath(doc, Paint()..color = const Color(0xFFD9534F));
    final foldPath = Path()
      ..moveTo(gx + gw * (1 - fold), gy)
      ..lineTo(gx + gw * (1 - fold), gy + gh * fold)
      ..lineTo(gx + gw, gy + gh * fold)
      ..close();
    canvas.drawPath(foldPath, Paint()..color = const Color(0xFFB23C38));

    // File name, ellipsized to the remaining width.
    final textLeft = gx + gw + r.height * 0.2;
    final maxW = r.right - textLeft - 8;
    if (maxW > 12) {
      final tp = TextPainter(
        text: TextSpan(
          text: el.name,
          style: TextStyle(
            color: const Color(0xFF2B2B2B),
            fontSize: (r.height * 0.32).clamp(9.0, 14.0),
            fontWeight: FontWeight.w600,
          ),
        ),
        textDirection: TextDirection.ltr,
        maxLines: 1,
        ellipsis: '…',
      )..layout(maxWidth: maxW);
      tp.paint(canvas, Offset(textLeft, r.center.dy - tp.height / 2));
    }
    canvas.restore();
  }

  void _paintStroke(Canvas canvas, StrokeElement stroke) {
    if (stroke.points.isEmpty) return;
    final isHighlighter = stroke.tool == StrokeTool.highlighter;

    var outline = stroke.cachedOutline;
    if (outline == null) {
      final points = [
        for (final p in stroke.points) PointVector(p.x, p.y, p.p),
      ];
      final outlinePoints = getStroke(
        points,
        options: StrokeOptions(
          size: isHighlighter ? stroke.size * 2.6 : stroke.size,
          thinning: isHighlighter ? 0.0 : 0.6,
          smoothing: 0.6,
          streamline: 0.6,
          simulatePressure: false,
        ),
      );
      if (outlinePoints.isEmpty) return;
      outline = _smoothOutlinePath(outlinePoints);
      stroke.cachedOutline = outline;
    }

    canvas.drawPath(
      outline,
      Paint()
        ..style = PaintingStyle.fill
        ..color = isHighlighter
            ? stroke.color.withValues(alpha: 0.35)
            : stroke.color,
    );
  }

  /// Builds the fill path for a `perfect_freehand` outline as a **smooth closed
  /// curve** instead of a straight-segment polygon. Each outline point is a
  /// quadratic-bézier control point and the midpoint between consecutive points
  /// is on-curve — perfect_freehand's own recommended rendering. This rounds
  /// the facets that a raw `addPolygon` leaves on thick / fast strokes (sparse
  /// outline points → visible straight edges on curves).
  static Path _smoothOutlinePath(List<Offset> pts) {
    final n = pts.length;
    final path = Path();
    if (n < 3) return path..addPolygon(pts, true);
    // Start on-curve at the midpoint of the closing edge (last → first).
    path.moveTo((pts[n - 1].dx + pts[0].dx) / 2, (pts[n - 1].dy + pts[0].dy) / 2);
    for (var i = 0; i < n; i++) {
      final c = pts[i];
      final next = pts[(i + 1) % n];
      path.quadraticBezierTo(
          c.dx, c.dy, (c.dx + next.dx) / 2, (c.dy + next.dy) / 2);
    }
    return path..close();
  }

  void _paintText(Canvas canvas, TextElement el) {
    final painter = TextPainter(
      text: textSpanForElement(el),
      textDirection: TextDirection.ltr,
      textAlign: switch (el.align) {
        TextAlignOption.center => TextAlign.center,
        TextAlignOption.right => TextAlign.right,
        _ => TextAlign.left,
      },
    )..layout(minWidth: el.rect.width, maxWidth: math.max(el.rect.width, 8));

    canvas.save();
    if (el.rotation != 0) {
      final c = el.rect.center;
      canvas.translate(c.dx, c.dy);
      canvas.rotate(el.rotation);
      canvas.translate(-c.dx, -c.dy);
    }
    painter.paint(canvas, el.rect.topLeft);

    // Editable-space hint: a link-only box carries an auto-appended trailing
    // space so there's a spot to tap for editing/moving (tapping the link text
    // itself opens the URL). Draw a faint underline under that space so the
    // spot is visible, like a fill-in blank.
    if (_hasTrailingEditSpace(el)) {
      final len = el.text.length;
      final start =
          painter.getOffsetForCaret(TextPosition(offset: len - 1), Rect.zero);
      final end =
          painter.getOffsetForCaret(TextPosition(offset: len), Rect.zero);
      final x0 = el.rect.left + start.dx;
      final w = math.max(end.dx - start.dx, 10.0);
      final y = el.rect.top + start.dy + el.runs.last.fontSize * 1.15;
      canvas.drawLine(
        Offset(x0, y),
        Offset(x0 + w, y),
        Paint()
          ..color = const Color(0x66888888)
          ..strokeWidth = 1.2,
      );
    }
    canvas.restore();
  }

  /// True when [el] is a link-only box with the auto-appended trailing space
  /// (every run but the last is a link, and the last is that plain space).
  bool _hasTrailingEditSpace(TextElement el) {
    final runs = el.runs;
    if (runs.length < 2) return false;
    if (runs.last.link != null || runs.last.text != ' ') return false;
    for (var i = 0; i < runs.length - 1; i++) {
      if (runs[i].link == null) return false;
    }
    return true;
  }

  void _paintImage(Canvas canvas, ImageElement el) {
    final file = controller.assetFileOf(el.assetId);
    final image = controller.renderCache.rasterImage(file);

    canvas.save();
    if (el.rotation != 0) {
      final c = el.rect.center;
      canvas.translate(c.dx, c.dy);
      canvas.rotate(el.rotation);
      canvas.translate(-c.dx, -c.dy);
    }
    if (image != null) {
      canvas.drawImageRect(
        image,
        Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
        el.rect,
        Paint()..filterQuality = FilterQuality.medium,
      );
    } else {
      _recordComplete = false; // decode pending — placeholder isn't cacheable
      canvas.drawRect(
        el.rect,
        Paint()..color = pageBorderColor.withValues(alpha: 0.3),
      );
    }
    canvas.restore();
  }

  void _paintPattern(Canvas canvas, Rect rect, PageBackground bg) {
    if (bg.pattern == BgPattern.blank) return;

    // Geometry (line endpoints / dot centers, page-local) is a pure function of
    // pattern + page size, so it's built once and cached — the per-frame work
    // collapses to a single drawRawPoints. Line COLOR (from the live page bg)
    // and WIDTH (zoom-dependent hairline) stay per-frame, so the cache needs no
    // invalidation and a page-colour change stays live without a rebuild.
    final geom = _patternGeometry(bg.pattern, rect.width, rect.height);
    if (geom.isEmpty) return;

    final isDark = bg.color.computeLuminance() < 0.4;
    final lineColor = isDark
        ? Colors.white.withValues(alpha: 0.14)
        : const Color(0xFF3B4A6B).withValues(alpha: 0.13);
    final z = controller.zoom.clamp(0.5, 4);

    canvas.save();
    canvas.translate(rect.left, rect.top);
    if (bg.pattern == BgPattern.dotted) {
      // Round cap + width 2r reproduces the old drawCircle(r) dots exactly.
      final paint = Paint()
        ..color = lineColor
        ..strokeCap = StrokeCap.round
        ..strokeWidth = (1.4 / z) * 2;
      canvas.drawRawPoints(ui.PointMode.points, geom, paint);
    } else {
      final paint = Paint()
        ..color = lineColor
        ..strokeWidth = 1 / z;
      canvas.drawRawPoints(ui.PointMode.lines, geom, paint);
    }
    canvas.restore();
  }

  /// Page-local pattern geometry for [pattern] on a [w]×[h] page, cached by
  /// (pattern, size) — the endpoint/dot list doesn't depend on colour or zoom.
  /// Ruled/grid entries are segment endpoint PAIRS (drawn `PointMode.lines`);
  /// dotted entries are dot centres (drawn `PointMode.points`). Mirrors the old
  /// per-frame loops exactly, so the appearance is unchanged.
  Float32List _patternGeometry(BgPattern pattern, double w, double h) {
    final key = '${pattern.index}:${w.toStringAsFixed(1)}x${h.toStringAsFixed(1)}';
    final cached = _patternGeomCache[key];
    if (cached != null) return cached;

    const spacing = 26.0;
    final pts = <double>[];
    switch (pattern) {
      case BgPattern.ruled:
        for (var y = spacing * 1.5; y < h - 8; y += spacing) {
          pts..add(20)..add(y)..add(w - 20)..add(y);
        }
      case BgPattern.grid:
        for (var x = spacing; x < w; x += spacing) {
          pts..add(x)..add(0)..add(x)..add(h);
        }
        for (var y = spacing; y < h; y += spacing) {
          pts..add(0)..add(y)..add(w)..add(y);
        }
      case BgPattern.dotted:
        for (var x = spacing; x < w; x += spacing) {
          for (var y = spacing; y < h; y += spacing) {
            pts..add(x)..add(y);
          }
        }
      case BgPattern.blank:
        break;
    }

    final list = Float32List.fromList(pts);
    // Tiny keyspace in practice (A4 default + a few PDF-normalized widths); a
    // rare wholesale clear is cheaper than tracking LRU for so few entries.
    if (_patternGeomCache.length >= _kPatternGeomCacheMax) {
      _patternGeomCache.clear();
    }
    _patternGeomCache[key] = list;
    return list;
  }

  void _paintCenteredLabel(Canvas canvas, Rect rect, String label) {
    final painter = TextPainter(
      text: TextSpan(
        text: label,
        style: TextStyle(
          color: canvasTextColor.withValues(alpha: 0.5),
          fontSize: 13 / controller.zoom.clamp(0.5, 3),
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    painter.paint(
      canvas,
      rect.center - Offset(painter.width / 2, painter.height / 2),
    );
  }

  // ── Screen-space overlays ────────────────────────────────────────────

  void _paintSelectionOverlay(Canvas canvas) {
    final rect = controller.selectionScreenRect;
    if (rect == null) return;

    canvas.drawRect(
      rect,
      Paint()..color = accentColor.withValues(alpha: 0.06),
    );
    canvas.drawRect(
      rect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = accentColor,
    );

    // Rotate handle: stem + knob above the top edge.
    final rotatePos = rect.topCenter - const Offset(0, 36);
    canvas.drawLine(
      rect.topCenter,
      rotatePos,
      Paint()
        ..strokeWidth = 1.5
        ..color = accentColor,
    );

    final handleFill = Paint()..color = Colors.white;
    final handleStroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..color = accentColor;

    // Corner handles for every selection. For text they resize the box's wrap
    // width only (the font size never changes); for everything else they scale.
    for (final corner in [
      rect.topLeft,
      rect.topRight,
      rect.bottomLeft,
      rect.bottomRight,
    ]) {
      final r = Rect.fromCircle(center: corner, radius: 6);
      canvas.drawRect(r, handleFill);
      canvas.drawRect(r, handleStroke);
    }
    // Side handles (non-uniform stretch) — mirror hitTestSelection's gating:
    // only on axes long enough not to crowd the corners; no vertical handles
    // for text (its height follows the wrapped content).
    const minForSide = 48.0;
    final sides = <Offset>[
      if (rect.width >= minForSide) ...[rect.centerLeft, rect.centerRight],
      if (rect.height >= minForSide && !controller.selectionIsTextOnly) ...[
        rect.topCenter,
        rect.bottomCenter,
      ],
    ];
    for (final s in sides) {
      final r = Rect.fromCircle(center: s, radius: 5);
      canvas.drawRect(r, handleFill);
      canvas.drawRect(r, handleStroke);
    }
    canvas.drawCircle(rotatePos, 7, handleFill);
    canvas.drawCircle(rotatePos, 7, handleStroke);
  }

  void _paintOverscrollHints(Canvas canvas, Size size) {
    void hint(Offset center, double progress) {
      if (progress <= 0) return;
      final t = (progress / CanvasController.overscrollThreshold).clamp(
        0.0,
        1.0,
      );
      final bg = Paint()
        ..color = accentColor.withValues(alpha: 0.25 + 0.6 * t);
      canvas.drawCircle(center, 22, bg);
      final ink = Paint()
        ..color = Colors.white
        ..strokeWidth = 3
        ..strokeCap = StrokeCap.round;
      canvas.drawLine(
        center - const Offset(8, 0),
        center + const Offset(8, 0),
        ink,
      );
      canvas.drawLine(
        center - const Offset(0, 8),
        center + const Offset(0, 8),
        ink,
      );
      if (t >= 1) {
        canvas.drawCircle(
          center,
          26,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2
            ..color = Colors.white,
        );
      }
    }

    hint(
      Offset(size.width - 40, size.height / 2),
      controller.overscrollRight,
    );
    hint(
      Offset(size.width / 2, size.height - 40),
      controller.overscrollBottom,
    );
  }

  void _paintScrollbars(Canvas canvas, Size size) {
    final thumbPaint = Paint()
      ..color = canvasTextColor.withValues(alpha: 0.55);
    final radius = Radius.circular(CanvasController.scrollbarThickness / 2);

    final v = controller.verticalScrollbarThumb();
    if (v != null) {
      canvas.drawRRect(RRect.fromRectAndRadius(v, radius), thumbPaint);
    }
    final h = controller.horizontalScrollbarThumb();
    if (h != null) {
      canvas.drawRRect(RRect.fromRectAndRadius(h, radius), thumbPaint);
    }
  }

  @override
  bool shouldRepaint(covariant CanvasPainter oldDelegate) => true;
}

