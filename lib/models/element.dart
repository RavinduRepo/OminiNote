import 'dart:math' as math;
import 'dart:ui';

int _idSeq = 0;

/// Generates a unique id: creation time + an in-process sequence number, so
/// two elements created in the same microsecond still get distinct ids.
String newModelId(String prefix) =>
    '${prefix}_${DateTime.now().microsecondsSinceEpoch}_${_idSeq++}';

/// A single input point of a stroke, in page-local PDF points.
/// `p` is stylus pressure 0..1 (0.5 when unknown).
class StrokePoint {
  double x;
  double y;
  double p;

  StrokePoint(this.x, this.y, this.p);

  Map<String, dynamic> toJson() => {'x': x, 'y': y, 'p': p};

  factory StrokePoint.fromJson(Map<String, dynamic> json) => StrokePoint(
    (json['x'] as num?)?.toDouble() ?? 0.0,
    (json['y'] as num?)?.toDouble() ?? 0.0,
    (json['p'] as num?)?.toDouble() ?? 0.5,
  );
}

/// Base of everything that can sit on a page. Position/geometry are stored in
/// page-local PDF points (1pt = 1/72"), so export maps 1:1 onto PDF space.
///
/// Elements are deliberately mutable: selection transforms mutate them live
/// during a drag, and the undo system snapshots deep copies around each
/// operation instead of requiring immutability.
sealed class CanvasElement {
  String id;

  CanvasElement({required this.id});

  /// Axis-aligned bounds in page-local points (rotation ignored — used for
  /// selection bboxes and culling, where approximate is fine).
  Rect get bounds;

  /// Deep copy. Keeps the id by default (undo snapshots); pass [withNewId]
  /// for duplicate/paste.
  CanvasElement deepCopy({bool withNewId = false});

  void translate(double dx, double dy);

  /// Uniform scale about [anchor].
  void scaleBy(double factor, Offset anchor);

  /// Rotate by [angle] radians about [pivot].
  void rotateBy(double angle, Offset pivot);

  Map<String, dynamic> toJson();

  static CanvasElement fromJson(Map<String, dynamic> json) {
    switch (json['type']) {
      case 'stroke':
        return StrokeElement.fromJson(json);
      case 'text':
        return TextElement.fromJson(json);
      case 'image':
        return ImageElement.fromJson(json);
      default:
        throw FormatException('Unknown element type: ${json['type']}');
    }
  }
}

enum StrokeTool { pen, highlighter }

class StrokeElement extends CanvasElement {
  StrokeTool tool;
  Color color;

  /// Nominal stroke width in points (perfect_freehand `size`).
  double size;
  List<StrokePoint> points;

  /// Cached rendered outline; invalidated whenever geometry changes.
  Path? cachedOutline;

  StrokeElement({
    required super.id,
    required this.tool,
    required this.color,
    required this.size,
    required this.points,
  });

  void invalidateCache() => cachedOutline = null;

  @override
  Rect get bounds {
    if (points.isEmpty) return Rect.zero;
    var minX = points.first.x, maxX = points.first.x;
    var minY = points.first.y, maxY = points.first.y;
    for (final p in points) {
      if (p.x < minX) minX = p.x;
      if (p.x > maxX) maxX = p.x;
      if (p.y < minY) minY = p.y;
      if (p.y > maxY) maxY = p.y;
    }
    final pad = size;
    return Rect.fromLTRB(minX - pad, minY - pad, maxX + pad, maxY + pad);
  }

  @override
  StrokeElement deepCopy({bool withNewId = false}) => StrokeElement(
    id: withNewId ? newModelId('el') : id,
    tool: tool,
    color: color,
    size: size,
    points: points.map((p) => StrokePoint(p.x, p.y, p.p)).toList(),
  );

  @override
  void translate(double dx, double dy) {
    for (final p in points) {
      p.x += dx;
      p.y += dy;
    }
    invalidateCache();
  }

  @override
  void scaleBy(double factor, Offset anchor) {
    for (final p in points) {
      p.x = anchor.dx + (p.x - anchor.dx) * factor;
      p.y = anchor.dy + (p.y - anchor.dy) * factor;
    }
    size *= factor;
    invalidateCache();
  }

  @override
  void rotateBy(double angle, Offset pivot) {
    final cosA = math.cos(angle), sinA = math.sin(angle);
    for (final p in points) {
      final dx = p.x - pivot.dx, dy = p.y - pivot.dy;
      p.x = pivot.dx + dx * cosA - dy * sinA;
      p.y = pivot.dy + dx * sinA + dy * cosA;
    }
    invalidateCache();
  }

  @override
  Map<String, dynamic> toJson() => {
    'type': 'stroke',
    'id': id,
    'tool': tool.name,
    'color': color.toARGB32(),
    'size': size,
    'points': points.map((p) => p.toJson()).toList(),
  };

  factory StrokeElement.fromJson(Map<String, dynamic> json) => StrokeElement(
    id: json['id'] ?? newModelId('el'),
    tool: StrokeTool.values.firstWhere(
      (t) => t.name == json['tool'],
      orElse: () => StrokeTool.pen,
    ),
    color: Color(json['color'] ?? 0xFF000000),
    size: (json['size'] as num?)?.toDouble() ?? 4.0,
    points: List<Map<String, dynamic>>.from(
      json['points'] ?? [],
    ).map(StrokePoint.fromJson).toList(),
  );
}

enum TextAlignOption { left, center, right }

/// A contiguous span of text sharing one style. A [TextElement]'s content is
/// an ordered list of these, so different parts of one box can be styled
/// independently (bold/italic/size/color/family per range).
class TextRun {
  String text;
  double fontSize;
  bool bold;
  bool italic;
  Color color;

  /// 'sans' | 'serif' | 'mono'.
  String fontFamily;

  TextRun({
    required this.text,
    required this.fontSize,
    required this.bold,
    required this.italic,
    required this.color,
    required this.fontFamily,
  });

  TextRun clone() => TextRun(
    text: text,
    fontSize: fontSize,
    bold: bold,
    italic: italic,
    color: color,
    fontFamily: fontFamily,
  );

  Map<String, dynamic> toJson() => {
    't': text,
    's': fontSize,
    'b': bold,
    'i': italic,
    'c': color.toARGB32(),
    'f': fontFamily,
  };

  factory TextRun.fromJson(Map<String, dynamic> j) => TextRun(
    text: j['t'] ?? '',
    fontSize: (j['s'] as num?)?.toDouble() ?? 16,
    bold: j['b'] ?? false,
    italic: j['i'] ?? false,
    color: Color(j['c'] ?? 0xFF000000),
    fontFamily: j['f'] ?? 'sans',
  );
}

class TextElement extends CanvasElement {
  Rect rect;

  /// Radians, about the rect center.
  double rotation;

  /// Styled content runs (z-order-free; concatenated left-to-right).
  List<TextRun> runs;

  /// Paragraph alignment (whole box).
  TextAlignOption align;

  // Default/baseline style — used for a new empty box, as the toolbar's
  // starting style, and as a fallback when [runs] is empty.
  String fontFamily;
  double fontSize;
  Color color;
  bool bold;
  bool italic;

  TextElement({
    required super.id,
    required this.rect,
    this.rotation = 0,
    String text = '',
    List<TextRun>? runs,
    this.fontFamily = 'sans',
    this.fontSize = 16,
    required this.color,
    this.bold = false,
    this.italic = false,
    this.align = TextAlignOption.left,
  }) : runs =
           runs ??
           (text.isEmpty
               ? <TextRun>[]
               : [
                   TextRun(
                     text: text,
                     fontSize: fontSize,
                     bold: bold,
                     italic: italic,
                     color: color,
                     fontFamily: fontFamily,
                   ),
                 ]);

  /// The plain concatenated text of all runs.
  String get text => runs.map((r) => r.text).join();

  @override
  Rect get bounds => rect;

  @override
  TextElement deepCopy({bool withNewId = false}) => TextElement(
    id: withNewId ? newModelId('el') : id,
    rect: rect,
    rotation: rotation,
    runs: [for (final r in runs) r.clone()],
    fontFamily: fontFamily,
    fontSize: fontSize,
    color: color,
    bold: bold,
    italic: italic,
    align: align,
  );

  @override
  void translate(double dx, double dy) => rect = rect.shift(Offset(dx, dy));

  /// Text intentionally ignores box scaling: the box auto-sizes to its content
  /// and font size is changed only via the text controls (spec: "resizing the
  /// box should not change the text size"). Only the top-left anchor follows a
  /// group scale so text keeps its relative position.
  @override
  void scaleBy(double factor, Offset anchor) {
    rect = Rect.fromLTWH(
      anchor.dx + (rect.left - anchor.dx) * factor,
      anchor.dy + (rect.top - anchor.dy) * factor,
      rect.width,
      rect.height,
    );
  }

  @override
  void rotateBy(double angle, Offset pivot) {
    rotation += angle;
    final c = rect.center;
    final dx = c.dx - pivot.dx, dy = c.dy - pivot.dy;
    final cosA = math.cos(angle), sinA = math.sin(angle);
    final nc = Offset(
      pivot.dx + dx * cosA - dy * sinA,
      pivot.dy + dx * sinA + dy * cosA,
    );
    rect = Rect.fromCenter(center: nc, width: rect.width, height: rect.height);
  }

  @override
  Map<String, dynamic> toJson() => {
    'type': 'text',
    'id': id,
    'rect': {'x': rect.left, 'y': rect.top, 'w': rect.width, 'h': rect.height},
    'rotation': rotation,
    'runs': [for (final r in runs) r.toJson()],
    // Baseline style, kept for the toolbar/new text and as a fallback.
    'fontFamily': fontFamily,
    'fontSize': fontSize,
    'color': color.toARGB32(),
    'bold': bold,
    'italic': italic,
    'align': align.name,
  };

  factory TextElement.fromJson(Map<String, dynamic> json) {
    final r = json['rect'] as Map<String, dynamic>? ?? {};
    final runsJson = json['runs'] as List?;
    return TextElement(
      id: json['id'] ?? newModelId('el'),
      rect: Rect.fromLTWH(
        (r['x'] as num?)?.toDouble() ?? 0,
        (r['y'] as num?)?.toDouble() ?? 0,
        (r['w'] as num?)?.toDouble() ?? 100,
        (r['h'] as num?)?.toDouble() ?? 40,
      ),
      rotation: (json['rotation'] as num?)?.toDouble() ?? 0,
      // New format: styled runs. Legacy: a single 'text' + flat style.
      runs: runsJson != null
          ? [
              for (final e in runsJson)
                TextRun.fromJson(e as Map<String, dynamic>),
            ]
          : null,
      text: runsJson == null ? (json['text'] ?? '') : '',
      fontFamily: json['fontFamily'] ?? 'sans',
      fontSize: (json['fontSize'] as num?)?.toDouble() ?? 16,
      color: Color(json['color'] ?? 0xFF000000),
      bold: json['bold'] ?? false,
      italic: json['italic'] ?? false,
      align: TextAlignOption.values.firstWhere(
        (a) => a.name == json['align'],
        orElse: () => TextAlignOption.left,
      ),
    );
  }
}

class ImageElement extends CanvasElement {
  Rect rect;

  /// Radians, about the rect center.
  double rotation;

  /// Content-addressed asset reference (file in the section's assets dir).
  String assetId;

  ImageElement({
    required super.id,
    required this.rect,
    this.rotation = 0,
    required this.assetId,
  });

  @override
  Rect get bounds => rect;

  @override
  ImageElement deepCopy({bool withNewId = false}) => ImageElement(
    id: withNewId ? newModelId('el') : id,
    rect: rect,
    rotation: rotation,
    assetId: assetId,
  );

  @override
  void translate(double dx, double dy) => rect = rect.shift(Offset(dx, dy));

  @override
  void scaleBy(double factor, Offset anchor) {
    rect = Rect.fromLTWH(
      anchor.dx + (rect.left - anchor.dx) * factor,
      anchor.dy + (rect.top - anchor.dy) * factor,
      rect.width * factor,
      rect.height * factor,
    );
  }

  @override
  void rotateBy(double angle, Offset pivot) {
    rotation += angle;
    final c = rect.center;
    final dx = c.dx - pivot.dx, dy = c.dy - pivot.dy;
    final cosA = math.cos(angle), sinA = math.sin(angle);
    final nc = Offset(
      pivot.dx + dx * cosA - dy * sinA,
      pivot.dy + dx * sinA + dy * cosA,
    );
    rect = Rect.fromCenter(center: nc, width: rect.width, height: rect.height);
  }

  @override
  Map<String, dynamic> toJson() => {
    'type': 'image',
    'id': id,
    'rect': {'x': rect.left, 'y': rect.top, 'w': rect.width, 'h': rect.height},
    'rotation': rotation,
    'assetId': assetId,
  };

  factory ImageElement.fromJson(Map<String, dynamic> json) {
    final r = json['rect'] as Map<String, dynamic>? ?? {};
    return ImageElement(
      id: json['id'] ?? newModelId('el'),
      rect: Rect.fromLTWH(
        (r['x'] as num?)?.toDouble() ?? 0,
        (r['y'] as num?)?.toDouble() ?? 0,
        (r['w'] as num?)?.toDouble() ?? 100,
        (r['h'] as num?)?.toDouble() ?? 100,
      ),
      rotation: (json['rotation'] as num?)?.toDouble() ?? 0,
      assetId: json['assetId'] ?? '',
    );
  }
}
