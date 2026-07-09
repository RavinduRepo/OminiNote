import 'package:flutter/material.dart';
import '../models/notebook.dart';
import '../services/auth_service.dart';
import '../services/notebook_service.dart';
import '../services/settings_service.dart';
import '../services/sync_service.dart';
import '../theme/app_theme.dart';
import '../utils/formatting.dart';
import '../widgets/color_swatch_picker.dart';
import '../widgets/refreshable_empty.dart';
import '../utils/pdf_export_ui.dart';
import 'note_search.dart';
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
    SyncService().dataVersion.addListener(_onSyncData);
  }

  @override
  void dispose() {
    SyncService().dataVersion.removeListener(_onSyncData);
    super.dispose();
  }

  void _onSyncData() {
    if (mounted) _loadNotebooks();
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

  Future<void> _exportNotebookPdf(Notebook notebook) async {
    final items = await _notebookService.collectNotebookExportItems(notebook);
    if (!mounted) return;
    await runTreeExport(context, items: items, fileName: notebook.name);
  }

  Future<void> _toggleSync(Notebook notebook) async {
    final makeLocal = !SettingsService().isNotebookLocalOnly(notebook.id);
    if (makeLocal) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Keep only on this device?'),
          content: Text(
            '"${notebook.name}" will stop syncing on this device — no uploads '
            'and no changes pulled from other devices. This is a per-device '
            'choice; other devices can still sync their own copy. Content '
            'already on Drive stays there until you delete it.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Make local-only'),
            ),
          ],
        ),
      );
      if (ok != true) return;
    }
    await _notebookService.setNotebookLocalOnly(notebook.id, makeLocal);
    // Re-enabling: catch up on anything missed while disconnected.
    if (!makeLocal && AuthService().isSignedIn) SyncService().repair();
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
    final choice = await showColorSwatchPicker(
      context,
      current: notebook.color,
    );
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
            icon: const Icon(Icons.search),
            tooltip: 'Search',
            onPressed: () => openNoteSearch(context),
          ),
          // Single, consistent add entry point across all list screens: the
          // app-bar "+" (the old FAB overlapped the last row's ⋮ menu).
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: 'New notebook',
            onPressed: _createNotebook,
          ),
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
          : RefreshIndicator(
              onRefresh: _refresh,
              child: notebooks.isEmpty
                  ? RefreshableEmpty(
                      child: _EmptyState(onCreate: _createNotebook),
                    )
                  : ReorderableListView.builder(
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                      itemCount: notebooks.length,
                      buildDefaultDragHandles: false,
                      onReorder: _reorderNotebooks,
                      proxyDecorator: (child, index, animation) =>
                          Material(color: Colors.transparent, child: child),
                      itemBuilder: (context, index) {
                        final notebook = notebooks[index];
                        return Padding(
                          key: ValueKey(notebook.id),
                          padding: const EdgeInsets.only(bottom: 8),
                          // Long-press anywhere on the card to reorder — no
                          // visible drag handle.
                          child: ReorderableDelayedDragStartListener(
                            index: index,
                            child: _NotebookRow(
                              notebook: notebook,
                              onTap: () {
                                Navigator.push(
                                  context,
                                  fadeThroughRoute(
                                    NotebookScreen(notebook: notebook),
                                  ),
                                ).then((_) => _loadNotebooks());
                              },
                              onRename: () => _renameNotebook(notebook),
                              onColor: () => _colorNotebook(notebook),
                              onExport: () => _exportNotebookPdf(notebook),
                              onToggleSync: () => _toggleSync(notebook),
                              onDelete: () => _deleteNotebook(notebook),
                            ),
                          ),
                        );
                      },
                    ),
            ),
    );
  }

  /// Pull-to-refresh: run a sync round trip, then reload the list.
  Future<void> _refresh() async {
    await SyncService().syncNow();
    await _loadNotebooks();
  }
}

class _NotebookRow extends StatelessWidget {
  final Notebook notebook;
  final VoidCallback onTap;
  final VoidCallback onRename;
  final VoidCallback onColor;
  final VoidCallback onExport;
  final VoidCallback onToggleSync;
  final VoidCallback onDelete;

  const _NotebookRow({
    required this.notebook,
    required this.onTap,
    required this.onRename,
    required this.onColor,
    required this.onExport,
    required this.onToggleSync,
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
          padding: const EdgeInsets.fromLTRB(12, 12, 6, 12),
          child: Row(
            children: [
              // Solid initial chip: notebooks read as the top-level item
              // (matches the desktop sidebar's collapsed rail).
              Container(
                width: 38,
                height: 38,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: identity,
                  borderRadius: BorderRadius.circular(kRadius),
                ),
                child: Text(
                  notebook.name.isNotEmpty
                      ? notebook.name[0].toUpperCase()
                      : '?',
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                    fontSize: 16,
                  ),
                ),
              ),
              const SizedBox(width: 12),
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
                        fontWeight: FontWeight.w700,
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
                onExport: onExport,
                onToggleSync: onToggleSync,
                isLocalOnly: SettingsService().isNotebookLocalOnly(notebook.id),
                onDelete: onDelete,
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
  final VoidCallback onExport;
  final VoidCallback onToggleSync;
  final bool isLocalOnly;
  final VoidCallback onDelete;
  const _RowMenu({
    required this.onRename,
    required this.onColor,
    required this.onExport,
    required this.onToggleSync,
    required this.isLocalOnly,
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
        if (value == 'export') onExport();
        if (value == 'sync') onToggleSync();
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
        const PopupMenuItem(
          value: 'export',
          child: Row(
            children: [
              Icon(Icons.picture_as_pdf_outlined, size: 18),
              SizedBox(width: 10),
              Text('Export to PDF'),
            ],
          ),
        ),
        PopupMenuItem(
          value: 'sync',
          child: Row(
            children: [
              Icon(
                isLocalOnly ? Icons.cloud_upload_outlined : Icons.cloud_off_outlined,
                size: 18,
              ),
              const SizedBox(width: 10),
              Text(isLocalOnly ? 'Enable cloud sync' : 'Make local-only'),
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
