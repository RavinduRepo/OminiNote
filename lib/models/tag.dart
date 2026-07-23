/// Tags: reusable **name-only** labels applied to any linkable item, plus their
/// per-item assignments. Both live in the store-root `tags.json` — a single
/// id-keyed map of enveloped records (a `t` field discriminates definition vs
/// assignment) — and merge exactly like `links.json`/`notebooks.json` (union
/// by id + per-record LWW + tombstone deletes), so a tag or assignment created
/// on one device survives first sync and a delete propagates as a tombstone.
///
/// Unlike a `LinkRecord` (a relationship between two items), a tag is a label
/// visible *on the item* — surfaced in its Connections menu — and used to
/// filter the graph. Assignments reuse the same `omninote://link/...` endpoint
/// URIs, so any of the 8 item kinds can be tagged with no new addressing.
library;

import 'link.dart';

/// A tag definition — just a name plus the sync envelope.
class TagDef {
  final int schemaVersion;
  final String id;
  int rev;
  DateTime updatedAt;
  String deviceId;
  DateTime? deletedAt;
  String name;
  final DateTime createdAt;

  TagDef({
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
        't': 'd',
        'schemaVersion': schemaVersion,
        'id': id,
        'rev': rev,
        'updatedAt': updatedAt.millisecondsSinceEpoch,
        'deviceId': deviceId,
        'deletedAt': deletedAt?.millisecondsSinceEpoch,
        'name': name,
        'createdAt': createdAt.millisecondsSinceEpoch,
      };

  static TagDef? tryFromJson(Map<String, dynamic> json) {
    final id = json['id'];
    if (id is! String) return null;
    return TagDef(
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

/// One (tag → item) assignment. The item is addressed by its endpoint URI.
class TagAssignment {
  final int schemaVersion;
  final String id;
  int rev;
  DateTime updatedAt;
  String deviceId;
  DateTime? deletedAt;
  final String tagId;
  LinkEndpoint endpoint;

  TagAssignment({
    this.schemaVersion = 1,
    required this.id,
    this.rev = 1,
    DateTime? updatedAt,
    required this.deviceId,
    this.deletedAt,
    required this.tagId,
    required this.endpoint,
  }) : updatedAt = updatedAt ?? DateTime.now();

  void bumpRev(String newDeviceId) {
    rev += 1;
    updatedAt = DateTime.now();
    deviceId = newDeviceId;
  }

  Map<String, dynamic> toJson() => {
        't': 'a',
        'schemaVersion': schemaVersion,
        'id': id,
        'rev': rev,
        'updatedAt': updatedAt.millisecondsSinceEpoch,
        'deviceId': deviceId,
        'deletedAt': deletedAt?.millisecondsSinceEpoch,
        'tagId': tagId,
        'ep': endpoint.toUri(),
      };

  static TagAssignment? tryFromJson(Map<String, dynamic> json) {
    final id = json['id'];
    final tagId = json['tagId'];
    final ep = LinkEndpoint.sideFrom(json['ep'] as String? ?? '');
    if (id is! String || tagId is! String || ep == null) return null;
    return TagAssignment(
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
      tagId: tagId,
      endpoint: ep,
    );
  }
}
