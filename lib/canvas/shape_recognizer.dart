/// Pure shape recognition + perfect-point generation for the "snap drawn
/// shapes" feature (see `SHAPES_PLAN.md`). **No controller/painter imports** —
/// it operates purely on page-local geometry so it is fully unit-testable and
/// can run anywhere (including a background isolate if ever needed).
///
/// A recognized shape is later committed as an ordinary `StrokeElement` whose
/// points happen to be mathematically clean — there is no new element subtype,
/// no schema change, no merge-engine change. This module owns only two
/// responsibilities: decide *what* the user drew ([recognizeShape]) and emit
/// render-ready points for it ([pointsForShape]).
library;

import 'dart:math' as math;
import 'dart:ui' show Offset, Rect;

import '../models/element.dart' show StrokePoint;

/// The kinds we can recognize. `arrow` is a stretch goal (slot kept, not yet
/// classified); everything else ships in Phase 1.
enum ShapeKind { line, arrow, triangle, rectangle, polygon, circle, ellipse, curve }

/// A successful fit. Which fields are meaningful depends on [kind]:
///   * line/arrow/triangle/rectangle/polygon → [vertices] (closed implied by
///     the kind; a polygon/triangle/rectangle wraps back to `vertices.first`).
///   * circle/ellipse → [center], [rx], [ry], [rotation] (radians).
///   * curve → [controlPoints] (an open Catmull-Rom control polyline).
class ShapeFit {
  final ShapeKind kind;

  /// 0..1, already thresholded by [recognizeShape] (a returned fit is always
  /// above [ShapeTuning.minConfidence]).
  final double confidence;

  final List<Offset> vertices;
  final Offset center;
  final double rx;
  final double ry;
  final double rotation;
  final List<Offset> controlPoints;

  const ShapeFit._({
    required this.kind,
    required this.confidence,
    this.vertices = const [],
    this.center = Offset.zero,
    this.rx = 0,
    this.ry = 0,
    this.rotation = 0,
    this.controlPoints = const [],
  });

  factory ShapeFit.polyline(
    ShapeKind kind,
    List<Offset> vertices,
    double confidence,
  ) =>
      ShapeFit._(kind: kind, vertices: vertices, confidence: confidence);

  factory ShapeFit.ellipse({
    required Offset center,
    required double rx,
    required double ry,
    required double rotation,
    required double confidence,
    bool circle = false,
  }) =>
      ShapeFit._(
        kind: circle ? ShapeKind.circle : ShapeKind.ellipse,
        center: center,
        rx: rx,
        ry: ry,
        rotation: rotation,
        confidence: confidence,
      );

  factory ShapeFit.curve(List<Offset> controlPoints, double confidence) =>
      ShapeFit._(
          kind: ShapeKind.curve,
          controlPoints: controlPoints,
          confidence: confidence);

  /// True for the closed polygon family (wraps back to the first vertex).
  bool get isClosedPolygon =>
      kind == ShapeKind.triangle ||
      kind == ShapeKind.rectangle ||
      kind == ShapeKind.polygon;
}

/// Every tolerance in one place — the on-device tuning tail edits only this.
/// Values are in page-local PDF points / degrees unless noted.
class ShapeTuning {
  const ShapeTuning._();

  static const double minPathLength = 24; // shorter → intent too small, bail
  static const int minRawPoints = 8;
  static const int resampleN = 64;

  static const double closedGapFrac = 0.12; // gap < max(frac*len, min) ⇒ closed
  static const double closedGapMin = 12;

  static const double cornerAngleDeg = 40; // turning angle that counts as a corner
  static const double cornerWindowFrac = 1 / 12; // neighbour offset k = frac*N

  static const double lineMaxDeviationFrac = 0.07; // perp dev / len for a line
  static const double lineAngleSnapDeg = 8; // snap near 0/45/90…

  static const double circleRadialCvMax = 0.14; // std/mean radius for a circle
  static const double circleAxisRatioMin = 0.80; // rx/ry above ⇒ call it a circle
  static const double rectEdgeAxisSnapDeg = 10; // near-axis edges ⇒ axis-align

  static const double polygonFitTolFrac = 0.07; // mean edge dist / len tol
  static const double ellipseResidualTol = 0.26; // mean |eq-1| tol (forgiving)

  static const double minConfidence = 0.55;

  static const double emitSpacing = 2.5; // generated edge/arc point spacing
  static const int ellipseSamples = 96;
  static const double cornerClusterInset = 0.5; // corner-pinning neighbour dist
  // Closed shapes retrace a little past their start so perfect_freehand's end
  // cap lands on top of the start cap — otherwise the loop shows a seam/gap.
  static const double closedSeamOverlap = 10; // page points of retrace
}

const double _deg = math.pi / 180;

/// Recognizes the shape in [raw] (page-local stroke points), or returns null if
/// there is no confident match / the input is too short / the intent looks
/// random. Never throws.
ShapeFit? recognizeShape(List<StrokePoint> raw) {
  if (raw.length < ShapeTuning.minRawPoints) return null;
  final pts = [for (final p in raw) Offset(p.x, p.y)];
  if (_pathLength(pts) < ShapeTuning.minPathLength) return null;

  final n = ShapeTuning.resampleN;
  final rs = _resample(pts, n);
  final len = _pathLength(rs);
  if (len <= 0) return null;

  final gap = (rs.first - rs.last).distance;
  final closed = gap <
      math.max(ShapeTuning.closedGapFrac * len, ShapeTuning.closedGapMin);
  final corners = _detectCorners(rs, closed);

  // Too busy to be a clean shape — treat as "random intent".
  if (corners.length > 8) return null;
  // A clean shape never crosses itself in its interior (a closed shape may
  // overlap only where it closes, which we exclude). A scribble/doodle does →
  // bail before classifying.
  final margin = math.max(2, (n * 0.12).round());
  if (_selfIntersectsInterior(rs, margin)) return null;

  ShapeFit? best;
  void consider(ShapeFit? f) {
    if (f == null) return;
    if (f.confidence < ShapeTuning.minConfidence) return;
    if (best == null || f.confidence > best!.confidence) best = f;
  }

  if (closed) {
    consider(_fitEllipse(rs, len));
    if (corners.length >= 3 && corners.length <= 8) {
      consider(_fitPolygon(rs, corners, len));
    }
  } else {
    // Open: a straight line, else a smooth curve.
    consider(_fitLine(rs, len, corners));
    if (best == null || best!.confidence < 0.9) {
      consider(_fitCurve(rs, corners));
    }
  }
  return best;
}

// ── Fitters ──────────────────────────────────────────────────────────────────

ShapeFit? _fitLine(List<Offset> rs, double len, List<int> corners) {
  if (corners.length > 1) return null;
  final a = rs.first;
  final b = rs.last;
  if ((b - a).distance < 1) return null;
  // Mean perpendicular distance of every point from the a→b chord.
  var sum = 0.0;
  for (final p in rs) {
    sum += _distToSegment(p, a, b);
  }
  final err = (sum / rs.length) / len;
  if (err > ShapeTuning.lineMaxDeviationFrac) return null;
  final snapped = _snapLineAngle(a, b);
  final conf =
      (1 - err / ShapeTuning.lineMaxDeviationFrac).clamp(0.0, 1.0).toDouble();
  return ShapeFit.polyline(ShapeKind.line, snapped, conf);
}

ShapeFit? _fitPolygon(List<Offset> rs, List<int> corners, double len) {
  final verts = [for (final i in corners) rs[i]];
  if (verts.length < 3) return null;
  final err = _closedPolyFitError(rs, verts) / len;
  final conf =
      (1 - err / ShapeTuning.polygonFitTolFrac).clamp(0.0, 1.0).toDouble();
  if (conf < ShapeTuning.minConfidence) return null;

  if (verts.length == 3) {
    return ShapeFit.polyline(ShapeKind.triangle, verts, conf);
  }
  if (verts.length == 4) {
    return ShapeFit.polyline(ShapeKind.rectangle, _maybeAxisAlign(verts), conf);
  }
  return ShapeFit.polyline(
      ShapeKind.polygon, _maybeRegularize(verts), conf);
}

ShapeFit? _fitEllipse(List<Offset> rs, double len) {
  final c = _centroid(rs);
  // Covariance about the centroid gives the principal-axis *direction*
  // regardless of how the boundary is sampled (arc-length resampling changes
  // point density but not the symmetry). The axis *lengths* come from the
  // measured extent along each direction, which is sampling-independent — the
  // variance→semi-axis formula only holds for angle-uniform sampling, which we
  // don't have after resampling.
  var sxx = 0.0, syy = 0.0, sxy = 0.0;
  for (final p in rs) {
    final dx = p.dx - c.dx, dy = p.dy - c.dy;
    sxx += dx * dx;
    syy += dy * dy;
    sxy += dx * dy;
  }
  final theta = (sxy.abs() < 1e-9)
      ? (sxx >= syy ? 0.0 : math.pi / 2)
      : 0.5 * math.atan2(2 * sxy, sxx - syy);
  final ux = math.cos(theta), uy = math.sin(theta);

  var extA = 0.0, extB = 0.0;
  for (final p in rs) {
    final dx = p.dx - c.dx, dy = p.dy - c.dy;
    final a = (dx * ux + dy * uy).abs(); // along theta
    final b = (-dx * uy + dy * ux).abs(); // perpendicular
    if (a > extA) extA = a;
    if (b > extB) extB = b;
  }
  // Major = larger extent.
  final double rx, ry, rotation;
  if (extA >= extB) {
    rx = extA;
    ry = extB;
    rotation = theta;
  } else {
    rx = extB;
    ry = extA;
    rotation = theta + math.pi / 2;
  }
  if (rx < 1 || ry < 1) return null;

  // Residual: every point should satisfy (x'/rx)²+(y'/ry)² ≈ 1 in ellipse frame.
  final cosR = math.cos(rotation), sinR = math.sin(rotation);
  var res = 0.0;
  for (final p in rs) {
    final dx = p.dx - c.dx, dy = p.dy - c.dy;
    final x = dx * cosR + dy * sinR; // projection onto major axis
    final y = -dx * sinR + dy * cosR; // onto minor
    final v = (x * x) / (rx * rx) + (y * y) / (ry * ry);
    res += (v - 1).abs();
  }
  res /= rs.length;
  final conf =
      (1 - res / ShapeTuning.ellipseResidualTol).clamp(0.0, 1.0).toDouble();
  if (conf < ShapeTuning.minConfidence) return null;

  final ratio = ry / rx; // rx is the major, so ratio ≤ 1
  if (ratio >= ShapeTuning.circleAxisRatioMin) {
    final r = (rx + ry) / 2;
    return ShapeFit.ellipse(
        center: c, rx: r, ry: r, rotation: 0, confidence: conf, circle: true);
  }
  return ShapeFit.ellipse(
      center: c, rx: rx, ry: ry, rotation: rotation, confidence: conf);
}

ShapeFit? _fitCurve(List<Offset> rs, List<int> corners) {
  if (corners.length > 2) return null;
  // Decimate with Ramer–Douglas–Peucker, then keep those as Catmull-Rom controls.
  final len = _pathLength(rs);
  final ctrl = _rdp(rs, len * 0.02);
  if (ctrl.length < 3) return null; // a near-straight curve is just a line
  // Modest, fixed confidence: a smooth open stroke that isn't a line.
  return ShapeFit.curve(ctrl, 0.6);
}

// ── Shape tool (drag-to-draw a chosen kind) ──────────────────────────────────

/// The predefined kinds the Shapes tool can draw. Persisted device-local as the
/// last-used kind (`SettingsService.shapeToolKind`).
enum ShapeToolKind {
  line,
  arrow,
  rectangle,
  ellipse,
  triangle,
  diamond,
  pentagon,
  hexagon,
  star,
}

/// Builds a [ShapeFit] for the Shapes tool from a drag between [a] (anchor) and
/// [b] (current pointer). [constrain] (Shift) squares the bounding box — circle,
/// square, 45°-snapped line, regular polygon. Reuses [pointsForShape] for the
/// actual points, so the tool and hold-to-snap render identically.
ShapeFit shapeToolFit(ShapeToolKind kind, Offset a, Offset b,
    {bool constrain = false}) {
  // Square the box when constrained (keeps the drag direction).
  Offset b2 = b;
  if (constrain && kind != ShapeToolKind.line && kind != ShapeToolKind.arrow) {
    final dx = b.dx - a.dx, dy = b.dy - a.dy;
    final s = math.max(dx.abs(), dy.abs());
    b2 = Offset(a.dx + (dx.isNegative ? -s : s), a.dy + (dy.isNegative ? -s : s));
  }
  final rect = Rect.fromPoints(a, b2);
  final c = rect.center;
  final hw = rect.width / 2, hh = rect.height / 2;

  Offset onBox(double ux, double uy) => Offset(c.dx + ux * hw, c.dy + uy * hh);
  // Regular n-gon (or n-point star when [inner] > 0) inscribed in the box,
  // pointing up. Vertices are evenly spaced on the unit circle then mapped onto
  // the box so a non-square drag stretches the shape to fit.
  List<Offset> ngon(int n, {double inner = 0}) {
    final count = inner > 0 ? n * 2 : n;
    const start = -math.pi / 2; // top
    return [
      for (var i = 0; i < count; i++)
        () {
          final r = (inner > 0 && i.isOdd) ? inner : 1.0;
          final ang = start + i * 2 * math.pi / count;
          return onBox(r * math.cos(ang), r * math.sin(ang));
        }()
    ];
  }

  switch (kind) {
    case ShapeToolKind.line:
      final verts = constrain ? _snapLineAngle(a, b) : [a, b];
      return ShapeFit.polyline(ShapeKind.line, verts, 1);
    case ShapeToolKind.arrow:
      final end = constrain ? _snapLineAngle(a, b)[1] : b;
      return ShapeFit.polyline(ShapeKind.arrow, _arrowVerts(a, end), 1);
    case ShapeToolKind.rectangle:
      return ShapeFit.polyline(
        ShapeKind.rectangle,
        [rect.topLeft, rect.topRight, rect.bottomRight, rect.bottomLeft],
        1,
      );
    case ShapeToolKind.ellipse:
      return ShapeFit.ellipse(
        center: c,
        rx: hw.abs(),
        ry: hh.abs(),
        rotation: 0,
        confidence: 1,
        circle: (hw - hh).abs() < 0.5,
      );
    case ShapeToolKind.triangle:
      return ShapeFit.polyline(
        ShapeKind.triangle,
        [
          Offset(c.dx, rect.top),
          Offset(rect.right, rect.bottom),
          Offset(rect.left, rect.bottom),
        ],
        1,
      );
    case ShapeToolKind.diamond:
      return ShapeFit.polyline(
        ShapeKind.polygon,
        [
          Offset(c.dx, rect.top),
          Offset(rect.right, c.dy),
          Offset(c.dx, rect.bottom),
          Offset(rect.left, c.dy),
        ],
        1,
      );
    case ShapeToolKind.pentagon:
      return ShapeFit.polyline(ShapeKind.polygon, ngon(5), 1);
    case ShapeToolKind.hexagon:
      return ShapeFit.polyline(ShapeKind.polygon, ngon(6), 1);
    case ShapeToolKind.star:
      return ShapeFit.polyline(ShapeKind.polygon, ngon(5, inner: 0.45), 1);
  }
}

List<Offset> _arrowVerts(Offset a, Offset b) {
  final v = b - a;
  final len = v.distance;
  if (len == 0) return [a, b];
  final ux = v.dx / len, uy = v.dy / len;
  final head = math.min(len * 0.28, 26.0); // barb length
  const spread = 0.42; // radians off the shaft
  final cosS = math.cos(spread), sinS = math.sin(spread);
  // Barb directions point back from the tip.
  final l = Offset(-ux * cosS + uy * sinS, -uy * cosS - ux * sinS);
  final r = Offset(-ux * cosS - uy * sinS, -uy * cosS + ux * sinS);
  final barbL = Offset(b.dx + l.dx * head, b.dy + l.dy * head);
  final barbR = Offset(b.dx + r.dx * head, b.dy + r.dy * head);
  return [a, b, barbL, b, barbR];
}

// ── Hold-drag adjust (pure) ──────────────────────────────────────────────────

/// The draggable anchors of [fit] in page space — used to pick which one the
/// pen grabs when adjusting a freshly-snapped shape. Meaning by kind:
///   * polyline (line/arrow/triangle/rectangle/polygon) → the vertices.
///   * circle → a single radius handle.
///   * ellipse → the 4 axis extrema (major±, minor±).
///   * curve → the two endpoints.
List<Offset> anchorsFor(ShapeFit fit) {
  switch (fit.kind) {
    case ShapeKind.line:
    case ShapeKind.arrow:
    case ShapeKind.triangle:
    case ShapeKind.rectangle:
    case ShapeKind.polygon:
      return fit.vertices;
    case ShapeKind.circle:
      return [Offset(fit.center.dx + fit.rx, fit.center.dy)];
    case ShapeKind.ellipse:
      return _ellipseExtrema(fit);
    case ShapeKind.curve:
      return fit.controlPoints.isEmpty
          ? const []
          : [fit.controlPoints.first, fit.controlPoints.last];
  }
}

/// Index (into [anchorsFor]) of the anchor nearest [p].
int nearestAnchorIndex(ShapeFit fit, Offset p) {
  final anchors = anchorsFor(fit);
  var best = 0;
  var bestD = double.infinity;
  for (var i = 0; i < anchors.length; i++) {
    final d = (anchors[i] - p).distance;
    if (d < bestD) {
      bestD = d;
      best = i;
    }
  }
  return best;
}

/// Returns a new [ShapeFit] with anchor [anchor] moved to [to]. A rectangle
/// pins the opposite corner (natural stretch/squash); a circle/ellipse resizes
/// the grabbed radius/semi-axis; other polylines move just that vertex; a curve
/// moves the grabbed endpoint.
ShapeFit moveAnchor(ShapeFit fit, int anchor, Offset to) {
  switch (fit.kind) {
    case ShapeKind.rectangle:
      final v = fit.vertices;
      if (v.length != 4) return fit;
      final pinned = v[(anchor + 2) % 4];
      final minX = math.min(pinned.dx, to.dx), maxX = math.max(pinned.dx, to.dx);
      final minY = math.min(pinned.dy, to.dy), maxY = math.max(pinned.dy, to.dy);
      return ShapeFit.polyline(
        ShapeKind.rectangle,
        [
          Offset(minX, minY),
          Offset(maxX, minY),
          Offset(maxX, maxY),
          Offset(minX, maxY),
        ],
        fit.confidence,
      );
    case ShapeKind.line:
    case ShapeKind.arrow:
    case ShapeKind.triangle:
    case ShapeKind.polygon:
      final v = [...fit.vertices];
      if (anchor >= 0 && anchor < v.length) v[anchor] = to;
      return ShapeFit.polyline(fit.kind, v, fit.confidence);
    case ShapeKind.circle:
      final r = (to - fit.center).distance;
      return ShapeFit.ellipse(
          center: fit.center,
          rx: r,
          ry: r,
          rotation: 0,
          confidence: fit.confidence,
          circle: true);
    case ShapeKind.ellipse:
      final d = to - fit.center;
      final majx = math.cos(fit.rotation), majy = math.sin(fit.rotation);
      if (anchor < 2) {
        final r = (d.dx * majx + d.dy * majy).abs();
        return ShapeFit.ellipse(
            center: fit.center,
            rx: r,
            ry: fit.ry,
            rotation: fit.rotation,
            confidence: fit.confidence);
      }
      final r = (d.dx * -majy + d.dy * majx).abs();
      return ShapeFit.ellipse(
          center: fit.center,
          rx: fit.rx,
          ry: r,
          rotation: fit.rotation,
          confidence: fit.confidence);
    case ShapeKind.curve:
      final c = [...fit.controlPoints];
      if (c.isNotEmpty) c[anchor == 0 ? 0 : c.length - 1] = to;
      return ShapeFit.curve(c, fit.confidence);
  }
}

List<Offset> _ellipseExtrema(ShapeFit f) {
  final cosR = math.cos(f.rotation), sinR = math.sin(f.rotation);
  Offset ext(double ax, double ay) => Offset(
      f.center.dx + ax * cosR - ay * sinR, f.center.dy + ax * sinR + ay * cosR);
  return [ext(f.rx, 0), ext(-f.rx, 0), ext(0, f.ry), ext(0, -f.ry)];
}

// ── Point generation ─────────────────────────────────────────────────────────

/// Emits render-ready [StrokePoint]s for [fit]: ~[ShapeTuning.emitSpacing]-pt
/// spacing on edges/arcs, constant pressure 0.5, and a tight neighbour cluster
/// at each polygon corner so both the input streamlining and the outline
/// smoothing pin the vertex (see SHAPES_PLAN §1.5).
List<StrokePoint> pointsForShape(ShapeFit fit) {
  switch (fit.kind) {
    case ShapeKind.circle:
    case ShapeKind.ellipse:
      return _ellipsePoints(fit);
    case ShapeKind.line:
    case ShapeKind.arrow:
      return _polylinePoints(fit.vertices, closed: false);
    case ShapeKind.triangle:
    case ShapeKind.rectangle:
    case ShapeKind.polygon:
      return _polylinePoints(fit.vertices, closed: true);
    case ShapeKind.curve:
      return _curvePoints(fit.controlPoints);
  }
}

List<StrokePoint> _ellipsePoints(ShapeFit fit) {
  final out = <StrokePoint>[];
  final cosR = math.cos(fit.rotation), sinR = math.sin(fit.rotation);
  final n = ShapeTuning.ellipseSamples;
  // Retrace past 2π by ~seam-overlap arc so the loop closes seamlessly.
  final rMean = (fit.rx + fit.ry) / 2;
  final overlapSteps = rMean <= 0
      ? 2
      : math.max(2, (ShapeTuning.closedSeamOverlap / rMean / (2 * math.pi) * n)
          .ceil());
  for (var i = 0; i <= n + overlapSteps; i++) {
    final t = (i / n) * 2 * math.pi;
    final x = fit.rx * math.cos(t);
    final y = fit.ry * math.sin(t);
    out.add(StrokePoint(
      fit.center.dx + x * cosR - y * sinR,
      fit.center.dy + x * sinR + y * cosR,
      0.5,
    ));
  }
  return out;
}

List<StrokePoint> _polylinePoints(List<Offset> verts, {required bool closed}) {
  final out = <StrokePoint>[];
  if (verts.isEmpty) return out;
  final path = closed ? [...verts, verts.first] : verts;
  for (var e = 0; e < path.length - 1; e++) {
    final a = path[e];
    final b = path[e + 1];
    // Pin the outgoing corner with a tight inset neighbour.
    if (e > 0) {
      _addCornerCluster(out, a, prev: path[e - 1], next: b);
    } else {
      out.add(StrokePoint(a.dx, a.dy, 0.5));
    }
    _addEdgeSamples(out, a, b);
  }
  // Closing vertex.
  final last = path.last;
  if (closed) {
    _addCornerCluster(out, last, prev: path[path.length - 2], next: path[1]);
    // Retrace a short way onto the first edge so the end cap overlaps the
    // start cap — otherwise the loop shows a seam/gap at the first vertex.
    final o0 = verts.first, o1 = verts.length > 1 ? verts[1] : verts.first;
    final d = (o1 - o0).distance;
    if (d > 0) {
      final overlap = math.min(d, ShapeTuning.closedSeamOverlap);
      final steps = math.max(1, (overlap / ShapeTuning.emitSpacing).ceil());
      for (var s = 1; s <= steps; s++) {
        final t = (s / steps) * (overlap / d);
        out.add(StrokePoint(
            o0.dx + (o1.dx - o0.dx) * t, o0.dy + (o1.dy - o0.dy) * t, 0.5));
      }
    }
  } else {
    out.add(StrokePoint(last.dx, last.dy, 0.5));
  }
  return out;
}

void _addEdgeSamples(List<StrokePoint> out, Offset a, Offset b) {
  final d = (b - a).distance;
  final steps = math.max(1, (d / ShapeTuning.emitSpacing).floor());
  for (var s = 1; s < steps; s++) {
    final t = s / steps;
    out.add(StrokePoint(
        a.dx + (b.dx - a.dx) * t, a.dy + (b.dy - a.dy) * t, 0.5));
  }
}

void _addCornerCluster(List<StrokePoint> out, Offset corner,
    {required Offset prev, required Offset next}) {
  final inset = ShapeTuning.cornerClusterInset;
  final fromPrev = _towards(corner, prev, inset);
  final toNext = _towards(corner, next, inset);
  out.add(StrokePoint(fromPrev.dx, fromPrev.dy, 0.5));
  out.add(StrokePoint(corner.dx, corner.dy, 0.5));
  out.add(StrokePoint(toNext.dx, toNext.dy, 0.5));
}

List<StrokePoint> _curvePoints(List<Offset> ctrl) {
  if (ctrl.length < 2) {
    return [for (final p in ctrl) StrokePoint(p.dx, p.dy, 0.5)];
  }
  final out = <StrokePoint>[StrokePoint(ctrl.first.dx, ctrl.first.dy, 0.5)];
  for (var i = 0; i < ctrl.length - 1; i++) {
    final p0 = ctrl[i == 0 ? 0 : i - 1];
    final p1 = ctrl[i];
    final p2 = ctrl[i + 1];
    final p3 = ctrl[i + 2 < ctrl.length ? i + 2 : ctrl.length - 1];
    final segLen = (p2 - p1).distance;
    final steps = math.max(2, (segLen / ShapeTuning.emitSpacing).round());
    for (var s = 1; s <= steps; s++) {
      final t = s / steps;
      out.add(_catmullRom(p0, p1, p2, p3, t));
    }
  }
  return out;
}

StrokePoint _catmullRom(Offset p0, Offset p1, Offset p2, Offset p3, double t) {
  final t2 = t * t, t3 = t2 * t;
  double c(double a, double b, double cc, double d) =>
      0.5 *
      ((2 * b) +
          (-a + cc) * t +
          (2 * a - 5 * b + 4 * cc - d) * t2 +
          (-a + 3 * b - 3 * cc + d) * t3);
  return StrokePoint(
      c(p0.dx, p1.dx, p2.dx, p3.dx), c(p0.dy, p1.dy, p2.dy, p3.dy), 0.5);
}

// ── Geometry helpers ─────────────────────────────────────────────────────────

double _pathLength(List<Offset> pts) {
  var total = 0.0;
  for (var i = 1; i < pts.length; i++) {
    total += (pts[i] - pts[i - 1]).distance;
  }
  return total;
}

List<Offset> _resample(List<Offset> pts, int n) {
  final total = _pathLength(pts);
  if (total == 0) return List.filled(n, pts.first);
  final interval = total / (n - 1);
  final out = <Offset>[pts.first];
  var prev = pts.first;
  var i = 1;
  var acc = 0.0;
  while (i < pts.length && out.length < n) {
    final next = pts[i];
    final seg = (next - prev).distance;
    if (seg <= 0) {
      i++;
      continue;
    }
    if (acc + seg >= interval) {
      final t = (interval - acc) / seg;
      final np = Offset(
          prev.dx + (next.dx - prev.dx) * t, prev.dy + (next.dy - prev.dy) * t);
      out.add(np);
      prev = np;
      acc = 0;
    } else {
      acc += seg;
      prev = next;
      i++;
    }
  }
  while (out.length < n) {
    out.add(pts.last);
  }
  return out;
}

Offset _centroid(List<Offset> pts) {
  var x = 0.0, y = 0.0;
  for (final p in pts) {
    x += p.dx;
    y += p.dy;
  }
  return Offset(x / pts.length, y / pts.length);
}

/// Turning angle (0 = straight, up to π) at [b] using neighbours [a] and [c].
double _turnAngle(Offset a, Offset b, Offset c) {
  final v1 = b - a, v2 = c - b;
  final l1 = v1.distance, l2 = v2.distance;
  if (l1 == 0 || l2 == 0) return 0;
  final cos = ((v1.dx * v2.dx + v1.dy * v2.dy) / (l1 * l2)).clamp(-1.0, 1.0);
  return math.acos(cos);
}

/// Indices of sharp corners on the resampled polyline (wraparound when closed).
List<int> _detectCorners(List<Offset> rs, bool closed) {
  final n = rs.length;
  final k = math.max(2, (n * ShapeTuning.cornerWindowFrac).round());
  final thresh = ShapeTuning.cornerAngleDeg * _deg;
  final angles = List<double>.filled(n, 0);
  for (var i = 0; i < n; i++) {
    if (!closed && (i < k || i >= n - k)) continue;
    final a = rs[(i - k + n) % n];
    final b = rs[i];
    final c = rs[(i + k) % n];
    angles[i] = _turnAngle(a, b, c);
  }
  final corners = <int>[];
  for (var i = 0; i < n; i++) {
    if (angles[i] < thresh) continue;
    var isMax = true;
    for (var j = -k; j <= k; j++) {
      final idx = closed ? (i + j + n) % n : i + j;
      if (idx < 0 || idx >= n) continue;
      if (angles[idx] > angles[i]) {
        isMax = false;
        break;
      }
    }
    if (isMax) corners.add(i);
  }
  return corners;
}

double _distToSegment(Offset p, Offset a, Offset b) {
  final ab = b - a;
  final len2 = ab.dx * ab.dx + ab.dy * ab.dy;
  if (len2 == 0) return (p - a).distance;
  var t = ((p.dx - a.dx) * ab.dx + (p.dy - a.dy) * ab.dy) / len2;
  t = t.clamp(0.0, 1.0);
  final proj = Offset(a.dx + ab.dx * t, a.dy + ab.dy * t);
  return (p - proj).distance;
}

/// Mean distance of each point in [rs] to the nearest edge of the closed
/// polygon [verts].
double _closedPolyFitError(List<Offset> rs, List<Offset> verts) {
  final edges = [...verts, verts.first];
  var sum = 0.0;
  for (final p in rs) {
    var best = double.infinity;
    for (var e = 0; e < edges.length - 1; e++) {
      final d = _distToSegment(p, edges[e], edges[e + 1]);
      if (d < best) best = d;
    }
    sum += best;
  }
  return sum / rs.length;
}

/// Snaps a line's direction to the nearest [ShapeTuning.lineAngleSnapDeg]-close
/// multiple of 45°, rotating [b] about [a] and keeping the length.
List<Offset> _snapLineAngle(Offset a, Offset b) {
  final v = b - a;
  final ang = math.atan2(v.dy, v.dx);
  const step = math.pi / 4;
  final nearest = (ang / step).round() * step;
  if ((ang - nearest).abs() <= ShapeTuning.lineAngleSnapDeg * _deg) {
    final len = v.distance;
    return [a, Offset(a.dx + len * math.cos(nearest), a.dy + len * math.sin(nearest))];
  }
  return [a, b];
}

/// If all four edges of a quad are within [ShapeTuning.rectEdgeAxisSnapDeg] of
/// the page axes, replace it with its axis-aligned bounding rectangle.
List<Offset> _maybeAxisAlign(List<Offset> verts) {
  final edges = [...verts, verts.first];
  for (var e = 0; e < edges.length - 1; e++) {
    final v = edges[e + 1] - edges[e];
    final ang = math.atan2(v.dy, v.dx).abs();
    final toAxis = math.min(
      math.min(ang, (math.pi - ang).abs()),
      (ang - math.pi / 2).abs(),
    );
    if (toAxis > ShapeTuning.rectEdgeAxisSnapDeg * _deg) return verts;
  }
  var minX = verts.first.dx, maxX = verts.first.dx;
  var minY = verts.first.dy, maxY = verts.first.dy;
  for (final p in verts) {
    minX = math.min(minX, p.dx);
    maxX = math.max(maxX, p.dx);
    minY = math.min(minY, p.dy);
    maxY = math.max(maxY, p.dy);
  }
  return [
    Offset(minX, minY),
    Offset(maxX, minY),
    Offset(maxX, maxY),
    Offset(minX, maxY),
  ];
}

/// If the polygon's edges and radii are near-uniform, snap it to a regular
/// N-gon (same centroid, mean radius, evenly spaced from the first vertex).
List<Offset> _maybeRegularize(List<Offset> verts) {
  final c = _centroid(verts);
  final radii = [for (final v in verts) (v - c).distance];
  final mean = radii.reduce((a, b) => a + b) / radii.length;
  if (mean <= 0) return verts;
  var maxDev = 0.0;
  for (final r in radii) {
    maxDev = math.max(maxDev, (r - mean).abs() / mean);
  }
  if (maxDev > ShapeTuning.polygonFitTolFrac * 3) return verts;
  final start = math.atan2(verts.first.dy - c.dy, verts.first.dx - c.dx);
  final n = verts.length;
  return [
    for (var i = 0; i < n; i++)
      Offset(
        c.dx + mean * math.cos(start + i * 2 * math.pi / n),
        c.dy + mean * math.sin(start + i * 2 * math.pi / n),
      )
  ];
}

/// Ramer–Douglas–Peucker decimation with tolerance [eps].
List<Offset> _rdp(List<Offset> pts, double eps) {
  if (pts.length < 3) return List.of(pts);
  var maxD = 0.0;
  var idx = 0;
  for (var i = 1; i < pts.length - 1; i++) {
    final d = _distToSegment(pts[i], pts.first, pts.last);
    if (d > maxD) {
      maxD = d;
      idx = i;
    }
  }
  if (maxD <= eps) return [pts.first, pts.last];
  final left = _rdp(pts.sublist(0, idx + 1), eps);
  final right = _rdp(pts.sublist(idx), eps);
  return [...left.sublist(0, left.length - 1), ...right];
}

/// True if the polyline crosses itself away from its endpoints. Segment pairs
/// where one segment is within [margin] of the path start *and* the other is
/// within [margin] of the end are ignored, so a closed shape's own closure
/// overlap doesn't count — only genuine interior crossings (scribbles) do.
bool _selfIntersectsInterior(List<Offset> pts, int margin) {
  final n = pts.length;
  for (var i = 0; i < n - 1; i++) {
    for (var j = i + 2; j < n - 1; j++) {
      final closureOverlap = i < margin && j >= n - 1 - margin;
      if (closureOverlap) continue;
      if (_segmentsCross(pts[i], pts[i + 1], pts[j], pts[j + 1])) return true;
    }
  }
  return false;
}

bool _segmentsCross(Offset a, Offset b, Offset c, Offset d) {
  double cross(Offset o, Offset p, Offset q) =>
      (p.dx - o.dx) * (q.dy - o.dy) - (p.dy - o.dy) * (q.dx - o.dx);
  final d1 = cross(c, d, a);
  final d2 = cross(c, d, b);
  final d3 = cross(a, b, c);
  final d4 = cross(a, b, d);
  return ((d1 > 0) != (d2 > 0)) && ((d3 > 0) != (d4 > 0));
}

Offset _towards(Offset from, Offset to, double dist) {
  final v = to - from;
  final l = v.distance;
  if (l == 0) return from;
  return Offset(from.dx + v.dx / l * dist, from.dy + v.dy / l * dist);
}
