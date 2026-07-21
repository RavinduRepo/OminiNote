import 'element.dart' show newModelId;

/// A node in a container's contents tree: either a reference to a leaf item
/// (a section inside a notebook, or a canvas inside a section) or a
/// **[FolderNode]** — a collapsible "super-section" that holds leaves *and*
/// other folders, nested arbitrarily deep (OneNote's section groups).
///
/// The same structure is reused at two levels: `Notebook.nodes` (leaves =
/// sections) and `Section.nodes` (leaves = canvases). See `ItemTreeView`.
sealed class TreeNode {
  Map<String, dynamic> toJson();

  /// All leaf ref-ids reachable from this node, depth-first.
  List<String> collectLeafIds();

  TreeNode clone();

  static TreeNode fromJson(Map<String, dynamic> json) {
    // `group`/`section` are legacy type tags; accept them alongside the new
    // `folder`/`leaf` so older files still parse.
    final type = json['type'];
    return (type == 'folder' || type == 'group')
        ? FolderNode.fromJson(json)
        : LeafNode.fromJson(json);
  }
}

class LeafNode extends TreeNode {
  final String refId;

  LeafNode(this.refId);

  @override
  Map<String, dynamic> toJson() => {'type': 'leaf', 'refId': refId};

  @override
  List<String> collectLeafIds() => [refId];

  @override
  LeafNode clone() => LeafNode(refId);

  factory LeafNode.fromJson(Map<String, dynamic> json) =>
      LeafNode(json['refId'] ?? json['sectionId'] ?? json['id'] ?? '');
}

/// A super-section: a named, colorable, collapsible container of child nodes.
class FolderNode extends TreeNode {
  final String id;
  String name;
  int? color; // ARGB; null → deterministic identity color
  bool collapsed;
  final List<TreeNode> children;

  FolderNode({
    required this.id,
    required this.name,
    this.color,
    this.collapsed = false,
    List<TreeNode>? children,
  }) : children = children ?? [];

  @override
  Map<String, dynamic> toJson() => {
    'type': 'folder',
    'id': id,
    'name': name,
    'color': color,
    'collapsed': collapsed,
    'children': children.map((c) => c.toJson()).toList(),
  };

  @override
  List<String> collectLeafIds() =>
      children.expand((c) => c.collectLeafIds()).toList();

  @override
  FolderNode clone() => FolderNode(
    id: id,
    name: name,
    color: color,
    collapsed: collapsed,
    children: children.map((c) => c.clone()).toList(),
  );

  factory FolderNode.fromJson(Map<String, dynamic> json) => FolderNode(
    id: json['id'] ?? newModelId('grp'),
    name: json['name'] ?? 'Section group',
    color: (json['color'] as num?)?.toInt(),
    collapsed: json['collapsed'] ?? false,
    children: List<Map<String, dynamic>>.from(
      json['children'] ?? [],
    ).map(TreeNode.fromJson).toList(),
  );
}

/// A super-section removed to the recycle bin. The whole [FolderNode] subtree
/// (its child leaf refs + nested folders) is kept so a restore re-links it
/// intact; the contained leaves' files stay on disk untouched (just hidden,
/// since the tree no longer references them) until the folder is purged.
class DeletedFolder {
  final FolderNode node;
  DateTime deletedAt;
  DateTime? purgedAt; // terminal marker (grow-only in merges)

  DeletedFolder({required this.node, required this.deletedAt, this.purgedAt});

  Map<String, dynamic> toJson() => {
        'node': node.toJson(),
        'deletedAt': deletedAt.millisecondsSinceEpoch,
        if (purgedAt != null) 'purgedAt': purgedAt!.millisecondsSinceEpoch,
      };

  factory DeletedFolder.fromJson(Map<String, dynamic> json) => DeletedFolder(
        node: FolderNode.fromJson(json['node'] as Map<String, dynamic>),
        deletedAt: DateTime.fromMillisecondsSinceEpoch(json['deletedAt']),
        purgedAt: json['purgedAt'] != null
            ? DateTime.fromMillisecondsSinceEpoch(json['purgedAt'])
            : null,
      );
}

/// Shared tree helpers used by the service at both levels.
class TreeOps {
  const TreeOps._();

  static List<TreeNode> parse(dynamic nodesJson, {List<String>? legacyIds}) {
    if (nodesJson is List) {
      return List<Map<String, dynamic>>.from(
        nodesJson,
      ).map(TreeNode.fromJson).toList();
    }
    // Legacy flat id list, no grouping.
    return (legacyIds ?? const []).map(LeafNode.new).toList();
  }

  static List<String> allLeafIds(List<TreeNode> nodes) =>
      nodes.expand((n) => n.collectLeafIds()).toList();

  static FolderNode? findFolder(List<TreeNode> nodes, String folderId) {
    for (final node in nodes) {
      if (node is FolderNode) {
        if (node.id == folderId) return node;
        final found = findFolder(node.children, folderId);
        if (found != null) return found;
      }
    }
    return null;
  }

  /// Inserts [node] immediately after the sibling identified by [afterId] —
  /// matching either a [LeafNode.refId] or a [FolderNode.id] — wherever it
  /// lives in the tree (top level or inside a folder), so a newly added item
  /// (leaf OR super-section) lands right below the currently-selected one.
  /// Returns false if [afterId] isn't found (the caller should then append).
  static bool insertNodeAfter(
    List<TreeNode> nodes,
    String afterId,
    TreeNode node,
  ) {
    for (var i = 0; i < nodes.length; i++) {
      final n = nodes[i];
      final matches =
          (n is LeafNode && n.refId == afterId) ||
          (n is FolderNode && n.id == afterId);
      if (matches) {
        nodes.insert(i + 1, node);
        return true;
      }
      if (n is FolderNode && insertNodeAfter(n.children, afterId, node)) {
        return true;
      }
    }
    return false;
  }

  /// [insertNodeAfter] specialised to a leaf (kept for existing call sites).
  static bool insertLeafAfter(
    List<TreeNode> nodes,
    String afterRefId,
    LeafNode leaf,
  ) =>
      insertNodeAfter(nodes, afterRefId, leaf);

  static bool removeLeaf(List<TreeNode> nodes, String refId) {
    for (var i = 0; i < nodes.length; i++) {
      final node = nodes[i];
      if (node is LeafNode && node.refId == refId) {
        nodes.removeAt(i);
        return true;
      }
      if (node is FolderNode && removeLeaf(node.children, refId)) return true;
    }
    return false;
  }

  static bool removeFolder(List<TreeNode> nodes, String folderId) {
    for (var i = 0; i < nodes.length; i++) {
      final node = nodes[i];
      if (node is FolderNode) {
        if (node.id == folderId) {
          nodes.removeAt(i);
          return true;
        }
        if (removeFolder(node.children, folderId)) return true;
      }
    }
    return false;
  }

  /// Replaces a folder with its own children (ungroup — keep contents).
  static bool spliceOutFolder(List<TreeNode> nodes, String folderId) {
    for (var i = 0; i < nodes.length; i++) {
      final node = nodes[i];
      if (node is FolderNode) {
        if (node.id == folderId) {
          nodes.replaceRange(i, i + 1, node.children);
          return true;
        }
        if (spliceOutFolder(node.children, folderId)) return true;
      }
    }
    return false;
  }
}
