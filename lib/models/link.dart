/// Internal-link ("Connections") model: a [LinkEndpoint] addresses any
/// linkable thing in the store by its id path, and a [LinkRecord] is one
/// two-way connection between two endpoints. Records live in the store-root
/// `links.json` (a map of id → record, like `notebooks.json`) and merge the
/// same way: union by id + per-record LWW + tombstone deletes.
///
/// Endpoints serialize as `omninote://link/...` URIs — the same string a
/// "Copy link" puts on the clipboard — so the clipboard, the JSON store and
/// text-run hyperlinks all share one canonical form.
library;

/// What a [LinkEndpoint] points at (derived from its deepest id).
enum LinkTargetKind {
  notebook,
  folder, // super-section in a notebook tree, or a folder in a canvas list
  section,
  canvas,
  page,
  element, // one or more lasso-selected elements on a page
  bookmark,
}

/// An address inside the store: notebook, then optionally deeper. The deepest
/// non-null level is the target ([kind]). Immutable.
class LinkEndpoint {
  final String notebookId;
  final String? sectionId;
  final String? canvasId;
  final String? pageId;

  /// Lasso-selected elements (page-level target when empty). Multiple ids form
  /// one endpoint (a selection linked as a whole).
  final List<String> elementIds;

  final String? bookmarkId;

  /// A folder (super-section) id — in the notebook's section tree when
  /// [sectionId] is null, else in that section's canvas tree.
  final String? folderId;

  const LinkEndpoint({
    required this.notebookId,
    this.sectionId,
    this.canvasId,
    this.pageId,
    this.elementIds = const [],
    this.bookmarkId,
    this.folderId,
  });

  LinkTargetKind get kind {
    if (bookmarkId != null) return LinkTargetKind.bookmark;
    if (elementIds.isNotEmpty) return LinkTargetKind.element;
    if (pageId != null) return LinkTargetKind.page;
    if (canvasId != null) return LinkTargetKind.canvas;
    if (folderId != null) return LinkTargetKind.folder;
    if (sectionId != null) return LinkTargetKind.section;
    return LinkTargetKind.notebook;
  }

  /// The id of the thing this endpoint targets (deepest level). For an
  /// element endpoint this is the *first* element id — use [touchesId] for
  /// membership checks.
  String get leafId {
    if (bookmarkId != null) return bookmarkId!;
    if (elementIds.isNotEmpty) return elementIds.first;
    if (pageId != null) return pageId!;
    if (canvasId != null) return canvasId!;
    if (folderId != null) return folderId!;
    if (sectionId != null) return sectionId!;
    return notebookId;
  }

  /// True if [id] appears anywhere in this endpoint's id path — used both for
  /// "connections of this exact item" (compare [leafId]) and the canvas-wide
  /// aggregate query (any endpoint whose path includes the canvas id).
  bool touchesId(String id) =>
      notebookId == id ||
      sectionId == id ||
      canvasId == id ||
      pageId == id ||
      bookmarkId == id ||
      folderId == id ||
      elementIds.contains(id);

  /// Canonical `omninote://link/...` URI. Segment pairs in fixed order:
  /// `n/nb [/f/folder] [/s/sec] [/f/folder] [/c/canvas] [/p/page]`
  /// `[/e/id1,id2…] [/b/bookmark]` — `f` binds to the notebook tree when it
  /// appears before `s`, to the canvas tree after it.
  String toUri() {
    final b = StringBuffer('omninote://link/n/$notebookId');
    if (folderId != null && sectionId == null) b.write('/f/$folderId');
    if (sectionId != null) b.write('/s/$sectionId');
    if (folderId != null && sectionId != null) b.write('/f/$folderId');
    if (canvasId != null) b.write('/c/$canvasId');
    if (pageId != null) b.write('/p/$pageId');
    if (elementIds.isNotEmpty) b.write('/e/${elementIds.join(',')}');
    if (bookmarkId != null) b.write('/b/$bookmarkId');
    return b.toString();
  }

  /// Parses a `omninote://link/...` URI, or returns null when [uri] isn't one
  /// (wrong scheme/shape) — never throws on foreign input (this runs on
  /// pasted clipboard text).
  static LinkEndpoint? tryParse(String uri) {
    const prefix = 'omninote://link/';
    if (!uri.startsWith(prefix)) return null;
    final segs = uri.substring(prefix.length).split('/');
    if (segs.length < 2 || segs.length.isOdd) return null;
    String? nb, sec, canvas, page, bookmark, folder;
    var elements = const <String>[];
    for (var i = 0; i < segs.length; i += 2) {
      final key = segs[i];
      final val = segs[i + 1];
      if (val.isEmpty) return null;
      switch (key) {
        case 'n':
          nb = val;
        case 's':
          sec = val;
        case 'f':
          folder = val;
        case 'c':
          canvas = val;
        case 'p':
          page = val;
        case 'e':
          elements = val.split(',');
        case 'b':
          bookmark = val;
        default:
          return null;
      }
    }
    if (nb == null) return null;
    return LinkEndpoint(
      notebookId: nb,
      sectionId: sec,
      canvasId: canvas,
      pageId: page,
      elementIds: elements,
      bookmarkId: bookmark,
      folderId: folder,
    );
  }

  /// Structural equality on the full id path (element order-insensitive).
  bool sameAs(LinkEndpoint other) =>
      notebookId == other.notebookId &&
      sectionId == other.sectionId &&
      canvasId == other.canvasId &&
      pageId == other.pageId &&
      bookmarkId == other.bookmarkId &&
      folderId == other.folderId &&
      elementIds.length == other.elementIds.length &&
      elementIds.toSet().containsAll(other.elementIds);
}

/// One two-way connection between endpoints [a] and [b]. Carries the standard
/// sync envelope so `links.json` merges by union + LWW like `notebooks.json`;
/// deletion tombstones ([deletedAt]) rather than removing the entry.
class LinkRecord {
  final int schemaVersion;
  final String id;
  int rev;
  DateTime updatedAt;
  String deviceId;
  DateTime? deletedAt;

  /// Where the link was placed (the item whose Connections "+" created it).
  final LinkEndpoint a;

  /// What it points at (the copied/picked target).
  final LinkEndpoint b;

  /// Optional user-edited label (overrides the resolved title in lists).
  String? label;

  /// Name snapshots taken at creation — the fallback display when an endpoint
  /// no longer resolves (deleted/purged/absent on this device). While the item
  /// is alive its *live* name is shown instead, so these are never refreshed.
  final String aName;
  final String bName;

  final DateTime createdAt;

  LinkRecord({
    this.schemaVersion = 1,
    required this.id,
    this.rev = 1,
    DateTime? updatedAt,
    required this.deviceId,
    this.deletedAt,
    required this.a,
    required this.b,
    this.label,
    this.aName = '',
    this.bName = '',
    DateTime? createdAt,
  })  : updatedAt = updatedAt ?? DateTime.now(),
        createdAt = createdAt ?? DateTime.now();

  void bumpRev(String newDeviceId) {
    rev += 1;
    updatedAt = DateTime.now();
    deviceId = newDeviceId;
  }

  /// The endpoint opposite [id]'s side, given one endpoint's leaf id — the
  /// "other end" shown in a Connections list. Null when [leafId] is neither
  /// side's leaf.
  LinkEndpoint? otherEndOf(String leafId) {
    if (a.leafId == leafId) return b;
    if (b.leafId == leafId) return a;
    return null;
  }

  /// Snapshot name of the endpoint opposite the one whose leaf id is
  /// [leafId] (see [otherEndOf]).
  String otherNameOf(String leafId) => a.leafId == leafId ? bName : aName;

  Map<String, dynamic> toJson() => {
        'schemaVersion': schemaVersion,
        'id': id,
        'rev': rev,
        'updatedAt': updatedAt.millisecondsSinceEpoch,
        'deviceId': deviceId,
        'deletedAt': deletedAt?.millisecondsSinceEpoch,
        'a': a.toUri(),
        'b': b.toUri(),
        if (label != null) 'label': label,
        if (aName.isNotEmpty) 'an': aName,
        if (bName.isNotEmpty) 'bn': bName,
        'createdAt': createdAt.millisecondsSinceEpoch,
      };

  /// Returns null (skip the entry) when either endpoint URI fails to parse —
  /// a forward-compat guard so a future schema never crashes an old build.
  static LinkRecord? tryFromJson(Map<String, dynamic> json) {
    final a = LinkEndpoint.tryParse(json['a'] as String? ?? '');
    final b = LinkEndpoint.tryParse(json['b'] as String? ?? '');
    if (a == null || b == null) return null;
    return LinkRecord(
      schemaVersion: json['schemaVersion'] ?? 1,
      id: json['id'],
      rev: json['rev'] ?? 1,
      updatedAt: json['updatedAt'] != null
          ? DateTime.fromMillisecondsSinceEpoch(json['updatedAt'])
          : DateTime.now(),
      deviceId: json['deviceId'] ?? 'unknown',
      deletedAt: json['deletedAt'] != null
          ? DateTime.fromMillisecondsSinceEpoch(json['deletedAt'])
          : null,
      a: a,
      b: b,
      label: json['label'] as String?,
      aName: json['an'] as String? ?? '',
      bName: json['bn'] as String? ?? '',
      createdAt: json['createdAt'] != null
          ? DateTime.fromMillisecondsSinceEpoch(json['createdAt'])
          : DateTime.now(),
    );
  }
}
