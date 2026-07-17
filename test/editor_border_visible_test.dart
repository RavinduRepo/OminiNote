import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omininote/canvas/text_measure.dart';
import 'package:omininote/screens/canvas_screen.dart' show kEditBorderStroke;

/// The box drawn around the text element being edited is deliberately OUTSET
/// past its Stack's bounds (negative left/top/bottom) so it brackets the text
/// instead of painting over it. `Stack` clips to its own size by default
/// (Clip.hardEdge), which silently erased the outset left/top/bottom edges and
/// left only the right one visible — the editor box looked like a single stray
/// vertical line. This pins that all four edges actually reach the screen.
void main() {
  const boxWidth = 200.0;
  const caretExtra = 3.0;
  const zoom = 1.0;
  const amber = Color(0xFFE9A23B);
  const originX = 10.0, originY = 10.0;

  /// Renders the overlay's Stack (field + outset border) and returns which
  /// columns/rows contain a run of amber border pixels.
  Future<({List<int> cols, List<int> rows})> paintedEdges(
    WidgetTester tester, {
    required Clip clipBehavior,
  }) async {
    final boundaryKey = GlobalKey();
    final controller = TextEditingController(text: 'probe text here');
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: RepaintBoundary(
              key: boundaryKey,
              child: Container(
                color: Colors.white,
                width: 260,
                height: 90,
                child: Stack(
                  children: [
                    Positioned(
                      left: originX,
                      top: originY,
                      width: boxWidth + caretExtra,
                      child: Transform.scale(
                        scale: zoom,
                        alignment: Alignment.topLeft,
                        child: Material(
                          color: Colors.transparent,
                          // The behavior under test.
                          child: Stack(
                            clipBehavior: clipBehavior,
                            children: [
                              SizedBox(
                                width: boxWidth + caretExtra,
                                child: MediaQuery.withNoTextScaling(
                                  child: TextField(
                                    controller: controller,
                                    maxLines: null,
                                    style: const TextStyle(
                                      inherit: false,
                                      fontSize: 16,
                                      height: 1.3,
                                      letterSpacing: 0,
                                      wordSpacing: 0,
                                      textBaseline: TextBaseline.alphabetic,
                                      leadingDistribution:
                                          TextLeadingDistribution.proportional,
                                      color: Color(0xFF000000),
                                    ),
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
                              // Mirrors _buildTextEditOverlay's border box.
                              Positioned(
                                left: -kEditBorderStroke / zoom,
                                top: -kEditBorderStroke / zoom,
                                bottom: -kTextBoxPad - (kEditBorderStroke / zoom),
                                width: boxWidth + (2 * kEditBorderStroke / zoom),
                                child: IgnorePointer(
                                  child: DecoratedBox(
                                    decoration: BoxDecoration(
                                      border: Border.all(
                                        color: amber,
                                        width: kEditBorderStroke / zoom,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ],
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
    );
    await tester.pump();

    final boundary =
        boundaryKey.currentContext!.findRenderObject() as RenderRepaintBoundary;
    // toImage/toByteData need real async — under fake async they never settle.
    final bytes = await tester.runAsync(() async {
      final img = await boundary.toImage();
      final bd = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
      img.dispose();
      return bd!;
    });

    const w = 260, h = 90;
    bool isAmber(int x, int y) {
      final o = (y * w + x) * 4;
      final r = bytes!.getUint8(o), g = bytes.getUint8(o + 1);
      final b = bytes.getUint8(o + 2);
      return r > 150 && g > 100 && g < 210 && b < 130;
    }

    final cols = <int>[];
    for (var x = 0; x < w; x++) {
      var n = 0;
      for (var y = 0; y < h; y++) {
        if (isAmber(x, y)) n++;
      }
      if (n >= 10) cols.add(x);
    }
    final rows = <int>[];
    for (var y = 0; y < h; y++) {
      var n = 0;
      for (var x = 0; x < w; x++) {
        if (isAmber(x, y)) n++;
      }
      if (n >= 100) rows.add(y);
    }
    return (cols: cols, rows: rows);
  }

  testWidgets('Clip.none: all four edges of the edit box are painted', (
    tester,
  ) async {
    final e = await paintedEdges(tester, clipBehavior: Clip.none);
    // A left AND a right vertical line, a top AND a bottom horizontal line.
    expect(e.cols.length, 2, reason: 'expected both vertical edges: ${e.cols}');
    expect(e.rows.length, 2, reason: 'expected both horizontal edges: ${e.rows}');
    // The box brackets the element rect (x: 10..210) from just outside it.
    expect(e.cols.first, lessThan(originX));
    expect(e.cols.last, greaterThanOrEqualTo(originX + boxWidth));
    expect(e.rows.first, lessThan(originY));
  });

  testWidgets('REGRESSION: the default Clip.hardEdge eats the outset edges', (
    tester,
  ) async {
    // Pins the bug: with the Stack's default clip, only the right edge and no
    // horizontal edge survives — the editor box all but disappears.
    final e = await paintedEdges(tester, clipBehavior: Clip.hardEdge);
    expect(e.cols.length, 1, reason: 'only the right edge survives: ${e.cols}');
    expect(e.rows, isEmpty, reason: 'both horizontal edges clipped: ${e.rows}');
  });
}
