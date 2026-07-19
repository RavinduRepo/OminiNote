import 'dart:async';
import 'package:flutter/material.dart';
import '../models/notebook.dart';
import '../models/section.dart';
import '../models/tree.dart';
import '../services/notebook_service.dart';
import '../services/sync_service.dart';
import '../theme/app_theme.dart';
import '../utils/pdf_export_ui.dart';
import '../widgets/color_swatch_picker.dart';
import '../widgets/item_tree_view.dart';
import '../widgets/location_picker.dart';
import '../widgets/refreshable_empty.dart';
import 'note_search.dart'; // searchRouteObserver (glow-on-reveal)
import 'section_screen.dart';

/// Mobile screen 2: a notebook's tree of **sections** + nested super-sections.
/// Tapping a section opens its canvas list (`SectionScreen`).
class NotebookScreen extends StatefulWidget {
  final Notebook notebook;

  /// A section / super-section id to briefly glow when reached via search (so
  /// the mobile flow highlights the target like the desktop shell does).
  final String? glowId;

  const NotebookScreen({super.key, required this.notebook, this.glowId});

  @override
  State<NotebookScreen> createState() => _NotebookScreenState();
}

class _NotebookScreenState extends State<NotebookScreen> with RouteAware {
  final _service = NotebookService();
  Notebook? _notebook;
  Map<String, Section> _sections = {};
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
    // A screen above was popped and we're visible again — re-glow the target.
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
    final nb = await _service.getNotebook(widget.notebook.id);
    final map = await _service.getSectionMap(widget.notebook.id);
    if (!mounted) return;
    setState(() {
      _notebook = nb ?? widget.notebook;
      _sections = map;
    });
  }

  // ── Actions ─────────────────────────────────────────────────────────

  Future<void> _exportSectionPdf(Section section) async {
    final items = await _service.collectSectionExportItems(section);
    if (!mounted) return;
    await runTreeExport(context, items: items, fileName: section.name);
  }

  Future<void> _addSection({String? folderId}) async {
    final name = await _prompt(title: 'New section', hint: 'Section name');
    if (name == null || name.isEmpty) return;
    await _service.createSection(
      widget.notebook.id,
      name,
      parentFolderId: folderId,
    );
    await _reload();
  }

  Future<void> _addFolder({String? folderId}) async {
    final name = await _prompt(title: 'New super-section', hint: 'Group name');
    if (name == null || name.isEmpty) return;
    await _service.createSectionFolder(
      _notebook!,
      name,
      parentFolderId: folderId,
    );
    await _reload();
  }

  void _openSection(Section section) {
    Navigator.push(
      context,
      slideRoute(SectionScreen(section: section)),
    ).then((_) => _reload());
  }

  Future<void> _renameSection(Section section) async {
    final name = await _prompt(
      title: 'Rename section',
      hint: 'Section name',
      initial: section.name,
      cta: 'Rename',
    );
    if (name == null || name.isEmpty) return;
    await _service.renameSection(section, name);
    await _reload();
  }

  Future<void> _colorSection(Section section) async {
    final choice = await showColorSwatchPicker(context, current: section.color);
    if (choice == null) return;
    await _service.setSectionColor(section, choice.color);
    await _reload();
  }

  Future<void> _deleteSection(Section section) async {
    await _service.deleteSection(widget.notebook.id, section.id);
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
    await _service.saveNotebook(_notebook!);
    if (mounted) setState(() {});
  }

  Future<void> _colorFolder(FolderNode folder) async {
    final choice = await showColorSwatchPicker(context, current: folder.color);
    if (choice == null) return;
    folder.color = choice.color;
    await _service.saveNotebook(_notebook!);
    if (mounted) setState(() {});
  }

  Future<void> _ungroup(FolderNode folder) async {
    await _service.ungroupInNotebook(_notebook!, folder.id);
    await _reload();
  }

  // No confirm — a deleted super-section (and its contents) is recoverable
  // from the recycle bin, same as any other delete.
  Future<void> _deleteFolder(FolderNode folder) async {
    await _service.deleteSectionFolder(_notebook!, folder.id);
    await _reload();
  }

  Future<void> _relocate(TreeNode node, {required bool copy}) async {
    final dst = await pickNotebookDestination(
      context,
      title: copy ? 'Copy to notebook' : 'Move to notebook',
    );
    if (dst == null) return;
    if (copy) {
      await _service.copySectionNode(widget.notebook.id, node, dst);
    } else {
      await _service.moveSectionNode(widget.notebook.id, node, dst);
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
    final notebook = _notebook;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.notebook.name),
        titleSpacing: 4,
        leadingWidth: 40,
        leading: IconButton(
          padding: EdgeInsets.zero,
          icon: const Icon(kBackIcon),
          tooltip: 'Back',
          onPressed: () => Navigator.of(context).pop(),
        ),
        actions: [
          PopupMenuButton<String>(
            icon: const Icon(Icons.add),
            tooltip: 'Add',
            onSelected: (action) {
              if (action == 'section') _addSection();
              if (action == 'group') _addFolder();
            },
            itemBuilder: (context) => const [
              PopupMenuItem(value: 'section', child: Text('New section')),
              PopupMenuItem(value: 'group', child: Text('New super-section')),
            ],
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: notebook == null
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _refresh,
              child: notebook.nodes.isEmpty
                  ? RefreshableEmpty(child: _EmptyState(onAdd: _addSection))
                  : SingleChildScrollView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: const EdgeInsets.only(top: 4, bottom: 24),
                      child: ItemTreeView<Section>(
                containerId: notebook.id,
                nodes: notebook.nodes,
                items: _sections,
                nameOf: (s) => s.name,
                colorOf: (s) => s.color,
                idOf: (s) => s.id,
                leafIcon: Icons.description_outlined,
                selectedId: null,
                glowId: _glowId,
                onOpen: _openSection,
                onExportLeaf: _exportSectionPdf,
                onRenameLeaf: _renameSection,
                onColorLeaf: _colorSection,
                onDeleteLeaf: _deleteSection,
                onRenameFolder: _renameFolder,
                onColorFolder: _colorFolder,
                onAddLeafToFolder: (f) => _addSection(folderId: f.id),
                onAddFolderToFolder: (f) => _addFolder(folderId: f.id),
                        onUngroup: _ungroup,
                        onDeleteFolder: _deleteFolder,
                        onRelocate: _relocate,
                        onTreeChanged: () => _service.saveNotebook(notebook),
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
          Icon(Icons.folder_open_outlined, size: 56, color: palette.textDim),
          const SizedBox(height: 18),
          Text(
            'No sections yet',
            style: TextStyle(color: palette.textDim, fontSize: 15),
          ),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: onAdd,
            icon: const Icon(Icons.add),
            label: const Text('New section'),
          ),
        ],
      ),
    );
  }
}
