import 'dart:convert';
import 'dart:ui';
import 'package:flutter_test/flutter_test.dart';
import 'package:omininote/models/canvas.dart';
import 'package:omininote/models/canvas_page.dart';
import 'package:omininote/models/element.dart';
import 'package:omininote/models/notebook.dart';
import 'package:omininote/models/section.dart';
import 'package:omininote/models/tree.dart';

void main() {
  group('Element serialization round-trips', () {
    test('StrokeElement keeps points, pressure, tool, color, size', () {
      final stroke = StrokeElement(
        id: 'el_1',
        tool: StrokeTool.highlighter,
        color: const Color(0xFFD9553B),
        size: 6.5,
        points: [StrokePoint(1, 2, 0.3), StrokePoint(10.5, 20.25, 0.9)],
      );

      final decoded =
          CanvasElement.fromJson(
                jsonDecode(jsonEncode(stroke.toJson()))
                    as Map<String, dynamic>,
              )
              as StrokeElement;

      expect(decoded.id, 'el_1');
      expect(decoded.tool, StrokeTool.highlighter);
      expect(decoded.color.toARGB32(), 0xFFD9553B);
      expect(decoded.size, 6.5);
      expect(decoded.points.length, 2);
      expect(decoded.points[1].x, 10.5);
      expect(decoded.points[1].p, 0.9);
    });

    test('TextElement keeps rect, style, alignment, rotation', () {
      final text = TextElement(
        id: 'el_2',
        rect: const Rect.fromLTWH(10, 20, 200, 48),
        rotation: 0.5,
        text: 'hello world',
        fontFamily: 'mono',
        fontSize: 21,
        color: const Color(0xFF2E9E5B),
        bold: true,
        italic: true,
        align: TextAlignOption.center,
      );

      final decoded =
          CanvasElement.fromJson(
                jsonDecode(jsonEncode(text.toJson())) as Map<String, dynamic>,
              )
              as TextElement;

      expect(decoded.text, 'hello world');
      expect(decoded.rect, const Rect.fromLTWH(10, 20, 200, 48));
      expect(decoded.rotation, 0.5);
      expect(decoded.fontFamily, 'mono');
      expect(decoded.bold, isTrue);
      expect(decoded.italic, isTrue);
      expect(decoded.align, TextAlignOption.center);
    });

    test('TextElement preserves per-run styling', () {
      final text = TextElement(
        id: 'el_runs',
        rect: const Rect.fromLTWH(0, 0, 200, 40),
        color: const Color(0xFF000000),
        runs: [
          TextRun(
            text: 'Hello ',
            fontSize: 16,
            bold: false,
            italic: false,
            color: const Color(0xFF000000),
            fontFamily: 'sans',
          ),
          TextRun(
            text: 'world',
            fontSize: 24,
            bold: true,
            italic: false,
            color: const Color(0xFFD9553B),
            fontFamily: 'serif',
          ),
        ],
      );

      final decoded =
          CanvasElement.fromJson(
                jsonDecode(jsonEncode(text.toJson())) as Map<String, dynamic>,
              )
              as TextElement;

      expect(decoded.text, 'Hello world');
      expect(decoded.runs.length, 2);
      expect(decoded.runs[1].fontSize, 24);
      expect(decoded.runs[1].bold, isTrue);
      expect(decoded.runs[1].color.toARGB32(), 0xFFD9553B);
      expect(decoded.runs[1].fontFamily, 'serif');
    });

    test('legacy flat text (no runs) upgrades to a single run', () {
      final decoded =
          CanvasElement.fromJson({
                'type': 'text',
                'id': 'el_legacy',
                'rect': {'x': 0, 'y': 0, 'w': 100, 'h': 40},
                'text': 'legacy',
                'fontSize': 18.0,
                'color': 0xFF112233,
                'bold': true,
              })
              as TextElement;
      expect(decoded.text, 'legacy');
      expect(decoded.runs.length, 1);
      expect(decoded.runs.single.bold, isTrue);
      expect(decoded.runs.single.fontSize, 18);
    });

    test('ImageElement keeps rect, rotation, assetId', () {
      final image = ImageElement(
        id: 'el_3',
        rect: const Rect.fromLTWH(5, 6, 120, 80),
        rotation: -0.25,
        assetId: 'abc123.png',
      );

      final decoded =
          CanvasElement.fromJson(
                jsonDecode(jsonEncode(image.toJson())) as Map<String, dynamic>,
              )
              as ImageElement;

      expect(decoded.assetId, 'abc123.png');
      expect(decoded.rect.width, 120);
      expect(decoded.rotation, -0.25);
    });

    test('legacy stroke points without pressure default to 0.5', () {
      final decoded =
          CanvasElement.fromJson({
                'type': 'stroke',
                'id': 'el_4',
                'tool': 'pen',
                'color': 0xFF000000,
                'size': 4.0,
                'points': [
                  {'x': 1.0, 'y': 2.0},
                ],
              })
              as StrokeElement;
      expect(decoded.points.single.p, 0.5);
    });
  });

  group('CanvasPage round-trips', () {
    test('PDF-backed page keeps source, size, background, elements', () {
      final page = CanvasPage(
        id: 'pg_1',
        width: 612,
        height: 792,
        background: const PageBackground(
          color: Color(0xFFF8F1E3),
          pattern: BgPattern.grid,
        ),
        source: const PdfSource(assetId: 'deadbeef.pdf', pageIndex: 3),
        elements: [
          StrokeElement(
            id: 'el_1',
            tool: StrokeTool.pen,
            color: const Color(0xFF000000),
            size: 4,
            points: [StrokePoint(0, 0, 0.5)],
          ),
        ],
      );

      final decoded = CanvasPage.fromJson(
        jsonDecode(jsonEncode(page.toJson())) as Map<String, dynamic>,
      );

      expect(decoded.id, 'pg_1');
      expect(decoded.width, 612);
      expect(decoded.source?.assetId, 'deadbeef.pdf');
      expect(decoded.source?.pageIndex, 3);
      expect(decoded.background.pattern, BgPattern.grid);
      expect(decoded.background.color.toARGB32(), 0xFFF8F1E3);
      expect(decoded.elements.single, isA<StrokeElement>());
    });
  });

  group('Canvas round-trips', () {
    test('rows, defaults and attachments survive', () {
      final canvas = Canvas(
        id: 'c1',
        notebookId: 'n1',
        sectionId: 's1',
        name: 'Physics',
        createdAt: DateTime(2026, 7, 6),
        defaultPageWidth: 500,
        defaultPageHeight: 700,
        defaultBackground: const PageBackground(pattern: BgPattern.ruled),
        rows: [
          PageRow(id: 'r1', pageIds: ['p1']),
          PageRow(id: 'r2', pageIds: ['p2', 'p3']),
        ],
        attachments: [
          Attachment(
            id: 'a1',
            name: 'syllabus.pdf',
            assetId: 'cafe.pdf',
            mime: 'application/pdf',
            addedAt: DateTime(2026, 7, 6),
          ),
        ],
      );

      final decoded = Canvas.fromJson(
        jsonDecode(jsonEncode(canvas.toJson())) as Map<String, dynamic>,
      );

      expect(decoded.name, 'Physics');
      expect(decoded.sectionId, 's1');
      expect(decoded.rows.length, 2);
      expect(decoded.rows[1].pageIds, ['p2', 'p3']);
      expect(decoded.pageCount, 3);
      expect(decoded.defaultBackground.pattern, BgPattern.ruled);
      expect(decoded.attachments.single.name, 'syllabus.pdf');
    });
  });

  group('Tree round-trips (shared by Notebook & Section)', () {
    test('a flat leaf list survives + color (notebook of sections)', () {
      final nb = Notebook(
        id: 'n1',
        name: 'School',
        createdAt: DateTime(2026, 1, 2),
        color: 0xFF3B7DD8,
        nodes: [LeafNode('s1'), LeafNode('s2')],
      );
      final decoded = Notebook.fromJson(
        jsonDecode(jsonEncode(nb.toJson())) as Map<String, dynamic>,
      );
      expect(decoded.allSectionIds, ['s1', 's2']);
      expect(decoded.color, 0xFF3B7DD8);
      expect(decoded.nodes.every((n) => n is LeafNode), isTrue);
    });

    test('nested folders (super-sections in super-sections) survive', () {
      // Exercised via Section (canvas tree), same TreeNode structure as
      // Notebook's section tree.
      final section = Section(
        id: 's2',
        notebookId: 'n2',
        name: 'Work',
        createdAt: DateTime(2026, 1, 2),
        nodes: [
          LeafNode('top'),
          FolderNode(
            id: 'g1',
            name: 'Projects',
            color: 0xFF2E9E5B,
            collapsed: true,
            children: [
              LeafNode('p1'),
              FolderNode(
                id: 'g2',
                name: 'Archive',
                children: [LeafNode('a1'), LeafNode('a2')],
              ),
            ],
          ),
        ],
      );
      final decoded = Section.fromJson(
        jsonDecode(jsonEncode(section.toJson())) as Map<String, dynamic>,
      );

      expect(decoded.allCanvasIds, ['top', 'p1', 'a1', 'a2']);

      final folder = decoded.nodes[1] as FolderNode;
      expect(folder.name, 'Projects');
      expect(folder.color, 0xFF2E9E5B);
      expect(folder.collapsed, isTrue);
      final nested = folder.children[1] as FolderNode;
      expect(nested.name, 'Archive');
      expect(nested.collectLeafIds(), ['a1', 'a2']);
    });

    test('legacy sectionIds (no nodes) upgrades to a flat leaf tree', () {
      final decoded = Notebook.fromJson({
        'id': 'n3',
        'name': 'Legacy',
        'createdAt': DateTime(2026, 1, 2).toIso8601String(),
        'sectionIds': ['x', 'y', 'z'],
      });
      expect(decoded.allSectionIds, ['x', 'y', 'z']);
      expect(decoded.nodes.length, 3);
      expect(decoded.nodes.every((n) => n is LeafNode), isTrue);
    });
  });

  group('Element transforms', () {
    test('translate moves stroke points and invalidates cache', () {
      final stroke = StrokeElement(
        id: 'el',
        tool: StrokeTool.pen,
        color: const Color(0xFF000000),
        size: 4,
        points: [StrokePoint(10, 10, 0.5)],
      );
      stroke.translate(5, -3);
      expect(stroke.points.single.x, 15);
      expect(stroke.points.single.y, 7);
    });

    test('stroke scale about an anchor scales geometry and stroke width', () {
      final stroke = StrokeElement(
        id: 'el',
        tool: StrokeTool.pen,
        color: const Color(0xFF000000),
        size: 4,
        points: [StrokePoint(10, 0, 0.5)],
      );
      stroke.scaleBy(2, Offset.zero);
      expect(stroke.points.single.x, 20);
      expect(stroke.size, 8);
    });

    test('text scale moves the anchor but never changes size', () {
      // Text boxes auto-size to content; resizing must not rescale font/box.
      final text = TextElement(
        id: 'el2',
        rect: const Rect.fromLTWH(10, 10, 100, 40),
        text: 'x',
        color: const Color(0xFF000000),
        fontSize: 16,
      );
      text.scaleBy(0.5, Offset.zero);
      expect(text.rect, const Rect.fromLTWH(5, 5, 100, 40)); // moved, not sized
      expect(text.fontSize, 16); // unchanged
    });
  });
}
