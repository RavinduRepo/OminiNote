import 'tree.dart';

/// The item opened from a notebook (screen 2/3): a container of **Canvases**,
/// organized as a tree of canvases + nested super-sections (`FolderNode`).
/// Owns no drawing content itself — that lives in its [Canvas] children.
///
/// Path: `notebooks/<nbId>/sections/<id>/section.json`.
class Section {
  final int schemaVersion;
  final String id;
  int rev;
  DateTime updatedAt;
  String deviceId;
  DateTime? deletedAt;

  /// Terminal purge marker (see [Notebook.purgedAt]): content permanently
  /// wiped everywhere, only this doc survives. Grow-only in merges.
  DateTime? purgedAt;

  final String notebookId;
  String name;
  final DateTime createdAt;
  int? color; // ARGB; null → deterministic identity color
  final List<TreeNode> nodes; // leaves = canvas ids

  /// Super-sections removed to the recycle bin (restorable/purgeable).
  final List<DeletedFolder> deletedFolders;

  Section({
    this.schemaVersion = 1,
    required this.id,
    this.rev = 1,
    DateTime? updatedAt,
    required this.deviceId,
    this.deletedAt,
    this.purgedAt,
    required this.notebookId,
    required this.name,
    required this.createdAt,
    this.color,
    List<TreeNode>? nodes,
    List<DeletedFolder>? deletedFolders,
  })  : updatedAt = updatedAt ?? DateTime.now(),
        nodes = nodes ?? [],
        deletedFolders = deletedFolders ?? [];

  /// Every canvas id in this section, depth-first.
  List<String> get allCanvasIds => TreeOps.allLeafIds(nodes);

  int get canvasCount => allCanvasIds.length;

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
        if (purgedAt != null) 'purgedAt': purgedAt!.millisecondsSinceEpoch,
        'notebookId': notebookId,
        'name': name,
        'createdAt': createdAt.toIso8601String(),
        'color': color,
        'nodes': nodes.map((n) => n.toJson()).toList(),
        if (deletedFolders.isNotEmpty)
          'deletedFolders': deletedFolders.map((f) => f.toJson()).toList(),
      };

  factory Section.fromJson(Map<String, dynamic> json) => Section(
        schemaVersion: json['schemaVersion'] ?? 1,
        id: json['id'],
        rev: json['rev'] ?? 1,
        updatedAt: json['updatedAt'] != null
            ? DateTime.fromMillisecondsSinceEpoch(json['updatedAt'])
            : DateTime.parse(json['createdAt'] ?? DateTime.now().toIso8601String()),
        deviceId: json['deviceId'] ?? 'unknown',
        deletedAt: json['deletedAt'] != null
            ? DateTime.fromMillisecondsSinceEpoch(json['deletedAt'])
            : null,
        purgedAt: json['purgedAt'] != null
            ? DateTime.fromMillisecondsSinceEpoch(json['purgedAt'])
            : null,
        notebookId: json['notebookId'] ?? '',
        name: json['name'] ?? 'Untitled',
        createdAt: DateTime.tryParse(json['createdAt'] ?? '') ?? DateTime.now(),
        color: (json['color'] as num?)?.toInt(),
        nodes: TreeOps.parse(json['nodes']),
        deletedFolders: [
          for (final f
              in List<Map<String, dynamic>>.from(json['deletedFolders'] ?? []))
            DeletedFolder.fromJson(f),
        ],
      );
}
