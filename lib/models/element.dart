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
  final int schemaVersion;
  String id;
  int rev;
  DateTime updatedAt;
  String deviceId;
  DateTime? deletedAt;

  /// Cross-list paint order. Strokes and objects live in separate lists (the
  /// sync model needs that), so without this an image could never go behind
  /// ink — the painter/exporter draw the combined list stable-sorted by
  /// [zIndex] (ties keep strokes-under-objects list order). Mutated by
  /// bring-to-front / send-to-back; syncs like any other element property.
  double zIndex = 0;

  CanvasElement({
    this.schemaVersion = 1,
    required this.id,
    this.rev = 1,
    DateTime? updatedAt,
    required this.deviceId,
    this.deletedAt,
  }) : updatedAt = updatedAt ?? DateTime.now();

  void bumpRev(String newDeviceId) {
    rev += 1;
    updatedAt = DateTime.now();
    deviceId = newDeviceId;
  }

  /// Axis-aligned bounds in page-local points (rotation ignored — used for
  /// selection bboxes and culling, where approximate is fine).
  Rect get bounds;

  /// Deep copy. Keeps the id by default (undo snapshots); pass [withNewId]
  /// for duplicate/paste.
  CanvasElement deepCopy({bool withNewId = false});

  void translate(double dx, double dy);

  /// Uniform scale about [anchor].
  void scaleBy(double factor, Offset anchor);

  /// Non-uniform scale about [anchor] by [sx] horizontally and [sy] vertically
  /// (stretch/squash — the selection box's side handles). Strokes/images stretch
  /// per axis; text and attachments no-op (text width is handled by the wrap
  /// path in the controller, attachments keep their aspect).
  void scaleXY(double sx, double sy, Offset anchor);

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
      case 'attachment':
        return AttachmentElement.fromJson(json);
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

  final DateTime createdAt;
  String z; // fractional index for draw order

  /// Cached rendered outline; invalidated whenever geometry changes.
  Path? cachedOutline;

  /// Cached point-bounding box (padded), invalidated with [cachedOutline].
  /// The eraser hit-scan pre-filters on this, so recomputing it per pointer
  /// move over every committed stroke would defeat the point of the filter.
  Rect? _cachedBounds;

  StrokeElement({
    int schemaVersion = 1,
    required super.id,
    int rev = 1,
    DateTime? updatedAt,
    required super.deviceId,
    DateTime? deletedAt,
    DateTime? createdAt,
    required this.z,
    required this.tool,
    required this.color,
    required this.size,
    required this.points,
  }) : createdAt = createdAt ?? DateTime.now(),
       super(
         schemaVersion: schemaVersion,
         rev: rev,
         updatedAt: updatedAt,
         deletedAt: deletedAt,
       );

  void invalidateCache() {
    cachedOutline = null;
    _cachedBounds = null;
  }

  @override
  Rect get bounds {
    final cached = _cachedBounds;
    if (cached != null) return cached;
    if (points.isEmpty) return Rect.zero; // degenerate; don't cache
    var minX = points.first.x, maxX = points.first.x;
    var minY = points.first.y, maxY = points.first.y;
    for (final p in points) {
      if (p.x < minX) minX = p.x;
      if (p.x > maxX) maxX = p.x;
      if (p.y < minY) minY = p.y;
      if (p.y > maxY) maxY = p.y;
    }
    final pad = size;
    return _cachedBounds =
        Rect.fromLTRB(minX - pad, minY - pad, maxX + pad, maxY + pad);
  }

  @override
  StrokeElement deepCopy({bool withNewId = false}) => StrokeElement(
    schemaVersion: schemaVersion,
    id: withNewId ? newModelId('el') : id,
    rev: rev,
    updatedAt: updatedAt,
    deviceId: deviceId,
    deletedAt: deletedAt,
    createdAt: createdAt,
    z: z,
    tool: tool,
    color: color,
    size: size,
    points: points.map((p) => StrokePoint(p.x, p.y, p.p)).toList(),
  )..zIndex = zIndex;

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
  void scaleXY(double sx, double sy, Offset anchor) {
    for (final p in points) {
      p.x = anchor.dx + (p.x - anchor.dx) * sx;
      p.y = anchor.dy + (p.y - anchor.dy) * sy;
    }
    // Strokes carry a single scalar width; use the geometric mean so a uniform
    // stretch matches scaleBy and a one-axis stretch nudges it modestly.
    size *= math.sqrt(sx.abs() * sy.abs());
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
    'schemaVersion': schemaVersion,
    'type': 'stroke',
    'id': id,
    'rev': rev,
    'updatedAt': updatedAt.millisecondsSinceEpoch,
    'deviceId': deviceId,
    'deletedAt': deletedAt?.millisecondsSinceEpoch,
    'zi': zIndex,
    'createdAt': createdAt.millisecondsSinceEpoch,
    'z': z,
    'tool': tool.name,
    'color': color.toARGB32(),
    'size': size,
    'points': points.map((p) => p.toJson()).toList(),
  };

  factory StrokeElement.fromJson(Map<String, dynamic> json) => StrokeElement(
    schemaVersion: json['schemaVersion'] ?? 1,
    id: json['id'] ?? newModelId('el'),
    rev: json['rev'] ?? 1,
    updatedAt: json['updatedAt'] != null
        ? DateTime.fromMillisecondsSinceEpoch(json['updatedAt'])
        : null,
    deviceId: json['deviceId'] ?? 'unknown',
    deletedAt: json['deletedAt'] != null
        ? DateTime.fromMillisecondsSinceEpoch(json['deletedAt'])
        : null,
    createdAt: json['createdAt'] != null
        ? DateTime.fromMillisecondsSinceEpoch(json['createdAt'])
        : DateTime.now(),
    z: json['z'] ?? '0|a0:',
    tool: StrokeTool.values.firstWhere(
      (t) => t.name == json['tool'],
      orElse: () => StrokeTool.pen,
    ),
    color: Color(json['color'] ?? 0xFF000000),
    size: (json['size'] as num?)?.toDouble() ?? 4.0,
    points: List<Map<String, dynamic>>.from(
      json['points'] ?? [],
    ).map(StrokePoint.fromJson).toList(),
  )..zIndex = (json['zi'] as num?)?.toDouble() ?? 0;
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

  /// When set, this run is a hyperlink to this (normalized) URL — rendered
  /// underlined in a link color and tappable. Auto-detected from the text.
  String? link;

  TextRun({
    required this.text,
    required this.fontSize,
    required this.bold,
    required this.italic,
    required this.color,
    required this.fontFamily,
    this.link,
  });

  TextRun clone() => TextRun(
    text: text,
    fontSize: fontSize,
    bold: bold,
    italic: italic,
    color: color,
    fontFamily: fontFamily,
    link: link,
  );

  Map<String, dynamic> toJson() => {
    't': text,
    's': fontSize,
    'b': bold,
    'i': italic,
    'c': color.toARGB32(),
    'f': fontFamily,
    if (link != null) 'l': link,
  };

  factory TextRun.fromJson(Map<String, dynamic> j) => TextRun(
    text: j['t'] ?? '',
    fontSize: (j['s'] as num?)?.toDouble() ?? 16,
    bold: j['b'] ?? false,
    italic: j['i'] ?? false,
    color: Color(j['c'] ?? 0xFF000000),
    fontFamily: j['f'] ?? 'sans',
    link: j['l'] as String?,
  );
}

class TextElement extends CanvasElement {
  Rect rect;

  /// Radians, about the rect center.
  double rotation;

  /// Styled content runs (z-order-free; concatenated left-to-right).
  List<TextRun> runs;

  /// Shared id linking the continuation boxes of one long pasted text that
  /// was split across pages, so "cut/delete all parts" can find its siblings.
  /// Null for ordinary boxes.
  String? linkId;

  /// Paragraph alignment (whole box).
  TextAlignOption align;

  /// User-set wrap width (from a resize drag). When null the box auto-sizes to
  /// its content; when set the box wraps text at this width and only its height
  /// follows the content. Resizing never changes the font size.
  double? manualWidth;

  // Default/baseline style — used for a new empty box, as the toolbar's
  // starting style, and as a fallback when [runs] is empty.
  String fontFamily;
  double fontSize;
  Color color;
  bool bold;
  bool italic;

  TextElement({
    int schemaVersion = 1,
    required super.id,
    int rev = 1,
    DateTime? updatedAt,
    required super.deviceId,
    DateTime? deletedAt,
    required this.rect,
    this.rotation = 0,
    String text = '',
    List<TextRun>? runs,
    this.linkId,
    this.fontFamily = 'sans',
    this.fontSize = 16,
    required this.color,
    this.bold = false,
    this.italic = false,
    this.align = TextAlignOption.left,
    this.manualWidth,
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
                 ]),
       super(
         schemaVersion: schemaVersion,
         rev: rev,
         updatedAt: updatedAt,
         deletedAt: deletedAt,
       );

  /// The plain concatenated text of all runs.
  String get text => runs.map((r) => r.text).join();

  @override
  Rect get bounds => rect;

  @override
  TextElement deepCopy({bool withNewId = false}) => TextElement(
    schemaVersion: schemaVersion,
    id: withNewId ? newModelId('el') : id,
    rev: rev,
    updatedAt: updatedAt,
    deviceId: deviceId,
    deletedAt: deletedAt,
    rect: rect,
    rotation: rotation,
    runs: [for (final r in runs) r.clone()],
    linkId: linkId,
    fontFamily: fontFamily,
    fontSize: fontSize,
    color: color,
    bold: bold,
    italic: italic,
    align: align,
    manualWidth: manualWidth,
  )..zIndex = zIndex;

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
  void scaleXY(double sx, double sy, Offset anchor) {
    // Text never scales its font by drag; horizontal wrap-width resize is
    // handled in the controller. Move the anchor-relative position only so a
    // text box caught in a mixed selection stretch travels with it.
    rect = Rect.fromLTWH(
      anchor.dx + (rect.left - anchor.dx) * sx,
      anchor.dy + (rect.top - anchor.dy) * sy,
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
    'schemaVersion': schemaVersion,
    'type': 'text',
    'id': id,
    'rev': rev,
    'updatedAt': updatedAt.millisecondsSinceEpoch,
    'deviceId': deviceId,
    'deletedAt': deletedAt?.millisecondsSinceEpoch,
    'zi': zIndex,
    'rect': {'x': rect.left, 'y': rect.top, 'w': rect.width, 'h': rect.height},
    'rotation': rotation,
    'runs': [for (final r in runs) r.toJson()],
    if (linkId != null) 'gid': linkId,
    // Baseline style, kept for the toolbar/new text and as a fallback.
    'fontFamily': fontFamily,
    'fontSize': fontSize,
    'color': color.toARGB32(),
    'bold': bold,
    'italic': italic,
    'align': align.name,
    if (manualWidth != null) 'mw': manualWidth,
  };

  factory TextElement.fromJson(Map<String, dynamic> json) {
    final r = json['rect'] as Map<String, dynamic>? ?? {};
    final runsJson = json['runs'] as List?;
    return TextElement(
      schemaVersion: json['schemaVersion'] ?? 1,
      id: json['id'] ?? newModelId('el'),
      rev: json['rev'] ?? 1,
      updatedAt: json['updatedAt'] != null
          ? DateTime.fromMillisecondsSinceEpoch(json['updatedAt'])
          : null,
      deviceId: json['deviceId'] ?? 'unknown',
      deletedAt: json['deletedAt'] != null
          ? DateTime.fromMillisecondsSinceEpoch(json['deletedAt'])
          : null,
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
      linkId: json['gid'] as String?,
      fontFamily: json['fontFamily'] ?? 'sans',
      fontSize: (json['fontSize'] as num?)?.toDouble() ?? 16,
      color: Color(json['color'] ?? 0xFF000000),
      bold: json['bold'] ?? false,
      italic: json['italic'] ?? false,
      align: TextAlignOption.values.firstWhere(
        (a) => a.name == json['align'],
        orElse: () => TextAlignOption.left,
      ),
      manualWidth: (json['mw'] as num?)?.toDouble(),
    )..zIndex = (json['zi'] as num?)?.toDouble() ?? 0;
  }
}

class ImageElement extends CanvasElement {
  Rect rect;

  /// Radians, about the rect center.
  double rotation;

  /// Content-addressed asset reference (file in the section's assets dir).
  String assetId;

  ImageElement({
    int schemaVersion = 1,
    required super.id,
    int rev = 1,
    DateTime? updatedAt,
    required super.deviceId,
    DateTime? deletedAt,
    required this.rect,
    this.rotation = 0,
    required this.assetId,
  }) : super(
         schemaVersion: schemaVersion,
         rev: rev,
         updatedAt: updatedAt,
         deletedAt: deletedAt,
       );

  @override
  Rect get bounds => rect;

  @override
  ImageElement deepCopy({bool withNewId = false}) => ImageElement(
    schemaVersion: schemaVersion,
    id: withNewId ? newModelId('el') : id,
    rev: rev,
    updatedAt: updatedAt,
    deviceId: deviceId,
    deletedAt: deletedAt,
    rect: rect,
    rotation: rotation,
    assetId: assetId,
  )..zIndex = zIndex;

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
  void scaleXY(double sx, double sy, Offset anchor) {
    rect = Rect.fromLTWH(
      anchor.dx + (rect.left - anchor.dx) * sx,
      anchor.dy + (rect.top - anchor.dy) * sy,
      rect.width * sx,
      rect.height * sy,
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
    'schemaVersion': schemaVersion,
    'type': 'image',
    'id': id,
    'rev': rev,
    'updatedAt': updatedAt.millisecondsSinceEpoch,
    'deviceId': deviceId,
    'deletedAt': deletedAt?.millisecondsSinceEpoch,
    'zi': zIndex,
    'rect': {'x': rect.left, 'y': rect.top, 'w': rect.width, 'h': rect.height},
    'rotation': rotation,
    'assetId': assetId,
  };

  factory ImageElement.fromJson(Map<String, dynamic> json) {
    final r = json['rect'] as Map<String, dynamic>? ?? {};
    return ImageElement(
      schemaVersion: json['schemaVersion'] ?? 1,
      id: json['id'] ?? newModelId('el'),
      rev: json['rev'] ?? 1,
      updatedAt: json['updatedAt'] != null
          ? DateTime.fromMillisecondsSinceEpoch(json['updatedAt'])
          : null,
      deviceId: json['deviceId'] ?? 'unknown',
      deletedAt: json['deletedAt'] != null
          ? DateTime.fromMillisecondsSinceEpoch(json['deletedAt'])
          : null,
      rect: Rect.fromLTWH(
        (r['x'] as num?)?.toDouble() ?? 0,
        (r['y'] as num?)?.toDouble() ?? 0,
        (r['w'] as num?)?.toDouble() ?? 100,
        (r['h'] as num?)?.toDouble() ?? 100,
      ),
      rotation: (json['rotation'] as num?)?.toDouble() ?? 0,
      assetId: json['assetId'] ?? '',
    )..zIndex = (json['zi'] as num?)?.toDouble() ?? 0;
  }
}

/// A visible "attached file" chip on the page: an icon + file name linking to
/// a stored asset (typically a PDF added "as attachment"). Tapping it in the
/// app opens the file; on export the chip is drawn and the file is embedded
/// in the output PDF as a document attachment.
class AttachmentElement extends CanvasElement {
  Rect rect;

  /// Radians, about the rect center.
  double rotation;

  /// Content-addressed asset reference (file in the canvas's assets dir).
  String assetId;

  /// Display name (original file name).
  String name;

  String mime;

  AttachmentElement({
    int schemaVersion = 1,
    required super.id,
    int rev = 1,
    DateTime? updatedAt,
    required super.deviceId,
    DateTime? deletedAt,
    required this.rect,
    this.rotation = 0,
    required this.assetId,
    required this.name,
    this.mime = 'application/pdf',
  }) : super(
         schemaVersion: schemaVersion,
         rev: rev,
         updatedAt: updatedAt,
         deletedAt: deletedAt,
       );

  @override
  Rect get bounds => rect;

  @override
  AttachmentElement deepCopy({bool withNewId = false}) => AttachmentElement(
    schemaVersion: schemaVersion,
    id: withNewId ? newModelId('el') : id,
    rev: rev,
    updatedAt: updatedAt,
    deviceId: deviceId,
    deletedAt: deletedAt,
    rect: rect,
    rotation: rotation,
    assetId: assetId,
    name: name,
    mime: mime,
  )..zIndex = zIndex;

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
  void scaleXY(double sx, double sy, Offset anchor) {
    // Attachment chips keep their aspect (move only, like a uniform anchor).
    rect = Rect.fromLTWH(
      anchor.dx + (rect.left - anchor.dx) * sx,
      anchor.dy + (rect.top - anchor.dy) * sy,
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
    'schemaVersion': schemaVersion,
    'type': 'attachment',
    'id': id,
    'rev': rev,
    'updatedAt': updatedAt.millisecondsSinceEpoch,
    'deviceId': deviceId,
    'deletedAt': deletedAt?.millisecondsSinceEpoch,
    'zi': zIndex,
    'rect': {'x': rect.left, 'y': rect.top, 'w': rect.width, 'h': rect.height},
    'rotation': rotation,
    'assetId': assetId,
    'name': name,
    'mime': mime,
  };

  factory AttachmentElement.fromJson(Map<String, dynamic> json) {
    final r = json['rect'] as Map<String, dynamic>? ?? {};
    return AttachmentElement(
      schemaVersion: json['schemaVersion'] ?? 1,
      id: json['id'] ?? newModelId('el'),
      rev: json['rev'] ?? 1,
      updatedAt: json['updatedAt'] != null
          ? DateTime.fromMillisecondsSinceEpoch(json['updatedAt'])
          : null,
      deviceId: json['deviceId'] ?? 'unknown',
      deletedAt: json['deletedAt'] != null
          ? DateTime.fromMillisecondsSinceEpoch(json['deletedAt'])
          : null,
      rect: Rect.fromLTWH(
        (r['x'] as num?)?.toDouble() ?? 0,
        (r['y'] as num?)?.toDouble() ?? 0,
        (r['w'] as num?)?.toDouble() ?? 180,
        (r['h'] as num?)?.toDouble() ?? 44,
      ),
      rotation: (json['rotation'] as num?)?.toDouble() ?? 0,
      assetId: json['assetId'] ?? '',
      name: json['name'] ?? 'attachment.pdf',
      mime: json['mime'] ?? 'application/pdf',
    )..zIndex = (json['zi'] as num?)?.toDouble() ?? 0;
  }
}
