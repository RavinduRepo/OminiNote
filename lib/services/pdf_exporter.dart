import 'dart:typed_data';
import 'dart:ui' show Color, Offset, Rect, Size;
import 'package:perfect_freehand/perfect_freehand.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart' as sf;
import '../canvas/text_measure.dart' show placedRunFragments, kLinkColor;
import '../models/canvas_page.dart';
import '../models/element.dart';
import '../models/canvas.dart';

/// Thin interface so the PDF library stays swappable (spec §10.3).
abstract class PdfExporter {
  /// Renders [canvas] to PDF bytes. [assetBytes] resolves an assetId to the
  /// stored file's bytes (imported PDFs, images).
  Future<Uint8List> export({
    required Canvas canvas,
    required Map<String, CanvasPage> pages,
    required Future<Uint8List> Function(String assetId) assetBytes,
  });
}

/// Vector export via Syncfusion (Community License):
/// - one Row → one PDF page; a multi-page row merges flush into one wide
///   landscape page (spec §10.1)
/// - PDF-backed pages draw the *original* imported page as a vector template,
///   so its text stays selectable and files stay small
/// - strokes become filled vector paths (pressure-varied width preserved via
///   the same perfect_freehand outline used on screen)
/// - text becomes real, selectable PDF text; images are embedded
/// - background pattern (ruled/grid/dotted) is drawn as vector lines/dots on
///   blank pages, mirroring the on-screen pattern geometry
class SyncfusionPdfExporter implements PdfExporter {
  @override
  Future<Uint8List> export({
    required Canvas canvas,
    required Map<String, CanvasPage> pages,
    required Future<Uint8List> Function(String assetId) assetBytes,
  }) async {
    final out = sf.PdfDocument();
    out.pageSettings.margins.all = 0;
    _assetBytesRef = assetBytes;
    _bitmapCache.clear();
    _runFontCache.clear();
    _referencedAttachments.clear();
    _embedNameByAsset.clear();
    _usedEmbedNames.clear();

    // Source PDFs opened once per asset; templates per (asset, pageIndex).
    final srcDocs = <String, sf.PdfDocument>{};
    final templates = <String, sf.PdfTemplate>{};

    Future<sf.PdfTemplate?> templateFor(PdfSource source) async {
      final key = '${source.assetId}#${source.pageIndex}';
      final cached = templates[key];
      if (cached != null) return cached;
      try {
        final doc = srcDocs[source.assetId] ??= sf.PdfDocument(
          inputBytes: await assetBytes(source.assetId),
        );
        if (source.pageIndex >= doc.pages.count) return null;
        final template = doc.pages[source.pageIndex].createTemplate();
        templates[key] = template;
        return template;
      } catch (_) {
        return null; // unreadable source: export the annotations alone
      }
    }

    try {
      for (final row in canvas.rows) {
        final rowPages = [
          for (final id in row.pageIds)
            if (pages[id] != null) pages[id]!,
        ];
        if (rowPages.isEmpty) continue;

        // Merged size: widths sum flush (no gap), height = tallest page.
        var totalW = 0.0, maxH = 0.0;
        for (final p in rowPages) {
          totalW += p.width;
          if (p.height > maxH) maxH = p.height;
        }

        final pdfSection = out.sections!.add();
        // Assign a *fresh* PdfPageSettings rather than mutating `.size` on the
        // existing one: PdfPageSettings.size's setter re-derives width/height
        // as (min, max) of whatever orientation is currently set (default
        // portrait), silently swapping them whenever width > height. That
        // clips every horizontally-merged row and every landscape-shaped PDF
        // page onto a taller/narrower page than intended. Constructing a new
        // PdfPageSettings with just a size (no orientation argument) stores it
        // verbatim instead.
        pdfSection.pageSettings = sf.PdfPageSettings(Size(totalW, maxH))
          ..margins.all = 0;
        final page = pdfSection.pages.add();
        final g = page.graphics;

        var xOffset = 0.0;
        for (final p in rowPages) {
          await _drawPage(page, g, p, xOffset, templateFor);
          xOffset += p.width;
        }
      }

      // Embed each referenced attachment file into the output document under
      // the exact name the chip's click action targets (readers also list
      // embedded files in the attachments panel).
      final embedded = <String>{};
      for (final att in _referencedAttachments) {
        if (!embedded.add(att.assetId)) continue;
        try {
          out.attachments.add(
            sf.PdfAttachment(
              _embedNameFor(att),
              await assetBytes(att.assetId),
              description: 'Omininote attachment',
              mimeType: att.mime,
            ),
          );
        } catch (_) {
          // Missing/unreadable asset: chip still exports, file just isn't
          // embedded.
        }
      }

      final bytes = await out.save();
      return Uint8List.fromList(bytes);
    } finally {
      _assetBytesRef = null;
      _bitmapCache.clear();
      _referencedAttachments.clear();
      out.dispose();
      for (final doc in srcDocs.values) {
        doc.dispose();
      }
    }
  }

  Future<void> _drawPage(
    sf.PdfPage pdfPage,
    sf.PdfGraphics g,
    CanvasPage page,
    double xOffset,
    Future<sf.PdfTemplate?> Function(PdfSource) templateFor,
  ) async {
    // Background color (skip pure white — it's the paper).
    if (page.background.color.toARGB32() != 0xFFFFFFFF) {
      g.drawRectangle(
        brush: sf.PdfSolidBrush(_pdfColor(page.background.color)),
        bounds: Rect.fromLTWH(xOffset, 0, page.width, page.height),
      );
    }

    // Original PDF page as vector background.
    if (page.source != null) {
      final template = await templateFor(page.source!);
      if (template != null) {
        g.drawPdfTemplate(
          template,
          Offset(xOffset, 0),
          Size(page.width, page.height),
        );
      }
    } else {
      // Background pattern (blank pages only — a PDF page's imported content
      // fully covers the page, same as on screen).
      _drawPattern(g, page, xOffset);
    }

    // Elements in z-order (same combined ordering as the on-screen painter).
    for (final el in zOrderedElements(page)) {
      switch (el) {
        case StrokeElement():
          _drawStroke(g, el, xOffset);
        case TextElement():
          _drawText(g, el, xOffset);
        case ImageElement():
          await _drawImage(g, el, xOffset);
        case AttachmentElement():
          _drawAttachmentChip(g, el, xOffset);
          _addChipClickAction(pdfPage, el, xOffset);
          _referencedAttachments.add(el);
      }
    }
  }

  /// Attachment chips seen while drawing pages; their files are embedded into
  /// the output document after the page loop (PDF "attachments" panel — the
  /// Flutter Syncfusion API has no in-page file annotation, so the chip is
  /// the visual pointer and the embedded file is the actual payload).
  final List<AttachmentElement> _referencedAttachments = [];

  /// Embedded-attachment name per assetId — must be unique inside the PDF and
  /// identical between the chip's click action and the embedded file, since
  /// `exportDataObject` looks the attachment up by name.
  final Map<String, String> _embedNameByAsset = {};
  final Set<String> _usedEmbedNames = {};

  String _embedNameFor(AttachmentElement el) {
    final existing = _embedNameByAsset[el.assetId];
    if (existing != null) return existing;
    var name = el.name;
    var n = 1;
    while (!_usedEmbedNames.add(name)) {
      name = '${++n}_${el.name}';
    }
    _embedNameByAsset[el.assetId] = name;
    return name;
  }

  /// Makes the chip clickable in the exported PDF: an invisible action
  /// annotation over its bounds runs Acrobat JavaScript that saves-and-opens
  /// the embedded attachment (`exportDataObject`, nLaunch:2). This is the
  /// closest thing to an embedded-file hyperlink the PDF spec offers without
  /// GoToE (which Syncfusion Flutter doesn't expose); works in Acrobat/Foxit
  /// class readers — simpler viewers still reach the file via the reader's
  /// attachments (paperclip) panel.
  void _addChipClickAction(
    sf.PdfPage pdfPage,
    AttachmentElement el,
    double xOffset,
  ) {
    final name = _embedNameFor(
      el,
    ).replaceAll('\\', r'\\').replaceAll('"', r'\"');
    final annotation = sf.PdfActionAnnotation(
      Rect.fromLTWH(
        el.rect.left + xOffset,
        el.rect.top,
        el.rect.width,
        el.rect.height,
      ),
      sf.PdfJavaScriptAction(
        'this.exportDataObject({cName:"$name", nLaunch:2});',
      ),
    );
    annotation.border = sf.PdfAnnotationBorder(0, 0, 0); // no visible frame
    pdfPage.annotations.add(annotation);
  }

  /// Mirrors CanvasPainter._paintAttachment: rounded chip, red document glyph
  /// with folded corner, ellipsized file name.
  void _drawAttachmentChip(
    sf.PdfGraphics g,
    AttachmentElement el,
    double xOffset,
  ) {
    final r = Rect.fromLTWH(
      el.rect.left + xOffset,
      el.rect.top,
      el.rect.width,
      el.rect.height,
    );

    g.drawRectangle(
      brush: sf.PdfSolidBrush(sf.PdfColor(0xF4, 0xF1, 0xEA)),
      pen: sf.PdfPen(sf.PdfColor(0xB9, 0xB2, 0xA4), width: 1),
      bounds: r,
    );

    final gh = r.height * 0.62;
    final gw = gh * 0.78;
    final gx = r.left + r.height * 0.22;
    final gy = r.center.dy - gh / 2;
    const fold = 0.32;
    final doc = sf.PdfPath()
      ..addPolygon([
        Offset(gx, gy),
        Offset(gx + gw * (1 - fold), gy),
        Offset(gx + gw, gy + gh * fold),
        Offset(gx + gw, gy + gh),
        Offset(gx, gy + gh),
      ]);
    g.drawPath(doc, brush: sf.PdfSolidBrush(sf.PdfColor(0xD9, 0x53, 0x4F)));
    final foldPath = sf.PdfPath()
      ..addPolygon([
        Offset(gx + gw * (1 - fold), gy),
        Offset(gx + gw * (1 - fold), gy + gh * fold),
        Offset(gx + gw, gy + gh * fold),
      ]);
    g.drawPath(
      foldPath,
      brush: sf.PdfSolidBrush(sf.PdfColor(0xB2, 0x3C, 0x38)),
    );

    final textLeft = gx + gw + r.height * 0.2;
    final maxW = r.right - textLeft - 8;
    if (maxW > 12) {
      final fontSize = (r.height * 0.32).clamp(9.0, 14.0);
      g.drawString(
        el.name,
        sf.PdfStandardFont(
          sf.PdfFontFamily.helvetica,
          fontSize,
          style: sf.PdfFontStyle.bold,
        ),
        brush: sf.PdfSolidBrush(sf.PdfColor(0x2B, 0x2B, 0x2B)),
        bounds: Rect.fromLTWH(textLeft, r.top, maxW, r.height),
        format: sf.PdfStringFormat(
          alignment: sf.PdfTextAlignment.left,
          lineAlignment: sf.PdfVerticalAlignment.middle,
        ),
      );
    }
  }

  /// Mirrors CanvasPainter._paintPattern's geometry (26pt spacing, same
  /// insets) so the exported page matches what's shown on screen.
  void _drawPattern(sf.PdfGraphics g, CanvasPage page, double xOffset) {
    final bg = page.background;
    if (bg.pattern == BgPattern.blank) return;

    final isDark = bg.color.computeLuminance() < 0.4;
    final lineColor = isDark
        ? sf.PdfColor(255, 255, 255, 36) // ~0.14 alpha
        : sf.PdfColor(0x3B, 0x4A, 0x6B, 33); // ~0.13 alpha

    const spacing = 26.0;
    final left = xOffset, top = 0.0;
    final right = xOffset + page.width, bottom = page.height;

    switch (bg.pattern) {
      case BgPattern.ruled:
        final pen = sf.PdfPen(lineColor, width: 0.6);
        for (var y = top + spacing * 1.5; y < bottom - 8; y += spacing) {
          g.drawLine(pen, Offset(left + 20, y), Offset(right - 20, y));
        }
      case BgPattern.grid:
        final pen = sf.PdfPen(lineColor, width: 0.6);
        for (var x = left + spacing; x < right; x += spacing) {
          g.drawLine(pen, Offset(x, top), Offset(x, bottom));
        }
        for (var y = top + spacing; y < bottom; y += spacing) {
          g.drawLine(pen, Offset(left, y), Offset(right, y));
        }
      case BgPattern.dotted:
        final brush = sf.PdfSolidBrush(lineColor);
        const r = 1.2;
        for (var x = left + spacing; x < right; x += spacing) {
          for (var y = top + spacing; y < bottom; y += spacing) {
            g.drawEllipse(
              Rect.fromLTWH(x - r, y - r, r * 2, r * 2),
              brush: brush,
            );
          }
        }
      case BgPattern.blank:
        break;
    }
  }

  void _drawStroke(sf.PdfGraphics g, StrokeElement stroke, double xOffset) {
    if (stroke.points.isEmpty) return;
    final isHighlighter = stroke.tool == StrokeTool.highlighter;

    // Identical outline math to the on-screen painter → identical shape.
    final outline = getStroke(
      [for (final p in stroke.points) PointVector(p.x, p.y, p.p)],
      options: StrokeOptions(
        size: isHighlighter ? stroke.size * 2.6 : stroke.size,
        thinning: isHighlighter ? 0.0 : 0.6,
        smoothing: 0.6,
        streamline: 0.6,
        simulatePressure: false,
      ),
    );
    if (outline.isEmpty) return;

    final path = sf.PdfPath()
      ..addPolygon([for (final o in outline) Offset(o.dx + xOffset, o.dy)]);
    final brush = sf.PdfSolidBrush(_pdfColor(stroke.color));

    if (isHighlighter) {
      final state = g.save();
      g.setTransparency(0.35);
      g.drawPath(path, brush: brush);
      g.restore(state);
    } else {
      g.drawPath(path, brush: brush);
    }
  }

  /// Per-(family,size,bold,italic) standard-font cache for run fragments.
  final _runFontCache = <String, sf.PdfStandardFont>{};

  sf.PdfStandardFont _fontForRun(TextRun r) {
    final key = '${r.fontFamily}|${r.fontSize}|${r.bold}|${r.italic}';
    return _runFontCache[key] ??= () {
      final family = switch (r.fontFamily) {
        'serif' => sf.PdfFontFamily.timesRoman,
        'mono' => sf.PdfFontFamily.courier,
        _ => sf.PdfFontFamily.helvetica,
      };
      final styles = <sf.PdfFontStyle>[
        if (r.bold) sf.PdfFontStyle.bold,
        if (r.italic) sf.PdfFontStyle.italic,
      ];
      return styles.isEmpty
          ? sf.PdfStandardFont(family, r.fontSize)
          : sf.PdfStandardFont(family, r.fontSize, multiStyle: styles);
    }();
  }

  /// Draws rich text **per styled run fragment**: the fragments (and thus
  /// line breaks, wrapping, and alignment) come from the exact same
  /// `TextPainter` layout the on-screen painter uses (`placedRunFragments`),
  /// and each fragment is drawn with its own font/size/style/color — so
  /// mixed-style boxes (rich paste, per-range styling) export faithfully
  /// instead of collapsing to the box's base style.
  void _drawText(sf.PdfGraphics g, TextElement el, double xOffset) {
    if (el.text.trim().isEmpty) return;
    final fragments = placedRunFragments(el);
    if (fragments.isEmpty) return;

    void drawAll(double ox, double oy) {
      for (final f in fragments) {
        // The screen line box is 1.3× the font size with the glyphs roughly
        // centered; PDF draws from the glyph top, so nudge down to line the
        // tops up.
        final y = oy + f.offset.dy + f.run.fontSize * 0.15;
        final isLink = f.run.link != null;
        final color = isLink ? _pdfColor(kLinkColor) : _pdfColor(f.run.color);
        final font = _fontForRun(f.run);
        final x = ox + f.offset.dx;
        g.drawString(
          f.text,
          font,
          brush: sf.PdfSolidBrush(color),
          // Zero-size bounds = draw unclipped from this point.
          bounds: Rect.fromLTWH(x, y, 0, 0),
        );
        // Underline link runs to match the on-screen link styling.
        if (isLink) {
          final w = font.measureString(f.text).width;
          final uy = y + f.run.fontSize * 1.05;
          g.drawLine(
            sf.PdfPen(color, width: 0.6),
            Offset(x, uy),
            Offset(x + w, uy),
          );
        }
      }
    }

    if (el.rotation != 0) {
      final state = g.save();
      final cx = el.rect.center.dx + xOffset, cy = el.rect.center.dy;
      g.translateTransform(cx, cy);
      g.rotateTransform(el.rotation * 180 / 3.141592653589793);
      drawAll(-el.rect.width / 2, -el.rect.height / 2);
      g.restore(state);
    } else {
      drawAll(el.rect.left + xOffset, el.rect.top);
    }
  }

  final _bitmapCache = <String, sf.PdfBitmap>{};

  Future<void> _drawImage(
    sf.PdfGraphics g,
    ImageElement el,
    double xOffset,
  ) async {
    sf.PdfBitmap bitmap;
    try {
      bitmap = _bitmapCache[el.assetId] ??= sf.PdfBitmap(
        await _assetBytesRef!(el.assetId),
      );
    } catch (_) {
      return; // missing/undecodable asset: skip rather than fail the export
    }

    final rect = Rect.fromLTWH(
      el.rect.left + xOffset,
      el.rect.top,
      el.rect.width,
      el.rect.height,
    );

    if (el.rotation != 0) {
      final state = g.save();
      g.translateTransform(rect.center.dx, rect.center.dy);
      g.rotateTransform(el.rotation * 180 / 3.141592653589793);
      g.drawImage(
        bitmap,
        Rect.fromLTWH(
          -rect.width / 2,
          -rect.height / 2,
          rect.width,
          rect.height,
        ),
      );
      g.restore(state);
    } else {
      g.drawImage(bitmap, rect);
    }
  }

  // Held during export so element drawers can resolve image assets.
  Future<Uint8List> Function(String assetId)? _assetBytesRef;

  sf.PdfColor _pdfColor(Color c) {
    final argb = c.toARGB32();
    return sf.PdfColor((argb >> 16) & 0xFF, (argb >> 8) & 0xFF, argb & 0xFF);
  }
}
