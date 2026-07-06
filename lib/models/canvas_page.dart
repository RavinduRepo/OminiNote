import 'dart:ui';
import 'element.dart';

/// A4 portrait in PDF points — the default page size (spec §4.1).
const double kDefaultPageWidth = 595;
const double kDefaultPageHeight = 842;

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

/// One sheet inside a Canvas. Size in PDF points; elements in page-local
/// coordinates; z-order = list order. Mutable (see CanvasElement note).
class CanvasPage {
  final String id;
  double width;
  double height;
  PageBackground background;

  /// Non-null when this page renders an imported PDF page as its background.
  PdfSource? source;
  final List<CanvasElement> elements;

  CanvasPage({
    required this.id,
    this.width = kDefaultPageWidth,
    this.height = kDefaultPageHeight,
    this.background = const PageBackground(),
    this.source,
    List<CanvasElement>? elements,
  }) : elements = elements ?? [];

  Size get size => Size(width, height);
  Rect get localRect => Rect.fromLTWH(0, 0, width, height);

  Map<String, dynamic> toJson() => {
    'id': id,
    'w': width,
    'h': height,
    'background': background.toJson(),
    'source': source?.toJson(),
    'elements': elements.map((e) => e.toJson()).toList(),
  };

  factory CanvasPage.fromJson(Map<String, dynamic> json) => CanvasPage(
    id: json['id'] ?? newModelId('pg'),
    width: (json['w'] as num?)?.toDouble() ?? kDefaultPageWidth,
    height: (json['h'] as num?)?.toDouble() ?? kDefaultPageHeight,
    background: PageBackground.fromJson(
      json['background'] as Map<String, dynamic>?,
    ),
    source: json['source'] == null
        ? null
        : PdfSource.fromJson(json['source'] as Map<String, dynamic>),
    elements: List<Map<String, dynamic>>.from(
      json['elements'] ?? [],
    ).map(CanvasElement.fromJson).toList(),
  );
}
