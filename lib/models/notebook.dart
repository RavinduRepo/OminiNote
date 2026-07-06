import 'tree.dart';

/// Top-level collection: a tree of **Sections** + nested super-sections
/// (`FolderNode`). Leaves reference sections by id.
class Notebook {
  final String id;
  String name;
  final DateTime createdAt;
  int? color; // ARGB; null → deterministic identity color
  final List<TreeNode> nodes; // leaves = section ids

  Notebook({
    required this.id,
    required this.name,
    required this.createdAt,
    this.color,
    List<TreeNode>? nodes,
  }) : nodes = nodes ?? [];

  /// Every section id in this notebook, depth-first.
  List<String> get allSectionIds => TreeOps.allLeafIds(nodes);

  int get sectionCount => allSectionIds.length;

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'createdAt': createdAt.toIso8601String(),
    'color': color,
    'nodes': nodes.map((n) => n.toJson()).toList(),
    // Derived flat list, kept for any back-compat reader.
    'sectionIds': allSectionIds,
  };

  factory Notebook.fromJson(Map<String, dynamic> json) => Notebook(
    id: json['id'],
    name: json['name'],
    createdAt: DateTime.parse(json['createdAt']),
    color: (json['color'] as num?)?.toInt(),
    nodes: TreeOps.parse(
      json['nodes'],
      legacyIds: List<String>.from(json['sectionIds'] ?? []),
    ),
  );
}
