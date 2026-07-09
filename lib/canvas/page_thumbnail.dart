import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:perfect_freehand/perfect_freehand.dart';
import '../models/canvas_page.dart';
import '../models/element.dart';
import '../services/render_cache.dart';
import 'text_measure.dart';

/// A small, read-only preview of a [CanvasPage]'s actual content (background,
/// pattern, PDF bitmap, ink, text, images), scaled to fit its box. Used by the
/// page-organizer grid. Deliberately self-contained so it can't destabilise the
/// live [CanvasPainter]; it reuses the same primitives (perfect_freehand stroke
/// outlines cached on the element, [RenderCache] for PDF/raster assets, and the
/// shared text span builder).
class PageThumbnail extends StatelessWidget {
  final CanvasPage page;
  final RenderCache renderCache;
  final File Function(String assetId) assetFileOf;

  const PageThumbnail({
    super.key,
    required this.page,
    required this.renderCache,
    required this.assetFileOf,
  });

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: page.width / page.height,
      child: CustomPaint(
        painter: _PageThumbnailPainter(
          page: page,
          renderCache: renderCache,
          assetFileOf: assetFileOf,
        ),
        size: Size.infinite,
      ),
    );
  }
}

class _PageThumbnailPainter extends CustomPainter {
  final CanvasPage page;
  final RenderCache renderCache;
  final File Function(String assetId) assetFileOf;

  _PageThumbnailPainter({
    required this.page,
    required this.renderCache,
    required this.assetFileOf,
  });

  static const _border = Color(0xFFC9CDD6);

  @override
  void paint(Canvas canvas, Size size) {
    final scale = size.width / page.width;
    canvas.save();
    canvas.scale(scale);
    final pageRect = Rect.fromLTWH(0, 0, page.width, page.height);

    // Background.
    canvas.drawRect(pageRect, Paint()..color = page.background.color);

    if (page.source != null) {
      final img = renderCache.pdfPageImage(
        assetFileOf(page.source!.assetId).path,
        page.source!.pageIndex,
        scale,
      );
      if (img != null) {
        canvas.drawImageRect(
          img,
          Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()),
          pageRect,
          Paint()..filterQuality = FilterQuality.low,
        );
      }
    } else {
      _paintPattern(canvas, pageRect, page.background);
    }

    // Elements, clipped to the page.
    canvas.save();
    canvas.clipRect(pageRect);
    for (final el in zOrderedElements(page)) {
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
    canvas.restore();

    // Hairline border.
    canvas.drawRect(
      pageRect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1 / scale
        ..color = _border,
    );
    canvas.restore();
  }

  void _paintStroke(Canvas canvas, StrokeElement stroke) {
    if (stroke.points.isEmpty) return;
    final isHighlighter = stroke.tool == StrokeTool.highlighter;
    var outline = stroke.cachedOutline;
    if (outline == null) {
      final pts = [for (final p in stroke.points) PointVector(p.x, p.y, p.p)];
      final poly = getStroke(
        pts,
        options: StrokeOptions(
          size: isHighlighter ? stroke.size * 2.6 : stroke.size,
          thinning: isHighlighter ? 0.0 : 0.6,
          smoothing: 0.6,
          streamline: 0.6,
          simulatePressure: false,
        ),
      );
      if (poly.isEmpty) return;
      outline = Path()..addPolygon(poly, true);
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
    final tp = TextPainter(
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
    tp.paint(canvas, el.rect.topLeft);
    canvas.restore();
  }

  void _paintImage(Canvas canvas, ImageElement el) {
    final ui.Image? img = renderCache.rasterImage(assetFileOf(el.assetId));
    canvas.save();
    if (el.rotation != 0) {
      final c = el.rect.center;
      canvas.translate(c.dx, c.dy);
      canvas.rotate(el.rotation);
      canvas.translate(-c.dx, -c.dy);
    }
    if (img != null) {
      canvas.drawImageRect(
        img,
        Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()),
        el.rect,
        Paint()..filterQuality = FilterQuality.low,
      );
    } else {
      canvas.drawRect(el.rect, Paint()..color = _border.withValues(alpha: 0.3));
    }
    canvas.restore();
  }

  void _paintAttachment(Canvas canvas, AttachmentElement el) {
    canvas.drawRRect(
      RRect.fromRectAndRadius(el.rect, const Radius.circular(4)),
      Paint()..color = const Color(0xFFF0EFEA),
    );
  }

  void _paintPattern(Canvas canvas, Rect rect, PageBackground bg) {
    if (bg.pattern == BgPattern.blank) return;
    final isDark = bg.color.computeLuminance() < 0.4;
    final lineColor = isDark
        ? Colors.white.withValues(alpha: 0.14)
        : const Color(0xFF3B4A6B).withValues(alpha: 0.13);
    final paint = Paint()
      ..color = lineColor
      ..strokeWidth = 1;
    const spacing = 26.0;
    switch (bg.pattern) {
      case BgPattern.ruled:
        for (var y = rect.top + spacing * 1.5; y < rect.bottom - 8; y += spacing) {
          canvas.drawLine(Offset(rect.left + 20, y), Offset(rect.right - 20, y), paint);
        }
      case BgPattern.grid:
        for (var x = rect.left + spacing; x < rect.right; x += spacing) {
          canvas.drawLine(Offset(x, rect.top), Offset(x, rect.bottom), paint);
        }
        for (var y = rect.top + spacing; y < rect.bottom; y += spacing) {
          canvas.drawLine(Offset(rect.left, y), Offset(rect.right, y), paint);
        }
      case BgPattern.dotted:
        final dot = Paint()..color = lineColor;
        for (var x = rect.left + spacing; x < rect.right; x += spacing) {
          for (var y = rect.top + spacing; y < rect.bottom; y += spacing) {
            canvas.drawCircle(Offset(x, y), 1.1, dot);
          }
        }
      case BgPattern.blank:
        break;
    }
  }

  @override
  bool shouldRepaint(_PageThumbnailPainter old) =>
      old.page != page || old.page.rev != page.rev;
}
