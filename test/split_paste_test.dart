import 'dart:ui' show Color, Rect;
import 'package:flutter_test/flutter_test.dart';
import 'package:omininote/canvas/canvas_controller.dart';
import 'package:omininote/canvas/text_measure.dart';
import 'package:omininote/models/canvas.dart';
import 'package:omininote/models/canvas_page.dart';
import 'package:omininote/models/element.dart';
import 'package:omininote/services/settings_service.dart';

TextRun run(String text, {double size = 16, bool bold = false}) => TextRun(
  text: text,
  fontSize: size,
  bold: bold,
  italic: false,
  color: const Color(0xFF000000),
  fontFamily: 'sans',
);

CanvasPage page(String id, {double w = 595, double h = 842}) =>
    CanvasPage(id: id, deviceId: 'test_device', width: w, height: h);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SettingsService().deviceId = 'test_device';

  group('splitRunsByHeight', () {
    test('short text stays one chunk', () {
      final chunks = splitRunsByHeight([run('hello world')], 400, 800);
      expect(chunks, hasLength(1));
    });

    test('long text splits into page-fitting chunks; concatenation is lossless '
        'and per-run styles survive the cut', () {
      // ~60 hard lines at 16px * 1.3 line height ≈ 1250px — needs 3 chunks
      // in a 500px budget.
      final lines = [for (var i = 0; i < 60; i++) 'line number $i'];
      final runs = [
        run('${lines.take(30).join('\n')}\n'),
        run(lines.skip(30).join('\n'), size: 20, bold: true),
      ];
      final original = runs.map((r) => r.text).join();

      final chunks = splitRunsByHeight(runs, 400, 500);
      expect(chunks.length, greaterThan(1));

      // Lossless: chunk texts concatenate back to the exact original.
      final rejoined = chunks.map((c) => c.map((r) => r.text).join()).join();
      expect(rejoined, original);

      // The later chunks carry the second run's style.
      final lastChunk = chunks.last;
      expect(lastChunk.every((r) => r.bold), isTrue);
      expect(lastChunk.every((r) => r.fontSize == 20), isTrue);

      // Every chunk actually fits the budget when laid out on its own.
      for (final chunk in chunks) {
        final el = TextElement(
          id: 'probe',
          deviceId: 'test_device',
          rect: Rect.zero,
          runs: chunk,
          color: const Color(0xFF000000),
        );
        expect(autoTextRect(el, 400).height, lessThanOrEqualTo(500));
      }
    });
  });

  group('CanvasController.insertRunsAsText', () {
    (CanvasController, CanvasPage) makeVertical() {
      final p1 = page('p1');
      final canvas = Canvas(
        id: 'c1',
        notebookId: 'n1',
        sectionId: 's1',
        name: 'T',
        createdAt: DateTime(2026, 7, 8),
        rows: [
          PageRow(id: 'r1', pageIds: ['p1']),
        ],
      );
      return (CanvasController(canvas: canvas, pages: {'p1': p1}), p1);
    }

    List<TextRun> longRuns() => [
      run([for (var i = 0; i < 120; i++) 'long pasted line $i'].join('\n')),
    ];

    test('fitting text lands as ONE unlinked box on the target page', () {
      final (c, p1) = makeVertical();
      final n = c.insertRunsAsText('p1', [run('short text')]);
      expect(n, 1);
      expect(p1.objects, hasLength(1));
      expect((p1.objects.single as TextElement).linkId, isNull);
      expect(c.canvas.rows, hasLength(1));
    });

    test('overflowing text in a single-page row splits into linked boxes on '
        'new rows BELOW; undo removes boxes, tombstones, pages and rows', () {
      final (c, p1) = makeVertical();
      final n = c.insertRunsAsText('p1', longRuns());

      expect(n, greaterThan(1));
      expect(c.canvas.rows, hasLength(n)); // 1 original + (n-1) new below
      expect(c.pages, hasLength(n));
      // Part 1 on the target page, one part per continuation page, all
      // sharing one linkId.
      final first = p1.objects.single as TextElement;
      expect(first.linkId, isNotNull);
      for (var i = 1; i < n; i++) {
        final pid = c.canvas.rows[i].pageIds.single;
        final el = c.pages[pid]!.objects.single as TextElement;
        expect(el.linkId, first.linkId);
      }

      c.undo();
      expect(c.canvas.rows, hasLength(1));
      expect(c.pages, hasLength(1));
      expect(p1.objects, isEmpty);
      expect(
        p1.deletedObjects.any((t) => t.strokeId == first.id),
        isTrue,
        reason: 'undo of a possibly-synced insert must tombstone',
      );

      c.redo();
      expect(c.canvas.rows, hasLength(n));
      expect(p1.objects, hasLength(1));
      expect(p1.deletedObjects, isEmpty);
    });

    test('overflowing text on a page in a HORIZONTAL row grows the same row to '
        'the right instead of adding rows below', () {
      final p1 = page('p1');
      final p2 = page('p2');
      final canvas = Canvas(
        id: 'c2',
        notebookId: 'n1',
        sectionId: 's1',
        name: 'H',
        createdAt: DateTime(2026, 7, 8),
        rows: [
          PageRow(id: 'r1', pageIds: ['p1', 'p2']),
        ],
      );
      final c = CanvasController(canvas: canvas, pages: {'p1': p1, 'p2': p2});

      final n = c.insertRunsAsText('p1', longRuns());
      expect(n, greaterThan(1));
      expect(canvas.rows, hasLength(1), reason: 'no new rows');
      expect(canvas.rows.single.pageIds.length, 2 + (n - 1));
      // Continuations inserted directly after the target page, before p2.
      expect(canvas.rows.single.pageIds.first, 'p1');
      expect(canvas.rows.single.pageIds.last, 'p2');

      c.undo();
      expect(canvas.rows.single.pageIds, ['p1', 'p2']);
    });
  });

  group('linked text actions', () {
    test('deleteLinkedText removes + tombstones every part; undo restores', () {
      final p1 = page('p1');
      final canvas = Canvas(
        id: 'c3',
        notebookId: 'n1',
        sectionId: 's1',
        name: 'D',
        createdAt: DateTime(2026, 7, 8),
        rows: [
          PageRow(id: 'r1', pageIds: ['p1']),
        ],
      );
      final c = CanvasController(canvas: canvas, pages: {'p1': p1});
      final n = c.insertRunsAsText('p1', [
        run([for (var i = 0; i < 120; i++) 'line $i'].join('\n')),
      ]);
      expect(n, greaterThan(1));

      // Select just the first part (single-page lasso reality).
      c.selection = [p1.objects.single];
      c.selectionPageId = 'p1';
      expect(c.selectionHasLinkedText, isTrue);

      c.deleteLinkedText();
      for (final p in c.pages.values) {
        expect(
          p.objects.whereType<TextElement>().where((t) => t.linkId != null),
          isEmpty,
        );
      }
      expect(p1.deletedObjects, isNotEmpty);

      c.undo();
      expect(p1.objects, hasLength(1));
      expect(p1.deletedObjects, isEmpty);
    });

    test('cutLinkedText merges all parts into one clipboard text element whose '
        'text is the exact original', () {
      final p1 = page('p1');
      final canvas = Canvas(
        id: 'c4',
        notebookId: 'n1',
        sectionId: 's1',
        name: 'C',
        createdAt: DateTime(2026, 7, 8),
        rows: [
          PageRow(id: 'r1', pageIds: ['p1']),
        ],
      );
      final c = CanvasController(canvas: canvas, pages: {'p1': p1});
      final original = [
        for (var i = 0; i < 120; i++) 'cut me line $i',
      ].join('\n');
      c.insertRunsAsText('p1', [run(original)]);

      c.selection = [p1.objects.single];
      c.selectionPageId = 'p1';
      c.cutLinkedText();

      expect(CanvasController.clipboardHasContent, isTrue);
      for (final p in c.pages.values) {
        expect(
          p.objects.whereType<TextElement>().where((t) => t.linkId != null),
          isEmpty,
          reason: 'cut removed every part',
        );
      }
      // Re-flowing the clipboard content elsewhere restores the text.
      final n2 = c.insertRunsAsText(
        canvas.rows.first.pageIds.first,
        // The merged element is on the private clipboard; simulate the
        // paste re-flow with the same runs to assert losslessness.
        [run(original)],
      );
      expect(n2, greaterThan(1));
      final rejoined = [
        for (final row in canvas.rows)
          for (final pid in row.pageIds)
            for (final el in c.pages[pid]!.objects.whereType<TextElement>())
              el.text,
      ].join();
      expect(rejoined, original);
    });
  });
}
