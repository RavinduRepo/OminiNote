import 'dart:ui';

import '../models/canvas_page.dart';
import '../utils/readable_text.dart';

/// The app-level PDF text model. It's populated from **pdfium's own text layer**
/// (see `RenderCache.pdfPageText`), reusing the document already open for
/// rendering — no separate whole-document parse. All rects are in the *original*
/// PDF page coordinate system (points) with a **top-left origin** (RenderCache
/// converts from pdfium's bottom-left origin); callers scale to the canvas page.

/// One extracted PDF text line: its text and bounds (top-left origin, points).
class PdfLineText {
  final String text;
  final double left, top, right, bottom;
  const PdfLineText(this.text, this.left, this.top, this.right, this.bottom);
}

/// One extracted PDF word: its text and bounds (top-left origin, points).
class PdfWordText {
  final String text;
  final double left, top, right, bottom;
  const PdfWordText(this.text, this.left, this.top, this.right, this.bottom);
}

/// A PDF page's extracted lines + words plus its original size (points), so the
/// caller can scale bounds to the canvas page (imported pages are normalized to
/// the canvas default width). [words] are in reading order (for word-level
/// selection); [lines] drive read-aloud + find. (Named `PdfTextPage`, not
/// `PdfPageText`, to avoid colliding with pdfrx's own `PdfPageText`.)
class PdfTextPage {
  final double width, height;
  final List<PdfLineText> lines;
  final List<PdfWordText> words;
  const PdfTextPage(this.width, this.height, this.lines, this.words);
}

/// Reads the imported-PDF text behind a PDF-backed page as one span — the page's
/// lines joined into flowing text (so sentences read naturally across wrapped
/// lines) carrying per-line boxes (so the read-along highlight can mark exactly
/// the wrapped lines a sentence spans, and a tap can hit-test a line). Line
/// bounds are scaled from the original PDF page size to the canvas page.
///
/// The page text is provided by a [resolve] callback (assetId, pageIndex) →
/// [PdfTextPage], so the source is decoupled from *how* the text is extracted
/// (today: pdfium via `RenderCache.pdfPageText`).
class PdfPageTextSource implements PageTextSource {
  PdfPageTextSource(this._resolve);

  final Future<PdfTextPage?> Function(String assetId, int pageIndex) _resolve;

  @override
  Future<List<ReadableSpan>> spansFor(CanvasPage page) async {
    final src = page.source;
    if (src == null) return const [];
    final pageText = await _resolve(src.assetId, src.pageIndex);
    if (pageText == null || pageText.lines.isEmpty) return const [];
    final scale = pageText.width > 0 ? page.width / pageText.width : 1.0;

    final buf = StringBuffer();
    final boxes = <SpanLineBox>[];
    for (final line in pageText.lines) {
      final t = line.text.trim();
      if (t.isEmpty) continue;
      if (buf.isNotEmpty) buf.write(' ');
      boxes.add(SpanLineBox(
        buf.length,
        Rect.fromLTRB(
          line.left * scale,
          line.top * scale,
          line.right * scale,
          line.bottom * scale,
        ),
      ));
      buf.write(t);
    }
    final text = buf.toString();
    if (text.trim().isEmpty || boxes.isEmpty) return const [];

    var union = boxes.first.rect;
    for (final b in boxes.skip(1)) {
      union = union.expandToInclude(b.rect);
    }
    return [
      ReadableSpan(
        text,
        bounds: union,
        sourceId: 'pdf:${src.assetId}#${src.pageIndex}',
        lineBoxes: boxes,
      ),
    ];
  }
}
