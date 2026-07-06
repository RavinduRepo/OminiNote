import 'package:flutter/material.dart';
import '../models/notebook.dart';
import '../services/notebook_service.dart';
import '../theme/app_theme.dart';
import '../utils/formatting.dart';
import '../widgets/color_swatch_picker.dart';
import 'notebook_screen.dart';
import 'settings_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _notebookService = NotebookService();
  List<Notebook>? _notebooks;

  @override
  void initState() {
    super.initState();
    _loadNotebooks();
  }

  Future<void> _loadNotebooks() async {
    final notebooks = await _notebookService.getNotebooks();
    if (!mounted) return;
    setState(() => _notebooks = notebooks);
  }

  Future<void> _createNotebook() async {
    final name = await _promptForName(title: 'New notebook');
    if (name == null || name.isEmpty) return;
    await _notebookService.createNotebook(name);
    _loadNotebooks();
  }

  Future<void> _renameNotebook(Notebook notebook) async {
    final name = await _promptForName(
      title: 'Rename notebook',
      initial: notebook.name,
      cta: 'Rename',
    );
    if (name == null || name.isEmpty) return;
    await _notebookService.renameNotebook(notebook.id, name);
    _loadNotebooks();
  }

  Future<void> _colorNotebook(Notebook notebook) async {
    final choice = await showColorSwatchPicker(context, current: notebook.color);
    if (choice == null) return;
    await _notebookService.setNotebookColor(notebook.id, choice.color);
    _loadNotebooks();
  }

  Future<void> _deleteNotebook(Notebook notebook) async {
    await _notebookService.deleteNotebook(notebook.id);
    _loadNotebooks();
  }

  Future<void> _reorderNotebooks(int oldIndex, int newIndex) async {
    final list = _notebooks;
    if (list == null) return;
    if (newIndex > oldIndex) newIndex--;
    setState(() {
      final nb = list.removeAt(oldIndex);
      list.insert(newIndex, nb);
    });
    await _notebookService.reorderNotebooks([for (final n in list) n.id]);
  }

  Future<String?> _promptForName({
    required String title,
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
          decoration: const InputDecoration(hintText: 'Notebook name'),
          onSubmitted: (value) => Navigator.pop(context, value.trim()),
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
    final notebooks = _notebooks;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Notebooks'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: 'Settings',
            onPressed: () => Navigator.push(
              context,
              fadeThroughRoute(const SettingsScreen()),
            ),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: notebooks == null
          ? const Center(child: CircularProgressIndicator())
          : notebooks.isEmpty
          ? _EmptyState(onCreate: _createNotebook)
          : ReorderableListView.builder(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
              itemCount: notebooks.length,
              onReorder: _reorderNotebooks,
              proxyDecorator: (child, index, animation) =>
                  Material(color: Colors.transparent, child: child),
              itemBuilder: (context, index) {
                final notebook = notebooks[index];
                return Padding(
                  key: ValueKey(notebook.id),
                  padding: const EdgeInsets.only(bottom: 8),
                  child: _NotebookRow(
                    notebook: notebook,
                    index: index,
                    onTap: () {
                      Navigator.push(
                        context,
                        fadeThroughRoute(NotebookScreen(notebook: notebook)),
                      ).then((_) => _loadNotebooks());
                    },
                    onRename: () => _renameNotebook(notebook),
                    onColor: () => _colorNotebook(notebook),
                    onDelete: () => _deleteNotebook(notebook),
                  ),
                );
              },
            ),
      floatingActionButton: FloatingActionButton(
        onPressed: _createNotebook,
        tooltip: 'New notebook',
        child: const Icon(Icons.add),
      ),
    );
  }
}

class _NotebookRow extends StatelessWidget {
  final Notebook notebook;
  final int index;
  final VoidCallback onTap;
  final VoidCallback onRename;
  final VoidCallback onColor;
  final VoidCallback onDelete;

  const _NotebookRow({
    required this.notebook,
    required this.index,
    required this.onTap,
    required this.onRename,
    required this.onColor,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = theme.extension<AppPalette>()!;
    final identity = AppPalette.resolveColor(notebook.id, notebook.color);
    final count = notebook.sectionCount;

    return Material(
      color: theme.colorScheme.surface,
      borderRadius: BorderRadius.circular(kRadius),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(kRadius),
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(kRadius),
            border: Border.all(color: palette.border),
          ),
          padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
          child: Row(
            children: [
              Container(
                width: 4,
                height: 34,
                decoration: BoxDecoration(
                  color: identity,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      notebook.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      '${formatCount(count)} ${count == 1 ? 'section' : 'sections'} · ${formatShortDate(notebook.createdAt)}',
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 11.5,
                        color: palette.textDim,
                      ),
                    ),
                  ],
                ),
              ),
              _RowMenu(
                onRename: onRename,
                onColor: onColor,
                onDelete: onDelete,
              ),
              ReorderableDragStartListener(
                index: index,
                child: Padding(
                  padding: const EdgeInsets.only(left: 2, right: 6),
                  child: Icon(
                    Icons.drag_indicator,
                    color: palette.textDim,
                    size: 20,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RowMenu extends StatelessWidget {
  final VoidCallback onRename;
  final VoidCallback onColor;
  final VoidCallback onDelete;
  const _RowMenu({
    required this.onRename,
    required this.onColor,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final palette = Theme.of(context).extension<AppPalette>()!;
    return PopupMenuButton<String>(
      icon: Icon(Icons.more_vert, color: palette.textDim, size: 20),
      onSelected: (value) {
        if (value == 'rename') onRename();
        if (value == 'color') onColor();
        if (value == 'delete') onDelete();
      },
      itemBuilder: (context) => [
        const PopupMenuItem(
          value: 'rename',
          child: Row(
            children: [
              Icon(Icons.edit_outlined, size: 18),
              SizedBox(width: 10),
              Text('Rename'),
            ],
          ),
        ),
        const PopupMenuItem(
          value: 'color',
          child: Row(
            children: [
              Icon(Icons.palette_outlined, size: 18),
              SizedBox(width: 10),
              Text('Change color'),
            ],
          ),
        ),
        PopupMenuItem(
          value: 'delete',
          child: Row(
            children: [
              Icon(
                Icons.delete_outline,
                size: 18,
                color: Theme.of(context).colorScheme.error,
              ),
              const SizedBox(width: 10),
              Text(
                'Delete',
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _EmptyState extends StatelessWidget {
  final VoidCallback onCreate;
  const _EmptyState({required this.onCreate});

  @override
  Widget build(BuildContext context) {
    final palette = Theme.of(context).extension<AppPalette>()!;
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.auto_stories_outlined, size: 56, color: palette.textDim),
          const SizedBox(height: 18),
          Text(
            'No notebooks yet',
            style: TextStyle(color: palette.textDim, fontSize: 15),
          ),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: onCreate,
            icon: const Icon(Icons.add),
            label: const Text('Create notebook'),
          ),
        ],
      ),
    );
  }
}
