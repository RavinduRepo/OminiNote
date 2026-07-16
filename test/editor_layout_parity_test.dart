import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

/// The canvas text-edit overlay must lay text out EXACTLY like the painter's
/// TextPainter, or text visibly shifts/re-wraps when an edit session opens or
/// commits. These tests pin the two layout-parity rules the overlay relies on
/// (see `_buildTextEditOverlay` in canvas_screen.dart):
///
/// 1. The editing TextField adds no inset — its EditableText sits at the
///    field's own origin (isDense + zero contentPadding + no border).
/// 2. With letterSpacing/wordSpacing zeroed and proportional leading, the
///    editor's glyph advances and positions equal a raw TextPainter's at the
///    same width. (Material 3 merges the theme's bodyLarge UNDER the field's
///    style — its letterSpacing 0.5 leaked through null fields and made
///    editor text wider per glyph than the committed text.)
void main() {
  // The overlay's exact style recipe (page-point size; Transform supplies
  // zoom in the real app, so tests run at zoom 1). `inherit: false` blocks
  // Material's bodyLarge merge entirely — that merge leaked letterSpacing
  // 0.5 AND an explicit fontFamily that can resolve to a different face than
  // the painter's null→engine-default (e.g. Samsung font substitution).
  // NOTE: the font-family half of that bug is untestable here — the test
  // environment maps every family to Ahem — which is why these tests passed
  // while a real device still re-wrapped; don't weaken inherit:false.
  const style = TextStyle(
    inherit: false,
    fontSize: 16,
    height: 1.3,
    letterSpacing: 0,
    wordSpacing: 0,
    leadingDistribution: TextLeadingDistribution.proportional,
    textBaseline: TextBaseline.alphabetic,
    color: Color(0xFF000000),
  );

  Future<TestGesture?> pumpEditor(WidgetTester tester, String text) async {
    final controller = TextEditingController(text: text);
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Stack(
            children: [
              Positioned(
                left: 100,
                top: 100,
                // +3 mirrors the app's caret-margin compensation: the field
                // is widened by RenderEditable's internal caret margin
                // (cursorWidth 2 + 1 gap) so its EFFECTIVE wrap width is 200,
                // the same width the painter lays out at.
                width: 203,
                child: Material(
                  color: Colors.transparent,
                  child: MediaQuery.withNoTextScaling(
                    child: TextField(
                      controller: controller,
                      maxLines: null,
                      cursorWidth: 2,
                      style: style,
                      decoration: const InputDecoration(
                        isDense: true,
                        contentPadding: EdgeInsets.zero,
                        border: InputBorder.none,
                        filled: false,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    return null;
  }

  testWidgets('the editing TextField adds no inset around its text', (
    tester,
  ) async {
    await pumpEditor(tester, 'probe text');
    final fieldTL = tester.getTopLeft(find.byType(TextField));
    final editableTL = tester.getTopLeft(find.byType(EditableText));
    expect(editableTL, fieldTL);
  });

  testWidgets('editor glyph positions match a raw TextPainter exactly', (
    tester,
  ) async {
    const text = 'probe text with several words to compare';
    await pumpEditor(tester, text);
    final renderEditable = tester.allRenderObjects
        .whereType<RenderEditable>()
        .first;
    final tp = TextPainter(
      text: const TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
    )..layout(minWidth: 200, maxWidth: 200);
    addTearDown(tp.dispose);

    // Per-character caret positions encode both glyph advances and line
    // breaks exactly. (Selection BOXES can't be compared directly —
    // RenderEditable splits them differently, e.g. around spaces — but the
    // caret position of every character must coincide if and only if the two
    // layouts are identical.)
    for (var i = 0; i <= text.length; i++) {
      final pos = TextPosition(offset: i);
      final ed = renderEditable.getLocalRectForCaret(pos);
      final painter = tp.getOffsetForCaret(pos, Rect.zero);
      expect(
        ed.left,
        moreOrLessEquals(painter.dx, epsilon: .02),
        reason: 'caret x at char $i',
      );
      // y compared as LINE INDEX: the two report caret tops under slightly
      // different conventions (sub-pixel ascent bookkeeping), but a char on
      // the wrong LINE is what a real wrap mismatch looks like.
      const lineHeight = 16 * 1.3;
      expect(
        (ed.top / lineHeight).round(),
        (painter.dy / lineHeight).round(),
        reason: 'caret line at char $i',
      );
    }
  });
}
