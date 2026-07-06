import 'package:flutter/material.dart';
import '../models/notebook.dart';
import '../models/section.dart';
import '../models/tree.dart';
import '../services/notebook_service.dart';
import '../theme/app_theme.dart';
import '../widgets/color_swatch_picker.dart';
import '../widgets/item_tree_view.dart';
import '../widgets/location_picker.dart';
import 'section_screen.dart';

/// Mobile screen 2: a notebook's tree of **sections** + nested super-sections.
/// Tapping a section opens its canvas list (`SectionScreen`).
class NotebookScreen extends StatefulWidget {
  final Notebook notebook;

  const NotebookScreen({super.key, required this.notebook});

  @override
  State<NotebookScreen> createState() => _NotebookScreenState();
}

class _NotebookScreenState extends State<NotebookScreen> {
  final _service = NotebookService();
  Notebook? _notebook;
  Map<String, Section> _sections = {};

  @override
  void initState() {
    super.initState();
    _reload();
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
      fadeThroughRoute(SectionScreen(section: section)),
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

  Future<void> _deleteFolder(FolderNode folder) async {
    final count = folder.collectLeafIds().length;
    final ok = await _confirm(
      'Delete super-section?',
      count == 0
          ? '"${folder.name}" will be deleted.'
          : '"${folder.name}" and its $count section(s) will be permanently deleted.',
    );
    if (!ok) return;
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

  Future<bool> _confirm(String title, String message) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  @override
  Widget build(BuildContext context) {
    final notebook = _notebook;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.notebook.name),
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
          : notebook.nodes.isEmpty
          ? _EmptyState(onAdd: _addSection)
          : SingleChildScrollView(
              padding: const EdgeInsets.only(top: 4, bottom: 96),
              child: ItemTreeView<Section>(
                containerId: notebook.id,
                nodes: notebook.nodes,
                items: _sections,
                nameOf: (s) => s.name,
                colorOf: (s) => s.color,
                idOf: (s) => s.id,
                leafIcon: Icons.description_outlined,
                selectedId: null,
                onOpen: _openSection,
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
      floatingActionButton: FloatingActionButton(
        onPressed: _addSection,
        tooltip: 'New section',
        child: const Icon(Icons.add),
      ),
    );
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
