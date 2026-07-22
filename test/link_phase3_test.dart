import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omininote/canvas/canvas_controller.dart';
import 'package:omininote/canvas/rich_text_controller.dart';
import 'package:omininote/canvas/text_measure.dart';
import 'package:omininote/models/canvas.dart';
import 'package:omininote/models/canvas_page.dart';
import 'package:omininote/models/element.dart';
import 'package:omininote/models/link.dart';
import 'package:omininote/services/settings_service.dart';

TextRun _run(String text, {String? link, double size = 16, bool bold = false}) =>
    TextRun(
      text: text,
      fontSize: size,
      bold: bold,
      italic: false,
      color: const Color(0xFF000000),
      fontFamily: 'sans',
      link: link,
    );

TextElement _el(List<TextRun> runs) => TextElement(
      id: 'el1',
      deviceId: 'test_device',
      rect: const Rect.fromLTWH(10, 10, 200, 40),
      runs: runs,
      color: const Color(0xFF000000),
    );

CanvasController _controller(TextElement el) {
  final page = CanvasPage(id: 'p1', deviceId: 'test_device');
  page.objects.add(el);
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SettingsService().deviceId = 'test_device';

  group('replaceRunRange', () {
    test('splices inside one run, keeping both sides\' style', () {
      final out = replaceRunRange(
        [_run('hello [[', bold: true)],
        6,
        8,
        [_run('LINK', link: 'omninote://link/n/nb')],
      );
      expect(out.map((r) => r.text).join(), 'hello LINK');
      expect(out.first.bold, isTrue);
      expect(out.last.link, 'omninote://link/n/nb');
    });

    test('splices across run boundaries losslessly', () {
      final out = replaceRunRange(
        [_run('ab'), _run('cd', bold: true), _run('ef')],
        1,
        5,
        [_run('X')],
      );
      expect(out.map((r) => r.text).join(), 'aXf');
      expect(out.first.text, 'a');
      expect(out.last.text, 'f');
      expect(out.last.bold, isFalse);
    });

    test('replacing at the very end appends', () {
      final out = replaceRunRange([_run('ab[[')], 2, 4, [_run('L')]);
      expect(out.map((r) => r.text).join(), 'abL');
    });
  });

  group('CanvasController.insertLinkIntoText ([[ trigger landing)', () {
    test('replaces the [[ marker with a styled link run + space; undoable',
        () {
      final el = _el([_run('see [[')]);
      final c = _controller(el);
      c.insertLinkIntoText(
          'p1', 'el1', 6, 'My canvas', 'omninote://link/n/nb/s/s/c/cv');
      final now =
          c.pages['p1']!.objects.whereType<TextElement>().first;
      expect(now.text, 'see My canvas ');
      final linkRun = now.runs.firstWhere((r) => r.link != null);
      expect(linkRun.text, 'My canvas');
      expect(linkRun.link, 'omninote://link/n/nb/s/s/c/cv');

      c.undo();
      expect(
        c.pages['p1']!.objects.whereType<TextElement>().first.text,
        'see [[',
      );
    });

    test('no-op when the marker is not there', () {
      final el = _el([_run('see []')]);
      final c = _controller(el);
      c.insertLinkIntoText('p1', 'el1', 6, 'x', 'omninote://link/n/nb');
      expect(c.pages['p1']!.objects.whereType<TextElement>().first.text,
          'see []');
    });
  });

  group('CanvasController.editLinkRun (pencil edit)', () {
    test('changes text + destination as one undoable op', () {
      final el = _el([_run('Old', link: 'omninote://link/n/a'), _run(' ')]);
      final c = _controller(el);
      c.editLinkRun('p1', 'el1', 0,
          newText: 'New', newLink: 'omninote://link/n/b');
      final now = c.pages['p1']!.objects.whereType<TextElement>().first;
      expect(now.runs.first.text, 'New');
      expect(now.runs.first.link, 'omninote://link/n/b');
      c.undo();
      final back = c.pages['p1']!.objects.whereType<TextElement>().first;
      expect(back.runs.first.text, 'Old');
      expect(back.runs.first.link, 'omninote://link/n/a');
    });

    test('null newLink removes the link but keeps the text', () {
      final el = _el([_run('Kept', link: 'omninote://link/n/a'), _run(' ')]);
      final c = _controller(el);
      c.editLinkRun('p1', 'el1', 0, newText: 'Kept', newLink: null);
      final now = c.pages['p1']!.objects.whereType<TextElement>().first;
      expect(now.runs.first.link, isNull);
      expect(now.runs.first.text, 'Kept');
    });
  });

  group('linkPencilSpots', () {
    test('one spot per link run, anchored past the run\'s laid-out end', () {
      final el = _el([
        _run('go ', size: 20),
        _run('here', link: 'omninote://link/n/nb', size: 20),
        _run(' and https://x.com', link: null, size: 20),
      ]);
      final spots = linkPencilSpots(el);
      expect(spots.length, 1);
      expect(spots.single.runIndex, 1);
      expect(spots.single.link, 'omninote://link/n/nb');
      // Page-local: to the right of the element's left edge, within its band.
      expect(spots.single.rect.left > el.rect.left, isTrue);
      expect(spots.single.rect.top >= el.rect.top - 5, isTrue);
    });

    test('no spots for link-free elements', () {
      expect(linkPencilSpots(_el([_run('plain')])), isEmpty);
    });
  });

  group('external link endpoints (unified Connections list)', () {
    test('sideFrom detects internal URIs, external URLs, and garbage', () {
      final internal = LinkEndpoint.sideFrom('omninote://link/n/nb/s/s1');
      expect(internal, isNotNull);
      expect(internal!.kind, LinkTargetKind.section);

      final ext = LinkEndpoint.sideFrom('https://example.com/a?b=1');
      expect(ext, isNotNull);
      expect(ext!.kind, LinkTargetKind.external);
      expect(ext.externalUrl, 'https://example.com/a?b=1');
      expect(ext.toUri(), 'https://example.com/a?b=1'); // raw URL round-trip
      expect(ext.leafId, 'https://example.com/a?b=1');

      expect(LinkEndpoint.sideFrom('just some words'), isNull);
    });

    test('sameAs separates external from internal and URL from URL', () {
      const a = LinkEndpoint.external('https://a.com');
      const b = LinkEndpoint.external('https://b.com');
      const c = LinkEndpoint(notebookId: 'nb');
      expect(a.sameAs(const LinkEndpoint.external('https://a.com')), isTrue);
      expect(a.sameAs(b), isFalse);
      expect(a.sameAs(c), isFalse);
      expect(c.sameAs(a), isFalse);
    });

    test('a record with an external side survives its JSON round-trip', () {
      final rec = LinkRecord(
        id: 'l1',
        deviceId: 'test_device',
        a: const LinkEndpoint(
            notebookId: 'nb', sectionId: 's1', canvasId: 'c1'),
        b: const LinkEndpoint.external('https://docs.flutter.dev'),
        bName: 'Flutter docs',
      );
      final back = LinkRecord.tryFromJson(rec.toJson())!;
      expect(back.b.kind, LinkTargetKind.external);
      expect(back.b.externalUrl, 'https://docs.flutter.dev');
      expect(back.a.sameAs(rec.a), isTrue);
    });
  });

  group('RichTextController.insertLinkText (in-editor paste)', () {
    test('inserts linked title + plain trailing space at the caret', () {
      final el = _el([_run('ab')]);
      final rc = RichTextController(
        text: el.text,
        attrs: attrsFromElement(el),
        defaults: defaultAttrOf(el),
      );
      rc.selection = const TextSelection.collapsed(offset: 2);
      rc.insertLinkText('Target', 'omninote://link/n/nb');
      expect(rc.text, 'abTarget ');
      final runs = runsFromController(rc);
      final linkRun = runs.firstWhere((r) => r.link != null);
      expect(linkRun.text, 'Target');
      expect(runs.last.link, isNull); // trailing space is plain
    });
  });

  group('setLinkOnRuns (link a selected span)', () {
    test('links the middle range, keeping surrounding text plain', () {
      final out = setLinkOnRuns([_run('one two three')], 4, 7,
          'omninote://link/n/nb/s/s/c/cv');
      expect(out.map((r) => r.text).join(), 'one two three');
      final linked = out.where((r) => r.link != null).toList();
      expect(linked.length, 1);
      expect(linked.single.text, 'two');
      expect(out.first.link, isNull);
      expect(out.last.link, isNull);
    });

    test('preserves per-run styles across the boundary', () {
      final out = setLinkOnRuns(
          [_run('ab', bold: true), _run('cd')], 1, 3, 'x://y');
      // 'a'(bold) | 'b'(bold,link) | 'c'(link) | 'd'
      expect(out.map((r) => r.text).join(), 'abcd');
      expect(out[0].text, 'a');
      expect(out[0].bold, isTrue);
      expect(out[0].link, isNull);
      final linked = out.where((r) => r.link == 'x://y').toList();
      expect(linked.map((r) => r.text).join(), 'bc');
      expect(linked.first.bold, isTrue); // 'b' kept its bold
    });

    test('empty range is a no-op', () {
      final input = [_run('hello')];
      expect(identical(setLinkOnRuns(input, 3, 3, 'x'), input), isTrue);
    });
  });

  group('CanvasController link on selection / at caret', () {
    test('applyLinkToRange hyperlinks the selected text, keeping it', () {
      final el = _el([_run('buy milk today')]);
      final c = _controller(el);
      c.applyLinkToRange('p1', 'el1', 4, 8, 'omninote://link/n/nb/s/s/c/cv');
      final now = c.pages['p1']!.objects.whereType<TextElement>().first;
      expect(now.text, 'buy milk today'); // text unchanged
      final linkRun = now.runs.firstWhere((r) => r.link != null);
      expect(linkRun.text, 'milk');
      expect(linkRun.link, 'omninote://link/n/nb/s/s/c/cv');
      c.undo();
      final reverted = c.pages['p1']!.objects.whereType<TextElement>().first;
      expect(reverted.runs.every((r) => r.link == null), isTrue);
    });

    test('insertLinkAtCaret inserts a link + space at the caret', () {
      final el = _el([_run('see ')]);
      final c = _controller(el);
      c.insertLinkAtCaret(
          'p1', 'el1', 4, 'My canvas', 'omninote://link/n/nb/s/s/c/cv');
      final now = c.pages['p1']!.objects.whereType<TextElement>().first;
      expect(now.text, 'see My canvas ');
      final linkRun = now.runs.firstWhere((r) => r.link != null);
      expect(linkRun.text, 'My canvas');
      c.undo();
      expect(c.pages['p1']!.objects.whereType<TextElement>().first.text, 'see ');
    });
  });
}
