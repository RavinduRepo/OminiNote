import 'dart:async';
import 'package:flutter/material.dart';
import '../models/canvas.dart';
import '../models/section.dart';
import '../models/tree.dart';
import '../services/notebook_service.dart';
import '../services/sync_service.dart';
import '../theme/app_theme.dart';
import '../utils/new_canvas_ui.dart';
import '../widgets/color_swatch_picker.dart';
import '../widgets/item_tree_view.dart';
import '../widgets/location_picker.dart';
import '../widgets/refreshable_empty.dart';
import 'canvas_screen.dart';
import 'note_search.dart'; // searchRouteObserver (glow-on-reveal)

/// Mobile screen 3: a section's tree of **canvases** + nested super-sections.
/// Tapping a canvas opens the drawing surface (`CanvasScreen`).
class SectionScreen extends StatefulWidget {
  final Section section;

  /// A canvas / super-section id to briefly glow when reached via search.
  final String? glowId;

  const SectionScreen({super.key, required this.section, this.glowId});

  @override
  State<SectionScreen> createState() => _SectionScreenState();
}

class _SectionScreenState extends State<SectionScreen> with RouteAware {
  final _service = NotebookService();
  Section? _section;
  Map<String, Canvas> _canvases = {};
  String? _glowId;
  Timer? _glowTimer;

  @override
  void initState() {
    super.initState();
    _reload();
    if (widget.glowId != null) _startGlow();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route is PageRoute) searchRouteObserver.subscribe(this, route);
  }

  @override
  void didPopNext() {
    // Popped back from an opened canvas — re-glow the canvas we came from.
    if (widget.glowId != null) _startGlow();
  }

  void _startGlow() {
    _glowTimer?.cancel();
    setState(() => _glowId = widget.glowId);
    _glowTimer = Timer(const Duration(milliseconds: 1800), () {
      if (mounted) setState(() => _glowId = null);
    });
  }

  @override
  void dispose() {
    _glowTimer?.cancel();
    searchRouteObserver.unsubscribe(this);
    super.dispose();
  }

  Future<void> _reload() async {
    final sec = await _service.getSection(
      widget.section.notebookId,
      widget.section.id,
    );
    final s = sec ?? widget.section;
    final map = await _service.getCanvasMap(s);
    if (!mounted) return;
    setState(() {
      _section = s;
      _canvases = map;
    });
  }

  // ── Actions ─────────────────────────────────────────────────────────

  Future<void> _addCanvas({String? folderId}) async {
    final kind = await pickNewCanvasKind(context);
    if (kind == null || !mounted) return;
    final Canvas canvas;
    if (kind == NewCanvasKind.pdf) {
      final c =
          await pickAndCreatePdfCanvas(context, _section!, parentFolderId: folderId);
      if (c == null) return;
      canvas = c;
    } else {
      final name = await _prompt(title: 'New canvas', hint: 'Canvas name');
      if (name == null || name.isEmpty) return;
      canvas = await _service.createCanvas(
        _section!,
        name,
        parentFolderId: folderId,
      );
    }
    await _reload();
    if (!mounted) return;
    // Root navigator so the canvas editor covers the mobile bottom nav bar.
    Navigator.of(context, rootNavigator: true).push(
      slideRoute(CanvasScreen(canvas: canvas)),
    ).then((_) => _reload());
  }

  Future<void> _addFolder({String? folderId}) async {
    final name = await _prompt(title: 'New super-section', hint: 'Group name');
    if (name == null || name.isEmpty) return;
    await _service.createCanvasFolder(_section!, name, parentFolderId: folderId);
    await _reload();
  }

  void _openCanvas(Canvas canvas) {
    // Root navigator so the canvas editor covers the mobile bottom nav bar.
    Navigator.of(context, rootNavigator: true).push(
      slideRoute(CanvasScreen(canvas: canvas)),
    ).then((_) => _reload());
  }

  Future<void> _renameCanvas(Canvas canvas) async {
    final name = await _prompt(
      title: 'Rename canvas',
      hint: 'Canvas name',
      initial: canvas.name,
      cta: 'Rename',
    );
    if (name == null || name.isEmpty) return;
    await _service.renameCanvas(canvas, name);
    await _reload();
  }

  Future<void> _colorCanvas(Canvas canvas) async {
    final choice = await showColorSwatchPicker(context, current: canvas.color);
    if (choice == null) return;
    await _service.setCanvasColor(canvas, choice.color);
    await _reload();
  }

  Future<void> _deleteCanvas(Canvas canvas) async {
    await _service.deleteCanvas(_section!, canvas.id);
    await _reload();
  }

  Future<void> _renameFolder(FolderNode folder) async {
    final name = await _prompt(
      title: 'Rename super-section',
      hint: 'Group name',
      initial: folder.name,
      cta: 'Rename',
    );
    if (name == null || name.isEmpty) return;
    folder.name = name;
    await _service.saveSection(_section!);
    if (mounted) setState(() {});
  }

  Future<void> _colorFolder(FolderNode folder) async {
    final choice = await showColorSwatchPicker(context, current: folder.color);
    if (choice == null) return;
    folder.color = choice.color;
    await _service.saveSection(_section!);
    if (mounted) setState(() {});
  }

  Future<void> _ungroup(FolderNode folder) async {
    await _service.ungroupInSection(_section!, folder.id);
    await _reload();
  }

  // No confirm — recoverable from the recycle bin like any other delete.
  Future<void> _deleteFolder(FolderNode folder) async {
    await _service.deleteCanvasFolder(_section!, folder.id);
    await _reload();
  }

  Future<void> _relocate(TreeNode node, {required bool copy}) async {
    final dst = await pickSectionDestination(
      context,
      title: copy ? 'Copy to section' : 'Move to section',
    );
    if (dst == null) return;
    if (copy) {
      await _service.copyCanvasNode(
        widget.section.notebookId,
        widget.section.id,
        node,
        dst.notebookId,
        dst.sectionId,
      );
    } else {
      await _service.moveCanvasNode(
        widget.section.notebookId,
        widget.section.id,
        node,
        dst.notebookId,
        dst.sectionId,
      );
    }
    await _reload();
  }

  // ── Dialogs ─────────────────────────────────────────────────────────

  Future<String?> _prompt({
    required String title,
    required String hint,
    String initial = '',
    String cta = 'Create',
  }) {
    final controller = TextEditingController(text: initial);
    controller.selection = TextSelection(
      baseOffset: 0,
      extentOffset: initial.length,
    );
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          textCapitalization: TextCapitalization.sentences,
          decoration: InputDecoration(hintText: hint),
          onSubmitted: (v) => Navigator.pop(context, v.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: Text(cta),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final section = _section;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.section.name),
        actions: [
          PopupMenuButton<String>(
            icon: const Icon(Icons.add),
            tooltip: 'Add',
            onSelected: (action) {
              if (action == 'canvas') _addCanvas();
              if (action == 'group') _addFolder();
            },
            itemBuilder: (context) => const [
              PopupMenuItem(value: 'canvas', child: Text('New canvas')),
              PopupMenuItem(value: 'group', child: Text('New super-section')),
            ],
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: section == null
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _refresh,
              child: section.nodes.isEmpty
                  ? RefreshableEmpty(child: _EmptyState(onAdd: _addCanvas))
                  : SingleChildScrollView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: const EdgeInsets.only(top: 4, bottom: 24),
                      child: ItemTreeView<Canvas>(
                        containerId: section.id,
                        nodes: section.nodes,
                        items: _canvases,
                        nameOf: (c) => c.name,
                        colorOf: (c) => c.color,
                        idOf: (c) => c.id,
                        // No leaf icon — the colored identity pill is enough.
                        selectedId: null,
                        glowId: _glowId,
                        onOpen: _openCanvas,
                        onRenameLeaf: _renameCanvas,
                        onColorLeaf: _colorCanvas,
                        onDeleteLeaf: _deleteCanvas,
                        onRenameFolder: _renameFolder,
                        onColorFolder: _colorFolder,
                        onAddLeafToFolder: (f) => _addCanvas(folderId: f.id),
                        onAddFolderToFolder: (f) => _addFolder(folderId: f.id),
                        onUngroup: _ungroup,
                        onDeleteFolder: _deleteFolder,
                        onRelocate: _relocate,
                        onTreeChanged: () => _service.saveSection(section),
                      ),
                    ),
            ),
    );
  }

  /// Pull-to-refresh: run a sync round trip, then reload the tree.
  Future<void> _refresh() async {
    await SyncService().syncNow();
    await _reload();
  }
}

class _EmptyState extends StatelessWidget {
  final VoidCallback onAdd;
  const _EmptyState({required this.onAdd});

  @override
  Widget build(BuildContext context) {
    final palette = Theme.of(context).extension<AppPalette>()!;
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.edit_note_outlined, size: 56, color: palette.textDim),
          const SizedBox(height: 18),
          Text(
            'No canvases yet',
            style: TextStyle(color: palette.textDim, fontSize: 15),
          ),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: onAdd,
            icon: const Icon(Icons.add),
            label: const Text('New canvas'),
          ),
        ],
      ),
    );
  }
}
