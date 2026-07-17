import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:omininote/canvas/canvas_controller.dart';
import 'package:omininote/models/canvas.dart';
import 'package:omininote/models/canvas_page.dart';
import 'package:omininote/models/element.dart';
import 'package:omininote/services/settings_service.dart';

/// Pasting an image while the caret is in a text box inserts it as a BLOCK,
/// Word-style: never inline, always on the line after the caret and
/// left-aligned to the box, with the text that followed the caret pushed below
/// it. See [CanvasController.insertImageAtCaret].
void main() {
  SettingsService().deviceId = 'test_device';

  const boxLeft = 40.0;
  const boxTop = 100.0;

  TextElement box(String text) => TextElement(
        id: 'txt',
        deviceId: 'test_device',
        rect: const Rect.fromLTWH(boxLeft, boxTop, 200, 40),
        text: text,
        fontSize: 16,
        color: const Color(0xFF000000),
      );

  ImageElement img({double w = 90, double h = 60}) => ImageElement(
        id: 'img',
        deviceId: 'test_device',
        rect: Rect.fromLTWH(0, 0, w, h),
        assetId: 'asset1',
      );

  ({CanvasController c, CanvasPage page}) harness(TextElement el) {
    final page = CanvasPage(id: 'p1', deviceId: 'test_device')
      ..objects.add(el);
    final canvas = Canvas(
      id: 'c1',
      notebookId: 'n1',
      sectionId: 's1',
      name: 'T',
      createdAt: DateTime(2026, 7, 17),
      rows: [PageRow(id: 'r1', pageIds: ['p1'])],
    );
    return (
      c: CanvasController(canvas: canvas, pages: {'p1': page}),
      page: page,
    );
  }

  List<TextElement> textsOn(CanvasPage p) =>
      p.objects.whereType<TextElement>().toList();

  test('caret at the END: nothing moves, the image lands under the box', () {
    final el = box('hello world');
    final h = harness(el);
    final before = el.rect;

    final placed = h.c.insertImageAtCaret('p1', el, el.text.length, img());

    expect(placed, isNotNull);
    // Only the original box — no split.
    expect(textsOn(h.page).length, 1);
    expect(textsOn(h.page).single.text, 'hello world');
    expect(textsOn(h.page).single.rect.top, before.top,
        reason: 'the box must not move');
    // Left-aligned to the box, below it.
    expect(placed!.rect.left, boxLeft);
    expect(placed.rect.top, greaterThan(before.top));
  });

  test('caret at the START: image takes the top-left, the box slides below',
      () {
    final el = box('hello world');
    final h = harness(el);

    final placed = h.c.insertImageAtCaret('p1', el, 0, img())!;

    // No split — the source IS the after-text.
    final texts = textsOn(h.page);
    expect(texts.length, 1);
    expect(texts.single.text, 'hello world');
    // Image sits where the box was; the box is now under it.
    expect(placed.rect.left, boxLeft);
    expect(placed.rect.top, boxTop);
    expect(texts.single.rect.top, greaterThanOrEqualTo(placed.rect.bottom));
    expect(texts.single.rect.left, boxLeft);
  });

  test('caret in the MIDDLE: box truncates, remainder moves below the image',
      () {
    final el = box('hello world');
    final h = harness(el);

    // "hello" | " world"
    final placed = h.c.insertImageAtCaret('p1', el, 5, img())!;

    final texts = textsOn(h.page)..sort((a, b) => a.rect.top.compareTo(b.rect.top));
    expect(texts.length, 2, reason: 'the box splits in two');
    expect(texts.first.text, 'hello');
    expect(texts.last.text, ' world');
    // Text is preserved exactly across the split.
    expect(texts.first.text + texts.last.text, 'hello world');

    // Stacking: above text, then image, then the remainder.
    expect(placed.rect.top, greaterThanOrEqualTo(texts.first.rect.bottom));
    expect(texts.last.rect.top, greaterThanOrEqualTo(placed.rect.bottom));
    // Everything left-aligned to the original box.
    expect(placed.rect.left, boxLeft);
    expect(texts.last.rect.left, boxLeft);
  });

  test('the split preserves per-run styling on both sides', () {
    final el = TextElement(
      id: 'txt',
      deviceId: 'test_device',
      rect: const Rect.fromLTWH(boxLeft, boxTop, 200, 40),
      runs: [
        TextRun(
          text: 'big',
          fontSize: 40,
          bold: true,
          italic: false,
          color: const Color(0xFFFF0000),
          fontFamily: 'sans',
        ),
        TextRun(
          text: 'small',
          fontSize: 12,
          bold: false,
          italic: true,
          color: const Color(0xFF0000FF),
          fontFamily: 'mono',
        ),
      ],
      color: const Color(0xFF000000),
    );
    final h = harness(el);

    h.c.insertImageAtCaret('p1', el, 3, img()); // exactly on the run boundary

    final texts = textsOn(h.page)..sort((a, b) => a.rect.top.compareTo(b.rect.top));
    expect(texts.first.runs.single.fontSize, 40);
    expect(texts.first.runs.single.bold, isTrue);
    expect(texts.last.runs.single.fontSize, 12);
    expect(texts.last.runs.single.italic, isTrue);
    expect(texts.last.runs.single.fontFamily, 'mono');
  });

  test('one undo restores the original box and removes both new elements', () {
    final el = box('hello world');
    final h = harness(el);
    final originalRect = el.rect;

    h.c.insertImageAtCaret('p1', el, 5, img());
    expect(textsOn(h.page).length, 2);
    expect(h.page.objects.whereType<ImageElement>().length, 1);

    h.c.undo();

    final texts = textsOn(h.page);
    expect(texts.length, 1, reason: 'the split box is gone');
    expect(texts.single.text, 'hello world');
    expect(texts.single.rect, originalRect);
    expect(h.page.objects.whereType<ImageElement>(), isEmpty);

    // ...and redo puts it back.
    h.c.redo();
    expect(textsOn(h.page).length, 2);
    expect(h.page.objects.whereType<ImageElement>().length, 1);
  });

  test('the image renders below ink (z under the lowest stroke)', () {
    final el = box('hello');
    final h = harness(el);
    h.page.strokes.add(
      StrokeElement(
        id: 's1',
        deviceId: 'test_device',
        z: '0|a0:',
        tool: StrokeTool.pen,
        color: const Color(0xFF000000),
        size: 3,
        points: [StrokePoint(0, 0, 0.5), StrokePoint(5, 5, 0.5)],
      ),
    );

    final placed = h.c.insertImageAtCaret('p1', el, 5, img())!;
    expect(placed.zIndex, lessThan(0));
  });

  test('a box that is not live on the page is refused', () {
    final el = box('hello');
    final h = harness(el);
    final orphan = box('elsewhere')..id = 'nope';
    expect(h.c.insertImageAtCaret('p1', orphan, 2, img()), isNull);
    expect(h.c.insertImageAtCaret('missing', el, 2, img()), isNull);
  });

  test('the deleted/erased elements are stamped for sync', () {
    final el = box('hello world');
    final h = harness(el);
    final revBefore = el.rev;

    h.c.insertImageAtCaret('p1', el, 5, img());

    final live = textsOn(h.page).firstWhere((e) => e.text == 'hello');
    expect(live.rev, greaterThan(revBefore),
        reason: 'the truncated box must out-rev its old copy for LWW');
  });
}
