import 'package:flutter/material.dart';
import '../models/tree.dart';
import '../theme/app_theme.dart';
import 'action_sheet.dart';

/// The dragged node plus the container it came from (a notebook id for a
/// section tree, a section id for a canvas tree) so a drop can tell same- from
/// cross-container.
class _DragData {
  final TreeNode node;
  final String containerId;
  final List<TreeNode> parent;
  const _DragData(this.node, this.containerId, this.parent);
}

class _FlatEntry {
  final TreeNode node;
  final int depth;
  final List<TreeNode> parent;
  final FolderNode? parentFolder; // null → container root
  final bool hidden; // inside a collapsed folder — rendered but animated to 0
  const _FlatEntry(this.node, this.depth, this.parent, this.parentFolder,
      {this.hidden = false});

  /// Stable identity for keying the row's expand/collapse animation.
  String get key => node is FolderNode
      ? 'f_${(node as FolderNode).id}'
      : 'l_${(node as LeafNode).refId}';
}

/// A generic drag-reorderable, collapsible tree of leaf items ([T] = Section or
/// Canvas) + nested super-section folders. Reused at two levels: sections
/// inside a notebook, and canvases inside a section.
///
/// Mutates [nodes] in place for same-container reorders (then calls
/// [onTreeChanged]); a drop from a *different* tree routes to [onCrossDrop] so
/// the host can relocate files and update both containers. All other actions
/// go through callbacks so the host owns dialogs + service calls.
class ItemTreeView<T> extends StatefulWidget {
  final String containerId;
  final List<TreeNode> nodes;
  final Map<String, T> items;

  final String Function(T) nameOf;
  final int? Function(T) colorOf;
  final String Function(T) idOf;

  /// Icon drawn on each leaf row, tinted in the item's identity color — or
  /// null for no icon, in which case a short colored pill carries the color
  /// instead. The two are deliberately exclusive so the leaf kind is readable
  /// at a glance: sections show a colored icon, canvases a bare pill.
  final IconData? leafIcon;

  final String? selectedId;

  /// Id of a leaf to briefly glow (e.g. the target the user just reached via
  /// search). Null = no glow.
  final String? glowId;

  final bool dense;

  final void Function(T) onOpen;
  final void Function(T) onRenameLeaf;
  final void Function(T) onColorLeaf;
  final void Function(T) onDeleteLeaf;

  /// Optional "Export to PDF" action on each leaf (used for sections, so a
  /// whole section exports from the list without opening it). Null = no item.
  final void Function(T)? onExportLeaf;

  final void Function(FolderNode) onRenameFolder;
  final void Function(FolderNode) onColorFolder;
  final void Function(FolderNode) onAddLeafToFolder;
  final void Function(FolderNode) onAddFolderToFolder;
  final void Function(FolderNode) onUngroup;
  final void Function(FolderNode) onDeleteFolder;

  /// Move-to… / Copy-to… on any node (leaf or folder). Host shows a
  /// destination picker and performs the relocation.
  final void Function(TreeNode, {required bool copy}) onRelocate;

  /// Persist a same-container reorder / collapse toggle.
  final Future<void> Function() onTreeChanged;

  /// A node dragged from a *different* container (by [containerId]) was dropped
  /// here. The host removes it from its source, relocates its files, and
  /// inserts it under [targetFolder] (null = root) at [index]. Null disables
  /// cross-container drop for this tree.
  final void Function(
    TreeNode dragged,
    String sourceContainerId,
    FolderNode? targetFolder,
    int index,
  )?
  onCrossDrop;

  const ItemTreeView({
    super.key,
    required this.containerId,
    required this.nodes,
    required this.items,
    required this.nameOf,
    required this.colorOf,
    required this.idOf,
    this.leafIcon,
    required this.selectedId,
    this.glowId,
    required this.onOpen,
    required this.onRenameLeaf,
    required this.onColorLeaf,
    required this.onDeleteLeaf,
    this.onExportLeaf,
    required this.onRenameFolder,
    required this.onColorFolder,
    required this.onAddLeafToFolder,
    required this.onAddFolderToFolder,
    required this.onUngroup,
    required this.onDeleteFolder,
    required this.onRelocate,
    required this.onTreeChanged,
    this.onCrossDrop,
    this.dense = false,
  });

  @override
  State<ItemTreeView<T>> createState() => _ItemTreeViewState<T>();
}

class _ItemTreeViewState<T> extends State<ItemTreeView<T>> {
  double get _rowHeight => widget.dense ? 34 : 48;
  double get _indent => widget.dense ? 16 : 20;
  double get _fontSize => widget.dense ? 13 : 14.5;

  // Row keys (`_FlatEntry.key`-style) animating out on delete (collapse + fade
  // before the host reloads the tree without them).
  final Set<String> _removingIds = {};
  static const _kRemoveAnim = Duration(milliseconds: 260);

  String _nodeKey(TreeNode node) => node is FolderNode
      ? 'f_${node.id}'
      : 'l_${(node as LeafNode).refId}';

  Future<void> _deleteLeaf(T item) async {
    final key = 'l_${widget.idOf(item)}';
    setState(() => _removingIds.add(key));
    await Future.delayed(_kRemoveAnim);
    widget.onDeleteLeaf(item);
    if (mounted) _removingIds.remove(key);
  }

  /// Animate a super-section (and its whole subtree) out, then delete it.
  Future<void> _deleteFolder(FolderNode folder) async {
    final keys = <String>{};
    void collect(TreeNode n) {
      keys.add(_nodeKey(n));
      if (n is FolderNode) {
        for (final c in n.children) {
          collect(c);
        }
      }
    }

    collect(folder);
    setState(() => _removingIds.addAll(keys));
    await Future.delayed(_kRemoveAnim);
    widget.onDeleteFolder(folder);
    if (mounted) _removingIds.removeAll(keys);
  }

  /// One vertical hairline per ancestor level, so nesting depth reads at a
  /// glance instead of relying on left padding alone.
  Widget _indentGuides(AppPalette palette, int depth) {
    if (depth <= 0) return const SizedBox.shrink();
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < depth; i++)
          Container(
            width: _indent,
            alignment: Alignment.centerLeft,
            padding: EdgeInsets.only(left: widget.dense ? 9 : 12),
            child: Container(width: 1, color: palette.border),
          ),
      ],
    );
  }

  List<_FlatEntry> _flatten(
    List<TreeNode> nodes,
    int depth,
    FolderNode? parentFolder, {
    bool hidden = false,
  }) {
    // All descendants are included (so collapse/expand can animate each row);
    // rows inside a collapsed folder carry `hidden` and render at height 0.
    final out = <_FlatEntry>[];
    for (final node in nodes) {
      out.add(_FlatEntry(node, depth, nodes, parentFolder, hidden: hidden));
      if (node is FolderNode) {
        out.addAll(_flatten(node.children, depth + 1, node,
            hidden: hidden || node.collapsed));
      }
    }
    return out;
  }

  // ── Tree mutation (same-container) ──────────────────────────────────────

  void _collectChildLists(FolderNode folder, Set<List<TreeNode>> out) {
    out.add(folder.children);
    for (final child in folder.children) {
      if (child is FolderNode) _collectChildLists(child, out);
    }
  }

  bool _wouldCycle(TreeNode dragged, List<TreeNode> target) {
    if (dragged is! FolderNode) return false;
    final lists = <List<TreeNode>>{};
    _collectChildLists(dragged, lists);
    return lists.any((l) => identical(l, target));
  }

  Future<void> _drop(
    _DragData data,
    List<TreeNode> targetList,
    FolderNode? targetFolder,
    int index,
  ) async {
    if (data.containerId != widget.containerId) {
      widget.onCrossDrop?.call(
        data.node,
        data.containerId,
        targetFolder,
        index,
      );
      return;
    }
    if (_wouldCycle(data.node, targetList)) return;
    final from = data.parent;
    final oldIndex = from.indexOf(data.node);
    if (oldIndex < 0) return;
    from.removeAt(oldIndex);
    var insertAt = index;
    if (identical(from, targetList) && oldIndex < insertAt) insertAt--;
    targetList.insert(insertAt.clamp(0, targetList.length), data.node);
    await widget.onTreeChanged();
    if (mounted) setState(() {});
  }

  bool _accepts(_DragData data, List<TreeNode> target) {
    if (data.containerId != widget.containerId) {
      return widget.onCrossDrop != null;
    }
    return !_wouldCycle(data.node, target);
  }

  Future<void> _toggleCollapse(FolderNode folder) async {
    folder.collapsed = !folder.collapsed;
    await widget.onTreeChanged();
    if (mounted) setState(() {});
  }

  // ── Build ──────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final palette = Theme.of(context).extension<AppPalette>()!;
    final entries = _flatten(widget.nodes, 0, null);

    if (entries.isEmpty) {
      return _gap(
        target: widget.nodes,
        folder: null,
        indexOf: () => widget.nodes.length,
        emptyLabel: 'Empty',
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final entry in entries)
          // Collapse/expand a super-section: rows inside it animate their
          // height + fade in BOTH directions (kept in the tree, hidden to 0).
          AnimatedCrossFade(
            key: ValueKey('tr_${entry.key}'),
            duration: const Duration(milliseconds: 260),
            sizeCurve: Curves.easeInOutCubic,
            firstCurve: Curves.easeInOutCubic,
            secondCurve: Curves.easeInOutCubic,
            crossFadeState: entry.hidden
                ? CrossFadeState.showSecond
                : CrossFadeState.showFirst,
            secondChild: const SizedBox(width: double.infinity),
            firstChild: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _gap(
                  target: entry.parent,
                  folder: entry.parentFolder,
                  indexOf: () => entry.parent.indexOf(entry.node),
                ),
                _buildRow(context, palette, entry),
              ],
            ),
          ),
        _gap(
          target: widget.nodes,
          folder: null,
          indexOf: () => widget.nodes.length,
          tall: true,
        ),
      ],
    );
  }

  Widget _gap({
    required List<TreeNode> target,
    required FolderNode? folder,
    required int Function() indexOf,
    bool tall = false,
    String? emptyLabel,
  }) {
    return DragTarget<_DragData>(
      onWillAcceptWithDetails: (d) => _accepts(d.data, target),
      onAcceptWithDetails: (d) => _drop(d.data, target, folder, indexOf()),
      builder: (context, candidate, rejected) {
        final palette = Theme.of(context).extension<AppPalette>()!;
        final active = candidate.isNotEmpty;
        if (emptyLabel != null) {
          return Container(
            padding: EdgeInsets.fromLTRB(widget.dense ? 20 : 24, 10, 16, 10),
            alignment: Alignment.centerLeft,
            color: active ? palette.accent.withValues(alpha: 0.1) : null,
            child: Text(
              emptyLabel,
              style: TextStyle(
                fontSize: widget.dense ? 12 : 13,
                color: palette.textDim,
              ),
            ),
          );
        }
        return Container(
          height: active ? 14 : (tall ? 24 : 6),
          alignment: Alignment.center,
          child: active
              ? Container(
                  height: 3,
                  margin: const EdgeInsets.symmetric(horizontal: 12),
                  decoration: BoxDecoration(
                    color: palette.accent,
                    borderRadius: BorderRadius.circular(2),
                  ),
                )
              : null,
        );
      },
    );
  }

  Widget _buildRow(BuildContext context, AppPalette palette, _FlatEntry entry) {
    final node = entry.node;
    final content = node is FolderNode
        ? _folderRow(context, palette, entry, node)
        : _leafRow(context, palette, entry, node as LeafNode);

    final row = LongPressDraggable<_DragData>(
      data: _DragData(node, widget.containerId, entry.parent),
      hapticFeedbackOnStart: true,
      feedback: _dragFeedback(context, palette, node),
      childWhenDragging: Opacity(opacity: 0.35, child: content),
      child: content,
    );

    // A row (leaf or whole super-section) being deleted collapses + fades out
    // before the reload drops it.
    final removing = _removingIds.contains(entry.key);
    return AnimatedSize(
      duration: _kRemoveAnim,
      curve: Curves.easeInOut,
      alignment: Alignment.topCenter,
      child: AnimatedOpacity(
        opacity: removing ? 0 : 1,
        duration: const Duration(milliseconds: 200),
        child: removing ? const SizedBox(width: double.infinity) : row,
      ),
    );
  }

  Widget _dragFeedback(
    BuildContext context,
    AppPalette palette,
    TreeNode node,
  ) {
    final theme = Theme.of(context);
    String label;
    IconData? icon;
    if (node is FolderNode) {
      label = node.name;
      icon = Icons.folder_outlined;
    } else {
      final item = widget.items[(node as LeafNode).refId];
      label = item == null ? '—' : widget.nameOf(item);
      icon = widget.leafIcon;
    }
    return Material(
      color: Colors.transparent,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          borderRadius: BorderRadius.circular(kRadius),
          border: Border.all(color: palette.accent),
          boxShadow: const [
            BoxShadow(
              color: Color(0x33000000),
              blurRadius: 12,
              offset: Offset(0, 4),
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, size: 16, color: palette.accent),
              const SizedBox(width: 8),
            ],
            Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
          ],
        ),
      ),
    );
  }

  Widget _leafRow(
    BuildContext context,
    AppPalette palette,
    _FlatEntry entry,
    LeafNode node,
  ) {
    final item = widget.items[node.refId];
    if (item == null) return const SizedBox.shrink();
    final id = widget.idOf(item);
    final selected = widget.selectedId == id;
    final glow = widget.glowId != null && widget.glowId == id;
    final color = AppPalette.resolveColor(id, widget.colorOf(item));

    return Material(
      color: selected ? palette.accentSoft : Colors.transparent,
      child: Stack(
        children: [
          // A brief accent wash that fades out, so search reveals are easy to
          // spot. Keyed by the glow id so it re-runs each time it's set.
          if (glow)
            Positioned.fill(
              child: IgnorePointer(child: _glowOverlay(palette, id)),
            ),
          InkWell(
            onTap: () => widget.onOpen(item),
        child: SizedBox(
          height: _rowHeight,
          child: Row(
            children: [
              _indentGuides(palette, entry.depth),
              SizedBox(width: widget.dense ? 12 : 16),
              // Identity color: a tinted icon when the row kind has one
              // (sections), else a short colored pill (canvases) — exclusive
              // so the leaf kind stays readable at a glance.
              if (widget.leafIcon != null) ...[
                Icon(widget.leafIcon, size: 15, color: color),
                const SizedBox(width: 8),
              ] else ...[
                Container(
                  width: 3,
                  height: widget.dense ? 14 : 18,
                  decoration: BoxDecoration(
                    color: color,
                    borderRadius: BorderRadius.circular(1.5),
                  ),
                ),
                const SizedBox(width: 9),
              ],
              Expanded(
                child: Text(
                  widget.nameOf(item),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: _fontSize,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                    color: selected ? palette.accent : null,
                  ),
                ),
              ),
              _leafMenu(context, palette, item, node),
              const SizedBox(width: 4),
            ],
          ),
        ),
          ),
        ],
      ),
    );
  }

  Widget _leafMenu(
    BuildContext context,
    AppPalette palette,
    T item,
    LeafNode node,
  ) {
    // Mobile (non-dense): a styled bottom sheet. Desktop keeps the popup.
    if (!widget.dense) {
      return IconButton(
        icon: Icon(Icons.more_vert, size: 18, color: palette.textDim),
        padding: EdgeInsets.zero,
        visualDensity: VisualDensity.compact,
        constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
        onPressed: () => showActionSheet(context, items: [
          ActionSheetItem(
              icon: Icons.edit_outlined,
              label: 'Rename',
              onTap: () => widget.onRenameLeaf(item)),
          ActionSheetItem(
              icon: Icons.palette_outlined,
              label: 'Change color',
              onTap: () => widget.onColorLeaf(item)),
          ActionSheetItem(
              icon: Icons.drive_file_move_outlined,
              label: 'Move to…',
              onTap: () => widget.onRelocate(node, copy: false)),
          ActionSheetItem(
              icon: Icons.copy_all_outlined,
              label: 'Copy to…',
              onTap: () => widget.onRelocate(node, copy: true)),
          if (widget.onExportLeaf != null)
            ActionSheetItem(
                icon: Icons.picture_as_pdf_outlined,
                label: 'Export to PDF',
                onTap: () => widget.onExportLeaf?.call(item)),
          ActionSheetItem(
              icon: Icons.delete_outline,
              label: 'Delete',
              destructive: true,
              onTap: () => _deleteLeaf(item)),
        ]),
      );
    }
    return PopupMenuButton<String>(
      icon: Icon(Icons.more_vert, size: 18, color: palette.textDim),
      padding: EdgeInsets.zero,
      onSelected: (action) {
        switch (action) {
          case 'rename':
            widget.onRenameLeaf(item);
          case 'color':
            widget.onColorLeaf(item);
          case 'move':
            widget.onRelocate(node, copy: false);
          case 'copy':
            widget.onRelocate(node, copy: true);
          case 'export':
            widget.onExportLeaf?.call(item);
          case 'delete':
            _deleteLeaf(item);
        }
      },
      itemBuilder: (context) => [
        iconMenuItem('rename', Icons.edit_outlined, 'Rename'),
        iconMenuItem('color', Icons.palette_outlined, 'Change color'),
        iconMenuItem('move', Icons.drive_file_move_outlined, 'Move to…'),
        iconMenuItem('copy', Icons.copy_all_outlined, 'Copy to…'),
        if (widget.onExportLeaf != null)
          iconMenuItem('export', Icons.picture_as_pdf_outlined,
              'Export to PDF'),
        iconMenuItem('delete', Icons.delete_outline, 'Delete',
            color: Theme.of(context).colorScheme.error),
      ],
    );
  }

  /// A fading accent wash + border used to briefly highlight a row the user
  /// just reached via search. Keyed by [id] so it restarts each reveal.
  Widget _glowOverlay(AppPalette palette, String id) {
    return TweenAnimationBuilder<double>(
      key: ValueKey('glow_$id'),
      tween: Tween(begin: 1, end: 0),
      duration: const Duration(milliseconds: 1600),
      curve: Curves.easeOut,
      builder: (context, t, _) => DecoratedBox(
        decoration: BoxDecoration(
          color: palette.accent.withValues(alpha: 0.28 * t),
          border: Border.all(
            color: palette.accent.withValues(alpha: 0.7 * t),
            width: 1.5,
          ),
          borderRadius: BorderRadius.circular(kRadius),
        ),
      ),
    );
  }

  Widget _folderRow(
    BuildContext context,
    AppPalette palette,
    _FlatEntry entry,
    FolderNode folder,
  ) {
    final color = AppPalette.resolveColor(folder.id, folder.color);
    final count = folder.collectLeafIds().length;
    final glow = widget.glowId != null && widget.glowId == folder.id;

    return DragTarget<_DragData>(
      onWillAcceptWithDetails: (d) => _accepts(d.data, folder.children),
      onAcceptWithDetails: (d) async {
        folder.collapsed = false;
        await _drop(d.data, folder.children, folder, folder.children.length);
      },
      builder: (context, candidate, rejected) {
        final active = candidate.isNotEmpty;
        return Material(
          // Rows stay neutral (OneNote-style); the folder's color lives in
          // its icon only.
          color: active
              ? palette.accent.withValues(alpha: 0.14)
              : Colors.transparent,
          child: Stack(
            children: [
              if (glow)
                Positioned.fill(
                  child: IgnorePointer(child: _glowOverlay(palette, folder.id)),
                ),
              InkWell(
            onTap: () => _toggleCollapse(folder),
            child: SizedBox(
              height: _rowHeight,
              child: Row(
                children: [
                  _indentGuides(palette, entry.depth),
                  SizedBox(width: widget.dense ? 3 : 7),
                  AnimatedRotation(
                    turns: folder.collapsed ? 0 : 0.25,
                    duration: const Duration(milliseconds: 150),
                    child: Icon(
                      Icons.chevron_right,
                      size: 18,
                      color: palette.textDim,
                    ),
                  ),
                  const SizedBox(width: 2),
                  Icon(Icons.folder, size: 15, color: color),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      folder.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: _fontSize,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  if (count > 0)
                    Padding(
                      padding: const EdgeInsets.only(right: 4),
                      child: Text(
                        '$count',
                        style: TextStyle(
                          fontSize: 11,
                          color: palette.textDim,
                          fontFamily: 'monospace',
                        ),
                      ),
                    ),
                  _folderMenu(context, palette, folder),
                  const SizedBox(width: 4),
                ],
              ),
            ),
          ),
            ],
          ),
        );
      },
    );
  }

  Widget _folderMenu(
    BuildContext context,
    AppPalette palette,
    FolderNode folder,
  ) {
    if (!widget.dense) {
      return IconButton(
        icon: Icon(Icons.more_vert, size: 18, color: palette.textDim),
        padding: EdgeInsets.zero,
        visualDensity: VisualDensity.compact,
        constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
        onPressed: () => showActionSheet(context, items: [
          ActionSheetItem(
              icon: Icons.add,
              label: 'New item',
              onTap: () => widget.onAddLeafToFolder(folder)),
          ActionSheetItem(
              icon: Icons.create_new_folder_outlined,
              label: 'New super-section',
              onTap: () => widget.onAddFolderToFolder(folder)),
          ActionSheetItem(
              icon: Icons.edit_outlined,
              label: 'Rename',
              onTap: () => widget.onRenameFolder(folder)),
          ActionSheetItem(
              icon: Icons.palette_outlined,
              label: 'Change color',
              onTap: () => widget.onColorFolder(folder)),
          ActionSheetItem(
              icon: Icons.drive_file_move_outlined,
              label: 'Move to…',
              onTap: () => widget.onRelocate(folder, copy: false)),
          ActionSheetItem(
              icon: Icons.copy_all_outlined,
              label: 'Copy to…',
              onTap: () => widget.onRelocate(folder, copy: true)),
          ActionSheetItem(
              icon: Icons.folder_off_outlined,
              label: 'Ungroup (keep items)',
              onTap: () => widget.onUngroup(folder)),
          ActionSheetItem(
              icon: Icons.delete_outline,
              label: 'Delete group + items',
              destructive: true,
              onTap: () => _deleteFolder(folder)),
        ]),
      );
    }
    return PopupMenuButton<String>(
      icon: Icon(Icons.more_vert, size: 18, color: palette.textDim),
      padding: EdgeInsets.zero,
      onSelected: (action) {
        switch (action) {
          case 'add_leaf':
            widget.onAddLeafToFolder(folder);
          case 'add_folder':
            widget.onAddFolderToFolder(folder);
          case 'rename':
            widget.onRenameFolder(folder);
          case 'color':
            widget.onColorFolder(folder);
          case 'move':
            widget.onRelocate(folder, copy: false);
          case 'copy':
            widget.onRelocate(folder, copy: true);
          case 'ungroup':
            widget.onUngroup(folder);
          case 'delete':
            _deleteFolder(folder);
        }
      },
      itemBuilder: (context) => [
        iconMenuItem('add_leaf', Icons.add, 'New item'),
        iconMenuItem('add_folder', Icons.create_new_folder_outlined,
            'New super-section'),
        const PopupMenuDivider(),
        iconMenuItem('rename', Icons.edit_outlined, 'Rename'),
        iconMenuItem('color', Icons.palette_outlined, 'Change color'),
        iconMenuItem('move', Icons.drive_file_move_outlined, 'Move to…'),
        iconMenuItem('copy', Icons.copy_all_outlined, 'Copy to…'),
        iconMenuItem('ungroup', Icons.folder_off_outlined,
            'Ungroup (keep items)'),
        iconMenuItem('delete', Icons.delete_outline, 'Delete group + items',
            color: Theme.of(context).colorScheme.error),
      ],
    );
  }
}
