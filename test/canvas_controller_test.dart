import 'dart:ui';
import 'package:flutter_test/flutter_test.dart';
import 'package:omininote/canvas/canvas_controller.dart';
import 'package:omininote/models/canvas_page.dart';
import 'package:omininote/models/canvas.dart';

void main() {
  group('CanvasController.setPageBackground', () {
    test(
      'ticking "apply to all pages" changes every existing page and the '
      'section default; undo restores each page to its own prior background',
      () {
        final pageA = CanvasPage(
          id: 'a',
          background: const PageBackground(
            color: Color(0xFFFFFFFF),
            pattern: BgPattern.blank,
          ),
        );
        final pageB = CanvasPage(
          id: 'b',
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
      final pageA = CanvasPage(id: 'a');
      final pageB = CanvasPage(id: 'b');
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
      final page = CanvasPage(id: 'a');
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
}
