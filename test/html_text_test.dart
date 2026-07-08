import 'dart:ui' show Color;
import 'package:flutter_test/flutter_test.dart';
import 'package:omininote/models/element.dart';
import 'package:omininote/utils/html_text.dart';

TextRun base({
  double size = 16,
  Color color = const Color(0xFF17171A),
  String family = 'sans',
}) => TextRun(
  text: '',
  fontSize: size,
  bold: false,
  italic: false,
  color: color,
  fontFamily: family,
);

String plain(List<TextRun> runs) => runs.map((r) => r.text).join();

void main() {
  group('runsFromHtml — inline styles', () {
    test('plain text becomes one base-styled run', () {
      final runs = runsFromHtml('hello world', base());
      expect(runs, hasLength(1));
      expect(runs.single.text, 'hello world');
      expect(runs.single.bold, isFalse);
      expect(runs.single.fontSize, 16);
    });

    test('b/strong and i/em split into styled runs', () {
      final runs = runsFromHtml('a <b>bold</b> and <em>italic</em>', base());
      expect(plain(runs), 'a bold and italic');
      expect(runs.map((r) => r.bold).toList(), [false, true, false, false]);
      expect(runs.map((r) => r.italic).toList(), [false, false, false, true]);
    });

    test('nested styles combine (bold inside italic)', () {
      final runs = runsFromHtml('<i>it <b>both</b></i>', base());
      expect(plain(runs), 'it both');
      final bothRun = runs.firstWhere((r) => r.text == 'both');
      expect(bothRun.bold, isTrue);
      expect(bothRun.italic, isTrue);
    });

    test('span style color/font-size/font-weight are honored', () {
      final runs = runsFromHtml(
        '<span style="color:#ff0000;font-size:24px;font-weight:700">red</span>',
        base(),
      );
      expect(runs.single.color, const Color(0xFFFF0000));
      expect(runs.single.fontSize, 24);
      expect(runs.single.bold, isTrue);
    });

    test('rgb() colors, short hex, and named colors parse', () {
      expect(
        runsFromHtml(
          '<span style="color:rgb(0, 128, 0)">x</span>',
          base(),
        ).single.color,
        const Color(0xFF008000),
      );
      expect(
        runsFromHtml('<span style="color:#f00">x</span>', base()).single.color,
        const Color(0xFFFF0000),
      );
      expect(
        runsFromHtml('<font color="navy">x</font>', base()).single.color,
        const Color(0xFF000080),
      );
    });

    test('pt and em font sizes convert to px-equivalent units', () {
      // 12pt = 16px.
      expect(
        runsFromHtml(
          '<span style="font-size:12pt">x</span>',
          base(),
        ).single.fontSize,
        closeTo(16, 0.01),
      );
      // 2em of a 16 base = 32.
      expect(
        runsFromHtml(
          '<span style="font-size:2em">x</span>',
          base(),
        ).single.fontSize,
        closeTo(32, 0.01),
      );
    });

    test('monospace/serif font families map to the app keys', () {
      expect(runsFromHtml('<code>x</code>', base()).single.fontFamily, 'mono');
      expect(
        runsFromHtml(
          '<span style="font-family:Georgia, serif">x</span>',
          base(),
        ).single.fontFamily,
        'serif',
      );
    });

    test('HTML entities decode', () {
      expect(plain(runsFromHtml('a &amp; b &lt;c&gt;', base())), 'a & b <c>');
    });
  });

  group('runsFromHtml — structure', () {
    test('headings get scaled bold text', () {
      final runs = runsFromHtml('<h1>Title</h1><p>body</p>', base());
      expect(plain(runs), 'Title\nbody');
      final title = runs.firstWhere((r) => r.text.startsWith('Title'));
      expect(title.bold, isTrue);
      expect(title.fontSize, 32); // 2× the 16 base
    });

    test('paragraphs and <br> become newlines (no doubling)', () {
      final runs = runsFromHtml('<p>one</p><p>two<br>three</p>', base());
      expect(plain(runs), 'one\ntwo\nthree');
    });

    test('unordered and ordered lists render glyph/number prefixes', () {
      expect(
        plain(runsFromHtml('<ul><li>a</li><li>b</li></ul>', base())),
        '• a\n• b',
      );
      expect(
        plain(runsFromHtml('<ol><li>a</li><li>b</li></ol>', base())),
        '1. a\n2. b',
      );
    });

    test('nested lists indent', () {
      final text = plain(
        runsFromHtml(
          '<ul><li>a<ul><li>a1</li></ul></li><li>b</li></ul>',
          base(),
        ),
      );
      expect(text, '• a\n  • a1\n• b');
    });

    test('whitespace collapses like a browser', () {
      final runs = runsFromHtml(
        '<p>  spaced\n   out  </p> \n <p>next</p>',
        base(),
      );
      expect(plain(runs), 'spaced out\nnext');
    });

    test('script/style/img content is dropped', () {
      final runs = runsFromHtml(
        'a<script>evil()</script><style>p{}</style><img src="x">b',
        base(),
      );
      expect(plain(runs), 'ab');
    });

    test('table cells degrade to spaced text per row', () {
      final runs = runsFromHtml(
        '<table><tr><td>a</td><td>b</td></tr><tr><td>c</td></tr></table>',
        base(),
      );
      expect(plain(runs), 'a  b\nc');
    });

    test('adjacent same-style runs merge; empty html gives no runs', () {
      final runs = runsFromHtml('<span>a</span><span>b</span>', base());
      expect(runs, hasLength(1));
      expect(runs.single.text, 'ab');

      expect(runsFromHtml('  <p>  </p> ', base()), isEmpty);
      expect(runsFromHtml('', base()), isEmpty);
    });
  });

  group('htmlFromRuns (copy-out)', () {
    test(
      'serializes styles and escapes text; round-trips through the parser',
      () {
        final runs = [
          TextRun(
            text: 'bold & <big>',
            fontSize: 20,
            bold: true,
            italic: false,
            color: const Color(0xFFFF0000),
            fontFamily: 'sans',
          ),
          TextRun(
            text: '\nplain',
            fontSize: 16,
            bold: false,
            italic: true,
            color: const Color(0xFF17171A),
            fontFamily: 'mono',
          ),
        ];
        final html = htmlFromRuns(runs);
        expect(html, contains('font-weight:bold'));
        expect(html, contains('color:#ff0000'));
        expect(html, contains('&amp;'));
        expect(html, contains('<br>'));

        // Feeding our own HTML back through the parser reproduces the styles.
        final back = runsFromHtml(html, base());
        expect(plain(back), 'bold & <big>\nplain');
        expect(back.first.bold, isTrue);
        expect(back.first.fontSize, 20);
        expect(back.first.color, const Color(0xFFFF0000));
        final mono = back.firstWhere((r) => r.text.contains('plain'));
        expect(mono.italic, isTrue);
        expect(mono.fontFamily, 'mono');
      },
    );
  });
}
