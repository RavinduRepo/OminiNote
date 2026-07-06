import 'canvas_page.dart';
import 'element.dart';

/// A horizontal band of pages inside a Canvas. Order of [pageIds] is the
/// left→right order; on PDF export a multi-page row merges into one wide
/// landscape PDF page.
class PageRow {
  final String id;
  final List<String> pageIds;

  PageRow({required this.id, List<String>? pageIds}) : pageIds = pageIds ?? [];

  Map<String, dynamic> toJson() => {'id': id, 'pageIds': pageIds};

  factory PageRow.fromJson(Map<String, dynamic> json) => PageRow(
    id: json['id'] ?? newModelId('row'),
    pageIds: List<String>.from(json['pageIds'] ?? []),
  );
}

/// A file added "as attachment" — stored with the canvas but not rendered
/// into it.
class Attachment {
  final String id;
  final String name;
  final String assetId;
  final String mime;
  final DateTime addedAt;

  Attachment({
    required this.id,
    required this.name,
    required this.assetId,
    required this.mime,
    required this.addedAt,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'assetId': assetId,
    'mime': mime,
    'addedAt': addedAt.toIso8601String(),
  };

  factory Attachment.fromJson(Map<String, dynamic> json) => Attachment(
    id: json['id'] ?? newModelId('att'),
    name: json['name'] ?? 'attachment',
    assetId: json['assetId'] ?? '',
    mime: json['mime'] ?? 'application/octet-stream',
    addedAt: DateTime.tryParse(json['addedAt'] ?? '') ?? DateTime.now(),
  );
}

/// The drawing surface opened from a section's canvas list (screen 4). Owns the
/// row/page structure; page bodies live in separate per-page files, so this
/// JSON stays small and structural edits rewrite only canvas.json.
///
/// Path: `notebooks/<nbId>/sections/<secId>/canvases/<id>/canvas.json`.
class Canvas {
  final String id;
  final String notebookId;
  final String sectionId;
  String name;
  final DateTime createdAt;
  int? color; // ARGB; null → deterministic identity color
  double defaultPageWidth;
  double defaultPageHeight;
  PageBackground defaultBackground;
  final List<PageRow> rows;
  final List<Attachment> attachments;

  Canvas({
    required this.id,
    required this.notebookId,
    required this.sectionId,
    required this.name,
    required this.createdAt,
    this.color,
    this.defaultPageWidth = kDefaultPageWidth,
    this.defaultPageHeight = kDefaultPageHeight,
    this.defaultBackground = const PageBackground(),
    List<PageRow>? rows,
    List<Attachment>? attachments,
  }) : rows = rows ?? [],
       attachments = attachments ?? [];

  int get pageCount => rows.fold(0, (sum, r) => sum + r.pageIds.length);

  Map<String, dynamic> toJson() => {
    'id': id,
    'notebookId': notebookId,
    'sectionId': sectionId,
    'name': name,
    'createdAt': createdAt.toIso8601String(),
    'color': color,
    'defaultPageWidth': defaultPageWidth,
    'defaultPageHeight': defaultPageHeight,
    'defaultBackground': defaultBackground.toJson(),
    'rows': rows.map((r) => r.toJson()).toList(),
    'attachments': attachments.map((a) => a.toJson()).toList(),
  };

  factory Canvas.fromJson(Map<String, dynamic> json) => Canvas(
    id: json['id'],
    notebookId: json['notebookId'] ?? '',
    sectionId: json['sectionId'] ?? '',
    name: json['name'] ?? 'Untitled',
    createdAt: DateTime.tryParse(json['createdAt'] ?? '') ?? DateTime.now(),
    color: (json['color'] as num?)?.toInt(),
    defaultPageWidth:
        (json['defaultPageWidth'] as num?)?.toDouble() ?? kDefaultPageWidth,
    defaultPageHeight:
        (json['defaultPageHeight'] as num?)?.toDouble() ?? kDefaultPageHeight,
    defaultBackground: PageBackground.fromJson(
      json['defaultBackground'] as Map<String, dynamic>?,
    ),
    rows: List<Map<String, dynamic>>.from(
      json['rows'] ?? [],
    ).map(PageRow.fromJson).toList(),
    attachments: List<Map<String, dynamic>>.from(
      json['attachments'] ?? [],
    ).map(Attachment.fromJson).toList(),
  );
}
