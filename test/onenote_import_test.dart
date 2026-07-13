// Tests for the OneNote importer (tools/onenote_importer/convert.dart):
// tiling invariants, unit/color conversions, and — when a converted store is
// present on disk — a round-trip of its JSON through the app's real models.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:omininote/models/canvas.dart';
import 'package:omininote/models/canvas_page.dart';
import 'package:omininote/models/element.dart';
import 'package:omininote/models/notebook.dart';
import 'package:omininote/models/section.dart';

import '../tools/onenote_importer/convert.dart';

ConvertedElement el(double l, double t, double r, double b) =>
    ConvertedElement(
      {
        'type': 'stroke',
        'points': [
          {'x': l, 'y': t, 'p': 0.5},
          {'x': r, 'y': b, 'p': 0.5},
        ],
      },
      Box(l, t, r, b),
      isStroke: true,
    );

void main() {
  group('color and unit conversion', () {
    test('COLORREF decodes as 0x00BBGGRR', () {
      // 9448795 = 0x902D5B → r=0x5B g=0x2D b=0x90 (the purple pen from the
      // user's real notes).
      expect(colorRefToArgb(9448795), 0xFF5B2D90);
      // 65535 = 0x00FFFF → yellow highlighter.
      expect(colorRefToArgb(65535), 0xFFFFFF00);
      expect(colorRefToArgb(null), 0xFF000000);
    });

    test('font family mapping', () {
      expect(mapFontFamily('Courier New'), 'mono');
      expect(mapFontFamily('Times New Roman'), 'serif');
      expect(mapFontFamily('Calibri Light'), 'sans');
      expect(mapFontFamily(null), 'sans');
    });
  });

  group('computeCuts', () {
    test('cuts land only in gaps between occupied intervals', () {
      // Blobs of content every 300pt with 60pt gaps.
      final occupied = [
        for (var i = 0; i < 10; i++) [i * 360.0, i * 360.0 + 300.0]
      ];
      final cuts = computeCuts(
          occupied: occupied, start: 0, end: 3600, target: 842);
      expect(cuts, isNotEmpty);
      for (final c in cuts) {
        for (final iv in occupied) {
          expect(c > iv[0] && c < iv[1], isFalse,
              reason: 'cut $c crosses interval $iv');
        }
      }
    });

    test('one uncuttable blob yields no cuts', () {
      final cuts = computeCuts(
        occupied: [
          [0.0, 5000.0]
        ],
        start: 0,
        end: 5000,
        target: 842,
      );
      expect(cuts, isEmpty);
    });
  });

  group('tileContent', () {
    test('empty content yields a single default page', () {
      final bands = tileContent([]);
      expect(bands, hasLength(1));
      expect(bands.first.cells, hasLength(1));
      expect(bands.first.cells.first.rect.width, kMinPageW);
      expect(bands.first.cells.first.rect.height, kMinPageH);
    });

    test('tall gap-separated content splits into bands, none cut', () {
      // 8 content blobs stacked vertically, 500pt tall with 80pt gaps.
      final elements = [
        for (var i = 0; i < 8; i++)
          el(50, i * 580.0, 400, i * 580.0 + 500.0)
      ];
      final bands = tileContent(elements);
      expect(bands.length, greaterThan(1));

      final all = bands.expand((b) => b.cells).toList();
      final assigned = all.expand((c) => c.elements).length;
      expect(assigned, elements.length, reason: 'every element placed once');

      for (final cell in all) {
        for (final e in cell.elements) {
          expect(e.bbox.top, greaterThanOrEqualTo(cell.rect.top - 0.01));
          expect(e.bbox.bottom, lessThanOrEqualTo(cell.rect.bottom + 0.01));
          expect(e.bbox.left, greaterThanOrEqualTo(cell.rect.left - 0.01));
          expect(e.bbox.right, lessThanOrEqualTo(cell.rect.right + 0.01));
        }
      }
    });

    test('bands tile the content region contiguously (spacing preserved)',
        () {
      final elements = [
        for (var i = 0; i < 6; i++)
          el(50, i * 700.0, 400, i * 700.0 + 600.0)
      ];
      final bands = tileContent(elements);
      final cells = bands.map((b) => b.cells.first).toList();
      for (var i = 1; i < cells.length; i++) {
        expect(cells[i].rect.top, closeTo(cells[i - 1].rect.bottom, 0.01),
            reason: 'band $i must start where band ${i - 1} ends');
      }
    });
  });

  group('buildPageTree', () {
    test('sub-pages nest under their parent by level', () {
      final tree = buildPageTree([
        {'title': 'A', 'level': 1},
        {'title': 'A.1', 'level': 2},
        {'title': 'A.1.a', 'level': 3},
        {'title': 'A.2', 'level': 2},
        {'title': 'B', 'level': 1},
      ]);
      expect(tree, hasLength(2));
      expect(tree[0].page['title'], 'A');
      expect(tree[0].children, hasLength(2));
      expect(tree[0].children[0].page['title'], 'A.1');
      expect(tree[0].children[0].children.single.page['title'], 'A.1.a');
      expect(tree[1].page['title'], 'B');
      expect(tree[1].children, isEmpty);
    });
  });

  group('converted store round-trips through the app models', () {
    final storeDir = Directory(
        'tools/onenote_importer/output/teaching_topics_new/omininote_store');

    test('notebook, sections, canvases, pages all parse', () {
      if (!storeDir.existsSync()) {
        markTestSkipped('no converted store present — run the importer first');
        return;
      }

      final index = jsonDecode(
              File('${storeDir.path}/notebooks.json').readAsStringSync())
          as Map<String, dynamic>;
      expect(index, isNotEmpty);

      for (final entry in index.entries) {
        final nb = Notebook.fromJson(entry.value as Map<String, dynamic>);
        expect(nb.id, entry.key);
        expect(nb.allSectionIds, isNotEmpty);

        var canvasesSeen = 0, strokesSeen = 0, objectsSeen = 0;
        for (final secId in nb.allSectionIds) {
          final secFile = File(
              '${storeDir.path}/notebooks/${nb.id}/sections/$secId/section.json');
          expect(secFile.existsSync(), isTrue,
              reason: 'section file for $secId');
          final sec = Section.fromJson(
              jsonDecode(secFile.readAsStringSync()) as Map<String, dynamic>);
          expect(sec.notebookId, nb.id);

          for (final cvId in sec.allCanvasIds) {
            canvasesSeen++;
            final cvDir =
                '${storeDir.path}/notebooks/${nb.id}/sections/$secId/canvases/$cvId';
            final cv = Canvas.fromJson(
                jsonDecode(File('$cvDir/canvas.json').readAsStringSync())
                    as Map<String, dynamic>);
            expect(cv.sectionId, secId);
            expect(cv.rows, isNotEmpty);

            for (final row in cv.rows) {
              expect(row.pageIds, isNotEmpty);
              for (final pgId in row.pageIds) {
                final page = CanvasPage.fromJson(
                    jsonDecode(File('$cvDir/pages/$pgId.json').readAsStringSync())
                        as Map<String, dynamic>);
                expect(page.id, pgId);
                expect(page.width, greaterThan(0));
                expect(page.height, greaterThan(0));
                strokesSeen += page.strokes.length;
                objectsSeen += page.objects.length;

                // Every element must lie within its page (the tiling
                // guarantee), and referenced assets must exist.
                for (final s in page.strokes) {
                  expect(s.points, isNotEmpty);
                  for (final p in s.points) {
                    expect(p.x, inInclusiveRange(-1, page.width + 1));
                    expect(p.y, inInclusiveRange(-1, page.height + 1));
                  }
                }
                for (final o in page.objects) {
                  final r = o.bounds;
                  expect(r.left, greaterThanOrEqualTo(-1));
                  expect(r.top, greaterThanOrEqualTo(-1));
                  expect(r.right, lessThanOrEqualTo(page.width + 1));
                  expect(r.bottom, lessThanOrEqualTo(page.height + 1));
                  if (o is ImageElement) {
                    expect(
                        File('$cvDir/assets/${o.assetId}').existsSync(), isTrue,
                        reason: 'image asset ${o.assetId}');
                  }
                  if (o is AttachmentElement) {
                    expect(
                        File('$cvDir/assets/${o.assetId}').existsSync(), isTrue,
                        reason: 'attachment asset ${o.assetId}');
                  }
                }
              }
            }
          }
        }
        expect(canvasesSeen, greaterThan(0));
        expect(strokesSeen, greaterThan(0));
        expect(objectsSeen, greaterThan(0));
      }
    });
  });
}
