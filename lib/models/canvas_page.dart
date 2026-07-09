import 'dart:ui';
import 'element.dart';

/// A4 portrait in PDF points — the default page size (spec §4.1).
const double kDefaultPageWidth = 595;
const double kDefaultPageHeight = 842;

/// Combined paint order for a page: strokes + objects stable-sorted by
/// [CanvasElement.zIndex] (ties keep list order, i.e. strokes under objects).
/// Used by both the on-screen painter and the PDF exporter so "send to back"
/// can put an image behind ink — the two lists alone couldn't express that.
List<CanvasElement> zOrderedElements(CanvasPage page) {
  final all = <CanvasElement>[...page.strokes, ...page.objects];
  final indexed = List.generate(all.length, (i) => (i, all[i]))
    ..sort((a, b) {
      final z = a.$2.zIndex.compareTo(b.$2.zIndex);
      return z != 0 ? z : a.$1.compareTo(b.$1);
    });
  return [for (final e in indexed) e.$2];
}

enum BgPattern { blank, ruled, grid, dotted }

/// A page's background: a solid color plus an optional pattern.
class PageBackground {
  final Color color;
  final BgPattern pattern;

  const PageBackground({
    this.color = const Color(0xFFFFFFFF),
    this.pattern = BgPattern.blank,
  });

  PageBackground copyWith({Color? color, BgPattern? pattern}) =>
      PageBackground(
        color: color ?? this.color,
        pattern: pattern ?? this.pattern,
      );

  Map<String, dynamic> toJson() => {
    'color': color.toARGB32(),
    'pattern': pattern.name,
  };

  factory PageBackground.fromJson(Map<String, dynamic>? json) {
    if (json == null) return const PageBackground();
    return PageBackground(
      color: Color(json['color'] ?? 0xFFFFFFFF),
      pattern: BgPattern.values.firstWhere(
        (p) => p.name == json['pattern'],
        orElse: () => BgPattern.blank,
      ),
    );
  }
}

/// Reference to one page of an imported PDF asset — makes a page "PDF-backed".
class PdfSource {
  final String assetId;
  final int pageIndex; // 0-based

  const PdfSource({required this.assetId, required this.pageIndex});

  Map<String, dynamic> toJson() => {'assetId': assetId, 'pageIndex': pageIndex};

  factory PdfSource.fromJson(Map<String, dynamic> json) => PdfSource(
    assetId: json['assetId'] ?? '',
    pageIndex: json['pageIndex'] ?? 0,
  );
}

class EraseTombstone {
  final String strokeId;
  final DateTime erasedAt;
  final int rev;
  final String deviceId;

  EraseTombstone({
    required this.strokeId,
    required this.erasedAt,
    this.rev = 1,
    required this.deviceId,
  });

  Map<String, dynamic> toJson() => {
        'strokeId': strokeId,
        'erasedAt': erasedAt.millisecondsSinceEpoch,
        'rev': rev,
        'deviceId': deviceId,
      };

  factory EraseTombstone.fromJson(Map<String, dynamic> json) =>
      EraseTombstone(
        strokeId: json['strokeId'],
        erasedAt: DateTime.fromMillisecondsSinceEpoch(json['erasedAt']),
        rev: json['rev'] ?? 1,
        deviceId: json['deviceId'] ?? 'unknown',
      );
}

/// One sheet inside a Canvas. Size in PDF points.
class CanvasPage {
  final int schemaVersion;
  final String id;
  int rev;
  DateTime updatedAt;
  String deviceId;
  DateTime? deletedAt;

  double width;
  double height;
  PageBackground background;

  /// Non-null when this page renders an imported PDF page as its background.
  PdfSource? source;

  final List<StrokeElement> strokes;
  final List<EraseTombstone> erased;
  final List<CanvasElement> objects;

  /// Tombstones for deleted text/image objects — same idea as [erased] for
  /// strokes. An object is never spliced out of [objects] on delete (that
  /// would let a stale remote copy of it resurrect on merge); instead its id
  /// lands here and merge filters it out. Reuses [EraseTombstone]'s shape
  /// (its `strokeId` field just holds the deleted object's id here).
  final List<EraseTombstone> deletedObjects;

  CanvasPage({
    this.schemaVersion = 1,
    required this.id,
    this.rev = 1,
    DateTime? updatedAt,
    required this.deviceId,
    this.deletedAt,
    this.width = kDefaultPageWidth,
    this.height = kDefaultPageHeight,
    this.background = const PageBackground(),
    this.source,
    List<StrokeElement>? strokes,
    List<EraseTombstone>? erased,
    List<CanvasElement>? objects,
    List<EraseTombstone>? deletedObjects,
  })  : updatedAt = updatedAt ?? DateTime.now(),
        strokes = strokes ?? [],
        erased = erased ?? [],
        objects = objects ?? [],
        deletedObjects = deletedObjects ?? [];

  Size get size => Size(width, height);
  Rect get localRect => Rect.fromLTWH(0, 0, width, height);

  /// A fresh, independent copy of this page: a new page id and new element ids
  /// (so it can coexist with the original, even in the same canvas). Tombstones
  /// are intentionally dropped — the copy starts clean. Used to duplicate a
  /// page and to paste a page copied from another canvas. Any referenced assets
  /// (image/PDF/attachment) must be copied separately by the caller.
  CanvasPage cloneWithNewIds({required String deviceId}) => CanvasPage(
        id: newModelId('pg'),
        deviceId: deviceId,
        width: width,
        height: height,
        background: background,
        source: source,
        strokes: [for (final el in strokes) el.deepCopy(withNewId: true)],
        objects: [for (final el in objects) el.deepCopy(withNewId: true)],
      );

  /// Every asset id this page references (PDF background + image/attachment
  /// objects), for copying assets when the page moves between canvases.
  Set<String> referencedAssetIds() {
    final ids = <String>{};
    if (source != null) ids.add(source!.assetId);
    for (final el in objects) {
      if (el is ImageElement) ids.add(el.assetId);
      if (el is AttachmentElement) ids.add(el.assetId);
    }
    return ids;
  }

  void bumpRev(String newDeviceId) {
    rev += 1;
    updatedAt = DateTime.now();
    deviceId = newDeviceId;
  }

  Map<String, dynamic> toJson() => {
        'schemaVersion': schemaVersion,
        'id': id,
        'rev': rev,
        'updatedAt': updatedAt.millisecondsSinceEpoch,
        'deviceId': deviceId,
        'deletedAt': deletedAt?.millisecondsSinceEpoch,
        'w': width,
        'h': height,
        'background': background.toJson(),
        'source': source?.toJson(),
        'strokes': strokes.map((s) => s.toJson()).toList(),
        'erased': erased.map((e) => e.toJson()).toList(),
        'objects': objects.map((e) => e.toJson()).toList(),
        'deletedObjects': deletedObjects.map((e) => e.toJson()).toList(),
      };

  factory CanvasPage.fromJson(Map<String, dynamic> json) {
    // Backwards compatibility for v1
    final elements = List<Map<String, dynamic>>.from(json['elements'] ?? []);
    final List<StrokeElement> legacyStrokes = [];
    final List<CanvasElement> legacyObjects = [];

    for (final e in elements) {
      if (e['type'] == 'stroke') {
        legacyStrokes.add(StrokeElement.fromJson(e));
      } else {
        legacyObjects.add(CanvasElement.fromJson(e));
      }
    }

    return CanvasPage(
      schemaVersion: json['schemaVersion'] ?? 1,
      id: json['id'] ?? newModelId('pg'),
      rev: json['rev'] ?? 1,
      updatedAt: json['updatedAt'] != null
          ? DateTime.fromMillisecondsSinceEpoch(json['updatedAt'])
          : null,
      deviceId: json['deviceId'] ?? 'unknown',
      deletedAt: json['deletedAt'] != null
          ? DateTime.fromMillisecondsSinceEpoch(json['deletedAt'])
          : null,
      width: (json['w'] as num?)?.toDouble() ?? kDefaultPageWidth,
      height: (json['h'] as num?)?.toDouble() ?? kDefaultPageHeight,
      background: PageBackground.fromJson(
        json['background'] as Map<String, dynamic>?,
      ),
      source: json['source'] == null
          ? null
          : PdfSource.fromJson(json['source'] as Map<String, dynamic>),
      strokes: json['strokes'] != null
          ? List<Map<String, dynamic>>.from(json['strokes'])
              .map(StrokeElement.fromJson)
              .toList()
          : legacyStrokes,
      erased: json['erased'] != null
          ? List<Map<String, dynamic>>.from(json['erased'])
              .map(EraseTombstone.fromJson)
              .toList()
          : [],
      objects: json['objects'] != null
          ? List<Map<String, dynamic>>.from(json['objects'])
              .map(CanvasElement.fromJson)
              .toList()
          : legacyObjects,
      deletedObjects: json['deletedObjects'] != null
          ? List<Map<String, dynamic>>.from(json['deletedObjects'])
              .map(EraseTombstone.fromJson)
              .toList()
          : [],
    );
  }
}
