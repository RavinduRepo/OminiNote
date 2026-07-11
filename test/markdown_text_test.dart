import 'dart:ui';
import 'package:flutter_test/flutter_test.dart';
import 'package:omininote/models/element.dart';
import 'package:omininote/utils/markdown_text.dart';

final _base = TextRun(
  text: '',
  fontSize: 16,
  bold: false,
  italic: false,
  color: const Color(0xFF000000),
  fontFamily: 'sans',
);

String _joined(List<TextRun> runs) => runs.map((r) => r.text).join();

void main() {
  group('looksLikeMarkdown — strict detection', () {
    test('strong signals convert alone', () {
      expect(looksLikeMarkdown('# Title\nbody'), isTrue);
      expect(looksLikeMarkdown('```\ncode\n```'), isTrue);
      expect(looksLikeMarkdown('- [ ] buy milk'), isTrue);
      expect(looksLikeMarkdown('see [docs](https://x.dev) for more'), isTrue);
      expect(looksLikeMarkdown('this is **important** stuff'), isTrue);
      expect(looksLikeMarkdown('- one\n- two'), isTrue);
      expect(looksLikeMarkdown('1. first\n2. second'), isTrue);
    });

    test('ordinary prose never matches', () {
      expect(looksLikeMarkdown('Just a normal sentence.'), isFalse);
      expect(looksLikeMarkdown('math like 2*3*4 and 5*6'), isFalse);
      expect(looksLikeMarkdown('a single - dash note'), isFalse);
      expect(looksLikeMarkdown('- one lonely list line'), isFalse);
      expect(looksLikeMarkdown('C:\\path\\to\\file and #hashtag'), isFalse);
    });

    test('two distinct weak signals convert', () {
      expect(looksLikeMarkdown('- item\n> quoted line'), isTrue);
      expect(looksLikeMarkdown('run `flutter test` first\n1. then push'),
          isTrue);
    });
  });

  group('runsFromMarkdown', () {
    test('headings scale and bold like the HTML converter', () {
      final runs = runsFromMarkdown('# Big\n## Mid\n### Small\nplain', _base);
      final big = runs.firstWhere((r) => r.text.contains('Big'));
      final mid = runs.firstWhere((r) => r.text.contains('Mid'));
      final small = runs.firstWhere((r) => r.text.contains('Small'));
      final plain = runs.firstWhere((r) => r.text.contains('plain'));
      expect(big.fontSize, 32);
      expect(big.bold, isTrue);
      expect(mid.fontSize, 24);
      expect(small.fontSize, closeTo(18.7, 0.1));
      expect(plain.fontSize, 16);
      expect(plain.bold, isFalse);
    });

    test('inline bold/italic/nesting; markers are consumed', () {
      final runs =
          runsFromMarkdown('a **bold** and *ital* and **both *in***', _base);
      expect(_joined(runs), 'a bold and ital and both in');
      expect(runs.firstWhere((r) => r.text == 'bold').bold, isTrue);
      expect(runs.firstWhere((r) => r.text == 'ital').italic, isTrue);
      final both = runs.firstWhere((r) => r.text == 'in');
      expect(both.bold, isTrue);
      expect(both.italic, isTrue);
    });

    test('unmatched markers pass through literally', () {
      final runs = runsFromMarkdown('- a\n- 2 ** 3 is *not closed', _base);
      expect(_joined(runs), '• a\n• 2 ** 3 is *not closed');
    });

    test('inline code and fenced blocks become mono runs', () {
      final runs = runsFromMarkdown(
          'run `flutter test`\n```\nvoid main() {}\n```\ndone', _base);
      expect(runs.firstWhere((r) => r.text == 'flutter test').fontFamily,
          'mono');
      expect(runs.firstWhere((r) => r.text.contains('void main')).fontFamily,
          'mono');
      expect(runs.firstWhere((r) => r.text.contains('done')).fontFamily,
          'sans');
    });

    test('lists: bullets, numbers, tasks → the app\'s glyph prefixes '
        '(tasks make the same tappable ☐/☑)', () {
      final runs = runsFromMarkdown(
          '- milk\n  - nested\n1. first\n- [ ] todo\n- [x] done', _base);
      final text = _joined(runs);
      expect(text, '• milk\n  • nested\n1. first\n☐ todo\n☑ done');
    });

    test('links become TextRun.link with the label as text', () {
      final runs = runsFromMarkdown('see [the docs](https://x.dev/a)', _base);
      final link = runs.firstWhere((r) => r.link != null);
      expect(link.text, 'the docs');
      expect(link.link, 'https://x.dev/a');
    });

    test('blockquote gets a │ prefix and italics', () {
      final runs = runsFromMarkdown('> wise words', _base);
      expect(_joined(runs), '│ wise words');
      expect(runs.firstWhere((r) => r.text == 'wise words').italic, isTrue);
    });

    test('escapes yield literal characters', () {
      final runs = runsFromMarkdown(r'- not \*bold\* here', _base);
      expect(_joined(runs), '• not *bold* here');
    });

    test('blank-line runs collapse; trailing newlines trimmed; empty input '
        'yields no runs', () {
      final runs = runsFromMarkdown('# A\n\n\n\nB\n\n', _base);
      expect(_joined(runs), 'A\n\nB');
      expect(runsFromMarkdown('   \n\n  ', _base), isEmpty);
    });

    test('horizontal rule renders as a divider line', () {
      final runs = runsFromMarkdown('above\n---\nbelow', _base);
      expect(_joined(runs), 'above\n──────────\nbelow');
    });

    test('tables degrade to column-padded mono rows (aligned), separator '
        'rows dropped, and 2+ rows trigger detection', () {
      const md = '| name | qty |\n|------|-----|\n| milk | 2 |\n| tea | 12 |';
      expect(looksLikeMarkdown(md), isTrue);
      final runs = runsFromMarkdown(md, _base);
      expect(_joined(runs), 'name  qty\nmilk  2\ntea   12');
      expect(runs.first.fontFamily, 'mono',
          reason: 'padding only aligns in a fixed-width font');
    });

    test('"[]" with no inner space still makes an unchecked box', () {
      final runs = runsFromMarkdown('- [] quick note\n- [x] done', _base);
      expect(_joined(runs), '☐ quick note\n☑ done');
    });
  });
}
