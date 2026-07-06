import 'tree.dart';

/// The item opened from a notebook (screen 2/3): a container of **Canvases**,
/// organized as a tree of canvases + nested super-sections (`FolderNode`).
/// Owns no drawing content itself — that lives in its [Canvas] children.
///
/// Path: `notebooks/<nbId>/sections/<id>/section.json`.
class Section {
  final String id;
  final String notebookId;
  String name;
  final DateTime createdAt;
  int? color; // ARGB; null → deterministic identity color
  final List<TreeNode> nodes; // leaves = canvas ids

  Section({
    required this.id,
    required this.notebookId,
    required this.name,
    required this.createdAt,
    this.color,
    List<TreeNode>? nodes,
  }) : nodes = nodes ?? [];

  /// Every canvas id in this section, depth-first.
  List<String> get allCanvasIds => TreeOps.allLeafIds(nodes);

  int get canvasCount => allCanvasIds.length;

  Map<String, dynamic> toJson() => {
    'id': id,
    'notebookId': notebookId,
    'name': name,
    'createdAt': createdAt.toIso8601String(),
    'color': color,
    'nodes': nodes.map((n) => n.toJson()).toList(),
  };

  factory Section.fromJson(Map<String, dynamic> json) => Section(
    id: json['id'],
    notebookId: json['notebookId'] ?? '',
    name: json['name'] ?? 'Untitled',
    createdAt: DateTime.tryParse(json['createdAt'] ?? '') ?? DateTime.now(),
    color: (json['color'] as num?)?.toInt(),
    nodes: TreeOps.parse(json['nodes']),
  );
}
