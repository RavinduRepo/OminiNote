import 'dart:ui';
import 'package:flutter_test/flutter_test.dart';
import 'package:omininote/canvas/canvas_controller.dart';
import 'package:omininote/models/canvas_page.dart';
import 'package:omininote/models/canvas.dart';
import 'package:omininote/models/element.dart';
import 'package:omininote/services/settings_service.dart';

StrokeElement _stroke(String id, {String device = 'dev'}) => StrokeElement(
      id: id,
      deviceId: device,
      z: '0|a0:',
      tool: StrokeTool.pen,
      color: const Color(0xFF000000),
      size: 3,
      points: [StrokePoint(0, 0, 0.5), StrokePoint(10, 10, 0.5)],
    );

void main() {
  // Tombstone paths stamp the local device id.
  SettingsService().deviceId = 'test_device';
  group('CanvasController.setPageBackground', () {
    test(
      'ticking "apply to all pages" changes every existing page and the '
      'section default; undo restores each page to its own prior background',
      () {
        final pageA = CanvasPage(
          id: 'a',
          deviceId: 'test_device',
          background: const PageBackground(
            color: Color(0xFFFFFFFF),
            pattern: BgPattern.blank,
          ),
        );
        final pageB = CanvasPage(
          id: 'b',
          deviceId: 'test_device',
          background: const PageBackground(
            color: Color(0xFFF8F1E3),
            pattern: BgPattern.ruled,
          ),
        );
        final section = Canvas(
          id: 's1',
          notebookId: 'n1',
          sectionId: 's1',
          name: 'Test',
          createdAt: DateTime(2026, 7, 6),
          rows: [
            PageRow(id: 'r1', pageIds: ['a']),
            PageRow(id: 'r2', pageIds: ['b']),
          ],
        );
        final controller = CanvasController(
          canvas: section,
          pages: {'a': pageA, 'b': pageB},
        );

        const newBg = PageBackground(
          color: Color(0xFF2A2A2E),
          pattern: BgPattern.dotted,
        );
        controller.setPageBackground('a', newBg, asSectionDefault: true);

        expect(controller.pages['a']!.background.pattern, BgPattern.dotted);
        expect(controller.pages['b']!.background.pattern, BgPattern.dotted);
        expect(controller.pages['b']!.background.color.toARGB32(), 0xFF2A2A2E);
        expect(section.defaultBackground.pattern, BgPattern.dotted);

        controller.undo();

        // Each page must return to its OWN prior background, not a shared one.
        expect(controller.pages['a']!.background.pattern, BgPattern.blank);
        expect(controller.pages['b']!.background.pattern, BgPattern.ruled);
        expect(controller.pages['b']!.background.color.toARGB32(), 0xFFF8F1E3);
      },
    );

    test('without the tick, only the targeted page changes', () {
      final pageA = CanvasPage(id: 'a', deviceId: 'test_device');
      final pageB = CanvasPage(id: 'b', deviceId: 'test_device');
      final section = Canvas(
        id: 's2',
        notebookId: 'n1',
          sectionId: 's1',
        name: 'Test2',
        createdAt: DateTime(2026, 7, 6),
        rows: [PageRow(id: 'r1', pageIds: ['a', 'b'])],
      );
      final controller = CanvasController(
        canvas: section,
        pages: {'a': pageA, 'b': pageB},
      );

      controller.setPageBackground(
        'a',
        const PageBackground(color: Color(0xFF2A2A2E), pattern: BgPattern.grid),
      );

      expect(controller.pages['a']!.background.pattern, BgPattern.grid);
      expect(controller.pages['b']!.background.pattern, BgPattern.blank);
      expect(section.defaultBackground.pattern, BgPattern.blank);
    });
  });

  group('CanvasController.reorderPages (preserve rows)', () {
    CanvasController make() {
      final pages = {
        for (final id in ['a', 'b', 'c', 'd'])
          id: CanvasPage(id: id, deviceId: 'test_device'),
      };
      final canvas = Canvas(
        id: 's5',
        notebookId: 'n1',
        sectionId: 's1',
        name: 'Reorder test',
        createdAt: DateTime(2026, 7, 9),
        rows: [
          PageRow(id: 'r1', pageIds: ['a']),
          PageRow(id: 'r2', pageIds: ['b', 'c']), // a horizontal (multi-page) row
          PageRow(id: 'r3', pageIds: ['d']),
        ],
      );
      return CanvasController(canvas: canvas, pages: pages);
    }

    test('orderedPageIds flattens rows in document order', () {
      expect(make().orderedPageIds, ['a', 'b', 'c', 'd']);
    });

    test('an undisturbed multi-page row stays grouped when reordered', () {
      final c = make();
      c.reorderPages(['a', 'd', 'b', 'c']); // move d up; b,c stay adjacent
      expect(c.canvas.rows.map((r) => r.pageIds).toList(), [
        ['a'],
        ['d'],
        ['b', 'c'], // preserved
      ]);
    });

    test('pulling a page out of a multi-page row splits it', () {
      final c = make();
      c.reorderPages(['a', 'b', 'd', 'c']); // d between b and c
      expect(c.canvas.rows.map((r) => r.pageIds).toList(), [
        ['a'],
        ['b'],
        ['d'],
        ['c'],
      ]);
    });

    test('reorder is undoable', () {
      final c = make();
      c.reorderPages(['d', 'a', 'b', 'c']);
      expect(c.orderedPageIds, ['d', 'a', 'b', 'c']);
      c.undo();
      expect(c.orderedPageIds, ['a', 'b', 'c', 'd']);
      expect(c.canvas.rows.map((r) => r.pageIds).toList(), [
        ['a'],
        ['b', 'c'],
        ['d'],
      ]);
    });
  });

  group('CanvasController.setTool / toolOptionsOpen', () {
    late CanvasController controller;

    setUp(() {
      final page = CanvasPage(id: 'a', deviceId: 'test_device');
      final section = Canvas(
        id: 's4',
        notebookId: 'n1',
          sectionId: 's1',
        name: 'Tool test',
        createdAt: DateTime(2026, 7, 6),
        rows: [PageRow(id: 'r1', pageIds: ['a'])],
      );
      controller = CanvasController(canvas: section, pages: {'a': page});
    });

    test('selecting a different tool never opens options', () {
      expect(controller.tool, CanvasTool.text); // Text is the default tool
      expect(controller.toolOptionsOpen, isFalse);

      controller.setTool(CanvasTool.highlighter);

      expect(controller.tool, CanvasTool.highlighter);
      expect(controller.toolOptionsOpen, isFalse);
    });

    test('tapping the already-active tool toggles options open, then closed', () {
      controller.setTool(CanvasTool.text); // already the default tool
      expect(controller.tool, CanvasTool.text);
      expect(controller.toolOptionsOpen, isTrue);

      controller.setTool(CanvasTool.text); // tap again
      expect(controller.toolOptionsOpen, isFalse);
    });

    test('switching to a different tool while options are open closes them', () {
      controller.setTool(CanvasTool.text); // opens options (already active)
      expect(controller.toolOptionsOpen, isTrue);

      controller.setTool(CanvasTool.lasso); // a genuinely different tool
      expect(controller.tool, CanvasTool.lasso);
      expect(controller.toolOptionsOpen, isFalse);
    });

    test('closeToolOptions is a no-op when already closed', () {
      expect(controller.toolOptionsOpen, isFalse);
      controller.closeToolOptions();
      expect(controller.toolOptionsOpen, isFalse);
    });
  });

  group('CanvasController delete → tombstones (v3)', () {
    late CanvasPage page;
    late CanvasController controller;

    setUp(() {
      page = CanvasPage(
        id: 'a',
        deviceId: 'test_device',
        strokes: [_stroke('s1'), _stroke('s2')],
      );
      final canvas = Canvas(
        id: 'c-del',
        notebookId: 'n1',
        sectionId: 's1',
        name: 'Del test',
        createdAt: DateTime(2026, 7, 7),
        rows: [PageRow(id: 'r1', pageIds: ['a'])],
      );
      controller = CanvasController(canvas: canvas, pages: {'a': page});
    });

    test('deleteSelection tombstones strokes; undo clears the tombstones', () {
      controller.selection = [page.strokes.first];
      controller.selectionPageId = 'a';
      controller.deleteSelection();

      expect(page.strokes.map((s) => s.id), ['s2']);
      expect(page.erased.map((e) => e.strokeId), ['s1'],
          reason: 'without the tombstone the deleted stroke resurrects on '
              'the next merge with a stale remote copy');

      controller.undo();
      expect(page.strokes.map((s) => s.id), containsAll(['s1', 's2']));
      expect(page.erased, isEmpty);
    });

    test(
        'the eraser TOOL writes tombstones on the first apply — not only on '
        'redo (the resurrection bug)', () {
      controller.setTool(CanvasTool.eraser);
      // Strokes run (0,0)→(10,10); a gesture at (5,5) hits them.
      controller.startToolGesture(const Offset(5, 5), 0.5);
      controller.endToolGesture();

      expect(page.strokes, isEmpty, reason: 'both strokes pass under (5,5)');
      expect(page.erased.map((e) => e.strokeId).toSet(), {'s1', 's2'},
          reason: 'the FIRST commit must write tombstones — the old code '
              'only wrote them on redo, so a plain erase synced as "stroke '
              'missing, no tombstone" and the other device restored it');

      controller.undo();
      expect(page.strokes.length, 2);
      expect(page.erased, isEmpty);

      controller.redo();
      expect(page.strokes, isEmpty);
      expect(page.erased.length, 2);
    });
  });

  group('CanvasController.addImageBelowInk (ink stays on top)', () {
    test(
        'inserted image sits below existing strokes in z-order, and below a '
        'stroke drawn afterward', () {
      final page = CanvasPage(
        id: 'a',
        deviceId: 'test_device',
        strokes: [_stroke('s1')],
      );
      final canvas = Canvas(
        id: 'c-img',
        notebookId: 'n1',
        sectionId: 's1',
        name: 'Img test',
        createdAt: DateTime(2026, 7, 8),
        rows: [PageRow(id: 'r1', pageIds: ['a'])],
      );
      final controller = CanvasController(canvas: canvas, pages: {'a': page});

      final image = ImageElement(
        id: 'img1',
        deviceId: 'test_device',
        rect: const Rect.fromLTWH(0, 0, 100, 100),
        assetId: 'asset1',
      );
      controller.addImageBelowInk('a', image);

      // Image lands beneath the lowest stroke z (default 0).
      expect(image.zIndex, lessThan(0));
      // Paint order: image first (under), stroke last (on top).
      final order = zOrderedElements(page).map((e) => e.id).toList();
      expect(order, ['img1', 's1']);

      // A stroke added afterward (default z 0) also renders above the image.
      page.strokes.add(_stroke('s2'));
      final order2 = zOrderedElements(page).map((e) => e.id).toList();
      expect(order2.first, 'img1');
      expect(order2.sublist(1), containsAll(['s1', 's2']));
    });
  });

  group('per-tool style memory', () {
    test('pen, highlighter, and text keep independent colors', () {
      final page = CanvasPage(id: 'a', deviceId: 'test_device');
      final canvas = Canvas(
        id: 'c-colors',
        notebookId: 'n1',
        sectionId: 's1',
        name: 'Colors',
        createdAt: DateTime(2026, 7, 7),
        rows: [PageRow(id: 'r1', pageIds: ['a'])],
      );
      final c = CanvasController(canvas: canvas, pages: {'a': page});

      c.setTool(CanvasTool.pen);
      c.color = const Color(0xFF111111);
      c.setTool(CanvasTool.highlighter);
      c.color = const Color(0xFF222222);
      c.setTool(CanvasTool.text);
      c.color = const Color(0xFF333333);

      c.setTool(CanvasTool.pen);
      expect(c.color.toARGB32(), 0xFF111111);
      c.setTool(CanvasTool.highlighter);
      expect(c.color.toARGB32(), 0xFF222222);
      c.setTool(CanvasTool.text);
      expect(c.color.toARGB32(), 0xFF333333);
    });
  });

  group('element rev stamping (LWW convergence)', () {
    test('a selection transform bumps rev/updatedAt on the moved elements',
        () {
      final page = CanvasPage(
        id: 'a',
        deviceId: 'test_device',
        strokes: [_stroke('s1')],
      );
      final canvas = Canvas(
        id: 'c-stamp',
        notebookId: 'n1',
        sectionId: 's1',
        name: 'Stamp test',
        createdAt: DateTime(2026, 7, 7),
        rows: [PageRow(id: 'r1', pageIds: ['a'])],
      );
      final controller = CanvasController(canvas: canvas, pages: {'a': page});
      final el = page.strokes.single;
      expect(el.rev, 1);

      // Lasso-select then drag the selection (move gesture).
      controller.setTool(CanvasTool.lasso);
      controller.selectSingle('a', el);
      controller.startToolGesture(const Offset(5, 5), 0.5);
      controller.updateToolGesture(const Offset(25, 25), 0.5);
      controller.endToolGesture();

      expect(el.rev, greaterThan(1),
          reason: 'without a rev bump, two devices\' copies of an edited '
              'element tie in LWW and never converge — "latest wins" '
              'depends on this');
    });
  });

  group('CanvasController.applyRemotePage (live merge of pulled pages)', () {
    test(
        'remote erase tombstone removes the live stroke; unsynced local '
        'stroke and remote-only stroke both survive', () {
      final page = CanvasPage(
        id: 'a',
        deviceId: 'devA',
        strokes: [_stroke('shared'), _stroke('localOnly', device: 'devA')],
      );
      final canvas = Canvas(
        id: 'c-live',
        notebookId: 'n1',
        sectionId: 's1',
        name: 'Live test',
        createdAt: DateTime(2026, 7, 7),
        rows: [PageRow(id: 'r1', pageIds: ['a'])],
      );
      final controller = CanvasController(canvas: canvas, pages: {'a': page});

      // Remote device erased 'shared' and drew 'remoteOnly'.
      final remote = CanvasPage(
        id: 'a',
        deviceId: 'devB',
        rev: 3,
        strokes: [_stroke('remoteOnly', device: 'devB')],
        erased: [
          EraseTombstone(
            strokeId: 'shared',
            erasedAt: DateTime.now(),
            deviceId: 'devB',
          ),
        ],
      );

      controller.applyRemotePage(remote);

      final live = controller.pages['a']!;
      final ids = live.strokes.map((s) => s.id).toSet();
      expect(ids, {'localOnly', 'remoteOnly'},
          reason: 'erased stroke gone, both devices\' other ink kept');
      expect(live.erased.map((e) => e.strokeId), contains('shared'),
          reason: 'tombstone retained so the erase propagates onward');
      // The same in-memory instance was updated — the open canvas repaints
      // it, and the next autosave persists the union instead of clobbering.
      expect(identical(live, page), isTrue);
    });

    test('a page tombstoned remotely is dropped from the open canvas', () {
      final pageA = CanvasPage(id: 'a', deviceId: 'devA');
      final pageB = CanvasPage(id: 'b', deviceId: 'devA');
      final canvas = Canvas(
        id: 'c-live2',
        notebookId: 'n1',
        sectionId: 's1',
        name: 'Live test 2',
        createdAt: DateTime(2026, 7, 7),
        rows: [
          PageRow(id: 'r1', pageIds: ['a']),
          PageRow(id: 'r2', pageIds: ['b']),
        ],
      );
      final controller =
          CanvasController(canvas: canvas, pages: {'a': pageA, 'b': pageB});

      final remoteTombstone = CanvasPage(
        id: 'b',
        deviceId: 'devB',
        rev: 5,
        deletedAt: DateTime.now(),
      );
      controller.applyRemotePage(remoteTombstone);

      expect(controller.pages.containsKey('b'), isFalse);
      expect(canvas.rows.length, 1);
      expect(canvas.rows.single.pageIds, ['a']);
    });
  });
}
