import 'package:flutter/material.dart' hide Canvas;
import 'package:flutter_test/flutter_test.dart';
import 'package:omininote/canvas/canvas_controller.dart';
import 'package:omininote/canvas/rich_text_controller.dart';
import 'package:omininote/models/canvas.dart';
import 'package:omininote/models/canvas_page.dart';
import 'package:omininote/models/element.dart';
import 'package:omininote/services/settings_service.dart';
import 'package:omininote/utils/html_text.dart';

// Reproduces the reported "select a portion of a pasted rich text box and
// apply a color/style — nothing happens" flow at the controller level, using
// a real TextField so focus/selection mechanics are the genuine ones.
void main() {
  SettingsService().deviceId = 'test_device';

  TextRun base() => TextRun(
    text: '',
    fontSize: 16,
    bold: false,
    italic: false,
    color: const Color(0xFF17171A),
    fontFamily: 'sans',
  );

  (CanvasController, TextElement, RichTextController) startEdit() {
    // A pasted-like element: mixed styles from real clipboard HTML.
    final el = TextElement(
      id: 'el1',
      deviceId: 'test_device',
      rect: const Rect.fromLTWH(20, 20, 300, 100),
      runs: runsFromHtml('<h2>Head</h2><p>plain <b>bold</b> tail</p>', base()),
      color: const Color(0xFF17171A),
    );
    final page = CanvasPage(id: 'p1', deviceId: 'test_device', objects: [el]);
    final canvas = Canvas(
      id: 'c1',
      notebookId: 'n1',
      sectionId: 's1',
      name: 'T',
      createdAt: DateTime(2026, 7, 8),
      rows: [
        PageRow(id: 'r1', pageIds: ['p1']),
      ],
    );
    final c = CanvasController(canvas: canvas, pages: {'p1': page});
    final rc = RichTextController(
      text: el.text,
      attrs: attrsFromElement(el),
      defaults: defaultAttrOf(el),
    );
    c.setEditing(el, rc);
    return (c, el, rc);
  }

  testWidgets('select a range inside a pasted rich box, apply color + bold — '
      'only that range changes and the selection survives', (tester) async {
    final (c, el, rc) = startEdit();
    addTearDown(rc.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TextField(controller: rc, maxLines: null, autofocus: true),
        ),
      ),
    );
    await tester.pump();

    // "Head\nplain bold tail" — select "plain" (offsets 5..10).
    final text = el.text;
    expect(text, 'Head\nplain bold tail');
    rc.selection = const TextSelection(baseOffset: 5, extentOffset: 10);
    await tester.pump();

    const red = Color(0xFFFF0000);
    c.setTextColor(red);
    c.toggleTextBold();
    await tester.pump();

    // Selection must survive the style application.
    expect(rc.selection.start, 5);
    expect(rc.selection.end, 10);

    // Exactly chars 5..9 are red+bold now.
    for (var i = 0; i < text.length; i++) {
      final inRange = i >= 5 && i < 10;
      expect(
        rc.attrs[i].color == red,
        inRange,
        reason: 'char $i ("${text[i]}") color',
      );
    }

    // Committing collapses back to runs that keep the change.
    final runs = runsFromController(rc);
    final styled = runs.firstWhere((r) => r.text.contains('plain'));
    expect(styled.color, red);
    expect(styled.bold, isTrue);
  });

  testWidgets(
    'toolbar sync on selection change reports the first selected char style',
    (tester) async {
      final (c, el, rc) = startEdit();
      addTearDown(rc.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TextField(controller: rc, maxLines: null, autofocus: true),
          ),
        ),
      );
      await tester.pump();

      // Select inside the heading (bold, 24pt from h2 = 1.5×16).
      rc.selection = const TextSelection(baseOffset: 0, extentOffset: 4);
      final attr = rc.styleForToolbar();
      expect(attr.bold, isTrue);
      expect(attr.fontSize, 24);
      expect(el.id, isNotEmpty);
      expect(c.isEditingText, isTrue);
    },
  );
}
