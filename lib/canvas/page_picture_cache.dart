import 'dart:ui' as ui;

/// Per-page cache of the committed-elements layer as a recorded [ui.Picture].
///
/// The painter replays one picture per visible page instead of re-issuing
/// every stroke/text/image draw each frame, so pan/zoom cost is independent of
/// how much ink a page holds (pictures are vector — they scale cleanly with
/// the canvas transform). Only zoom-independent content may go in a picture;
/// zoom-dependent drawing (PDF background bitmap, hairline border, pattern
/// line widths, page-number badge, live stroke/lasso) stays outside.
///
/// Invalidation contract: any code path that visually mutates a page's
/// committed elements must call [invalidate] for that page (the controller
/// hooks this into `_markDirty`, the live eraser, live selection drags, and
/// remote merges). A missed site shows as stale ink until the next invalidate.
class PagePictureCache {
  final Map<String, _Entry> _entries = {};
  int _tick = 0;

  /// Enough for every page visible at min zoom plus scroll margin; pictures
  /// are command lists (small), this only bounds worst-case growth.
  static const int maxEntries = 24;

  void invalidate(String pageId) {
    _entries.remove(pageId)?.picture.dispose();
  }

  void invalidateAll() {
    for (final e in _entries.values) {
      e.picture.dispose();
    }
    _entries.clear();
  }

  /// Draws [pageId]'s cached picture onto [canvas], re-recording it via
  /// [record] when missing or stale. [skippedElementId] keys the entry (the
  /// painter omits the element an open text editor covers); [record] returns
  /// false when something it needed wasn't ready (an image raster still
  /// decoding) — the entry is then kept provisional and re-recorded next
  /// frame, matching today's draw-placeholder-until-decoded behavior.
  void paint(
    ui.Canvas canvas,
    String pageId, {
    required String? skippedElementId,
    required bool Function(ui.Canvas) record,
  }) {
    _tick++;
    var entry = _entries[pageId];
    if (entry == null ||
        entry.skippedElementId != skippedElementId ||
        !entry.complete) {
      final recorder = ui.PictureRecorder();
      final complete = record(ui.Canvas(recorder));
      final picture = recorder.endRecording();
      _entries.remove(pageId)?.picture.dispose();
      entry = _Entry(picture, skippedElementId, complete)..lastUsed = _tick;
      _entries[pageId] = entry;
      // lastUsed is already stamped, so eviction can never pick the entry
      // we're about to draw.
      _evictIfNeeded();
    } else {
      entry.lastUsed = _tick;
    }
    canvas.drawPicture(entry.picture);
  }

  void _evictIfNeeded() {
    while (_entries.length > maxEntries) {
      String? oldest;
      var oldestTick = _tick + 1;
      _entries.forEach((id, e) {
        if (e.lastUsed < oldestTick) {
          oldestTick = e.lastUsed;
          oldest = id;
        }
      });
      _entries.remove(oldest)!.picture.dispose();
    }
  }

  void dispose() => invalidateAll();
}

class _Entry {
  _Entry(this.picture, this.skippedElementId, this.complete);

  final ui.Picture picture;
  final String? skippedElementId;
  final bool complete;
  int lastUsed = 0;
}
