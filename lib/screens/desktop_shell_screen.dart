import 'package:flutter/material.dart';
import '../models/canvas.dart';
import '../models/notebook.dart';
import '../models/section.dart';
import '../models/tree.dart';
import '../services/notebook_service.dart';
import '../services/sync_service.dart';
import '../theme/app_theme.dart';
import '../widgets/sync_status_icon.dart';
import '../widgets/color_swatch_picker.dart';
import '../widgets/item_tree_view.dart';
import '../widgets/location_picker.dart';
import 'canvas_screen.dart';
import 'settings_screen.dart';

/// OneNote-desktop-style three-pane view. Sidebar: notebooks (reorderable) →
/// each expands to its **section** tree (drag/reorder/color/group,
/// cross-notebook drag moves sections). Middle: the selected section's
/// **canvas** list in a narrow page-list column. Main pane: the selected
/// canvas embedded directly. The header's book icon collapses the sidebar
/// *and* the canvas column to a narrow rail. Used instead of the mobile push
/// flow on wide windows.
class DesktopShellScreen extends StatefulWidget {
  const DesktopShellScreen({super.key});

  @override
  State<DesktopShellScreen> createState() => _DesktopShellScreenState();
}

class _DesktopShellScreenState extends State<DesktopShellScreen> {
  final _service = NotebookService();

  List<Notebook>? _notebooks;
  final Map<String, Map<String, Section>> _sectionMaps = {};

  final Set<String> _expanded = {};
  Section? _selectedSection;
  Map<String, Canvas> _selectedCanvases = {};
  Canvas? _selectedCanvas;

  double _sidebarWidth = 300;
  double _canvasListWidth = 230;
  bool _sidebarCollapsed = false;

  static const double _minSidebarWidth = 220;
  static const double _maxSidebarWidth = 460;
  static const double _collapsedWidth = 56;
  static const double _minCanvasListWidth = 170;
  static const double _maxCanvasListWidth = 380;

  @override
  void initState() {
    super.initState();
    _loadAll();
    SyncService().dataVersion.addListener(_onSyncData);
  }

  @override
  void dispose() {
    SyncService().dataVersion.removeListener(_onSyncData);
    super.dispose();
  }

  void _onSyncData() {
    if (mounted) _loadAll();
  }

  Future<void> _loadAll() async {
    final notebooks = await _service.getNotebooks();
    for (final nb in notebooks) {
      _sectionMaps[nb.id] = await _service.getSectionMap(nb.id);
    }
    if (!mounted) return;
    setState(() => _notebooks = notebooks);
  }

  Future<void> _reloadNotebook(String notebookId) async {
    final nb = await _service.getNotebook(notebookId);
    final map = await _service.getSectionMap(notebookId);
    if (!mounted || nb == null) return;
    setState(() {
      final list = _notebooks;
      if (list != null) {
        final i = list.indexWhere((n) => n.id == notebookId);
        if (i >= 0) list[i] = nb;
      }
      _sectionMaps[notebookId] = map;
      final sel = _selectedSection;
      if (sel != null && sel.notebookId == notebookId) {
        _selectedSection = map[sel.id];
        if (_selectedSection == null) _selectedCanvas = null;
      }
    });
  }

  Future<void> _selectSection(Section section) async {
    final canvases = await _service.getCanvasMap(section);
    if (!mounted) return;
    setState(() {
      _selectedSection = section;
      _selectedCanvases = canvases;
      _selectedCanvas = null;
    });
  }

  Future<void> _reloadSelectedSection() async {
    final sel = _selectedSection;
    if (sel == null) return;
    final fresh = await _service.getSection(sel.notebookId, sel.id);
    final canvases = fresh == null
        ? <String, Canvas>{}
        : await _service.getCanvasMap(fresh);
    if (!mounted) return;
    setState(() {
      _selectedSection = fresh;
      _selectedCanvases = canvases;
      if (fresh == null) _selectedCanvas = null;
    });
  }

  // ── Notebook actions ────────────────────────────────────────────────

  Future<void> _createNotebook() async {
    final name = await _prompt(title: 'New notebook', hint: 'Notebook name');
    if (name == null || name.isEmpty) return;
    final notebook = await _service.createNotebook(name);
    _sectionMaps[notebook.id] = {};
    if (!mounted) return;
    setState(() {
      (_notebooks ??= []).add(notebook);
      _expanded.add(notebook.id);
      _sidebarCollapsed = false;
    });
  }

  Future<void> _renameNotebook(Notebook notebook) async {
    final name = await _prompt(
      title: 'Rename notebook',
      hint: 'Notebook name',
      initial: notebook.name,
      cta: 'Rename',
    );
    if (name == null || name.isEmpty) return;
    notebook.name = name;
    await _service.saveNotebook(notebook);
    if (mounted) setState(() {});
  }

  Future<void> _colorNotebook(Notebook notebook) async {
    final choice = await showColorSwatchPicker(
      context,
      current: notebook.color,
    );
    if (choice == null) return;
    notebook.color = choice.color;
    await _service.saveNotebook(notebook);
    if (mounted) setState(() {});
  }

  Future<void> _deleteNotebook(Notebook notebook) async {
    final ok = await _confirm(
      'Delete notebook?',
      '"${notebook.name}" and all its sections & canvases will be permanently deleted.',
    );
    if (!ok) return;
    if (_selectedSection?.notebookId == notebook.id) {
      _selectedSection = null;
      _selectedCanvas = null;
    }
    _expanded.remove(notebook.id);
    await _service.deleteNotebook(notebook.id);
    _sectionMaps.remove(notebook.id);
    if (!mounted) return;
    setState(() => _notebooks?.removeWhere((n) => n.id == notebook.id));
  }

  Future<void> _reorderNotebooks(int oldIndex, int newIndex) async {
    final list = _notebooks;
    if (list == null) return;
    if (newIndex > oldIndex) newIndex--;
    setState(() => list.insert(newIndex, list.removeAt(oldIndex)));
    await _service.reorderNotebooks([for (final n in list) n.id]);
  }

  // ── Section actions (sidebar) ───────────────────────────────────────

  Future<void> _addSection(Notebook notebook, {String? folderId}) async {
    final name = await _prompt(title: 'New section', hint: 'Section name');
    if (name == null || name.isEmpty) return;
    final section = await _service.createSection(
      notebook.id,
      name,
      parentFolderId: folderId,
    );
    await _reloadNotebook(notebook.id);
    await _selectSection(section);
  }

  Future<void> _addSectionFolder(Notebook notebook, {String? folderId}) async {
    final name = await _prompt(title: 'New super-section', hint: 'Group name');
    if (name == null || name.isEmpty) return;
    await _service.createSectionFolder(
      notebook,
      name,
      parentFolderId: folderId,
    );
    await _reloadNotebook(notebook.id);
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
    await _reloadNotebook(section.notebookId);
  }

  Future<void> _colorSection(Section section) async {
    final choice = await showColorSwatchPicker(context, current: section.color);
    if (choice == null) return;
    await _service.setSectionColor(section, choice.color);
    await _reloadNotebook(section.notebookId);
  }

  Future<void> _deleteSection(Section section) async {
    if (_selectedSection?.id == section.id) {
      _selectedSection = null;
      _selectedCanvas = null;
    }
    await _service.deleteSection(section.notebookId, section.id);
    await _reloadNotebook(section.notebookId);
  }

  Future<void> _renameSectionFolder(Notebook nb, FolderNode folder) async {
    final name = await _prompt(
      title: 'Rename super-section',
      hint: 'Group name',
      initial: folder.name,
      cta: 'Rename',
    );
    if (name == null || name.isEmpty) return;
    folder.name = name;
    await _service.saveNotebook(nb);
    if (mounted) setState(() {});
  }

  Future<void> _colorSectionFolder(Notebook nb, FolderNode folder) async {
    final choice = await showColorSwatchPicker(context, current: folder.color);
    if (choice == null) return;
    folder.color = choice.color;
    await _service.saveNotebook(nb);
    if (mounted) setState(() {});
  }

  Future<void> _deleteSectionFolder(Notebook nb, FolderNode folder) async {
    final count = folder.collectLeafIds().length;
    final ok = await _confirm(
      'Delete super-section?',
      count == 0
          ? '"${folder.name}" will be deleted.'
          : '"${folder.name}" and its $count section(s) will be permanently deleted.',
    );
    if (!ok) return;
    if (_selectedSection != null &&
        folder.collectLeafIds().contains(_selectedSection!.id)) {
      _selectedSection = null;
      _selectedCanvas = null;
    }
    await _service.deleteSectionFolder(nb, folder.id);
    await _reloadNotebook(nb.id);
  }

  Future<void> _relocateSection(
    Notebook nb,
    TreeNode node, {
    required bool copy,
  }) async {
    final dst = await pickNotebookDestination(
      context,
      title: copy ? 'Copy to notebook' : 'Move to notebook',
    );
    if (dst == null) return;
    if (copy) {
      await _service.copySectionNode(nb.id, node, dst);
    } else {
      await _service.moveSectionNode(nb.id, node, dst);
    }
    await _reloadNotebook(nb.id);
    if (dst != nb.id) await _reloadNotebook(dst);
  }

  Future<void> _crossDropSection(
    Notebook dstNb,
    TreeNode dragged,
    String srcNbId,
    FolderNode? targetFolder,
  ) async {
    await _service.moveSectionNode(
      srcNbId,
      dragged,
      dstNb.id,
      dstFolderId: targetFolder?.id,
    );
    await _reloadNotebook(srcNbId);
    if (srcNbId != dstNb.id) await _reloadNotebook(dstNb.id);
  }

  // ── Canvas actions (main pane, for _selectedSection) ────────────────

  Future<void> _addCanvas({String? folderId}) async {
    final section = _selectedSection;
    if (section == null) return;
    final name = await _prompt(title: 'New canvas', hint: 'Canvas name');
    if (name == null || name.isEmpty) return;
    final canvas = await _service.createCanvas(
      section,
      name,
      parentFolderId: folderId,
    );
    await _reloadSelectedSection();
    if (mounted) setState(() => _selectedCanvas = canvas);
  }

  Future<void> _addCanvasFolder({String? folderId}) async {
    final section = _selectedSection;
    if (section == null) return;
    final name = await _prompt(title: 'New super-section', hint: 'Group name');
    if (name == null || name.isEmpty) return;
    await _service.createCanvasFolder(section, name, parentFolderId: folderId);
    await _reloadSelectedSection();
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
    if (_selectedCanvas?.id == canvas.id) _selectedCanvas = canvas;
    await _reloadSelectedSection();
  }

  Future<void> _colorCanvas(Canvas canvas) async {
    final choice = await showColorSwatchPicker(context, current: canvas.color);
    if (choice == null) return;
    await _service.setCanvasColor(canvas, choice.color);
    await _reloadSelectedSection();
  }

  Future<void> _deleteCanvas(Canvas canvas) async {
    final section = _selectedSection;
    if (section == null) return;
    if (_selectedCanvas?.id == canvas.id) _selectedCanvas = null;
    await _service.deleteCanvas(section, canvas.id);
    await _reloadSelectedSection();
  }

  Future<void> _renameCanvasFolder(FolderNode folder) async {
    final section = _selectedSection;
    if (section == null) return;
    final name = await _prompt(
      title: 'Rename super-section',
      hint: 'Group name',
      initial: folder.name,
      cta: 'Rename',
    );
    if (name == null || name.isEmpty) return;
    folder.name = name;
    await _service.saveSection(section);
    if (mounted) setState(() {});
  }

  Future<void> _colorCanvasFolder(FolderNode folder) async {
    final section = _selectedSection;
    if (section == null) return;
    final choice = await showColorSwatchPicker(context, current: folder.color);
    if (choice == null) return;
    folder.color = choice.color;
    await _service.saveSection(section);
    if (mounted) setState(() {});
  }

  Future<void> _deleteCanvasFolder(FolderNode folder) async {
    final section = _selectedSection;
    if (section == null) return;
    final count = folder.collectLeafIds().length;
    final ok = await _confirm(
      'Delete super-section?',
      count == 0
          ? '"${folder.name}" will be deleted.'
          : '"${folder.name}" and its $count canvas(es) will be permanently deleted.',
    );
    if (!ok) return;
    await _service.deleteCanvasFolder(section, folder.id);
    await _reloadSelectedSection();
  }

  Future<void> _relocateCanvas(TreeNode node, {required bool copy}) async {
    final section = _selectedSection;
    if (section == null) return;
    final dst = await pickSectionDestination(
      context,
      title: copy ? 'Copy to section' : 'Move to section',
    );
    if (dst == null) return;
    if (copy) {
      await _service.copyCanvasNode(
        section.notebookId,
        section.id,
        node,
        dst.notebookId,
        dst.sectionId,
      );
    } else {
      await _service.moveCanvasNode(
        section.notebookId,
        section.id,
        node,
        dst.notebookId,
        dst.sectionId,
      );
    }
    await _reloadSelectedSection();
    await _reloadNotebook(dst.notebookId);
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

  // ── Build ───────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = theme.extension<AppPalette>()!;
    return Scaffold(
      body: LayoutBuilder(
        builder: (context, constraints) {
          final desired = _sidebarCollapsed ? _collapsedWidth : _sidebarWidth;
          final width = constraints.maxWidth.isFinite
              ? desired.clamp(0.0, constraints.maxWidth)
              : desired;
          // Space left for the canvas-list column (guards the transient
          // zero-width startup frame, same as the sidebar clamp).
          final remaining = constraints.maxWidth.isFinite
              ? (constraints.maxWidth - width).clamp(0.0, double.infinity)
              : double.infinity;
          final canvasColumnOpen =
              !_sidebarCollapsed && _selectedSection != null;
          return Row(
            children: [
              _buildSidebar(theme, palette, width),
              if (!_sidebarCollapsed)
                _resizeDivider(
                  palette,
                  (dx) => setState(() {
                    _sidebarWidth = (_sidebarWidth + dx).clamp(
                      _minSidebarWidth,
                      _maxSidebarWidth,
                    );
                  }),
                ),
              _buildCanvasColumn(theme, palette, remaining),
              if (canvasColumnOpen)
                _resizeDivider(
                  palette,
                  (dx) => setState(() {
                    _canvasListWidth = (_canvasListWidth + dx).clamp(
                      _minCanvasListWidth,
                      _maxCanvasListWidth,
                    );
                  }),
                ),
              Expanded(child: _buildMainPane(theme, palette)),
            ],
          );
        },
      ),
    );
  }

  Widget _buildMainPane(ThemeData theme, AppPalette palette) {
    final canvas = _selectedCanvas;
    if (canvas != null) {
      // The canvas list stays visible in its own column (OneNote-style), so
      // the canvas embeds directly — no breadcrumb / back bar needed.
      return CanvasScreen(
        key: ValueKey(canvas.id),
        canvas: canvas,
        onCanvasRenamed: _reloadSelectedSection,
      );
    }
    if (_selectedSection != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.crop_portrait, size: 56, color: palette.textDim),
            const SizedBox(height: 16),
            Text(
              'Select a canvas',
              style: TextStyle(fontSize: 15, color: palette.textDim),
            ),
            const SizedBox(height: 6),
            Text(
              'Pick one from the list, or create a new canvas.',
              style: TextStyle(fontSize: 12.5, color: palette.textDim),
            ),
          ],
        ),
      );
    }
    return _EmptyMainPane(onNewNotebook: _createNotebook);
  }

  /// A 6px draggable column divider (mouse resize-cursor + 1px hairline).
  /// Shared by the sidebar and the canvas-list column.
  Widget _resizeDivider(AppPalette palette, void Function(double dx) onDrag) {
    return MouseRegion(
      cursor: SystemMouseCursors.resizeColumn,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onHorizontalDragUpdate: (d) => onDrag(d.delta.dx),
        child: SizedBox(
          width: 6,
          child: Center(child: Container(width: 1, color: palette.border)),
        ),
      ),
    );
  }

  /// OneNote-style page-list column between the sidebar and the canvas:
  /// the selected section's canvases. Slides closed together with the
  /// sidebar (`_sidebarCollapsed`) and when no section is selected.
  Widget _buildCanvasColumn(
    ThemeData theme,
    AppPalette palette,
    double maxWidth,
  ) {
    final section = _selectedSection;
    final open = !_sidebarCollapsed && section != null;
    final target = open ? _canvasListWidth : 0.0;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      width: target.clamp(0.0, maxWidth),
      // No right border — the resize divider beside it is the separator when
      // open; when closed the column is 0-width so nothing shows.
      color: palette.surface2,
      child: ClipRect(
        child: OverflowBox(
          alignment: Alignment.topLeft,
          minWidth: _canvasListWidth,
          maxWidth: _canvasListWidth,
          child: SizedBox(
            width: _canvasListWidth,
            child: section == null
                ? const SizedBox.shrink()
                : _buildCanvasListContent(theme, palette, section),
          ),
        ),
      ),
    );
  }

  Widget _buildCanvasListContent(
    ThemeData theme,
    AppPalette palette,
    Section section,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: palette.border)),
          ),
          padding: const EdgeInsets.fromLTRB(14, 10, 4, 10),
          child: Row(
            children: [
              Icon(
                Icons.description_outlined,
                size: 15,
                color: AppPalette.resolveColor(section.id, section.color),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  section.name,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              PopupMenuButton<String>(
                icon: const Icon(Icons.add, size: 18),
                tooltip: 'Add',
                padding: EdgeInsets.zero,
                onSelected: (a) {
                  if (a == 'canvas') _addCanvas();
                  if (a == 'group') _addCanvasFolder();
                },
                itemBuilder: (context) => const [
                  PopupMenuItem(value: 'canvas', child: Text('New canvas')),
                  PopupMenuItem(
                    value: 'group',
                    child: Text('New super-section'),
                  ),
                ],
              ),
            ],
          ),
        ),
        Expanded(
          child: section.nodes.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.edit_note_outlined,
                        size: 40,
                        color: palette.textDim,
                      ),
                      const SizedBox(height: 10),
                      Text(
                        'No canvases yet',
                        style: TextStyle(color: palette.textDim, fontSize: 13),
                      ),
                      const SizedBox(height: 12),
                      FilledButton.icon(
                        onPressed: _addCanvas,
                        icon: const Icon(Icons.add, size: 16),
                        label: const Text('New canvas'),
                      ),
                    ],
                  ),
                )
              : SingleChildScrollView(
                  child: ItemTreeView<Canvas>(
                    containerId: section.id,
                    nodes: section.nodes,
                    items: _selectedCanvases,
                    dense: true,
                    nameOf: (c) => c.name,
                    colorOf: (c) => c.color,
                    idOf: (c) => c.id,
                    // No leaf icon — the colored identity pill is enough.
                    selectedId: _selectedCanvas?.id,
                    onOpen: (c) => setState(() => _selectedCanvas = c),
                    onRenameLeaf: _renameCanvas,
                    onColorLeaf: _colorCanvas,
                    onDeleteLeaf: _deleteCanvas,
                    onRenameFolder: _renameCanvasFolder,
                    onColorFolder: _colorCanvasFolder,
                    onAddLeafToFolder: (f) => _addCanvas(folderId: f.id),
                    onAddFolderToFolder: (f) =>
                        _addCanvasFolder(folderId: f.id),
                    onUngroup: (f) async {
                      await _service.ungroupInSection(section, f.id);
                      await _reloadSelectedSection();
                    },
                    onDeleteFolder: _deleteCanvasFolder,
                    onRelocate: _relocateCanvas,
                    onTreeChanged: () => _service.saveSection(section),
                  ),
                ),
        ),
      ],
    );
  }

  Widget _buildSidebar(ThemeData theme, AppPalette palette, double width) {
    final targetWidth = _sidebarCollapsed ? _collapsedWidth : _sidebarWidth;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      width: width,
      color: theme.colorScheme.surface,
      child: ClipRect(
        child: OverflowBox(
          alignment: Alignment.topLeft,
          minWidth: targetWidth,
          maxWidth: targetWidth,
          child: SizedBox(
            width: targetWidth,
            child: Column(
              children: [
                const SizedBox(height: 20),
                _buildHeader(context, palette),
                Divider(height: 1, color: palette.border),
                Expanded(
                  child: _sidebarCollapsed
                      ? _buildCollapsedRail(palette)
                      : _buildTree(palette),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSidebarToggle(AppPalette palette) {
    return Tooltip(
      message: _sidebarCollapsed ? 'Expand panels' : 'Collapse panels',
      child: InkWell(
        borderRadius: BorderRadius.circular(kRadius),
        onTap: () => setState(() => _sidebarCollapsed = !_sidebarCollapsed),
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Icon(
            Icons.auto_stories_outlined,
            color: palette.accent,
            size: 20,
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context, AppPalette palette) {
    if (_sidebarCollapsed) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Center(child: _buildSidebarToggle(palette)),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 14, 8, 14),
      child: Row(
        children: [
          _buildSidebarToggle(palette),
          const SizedBox(width: 6),
          const Expanded(
            child: Text(
              'Omininote',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          IconButton(
            icon: const Icon(Icons.add, size: 20),
            tooltip: 'New notebook',
            onPressed: _createNotebook,
          ),
          const SyncStatusIcon(),
          IconButton(
            icon: const Icon(Icons.settings_outlined, size: 20),
            tooltip: 'Settings',
            onPressed: () => Navigator.push(
              context,
              fadeThroughRoute(const SettingsScreen()),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCollapsedRail(AppPalette palette) {
    final notebooks = _notebooks ?? const <Notebook>[];
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: [
        for (final notebook in notebooks)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 10),
            child: Tooltip(
              message: notebook.name,
              child: InkWell(
                borderRadius: BorderRadius.circular(18),
                onTap: () => setState(() {
                  _sidebarCollapsed = false;
                  _expanded.add(notebook.id);
                }),
                child: Container(
                  width: 36,
                  height: 36,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: AppPalette.resolveColor(notebook.id, notebook.color),
                    shape: BoxShape.circle,
                  ),
                  child: Text(
                    notebook.name.isNotEmpty
                        ? notebook.name[0].toUpperCase()
                        : '?',
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                      fontSize: 14,
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildTree(AppPalette palette) {
    final notebooks = _notebooks;
    if (notebooks == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (notebooks.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.auto_stories_outlined,
                size: 40,
                color: palette.textDim,
              ),
              const SizedBox(height: 12),
              Text(
                'No notebooks yet',
                style: TextStyle(color: palette.textDim, fontSize: 13),
              ),
              const SizedBox(height: 14),
              FilledButton.icon(
                onPressed: _createNotebook,
                icon: const Icon(Icons.add, size: 16),
                label: const Text('New notebook'),
              ),
            ],
          ),
        ),
      );
    }

    return ReorderableListView(
      buildDefaultDragHandles: false,
      padding: const EdgeInsets.only(bottom: 16),
      onReorder: _reorderNotebooks,
      children: [
        for (var i = 0; i < notebooks.length; i++)
          _buildNotebookSection(palette, notebooks[i], i),
      ],
    );
  }

  Widget _buildNotebookSection(
    AppPalette palette,
    Notebook notebook,
    int index,
  ) {
    final expanded = _expanded.contains(notebook.id);
    final color = AppPalette.resolveColor(notebook.id, notebook.color);
    final sectionMap = _sectionMaps[notebook.id] ?? const {};

    return Column(
      key: ValueKey('nb_${notebook.id}'),
      mainAxisSize: MainAxisSize.min,
      children: [
        // Notebooks are the top level: neutral row, the solid initial chip
        // carries the color; long-press anywhere to reorder (no handle).
        Padding(
          padding: const EdgeInsets.fromLTRB(6, 2, 6, 2),
          child: ReorderableDelayedDragStartListener(
            index: index,
            child: Material(
              color: expanded ? palette.surface2 : Colors.transparent,
              borderRadius: BorderRadius.circular(kRadius),
              child: InkWell(
                borderRadius: BorderRadius.circular(kRadius),
                onTap: () => setState(() {
                  expanded
                      ? _expanded.remove(notebook.id)
                      : _expanded.add(notebook.id);
                }),
                child: SizedBox(
                  height: 44,
                  child: Row(
                    children: [
                      const SizedBox(width: 6),
                      AnimatedRotation(
                        turns: expanded ? 0.25 : 0,
                        duration: const Duration(milliseconds: 150),
                        child: Icon(
                          Icons.chevron_right,
                          size: 18,
                          color: palette.textDim,
                        ),
                      ),
                      const SizedBox(width: 4),
                      Container(
                        width: 20,
                        height: 20,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: color,
                          borderRadius: BorderRadius.circular(5),
                        ),
                        child: Text(
                          notebook.name.isNotEmpty
                              ? notebook.name[0].toUpperCase()
                              : '?',
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w700,
                            fontSize: 11,
                          ),
                        ),
                      ),
                      const SizedBox(width: 9),
                      Expanded(
                        child: Text(
                          notebook.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 13.5,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      PopupMenuButton<String>(
                        icon: Icon(Icons.add, size: 18, color: palette.textDim),
                        tooltip: 'Add',
                        padding: EdgeInsets.zero,
                        onSelected: (a) {
                          if (a == 'section') _addSection(notebook);
                          if (a == 'group') _addSectionFolder(notebook);
                        },
                        itemBuilder: (context) => const [
                          PopupMenuItem(
                            value: 'section',
                            child: Text('New section'),
                          ),
                          PopupMenuItem(
                            value: 'group',
                            child: Text('New super-section'),
                          ),
                        ],
                      ),
                      PopupMenuButton<String>(
                        icon: Icon(
                          Icons.more_vert,
                          size: 18,
                          color: palette.textDim,
                        ),
                        padding: EdgeInsets.zero,
                        onSelected: (a) {
                          switch (a) {
                            case 'rename':
                              _renameNotebook(notebook);
                            case 'color':
                              _colorNotebook(notebook);
                            case 'delete':
                              _deleteNotebook(notebook);
                          }
                        },
                        itemBuilder: (context) => [
                          const PopupMenuItem(
                            value: 'rename',
                            child: Text('Rename'),
                          ),
                          const PopupMenuItem(
                            value: 'color',
                            child: Text('Change color'),
                          ),
                          PopupMenuItem(
                            value: 'delete',
                            child: Text(
                              'Delete',
                              style: TextStyle(
                                color: Theme.of(context).colorScheme.error,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(width: 2),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
        if (expanded)
          // Sections hang off their notebook: indented under a rail in the
          // notebook's color so the parent/child relationship is visible.
          Padding(
            padding: const EdgeInsets.only(left: 15, right: 4, bottom: 4),
            child: Container(
              decoration: BoxDecoration(
                border: Border(
                  left: BorderSide(
                    color: color.withValues(alpha: 0.45),
                    width: 2,
                  ),
                ),
              ),
              child: ItemTreeView<Section>(
                containerId: notebook.id,
                nodes: notebook.nodes,
                items: sectionMap,
                dense: true,
                nameOf: (s) => s.name,
                colorOf: (s) => s.color,
                idOf: (s) => s.id,
                leafIcon: Icons.description_outlined,
                selectedId: _selectedSection?.id,
                onOpen: _selectSection,
                onRenameLeaf: _renameSection,
                onColorLeaf: _colorSection,
                onDeleteLeaf: _deleteSection,
                onRenameFolder: (f) => _renameSectionFolder(notebook, f),
                onColorFolder: (f) => _colorSectionFolder(notebook, f),
                onAddLeafToFolder: (f) => _addSection(notebook, folderId: f.id),
                onAddFolderToFolder: (f) =>
                    _addSectionFolder(notebook, folderId: f.id),
                onUngroup: (f) async {
                  await _service.ungroupInNotebook(notebook, f.id);
                  await _reloadNotebook(notebook.id);
                },
                onDeleteFolder: (f) => _deleteSectionFolder(notebook, f),
                onRelocate: (node, {required copy}) =>
                    _relocateSection(notebook, node, copy: copy),
                onTreeChanged: () => _service.saveNotebook(notebook),
                onCrossDrop: (dragged, srcId, folder, index) =>
                    _crossDropSection(notebook, dragged, srcId, folder),
              ),
            ),
          ),
      ],
    );
  }
}

class _EmptyMainPane extends StatelessWidget {
  final VoidCallback onNewNotebook;
  const _EmptyMainPane({required this.onNewNotebook});

  @override
  Widget build(BuildContext context) {
    final palette = Theme.of(context).extension<AppPalette>()!;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.description_outlined, size: 64, color: palette.textDim),
          const SizedBox(height: 18),
          Text(
            'Select a section to see its canvases',
            style: TextStyle(fontSize: 15, color: palette.textDim),
          ),
          const SizedBox(height: 6),
          Text(
            'Choose a notebook on the left, or create one.',
            style: TextStyle(fontSize: 12.5, color: palette.textDim),
          ),
        ],
      ),
    );
  }
}
