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
      expect(controller.tool, CanvasTool.pen);
      expect(controller.toolOptionsOpen, isFalse);

      controller.setTool(CanvasTool.highlighter);

      expect(controller.tool, CanvasTool.highlighter);
      expect(controller.toolOptionsOpen, isFalse);
    });

    test('tapping the already-active tool toggles options open, then closed', () {
      controller.setTool(CanvasTool.pen); // already the default tool
      expect(controller.tool, CanvasTool.pen);
      expect(controller.toolOptionsOpen, isTrue);

      controller.setTool(CanvasTool.pen); // tap again
      expect(controller.toolOptionsOpen, isFalse);
    });

    test('switching to a different tool while options are open closes them', () {
      controller.setTool(CanvasTool.pen); // opens options
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
