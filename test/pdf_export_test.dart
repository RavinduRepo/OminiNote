import 'dart:typed_data';
import 'dart:ui' show Color, Rect, Size;
import 'package:flutter_test/flutter_test.dart';
import 'package:omininote/canvas/text_measure.dart';
import 'package:omininote/models/canvas_page.dart';
import 'package:omininote/models/canvas.dart';
import 'package:omininote/models/element.dart';
import 'package:omininote/services/pdf_exporter.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart' as sf;

TextRun run(
  String text, {
  double size = 16,
  bool bold = false,
  Color color = const Color(0xFF000000),
}) => TextRun(
  text: text,
  fontSize: size,
  bold: bold,
  italic: false,
  color: color,
  fontFamily: 'sans',
);

void main() {
  group('Syncfusion PdfPageSettings sizing', () {
    // Regression test for the exporter bug: PdfPageSettings.size's setter
    // re-derives width/height as (min, max) of the *current* orientation
    // (default portrait), silently swapping any size where width > height —
    // e.g. every horizontally-merged row and every landscape PDF page. The
    // fix is to assign a brand-new PdfPageSettings constructed with only a
    // size (no orientation arg), which stores it verbatim.

    test(
      'mutating .size on the default settings swaps a wide page (the bug)',
      () {
        final doc = sf.PdfDocument();
        final section = doc.sections!.add();

        // A horizontally-merged row: much wider than tall.
        section.pageSettings.size = const Size(1190, 842);

        // Demonstrates the bug: width/height get reordered to (min, max).
        expect(section.pageSettings.size, const Size(842, 1190));

        doc.dispose();
      },
    );

    test(
      'assigning a fresh PdfPageSettings preserves a wide page (the fix)',
      () {
        final doc = sf.PdfDocument();
        final section = doc.sections!.add();

        section.pageSettings = sf.PdfPageSettings(const Size(1190, 842))
          ..margins.all = 0;

        expect(section.pageSettings.size, const Size(1190, 842));

        final page = section.pages.add();
        expect(page.size, const Size(1190, 842));

        doc.dispose();
      },
    );

    test('a normal tall (portrait-shaped) page is unaffected either way', () {
      final doc = sf.PdfDocument();
      final section = doc.sections!.add();

      section.pageSettings = sf.PdfPageSettings(const Size(595, 842))
        ..margins.all = 0;

      expect(section.pageSettings.size, const Size(595, 842));

      doc.dispose();
    });
  });

  group('SyncfusionPdfExporter end-to-end page sizing', () {
    test(
      'a horizontally-merged (wide) row and a plain portrait row each export '
      'at their exact intended size',
      () async {
        final wideLeft = CanvasPage(
          id: 'p1',
          deviceId: 'test_device',
          width: 595,
          height: 842,
        );
        final wideRight = CanvasPage(
          id: 'p2',
          deviceId: 'test_device',
          width: 595,
          height: 842,
        );
        final portrait = CanvasPage(
          id: 'p3',
          deviceId: 'test_device',
          width: 595,
          height: 842,
        );

        final section = Canvas(
          id: 's1',
          notebookId: 'n1',
          sectionId: 's1',
          name: 'Test section',
          createdAt: DateTime(2026, 7, 6),
          rows: [
            PageRow(id: 'r1', pageIds: ['p1', 'p2']), // merges to 1190x842
            PageRow(id: 'r2', pageIds: ['p3']), // stays 595x842
          ],
        );

        final bytes = await SyncfusionPdfExporter().export(
          canvas: section,
          pages: {'p1': wideLeft, 'p2': wideRight, 'p3': portrait},
          assetBytes: (_) async => Uint8List(0), // no PDF/image elements used
        );

        final result = sf.PdfDocument(inputBytes: bytes);
        expect(result.pages.count, 2);
        // The merged row must be exactly as wide as its two pages combined —
        // not swapped into a taller-than-wide page.
        expect(result.pages[0].size, const Size(1190, 842));
        expect(result.pages[1].size, const Size(595, 842));
        result.dispose();
      },
    );

    test(
      'a page with a background pattern exports meaningfully more content '
      'than the same page left blank (the pattern is actually drawn)',
      () async {
        Future<Uint8List> exportSinglePage(BgPattern pattern) {
          final page = CanvasPage(
            id: 'p1',
            deviceId: 'test_device',
            width: 595,
            height: 842,
            background: PageBackground(
              color: const Color(0xFFF8F1E3),
              pattern: pattern,
            ),
          );
          final section = Canvas(
            id: 's3',
            notebookId: 'n1',
            sectionId: 's1',
            name: 'Pattern test',
            createdAt: DateTime(2026, 7, 6),
            rows: [
              PageRow(id: 'r1', pageIds: ['p1']),
            ],
          );
          return SyncfusionPdfExporter().export(
            canvas: section,
            pages: {'p1': page},
            assetBytes: (_) async => Uint8List(0),
          );
        }

        final blank = await exportSinglePage(BgPattern.blank);
        final grid = await exportSinglePage(BgPattern.grid);
        final dotted = await exportSinglePage(BgPattern.dotted);

        // Drawing a page-covering grid/dot pattern emits many more vector
        // operations than a solid-color page, so the file grows noticeably.
        expect(grid.length, greaterThan(blank.length + 200));
        expect(dotted.length, greaterThan(blank.length + 200));
      },
    );
  });

  group('rich text (per-run) layout + export', () {
    // Wide enough that line 1 never wraps, in any test-font metrics.
    TextElement richElement() => TextElement(
      id: 'el1',
      deviceId: 'test_device',
      rect: const Rect.fromLTWH(50, 60, 900, 100),
      runs: [
        run('normal '),
        run('big-bold ', size: 28, bold: true),
        run('red\nsecond line', color: const Color(0xFFFF0000)),
      ],
      color: const Color(0xFF000000),
    );

    test(
      'placedRunFragments keeps every styled run, splits at the hard newline, '
      'and places later fragments below earlier ones',
      () {
        final fragments = placedRunFragments(richElement());

        expect(fragments.map((f) => f.text).toList(), [
          'normal ',
          'big-bold ',
          'red',
          'second line',
        ]);
        // Styles ride along per fragment.
        expect(fragments[1].run.bold, isTrue);
        expect(fragments[1].run.fontSize, 28);
        expect(fragments[2].run.color, const Color(0xFFFF0000));

        // Same line: x advances (tops differ per style — smaller text sits
        // lower to share the line's baseline). Next line: y advances, x
        // resets to the left.
        expect(fragments[1].offset.dx, greaterThan(fragments[0].offset.dx));
        expect(fragments[2].offset.dx, greaterThan(fragments[1].offset.dx));
        expect(fragments[3].offset.dy, greaterThan(fragments[0].offset.dy));
        expect(fragments[3].offset.dy, greaterThan(fragments[1].offset.dy));
        expect(fragments[3].offset.dx, lessThan(fragments[1].offset.dx));
      },
    );

    test('a soft-wrapped run yields one placed fragment per line', () {
      final el = TextElement(
        id: 'el2',
        deviceId: 'test_device',
        // Narrow box: this text cannot fit one line at size 16.
        rect: const Rect.fromLTWH(0, 0, 120, 200),
        runs: [run('several words that will definitely wrap around')],
        color: const Color(0xFF000000),
      );
      final fragments = placedRunFragments(el);
      expect(fragments.length, greaterThan(1));
      // No visible characters are lost across the wrap points (exact break
      // positions depend on the test font's metrics — don't assert those).
      expect(
        fragments.map((f) => f.text).join().replaceAll(' ', ''),
        'several words that will definitely wrap around'.replaceAll(' ', ''),
      );
      final ys = [for (final f in fragments) f.offset.dy];
      for (var i = 1; i < ys.length; i++) {
        expect(ys[i], greaterThan(ys[i - 1]));
      }
    });

    test('a canvas with a multi-style text box exports without error and '
        'draws every run (file grows vs. a single-style box)', () async {
      Future<Uint8List> exportWith(List<TextRun> runs) {
        final page = CanvasPage(
          id: 'p1',
          deviceId: 'test_device',
          width: 595,
          height: 842,
          objects: [
            TextElement(
              id: 'el1',
              deviceId: 'test_device',
              rect: const Rect.fromLTWH(50, 60, 400, 200),
              runs: runs,
              color: const Color(0xFF000000),
            ),
          ],
        );
        final section = Canvas(
          id: 's-rich',
          notebookId: 'n1',
          sectionId: 's1',
          name: 'Rich text test',
          createdAt: DateTime(2026, 7, 8),
          rows: [
            PageRow(id: 'r1', pageIds: ['p1']),
          ],
        );
        return SyncfusionPdfExporter().export(
          canvas: section,
          pages: {'p1': page},
          assetBytes: (_) async => Uint8List(0),
        );
      }

      final single = await exportWith([run('hello world')]);
      final rich = await exportWith([
        run('hello '),
        run('big ', size: 30, bold: true),
        run('red ', color: const Color(0xFFFF0000)),
        run('world'),
      ]);

      final reopened = sf.PdfDocument(inputBytes: rich);
      expect(reopened.pages.count, 1);
      reopened.dispose();

      // Four styled fragments (two extra fonts, an extra color) must emit
      // more content than one plain string.
      expect(rich.length, greaterThan(single.length));
    });
  });
}
