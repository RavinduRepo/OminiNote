import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:pdfrx/pdfrx.dart';

import 'pdf_text_extractor.dart';

/// Renders pages of imported PDFs to [ui.Image]s and caches them, and decodes
/// raster image assets. pdfrx is used purely as a *renderer* here — the app
/// owns the viewport (spec §6), so `PdfViewer` and its gestures are not used.
///
/// The painter asks synchronously via [pdfPageImage]/[rasterImage]; a miss
/// kicks off an async render and [onUpdated] fires when it lands, letting the
/// canvas repaint.
class RenderCache {
  RenderCache({required this.onUpdated});

  /// Called whenever a new image becomes available.
  final void Function() onUpdated;

  final _docs = <String, Future<PdfDocument>>{};
  final _outlines = <String, Future<List<PdfOutlineEntry>>>{};
  final _pdfText = <String, Future<PdfTextPage?>>{};
  // Insertion-ordered map used as an LRU (re-insert on touch, evict oldest).
  final _pdfImages = <String, _CachedPdfImage>{};
  final _pdfPending = <String>{};
  final _rasters = <String, ui.Image>{};
  final _rasterPending = <String>{};

  /// Rendered-resolution buckets (page points → pixels multiplier). Rendering
  /// re-runs only when the viewport zoom crosses into a higher bucket.
  static const _scaleBuckets = [0.75, 1.0, 1.5, 2.0, 3.0];
  static const _maxCachedPdfImages = 20;

  Future<PdfDocument> _open(String path) =>
      _docs.putIfAbsent(path, () => PdfDocument.openFile(path));

  /// Page sizes of a PDF in points (pdfium reports 72dpi units).
  Future<List<ui.Size>> pdfPageSizes(String path) async {
    final doc = await _open(path);
    return [for (final p in doc.pages) ui.Size(p.width, p.height)];
  }

  /// The PDF's document outline (table of contents) as an app-level tree, with
  /// pdfrx's 1-based destination page numbers converted to 0-based page
  /// indices. Cached per path; an outline-less or unreadable PDF yields `[]`.
  Future<List<PdfOutlineEntry>> pdfOutline(String path) =>
      _outlines.putIfAbsent(path, () async {
        try {
          final doc = await _open(path);
          return _mapOutline(await doc.loadOutline());
        } catch (_) {
          return const [];
        }
      });

  static List<PdfOutlineEntry> _mapOutline(List<PdfOutlineNode> nodes) => [
        for (final n in nodes)
          PdfOutlineEntry(
            title: n.title,
            pageIndex: n.dest != null ? n.dest!.pageNumber - 1 : null,
            children: _mapOutline(n.children),
          ),
      ];

  /// One PDF page's text from **pdfium's own text layer** — reusing the already-
  /// open render document (no second full-document parse, no whole-file read, no
  /// main-thread byte copy), on pdfium's background worker, per page. Rects are
  /// converted from pdfium's bottom-left origin to the app's top-left origin (in
  /// PDF points); callers scale to the canvas page. Cached per (path, pageIndex);
  /// a page with no text layer (scanned) yields empty lines/words. Null on error.
  Future<PdfTextPage?> pdfPageText(String path, int pageIndex) {
    final key = '$path#$pageIndex';
    return _pdfText.putIfAbsent(key, () async {
      try {
        final doc = await _open(path);
        if (pageIndex < 0 || pageIndex >= doc.pages.length) return null;
        final page = doc.pages[pageIndex];
        final ph = page.height; // page height in points (for the Y-flip)
        final st = await page.loadStructuredText();
        final lines = <PdfLineText>[];
        final words = <PdfWordText>[];
        for (final f in st.fragments) {
          final b = f.bounds;
          if (f.text.trim().isNotEmpty) {
            lines.add(PdfLineText(
                f.text, b.left, ph - b.top, b.right, ph - b.bottom));
          }
          _splitWords(f, ph, words);
        }
        return PdfTextPage(page.width, page.height, lines, words);
      } catch (_) {
        return null;
      }
    });
  }

  /// Splits a fragment into words on whitespace, each word's rect = the union of
  /// its (non-space) character boxes, converted to top-left origin.
  static void _splitWords(
      PdfPageTextFragment f, double ph, List<PdfWordText> out) {
    final text = f.text;
    final rects = f.charRects;
    final n = text.length < rects.length ? text.length : rects.length;
    var start = -1;
    double wl = 0, wr = 0, wt = 0, wb = 0;
    void flush(int endExclusive) {
      if (start < 0) return;
      final w = text.substring(start, endExclusive).trim();
      if (w.isNotEmpty) {
        out.add(PdfWordText(w, wl, ph - wt, wr, ph - wb));
      }
      start = -1;
    }

    for (var i = 0; i < n; i++) {
      if (text[i].trim().isEmpty) {
        flush(i);
        continue;
      }
      final r = rects[i];
      if (start < 0) {
        start = i;
        wl = r.left;
        wr = r.right;
        wt = r.top;
        wb = r.bottom;
      } else {
        if (r.left < wl) wl = r.left;
        if (r.right > wr) wr = r.right;
        if (r.top > wt) wt = r.top;
        if (r.bottom < wb) wb = r.bottom;
      }
    }
    flush(n);
  }

  static double _bucketFor(double scale) => _scaleBuckets.firstWhere(
    (b) => b >= scale,
    orElse: () => _scaleBuckets.last,
  );

  /// Cached bitmap for a PDF page, or null while it renders. [scale] is the
  /// current on-screen pixels-per-point for the page.
  ui.Image? pdfPageImage(String path, int pageIndex, double scale) {
    final key = '$path#$pageIndex';
    final bucket = _bucketFor(scale);
    final cached = _pdfImages[key];
    if (cached != null) {
      // LRU touch.
      _pdfImages.remove(key);
      _pdfImages[key] = cached;
      if (cached.bucket >= bucket) return cached.image;
      // Needs a sharper render; keep showing the old one meanwhile.
      _renderPdfPage(path, pageIndex, bucket);
      return cached.image;
    }
    _renderPdfPage(path, pageIndex, bucket);
    return null;
  }

  Future<void> _renderPdfPage(String path, int pageIndex, double bucket) async {
    final key = '$path#$pageIndex';
    if (_pdfPending.contains(key)) return;
    _pdfPending.add(key);
    try {
      final doc = await _open(path);
      if (pageIndex < 0 || pageIndex >= doc.pages.length) return;
      final page = doc.pages[pageIndex];

      // Cap the pixel count so a huge page at high zoom can't blow memory.
      var w = page.width * bucket;
      var h = page.height * bucket;
      const maxPixels = 12_000_000;
      if (w * h > maxPixels) {
        final f = maxPixels / (w * h);
        w *= f;
        h *= f;
      }

      final pdfImage = await page.render(
        fullWidth: w,
        fullHeight: h,
        backgroundColor: 0xFFFFFFFF,
      );
      if (pdfImage == null) return;
      final image = await pdfImage.createImage();
      pdfImage.dispose();

      final old = _pdfImages.remove(key);
      old?.image.dispose();
      _pdfImages[key] = _CachedPdfImage(image, bucket);
      _evictIfNeeded();
      onUpdated();
    } catch (_) {
      // Render failure: leave the page blank rather than crash the canvas.
    } finally {
      _pdfPending.remove(key);
    }
  }

  void _evictIfNeeded() {
    while (_pdfImages.length > _maxCachedPdfImages) {
      final oldestKey = _pdfImages.keys.first;
      _pdfImages.remove(oldestKey)?.image.dispose();
    }
  }

  /// Cached decode of a raster asset (images placed on pages), or null while
  /// decoding.
  ui.Image? rasterImage(File file) {
    final key = file.path;
    final cached = _rasters[key];
    if (cached != null) return cached;
    if (!_rasterPending.contains(key)) {
      _rasterPending.add(key);
      _decodeRaster(file);
    }
    return null;
  }

  Future<void> _decodeRaster(File file) async {
    try {
      final bytes = await file.readAsBytes();
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      _rasters[file.path] = frame.image;
      onUpdated();
    } catch (_) {
      // Undecodable image: painter keeps drawing the placeholder.
    } finally {
      _rasterPending.remove(file.path);
    }
  }

  void dispose() {
    for (final c in _pdfImages.values) {
      c.image.dispose();
    }
    _pdfImages.clear();
    for (final img in _rasters.values) {
      img.dispose();
    }
    _rasters.clear();
    for (final doc in _docs.values) {
      doc.then((d) => d.dispose()).catchError((_) {});
    }
    _docs.clear();
    _outlines.clear();
    _pdfText.clear();
  }
}

class _CachedPdfImage {
  final ui.Image image;
  final double bucket;
  _CachedPdfImage(this.image, this.bucket);
}

/// One node of a PDF's table of contents, flattened from pdfrx's outline. A
/// null [pageIndex] means the entry has no jump destination (a plain header).
class PdfOutlineEntry {
  final String title;
  final int? pageIndex; // 0-based into the PDF
  final List<PdfOutlineEntry> children;
  const PdfOutlineEntry({
    required this.title,
    required this.pageIndex,
    required this.children,
  });
}
