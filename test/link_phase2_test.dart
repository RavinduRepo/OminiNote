import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:omininote/canvas/canvas_controller.dart';
import 'package:omininote/canvas/rich_text_controller.dart';
import 'package:omininote/models/canvas.dart';
import 'package:omininote/models/canvas_page.dart';
import 'package:omininote/models/element.dart';
import 'package:omininote/services/settings_service.dart';
import 'package:omininote/utils/url_text.dart';

TextRun _run(String text, {String? link}) => TextRun(
      text: text,
      fontSize: 16,
      bold: false,
      italic: false,
      color: const Color(0xFF000000),
      fontFamily: 'sans',
      link: link,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SettingsService().deviceId = 'test_device';

  group('linkifyRuns and internal links', () {
    test('preserves an internal omninote link run verbatim', () {
      const uri = 'omninote://link/n/nb1/s/s1/c/c1';
      final out = linkifyRuns([_run('My canvas', link: uri), _run(' ')]);
      expect(out.first.link, uri);
      expect(out.first.text, 'My canvas');
    });

    test('still auto-links URLs in other runs and stays idempotent', () {
      const uri = 'omninote://link/n/nb1';
      final once = linkifyRuns(
          [_run('Jump', link: uri), _run(' see https://x.com ok')]);
      expect(once.first.link, uri);
      expect(once.any((r) => r.link == 'https://x.com'), isTrue);
      final twice = linkifyRuns([for (final r in once) r.clone()]);
      expect(twice.length, once.length);
      for (var i = 0; i < once.length; i++) {
        expect(twice[i].text, once[i].text);
        expect(twice[i].link, once[i].link);
      }
    });

    test('editing round-trip keeps the link (attrs -> runs)', () {
      const uri = 'omninote://link/n/nb1/s/s1';
      final el = TextElement(
        id: 'el1',
        deviceId: 'test_device',
        rect: const Rect.fromLTWH(0, 0, 100, 20),
        runs: [_run('Section link', link: uri), _run(' tail')],
        color: const Color(0xFF000000),
      );
      final rc = RichTextController(
        text: el.text,
        attrs: attrsFromElement(el),
        defaults: defaultAttrOf(el),
      );
      final back = runsFromController(rc);
      expect(back.length, 2);
      expect(back[0].text, 'Section link');
      expect(back[0].link, uri);
      expect(back[1].link, isNull);
    });
  });

  group('CanvasController link items + landing flash', () {
    CanvasController build() {
      final page = CanvasPage(id: 'p1', deviceId: 'test_device');
      final canvas = Canvas(
        id: 'c1',
        notebookId: 'n1',
        sectionId: 's1',
        name: 'Host',
        createdAt: DateTime(2026, 7, 19),
        rows: [
          PageRow(id: 'r1', pageIds: ['p1'])
        ],
      );
      return CanvasController(canvas: canvas, pages: {'p1': page});
    }

    test('insertLinkItem creates a tappable link box; undo removes it', () {
      final c = build();
      const uri = 'omninote://link/n/nb2/s/s2/c/c2';
      final el = c.insertLinkItem('p1', uri, 'Other canvas')!;
      expect(c.pages['p1']!.objects, contains(el));
      expect(el.runs.first.link, uri);
      expect(el.runs.first.text, 'Other canvas');
      // Trailing non-link space keeps the box grabbable/editable.
      expect(el.runs.last.link, isNull);
      // The box lies on the page.
      final page = c.pages['p1']!;
      expect(el.rect.bottom <= page.height, isTrue);
      expect(el.rect.top >= 0, isTrue);

      c.undo();
      expect(c.pages['p1']!.objects, isNot(contains(el)));
      c.redo();
      expect(c.pages['p1']!.objects.any((e) => e.id == el.id), isTrue);
    });

    test('focusElements flashes existing elements, plain-jumps unknown ids',
        () {
      final c = build();
      final el = c.insertLinkItem('p1', 'omninote://link/n/nb2', 'x')!;
      c.focusElements('p1', [el.id]);
      expect(c.linkFlashNotifier.value, isNotNull);
      expect(c.linkFlashNotifier.value!.pageId, 'p1');
      expect(c.linkFlashNotifier.value!.ids, {el.id});

      c.linkFlashNotifier.value = null;
      c.focusElements('p1', ['nope']);
      expect(c.linkFlashNotifier.value, isNull); // fell back to page jump
    });
  });
}
