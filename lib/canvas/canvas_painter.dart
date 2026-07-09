import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:perfect_freehand/perfect_freehand.dart';
import '../models/canvas_page.dart';
import '../models/element.dart';
import 'canvas_controller.dart';
import 'canvas_layout.dart';
import 'text_measure.dart';

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

  @override
  void paint(Canvas canvas, Size size) {
    // Generous cull margin (canvas units) so edge pages aren't dropped.
    final visibleCanvasRect = Rect.fromPoints(
      controller.screenToCanvas(Offset.zero),
      controller.screenToCanvas(Offset(size.width, size.height)),
    ).inflate(300);

    canvas.save();
    canvas.transform(controller.viewportMatrix.storage);

    for (final l in controller.layout.pages) {
      if (!l.rect.overlaps(visibleCanvasRect)) continue;
      final page = controller.pages[l.pageId];
      if (page == null) continue;
      _paintPage(canvas, l, page);
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

    // Elements, clipped to the page.
    canvas.save();
    canvas.clipRect(rect);
    canvas.translate(rect.left, rect.top);

    for (final el in zOrderedElements(page)) {
      if (el.id == controller.editingElementId) continue; // text overlay open
      _paintElement(canvas, el);
    }

    // In-progress stroke on this page.
    if (controller.activeStrokePageId == page.id &&
        controller.activeStroke != null) {
      _paintStroke(canvas, controller.activeStroke!);
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
      outline = Path()..addPolygon(outlinePoints, true);
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
      canvas.drawRect(
        el.rect,
        Paint()..color = pageBorderColor.withValues(alpha: 0.3),
      );
    }
    canvas.restore();
  }

  void _paintPattern(Canvas canvas, Rect rect, PageBackground bg) {
    if (bg.pattern == BgPattern.blank) return;

    final isDark = bg.color.computeLuminance() < 0.4;
    final lineColor = isDark
        ? Colors.white.withValues(alpha: 0.14)
        : const Color(0xFF3B4A6B).withValues(alpha: 0.13);
    final paint = Paint()
      ..color = lineColor
      ..strokeWidth = 1 / controller.zoom.clamp(0.5, 4);

    const spacing = 26.0;
    switch (bg.pattern) {
      case BgPattern.ruled:
        for (var y = rect.top + spacing * 1.5;
            y < rect.bottom - 8;
            y += spacing) {
          canvas.drawLine(
            Offset(rect.left + 20, y),
            Offset(rect.right - 20, y),
            paint,
          );
        }
      case BgPattern.grid:
        for (var x = rect.left + spacing; x < rect.right; x += spacing) {
          canvas.drawLine(
            Offset(x, rect.top),
            Offset(x, rect.bottom),
            paint,
          );
        }
        for (var y = rect.top + spacing; y < rect.bottom; y += spacing) {
          canvas.drawLine(
            Offset(rect.left, y),
            Offset(rect.right, y),
            paint,
          );
        }
      case BgPattern.dotted:
        final dotPaint = Paint()..color = lineColor;
        final r = 1.4 / controller.zoom.clamp(0.5, 4);
        for (var x = rect.left + spacing; x < rect.right; x += spacing) {
          for (var y = rect.top + spacing; y < rect.bottom; y += spacing) {
            canvas.drawCircle(Offset(x, y), r, dotPaint);
          }
        }
      case BgPattern.blank:
        break;
    }
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

