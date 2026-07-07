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

/// A named jump target: bookmarks a page inside the canvas. Lives in
/// canvas.json, so it syncs with the rest of the canvas structure.
class Bookmark {
  final String id;
  String name;
  final String pageId;
  final DateTime createdAt;

  Bookmark({
    required this.id,
    required this.name,
    required this.pageId,
    required this.createdAt,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'pageId': pageId,
    'createdAt': createdAt.toIso8601String(),
  };

  factory Bookmark.fromJson(Map<String, dynamic> json) => Bookmark(
    id: json['id'] ?? newModelId('bm'),
    name: json['name'] ?? 'Bookmark',
    pageId: json['pageId'] ?? '',
    createdAt: DateTime.tryParse(json['createdAt'] ?? '') ?? DateTime.now(),
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
  final int schemaVersion;
  final String id;
  int rev;
  DateTime updatedAt;
  String deviceId;
  DateTime? deletedAt;

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
  final List<Bookmark> bookmarks;

  Canvas({
    this.schemaVersion = 1,
    required this.id,
    this.rev = 1,
    DateTime? updatedAt,
    this.deviceId = 'unknown',
    this.deletedAt,
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
    List<Bookmark>? bookmarks,
  })  : updatedAt = updatedAt ?? DateTime.now(),
        rows = rows ?? [],
        attachments = attachments ?? [],
        bookmarks = bookmarks ?? [];

  int get pageCount => rows.fold(0, (sum, r) => sum + r.pageIds.length);

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
    'bookmarks': bookmarks.map((b) => b.toJson()).toList(),
  };

  factory Canvas.fromJson(Map<String, dynamic> json) => Canvas(
    schemaVersion: json['schemaVersion'] ?? 1,
    id: json['id'],
    rev: json['rev'] ?? 1,
    updatedAt: json['updatedAt'] != null
        ? DateTime.fromMillisecondsSinceEpoch(json['updatedAt'])
        : (DateTime.tryParse(json['createdAt'] ?? '') ?? DateTime.now()),
    deviceId: json['deviceId'] ?? 'unknown',
    deletedAt: json['deletedAt'] != null
        ? DateTime.fromMillisecondsSinceEpoch(json['deletedAt'])
        : null,
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
    bookmarks: List<Map<String, dynamic>>.from(
      json['bookmarks'] ?? [],
    ).map(Bookmark.fromJson).toList(),
  );
}
