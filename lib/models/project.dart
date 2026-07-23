/// Projects: named, graph-side saved selections of items. Unlike a tag (visible
/// on the item), a project is invisible from the item side — it's a set you
/// build in the graph and activate to filter the graph to just those items
/// (linked or not). Stored in the store-root `projects.json` — a single
/// id-keyed map of enveloped records (`t` = 'pd' definition / 'pi' membership)
/// — merged exactly like `tags.json`/`links.json` (union + LWW + tombstones),
/// so a project or membership created on one device survives sync.
library;

import 'link.dart';

/// A project definition — a name plus the sync envelope.
class ProjectDef {
  final int schemaVersion;
  final String id;
  int rev;
  DateTime updatedAt;
  String deviceId;
  DateTime? deletedAt;
  String name;
  final DateTime createdAt;

  /// When true, activating this project restores its saved node [layout] and
  /// pins those nodes in place (instead of running the force layout). A
  /// per-project alternative to the global "pin on drag" — synced, so an
  /// arrangement made on one device comes back on another. Default false.
  bool pinLayout;

  /// Saved node positions for this project's graph: canonical node key
  /// (endpoint URI) → `[dx, dy]` in graph/world coordinates. Applied only when
  /// [pinLayout] is on. Kept even while unpinned so toggling back on restores
  /// the same arrangement. Omitted from JSON when empty (byte-stable vs. old
  /// data). Whole-map LWW on the def (rare concurrent arranging — one wins).
  Map<String, List<double>> layout;

  ProjectDef({
    this.schemaVersion = 1,
    required this.id,
    this.rev = 1,
    DateTime? updatedAt,
    required this.deviceId,
    this.deletedAt,
    required this.name,
    DateTime? createdAt,
    this.pinLayout = false,
    Map<String, List<double>>? layout,
  })  : updatedAt = updatedAt ?? DateTime.now(),
        createdAt = createdAt ?? DateTime.now(),
        layout = layout ?? {};

  void bumpRev(String newDeviceId) {
    rev += 1;
    updatedAt = DateTime.now();
    deviceId = newDeviceId;
  }

  Map<String, dynamic> toJson() => {
        't': 'pd',
        'schemaVersion': schemaVersion,
        'id': id,
        'rev': rev,
        'updatedAt': updatedAt.millisecondsSinceEpoch,
        'deviceId': deviceId,
        'deletedAt': deletedAt?.millisecondsSinceEpoch,
        'name': name,
        'createdAt': createdAt.millisecondsSinceEpoch,
        if (pinLayout) 'pinLayout': true,
        if (layout.isNotEmpty) 'layout': layout,
      };

  static ProjectDef? tryFromJson(Map<String, dynamic> json) {
    final id = json['id'];
    if (id is! String) return null;
    Map<String, List<double>>? layout;
    final rawLayout = json['layout'];
    if (rawLayout is Map) {
      layout = {};
      for (final e in rawLayout.entries) {
        final v = e.value;
        if (e.key is String && v is List && v.length >= 2) {
          layout[e.key as String] = [
            (v[0] as num).toDouble(),
            (v[1] as num).toDouble(),
          ];
        }
      }
    }
    return ProjectDef(
      schemaVersion: json['schemaVersion'] ?? 1,
      id: id,
      rev: json['rev'] ?? 1,
      updatedAt: json['updatedAt'] != null
          ? DateTime.fromMillisecondsSinceEpoch(json['updatedAt'])
          : DateTime.now(),
      deviceId: json['deviceId'] ?? 'unknown',
      deletedAt: json['deletedAt'] != null
          ? DateTime.fromMillisecondsSinceEpoch(json['deletedAt'])
          : null,
      name: json['name'] as String? ?? '',
      createdAt: json['createdAt'] != null
          ? DateTime.fromMillisecondsSinceEpoch(json['createdAt'])
          : DateTime.now(),
      pinLayout: json['pinLayout'] == true,
      layout: layout,
    );
  }
}

/// One (project → item) membership. The item is addressed by its endpoint URI.
class ProjectItem {
  final int schemaVersion;
  final String id;
  int rev;
  DateTime updatedAt;
  String deviceId;
  DateTime? deletedAt;
  final String projectId;
  LinkEndpoint endpoint;

  /// When true this record *excludes* [endpoint] from the project rather than
  /// including it — the per-item override that lets you uncheck one canvas under
  /// a whole-section (inherited) include. Membership is decided nearest-first
  /// over the container ancestry, so a nearer exclude beats a farther include
  /// (and vice-versa). Defaults false (a plain include) — legacy records with no
  /// `ex` flag load as includes, so old projects keep working.
  bool excluded;

  ProjectItem({
    this.schemaVersion = 1,
    required this.id,
    this.rev = 1,
    DateTime? updatedAt,
    required this.deviceId,
    this.deletedAt,
    required this.projectId,
    required this.endpoint,
    this.excluded = false,
  }) : updatedAt = updatedAt ?? DateTime.now();

  void bumpRev(String newDeviceId) {
    rev += 1;
    updatedAt = DateTime.now();
    deviceId = newDeviceId;
  }

  Map<String, dynamic> toJson() => {
        't': 'pi',
        'schemaVersion': schemaVersion,
        'id': id,
        'rev': rev,
        'updatedAt': updatedAt.millisecondsSinceEpoch,
        'deviceId': deviceId,
        'deletedAt': deletedAt?.millisecondsSinceEpoch,
        'projectId': projectId,
        'ep': endpoint.toUri(),
        // Omitted when false so include records stay byte-stable vs. old data.
        if (excluded) 'ex': true,
      };

  static ProjectItem? tryFromJson(Map<String, dynamic> json) {
    final id = json['id'];
    final projectId = json['projectId'];
    final ep = LinkEndpoint.sideFrom(json['ep'] as String? ?? '');
    if (id is! String || projectId is! String || ep == null) return null;
    return ProjectItem(
      schemaVersion: json['schemaVersion'] ?? 1,
      id: id,
      rev: json['rev'] ?? 1,
      updatedAt: json['updatedAt'] != null
          ? DateTime.fromMillisecondsSinceEpoch(json['updatedAt'])
          : DateTime.now(),
      deviceId: json['deviceId'] ?? 'unknown',
      deletedAt: json['deletedAt'] != null
          ? DateTime.fromMillisecondsSinceEpoch(json['deletedAt'])
          : null,
      projectId: projectId,
      endpoint: ep,
      excluded: json['ex'] == true,
    );
  }
}
