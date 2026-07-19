import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:omininote/models/canvas.dart';
import 'package:omininote/models/canvas_page.dart';
import 'package:omininote/models/element.dart';
import 'package:omininote/utils/readable_text.dart';

TextElement _text(String s, {required Rect rect, String id = 'el'}) =>
    TextElement(
      id: id,
      deviceId: 'dev',
      rect: rect,
      color: const Color(0xFF000000),
      text: s,
    );

CanvasPage _page(String id, List<CanvasElement> objects) =>
    CanvasPage(id: id, deviceId: 'dev', objects: objects);

Canvas _canvas(List<PageRow> rows) => Canvas(
      id: 'c',
      notebookId: 'nb',
      sectionId: 'sec',
      name: 'Canvas',
      createdAt: DateTime(2026),
      rows: rows,
    );

void main() {
  group('splitIntoUtterances', () {
    test('splits sentences and newlines, drops empties', () {
      expect(
        splitIntoUtterances('Hello world. How are you?\n\nFine!'),
        ['Hello world.', 'How are you?', 'Fine!'],
      );
    });

    test('text with no terminator stays one utterance', () {
      expect(splitIntoUtterances('just a phrase'), ['just a phrase']);
    });

    test('blank text yields nothing', () {
      expect(splitIntoUtterances('   \n  '), isEmpty);
    });
  });

  group('orderSpansForReading', () {
    test('top-to-bottom, left-to-right within a line', () {
      final spans = [
        const ReadableSpan('C', bounds: Rect.fromLTWH(0, 200, 10, 10)),
        const ReadableSpan('A', bounds: Rect.fromLTWH(0, 0, 10, 10)),
        const ReadableSpan('B', bounds: Rect.fromLTWH(100, 2, 10, 10)), // same line as A
      ];
      expect(
        orderSpansForReading(spans).map((s) => s.text).toList(),
        ['A', 'B', 'C'],
      );
    });

    test('unpositioned spans sort after positioned ones, order kept', () {
      final spans = [
        const ReadableSpan('unp1'),
        const ReadableSpan('pos', bounds: Rect.fromLTWH(0, 50, 10, 10)),
        const ReadableSpan('unp2'),
      ];
      expect(
        orderSpansForReading(spans).map((s) => s.text).toList(),
        ['pos', 'unp1', 'unp2'],
      );
    });
  });

  group('readingOrderPageIds', () {
    final canvas = _canvas([
      PageRow(id: 'r1', pageIds: ['p1', 'p1b']),
      PageRow(id: 'r2', pageIds: ['p2']),
      PageRow(id: 'r3', pageIds: []), // empty row skipped
      PageRow(id: 'r4', pageIds: ['p4', 'p4b', 'p4c']),
    ]);

    test('all pages, row-major (horizontals included)', () {
      expect(
        readingOrderPageIds(canvas, mainColumnOnly: false),
        ['p1', 'p1b', 'p2', 'p4', 'p4b', 'p4c'],
      );
    });

    test('main column only reads the first page of each row', () {
      expect(
        readingOrderPageIds(canvas, mainColumnOnly: true),
        ['p1', 'p2', 'p4'],
      );
    });
  });

  group('TypedTextSource', () {
    test('extracts non-empty text boxes with bounds + id', () async {
      final page = _page('pg', [
        _text('Hello.', rect: const Rect.fromLTWH(0, 10, 50, 20), id: 'a'),
        _text('   ', rect: const Rect.fromLTWH(0, 40, 50, 20), id: 'blank'),
        ImageElement(
          id: 'img',
          deviceId: 'dev',
          rect: const Rect.fromLTWH(0, 80, 50, 50),
          assetId: 'x',
        ),
      ]);
      final spans = await const TypedTextSource().spansFor(page);
      expect(spans.length, 1);
      expect(spans.single.text, 'Hello.');
      expect(spans.single.sourceId, 'a');
      expect(spans.single.bounds, const Rect.fromLTWH(0, 10, 50, 20));
    });
  });

  group('splitIntoUtterancesWithOffsets', () {
    test('offsets point at the sentence start within the original text', () {
      final text = 'One. Two.\nThree';
      final parts = splitIntoUtterancesWithOffsets(text);
      expect(parts.map((p) => p.$1).toList(), ['One.', 'Two.', 'Three']);
      // Each offset + length must slice back to the exact sentence.
      for (final (sentence, start) in parts) {
        expect(text.substring(start, start + sentence.length), sentence);
      }
    });
  });

  group('readingUnitsForPage', () {
    test('splits each span into per-sentence units tagged with the page', () {
      final spans = [
        const ReadableSpan('One. Two.',
            bounds: Rect.fromLTWH(0, 0, 10, 10), sourceId: 's1'),
      ];
      final units = readingUnitsForPage('pg7', spans);
      expect(units.map((u) => u.text).toList(), ['One.', 'Two.']);
      expect(units.every((u) => u.pageId == 'pg7'), isTrue);
      expect(units.every((u) => u.sourceId == 's1'), isTrue);
    });

    test('char ranges map each unit back onto the span text (for highlight)', () {
      const span = ReadableSpan('One. Two.', sourceId: 's1');
      final units = readingUnitsForPage('pg', [span]);
      for (final u in units) {
        expect(span.text.substring(u.charStart, u.charEnd), u.text);
      }
    });

    test('PDF line boxes: a sentence gets the rects of every line it spans', () {
      const rectA = Rect.fromLTWH(0, 0, 100, 12);
      const rectB = Rect.fromLTWH(0, 14, 100, 12);
      // "Hello world" (line 0, start 0) + " " + "foo bar." (line 1, start 12).
      const span = ReadableSpan(
        'Hello world foo bar.',
        sourceId: 'pdf:x#0',
        lineBoxes: [SpanLineBox(0, rectA), SpanLineBox(12, rectB)],
      );
      final units = readingUnitsForPage('pg', [span]);
      // One sentence spanning both wrapped lines → both rects highlight.
      expect(units.length, 1);
      expect(units.single.rects, [rectA, rectB]);
    });

    test('PDF line boxes: separate sentences highlight only their own line', () {
      const rectA = Rect.fromLTWH(0, 0, 100, 12);
      const rectB = Rect.fromLTWH(0, 14, 100, 12);
      // "One." (start 0) + " " + "Two." (start 5).
      const span = ReadableSpan(
        'One. Two.',
        sourceId: 'pdf:x#0',
        lineBoxes: [SpanLineBox(0, rectA), SpanLineBox(5, rectB)],
      );
      final units = readingUnitsForPage('pg', [span]);
      expect(units.map((u) => u.text).toList(), ['One.', 'Two.']);
      expect(units[0].rects, [rectA]);
      expect(units[1].rects, [rectB]);
    });
  });

  group('detectScriptLanguage', () {
    test('Sinhala text is detected', () {
      expect(detectScriptLanguage('මම හොඳින් සිටිමි'), 'si');
    });

    test('Tamil text is detected', () {
      expect(detectScriptLanguage('நான் நலமாக இருக்கிறேன்'), 'ta');
    });

    test('plain Latin text is not assigned a language (too ambiguous)', () {
      expect(detectScriptLanguage('Hello, how are you today?'), null);
    });

    test('short/punctuation-only text has no signal', () {
      expect(detectScriptLanguage('...'), null);
      expect(detectScriptLanguage('සි'), null); // only 2 chars, below threshold
    });

    test('mixed script picks the majority language', () {
      // Mostly Sinhala with one embedded Latin word.
      expect(detectScriptLanguage('මම Flutter වලින් app එකක් හදනවා'), 'si');
    });

    test('Russian (Cyrillic) and Greek are detected', () {
      expect(detectScriptLanguage('Привет, как дела сегодня?'), 'ru');
      expect(detectScriptLanguage('Γειά σου, πώς είσαι σήμερα;'), 'el');
    });
  });
}
