import 'dart:ui';
import 'package:flutter_test/flutter_test.dart';
import 'package:omininote/canvas/canvas_controller.dart';
import 'package:omininote/models/canvas.dart';
import 'package:omininote/models/canvas_page.dart';
import 'package:omininote/models/element.dart';
import 'package:omininote/services/settings_service.dart';

/// A horizontal stroke y=50 with a point every 5 units, x in [0, 100].
StrokeElement _longStroke(String id) => StrokeElement(
      id: id,
      deviceId: 'test_device',
      z: '0|a0:',
      tool: StrokeTool.pen,
      color: const Color(0xFF112233),
      size: 3,
      points: [for (var x = 0; x <= 100; x += 5) StrokePoint(x.toDouble(), 50, 0.5)],
    );

CanvasController _controller(CanvasPage page) {
  final canvas = Canvas(
    id: 'c1',
    notebookId: 'n1',
    sectionId: 's1',
    name: 'T',
    createdAt: DateTime(2026, 7, 12),
    rows: [
      PageRow(id: 'r1', pageIds: [page.id]),
    ],
  );
  return CanvasController(canvas: canvas, pages: {page.id: page})
    ..setTool(CanvasTool.eraser)
    ..eraserPartial = true;
}

void main() {
  SettingsService().deviceId = 'test_device';

  test('a mid-stroke erase splits into two segments; the original is '
      'tombstoned; segment style survives', () {
    final page = CanvasPage(id: 'a', deviceId: 'test_device')
      ..strokes.add(_longStroke('s1'));
    final c = _controller(page);

    c.startToolGesture(const Offset(50, 50), 0.5);
    c.endToolGesture();

    expect(page.strokes.length, 2, reason: 'two surviving halves');
    expect(page.strokes.map((s) => s.id), isNot(contains('s1')));
    expect(page.erased.map((e) => e.strokeId), ['s1'],
        reason: 'the original must tombstone or it resurrects via sync');
    for (final s in page.strokes) {
      expect(s.color, const Color(0xFF112233));
      expect(s.size, 3);
      expect(
          s.points.every((p) =>
              (Offset(p.x, p.y) - const Offset(50, 50)).distance > 11),
          isTrue,
          reason: 'no surviving point inside the eraser radius');
    }
  });

  test('undo/redo revive the SAME ids with a rev bumped above the tombstone '
      '(rev-based; tombstones kept). This is what restores the WHOLE line on '
      'a device that already pulled the partial-erase.', () {
    int tombRev(CanvasPage p, String id) => p.erased
        .where((e) => e.strokeId == id)
        .map((e) => e.rev)
        .fold(0, (m, r) => r > m ? r : m);

    final page = CanvasPage(id: 'a', deviceId: 'test_device')
      ..strokes.add(_longStroke('s1'));
    final c = _controller(page);
    c.startToolGesture(const Offset(50, 50), 0.5);
    c.endToolGesture();
    final segIds = page.strokes.map((s) => s.id).toSet();

    c.undo();
    expect(page.strokes.map((s) => s.id), ['s1'],
        reason: 'the original line is back under its SAME id');
    expect(page.strokes.single.rev, greaterThan(tombRev(page, 's1')),
        reason: 'out-revs its tombstone → alive across a merge (the WHOLE '
            'line is restored on the remote device, not deleted)');
    expect(page.erased.map((e) => e.strokeId), contains('s1'),
        reason: 'the tombstone stays (grow-only storage)');
    expect(page.erased.map((e) => e.strokeId).toSet(), containsAll(segIds),
        reason: 'the segments are tombstoned');

    c.redo();
    expect(page.strokes.map((s) => s.id).toSet(), segIds,
        reason: 'split state back under the SAME segment ids');
    for (final s in page.strokes) {
      expect(s.rev, greaterThan(tombRev(page, s.id)),
          reason: 'each revived segment out-revs its tombstone');
    }
  });

  test('erasing at the stroke end leaves a single segment', () {
    final page = CanvasPage(id: 'a', deviceId: 'test_device')
      ..strokes.add(_longStroke('s1'));
    final c = _controller(page);
    c.startToolGesture(const Offset(100, 50), 0.5);
    c.endToolGesture();
    expect(page.strokes.length, 1);
    expect(page.strokes.single.points.first.x, 0);
  });

  test('a stroke consumed whole (short, fully in radius) just disappears',
      () {
    final page = CanvasPage(id: 'a', deviceId: 'test_device')
      ..strokes.add(StrokeElement(
        id: 'tiny',
        deviceId: 'test_device',
        z: '0|a0:',
        tool: StrokeTool.pen,
        color: const Color(0xFF000000),
        size: 3,
        points: [StrokePoint(48, 50, .5), StrokePoint(52, 50, .5)],
      ));
    final c = _controller(page);
    c.startToolGesture(const Offset(50, 50), 0.5);
    c.endToolGesture();
    expect(page.strokes, isEmpty);
    expect(page.erased.map((e) => e.strokeId), ['tiny']);
  });

  test('two erases along one stroke in ONE gesture re-split our own segment '
      'without tombstoning it', () {
    final page = CanvasPage(id: 'a', deviceId: 'test_device')
      ..strokes.add(_longStroke('s1'));
    final c = _controller(page);
    c.startToolGesture(const Offset(25, 50), 0.5);
    c.updateToolGesture(const Offset(75, 50), 0.5);
    c.endToolGesture();

    expect(page.strokes.length, 3, reason: 'three surviving spans');
    expect(page.erased.map((e) => e.strokeId), ['s1'],
        reason: 'only the persisted original needs a tombstone — gesture-'
            'local segments were never saved');
  });

  test('stroke mode still removes whole strokes', () {
    final page = CanvasPage(id: 'a', deviceId: 'test_device')
      ..strokes.add(_longStroke('s1'));
    final c = _controller(page)..eraserPartial = false;
    c.startToolGesture(const Offset(50, 50), 0.5);
    c.endToolGesture();
    expect(page.strokes, isEmpty);
    expect(page.erased.map((e) => e.strokeId), ['s1']);
  });
}
