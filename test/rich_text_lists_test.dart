import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omininote/canvas/rich_text_controller.dart';

RichTextController _rc(String text, {int? caret}) {
  final rc = RichTextController(
    text: text,
    attrs: [
      for (var i = 0; i < text.length; i++)
        CharAttr(
          fontSize: 16,
          bold: false,
          italic: false,
          color: const Color(0xFF000000),
          family: 'sans',
        ),
    ],
    defaults: CharAttr(
      fontSize: 16,
      bold: false,
      italic: false,
      color: const Color(0xFF000000),
      family: 'sans',
    ),
  );
  rc.selection = TextSelection.collapsed(offset: caret ?? text.length);
  return rc;
}

void main() {
  group('toggleLinePrefix', () {
    test('adds a bullet to a plain line and removes it on re-toggle', () {
      final rc = _rc('hello', caret: 3);
      rc.toggleLinePrefix(RichTextController.bulletPrefix);
      expect(rc.text, '• hello');
      expect(rc.selection.baseOffset, 5, reason: 'caret shifts by prefix');

      rc.toggleLinePrefix(RichTextController.bulletPrefix);
      expect(rc.text, 'hello');
    });

    test('replaces one list glyph with another', () {
      final rc = _rc('• task');
      rc.toggleLinePrefix(RichTextController.starPrefix);
      expect(rc.text, '★ task');
    });

    test('applies to every selected line', () {
      final rc = _rc('one\ntwo\nthree');
      rc.selection = const TextSelection(baseOffset: 0, extentOffset: 13);
      rc.toggleLinePrefix(RichTextController.bulletPrefix);
      expect(rc.text, '• one\n• two\n• three');
      // Style array stays aligned with the text after the rewrite.
      expect(rc.attrs.length, rc.text.length);
    });

    test('checkbox cycles none → unchecked → checked → none', () {
      final rc = _rc('buy milk');
      rc.toggleLinePrefix(RichTextController.uncheckedPrefix, cycle: true);
      expect(rc.text, '☐ buy milk');
      rc.toggleLinePrefix(RichTextController.uncheckedPrefix, cycle: true);
      expect(rc.text, '☑ buy milk');
      rc.toggleLinePrefix(RichTextController.uncheckedPrefix, cycle: true);
      expect(rc.text, 'buy milk');
    });
  });

  group('Enter auto-continues lists', () {
    TextEditingValue enterAt(RichTextController rc, int caret) {
      final t = rc.text;
      return TextEditingValue(
        text: '${t.substring(0, caret)}\n${t.substring(caret)}',
        selection: TextSelection.collapsed(offset: caret + 1),
      );
    }

    test('bullet line + Enter → new line starts with a bullet', () {
      final rc = _rc('• apples');
      rc.value = enterAt(rc, rc.text.length);
      expect(rc.text, '• apples\n• ');
      expect(rc.selection.baseOffset, rc.text.length);
    });

    test('checked line + Enter → new item is UNchecked', () {
      final rc = _rc('☑ done thing');
      rc.value = enterAt(rc, rc.text.length);
      expect(rc.text, '☑ done thing\n☐ ');
    });

    test('empty list item + Enter → exits the list (prefix removed)', () {
      final rc = _rc('• apples\n• ');
      rc.value = enterAt(rc, rc.text.length);
      expect(rc.text, '• apples\n');
      expect(rc.selection.baseOffset, rc.text.length);
    });

    test('plain text + Enter is untouched', () {
      final rc = _rc('no list here');
      rc.value = enterAt(rc, rc.text.length);
      expect(rc.text, 'no list here\n');
    });

    test('attrs stay aligned after auto-continuation', () {
      final rc = _rc('• apples');
      rc.value = enterAt(rc, rc.text.length);
      expect(rc.attrs.length, rc.text.length);
    });
  });
}
