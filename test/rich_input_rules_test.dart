import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omininote/canvas/rich_text_controller.dart';

CharAttr _base() => CharAttr(
      fontSize: 16,
      bold: false,
      italic: false,
      color: const Color(0xFF000000),
      family: 'sans',
    );

RichTextController _rc() =>
    RichTextController(text: '', attrs: [], defaults: _base())
      ..selection = const TextSelection.collapsed(offset: 0);

/// Simulates typing character by character (each keystroke is one value set,
/// like a real TextField).
void _type(RichTextController rc, String s) {
  for (final ch in s.split('')) {
    final caret = rc.selection.baseOffset;
    rc.value = TextEditingValue(
      text: rc.text.substring(0, caret) + ch + rc.text.substring(caret),
      selection: TextSelection.collapsed(offset: caret + 1),
    );
  }
}

void _backspace(RichTextController rc) {
  final caret = rc.selection.baseOffset;
  if (caret == 0) return;
  rc.value = TextEditingValue(
    text: rc.text.substring(0, caret - 1) + rc.text.substring(caret),
    selection: TextSelection.collapsed(offset: caret - 1),
  );
}

void main() {
  group('line-start rules', () {
    test('# / ## / ### become sized+bold typing styles, marker consumed', () {
      for (final (marker, size) in [('# ', 32.0), ('## ', 24.0)]) {
        final rc = _rc();
        _type(rc, '${marker}Hi');
        expect(rc.text, 'Hi', reason: 'marker consumed for "$marker"');
        final runs = runsFromController(rc);
        expect(runs.single.fontSize, size);
        expect(runs.single.bold, isTrue);
      }
    });

    test('Enter after a heading line resets typing to the base size', () {
      final rc = _rc();
      _type(rc, '# Head\nbody');
      final runs = runsFromController(rc);
      expect(runs.first.fontSize, 32);
      final body = runs.firstWhere((r) => r.text.contains('body'));
      expect(body.fontSize, 16);
      expect(body.bold, isFalse);
    });

    test('"# " before existing text converts the whole line', () {
      final rc = _rc();
      _type(rc, 'Title here');
      rc.selection = const TextSelection.collapsed(offset: 0);
      _type(rc, '# ');
      expect(rc.text, 'Title here');
      expect(runsFromController(rc).first.fontSize, 32);
    });

    test('"- " and "* " become bullets; "[ ] "/"[x] " become checkboxes; '
        '"- [ ] " chains into a checkbox', () {
      final rc1 = _rc();
      _type(rc1, '- milk');
      expect(rc1.text, '• milk');

      final rc2 = _rc();
      _type(rc2, '[ ] todo\n');
      // Enter auto-continued the list with a "☐ " — typing "[x] " on that
      // line flips the glyph rather than nesting a second marker.
      _type(rc2, '[x] done');
      expect(rc2.text, '☐ todo\n☑ done');

      final rc3 = _rc();
      _type(rc3, '- [ ] both');
      expect(rc3.text, '☐ both');
    });

    test('"> " becomes a quote bar with italic typing', () {
      final rc = _rc();
      _type(rc, '> wise');
      expect(rc.text, '│ wise');
      expect(runsFromController(rc).last.italic, isTrue);
    });
  });

  group('inline pair rules', () {
    test('**bold** completes: markers gone, content bold, typing continues '
        'unbolded', () {
      final rc = _rc();
      _type(rc, 'a **hi** b');
      expect(rc.text, 'a hi b');
      final runs = runsFromController(rc);
      expect(runs.firstWhere((r) => r.text == 'hi').bold, isTrue);
      expect(runs.last.bold, isFalse);
    });

    test('inline rules suppress one style adoption so the editor does not '
        're-adopt the styled content as the typing style (found live: '
        'bold/italic/code never reset after the pair closed)', () {
      final rc = _rc();
      _type(rc, '**hi**');
      expect(rc.consumeSuppressStyleAdopt(), isTrue,
          reason: 'the edit session must skip adopting the bold char style');
      expect(rc.consumeSuppressStyleAdopt(), isFalse, reason: 'one-shot');
    });

    test('*italic* completes; the first closing * of ** does not misfire', () {
      final rc = _rc();
      _type(rc, 'x *it* y');
      expect(rc.text, 'x it y');
      expect(runsFromController(rc).firstWhere((r) => r.text == 'it').italic,
          isTrue);

      final rc2 = _rc();
      _type(rc2, '**hi*');
      expect(rc2.text, '**hi*',
          reason: 'mid-bold state must not italicize as "*hi*"');
    });

    test('`code` becomes mono', () {
      final rc = _rc();
      _type(rc, 'run `x` now');
      expect(rc.text, 'run x now');
      expect(runsFromController(rc).firstWhere((r) => r.text == 'x').fontFamily,
          'mono');
    });

    test('math asterisks and snake_case never transform', () {
      final rc = _rc();
      _type(rc, '2 ** 3 and snake_case_name ');
      expect(rc.text, '2 ** 3 and snake_case_name ');
    });
  });

  group('escape hatches', () {
    test('backspace right after a rule restores the raw characters', () {
      final rc = _rc();
      _type(rc, '- ');
      expect(rc.text, '• ');
      _backspace(rc);
      expect(rc.text, '- ', reason: 'the raw markdown comes back');
      _type(rc, 'x');
      expect(rc.text, '- x', reason: 'and the rule does not re-fire');
    });

    test('backspace after a style-changing rule (quote) restores the raw '
        'text AND the base typing style', () {
      final rc = _rc();
      _type(rc, '> ');
      expect(rc.text, '│ ');
      _backspace(rc);
      expect(rc.text, '> ', reason: 'raw markdown restored');
      _type(rc, 'x');
      expect(runsFromController(rc).last.italic, isFalse,
          reason: 'italic typing style reverted with the rule');
    });

    test('rules do not fire mid-IME-composition', () {
      final rc = _rc();
      rc.value = const TextEditingValue(
        text: '- ',
        selection: TextSelection.collapsed(offset: 2),
        composing: TextRange(start: 0, end: 2),
      );
      expect(rc.text, '- ');
    });
  });
}
