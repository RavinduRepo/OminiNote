import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omininote/models/element.dart';
import 'package:omininote/utils/link_markers.dart';

TextRun _run(String text, {String? link}) => TextRun(
      text: text,
      fontSize: 16,
      bold: false,
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

StrokeElement _stroke() => StrokeElement(
      id: 's1',
      deviceId: 'test_device',
      z: 'a0',
      tool: StrokeTool.pen,
      color: const Color(0xFF000000),
      size: 2,
      points: [StrokePoint(0, 0, 0.5), StrokePoint(10, 10, 0.5)],
    );

void main() {
  const uri = 'omninote://link/n/nb1/s/s1/c/c1/p/p1/e/elem2';

  group('standaloneMarkerUri', () {
    test('a link run + trailing space IS a standalone marker (the marker shape)',
        () {
      expect(standaloneMarkerUri(_el([_run('My item', link: uri), _run(' ')])),
          uri);
    });

    test('a lone link run with no trailing space is still one', () {
      expect(standaloneMarkerUri(_el([_run('My item', link: uri)])), uri);
    });

    test('an inline link inside real prose is NOT a standalone marker', () {
      // deleting the box shouldn't auto-break a connection / delete content
      expect(
        standaloneMarkerUri(
            _el([_run('see '), _run('here', link: uri), _run(' now')])),
        isNull,
      );
    });

    test('leading text before the link disqualifies it', () {
      expect(
          standaloneMarkerUri(_el([_run('see '), _run('x', link: uri)])), isNull);
    });

    test('two different links in one box → not a (single) marker', () {
      expect(
        standaloneMarkerUri(_el([
          _run('a', link: uri),
          _run(' '),
          _run('b', link: 'https://example.com'),
        ])),
        isNull,
      );
    });

    test('plain text box (no link) is not a marker', () {
      expect(standaloneMarkerUri(_el([_run('just text')])), isNull);
    });

    test('a non-text element is never a marker', () {
      expect(standaloneMarkerUri(_stroke()), isNull);
    });
  });
}
