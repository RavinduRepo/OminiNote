import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omininote/canvas/text_measure.dart';
import 'package:omininote/models/element.dart';

/// Opening a text box for editing puts the caret where the user TAPPED
/// (`_startTextEdit`'s `caretAt`), not at the end of the text.
///
/// This is what keeps the viewport still on open. With the selection left
/// invalid, `_ensureEditCaretVisible` falls back to end-of-text AND
/// EditableText separately assigns `selection = collapsed(text.length)` on
/// focus (which notifies, firing a second glide) — so zoomed in on a tall box,
/// tapping it scrolled twice to the box's END, dragging the spot the user was
/// aiming at out from under them before they could place the caret.
///
/// The test font is Ahem: every glyph is a fontSize x fontSize box, so
/// character offsets are exact.
void main() {
  TextElement box(String text, {double size = 16, double width = 200}) =>
      TextElement(
        id: 't1',
        deviceId: 'test_device',
        rect: Rect.fromLTWH(0, 0, width, 400),
        text: text,
        fontSize: size,
        color: const Color(0xFF000000),
      );

  test('a tap maps to the character under it', () {
    final el = box('abcdefghij');
    // Middle of the 4th glyph: x = 3*16 + 8 = 56.
    expect(caretOffsetAt(el, const Offset(56, 8)), 4);
    expect(caretOffsetAt(el, const Offset(0, 8)), 0);
  });

  test('a tap on an early line does NOT resolve to end-of-text', () {
    // Wraps to several lines in a 200pt box.
    final el = box('aaaa bbbb cccc dddd eeee ffff gggg hhhh');
    expect(el.text.length, greaterThan(20));
    // Tapping the first line must stay on the first line — the whole point.
    expect(caretOffsetAt(el, const Offset(0, 4)), 0);
    expect(
      caretOffsetAt(el, const Offset(0, 4)),
      isNot(el.text.length),
      reason: 'the old invalid-selection path fell back to end-of-text',
    );
  });

  test('a tap on a lower line lands on that line, not the last', () {
    final el = box('aaaaaaaaaaaa bbbbbbbbbbbb cccccccccccc dddddddddddd');
    // Line height = 16 * 1.3 = 20.8; sample the 2nd line.
    final second = caretOffsetAt(el, const Offset(0, 24));
    expect(second, greaterThan(0));
    expect(second, lessThan(el.text.length));
  });

  test('offsets clamp into range; an empty box yields 0', () {
    expect(caretOffsetAt(box(''), Offset.zero), 0);
    final el = box('abc');
    expect(caretOffsetAt(el, const Offset(9999, 9999)), lessThanOrEqualTo(3));
    expect(caretOffsetAt(el, const Offset(-50, -50)), greaterThanOrEqualTo(0));
  });
}
