import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omininote/canvas/rich_text_controller.dart';

/// A text box that mixes font sizes (or whose size changed after creation, so
/// `el.fontSize` is stale) must look the SAME whether it's being edited or
/// committed — "selected vs not selected".
///
/// The editor is a TextField (RenderEditable); the committed box is drawn by a
/// TextPainter. TextPainter applies no strut. EditableText, when `strutStyle`
/// is null, applies `StrutStyle.fromTextStyle(style, forceStrutHeight: true)` —
/// forcing EVERY line to the BASE style's height regardless of the run sizes on
/// it. That crushed line spacing while editing and sprang back on commit, so
/// the overlay passes `StrutStyle.disabled`.
///
/// These tests render both and diff the pixels — the same thing the eye does.
void main() {
  const text = 'small text then BIG TEXT here and more';
  const baseSize = 16.0;
  const bigSize = 40.0;
  const splitAt = 16; // [0,16) at baseSize, [16,end) at bigSize
  const w = 220, h = 320;
  const wrapWidth = 200.0;

  CharAttr attr(double size) => CharAttr(
        fontSize: size,
        bold: false,
        italic: false,
        color: const Color(0xFF000000),
        family: 'sans',
      );

  // The overlay's base style, in page points (zoom 1 in tests).
  const baseStyle = TextStyle(
    inherit: false,
    fontSize: baseSize,
    height: 1.3,
    letterSpacing: 0,
    wordSpacing: 0,
    leadingDistribution: TextLeadingDistribution.proportional,
    textBaseline: TextBaseline.alphabetic,
    color: Color(0xFF000000),
  );

  /// Stacks the committed rendering (a TextPainter, drawn in RED) under the
  /// edit overlay's field (drawn in BLACK) at the same origin and wrap width.
  /// Returns the number of rows where RED still shows through — i.e. where the
  /// painter put a glyph the editor did not. 0 == the two layouts coincide.
  Future<int> disagreeingRows(WidgetTester tester, StrutStyle? strut) async {
    final key = GlobalKey();
    final controller = RichTextController(
      text: text,
      attrs: [
        for (var i = 0; i < text.length; i++)
          attr(i < splitAt ? baseSize : bigSize),
      ],
      defaults: attr(baseSize),
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: RepaintBoundary(
              key: key,
              child: SizedBox(
                width: w.toDouble(),
                height: h.toDouble(),
                child: ColoredBox(
                  color: Colors.white,
                  child: MediaQuery.withNoTextScaling(
                    child: Stack(
                    children: [
                      Positioned(
                        left: 0,
                        top: 0,
                        width: wrapWidth,
                        child: _CommittedText(controller: controller),
                      ),
                      Positioned(
                        left: 0,
                        top: 0,
                        // +3 = the overlay's caret-margin compensation, so the
                        // field's EFFECTIVE wrap width is wrapWidth.
                        width: wrapWidth + 3,
                        child: Material(
                          color: Colors.transparent,
                          child: TextField(
                            controller: controller,
                            maxLines: null,
                            strutStyle: strut,
                            style: baseStyle,
                            decoration: const InputDecoration(
                              isDense: true,
                              contentPadding: EdgeInsets.zero,
                              border: InputBorder.none,
                              enabledBorder: InputBorder.none,
                              focusedBorder: InputBorder.none,
                              filled: false,
                            ),
                          ),
                        ),
                      ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final boundary =
        key.currentContext!.findRenderObject() as RenderRepaintBoundary;
    // toImage/toByteData need real async — under fake async they never settle.
    final bytes = await tester.runAsync(() async {
      final img = await boundary.toImage();
      final bd = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
      img.dispose();
      return bd!;
    });

    var rows = 0;
    for (var y = 0; y < h; y++) {
      var red = 0;
      for (var x = 0; x < w; x++) {
        final o = (y * w + x) * 4;
        final r = bytes!.getUint8(o);
        final g = bytes.getUint8(o + 1);
        final b = bytes.getUint8(o + 2);
        if (r > 140 && g < 90 && b < 90) red++;
      }
      if (red > 3) rows++;
    }
    return rows;
  }

  testWidgets('StrutStyle.disabled: the editor matches the committed text', (
    tester,
  ) async {
    expect(await disagreeingRows(tester, StrutStyle.disabled), 0);
  });

  testWidgets(
    'REGRESSION: a null strutStyle crushes mixed-size lines to the base size',
    (tester) async {
      // Pins the bug. EditableText's default forceStrutHeight strut pegs every
      // line to baseSize*1.3, so the 40pt run lays out far from where the
      // painter puts it and the box visibly changes on select/deselect.
      expect(await disagreeingRows(tester, null), greaterThan(50));
    },
  );
}

/// Draws the span exactly as the committed box does (a plain TextPainter, no
/// strut), in RED so any pixel the editor fails to cover is visible.
class _CommittedText extends LeafRenderObjectWidget {
  const _CommittedText({required this.controller});
  final RichTextController controller;

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderCommittedText(
        controller.buildTextSpan(context: context, withComposing: false),
      );
}

class _RenderCommittedText extends RenderBox {
  _RenderCommittedText(this.span);
  final InlineSpan span;

  late final TextPainter _tp = TextPainter(
    text: _recolor(span),
    textDirection: TextDirection.ltr,
  );

  @override
  void performLayout() {
    _tp.layout(minWidth: 200, maxWidth: 200);
    size = constraints.constrain(Size(200, _tp.height));
  }

  @override
  void paint(PaintingContext context, Offset offset) =>
      _tp.paint(context.canvas, offset);

  static InlineSpan _recolor(InlineSpan s) {
    if (s is TextSpan) {
      return TextSpan(
        text: s.text,
        style: (s.style ?? const TextStyle())
            .copyWith(color: const Color(0xFFFF0000)),
        children: s.children?.map(_recolor).toList(),
      );
    }
    return s;
  }
}
