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

  group('CanvasController.adjustInkForContrast', () {
    test(
      'flips enabled ink lightness (keeps hue), skips highlighter when off, '
      'stamps mutated elements, and undo restores originals',
      () {
        final pen = StrokeElement(
          id: 'p',
          deviceId: 'test_device',
          z: '0|a0:',
          tool: StrokeTool.pen,
          color: const Color(0xFF000000),
          size: 3,
          points: [StrokePoint(0, 0, 0.5), StrokePoint(10, 10, 0.5)],
        );
        final hl = StrokeElement(
          id: 'h',
          deviceId: 'test_device',
          z: '0|a1:',
          tool: StrokeTool.highlighter,
          color: const Color(0xFFEAD24B),
          size: 8,
          points: [StrokePoint(0, 0, 0.5), StrokePoint(10, 10, 0.5)],
        );
        final txt = TextElement(
          id: 't',
          deviceId: 'test_device',
          rect: const Rect.fromLTWH(0, 0, 100, 20),
          color: const Color(0xFF000000),
          runs: [
            TextRun(
              text: 'hi',
              fontSize: 16,
              bold: false,
              italic: false,
              color: const Color(0xFF000000),
              fontFamily: 'sans',
            ),
          ],
        );
        final page = CanvasPage(id: 'a', deviceId: 'test_device');
        page.strokes.addAll([pen, hl]);
        page.objects.add(txt);
        final section = Canvas(
          id: 's3',
          notebookId: 'n1',
          sectionId: 's1',
          name: 'T3',
          createdAt: DateTime(2026, 7, 14),
          rows: [PageRow(id: 'r1', pageIds: ['a'])],
        );
        final controller =
            CanvasController(canvas: section, pages: {'a': page});

        final penRev0 = pen.rev;
        final hlRev0 = hl.rev;
        final txtRev0 = txt.rev;

        controller.adjustInkForContrast(
          {'a'},
          pen: true,
          highlighter: false,
          text: true,
        );

        StrokeElement s(String id) =>
            controller.pages['a']!.strokes.firstWhere((e) => e.id == id);
        TextElement t() =>
            controller.pages['a']!.objects.whereType<TextElement>().first;

        // Pen + text flip black → white; highlighter is left alone (off).
        expect(s('p').color.toARGB32(), 0xFFFFFFFF);
        expect(t().color.toARGB32(), 0xFFFFFFFF);
        expect(t().runs.first.color.toARGB32(), 0xFFFFFFFF);
        expect(s('h').color.toARGB32(), 0xFFEAD24B);

        // Mutated elements are stamped (rev bumped) for sync; highlighter isn't.
        expect(s('p').rev, greaterThan(penRev0));
        expect(t().rev, greaterThan(txtRev0));
        expect(s('h').rev, hlRev0);

        controller.undo();
        expect(s('p').color.toARGB32(), 0xFF000000);
        expect(t().color.toARGB32(), 0xFF000000);
        expect(t().runs.first.color.toARGB32(), 0xFF000000);
      },
    );
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

    int tombRev(CanvasPage p, String id) =>
        p.erased.where((e) => e.strokeId == id).map((e) => e.rev).fold(0,
            (m, r) => r > m ? r : m);

    test('deleteSelection tombstones strokes at the element rev; undo revives '
        'the SAME id with rev bumped ABOVE the tombstone (kept) — rev-based, '
        'so it survives a merge with a device that pulled the tombstone', () {
      controller.selection = [page.strokes.first];
      controller.selectionPageId = 'a';
      controller.deleteSelection();

      expect(page.strokes.map((s) => s.id), ['s2']);
      expect(page.erased.map((e) => e.strokeId), ['s1']);

      controller.undo();
      expect(page.strokes.map((s) => s.id), containsAll(['s1', 's2']),
          reason: 's1 comes back with the SAME id (undo chain stays intact)');
      expect(page.erased.map((e) => e.strokeId), ['s1'],
          reason: 'the tombstone stays (grow-only storage)');
      final s1 = page.strokes.firstWhere((s) => s.id == 's1');
      expect(s1.rev, greaterThan(tombRev(page, 's1')),
          reason: 'the revived stroke out-revs its tombstone → alive on merge');
    });

    test('the eraser TOOL tombstones on the first apply; undo/redo revive the '
        'same ids with a climbing rev', () {
      controller.setTool(CanvasTool.eraser);
      // Strokes run (0,0)→(10,10); a gesture at (5,5) hits them.
      controller.startToolGesture(const Offset(5, 5), 0.5);
      controller.endToolGesture();

      expect(page.strokes, isEmpty, reason: 'both strokes pass under (5,5)');
      expect(page.erased.map((e) => e.strokeId).toSet(), {'s1', 's2'},
          reason: 'the FIRST commit must write tombstones');

      controller.undo();
      expect(page.strokes.map((s) => s.id).toSet(), {'s1', 's2'},
          reason: 'revived under the SAME ids');
      expect(page.erased.map((e) => e.strokeId).toSet(), {'s1', 's2'},
          reason: 'tombstones kept');
      for (final s in page.strokes) {
        expect(s.rev, greaterThan(tombRev(page, s.id)),
            reason: 'each revived stroke out-revs its tombstone');
      }

      controller.redo();
      expect(page.strokes, isEmpty);
      expect(page.erased.map((e) => e.strokeId).toSet(), {'s1', 's2'},
          reason: 're-tombstoned at the bumped rev (deduped, not doubled)');
    });

    test('redo of an INSERT keeps the same id and out-revs its tombstone '
        '(undo tombstones it; redo never un-tombstones)', () {
      final fresh = CanvasPage(id: 'p', deviceId: 'test_device');
      final canvas = Canvas(
        id: 'c9',
        notebookId: 'n1',
        sectionId: 's1',
        name: 'Ins',
        createdAt: DateTime(2026, 7, 12),
        rows: [PageRow(id: 'r1', pageIds: ['p'])],
      );
      final c2 = CanvasController(canvas: canvas, pages: {'p': fresh});

      c2.addElement('p', _stroke('new1'));
      expect(fresh.strokes.map((s) => s.id), ['new1']);

      c2.undo();
      expect(fresh.strokes, isEmpty);
      expect(fresh.erased.map((e) => e.strokeId), ['new1'],
          reason: 'undo of an insert tombstones it');

      c2.redo();
      expect(fresh.strokes.single.id, 'new1', reason: 'SAME id on redo');
      expect(fresh.erased.map((e) => e.strokeId), ['new1'],
          reason: 'the tombstone stays — redo never un-tombstones');
      expect(fresh.strokes.single.rev,
          greaterThan(tombRev(fresh, 'new1')),
          reason: 'redo bumps the rev above the tombstone → alive');
    });

    test('undo CHAIN stays intact across a delete (Issue 2): insert X → '
        'delete X → undo → undo removes X cleanly, no orphan', () {
      final fresh = CanvasPage(id: 'p', deviceId: 'test_device');
      final canvas = Canvas(
        id: 'c10',
        notebookId: 'n1',
        sectionId: 's1',
        name: 'Chain',
        createdAt: DateTime(2026, 7, 12),
        rows: [PageRow(id: 'r1', pageIds: ['p'])],
      );
      final c2 = CanvasController(canvas: canvas, pages: {'p': fresh});

      c2.addElement('p', _stroke('X')); // op1: write
      c2.selection = [fresh.strokes.single];
      c2.selectionPageId = 'p';
      c2.deleteSelection(); // op2: delete
      expect(fresh.strokes, isEmpty);

      c2.undo(); // undo delete → X back, SAME id
      expect(fresh.strokes.map((s) => s.id), ['X']);

      c2.undo(); // undo write → must still find X (same id) and remove it
      expect(fresh.strokes, isEmpty,
          reason: 'the original write-undo targets id X — same-id revival '
              'keeps it findable, so no orphan is left behind');
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

  group('CanvasController hold-to-snap commit', () {
    CanvasController build() {
      final page = CanvasPage(id: 'p', deviceId: 'test_device');
      final canvas = Canvas(
        id: 'c',
        notebookId: 'n',
        sectionId: 's',
        name: 'C',
        createdAt: DateTime(2026, 7, 15),
        rows: [PageRow(id: 'r', pageIds: ['p'])],
      );
      return CanvasController(canvas: canvas, pages: {'p': page});
    }

    // A "snapped" stroke: its live points are the shape, with the original
    // freehand points kept aside for the undo-to-freehand op.
    List<StrokePoint> shapePts() =>
        [for (var i = 0; i < 6; i++) StrokePoint(i * 20.0, 40, 0.5)];
    List<StrokePoint> freehandPts() =>
        [StrokePoint(0, 40, 0.5), StrokePoint(101, 42, 0.5)];

    test('commits as two ops: undo #1 → freehand, undo #2 → gone', () {
      final c = build();
      final stroke = _stroke('sh', device: 'test_device')
        ..points = shapePts();
      c.debugCommitSnap('p', stroke, freehandPts());

      final page = c.pages['p']!;
      expect(page.strokes.length, 1);
      expect(page.strokes.single.points.length, 6); // shape

      c.undo(); // undo the swap → freehand ink
      expect(page.strokes.length, 1);
      expect(page.strokes.single.points.length, 2); // freehand

      c.undo(); // undo the add → gone (tombstoned)
      expect(page.strokes.where((e) => e.id == 'sh'), isEmpty);
    });

    test('redo re-applies freehand then shape', () {
      final c = build();
      final stroke = _stroke('sh', device: 'test_device')
        ..points = shapePts();
      c.debugCommitSnap('p', stroke, freehandPts());
      c.undo();
      c.undo();

      c.redo(); // re-add → freehand
      expect(c.pages['p']!.strokes.single.points.length, 2);
      c.redo(); // re-swap → shape
      expect(c.pages['p']!.strokes.single.points.length, 6);
    });

    test('rev climbs monotonically across the undo↔redo cycle (LWW-safe)', () {
      final c = build();
      final stroke = _stroke('sh', device: 'test_device')
        ..points = shapePts();
      c.debugCommitSnap('p', stroke, freehandPts());
      int rev() => c.pages['p']!.strokes.single.rev;

      final committed = rev();
      c.undo(); // swap→freehand stamps
      expect(rev(), greaterThan(committed));
      final afterUndo = rev();
      c.redo(); // freehand→shape stamps
      expect(rev(), greaterThan(afterUndo));
    });
  });

  group('CanvasController cross-page stroke', () {
    // Two A4 pages stacked vertically (row per page). Page 'a' spans canvas
    // y 0..842, page 'b' spans y 842..1684 (kPageGap == 0, so they're flush).
    CanvasController build() {
      final pageA = CanvasPage(id: 'a', deviceId: 'test_device');
      final pageB = CanvasPage(id: 'b', deviceId: 'test_device');
      final canvas = Canvas(
        id: 's1',
        notebookId: 'n1',
        sectionId: 's1',
        name: 'Test',
        createdAt: DateTime(2026, 7, 20),
        rows: [
          PageRow(id: 'r1', pageIds: ['a']),
          PageRow(id: 'r2', pageIds: ['b']),
        ],
      );
      // zoom 1 / pan 0 → screenToCanvas is the identity, so screen == canvas.
      return CanvasController(canvas: canvas, pages: {'a': pageA, 'b': pageB});
    }

    test('a stroke that stays on one page commits as a single stroke', () {
      final c = build()..setTool(CanvasTool.pen);
      c.startToolGesture(const Offset(100, 100), 0.5);
      c.updateToolGesture(const Offset(150, 200), 0.5);
      c.updateToolGesture(const Offset(200, 300), 0.5);
      c.endToolGesture();
      expect(c.pages['a']!.strokes.length, 1);
      expect(c.pages['b']!.strokes, isEmpty);
    });

    test(
        'a stroke crossing the page boundary splits into one stroke per page, '
        'each within its own bounds and meeting flush at the edge', () {
      final c = build()..setTool(CanvasTool.pen);
      c.startToolGesture(const Offset(100, 800), 0.5); // page a
      c.updateToolGesture(const Offset(100, 820), 0.5); // page a
      c.updateToolGesture(const Offset(100, 900), 0.5); // page b (y>842)
      c.updateToolGesture(const Offset(100, 950), 0.5); // page b
      c.endToolGesture();

      final a = c.pages['a']!.strokes;
      final b = c.pages['b']!.strokes;
      expect(a.length, 1, reason: 'origin-page half');
      expect(b.length, 1, reason: 'crossed-onto-page half');

      // Every point stays within its page's height (local space).
      for (final p in a.single.points) {
        expect(p.y, lessThanOrEqualTo(842 + 0.001));
      }
      for (final p in b.single.points) {
        expect(p.y, greaterThanOrEqualTo(-0.001));
      }
      // Flush join: page a ends at its bottom edge, page b starts at its top.
      expect(a.single.points.last.y, closeTo(842, 0.5));
      expect(b.single.points.first.y, closeTo(0, 0.5));
    });

    test('one undo removes both halves of a cross-page stroke', () {
      final c = build()..setTool(CanvasTool.pen);
      c.startToolGesture(const Offset(100, 800), 0.5);
      c.updateToolGesture(const Offset(100, 900), 0.5);
      c.updateToolGesture(const Offset(100, 950), 0.5);
      c.endToolGesture();
      expect(c.pages['a']!.strokes, isNotEmpty);
      expect(c.pages['b']!.strokes, isNotEmpty);

      c.undo();
      expect(c.pages['a']!.strokes, isEmpty);
      expect(c.pages['b']!.strokes, isEmpty);

      c.redo();
      expect(c.pages['a']!.strokes, isNotEmpty);
      expect(c.pages['b']!.strokes, isNotEmpty);
    });
  });
}
