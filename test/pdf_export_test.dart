import 'dart:typed_data';
import 'dart:ui' show Color, Size;
import 'package:flutter_test/flutter_test.dart';
import 'package:omininote/models/canvas_page.dart';
import 'package:omininote/models/canvas.dart';
import 'package:omininote/services/pdf_exporter.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart' as sf;

void main() {
  group('Syncfusion PdfPageSettings sizing', () {
    // Regression test for the exporter bug: PdfPageSettings.size's setter
    // re-derives width/height as (min, max) of the *current* orientation
    // (default portrait), silently swapping any size where width > height —
    // e.g. every horizontally-merged row and every landscape PDF page. The
    // fix is to assign a brand-new PdfPageSettings constructed with only a
    // size (no orientation arg), which stores it verbatim.

    test('mutating .size on the default settings swaps a wide page (the bug)', () {
      final doc = sf.PdfDocument();
      final section = doc.sections!.add();

      // A horizontally-merged row: much wider than tall.
      section.pageSettings.size = const Size(1190, 842);

      // Demonstrates the bug: width/height get reordered to (min, max).
      expect(section.pageSettings.size, const Size(842, 1190));

      doc.dispose();
    });

    test('assigning a fresh PdfPageSettings preserves a wide page (the fix)', () {
      final doc = sf.PdfDocument();
      final section = doc.sections!.add();

      section.pageSettings = sf.PdfPageSettings(const Size(1190, 842))
        ..margins.all = 0;

      expect(section.pageSettings.size, const Size(1190, 842));

      final page = section.pages.add();
      expect(page.size, const Size(1190, 842));

      doc.dispose();
    });

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
        final wideLeft = CanvasPage(id: 'p1', width: 595, height: 842);
        final wideRight = CanvasPage(id: 'p2', width: 595, height: 842);
        final portrait = CanvasPage(id: 'p3', width: 595, height: 842);

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
            rows: [PageRow(id: 'r1', pageIds: ['p1'])],
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
}
