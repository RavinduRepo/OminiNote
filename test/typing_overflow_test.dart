import 'dart:ui';
import 'package:flutter_test/flutter_test.dart';
import 'package:omininote/canvas/canvas_controller.dart';
import 'package:omininote/models/canvas.dart';
import 'package:omininote/models/canvas_page.dart';
import 'package:omininote/models/element.dart';
import 'package:omininote/services/settings_service.dart';

TextRun _run(String text) => TextRun(
      text: text,
      fontSize: 16,
      bold: false,
      italic: false,
      color: const Color(0xFF000000),
      fontFamily: 'sans',
    );

TextElement _box(String text, {String? linkId}) => TextElement(
      id: 'src',
      deviceId: 'test_device',
      rect: const Rect.fromLTWH(50, 700, 200, 120),
      text: text,
      color: const Color(0xFF000000),
      linkId: linkId,
    );

CanvasController _controller(List<PageRow> rows, Map<String, CanvasPage> pages) {
  final canvas = Canvas(
    id: 'c1',
    notebookId: 'n1',
    sectionId: 's1',
    name: 'T',
    createdAt: DateTime(2026, 7, 12),
    rows: rows,
  );
  return CanvasController(canvas: canvas, pages: pages);
}

void main() {
  SettingsService().deviceId = 'test_device';

  group('CanvasController.insertTypingContinuation', () {
    test('reuses an empty next page (vertical) — no structural change', () {
      final src = _box('full page text');
      final a = CanvasPage(id: 'a', deviceId: 'test_device')..objects.add(src);
      final empty = CanvasPage(id: 'b', deviceId: 'test_device');
      final c = _controller([
        PageRow(id: 'r1', pageIds: ['a']),
        PageRow(id: 'r2', pageIds: ['b']),
      ], {'a': a, 'b': empty});

      final res = c.insertTypingContinuation('a', src, [_run('overflow')]);
      expect(res, isNotNull);
      expect(res!.$1, 'b', reason: 'empty next page is reused');
      expect(c.canvas.rows.length, 2, reason: 'no page inserted');
      expect(empty.objects.single, res.$2);
      expect(src.linkId, isNotNull);
      expect(res.$2.linkId, src.linkId, reason: 'parts are linked');
    });

    test('inserts a fresh page when the next one has content (vertical); '
        'undo removes it', () {
      final src = _box('full page text');
      final a = CanvasPage(id: 'a', deviceId: 'test_device')..objects.add(src);
      final busy = CanvasPage(id: 'b', deviceId: 'test_device')
        ..objects.add(TextElement(
          id: 'other',
          deviceId: 'test_device',
          rect: const Rect.fromLTWH(0, 0, 50, 20),
          text: 'existing',
          color: const Color(0xFF000000),
        ));
      final c = _controller([
        PageRow(id: 'r1', pageIds: ['a']),
        PageRow(id: 'r2', pageIds: ['b']),
      ], {'a': a, 'b': busy});

      final res = c.insertTypingContinuation('a', src, [_run('overflow')]);
      expect(res, isNotNull);
      expect(res!.$1, isNot('b'), reason: 'busy page must not be overlapped');
      expect(c.canvas.rows.length, 3);
      expect(c.canvas.rows[1].pageIds, [res.$1],
          reason: 'new page sits between the current and the busy one');

      c.undo();
      expect(c.canvas.rows.length, 2);
      expect(c.pages.containsKey(res.$1), isFalse);
    });

    test('horizontal row: the new page joins the row right after the current',
        () {
      final src = _box('full page text');
      final a = CanvasPage(id: 'a', deviceId: 'test_device')..objects.add(src);
      final right = CanvasPage(id: 'z', deviceId: 'test_device')
        ..strokes.add(StrokeElement(
          id: 's1',
          deviceId: 'test_device',
          z: '0|a0:',
          tool: StrokeTool.pen,
          color: const Color(0xFF000000),
          size: 3,
          points: [StrokePoint(0, 0, 0.5)],
        ));
      final row = PageRow(id: 'r1', pageIds: ['a', 'z']);
      final c = _controller([row], {'a': a, 'z': right});

      final res = c.insertTypingContinuation('a', src, [_run('overflow')]);
      expect(res, isNotNull);
      expect(row.pageIds.length, 3);
      expect(row.pageIds[1], res!.$1, reason: 'inserted right after "a"');
      expect(c.canvas.rows.length, 1, reason: 'stays one horizontal row');
    });

    test('a second overflow prepends into the existing continuation', () {
      final src = _box('full page text');
      final a = CanvasPage(id: 'a', deviceId: 'test_device')..objects.add(src);
      final empty = CanvasPage(id: 'b', deviceId: 'test_device');
      final c = _controller([
        PageRow(id: 'r1', pageIds: ['a']),
        PageRow(id: 'r2', pageIds: ['b']),
      ], {'a': a, 'b': empty});

      final first = c.insertTypingContinuation('a', src, [_run('tail one\n')]);
      final second = c.insertTypingContinuation('a', src, [_run('tail two\n')]);
      expect(second!.$2, same(first!.$2),
          reason: 'no second box — overflow merges into the linked part');
      expect(second.$2.text, 'tail two\ntail one\n',
          reason: 'later overflow prepends (it sits closer to part 1)');
      expect(empty.objects.length, 1);
    });
  });
}
