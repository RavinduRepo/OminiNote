import 'package:flutter/foundation.dart';
import '../models/canvas.dart';
import '../models/canvas_page.dart';

/// App-global clipboard for a whole copied page, so a page can be pasted into a
/// different canvas / section / notebook. Holds an independent snapshot of the
/// page plus the source [Canvas] (needed to copy the page's assets on paste).
class PageClipboard {
  static final PageClipboard _instance = PageClipboard._();
  factory PageClipboard() => _instance;
  PageClipboard._();

  Canvas? _sourceCanvas;
  CanvasPage? _page;

  /// True when a page is available to paste — bind UI enablement to this.
  final ValueNotifier<bool> hasPage = ValueNotifier(false);

  Canvas? get sourceCanvas => _sourceCanvas;
  CanvasPage? get page => _page;

  /// Snapshots [page] (a fresh clone, so later edits to the original don't
  /// change what gets pasted) and remembers its [source] canvas for assets.
  void copy(Canvas source, CanvasPage page) {
    _sourceCanvas = source;
    _page = page.cloneWithNewIds(deviceId: page.deviceId);
    hasPage.value = true;
  }

  void clear() {
    _sourceCanvas = null;
    _page = null;
    hasPage.value = false;
  }
}
