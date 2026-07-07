import 'tree.dart';

/// Top-level collection: a tree of **Sections** + nested super-sections
/// (`FolderNode`). Leaves reference sections by id.
class Notebook {
  final int schemaVersion;
  final String id;
  int rev;
  DateTime updatedAt;
  String deviceId;
  DateTime? deletedAt;

  String name;
  final DateTime createdAt;
  int? color; // ARGB; null → deterministic identity color
  final List<TreeNode> nodes; // leaves = section ids

  Notebook({
    this.schemaVersion = 1,
    required this.id,
    this.rev = 1,
    DateTime? updatedAt,
    required this.deviceId,
    this.deletedAt,
    required this.name,
    required this.createdAt,
    this.color,
    List<TreeNode>? nodes,
  })  : updatedAt = updatedAt ?? DateTime.now(),
        nodes = nodes ?? [];

  /// Every section id in this notebook, depth-first.
  List<String> get allSectionIds => TreeOps.allLeafIds(nodes);

  int get sectionCount => allSectionIds.length;

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
        'name': name,
        'createdAt': createdAt.toIso8601String(),
        'color': color,
        'nodes': nodes.map((n) => n.toJson()).toList(),
        // Derived flat list, kept for any back-compat reader.
        'sectionIds': allSectionIds,
      };

  factory Notebook.fromJson(Map<String, dynamic> json) => Notebook(
        schemaVersion: json['schemaVersion'] ?? 1,
        id: json['id'],
        rev: json['rev'] ?? 1,
        updatedAt: json['updatedAt'] != null
            ? DateTime.fromMillisecondsSinceEpoch(json['updatedAt'])
            : DateTime.parse(json['createdAt']), // fallback
        deviceId: json['deviceId'] ?? 'unknown',
        deletedAt: json['deletedAt'] != null
            ? DateTime.fromMillisecondsSinceEpoch(json['deletedAt'])
            : null,
        name: json['name'],
        createdAt: DateTime.parse(json['createdAt']),
        color: (json['color'] as num?)?.toInt(),
        nodes: TreeOps.parse(
          json['nodes'],
          legacyIds: List<String>.from(json['sectionIds'] ?? []),
        ),
      );
}
