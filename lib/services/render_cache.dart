import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:pdfrx/pdfrx.dart';

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
  }
}

class _CachedPdfImage {
  final ui.Image image;
  final double bucket;
  _CachedPdfImage(this.image, this.bucket);
}
