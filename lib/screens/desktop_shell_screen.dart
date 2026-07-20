import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/canvas.dart';
import '../models/link.dart';
import '../models/notebook.dart';
import '../models/section.dart';
import '../models/tree.dart';
import '../services/link_navigator.dart';
import '../services/notebook_service.dart';
import '../services/search_service.dart';
import '../services/settings_service.dart';
import '../services/sync_service.dart';
import '../theme/app_theme.dart';
import '../widgets/sync_status_icon.dart';
import '../widgets/color_swatch_picker.dart';
import '../widgets/connections_sheet.dart';
import '../widgets/item_tree_view.dart';
import '../widgets/location_picker.dart';
import '../widgets/notebook_account_badge.dart';
import '../widgets/scroll_into_view.dart';
import '../utils/pdf_export_ui.dart';
import '../utils/sync_target_ui.dart';
import '../utils/notebook_share_ui.dart';
import '../utils/new_canvas_ui.dart';
import 'canvas_workspace_screen.dart';
import 'note_search.dart';
import '../widgets/action_sheet.dart';
import 'bin_screen.dart';
import 'settings_screen.dart';

/// What the desktop shell's main (rightmost) pane is showing.
enum _MainMode { canvas, search, bin, settings }

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
  // Notebooks whose section tree has been built at least once this session.
  // A collapsed-but-opened notebook keeps its tree so re-expand/collapse still
  // animate with content, but a notebook the user never opened doesn't build
  // its whole section subtree at all — so a sidebar rebuild (which happens on
  // every setState, e.g. selecting a canvas) scales with *opened* notebooks,
  // not total sections across every notebook. (Perf 07/14/26.)
  final Set<String> _everExpanded = {};
  Section? _selectedSection;
  Map<String, Canvas> _selectedCanvases = {};
  Canvas? _selectedCanvas;

  // Per-section canvas-map cache, keyed by section id, so re-selecting a
  // visited section is instant (no disk re-read). Cleared whenever data
  // changes (dataVersion) and refreshed after local canvas edits, so it can't
  // serve a stale list across a sync or a local mutation. (Perf 07/14/26.)
  final Map<String, Map<String, Canvas>> _canvasCache = {};

  // What the main (rightmost) pane shows. Search + Bin open here — keeping the
  // sidebar + canvas list visible — instead of covering everything.
  _MainMode _mainMode = _MainMode.canvas;
  final ValueNotifier<int> _binRefresh = ValueNotifier(0);

  // Notebook animating out on delete (collapse + fade).
  String? _removingNotebookId;

  // Search-reveal state: page to jump to when opening a bookmarked canvas, and
  // the id of the item to briefly glow (so you can see where search took you).
  String? _pendingJumpPageId;
  String? _glowId;
  Timer? _glowTimer;

  double _sidebarWidth = 300;
  double _canvasListWidth = 230;
  // The user's explicit collapse choice for the notebook sidebar. Kept
  // SEPARATE from full-screen and from the Search/Bin/Settings full-pane modes
  // (which merely hide the panes) so that leaving those never silently
  // re-expands a sidebar the user collapsed on purpose — it only expands when
  // the user presses the Notebooks rail button while already in canvas mode.
  bool _sidebarCollapsed = false;
  // Desktop canvas full-screen. Hides the side panes while active WITHOUT
  // touching _sidebarCollapsed, so exiting full screen restores whatever the
  // user had.
  bool _fullScreen = false;
  // Pin the canvas-list column so it stays visible even when the notebook
  // sidebar is collapsed (toggled from the list header).
  bool _canvasListPinned = false;

  static const double _minSidebarWidth = 220;
  static const double _maxSidebarWidth = 460;
  // Collapsed = fully hidden (0 width). The left icon nav rail already serves
  // the "narrow rail" purpose, so there's no leftover notebook-initials column.
  static const double _collapsedWidth = 0;
  static const double _minCanvasListWidth = 170;
  static const double _maxCanvasListWidth = 380;

  @override
  void initState() {
    super.initState();
    _loadAll();
    SyncService().dataVersion.addListener(_onSyncData);
    // Internal links ("Connections") navigate through the same reveal path as
    // search results, whichever shell is active.
    LinkNavigator().register(_revealFromLink);
  }

  @override
  void dispose() {
    LinkNavigator().unregister(_revealFromLink);
    SyncService().dataVersion.removeListener(_onSyncData);
    _glowTimer?.cancel();
    _binRefresh.dispose();
    super.dispose();
  }

  /// A tapped internal link (Connections) reveals like a search result, first
  /// making sure the panes are showing (mirrors the search overlay's onReveal).
  void _revealFromLink(SearchResult r) {
    setState(() {
      _mainMode = _MainMode.canvas;
      _sidebarCollapsed = false;
    });
    _revealSearchResult(r);
  }

  // ── Search reveal ───────────────────────────────────────────────────────

  /// Opens a search result *in place*: expands the notebook + any collapsed
  /// super-sections on the path, selects the section and canvas in the panes
  /// (jumping to a bookmarked page), and briefly glows the target — so it looks
  /// exactly like navigating there by hand, not a separate view.
  Future<void> _revealSearchResult(SearchResult r) async {
    final nb = _notebooks?.where((n) => n.id == r.notebook.id).firstOrNull;
    if (nb == null) return;
    setState(() {
      _expanded.add(nb.id);
      _everExpanded.add(nb.id);
    });

    // A notebook hit: expand it and glow the notebook row.
    if (r.kind == SearchKind.notebook) {
      _flashGlow(nb.id);
      return;
    }

    // A notebook-level super-section (groups sections in the sidebar tree):
    // reveal + glow the folder in place.
    if (r.kind == SearchKind.superSection && r.section == null) {
      final fid = r.folderId;
      if (fid != null) _expandToFolder(nb.nodes, fid);
      _flashGlow(fid ?? nb.id);
      return;
    }

    final sectionId = r.section?.id;
    if (sectionId == null) {
      _flashGlow(nb.id);
      return;
    }

    // Expand super-sections leading to the section in the notebook tree.
    _expandFoldersTo(nb.nodes, sectionId);

    final section =
        _sectionMaps[nb.id]?[sectionId] ??
        await _service.getSection(nb.id, sectionId);
    if (section == null || !mounted) return;
    await _selectSection(section);

    // A section-level super-section (groups canvases in the canvas column):
    // open its section, reveal + glow the folder there.
    if (r.kind == SearchKind.superSection) {
      final fid = r.folderId;
      if (fid != null) _expandToFolder(section.nodes, fid);
      _flashGlow(fid ?? sectionId);
      return;
    }

    final canvasId = r.canvas?.id;
    if (canvasId == null) {
      _flashGlow(sectionId);
      return;
    }

    // Expand super-sections leading to the canvas in the section tree.
    _expandFoldersTo(section.nodes, canvasId);
    final canvas = _selectedCanvases[canvasId];
    if (canvas == null) return;
    setState(() {
      _selectedCanvas = canvas;
      _pendingJumpPageId = r.pageId; // non-null for a bookmark
    });
    _flashGlow(canvasId);
  }

  /// Un-collapses every super-section on the path to [targetLeafId]. Returns
  /// true if the leaf was found in [nodes].
  bool _expandFoldersTo(List<TreeNode> nodes, String targetLeafId) {
    for (final n in nodes) {
      if (n is LeafNode && n.refId == targetLeafId) return true;
      if (n is FolderNode && _expandFoldersTo(n.children, targetLeafId)) {
        n.collapsed = false;
        return true;
      }
    }
    return false;
  }

  /// Un-collapses the folder [folderId] (revealing its contents) and every
  /// ancestor folder on the path to it. Returns true if found.
  bool _expandToFolder(List<TreeNode> nodes, String folderId) {
    for (final n in nodes) {
      if (n is FolderNode) {
        if (n.id == folderId) {
          n.collapsed = false;
          return true;
        }
        if (_expandToFolder(n.children, folderId)) {
          n.collapsed = false;
          return true;
        }
      }
    }
    return false;
  }

  void _flashGlow(String id) {
    _glowTimer?.cancel();
    setState(() => _glowId = id);
    _glowTimer = Timer(const Duration(milliseconds: 1800), () {
      if (mounted) setState(() => _glowId = null);
    });
  }

  /// A fading accent wash + border to briefly highlight a notebook row reached
  /// via search (the tree rows use their own equivalent inside ItemTreeView).
  Widget _glowBox(AppPalette palette, String id) {
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

  void _onSyncData() {
    if (mounted) {
      // Data changed (sync pull, delete, rename, …) — cached canvas maps may
      // now be stale, so drop them; the next section select re-reads.
      _canvasCache.clear();
      _loadAll();
    }
  }

  Future<void> _loadAll() async {
    final notebooks = await _service.getNotebooks();
    for (final nb in notebooks) {
      // Pass the already-loaded notebook so getSectionMap doesn't re-decode
      // the whole notebooks.json for every notebook in the loop.
      _sectionMaps[nb.id] = await _service.getSectionMap(nb.id, notebook: nb);
    }
    if (!mounted) return;
    // If the open canvas's notebook was moved/deleted elsewhere (its entry is
    // now gone/tombstoned), clear the selection so the stale canvas closes.
    final openNbId = _selectedCanvas?.notebookId;
    final notebookGone =
        openNbId != null && !notebooks.any((n) => n.id == openNbId);
    setState(() {
      _notebooks = notebooks;
      if (notebookGone) {
        _selectedCanvas = null;
        _selectedSection = null;
      }
    });
  }

  Future<void> _reloadNotebook(String notebookId) async {
    final nb = await _service.getNotebook(notebookId);
    if (nb == null) return;
    final map = await _service.getSectionMap(notebookId, notebook: nb);
    if (!mounted) return;
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
    // Cache hit → switch instantly, no disk read. The cache is dropped on any
    // data change (dataVersion) and refreshed on local edits, so it's fresh.
    final cached = _canvasCache[section.id];
    if (cached != null) {
      setState(() {
        _selectedSection = section;
        _selectedCanvases = cached;
        _selectedCanvas = null;
      });
      return;
    }
    final canvases = await _service.getCanvasMap(section);
    if (!mounted) return;
    _canvasCache[section.id] = canvases;
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
    // Just re-read from disk — refresh the cache so a later re-select stays
    // both fast and correct.
    if (fresh != null) _canvasCache[fresh.id] = canvases;
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
    if (!mounted) return;
    final target = await chooseNewNotebookAccount(context);
    if (target == null) return; // cancelled the account picker
    final notebook = await _service.createNotebook(
      name,
      syncTarget: target.accountId,
    );
    if (target.localOnly) {
      await _service.setNotebookLocalOnly(notebook.id, true);
    }
    _sectionMaps[notebook.id] = {};
    if (!mounted) return;
    setState(() {
      (_notebooks ??= []).add(notebook);
      _expanded.add(notebook.id);
      _everExpanded.add(notebook.id);
      _sidebarCollapsed = false;
    });
  }

  Future<void> _importNotebook() async {
    final nb = await importNotebookCopy(context);
    if (nb == null || !mounted) return;
    await _loadAll();
    if (mounted) {
      setState(() {
        _expanded.add(nb.id);
        _everExpanded.add(nb.id);
      });
    }
  }

  Future<void> _exportNotebookPdf(Notebook notebook) async {
    final items = await _service.collectNotebookExportItems(notebook);
    if (!mounted) return;
    await runTreeExport(context, items: items, fileName: notebook.name);
  }

  Future<void> _pickSyncTarget(Notebook notebook) async {
    final changed = await showSyncTargetPicker(context, notebook);
    if (changed && mounted) setState(() {});
  }

  Future<void> _exportSectionPdf(Section section) async {
    final items = await _service.collectSectionExportItems(section);
    if (!mounted) return;
    await runTreeExport(context, items: items, fileName: section.name);
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

  /// Toggle this device's default landing notebook (device-local; where quick
  /// PDF imports / opened PDFs go). Tapping the current default clears it.
  Future<void> _toggleDefaultNotebook(Notebook notebook) async {
    final settings = SettingsService();
    final makeDefault = settings.defaultNotebookId != notebook.id;
    await settings.setDefaultNotebook(makeDefault ? notebook.id : null);
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
    setState(() => _removingNotebookId = notebook.id); // collapse + fade out
    await Future.delayed(const Duration(milliseconds: 260));
    await _service.deleteNotebook(notebook.id);
    _sectionMaps.remove(notebook.id);
    if (!mounted) return;
    setState(() {
      _notebooks?.removeWhere((n) => n.id == notebook.id);
      _removingNotebookId = null;
    });
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

  // No confirm — recoverable from the recycle bin like any other delete.
  Future<void> _deleteSectionFolder(Notebook nb, FolderNode folder) async {
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
    final kind = await pickNewCanvasKind(context);
    if (kind == null || !mounted) return;
    final Canvas canvas;
    if (kind == NewCanvasKind.pdf) {
      final c = await pickAndCreatePdfCanvas(
        context,
        section,
        parentFolderId: folderId,
      );
      if (c == null) return;
      canvas = c;
    } else {
      final name = await _prompt(title: 'New canvas', hint: 'Canvas name');
      if (name == null || name.isEmpty) return;
      canvas = await _service.createCanvas(
        section,
        name,
        parentFolderId: folderId,
      );
    }
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

  // No confirm — recoverable from the recycle bin like any other delete.
  Future<void> _deleteCanvasFolder(FolderNode folder) async {
    final section = _selectedSection;
    if (section == null) return;
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
    // The destination section (which may not be the selected one) gained a
    // canvas — drop its cached map so a later select re-reads it.
    _canvasCache.remove(dst.sectionId);
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
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyK, control: true): () =>
            _openMainMode(_MainMode.search),
        const SingleActivator(LogicalKeyboardKey.keyK, meta: true): () =>
            _openMainMode(_MainMode.search),
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          body: LayoutBuilder(
            builder: (context, constraints) {
              // The left icon nav rail is a fixed strip; the pane width math works
              // off the space that remains beside it.
              const railWidth = 60.0;
              final avail = constraints.maxWidth.isFinite
                  ? (constraints.maxWidth - railWidth).clamp(
                      0.0,
                      double.infinity,
                    )
                  : constraints.maxWidth;
              // Whether the left area is shown at all (a full-pane mode or
              // full screen hides it), and then whether the notebook sidebar
              // itself is expanded within that.
              final panesVisible = _mainMode == _MainMode.canvas && !_fullScreen;
              final sidebarShown = panesVisible && !_sidebarCollapsed;
              final desired = sidebarShown ? _sidebarWidth : _collapsedWidth;
              final width = avail.isFinite
                  ? desired.clamp(0.0, avail)
                  : desired;
              // Space left for the canvas-list column (guards the transient
              // zero-width startup frame, same as the sidebar clamp).
              final remaining = avail.isFinite
                  ? (avail - width).clamp(0.0, double.infinity)
                  : double.infinity;
              // The canvas list stays open when the sidebar is expanded, or
              // when pinned (so collapsing the notebook sidebar keeps it).
              final canvasColumnOpen = panesVisible &&
                  _selectedSection != null &&
                  (!_sidebarCollapsed || _canvasListPinned);
              return Row(
                children: [
                  _buildNavRail(context, theme, palette),
                  _buildSidebar(theme, palette, width),
                  if (sidebarShown)
                    _resizeDivider(
                      palette,
                      (dx) => setState(() {
                        _sidebarWidth = (_sidebarWidth + dx).clamp(
                          _minSidebarWidth,
                          _maxSidebarWidth,
                        );
                      }),
                    ),
                  _buildCanvasColumn(theme, palette, remaining, canvasColumnOpen),
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
        ),
      ),
    );
  }

  /// The left icon nav rail (redesign): logo, primary destinations, then
  /// Settings + an account avatar pinned to the bottom. Wired to the existing
  /// behavior — Notebooks is the always-present pane, Search opens the overlay,
  /// Bin/Settings push their screens.
  Widget _buildNavRail(
    BuildContext context,
    ThemeData theme,
    AppPalette palette,
  ) {
    return Container(
      width: 60,
      decoration: BoxDecoration(
        color: palette.canvas,
        border: Border(right: BorderSide(color: palette.border)),
      ),
      child: Column(
        children: [
          const SizedBox(height: 22),
          Container(
            width: 34,
            height: 34,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: palette.accent,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              'O',
              style: TextStyle(
                color: theme.colorScheme.onPrimary,
                fontWeight: FontWeight.w700,
                fontSize: 16,
              ),
            ),
          ),
          const SizedBox(height: 20),
          // Notebooks: return to the canvas view (re-expanding the panes) if a
          // full-pane mode is open, else toggle the left panes collapsed.
          // Filled while the panes are expanded (the mobile nav's selected
          // look), outlined while collapsed.
          _railButton(
            palette,
            _mainMode == _MainMode.canvas && !_sidebarCollapsed
                ? Icons.book
                : Icons.book_outlined,
            'Notebooks',
            active: _mainMode == _MainMode.canvas && !_sidebarCollapsed,
            onTap: () => setState(() {
              // Returning from a full-pane mode just restores the canvas view
              // with the sidebar in whatever collapse state the user left it;
              // only an explicit press while already in canvas mode toggles it.
              if (_mainMode != _MainMode.canvas) {
                _mainMode = _MainMode.canvas;
              } else {
                _sidebarCollapsed = !_sidebarCollapsed;
              }
            }),
          ),
          // Search / Bin / Settings take over the main area — the notebooks +
          // canvas-list columns collapse, leaving just this nav rail.
          _railButton(
            palette,
            Icons.search,
            'Search (Ctrl/Cmd+K)',
            active: _mainMode == _MainMode.search,
            onTap: () => _openMainMode(_MainMode.search),
          ),
          _railButton(
            palette,
            Icons.delete_outline,
            'Recycle bin',
            active: _mainMode == _MainMode.bin,
            onTap: () {
              _binRefresh.value++;
              _openMainMode(_MainMode.bin);
            },
          ),
          const Spacer(),
          // Settings also opens as a full pane (no account avatar — multiple
          // accounts are managed inside Settings, so one avatar would mislead).
          _railButton(
            palette,
            Icons.settings_outlined,
            'Settings',
            active: _mainMode == _MainMode.settings,
            onTap: () => _openMainMode(_MainMode.settings),
          ),
          const SizedBox(height: 18),
        ],
      ),
    );
  }

  Widget _railButton(
    AppPalette palette,
    IconData icon,
    String tooltip, {
    bool active = false,
    required VoidCallback onTap,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Tooltip(
        message: tooltip,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(11),
          child: Container(
            width: 44,
            height: 44,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: active ? palette.accentSoft : Colors.transparent,
              borderRadius: BorderRadius.circular(11),
            ),
            child: Icon(
              icon,
              size: 20,
              color: active ? palette.accent : palette.textDim,
            ),
          ),
        ),
      ),
    );
  }

  /// Open a full-pane mode (Search/Bin/Settings): the notebooks + canvas-list
  /// columns collapse, leaving the nav rail + the mode filling the main area.
  // Only switches the main pane — it deliberately does NOT collapse the
  // sidebar (the layout already hides the panes whenever _mainMode != canvas),
  // so returning to Notebooks preserves the user's own collapse choice.
  // Leaving the canvas view disposes the CanvasWorkspace, so clear _fullScreen
  // (its onFullScreenChanged(false) won't fire once it's gone).
  void _openMainMode(_MainMode mode) => setState(() {
    _mainMode = mode;
    _fullScreen = false;
  });

  Widget _buildMainPane(ThemeData theme, AppPalette palette) {
    // Search / Bin / Settings take over the main area (panes collapsed).
    switch (_mainMode) {
      case _MainMode.search:
        return NoteSearchView(
          autofocus: true, // start typing as soon as Search opens
          onReveal: (r) {
            setState(() {
              _mainMode = _MainMode.canvas;
              _sidebarCollapsed = false; // re-expand to show where we landed
            });
            _revealSearchResult(r);
          },
        );
      case _MainMode.bin:
        return BinScreen(refreshSignal: _binRefresh);
      case _MainMode.settings:
        return const SettingsScreen();
      case _MainMode.canvas:
        break;
    }
    final canvas = _selectedCanvas;
    if (canvas != null) {
      // The canvas list stays visible in its own column (OneNote-style), so
      // the canvas embeds directly — no breadcrumb / back bar needed. Hosted in
      // a CanvasWorkspace so "Open canvas alongside" can split the main pane
      // into 2+ canvases here too (a new canvas from the list resets the split,
      // since the key is the selected canvas id).
      return CanvasWorkspace(
        key: ValueKey(canvas.id),
        initialCanvas: canvas,
        initialPageId: _pendingJumpPageId,
        onCanvasRenamed: _reloadSelectedSection,
        // Desktop full screen: the canvas hides its own app bar/toolbar (its
        // internal full-screen) AND the shell hides the side panes so the
        // canvas fills the window. Tracked separately from _sidebarCollapsed
        // so exiting full screen restores the user's own collapse choice.
        onFullScreenChanged: (fs) => setState(() => _fullScreen = fs),
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
    bool open,
  ) {
    final section = _selectedSection;
    final target = open && section != null ? _canvasListWidth : 0.0;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeInOutCubic,
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
            // Switching sections retracts the old canvas list and expands the
            // new one (fade + slide keyed by section id).
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 280),
              switchInCurve: Curves.easeOutCubic,
              switchOutCurve: Curves.easeInCubic,
              transitionBuilder: (child, anim) => FadeTransition(
                opacity: anim,
                child: SlideTransition(
                  position: Tween<Offset>(
                    begin: const Offset(0.06, 0),
                    end: Offset.zero,
                  ).animate(anim),
                  child: child,
                ),
              ),
              child: KeyedSubtree(
                key: ValueKey(section?.id ?? '_none'),
                child: section == null
                    ? const SizedBox.shrink()
                    : _buildCanvasListContent(theme, palette, section),
              ),
            ),
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
              IconButton(
                icon: Icon(
                  _canvasListPinned
                      ? Icons.push_pin
                      : Icons.push_pin_outlined,
                  size: 16,
                  color: _canvasListPinned ? palette.accent : palette.textDim,
                ),
                tooltip: _canvasListPinned
                    ? 'Unpin canvas list'
                    : 'Pin canvas list (keep it when the sidebar is collapsed)',
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                onPressed: () =>
                    setState(() => _canvasListPinned = !_canvasListPinned),
              ),
              PopupMenuButton<String>(
                icon: const Icon(Icons.add, size: 18),
                tooltip: 'Add',
                padding: EdgeInsets.zero,
                onSelected: (a) {
                  if (a == 'canvas') _addCanvas();
                  if (a == 'group') _addCanvasFolder();
                },
                itemBuilder: (context) => [
                  iconMenuItem('canvas', Icons.note_add_outlined, 'New canvas'),
                  iconMenuItem(
                    'group',
                    Icons.create_new_folder_outlined,
                    'New super-section',
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
                    glowId: _glowId,
                    onOpen: (c) => setState(() {
                      _selectedCanvas = c;
                      _mainMode = _MainMode.canvas; // leave Search/Bin
                      _pendingJumpPageId = null; // manual open: don't re-jump
                    }),
                    onConnectionsLeaf: (c) => showConnectionsSheet(
                      context,
                      title: c.name,
                      endpoint: LinkEndpoint(
                        notebookId: section.notebookId,
                        sectionId: section.id,
                        canvasId: c.id,
                      ),
                      endpointName: c.name,
                    ),
                    onConnectionsFolder: (f) => showConnectionsSheet(
                      context,
                      title: f.name,
                      endpoint: LinkEndpoint(
                        notebookId: section.notebookId,
                        sectionId: section.id,
                        folderId: f.id,
                      ),
                      endpointName: f.name,
                    ),
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
    // The content is always laid out at the full sidebar width inside the
    // clip, and only the outer AnimatedContainer width animates 0 ↔ full — so
    // collapse/expand slides smoothly without reflowing the tree mid-transition.
    return AnimatedContainer(
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeInOutCubic,
      width: width,
      color: theme.colorScheme.surface,
      child: ClipRect(
        child: OverflowBox(
          alignment: Alignment.topLeft,
          minWidth: _sidebarWidth,
          maxWidth: _sidebarWidth,
          child: SizedBox(
            width: _sidebarWidth,
            child: Column(
              children: [
                const SizedBox(height: 20),
                _buildHeader(context, palette),
                Divider(height: 1, color: palette.border),
                Expanded(child: _buildTree(palette)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context, AppPalette palette) {
    // Title matches the mobile Notebooks screen; no collapse-toggle icon (the
    // nav rail's Notebooks button collapses/expands the panes now).
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 14, 8, 14),
      child: Row(
        children: [
          const Expanded(
            child: Text(
              'Notebooks',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          // Search and Settings moved to the nav rail; the header keeps the
          // sync status + Add, in the same order as the mobile Notebooks bar.
          const SyncStatusIcon(),
          PopupMenuButton<String>(
            icon: const Icon(Icons.add, size: 20),
            tooltip: 'Add',
            onSelected: (v) {
              if (v == 'new') _createNotebook();
              if (v == 'import') _importNotebook();
            },
            itemBuilder: (context) => [
              iconMenuItem('new', Icons.note_add_outlined, 'New notebook'),
              iconMenuItem(
                'import',
                Icons.file_download_outlined,
                'Import notebook…',
              ),
            ],
          ),
        ],
      ),
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
    final glow = _glowId != null && _glowId == notebook.id;
    final removing = _removingNotebookId == notebook.id;

    return AnimatedSize(
      key: ValueKey('nb_${notebook.id}'),
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeInOut,
      alignment: Alignment.topCenter,
      child: AnimatedOpacity(
        opacity: removing ? 0 : 1,
        duration: const Duration(milliseconds: 200),
        child: removing
            ? const SizedBox(width: double.infinity)
            : Column(
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
                        child: Stack(
                          children: [
                            if (glow)
                              Positioned.fill(
                                child: IgnorePointer(
                                  child: ScrollIntoViewOnce(
                                    key: ValueKey('sv_${notebook.id}'),
                                    child: _glowBox(palette, notebook.id),
                                  ),
                                ),
                              ),
                            InkWell(
                              borderRadius: BorderRadius.circular(kRadius),
                              onTap: () => setState(() {
                                if (expanded) {
                                  _expanded.remove(notebook.id);
                                } else {
                                  _expanded.add(notebook.id);
                                  _everExpanded.add(notebook.id);
                                }
                              }),
                              child: SizedBox(
                                height: 44,
                                child: Row(
                                  children: [
                                    const SizedBox(width: 10),
                                    // Same glyph as the nav rail's Notebooks destination,
                                    // tinted in the notebook's identity color; filled while
                                    // expanded (mirrors the mobile nav's selected state) —
                                    // no chevron, the icon carries the state.
                                    Icon(
                                      expanded
                                          ? Icons.book
                                          : Icons.book_outlined,
                                      size: 18,
                                      color: color,
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
                                    if (SettingsService().defaultNotebookId ==
                                        notebook.id)
                                      Padding(
                                        padding: const EdgeInsets.only(
                                          right: 2,
                                        ),
                                        child: Icon(
                                          Icons.star_rounded,
                                          size: 14,
                                          color: palette.accent,
                                        ),
                                      ),
                                    // Tiny account indicator (profile photo + color ring),
                                    // matching the mobile home cards.
                                    Padding(
                                      padding: const EdgeInsets.only(right: 2),
                                      child: NotebookAccountBadge(
                                        notebook: notebook,
                                      ),
                                    ),
                                    // Compacted tap targets: a bare PopupMenuButton keeps the
                                    // IconButton's 48px min width even with padding:zero, which
                                    // left a big gap between + and ⋮. Constrain each to ~30px
                                    // so the trailing controls sit tight together.
                                    SizedBox(
                                      width: 30,
                                      height: 40,
                                      child: PopupMenuButton<String>(
                                        icon: Icon(
                                          Icons.add,
                                          size: 18,
                                          color: palette.textDim,
                                        ),
                                        tooltip: 'Add',
                                        padding: EdgeInsets.zero,
                                        onSelected: (a) {
                                          if (a == 'section')
                                            _addSection(notebook);
                                          if (a == 'group')
                                            _addSectionFolder(notebook);
                                        },
                                        itemBuilder: (context) => [
                                          iconMenuItem(
                                            'section',
                                            Icons.post_add_outlined,
                                            'New section',
                                          ),
                                          iconMenuItem(
                                            'group',
                                            Icons.create_new_folder_outlined,
                                            'New super-section',
                                          ),
                                        ],
                                      ),
                                    ),
                                    SizedBox(
                                      width: 30,
                                      height: 40,
                                      child: PopupMenuButton<String>(
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
                                            case 'export':
                                              _exportNotebookPdf(notebook);
                                            case 'share':
                                              shareNotebookCopy(
                                                context,
                                                notebook,
                                              );
                                            case 'sharelink':
                                              shareNotebookLink(
                                                context,
                                                notebook,
                                              );
                                            case 'sync':
                                              _pickSyncTarget(notebook);
                                            case 'default':
                                              _toggleDefaultNotebook(notebook);
                                            case 'connections':
                                              showConnectionsSheet(
                                                context,
                                                title: notebook.name,
                                                endpoint: LinkEndpoint(
                                                  notebookId: notebook.id,
                                                ),
                                                endpointName: notebook.name,
                                              );
                                            case 'delete':
                                              _deleteNotebook(notebook);
                                          }
                                        },
                                        itemBuilder: (context) => [
                                          iconMenuItem(
                                            'rename',
                                            Icons.edit_outlined,
                                            'Rename',
                                          ),
                                          iconMenuItem(
                                            'color',
                                            Icons.palette_outlined,
                                            'Change color',
                                          ),
                                          iconMenuItem(
                                            'export',
                                            Icons.picture_as_pdf_outlined,
                                            'Export to PDF',
                                          ),
                                          iconMenuItem(
                                            'share',
                                            Icons.ios_share,
                                            'Send a copy',
                                          ),
                                          iconMenuItem(
                                            'sharelink',
                                            Icons.link,
                                            'Share link',
                                          ),
                                          iconMenuItem(
                                            'sync',
                                            Icons.sync_outlined,
                                            'Sync to…',
                                          ),
                                          iconMenuItem(
                                            'default',
                                            SettingsService()
                                                        .defaultNotebookId ==
                                                    notebook.id
                                                ? Icons.star_rounded
                                                : Icons.star_border_rounded,
                                            SettingsService()
                                                        .defaultNotebookId ==
                                                    notebook.id
                                                ? 'Remove as default target'
                                                : 'Set as default target',
                                          ),
                                          iconMenuItem(
                                            'connections',
                                            Icons.hub_outlined,
                                            'Connections',
                                          ),
                                          iconMenuItem(
                                            'delete',
                                            Icons.delete_outline,
                                            'Delete',
                                            color: Theme.of(
                                              context,
                                            ).colorScheme.error,
                                          ),
                                        ],
                                      ),
                                    ),
                                    const SizedBox(width: 6),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  // Expand/collapse the section tree — animates the height + fade in
                  // BOTH directions (AnimatedCrossFade keeps the content while shrinking,
                  // so collapse reverses the expand instead of blinking out).
                  AnimatedCrossFade(
                    duration: const Duration(milliseconds: 340),
                    sizeCurve: Curves.easeInOutCubic,
                    firstCurve: Curves.easeInOutCubic,
                    secondCurve: Curves.easeInOutCubic,
                    crossFadeState: expanded
                        ? CrossFadeState.showFirst
                        : CrossFadeState.showSecond,
                    secondChild: const SizedBox(width: double.infinity),
                    // Sections hang off their notebook: indented under a rail in the
                    // notebook's color so the parent/child relationship is visible.
                    // Build the tree only for notebooks that have been opened —
                    // AnimatedCrossFade constructs firstChild regardless of collapse
                    // state, so an ungated firstChild would build EVERY notebook's whole
                    // section subtree on every sidebar rebuild (e.g. each canvas click).
                    // `expanded ||` guarantees it's present whenever the animation needs
                    // it. (Perf 07/14/26.)
                    firstChild:
                        (expanded || _everExpanded.contains(notebook.id))
                        ? Padding(
                            padding: const EdgeInsets.only(
                              left: 15,
                              right: 4,
                              bottom: 4,
                            ),
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
                                glowId: _glowId,
                                onOpen: _selectSection,
                                onExportLeaf: _exportSectionPdf,
                                onConnectionsLeaf: (s) => showConnectionsSheet(
                                  context,
                                  title: s.name,
                                  endpoint: LinkEndpoint(
                                    notebookId: notebook.id,
                                    sectionId: s.id,
                                  ),
                                  endpointName: s.name,
                                ),
                                onConnectionsFolder: (f) =>
                                    showConnectionsSheet(
                                  context,
                                  title: f.name,
                                  endpoint: LinkEndpoint(
                                    notebookId: notebook.id,
                                    folderId: f.id,
                                  ),
                                  endpointName: f.name,
                                ),
                                onRenameLeaf: _renameSection,
                                onColorLeaf: _colorSection,
                                onDeleteLeaf: _deleteSection,
                                onRenameFolder: (f) =>
                                    _renameSectionFolder(notebook, f),
                                onColorFolder: (f) =>
                                    _colorSectionFolder(notebook, f),
                                onAddLeafToFolder: (f) =>
                                    _addSection(notebook, folderId: f.id),
                                onAddFolderToFolder: (f) =>
                                    _addSectionFolder(notebook, folderId: f.id),
                                onUngroup: (f) async {
                                  await _service.ungroupInNotebook(
                                    notebook,
                                    f.id,
                                  );
                                  await _reloadNotebook(notebook.id);
                                },
                                onDeleteFolder: (f) =>
                                    _deleteSectionFolder(notebook, f),
                                onRelocate: (node, {required copy}) =>
                                    _relocateSection(
                                      notebook,
                                      node,
                                      copy: copy,
                                    ),
                                onTreeChanged: () =>
                                    _service.saveNotebook(notebook),
                                onCrossDrop: (dragged, srcId, folder, index) =>
                                    _crossDropSection(
                                      notebook,
                                      dragged,
                                      srcId,
                                      folder,
                                    ),
                              ),
                            ),
                          )
                        : const SizedBox(width: double.infinity),
                  ),
                ],
              ),
      ),
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
