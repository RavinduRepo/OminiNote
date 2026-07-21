import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui';
import 'package:flutter_test/flutter_test.dart';
import 'package:omininote/models/canvas.dart';
import 'package:omininote/models/canvas_page.dart';
import 'package:omininote/models/element.dart';
import 'package:omininote/models/notebook.dart';
import 'package:omininote/models/section.dart';
import 'package:omininote/models/shape_template.dart';
import 'package:omininote/models/tree.dart';
import 'package:omininote/services/notebook_service.dart';

void main() {
  group('Element serialization round-trips', () {
    test('StrokeElement keeps points, pressure, tool, color, size', () {
      final stroke = StrokeElement(
        id: 'el_1',
        deviceId: 'test_device',
        z: '0|a0:',
        tool: StrokeTool.highlighter,
        color: const Color(0xFFD9553B),
        size: 6.5,
        points: [StrokePoint(1, 2, 0.3), StrokePoint(10.5, 20.25, 0.9)],
      );

      final decoded =
          CanvasElement.fromJson(
                jsonDecode(jsonEncode(stroke.toJson())) as Map<String, dynamic>,
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
        deviceId: 'test_device',
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
        deviceId: 'test_device',
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

    test('TextElement linkId (split-paste group) survives json + deepCopy', () {
      final text = TextElement(
        id: 'el_linked',
        deviceId: 'test_device',
        rect: const Rect.fromLTWH(0, 0, 200, 40),
        color: const Color(0xFF000000),
        text: 'part one',
        linkId: 'lnk_1',
      );

      final decoded =
          CanvasElement.fromJson(
                jsonDecode(jsonEncode(text.toJson())) as Map<String, dynamic>,
              )
              as TextElement;
      expect(decoded.linkId, 'lnk_1');
      expect(text.deepCopy().linkId, 'lnk_1');

      // Ordinary boxes stay null (and the json key is omitted).
      final plain = TextElement(
        id: 'el_plain',
        deviceId: 'test_device',
        rect: const Rect.fromLTWH(0, 0, 100, 40),
        color: const Color(0xFF000000),
        text: 'x',
      );
      expect(plain.toJson().containsKey('gid'), isFalse);
      final plainBack =
          CanvasElement.fromJson(
                jsonDecode(jsonEncode(plain.toJson())) as Map<String, dynamic>,
              )
              as TextElement;
      expect(plainBack.linkId, isNull);
    });

    test('TextElement manualWidth (resized box) survives json + deepCopy', () {
      final resized = TextElement(
        id: 'el_resized',
        deviceId: 'test_device',
        rect: const Rect.fromLTWH(10, 10, 150, 60),
        color: const Color(0xFF000000),
        text: 'wrapped text',
        manualWidth: 150,
      );
      final decoded =
          CanvasElement.fromJson(
                jsonDecode(jsonEncode(resized.toJson())) as Map<String, dynamic>,
              )
              as TextElement;
      expect(decoded.manualWidth, 150);
      expect(resized.deepCopy().manualWidth, 150);

      // Auto-sizing boxes omit the key and decode back to null.
      final auto = TextElement(
        id: 'el_auto',
        deviceId: 'test_device',
        rect: const Rect.fromLTWH(0, 0, 100, 40),
        color: const Color(0xFF000000),
        text: 'x',
      );
      expect(auto.toJson().containsKey('mw'), isFalse);
      final autoBack =
          CanvasElement.fromJson(
                jsonDecode(jsonEncode(auto.toJson())) as Map<String, dynamic>,
              )
              as TextElement;
      expect(autoBack.manualWidth, isNull);
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
        deviceId: 'test_device',
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
        deviceId: 'test_device',
        width: 612,
        height: 792,
        background: const PageBackground(
          color: Color(0xFFF8F1E3),
          pattern: BgPattern.grid,
        ),
        source: const PdfSource(assetId: 'deadbeef.pdf', pageIndex: 3),
        strokes: [
          StrokeElement(
            id: 'el_1',
            deviceId: 'test_device',
            z: '0|a0:',
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
      expect(decoded.strokes.single, isA<StrokeElement>());
    });

    test('cloneWithNewIds: fresh page/element ids, same content, assets listed',
        () {
      final page = CanvasPage(
        id: 'pg_src',
        deviceId: 'dev_a',
        width: 400,
        height: 600,
        source: const PdfSource(assetId: 'doc.pdf', pageIndex: 1),
        strokes: [
          StrokeElement(
            id: 'el_stroke',
            deviceId: 'dev_a',
            z: '0|a0:',
            tool: StrokeTool.pen,
            color: const Color(0xFF000000),
            size: 4,
            points: [StrokePoint(1, 2, 0.5)],
          ),
        ],
        objects: [
          ImageElement(
            id: 'el_img',
            deviceId: 'dev_a',
            rect: const Rect.fromLTWH(0, 0, 50, 50),
            assetId: 'pic.png',
          ),
        ],
      );

      final clone = page.cloneWithNewIds(deviceId: 'dev_b');
      // New ids everywhere so the copy can coexist with the original.
      expect(clone.id, isNot('pg_src'));
      expect(clone.deviceId, 'dev_b');
      expect(clone.strokes.single.id, isNot('el_stroke'));
      expect(clone.objects.single.id, isNot('el_img'));
      // Content preserved.
      expect(clone.width, 400);
      expect(clone.source?.assetId, 'doc.pdf');
      expect(clone.strokes.single.points.single.p, 0.5);
      expect((clone.objects.single as ImageElement).assetId, 'pic.png');
      // Assets to copy on paste = pdf + image.
      expect(page.referencedAssetIds(), {'doc.pdf', 'pic.png'});
    });

    test('zIndex round-trips and survives deepCopy (cross-list layering)', () {
      final el = ImageElement(
        id: 'img1',
        deviceId: 'test_device',
        rect: const Rect.fromLTWH(0, 0, 100, 100),
        assetId: 'a.png',
      )..zIndex = -2;
      final decoded = CanvasElement.fromJson(
        jsonDecode(jsonEncode(el.toJson())) as Map<String, dynamic>,
      );
      expect(decoded.zIndex, -2);
      expect(el.deepCopy().zIndex, -2);

      // zOrderedElements: a negative-z image paints under a default-z stroke.
      final stroke = StrokeElement(
        id: 's1',
        deviceId: 'test_device',
        z: '0|a0:',
        tool: StrokeTool.pen,
        color: const Color(0xFF000000),
        size: 3,
        points: [StrokePoint(0, 0, 0.5)],
      );
      final page = CanvasPage(
        id: 'p1',
        deviceId: 'test_device',
        strokes: [stroke],
        objects: [el],
      );
      final ordered = zOrderedElements(page);
      expect(
        ordered.first.id,
        'img1',
        reason: 'sent-to-back image must paint before (under) ink',
      );
      expect(ordered.last.id, 's1');
    });

    test('Bookmarks ride canvas.json (round-trip)', () {
      final canvas = Canvas(
        id: 'c1',
        notebookId: 'n1',
        sectionId: 's1',
        name: 'B',
        createdAt: DateTime(2026, 7, 7),
        bookmarks: [
          Bookmark(
            id: 'bm1',
            name: 'Chapter 2',
            pageId: 'p9',
            createdAt: DateTime(2026, 7, 7),
          ),
        ],
      );
      final decoded = Canvas.fromJson(
        jsonDecode(jsonEncode(canvas.toJson())) as Map<String, dynamic>,
      );
      expect(decoded.bookmarks.single.name, 'Chapter 2');
      expect(decoded.bookmarks.single.pageId, 'p9');
    });

    test('AttachmentElement round-trips rect, assetId, name, mime', () {
      final el = AttachmentElement(
        id: 'att_1',
        deviceId: 'test_device',
        rect: const Rect.fromLTWH(20, 30, 180, 44),
        assetId: 'deadbeef.pdf',
        name: 'paper.pdf',
        mime: 'application/pdf',
      );
      final decoded = CanvasElement.fromJson(
        jsonDecode(jsonEncode(el.toJson())) as Map<String, dynamic>,
      );
      expect(decoded, isA<AttachmentElement>());
      final a = decoded as AttachmentElement;
      expect(a.rect, const Rect.fromLTWH(20, 30, 180, 44));
      expect(a.assetId, 'deadbeef.pdf');
      expect(a.name, 'paper.pdf');
      expect(a.mime, 'application/pdf');
    });

    test('deletedAt (page tombstone) and deletedObjects survive', () {
      final page = CanvasPage(
        id: 'pg_1',
        deviceId: 'test_device',
        rev: 4,
        deletedAt: DateTime(2026, 7, 7),
        deletedObjects: [
          EraseTombstone(
            strokeId: 'el_deleted',
            erasedAt: DateTime(2026, 7, 7),
            deviceId: 'test_device',
          ),
        ],
      );

      final decoded = CanvasPage.fromJson(
        jsonDecode(jsonEncode(page.toJson())) as Map<String, dynamic>,
      );

      expect(decoded.deletedAt, DateTime(2026, 7, 7));
      expect(decoded.deletedObjects.single.strokeId, 'el_deleted');
    });

    test('purgedAt (terminal page marker) round-trips; absent stays null', () {
      final purged = CanvasPage(
        id: 'pg_1',
        deviceId: 'test_device',
        rev: 7,
        deletedAt: DateTime(2026, 7, 12),
        purgedAt: DateTime(2026, 7, 12),
      );
      final decoded = CanvasPage.fromJson(
        jsonDecode(jsonEncode(purged.toJson())) as Map<String, dynamic>,
      );
      expect(decoded.purgedAt, DateTime(2026, 7, 12));

      // A normal (never-purged) page leaves purgedAt out of the JSON entirely.
      final live = CanvasPage(id: 'pg_2', deviceId: 'test_device');
      expect(live.toJson().containsKey('purgedAt'), isFalse);
      expect(
        CanvasPage.fromJson(
          jsonDecode(jsonEncode(live.toJson())) as Map<String, dynamic>,
        ).purgedAt,
        isNull,
      );
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

    test('audio recordings survive; empty recordings omit the JSON key', () {
      final base = Canvas(
        id: 'c1',
        notebookId: 'n1',
        sectionId: 's1',
        name: 'Lecture',
        createdAt: DateTime(2026, 7, 18),
      );
      // No recordings → the key is absent (keeps old canvas.json byte-stable
      // and avoids spurious merge diffs).
      expect(base.toJson().containsKey('recordings'), isFalse);

      final canvas = Canvas(
        id: 'c1',
        notebookId: 'n1',
        sectionId: 's1',
        name: 'Lecture',
        createdAt: DateTime(2026, 7, 18),
        recordings: [
          AudioRecording(
            id: 'rec1',
            name: 'Take 1',
            assetId: 'beef.m4a',
            startedAt: DateTime(2026, 7, 18, 9, 30),
            durationMs: 65000,
            createdAt: DateTime(2026, 7, 18, 9, 31),
          ),
        ],
      );
      final decoded = Canvas.fromJson(
        jsonDecode(jsonEncode(canvas.toJson())) as Map<String, dynamic>,
      );
      expect(decoded.recordings.single.name, 'Take 1');
      expect(decoded.recordings.single.assetId, 'beef.m4a');
      expect(decoded.recordings.single.durationMs, 65000);
      expect(decoded.recordings.single.startedAt, DateTime(2026, 7, 18, 9, 30));
    });
  });

  group('Tree round-trips (shared by Notebook & Section)', () {
    test('a flat leaf list survives + color (notebook of sections)', () {
      final nb = Notebook(
        id: 'n1',
        deviceId: 'test_device',
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

    test('deletedFolders (binned super-sections) round-trip with subtree', () {
      final nb = Notebook(
        id: 'n1',
        deviceId: 'test_device',
        name: 'School',
        createdAt: DateTime(2026, 1, 2),
        nodes: [LeafNode('s_live')],
        deletedFolders: [
          DeletedFolder(
            node: FolderNode(
              id: 'grp1',
              name: 'Archive',
              children: [LeafNode('s_a'), LeafNode('s_b')],
            ),
            deletedAt: DateTime(2026, 7, 13),
          ),
        ],
      );
      final decoded = Notebook.fromJson(
        jsonDecode(jsonEncode(nb.toJson())) as Map<String, dynamic>,
      );
      // The deleted folder's sections are NOT in the live tree...
      expect(decoded.allSectionIds, ['s_live']);
      // ...but its subtree survives intact in deletedFolders for restore.
      expect(decoded.deletedFolders.single.node.name, 'Archive');
      expect(decoded.deletedFolders.single.node.collectLeafIds(),
          ['s_a', 's_b']);
      expect(decoded.deletedFolders.single.deletedAt, DateTime(2026, 7, 13));

      // A notebook with no binned folders omits the key entirely.
      final clean = Notebook(
        id: 'n2',
        deviceId: 'test_device',
        name: 'Clean',
        createdAt: DateTime(2026, 1, 2),
      );
      expect(clean.toJson().containsKey('deletedFolders'), isFalse);
    });

    test('syncTarget round-trips; null → default account, explicit wins', () {
      // Explicit target survives serialization.
      final bound = Notebook(
        id: 'n1',
        deviceId: 'test_device',
        name: 'Bound',
        createdAt: DateTime(2026, 1, 2),
        syncTarget: 'sub-account-A',
      );
      final decoded = Notebook.fromJson(
        jsonDecode(jsonEncode(bound.toJson())) as Map<String, dynamic>,
      );
      expect(decoded.syncTarget, 'sub-account-A');
      expect(NotebookService.effectiveSyncTarget(decoded, 'default-X'),
          'sub-account-A');

      // Null target falls back to the default account (no eager migration).
      final unbound = Notebook(
        id: 'n2',
        deviceId: 'test_device',
        name: 'Unbound',
        createdAt: DateTime(2026, 1, 2),
      );
      final decodedUnbound = Notebook.fromJson(
        jsonDecode(jsonEncode(unbound.toJson())) as Map<String, dynamic>,
      );
      expect(decodedUnbound.syncTarget, isNull);
      expect(NotebookService.effectiveSyncTarget(decodedUnbound, 'default-X'),
          'default-X');
      expect(NotebookService.effectiveSyncTarget(decodedUnbound, null), isNull);

      // A legacy notebook with no syncTarget key decodes to null.
      final legacy = Notebook.fromJson({
        'id': 'n3',
        'name': 'Legacy',
        'createdAt': DateTime(2026, 1, 2).toIso8601String(),
        'sectionIds': <String>[],
      });
      expect(legacy.syncTarget, isNull);
    });

    test('nested folders (super-sections in super-sections) survive', () {
      // Exercised via Section (canvas tree), same TreeNode structure as
      // Notebook's section tree.
      final section = Section(
        id: 's2',
        deviceId: 'test_device',
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

    test('insertLeafAfter drops a new leaf right below the target (top level)',
        () {
      final nodes = <TreeNode>[LeafNode('a'), LeafNode('b'), LeafNode('c')];
      final ok = TreeOps.insertLeafAfter(nodes, 'b', LeafNode('new'));
      expect(ok, isTrue);
      expect(nodes.map((n) => (n as LeafNode).refId).toList(),
          ['a', 'b', 'new', 'c']);
    });

    test('insertLeafAfter finds the target inside a folder', () {
      final folder = FolderNode(id: 'g', name: 'G', children: [
        LeafNode('p1'),
        LeafNode('p2'),
      ]);
      final nodes = <TreeNode>[LeafNode('top'), folder];
      final ok = TreeOps.insertLeafAfter(nodes, 'p1', LeafNode('new'));
      expect(ok, isTrue);
      expect(folder.children.map((n) => (n as LeafNode).refId).toList(),
          ['p1', 'new', 'p2']);
      // Top level untouched.
      expect(nodes.length, 2);
    });

    test('insertLeafAfter returns false when the target is missing', () {
      final nodes = <TreeNode>[LeafNode('a'), LeafNode('b')];
      final ok = TreeOps.insertLeafAfter(nodes, 'zzz', LeafNode('new'));
      expect(ok, isFalse);
      expect(nodes.length, 2);
    });

    test('insertNodeAfter drops a super-section below a selected leaf', () {
      final nodes = <TreeNode>[LeafNode('a'), LeafNode('b')];
      final folder = FolderNode(id: 'g', name: 'G');
      final ok = TreeOps.insertNodeAfter(nodes, 'a', folder);
      expect(ok, isTrue);
      expect(nodes[1], same(folder)); // right after 'a'
      expect(nodes.length, 3);
    });

    test('insertNodeAfter can target a folder id (below a selected folder)', () {
      final folder = FolderNode(id: 'g', name: 'G');
      final nodes = <TreeNode>[LeafNode('a'), folder, LeafNode('b')];
      final ok = TreeOps.insertNodeAfter(nodes, 'g', LeafNode('new'));
      expect(ok, isTrue);
      expect((nodes[2] as LeafNode).refId, 'new'); // after the folder
    });
  });

  group('Element transforms', () {
    test('translate moves stroke points and invalidates cache', () {
      final stroke = StrokeElement(
        id: 'el',
        deviceId: 'test_device',
        z: '0|a0:',
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
        deviceId: 'test_device',
        z: '0|a0:',
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
        deviceId: 'test_device',
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

  group('scaleXY (non-uniform stretch)', () {
    test('stroke scales points per axis; width uses the geometric mean', () {
      final s = StrokeElement(
        id: 's',
        deviceId: 'd',
        z: '0|a0:',
        tool: StrokeTool.pen,
        color: const Color(0xFF000000),
        size: 4,
        points: [StrokePoint(0, 0, 0.5), StrokePoint(10, 10, 0.5)],
      );
      s.scaleXY(2, 1, Offset.zero); // stretch x only, anchor at origin
      expect(s.points[1].x, 20);
      expect(s.points[1].y, 10); // y unchanged
      expect(s.size, closeTo(4 * math.sqrt(2), 1e-9));
    });

    test('image stretches its rect per axis', () {
      final img = ImageElement(
        id: 'i',
        deviceId: 'd',
        rect: const Rect.fromLTWH(0, 0, 10, 10),
        assetId: 'a',
      );
      img.scaleXY(3, 2, Offset.zero);
      expect(img.rect, const Rect.fromLTWH(0, 0, 30, 20));
    });

    test('text keeps its size (moves only)', () {
      final t = TextElement(
        id: 't',
        deviceId: 'd',
        rect: const Rect.fromLTWH(10, 10, 100, 40),
        text: 'hi',
        color: const Color(0xFF000000),
      );
      t.scaleXY(2, 2, Offset.zero);
      expect(t.rect, const Rect.fromLTWH(20, 20, 100, 40)); // moved, not sized
    });

    test('attachment keeps its aspect (moves only)', () {
      final a = AttachmentElement(
        id: 'at',
        deviceId: 'd',
        rect: const Rect.fromLTWH(10, 0, 30, 20),
        assetId: 'a',
        name: 'f.pdf',
        mime: 'application/pdf',
      );
      a.scaleXY(2, 3, Offset.zero);
      expect(a.rect, const Rect.fromLTWH(20, 0, 30, 20)); // pos scaled, size kept
    });
  });

  group('ShapeTemplate', () {
    test('round-trips through JSON (multi-polyline unit-box geometry)', () {
      final t = ShapeTemplate(
        id: 'tmpl_1',
        name: 'Arrow',
        polylines: const [
          [Offset(0, 0.5), Offset(1, 0.5)],
          [Offset(0.7, 0.2), Offset(1, 0.5), Offset(0.7, 0.8)],
        ],
        createdAt: DateTime(2026, 7, 16, 9, 30),
      );
      final back = ShapeTemplate.fromJson(
          jsonDecode(jsonEncode(t.toJson())) as Map<String, dynamic>);
      expect(back.id, 'tmpl_1');
      expect(back.name, 'Arrow');
      expect(back.createdAt, DateTime(2026, 7, 16, 9, 30));
      expect(back.polylines.length, 2);
      expect(back.polylines[0].length, 2);
      expect(back.polylines[1].length, 3);
      expect(back.polylines[1][1], const Offset(1, 0.5));
    });
  });
}
