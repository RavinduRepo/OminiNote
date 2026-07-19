import 'dart:io';
import 'dart:isolate';
import 'dart:ui';

import 'package:syncfusion_flutter_pdf/pdf.dart';

import '../models/canvas_page.dart';
import '../utils/readable_text.dart';

/// One extracted PDF text line: its text and bounds in the *original* PDF page
/// coordinate system (points, top-left origin — syncfusion's convention).
class PdfLineText {
  final String text;
  final double left, top, right, bottom;
  const PdfLineText(this.text, this.left, this.top, this.right, this.bottom);
}

/// A PDF page's extracted lines plus its original size (points), so the caller
/// can scale line bounds to the canvas page (imported pages are normalized to
/// the canvas default width).
class PdfPageText {
  final double width, height;
  final List<PdfLineText> lines;
  const PdfPageText(this.width, this.height, this.lines);
}

/// Extracts and caches the *positioned* text of imported PDF assets for
/// read-aloud (and the read-along highlight / tap-to-jump).
///
/// The per-asset extraction — loading the whole PDF and pulling every page's
/// text lines with bounds — runs off the main isolate (it's pure CPU that would
/// otherwise jank the canvas), mirroring how PDF *export* is offloaded. Results
/// are cached per asset so re-reading opens the document only once.
class PdfTextCache {
  PdfTextCache(this._fileForAsset);

  /// Resolves an asset id to its on-disk file (the canvas `assets/` dir).
  final File Function(String assetId) _fileForAsset;

  // assetId → future list of per-page text (list index = PDF page index).
  final _byAsset = <String, Future<List<PdfPageText>>>{};

  /// The extracted lines of one PDF page, or null when the asset can't be read
  /// or the page carries no text layer (e.g. a scanned image — a future OCR
  /// source would cover that).
  Future<PdfPageText?> page(String assetId, int pageIndex) async {
    final pages =
        await _byAsset.putIfAbsent(assetId, () => _extractAsset(assetId));
    if (pageIndex < 0 || pageIndex >= pages.length) return null;
    return pages[pageIndex];
  }

  Future<List<PdfPageText>> _extractAsset(String assetId) async {
    try {
      final bytes = await _fileForAsset(assetId).readAsBytes();
      try {
        return await Isolate.run(() => _extractAllPages(bytes));
      } catch (_) {
        // A hiccup spawning the isolate must never break reading — do it inline.
        return _extractAllPages(bytes);
      }
    } catch (_) {
      return const <PdfPageText>[];
    }
  }

  /// Drops cached extractions (e.g. on canvas dispose).
  void clear() => _byAsset.clear();
}

/// Pure, isolate-safe: given PDF bytes, return each page's lines + original size.
List<PdfPageText> _extractAllPages(List<int> bytes) {
  PdfDocument? doc;
  try {
    doc = PdfDocument(inputBytes: bytes);
    final extractor = PdfTextExtractor(doc);
    final count = doc.pages.count;
    final out = <PdfPageText>[];
    for (var i = 0; i < count; i++) {
      final size = doc.pages[i].size;
      final lines = extractor.extractTextLines(
        startPageIndex: i,
        endPageIndex: i,
      );
      out.add(PdfPageText(size.width, size.height, [
        for (final l in lines)
          if (l.text.trim().isNotEmpty)
            PdfLineText(
              l.text,
              l.bounds.left,
              l.bounds.top,
              l.bounds.right,
              l.bounds.bottom,
            ),
      ]));
    }
    return out;
  } catch (_) {
    return const <PdfPageText>[];
  } finally {
    doc?.dispose();
  }
}

/// Reads the imported-PDF text behind a PDF-backed page as one span — the page's
/// lines joined into flowing text (so sentences read naturally across wrapped
/// lines) carrying per-line boxes (so the read-along highlight can mark exactly
/// the wrapped lines a sentence spans, and a tap can hit-test a line). Line
/// bounds are scaled from the original PDF page size to the canvas page.
class PdfPageTextSource implements PageTextSource {
  PdfPageTextSource(this._cache);

  final PdfTextCache _cache;

  @override
  Future<List<ReadableSpan>> spansFor(CanvasPage page) async {
    final src = page.source;
    if (src == null) return const [];
    final pageText = await _cache.page(src.assetId, src.pageIndex);
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
