import 'dart:async';

import 'package:flutter/material.dart';
import '../models/link.dart';
import '../models/notebook.dart';
import '../services/notebook_service.dart';
import '../services/settings_service.dart';
import '../services/sync_service.dart';
import '../theme/app_theme.dart';
import '../utils/formatting.dart';
import '../widgets/action_sheet.dart';
import '../widgets/color_swatch_picker.dart';
import '../widgets/connections_sheet.dart';
import '../widgets/notebook_account_badge.dart';
import '../widgets/refreshable_empty.dart';
import '../widgets/sync_status_icon.dart';
import '../utils/pdf_export_ui.dart';
import '../utils/sync_target_ui.dart';
import '../utils/notebook_share_ui.dart';
import 'notebook_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  /// One-shot glow request: the mobile shell sets a notebook id here when an
  /// internal link targets a notebook — the home list (this tab root, kept
  /// alive) briefly glows that card instead of auto-opening the notebook
  /// (the mobile "stop one level up" link-navigation rule).
  static final ValueNotifier<String?> glowRequest = ValueNotifier(null);

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _notebookService = NotebookService();
  List<Notebook>? _notebooks;

  // Id of the notebook currently animating out on delete (collapse + fade).
  String? _removingId;
  static const _kRemoveAnim = Duration(milliseconds: 280);

  // Card briefly highlighted after arriving via an internal link.
  String? _glowId;
  Timer? _glowTimer;

  @override
  void initState() {
    super.initState();
    _loadNotebooks();
    SyncService().dataVersion.addListener(_onSyncData);
    HomeScreen.glowRequest.addListener(_onGlowRequest);
  }

  @override
  void dispose() {
    HomeScreen.glowRequest.removeListener(_onGlowRequest);
    _glowTimer?.cancel();
    SyncService().dataVersion.removeListener(_onSyncData);
    super.dispose();
  }

  void _onGlowRequest() {
    final id = HomeScreen.glowRequest.value;
    if (id == null || !mounted) return;
    HomeScreen.glowRequest.value = null; // consumed
    _glowTimer?.cancel();
    setState(() => _glowId = id);
    _glowTimer = Timer(const Duration(milliseconds: 1800), () {
      if (mounted) setState(() => _glowId = null);
    });
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
    if (!mounted) return;
    final target = await chooseNewNotebookAccount(context);
    if (target == null) return; // cancelled the account picker
    final nb =
        await _notebookService.createNotebook(name, syncTarget: target.accountId);
    if (target.localOnly) {
      await _notebookService.setNotebookLocalOnly(nb.id, true);
    }
    _loadNotebooks();
  }

  Future<void> _exportNotebookPdf(Notebook notebook) async {
    final items = await _notebookService.collectNotebookExportItems(notebook);
    if (!mounted) return;
    await runTreeExport(context, items: items, fileName: notebook.name);
  }

  Future<void> _pickSyncTarget(Notebook notebook) async {
    final changed = await showSyncTargetPicker(context, notebook);
    if (changed && mounted) _loadNotebooks();
  }

  Future<void> _importNotebook() async {
    final nb = await importNotebookCopy(context);
    if (nb != null && mounted) _loadNotebooks();
  }

  Future<void> _shareNotebook(Notebook notebook) =>
      shareNotebookCopy(context, notebook);

  Future<void> _shareNotebookLink(Notebook notebook) =>
      shareNotebookLink(context, notebook);

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
    setState(() => _removingId = notebook.id); // collapse + fade the row out
    await Future.delayed(_kRemoveAnim);
    await _notebookService.deleteNotebook(notebook.id);
    _removingId = null;
    _loadNotebooks();
  }

  /// Toggle this device's default landing notebook (device-local; where quick
  /// PDF imports / opened PDFs go). Tapping the current default clears it.
  Future<void> _toggleDefaultNotebook(Notebook notebook) async {
    final settings = SettingsService();
    final makeDefault = settings.defaultNotebookId != notebook.id;
    await settings.setDefaultNotebook(makeDefault ? notebook.id : null);
    if (mounted) setState(() {});
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
          // Search and Settings now live in the bottom navigation bar. The
          // app bar keeps the sync status + add, consistent with the desktop
          // notebooks-pane header.
          const SyncStatusIcon(),
          PopupMenuButton<String>(
            icon: const Icon(Icons.add),
            tooltip: 'Add',
            onSelected: (v) {
              if (v == 'new') _createNotebook();
              if (v == 'import') _importNotebook();
            },
            itemBuilder: (context) => const [
              PopupMenuItem(
                value: 'new',
                child: Row(children: [
                  Icon(Icons.note_add_outlined, size: 18),
                  SizedBox(width: 10),
                  Text('New notebook'),
                ]),
              ),
              PopupMenuItem(
                value: 'import',
                child: Row(children: [
                  Icon(Icons.file_download_outlined, size: 18),
                  SizedBox(width: 10),
                  Text('Import notebook…'),
                ]),
              ),
            ],
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
                        final removing = notebook.id == _removingId;
                        return AnimatedSize(
                          key: ValueKey(notebook.id),
                          duration: _kRemoveAnim,
                          curve: Curves.easeInOut,
                          alignment: Alignment.topCenter,
                          child: AnimatedOpacity(
                            opacity: removing ? 0 : 1,
                            duration: const Duration(milliseconds: 200),
                            child: removing
                                ? const SizedBox(width: double.infinity)
                                : Padding(
                                    padding: const EdgeInsets.only(bottom: 6),
                                    // Long-press anywhere on the card to
                                    // reorder — no visible drag handle.
                                    child: ReorderableDelayedDragStartListener(
                                      index: index,
                            child: Stack(children: [
                              _NotebookRow(
                              notebook: notebook,
                              onTap: () {
                                Navigator.push(
                                  context,
                                  slideRoute(
                                    NotebookScreen(notebook: notebook),
                                  ),
                                ).then((_) => _loadNotebooks());
                              },
                              onRename: () => _renameNotebook(notebook),
                              onColor: () => _colorNotebook(notebook),
                              onExport: () => _exportNotebookPdf(notebook),
                              onShare: () => _shareNotebook(notebook),
                              onShareLink: () => _shareNotebookLink(notebook),
                              onSyncTo: () => _pickSyncTarget(notebook),
                              onConnections: () => showConnectionsSheet(
                                context,
                                title: notebook.name,
                                endpoint:
                                    LinkEndpoint(notebookId: notebook.id),
                                endpointName: notebook.name,
                              ),
                              onDelete: () => _deleteNotebook(notebook),
                              isDefault: SettingsService().defaultNotebookId ==
                                  notebook.id,
                              onSetDefault: () =>
                                  _toggleDefaultNotebook(notebook),
                              ),
                              if (notebook.id == _glowId)
                                Positioned.fill(
                                  child: IgnorePointer(
                                    child: _glowOverlay(context, notebook.id),
                                  ),
                                ),
                            ]),
                          ),
                        ),
                      ),
                    );
                      },
                    ),
            ),
    );
  }

  /// A fading accent wash + border briefly highlighting the card an internal
  /// link led to (same look as the tree rows' reveal glow).
  Widget _glowOverlay(BuildContext context, String id) {
    final palette = Theme.of(context).extension<AppPalette>()!;
    return TweenAnimationBuilder<double>(
      key: ValueKey('glow_$id'),
      tween: Tween(begin: 1, end: 0),
      duration: const Duration(milliseconds: 1600),
      curve: Curves.easeOut,
      builder: (context, t, _) => DecoratedBox(
        decoration: BoxDecoration(
          color: palette.accent.withValues(alpha: 0.28 * t),
          borderRadius: BorderRadius.circular(kRadius),
          border: Border.all(
            color: palette.accent.withValues(alpha: 0.7 * t),
            width: 1.5,
          ),
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
  final VoidCallback onShare;
  final VoidCallback onShareLink;
  final VoidCallback onSyncTo;
  final VoidCallback onConnections;
  final VoidCallback onDelete;
  final bool isDefault;
  final VoidCallback onSetDefault;

  const _NotebookRow({
    required this.notebook,
    required this.onTap,
    required this.onRename,
    required this.onColor,
    required this.onExport,
    required this.onShare,
    required this.onShareLink,
    required this.onSyncTo,
    required this.onConnections,
    required this.onDelete,
    required this.isDefault,
    required this.onSetDefault,
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
          padding: const EdgeInsets.fromLTRB(10, 8, 4, 8),
          child: Row(
            children: [
              // The nav-rail/desktop book glyph in the notebook's identity
              // color (matches the desktop sidebar rows; no expanded state on
              // mobile, so always outlined).
              SizedBox(
                width: 30,
                height: 30,
                child: Icon(Icons.book_outlined, size: 21, color: identity),
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            notebook.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 14.5,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        if (isDefault) ...[
                          const SizedBox(width: 5),
                          Icon(Icons.star_rounded,
                              size: 15, color: palette.accent),
                        ],
                      ],
                    ),
                    const SizedBox(height: 1),
                    Text(
                      '${formatCount(count)} ${count == 1 ? 'section' : 'sections'} · ${formatShortDate(notebook.createdAt)}',
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 11,
                        color: palette.textDim,
                      ),
                    ),
                  ],
                ),
              ),
              // Tasteful, tiny account indicator (avatar initial for a synced
              // account, cloud-off for local-only, nothing when signed out).
              Padding(
                padding: const EdgeInsets.only(left: 6),
                child: NotebookAccountBadge(notebook: notebook),
              ),
              _RowMenu(
                onRename: onRename,
                onColor: onColor,
                onExport: onExport,
                onShare: onShare,
                onShareLink: onShareLink,
                onSyncTo: onSyncTo,
                onConnections: onConnections,
                onDelete: onDelete,
                isDefault: isDefault,
                onSetDefault: onSetDefault,
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
  final VoidCallback onShare;
  final VoidCallback onShareLink;
  final VoidCallback onSyncTo;
  final VoidCallback onConnections;
  final VoidCallback onDelete;
  final bool isDefault;
  final VoidCallback onSetDefault;
  const _RowMenu({
    required this.onRename,
    required this.onColor,
    required this.onExport,
    required this.onShare,
    required this.onShareLink,
    required this.onSyncTo,
    required this.onConnections,
    required this.onDelete,
    required this.isDefault,
    required this.onSetDefault,
  });

  @override
  Widget build(BuildContext context) {
    final palette = Theme.of(context).extension<AppPalette>()!;
    return IconButton(
      icon: Icon(Icons.more_vert, color: palette.textDim, size: 20),
      visualDensity: VisualDensity.compact,
      constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
      padding: EdgeInsets.zero,
      onPressed: () => showActionSheet(context, items: [
        ActionSheetItem(
            icon: Icons.edit_outlined, label: 'Rename', onTap: onRename),
        ActionSheetItem(
            icon: Icons.palette_outlined,
            label: 'Change color',
            onTap: onColor),
        ActionSheetItem(
            icon: Icons.picture_as_pdf_outlined,
            label: 'Export to PDF',
            onTap: onExport),
        ActionSheetItem(
            icon: Icons.ios_share, label: 'Send a copy', onTap: onShare),
        ActionSheetItem(
            icon: Icons.link, label: 'Share link', onTap: onShareLink),
        ActionSheetItem(
            icon: Icons.sync_outlined, label: 'Sync to…', onTap: onSyncTo),
        ActionSheetItem(
            icon: Icons.hub_outlined,
            label: 'Connections',
            onTap: onConnections),
        ActionSheetItem(
            icon: isDefault ? Icons.star_rounded : Icons.star_border_rounded,
            label: isDefault
                ? 'Remove as default target'
                : 'Set as default target',
            onTap: onSetDefault),
        ActionSheetItem(
            icon: Icons.delete_outline,
            label: 'Delete',
            destructive: true,
            onTap: onDelete),
      ]),
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
