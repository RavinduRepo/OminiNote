import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:perfect_freehand/perfect_freehand.dart';
import '../models/canvas_page.dart';
import '../models/element.dart';
import '../utils/audio_sync.dart';
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
  }) : super(
          // Also repaint when the audio-sync playhead advances or the read-aloud
          // highlight moves, so both track playback/reading without notifying the
          // rest of the widget tree.
          repaint: Listenable.merge([
            controller,
            controller.audioPlayheadNotifier,
            controller.actionGlowNotifier,
            controller.readAloudHighlightNotifier,
            controller.pdfSelectionNotifier,
            controller.linkFlashNotifier,
          ]),
        );

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

    // In-progress freehand stroke / shape / template preview. Drawn here,
    // OUTSIDE any per-page clip, translated by the origin page's top-left, so a
    // stroke that crosses onto a neighbouring page previews as one continuous
    // line (it commits split into per-page strokes on lift). Its points are in
    // the origin page's local space.
    final activeId = controller.activeStrokePageId;
    if (activeId != null) {
      final al = controller.layout.layoutOf(activeId);
      if (al != null) {
        canvas.save();
        canvas.translate(al.rect.left, al.rect.top);
        if (controller.activeStroke != null) {
          _paintStroke(canvas, controller.activeStroke!);
        }
        for (final s in controller.previewStrokes) {
          _paintStroke(canvas, s);
        }
        canvas.restore();
      }
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

    // Audio-sync: while a recording plays, glow the strokes drawn around the
    // playhead. Drawn outside the picture cache (dynamic each frame), and only
    // for strokes whose outline is already cached, so it stays cheap.
    final playhead = controller.audioPlayheadNotifier.value;
    if (playhead != null) {
      for (final s in page.strokes) {
        if (s.id == skipped) continue;
        if (strokeActiveAt(s.createdAt, playhead)) {
          _paintAudioGlow(canvas, s);
        }
      }
    }

    // Action-recording replay: glow the strokes recorded at the current media
    // position (id set computed by the controller from action segments).
    final actionGlow = controller.actionGlowNotifier.value;
    if (actionGlow != null) {
      for (final s in page.strokes) {
        if (s.id == skipped) continue;
        if (actionGlow.contains(s.id)) _paintAudioGlow(canvas, s);
      }
    }

    // PDF text selection / find highlight: page-local rects behind the text.
    final pdfSel = controller.pdfSelectionNotifier.value;
    if (pdfSel != null && pdfSel.pageId == page.id) {
      final hl = Paint()..color = accentColor.withValues(alpha: 0.30);
      for (final r in pdfSel.rects) {
        canvas.drawRRect(
          RRect.fromRectAndRadius(r, const Radius.circular(2)),
          hl,
        );
      }
    }

    // Connections landing flash: halo the elements an internal link led to.
    // Like the audio glow — outside the picture cache, no-op when idle.
    final flash = controller.linkFlashNotifier.value;
    if (flash != null && flash.pageId == page.id) {
      for (final el in [...page.strokes, ...page.objects]) {
        if (!flash.ids.contains(el.id)) continue;
        if (el is StrokeElement) {
          _paintAudioGlow(canvas, el);
        } else {
          canvas.drawRRect(
            RRect.fromRectAndRadius(
              el.bounds.inflate(6 / controller.zoom),
              Radius.circular(4 / controller.zoom),
            ),
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = 3 / controller.zoom
              ..color = accentColor.withValues(alpha: 0.6)
              ..maskFilter =
                  MaskFilter.blur(BlurStyle.normal, 2 / controller.zoom),
          );
        }
      }
    }

    // Read-along highlight: a soft marker behind the sentence being read.
    // Page-local rects, so it sits inside this page's translate like the text.
    final hl = controller.readAloudHighlightNotifier.value;
    if (hl != null && hl.pageId == page.id) {
      final paint = Paint()..color = accentColor.withValues(alpha: 0.24);
      for (final r in hl.rects) {
        canvas.drawRRect(
          RRect.fromRectAndRadius(r.inflate(1), Radius.circular(2 / controller.zoom)),
          paint,
        );
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

  /// Icon + tint for an attachment chip, chosen by the file's mime family so
  /// audio/image/video/PDF/other chips are distinguishable at a glance.
  (IconData, Color) _attachmentGlyph(String mime) {
    if (mime == 'application/pdf') {
      return (Icons.picture_as_pdf, const Color(0xFFD9534F));
    }
    if (mime.startsWith('audio/')) {
      return (Icons.audiotrack, const Color(0xFF7E57C2));
    }
    if (mime.startsWith('image/')) {
      return (Icons.image, const Color(0xFF2E9E8F));
    }
    if (mime.startsWith('video/')) {
      return (Icons.movie, const Color(0xFF3F51B5));
    }
    return (Icons.insert_drive_file, const Color(0xFF8A8A8A));
  }

  /// The attachment chip: rounded rect, a media glyph tinted by file kind, and
  /// the file name. Tap-to-open/play is handled by the screen.
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

    // Media glyph — the icon depends on the file kind (audio/image/video/pdf/
    // file) — sized to the chip height and painted from the icon font.
    final (glyphIcon, glyphColor) = _attachmentGlyph(el.mime);
    final gh = r.height * 0.62;
    final gx = r.left + r.height * 0.22;
    final glyph = TextPainter(
      text: TextSpan(
        text: String.fromCharCode(glyphIcon.codePoint),
        style: TextStyle(
          fontFamily: glyphIcon.fontFamily,
          package: glyphIcon.fontPackage,
          fontSize: gh,
          color: glyphColor,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    glyph.paint(canvas, Offset(gx, r.center.dy - glyph.height / 2));

    // File name, ellipsized to the remaining width.
    final textLeft = gx + glyph.width + r.height * 0.2;
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

  /// A soft accent halo under a stroke being "written" at the playback
  /// playhead. Reuses the stroke's already-built outline (skips if not cached
  /// yet — the picture-cache pass builds it, so it's present in practice) and
  /// blurs it, so audio-sync costs a few extra draws only during playback.
  void _paintAudioGlow(Canvas canvas, StrokeElement stroke) {
    final outline = stroke.cachedOutline;
    if (outline == null) return;
    final zoom = controller.zoom;
    canvas.drawPath(
      outline,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 7 / zoom
        ..color = accentColor.withValues(alpha: 0.55)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, 4 / zoom),
    );
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

    // Always-visible ✎ after each link run (replaced the old faint-underline
    // "editable space" hint): tapping the glyph edits the link (display text
    // + destination) without opening it. Drawn at picture-record time, so it
    // costs nothing per frame.
    for (final spot in linkPencilSpots(el)) {
      final glyph = TextPainter(
        text: TextSpan(
          text: '✎',
          style: TextStyle(
            fontSize: spot.rect.height,
            color: kLinkColor.withValues(alpha: 0.8),
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      glyph.paint(canvas, spot.rect.topLeft);
      glyph.dispose();
    }
    canvas.restore();
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
      // Stay hidden until the pull clearly passes the floor, so the "+" never
      // flashes during ordinary edge-scrolling. From the floor it fades/fills
      // up to the threshold (where releasing adds the page).
      if (progress <= CanvasController.overscrollHintFloor) return;
      const floor = CanvasController.overscrollHintFloor;
      const span = CanvasController.overscrollThreshold - floor;
      final t = ((progress - floor) / span).clamp(0.0, 1.0);
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

