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

  ProjectDef({
    this.schemaVersion = 1,
    required this.id,
    this.rev = 1,
    DateTime? updatedAt,
    required this.deviceId,
    this.deletedAt,
    required this.name,
    DateTime? createdAt,
  })  : updatedAt = updatedAt ?? DateTime.now(),
        createdAt = createdAt ?? DateTime.now();

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
      };

  static ProjectDef? tryFromJson(Map<String, dynamic> json) {
    final id = json['id'];
    if (id is! String) return null;
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

  ProjectItem({
    this.schemaVersion = 1,
    required this.id,
    this.rev = 1,
    DateTime? updatedAt,
    required this.deviceId,
    this.deletedAt,
    required this.projectId,
    required this.endpoint,
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
    );
  }
}
