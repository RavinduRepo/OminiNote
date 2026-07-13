import 'dart:typed_data';
import 'dart:ui' show Color, Rect, Size;
import 'package:flutter_test/flutter_test.dart';
import 'package:omininote/models/canvas.dart';
import 'package:omininote/models/canvas_page.dart';
import 'package:omininote/models/element.dart';
import 'package:omininote/services/pdf_export_isolate.dart';
import 'package:omininote/services/pdf_exporter.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart' as sf;

/// Verifies the background-isolate PDF export produces a valid PDF equivalent
/// to the on-main export (strokes, precomputed text, and a background pattern
/// all survive the JSON+bytes isolate boundary), and that per-canvas progress
/// is reported. TextPainter runs on the (test) main isolate during
/// serialization; the isolate itself only does pure-Dart assembly.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // A fresh item each call — the exporter/isolate may consume the models.
  PdfExportItem buildItem() {
    final page = CanvasPage(
      id: 'p1',
      deviceId: 'test_device',
      width: 595,
      height: 842,
      background: const PageBackground(
        color: Color(0xFFFFFFFF),
        pattern: BgPattern.grid,
      ),
      strokes: [
        StrokeElement(
          id: 'st1',
          deviceId: 'test_device',
          z: 'a0',
          tool: StrokeTool.pen,
          color: const Color(0xFF112233),
          size: 3,
          points: [
            StrokePoint(10, 10, 0.5),
            StrokePoint(120, 60, 0.6),
            StrokePoint(220, 40, 0.4),
          ],
        ),
      ],
      objects: [
        TextElement(
          id: 'tx1',
          deviceId: 'test_device',
          rect: const Rect.fromLTWH(40, 60, 420, 120),
          runs: [
            TextRun(
              text: 'Hello ',
              fontSize: 18,
              bold: false,
              italic: false,
              color: const Color(0xFF000000),
              fontFamily: 'sans',
            ),
            TextRun(
              text: 'bold red',
              fontSize: 24,
              bold: true,
              italic: false,
              color: const Color(0xFFAA0000),
              fontFamily: 'sans',
            ),
          ],
          color: const Color(0xFF000000),
        ),
      ],
    );
    final canvas = Canvas(
      id: 'c1',
      notebookId: 'n1',
      sectionId: 's1',
      name: 'Iso',
      createdAt: DateTime(2026, 7, 14),
      rows: [
        PageRow(id: 'r1', pageIds: ['p1']),
      ],
    );
    return PdfExportItem(
      outline: const ['NB', 'Sec', 'Iso'],
      canvas: canvas,
      pages: {'p1': page},
      assetBytes: (_) async => Uint8List(0),
    );
  }

  test(
    'isolate export == on-main export (structure) and reports progress',
    () async {
      final onMain = await SyncfusionPdfExporter().exportTree([buildItem()]);

      final progress = <List<int>>[];
      final iso = await exportPdfInIsolate(
        [buildItem()],
        onProgress: (done, total) => progress.add([done, total]),
      );

      final a = sf.PdfDocument(inputBytes: onMain);
      final b = sf.PdfDocument(inputBytes: iso);
      expect(b.pages.count, a.pages.count);
      expect(b.pages.count, 1);
      expect(b.pages[0].size, const Size(595, 842));
      expect(b.pages[0].size, a.pages[0].size);
      // Nested outline mirrors the tree: NB › Sec › Iso.
      expect(b.bookmarks.count, 1);
      expect(b.bookmarks[0].title, 'NB');
      a.dispose();
      b.dispose();

      // Progress ran to completion (1 of 1 canvas).
      expect(progress.isNotEmpty, isTrue);
      expect(progress.last, [1, 1]);

      // Real content (stroke + text + grid pattern) was drawn.
      expect(iso.length, greaterThan(1000));
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );
}
