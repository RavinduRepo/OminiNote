import 'dart:ui';
import 'package:flutter_test/flutter_test.dart';
import 'package:omininote/canvas/canvas_controller.dart';
import 'package:omininote/canvas/text_measure.dart';
import 'package:omininote/models/canvas.dart';
import 'package:omininote/models/canvas_page.dart';
import 'package:omininote/models/element.dart';
import 'package:omininote/services/settings_service.dart';

TextElement _box(String text, {String id = 't1'}) => TextElement(
      id: id,
      deviceId: 'test_device',
      rect: const Rect.fromLTWH(0, 0, 200, 60),
      text: text,
      color: const Color(0xFF000000),
    );

CanvasController _controller(TextElement el) {
  final page = CanvasPage(id: 'a', deviceId: 'test_device')..objects.add(el);
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
  return CanvasController(canvas: canvas, pages: {'a': page});
}

void main() {
  SettingsService().deviceId = 'test_device';

  group('CanvasController.toggleCheckboxAt', () {
    test('flips ☐→☑ and back, undoable/redoable, and stamps for sync', () {
      final el = _box('☐ buy milk');
      final c = _controller(el);
      String boxText() =>
          c.pages['a']!.objects.whereType<TextElement>().single.text;
      int boxRev() =>
          c.pages['a']!.objects.whereType<TextElement>().single.rev;

      c.toggleCheckboxAt('a', 't1', 0);
      expect(boxText(), '☑ buy milk');
      expect(boxRev(), greaterThan(1), reason: 'must stamp for LWW sync');

      c.toggleCheckboxAt('a', 't1', 0);
      expect(boxText(), '☐ buy milk');

      c.undo();
      expect(boxText(), '☑ buy milk');
      c.undo();
      expect(boxText(), '☐ buy milk');
      c.redo();
      expect(boxText(), '☑ buy milk');
    });

    test('a non-glyph offset is a no-op (no phantom op on the undo stack)',
        () {
      final el = _box('☐ buy milk');
      final c = _controller(el);
      c.toggleCheckboxAt('a', 't1', 3); // 'u' of "buy"
      expect(
          c.pages['a']!.objects.whereType<TextElement>().single.text,
          '☐ buy milk');
      expect(c.canUndo, isFalse);
    });
  });

  group('checkboxOffsetAt (hit geometry, Ahem font: 1 glyph = fontSize px)',
      () {
    test('tap on the leading glyph hits; tap elsewhere in the line misses',
        () {
      final el = _box('☐ buy milk\n☑ done');
      // First line's glyph box ≈ x 0..16, line height ≈ 20.8 (16 × 1.3).
      expect(checkboxOffsetAt(el, const Offset(8, 10)), 0);
      expect(checkboxOffsetAt(el, const Offset(100, 10)), isNull,
          reason: 'the text after the glyph must not toggle');
      // Second line's glyph is the char after "☐ buy milk\n" (index 11).
      expect(checkboxOffsetAt(el, const Offset(8, 31)), 11);
    });

    test('an indented (nested) checkbox is still tappable', () {
      final el = _box('  ☐ nested');
      // Two Ahem spaces (16 px each) → glyph box ≈ x 32..48.
      expect(checkboxOffsetAt(el, const Offset(40, 10)), 2);
    });

    test('a ☐ in the middle of a sentence is not a checkbox', () {
      final el = _box('see ☐ here');
      expect(checkboxOffsetAt(el, const Offset(8, 10)), isNull);
      // Even tapping the glyph itself (5th char → x 64..80) does nothing.
      expect(checkboxOffsetAt(el, const Offset(72, 10)), isNull);
    });

    test('plain text boxes bail out early', () {
      final el = _box('no boxes here');
      expect(checkboxOffsetAt(el, const Offset(8, 10)), isNull);
    });
  });
}
