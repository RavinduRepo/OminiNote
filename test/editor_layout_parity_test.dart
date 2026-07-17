import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omininote/theme/app_theme.dart';

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

  /// The overlay's exact InputDecoration. Every border slot is cleared, not
  /// just `border` — see the test below for why that is load-bearing.
  const decoration = InputDecoration(
    isDense: true,
    contentPadding: EdgeInsets.zero,
    border: InputBorder.none,
    enabledBorder: InputBorder.none,
    focusedBorder: InputBorder.none,
    disabledBorder: InputBorder.none,
    errorBorder: InputBorder.none,
    focusedErrorBorder: InputBorder.none,
    filled: false,
  );

  /// Pumps the overlay's field under the REAL app theme. Using a bare
  /// MaterialApp here (as this file originally did) is what let the
  /// theme-leak bug through: the default theme has no InputDecorationTheme,
  /// so nothing could leak and the tests passed while the device was broken.
  Future<TestGesture?> pumpEditor(
    WidgetTester tester,
    String text, {
    InputDecoration deco = decoration,
  }) async {
    final controller = TextEditingController(text: text);
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
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
                      // The real overlay autofocuses — load-bearing for the
                      // leak below, since a focused field resolves
                      // `focusedBorder`, not `border`.
                      autofocus: true,
                      maxLines: null,
                      cursorWidth: 2,
                      style: style,
                      decoration: deco,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    return null;
  }

  testWidgets('the editing TextField adds no inset around its text', (
    tester,
  ) async {
    await pumpEditor(tester, 'probe text');
    final fieldTL = tester.getTopLeft(find.byType(TextField));
    final editableTL = tester.getTopLeft(find.byType(EditableText));
    expect(editableTL, fieldTL);
    // ...and no width is eaten either, or the editor wraps early.
    expect(
      tester.getSize(find.byType(EditableText)).width,
      tester.getSize(find.byType(TextField)).width,
    );
  });

  testWidgets(
    'REGRESSION: clearing only `border` lets the theme OutlineInputBorder leak',
    (tester) async {
      // Pins WHY every border slot must be cleared. InputDecoration.applyDefaults
      // falls back to the theme PER SLOT (`focusedBorder ?? theme.focusedBorder`),
      // and the overlay's field is always focused — so this decoration, which sets
      // only `border`, still resolves the app theme's focusedBorder (an
      // OutlineInputBorder). Material 3 then adds that border's gapPadding (4.0)
      // to contentPadding on both sides via InputDecorator's `inputGap`.
      // This is the exact shape of the shipped bug: text pushed 4pt right and
      // 8pt of wrap width lost, so the editor broke lines at different words
      // than the painter. If this test ever starts reporting 0 drift, Flutter
      // changed the behavior and the overlay's belt-and-braces can be revisited.
      await pumpEditor(
        tester,
        'probe text',
        deco: const InputDecoration(
          isDense: true,
          contentPadding: EdgeInsets.zero,
          border: InputBorder.none,
          filled: false,
        ),
      );
      final dx = tester.getTopLeft(find.byType(EditableText)).dx -
          tester.getTopLeft(find.byType(TextField)).dx;
      final lostWidth = tester.getSize(find.byType(TextField)).width -
          tester.getSize(find.byType(EditableText)).width;
      expect(dx, 4.0, reason: 'leaked OutlineInputBorder gapPadding');
      expect(lostWidth, 8.0, reason: 'gapPadding applied on both sides');
    },
  );

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
