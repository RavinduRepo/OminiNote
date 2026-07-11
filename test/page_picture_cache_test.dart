import 'dart:ui' as ui;
import 'package:flutter/material.dart' hide Canvas;
import 'package:flutter_test/flutter_test.dart';
import 'package:omininote/canvas/canvas_controller.dart';
import 'package:omininote/canvas/canvas_painter.dart';
import 'package:omininote/canvas/page_picture_cache.dart';
import 'package:omininote/models/canvas.dart';
import 'package:omininote/models/canvas_page.dart';
import 'package:omininote/models/element.dart';
import 'package:omininote/services/settings_service.dart';

StrokeElement _stroke(String id) => StrokeElement(
      id: id,
      deviceId: 'test_device',
      z: '0|a0:',
      tool: StrokeTool.pen,
      color: const ui.Color(0xFF000000),
      size: 3,
      points: [StrokePoint(0, 0, 0.5), StrokePoint(10, 10, 0.5)],
    );

/// Paints [pageId] through [cache] onto a throwaway canvas, bumping
/// [counter] each time the record closure actually runs.
void _paint(
  PagePictureCache cache,
  String pageId,
  List<int> counter, {
  String? skipped,
  bool complete = true,
}) {
  final recorder = ui.PictureRecorder();
  cache.paint(
    ui.Canvas(recorder),
    pageId,
    skippedElementId: skipped,
    record: (c) {
      counter[0]++;
      c.drawRect(const ui.Rect.fromLTWH(0, 0, 10, 10), ui.Paint());
      return complete;
    },
  );
  recorder.endRecording().dispose();
}

void main() {
  SettingsService().deviceId = 'test_device';

  group('PagePictureCache', () {
    test('replays the cached picture — record runs once across many paints',
        () {
      final cache = PagePictureCache();
      final n = [0];
      for (var i = 0; i < 5; i++) {
        _paint(cache, 'p1', n);
      }
      expect(n[0], 1);
      cache.dispose();
    });

    test('invalidate forces a re-record; other pages stay cached', () {
      final cache = PagePictureCache();
      final n1 = [0], n2 = [0];
      _paint(cache, 'p1', n1);
      _paint(cache, 'p2', n2);
      cache.invalidate('p1');
      _paint(cache, 'p1', n1);
      _paint(cache, 'p2', n2);
      expect(n1[0], 2);
      expect(n2[0], 1);
      cache.dispose();
    });

    test('a changed skipped-element id re-records (text edit open/close)', () {
      final cache = PagePictureCache();
      final n = [0];
      _paint(cache, 'p1', n); // no editor open
      _paint(cache, 'p1', n, skipped: 'el1'); // editor opened
      _paint(cache, 'p1', n, skipped: 'el1'); // still open — cached
      _paint(cache, 'p1', n); // editor closed
      expect(n[0], 3);
      cache.dispose();
    });

    test('an incomplete recording (raster still decoding) re-records until '
        'complete', () {
      final cache = PagePictureCache();
      final n = [0];
      _paint(cache, 'p1', n, complete: false);
      _paint(cache, 'p1', n, complete: false);
      _paint(cache, 'p1', n); // raster landed
      _paint(cache, 'p1', n); // now stable
      expect(n[0], 3);
      cache.dispose();
    });

    test('LRU eviction: overflowing the cap drops the oldest entries only',
        () {
      final cache = PagePictureCache();
      final first = [0], last = [0], other = [0];
      _paint(cache, 'page0', first);
      for (var i = 1; i <= PagePictureCache.maxEntries; i++) {
        _paint(cache, 'page$i', other); // pushes page0 past the cap
      }
      _paint(cache, 'page${PagePictureCache.maxEntries}', last);
      expect(last[0], 0); // newest survived — replayed from cache
      _paint(cache, 'page0', first);
      expect(first[0], 2); // oldest was evicted → re-recorded
      cache.dispose();
    });
  });

  group('CanvasController picture-cache invalidation', () {
    test('a committed op, its undo, and its redo each invalidate the page',
        () {
      final stroke = _stroke('s1');
      final page = CanvasPage(id: 'a', deviceId: 'test_device')
        ..strokes.add(stroke);
      final canvas = Canvas(
        id: 'c1',
        notebookId: 'n1',
        sectionId: 's1',
        name: 'T',
        createdAt: DateTime(2026, 7, 11),
        rows: [
          PageRow(id: 'r1', pageIds: ['a']),
        ],
      );
      final controller = CanvasController(canvas: canvas, pages: {'a': page});

      final n = [0];
      _paint(controller.pictureCache, 'a', n);
      _paint(controller.pictureCache, 'a', n);
      expect(n[0], 1); // cached

      controller.removeElement('a', stroke);
      _paint(controller.pictureCache, 'a', n);
      expect(n[0], 2); // op invalidated

      controller.undo();
      _paint(controller.pictureCache, 'a', n);
      expect(n[0], 3); // undo invalidated

      controller.redo();
      _paint(controller.pictureCache, 'a', n);
      expect(n[0], 4); // redo invalidated
      // No controller.dispose() — it flushes saves through NotebookService,
      // which has no path_provider in tests (same as the other controller tests).
    });
  });

  group('CanvasPainter + picture cache integration', () {
    testWidgets('paints, replays from cache, and re-records after an '
        'invalidate without throwing', (tester) async {
      final page = CanvasPage(id: 'a', deviceId: 'test_device')
        ..strokes.add(_stroke('s1'));
      final canvas = Canvas(
        id: 'c2',
        notebookId: 'n1',
        sectionId: 's1',
        name: 'Paint',
        createdAt: DateTime(2026, 7, 11),
        rows: [
          PageRow(id: 'r1', pageIds: ['a']),
        ],
      );
      final controller = CanvasController(canvas: canvas, pages: {'a': page});

      await tester.pumpWidget(
        MaterialApp(
          home: SizedBox.expand(
            child: CustomPaint(
              painter: CanvasPainter(
                controller: controller,
                pageBorderColor: const Color(0xFFCCCCCC),
                accentColor: const Color(0xFFB8860B),
                canvasTextColor: const Color(0xFF444444),
              ),
            ),
          ),
        ),
      );
      await tester.pump(); // second frame — the cache-hit replay path

      // Invalidate + force a repaint (pan notifies) — the re-record path.
      // No op-based mutation here: the op's 500 ms save timer can't run in
      // tests (no path_provider).
      controller.pictureCache.invalidate('a');
      controller.panImmediate(const Offset(0, 5));
      await tester.pump();

      expect(tester.takeException(), isNull);
    });
  });
}
