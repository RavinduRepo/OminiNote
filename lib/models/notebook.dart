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

  /// Terminal purge marker: content was permanently wiped from Drive and every
  /// device; only this envelope survives (grow-only in merges — once set
  /// anywhere it stays set everywhere, and a racing restore loses). Implies
  /// deleted.
  DateTime? purgedAt;

  String name;
  final DateTime createdAt;
  int? color; // ARGB; null → deterministic identity color

  /// Which Google account this notebook syncs to (Phase 2), as the account's
  /// OIDC `sub`. **Synced** in notebooks.json so both devices agree. `null` is
  /// treated as "the default account" at routing time — so existing notebooks
  /// need no eager rewrite. Orthogonal to the device-local *local-only* set
  /// (`SettingsService.localOnlyNotebooks`), which overrides this per-device.
  String? syncTarget;

  final List<TreeNode> nodes; // leaves = section ids

  /// Super-sections removed to the recycle bin (restorable/purgeable). Their
  /// contained sections' files stay on disk (hidden) until restore or purge.
  final List<DeletedFolder> deletedFolders;

  Notebook({
    this.schemaVersion = 1,
    required this.id,
    this.rev = 1,
    DateTime? updatedAt,
    required this.deviceId,
    this.deletedAt,
    this.purgedAt,
    required this.name,
    required this.createdAt,
    this.color,
    this.syncTarget,
    List<TreeNode>? nodes,
    List<DeletedFolder>? deletedFolders,
  })  : updatedAt = updatedAt ?? DateTime.now(),
        nodes = nodes ?? [],
        deletedFolders = deletedFolders ?? [];

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
        if (purgedAt != null) 'purgedAt': purgedAt!.millisecondsSinceEpoch,
        'name': name,
        'createdAt': createdAt.toIso8601String(),
        'color': color,
        'syncTarget': syncTarget,
        'nodes': nodes.map((n) => n.toJson()).toList(),
        if (deletedFolders.isNotEmpty)
          'deletedFolders': deletedFolders.map((f) => f.toJson()).toList(),
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
        purgedAt: json['purgedAt'] != null
            ? DateTime.fromMillisecondsSinceEpoch(json['purgedAt'])
            : null,
        name: json['name'],
        createdAt: DateTime.parse(json['createdAt']),
        color: (json['color'] as num?)?.toInt(),
        syncTarget: json['syncTarget'] as String?,
        nodes: TreeOps.parse(
          json['nodes'],
          legacyIds: List<String>.from(json['sectionIds'] ?? []),
        ),
        deletedFolders: [
          for (final f
              in List<Map<String, dynamic>>.from(json['deletedFolders'] ?? []))
            DeletedFolder.fromJson(f),
        ],
      );
}
