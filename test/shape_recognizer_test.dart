import 'dart:math' as math;
import 'package:flutter_test/flutter_test.dart';
import 'package:omininote/canvas/shape_recognizer.dart';
import 'package:omininote/models/element.dart' show StrokePoint;

/// Unit tests for the pure shape recognizer (SHAPES_PLAN Phase 1.2). Synthetic
/// jittered inputs must classify to the right [ShapeKind]; scribbles/doodles
/// must return null ("random intent"). Deterministic (seeded jitter).
void main() {
  final rnd = math.Random(42);
  double j(double amp) => (rnd.nextDouble() - 0.5) * 2 * amp;

  List<StrokePoint> pts(List<Offset> o, {double jitter = 0}) =>
      [for (final p in o) StrokePoint(p.dx + j(jitter), p.dy + j(jitter), 0.5)];

  // Densely sample a polyline (optionally closed) into raw points.
  List<Offset> samplePoly(List<Offset> verts,
      {required bool closed, double spacing = 4}) {
    final path = closed ? [...verts, verts.first] : verts;
    final out = <Offset>[];
    for (var e = 0; e < path.length - 1; e++) {
      final a = path[e], b = path[e + 1];
      final d = (b - a).distance;
      final steps = math.max(1, (d / spacing).round());
      for (var s = 0; s < steps; s++) {
        final t = s / steps;
        out.add(Offset(a.dx + (b.dx - a.dx) * t, a.dy + (b.dy - a.dy) * t));
      }
    }
    out.add(path.last);
    return out;
  }

  List<Offset> sampleEllipse(Offset c, double rx, double ry, double rot,
      {int n = 80}) {
    final cosR = math.cos(rot), sinR = math.sin(rot);
    return [
      for (var i = 0; i <= n; i++)
        () {
          final t = i / n * 2 * math.pi;
          final x = rx * math.cos(t), y = ry * math.sin(t);
          return Offset(c.dx + x * cosR - y * sinR, c.dy + x * sinR + y * cosR);
        }()
    ];
  }

  group('recognizeShape', () {
    test('straight line', () {
      final raw = pts(samplePoly(const [Offset(20, 30), Offset(220, 34)],
          closed: false));
      final fit = recognizeShape(raw);
      expect(fit, isNotNull);
      expect(fit!.kind, ShapeKind.line);
      expect(fit.vertices.length, 2);
    });

    test('line angle snaps to horizontal', () {
      // ~3° off horizontal → should snap flat.
      final raw = pts(
          samplePoly(const [Offset(20, 100), Offset(220, 110)], closed: false));
      final fit = recognizeShape(raw)!;
      expect(fit.kind, ShapeKind.line);
      expect((fit.vertices[0].dy - fit.vertices[1].dy).abs(), lessThan(1.0));
    });

    test('axis-aligned rectangle', () {
      final raw = pts(
          samplePoly(const [
            Offset(40, 40),
            Offset(240, 40),
            Offset(240, 180),
            Offset(40, 180),
          ], closed: true),
          jitter: 2.0);
      final fit = recognizeShape(raw);
      expect(fit, isNotNull);
      expect(fit!.kind, ShapeKind.rectangle);
      expect(fit.vertices.length, 4);
    });

    test('triangle', () {
      final raw = pts(
          samplePoly(const [
            Offset(120, 30),
            Offset(220, 200),
            Offset(20, 200),
          ], closed: true),
          jitter: 2.0);
      final fit = recognizeShape(raw);
      expect(fit, isNotNull);
      expect(fit!.kind, ShapeKind.triangle);
      expect(fit.vertices.length, 3);
    });

    test('circle', () {
      final raw = pts(sampleEllipse(const Offset(120, 120), 80, 80, 0),
          jitter: 2.5);
      final fit = recognizeShape(raw);
      expect(fit, isNotNull);
      expect(fit!.kind, ShapeKind.circle);
      expect((fit.center - const Offset(120, 120)).distance, lessThan(12));
      expect(fit.rx, closeTo(80, 12));
    });

    test('ellipse (non-round)', () {
      final raw = pts(sampleEllipse(const Offset(150, 120), 120, 55, 0),
          jitter: 2.0);
      final fit = recognizeShape(raw);
      expect(fit, isNotNull);
      expect(fit!.kind, ShapeKind.ellipse);
      // rx is the major axis.
      expect(fit.rx, greaterThan(fit.ry));
      expect(fit.rx, closeTo(120, 22));
    });

    test('rotated ellipse recovers a rotation', () {
      final raw = pts(
          sampleEllipse(const Offset(150, 150), 110, 50, math.pi / 6),
          jitter: 1.5);
      final fit = recognizeShape(raw);
      expect(fit, isNotNull);
      expect(fit!.kind, ShapeKind.ellipse);
      expect(fit.rotation.abs(), greaterThan(0.1));
    });

    test('smooth open curve is a curve (not a line)', () {
      // A gentle arc: open, curved, no corners.
      final arc = [
        for (var i = 0; i <= 40; i++)
          () {
            final t = i / 40 * math.pi; // half circle, open
            return Offset(120 + 90 * math.cos(t), 120 - 60 * math.sin(t));
          }()
      ];
      final fit = recognizeShape(pts(arc, jitter: 1.0));
      expect(fit, isNotNull);
      expect(fit!.kind, ShapeKind.curve);
      expect(fit.controlPoints.length, greaterThanOrEqualTo(3));
    });
  });

  group('rejects random intent', () {
    test('tiny stroke → null', () {
      final raw = pts(const [Offset(10, 10), Offset(12, 11), Offset(13, 12)]);
      expect(recognizeShape(raw), isNull);
    });

    test('too few points → null', () {
      expect(
          recognizeShape([StrokePoint(0, 0, 0.5), StrokePoint(50, 50, 0.5)]),
          isNull);
    });

    test('a self-crossing scribble → null', () {
      final scribble = <Offset>[];
      for (var i = 0; i <= 60; i++) {
        final t = i / 60 * 6 * math.pi;
        scribble.add(Offset(120 + 60 * math.cos(t) * (1 - i / 90),
            120 + 60 * math.sin(t * 1.7)));
      }
      expect(recognizeShape(pts(scribble, jitter: 1.0)), isNull);
    });
  });

  group('pointsForShape', () {
    test('rectangle emits a closed-ish, on-box point set', () {
      final fit = recognizeShape(pts(
          samplePoly(const [
            Offset(40, 40),
            Offset(240, 40),
            Offset(240, 180),
            Offset(40, 180),
          ], closed: true),
          jitter: 1.5))!;
      final out = pointsForShape(fit);
      expect(out.length, greaterThan(8));
      // Closed shape: the stroke returns to (and slightly past) its start, so
      // the last point sits within the seam-overlap distance of the first.
      final first = out.first, last = out.last;
      expect((Offset(first.x, first.y) - Offset(last.x, last.y)).distance,
          lessThan(14));
      // Every generated point lies within the shape's bounds (+ small margin).
      for (final p in out) {
        expect(p.x, inInclusiveRange(30, 250));
        expect(p.y, inInclusiveRange(30, 190));
      }
    });

    test('circle emits points at ~radius from the center', () {
      final fit = recognizeShape(
          pts(sampleEllipse(const Offset(120, 120), 80, 80, 0), jitter: 1.0))!;
      final out = pointsForShape(fit);
      for (final p in out) {
        final r = (Offset(p.x, p.y) - fit.center).distance;
        expect(r, closeTo(fit.rx, 4));
      }
    });

    test('all generated points carry neutral pressure 0.5', () {
      final fit = recognizeShape(
          pts(samplePoly(const [Offset(20, 20), Offset(220, 20)], closed: false)))!;
      for (final p in pointsForShape(fit)) {
        expect(p.p, 0.5);
      }
    });
  });
}
