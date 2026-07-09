import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';
import '../models/canvas.dart';
import '../models/canvas_page.dart';
import '../models/notebook.dart';
import '../models/section.dart';
import '../models/tree.dart';
import 'settings_service.dart';
import 'sync_service.dart';

/// File-based persistence for the **Notebook → Section → Canvas** model.
///
/// Layout on disk (storage v2):
/// ```
/// <docs>/notebooks.json                                     # nbId -> Notebook (tree of sections)
/// <docs>/notebooks/<nb>/sections/<sec>/section.json         # Section (tree of canvases)
/// <docs>/notebooks/<nb>/sections/<sec>/canvases/<cid>/canvas.json   # Canvas (rows, defaults, attachments)
/// <docs>/notebooks/<nb>/sections/<sec>/canvases/<cid>/pages/<pid>.json
/// <docs>/notebooks/<nb>/sections/<sec>/canvases/<cid>/assets/<sha>.<ext>
/// ```
/// All writes go through [_writeAtomic] (temp file + rename) so an app kill
/// mid-write can't leave a truncated file behind.
class NotebookService {
  static final NotebookService _instance = NotebookService._internal();

  factory NotebookService() => _instance;

  NotebookService._internal();

  late Directory appDir;
  late File notebooksFile;

  static const int _storageVersion = 2;

  Future<void> init() async {
    appDir = await getApplicationDocumentsDirectory();
    notebooksFile = File('${appDir.path}/notebooks.json');
    await _freshStartIfOldFormat();
    if (!await notebooksFile.exists()) {
      await _writeAtomic(notebooksFile, jsonEncode({}));
    }
  }

  /// The Canvas layer (storage v2) changed the on-disk shape incompatibly.
  /// Fresh start was chosen: if a version marker below the current one is
  /// present (or absent while data exists), move the old data aside and begin
  /// empty rather than migrate.
  Future<void> _freshStartIfOldFormat() async {
    final versionFile = File('${appDir.path}/storage_version.txt');
    int existing = 0;
    if (await versionFile.exists()) {
      existing = int.tryParse((await versionFile.readAsString()).trim()) ?? 0;
    }
    if (existing < _storageVersion && await notebooksFile.exists()) {
      final stamp = DateTime.now().millisecondsSinceEpoch;
      try {
        await notebooksFile.rename(
          '${appDir.path}/notebooks_legacy_$stamp.json',
        );
      } catch (_) {}
      final dir = Directory('${appDir.path}/notebooks');
      if (await dir.exists()) {
        try {
          await dir.rename('${appDir.path}/notebooks_legacy_$stamp');
        } catch (_) {}
      }
    }
    await versionFile.writeAsString('$_storageVersion', flush: true);
  }

  Future<void> _writeAtomic(File file, String content) async {
    await file.parent.create(recursive: true);
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(content, flush: true);
    if (await file.exists()) await file.delete();
    await tmp.rename(file.path);
    // Notify sync service about the write (no-op if not signed in).
    SyncService().onLocalFileSaved(file.path, content);
  }

  /// Public shim used by [SyncService] to write remote content locally
  /// without triggering another upload loop.
  Future<void> writeAtomicPublic(File file, String content) async {
    await file.parent.create(recursive: true);
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(content, flush: true);
    if (await file.exists()) await file.delete();
    await tmp.rename(file.path);
  }

  /// Binary counterpart of [writeAtomicPublic] — for pulled asset blobs.
  Future<void> writeAtomicBytesPublic(File file, List<int> bytes) async {
    await file.parent.create(recursive: true);
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsBytes(bytes, flush: true);
    if (await file.exists()) await file.delete();
    await tmp.rename(file.path);
  }

  static String _basename(String path) =>
      path.replaceAll('\\', '/').split('/').where((s) => s.isNotEmpty).last;

  /// Recursively copies [src] into [dst].
  Future<void> _copyDir(Directory src, Directory dst) async {
    await dst.create(recursive: true);
    await for (final entity in src.list()) {
      final name = _basename(entity.path);
      if (entity is Directory) {
        await _copyDir(entity, Directory('${dst.path}/$name'));
      } else if (entity is File) {
        await entity.copy('${dst.path}/$name');
      }
    }
  }

  // ── Notebooks ──────────────────────────────────────────────────────────

  Future<Map<String, dynamic>> _readIndex() async {
    try {
      return jsonDecode(await notebooksFile.readAsString()) as Map<String, dynamic>;
    } catch (_) {
      // If the file is corrupted or empty, return an empty map to allow recovery.
      return {};
    }
  }

  Future<List<Notebook>> getNotebooks() async {
    final data = await _readIndex();
    return data.values
        .map((json) => Notebook.fromJson(json as Map<String, dynamic>))
        .where((nb) => nb.deletedAt == null)
        .toList();
  }

  Future<Notebook?> getNotebook(String notebookId) async {
    final data = await _readIndex();
    final json = data[notebookId] as Map<String, dynamic>?;
    if (json == null) return null;
    final nb = Notebook.fromJson(json);
    return nb.deletedAt == null ? nb : null;
  }

  Future<Notebook> createNotebook(String name) async {
    final notebook = Notebook(id: newId(), deviceId: SettingsService().deviceId, name: name, createdAt: DateTime.now());
    final data = await _readIndex();
    data[notebook.id] = notebook.toJson();
    await _writeAtomic(notebooksFile, jsonEncode(data));
    return notebook;
  }

  /// Persists a notebook's full metadata (name, color, section tree). The
  /// in-memory [Notebook] is the source of truth — mutate then call this.
  Future<void> saveNotebook(Notebook notebook) async {
    notebook.bumpRev(SettingsService().deviceId);
    final data = await _readIndex();
    data[notebook.id] = notebook.toJson();
    await _writeAtomic(notebooksFile, jsonEncode(data));
  }

  Future<void> renameNotebook(String notebookId, String name) async {
    final nb = await getNotebook(notebookId);
    if (nb == null) return;
    nb.name = name;
    await saveNotebook(nb);
  }

  Future<void> setNotebookColor(String notebookId, int? color) async {
    final nb = await getNotebook(notebookId);
    if (nb == null) return;
    nb.color = color;
    await saveNotebook(nb);
  }

  Future<void> reorderNotebooks(List<String> orderedIds) async {
    final data = await _readIndex();
    final reordered = <String, dynamic>{};
    for (final id in orderedIds) {
      if (data.containsKey(id)) reordered[id] = data[id];
    }
    for (final entry in data.entries) {
      reordered.putIfAbsent(entry.key, () => entry.value);
    }
    await _writeAtomic(notebooksFile, jsonEncode(reordered));
  }

  /// Soft-delete: tombstone the entry (never remove it from the map). A
  /// removed map entry has no envelope left to compare, so another device
  /// that still has the notebook would win the union merge and bring it
  /// back — the classic "delete doesn't stick" bug. Physical cleanup happens
  /// later via [runGarbageCollection], once the tombstone is old enough that
  /// every device has had a chance to observe it.
  Future<void> deleteNotebook(String notebookId) async {
    final data = await _readIndex();
    final json = data[notebookId] as Map<String, dynamic>?;
    if (json == null) return;
    final nb = Notebook.fromJson(json);
    nb.deletedAt = DateTime.now();
    nb.bumpRev(SettingsService().deviceId);
    data[notebookId] = nb.toJson();
    await _writeAtomic(notebooksFile, jsonEncode(data));
  }

  // ── Sections (containers of canvases) ──────────────────────────────────

  Directory sectionDir(String notebookId, String sectionId) =>
      Directory('${appDir.path}/notebooks/$notebookId/sections/$sectionId');

  File _sectionFile(String notebookId, String sectionId) =>
      File('${sectionDir(notebookId, sectionId).path}/section.json');

  Future<Section?> getSection(String notebookId, String sectionId) async {
    final file = _sectionFile(notebookId, sectionId);
    if (!await file.exists()) return null;
    try {
      final s = Section.fromJson(
        jsonDecode(await file.readAsString()) as Map<String, dynamic>,
      );
      return s.deletedAt == null ? s : null;
    } catch (_) {
      return null;
    }
  }

  Future<Map<String, Section>> getSectionMap(String notebookId) async {
    final nb = await getNotebook(notebookId);
    if (nb == null) return {};
    final out = <String, Section>{};
    for (final id in nb.allSectionIds) {
      final s = await getSection(notebookId, id);
      if (s != null) out[id] = s;
    }
    return out;
  }

  Future<void> saveSection(Section section) async {
    section.bumpRev(SettingsService().deviceId);
    await _writeAtomic(
      _sectionFile(section.notebookId, section.id),
      jsonEncode(section.toJson()),
    );
  }

  /// Creates a section (with one default canvas) into the notebook root or a
  /// folder.
  Future<Section> createSection(
    String notebookId,
    String name, {
    String? parentFolderId,
  }) async {
    final section = Section(
      id: newId(),
      deviceId: SettingsService().deviceId,
      notebookId: notebookId,
      name: name,
      createdAt: DateTime.now(),
    );
    // Seed one default canvas so the section isn't empty.
    final canvas = _newCanvas(notebookId, section.id, 'Canvas 1');
    section.nodes.add(LeafNode(canvas.id));
    await _writeCanvasWithDefaultPage(canvas);
    await saveSection(section);

    final nb = await getNotebook(notebookId);
    if (nb != null) {
      final target = parentFolderId == null
          ? nb.nodes
          : TreeOps.findFolder(nb.nodes, parentFolderId)?.children ?? nb.nodes;
      target.add(LeafNode(section.id));
      await saveNotebook(nb);
    }
    return section;
  }

  Future<void> renameSection(Section section, String name) async {
    section.name = name;
    await saveSection(section);
  }

  Future<void> setSectionColor(Section section, int? color) async {
    section.color = color;
    await saveSection(section);
  }

  /// Soft-delete: tombstone the section (keep section.json + its canvases on
  /// disk for GC later), and drop the tree leaf locally for immediate UI
  /// cleanliness. The tombstone — not tree membership — is what makes the
  /// deletion durable across devices (see [deleteNotebook]).
  Future<void> deleteSection(String notebookId, String sectionId) async {
    final sec = await getSection(notebookId, sectionId);
    if (sec != null) {
      sec.deletedAt = DateTime.now();
      await saveSection(sec);
    }
    final nb = await getNotebook(notebookId);
    if (nb != null) {
      TreeOps.removeLeaf(nb.nodes, sectionId);
      await saveNotebook(nb);
    }
  }

  // ── Canvases (drawing surfaces) ────────────────────────────────────────

  Directory canvasDir(String notebookId, String sectionId, String canvasId) =>
      Directory('${sectionDir(notebookId, sectionId).path}/canvases/$canvasId');

  File _canvasFile(Canvas c) =>
      File('${canvasDir(c.notebookId, c.sectionId, c.id).path}/canvas.json');

  File _pageFile(Canvas c, String pageId) => File(
    '${canvasDir(c.notebookId, c.sectionId, c.id).path}/pages/$pageId.json',
  );

  Directory assetsDir(Canvas c) =>
      Directory('${canvasDir(c.notebookId, c.sectionId, c.id).path}/assets');

  Canvas _newCanvas(String notebookId, String sectionId, String name) => Canvas(
    id: newId(),
    notebookId: notebookId,
    sectionId: sectionId,
    name: name,
    createdAt: DateTime.now(),
    defaultBackground: SettingsService().effectiveDefaultBackground(),
  );

  Future<void> _writeCanvasWithDefaultPage(Canvas canvas) async {
    final page = CanvasPage(
      id: newId(),
      deviceId: SettingsService().deviceId,
      width: canvas.defaultPageWidth,
      height: canvas.defaultPageHeight,
      background: canvas.defaultBackground,
    );
    canvas.rows.add(PageRow(id: newId(), pageIds: [page.id]));
    await savePage(canvas, page);
    await saveCanvas(canvas);
  }

  Future<Canvas?> getCanvas(
    String notebookId,
    String sectionId,
    String canvasId,
  ) async {
    final file = File(
      '${canvasDir(notebookId, sectionId, canvasId).path}/canvas.json',
    );
    if (!await file.exists()) return null;
    try {
      final c = Canvas.fromJson(
        jsonDecode(await file.readAsString()) as Map<String, dynamic>,
      );
      return c.deletedAt == null ? c : null;
    } catch (_) {
      return null;
    }
  }

  Future<Map<String, Canvas>> getCanvasMap(Section section) async {
    final out = <String, Canvas>{};
    for (final id in section.allCanvasIds) {
      final c = await getCanvas(section.notebookId, section.id, id);
      if (c != null) out[id] = c;
    }
    return out;
  }

  Future<void> saveCanvas(Canvas canvas) async {
    canvas.bumpRev(SettingsService().deviceId);
    await _writeAtomic(_canvasFile(canvas), jsonEncode(canvas.toJson()));
  }

  Future<Canvas> createCanvas(
    Section section,
    String name, {
    String? parentFolderId,
  }) async {
    final canvas = _newCanvas(section.notebookId, section.id, name);
    await _writeCanvasWithDefaultPage(canvas);
    final target = parentFolderId == null
        ? section.nodes
        : TreeOps.findFolder(section.nodes, parentFolderId)?.children ??
              section.nodes;
    target.add(LeafNode(canvas.id));
    await saveSection(section);
    return canvas;
  }

  Future<void> renameCanvas(Canvas canvas, String name) async {
    canvas.name = name;
    await saveCanvas(canvas);
  }

  Future<void> setCanvasColor(Canvas canvas, int? color) async {
    canvas.color = color;
    await saveCanvas(canvas);
  }

  /// Soft-delete: tombstone the canvas (keep canvas.json + its pages/assets
  /// on disk for GC later), and drop the tree leaf locally. See
  /// [deleteNotebook] for why tombstoning (not tree removal) is what makes a
  /// delete durable.
  Future<void> deleteCanvas(Section section, String canvasId) async {
    final c = await getCanvas(section.notebookId, section.id, canvasId);
    if (c != null) {
      c.deletedAt = DateTime.now();
      await saveCanvas(c);
    }
    TreeOps.removeLeaf(section.nodes, canvasId);
    await saveSection(section);
  }

  // ── Folders (super-sections) at both levels ────────────────────────────

  FolderNode _newFolder(String name) => FolderNode(id: newId(), name: name);

  Future<void> createSectionFolder(
    Notebook notebook,
    String name, {
    String? parentFolderId,
  }) async {
    final folder = _newFolder(name);
    final target = parentFolderId == null
        ? notebook.nodes
        : TreeOps.findFolder(notebook.nodes, parentFolderId)?.children ??
              notebook.nodes;
    target.add(folder);
    await saveNotebook(notebook);
  }

  Future<void> createCanvasFolder(
    Section section,
    String name, {
    String? parentFolderId,
  }) async {
    final folder = _newFolder(name);
    final target = parentFolderId == null
        ? section.nodes
        : TreeOps.findFolder(section.nodes, parentFolderId)?.children ??
              section.nodes;
    target.add(folder);
    await saveSection(section);
  }

  Future<void> ungroupInNotebook(Notebook notebook, String folderId) async {
    TreeOps.spliceOutFolder(notebook.nodes, folderId);
    await saveNotebook(notebook);
  }

  Future<void> ungroupInSection(Section section, String folderId) async {
    TreeOps.spliceOutFolder(section.nodes, folderId);
    await saveSection(section);
  }

  /// Deletes a section-tree folder and all sections inside it.
  Future<void> deleteSectionFolder(Notebook notebook, String folderId) async {
    final folder = TreeOps.findFolder(notebook.nodes, folderId);
    final ids = folder?.collectLeafIds() ?? const <String>[];
    TreeOps.removeFolder(notebook.nodes, folderId);
    await saveNotebook(notebook);
    for (final sectionId in ids) {
      final dir = sectionDir(notebook.id, sectionId);
      if (await dir.exists()) await dir.delete(recursive: true);
    }
  }

  /// Deletes a canvas-tree folder and all canvases inside it.
  Future<void> deleteCanvasFolder(Section section, String folderId) async {
    final folder = TreeOps.findFolder(section.nodes, folderId);
    final ids = folder?.collectLeafIds() ?? const <String>[];
    TreeOps.removeFolder(section.nodes, folderId);
    await saveSection(section);
    for (final canvasId in ids) {
      final dir = canvasDir(section.notebookId, section.id, canvasId);
      if (await dir.exists()) await dir.delete(recursive: true);
    }
  }

  // ── Move / copy (whole nodes: leaves or folder subtrees) ───────────────

  void _removeNode(List<TreeNode> nodes, TreeNode node) {
    if (node is LeafNode) {
      TreeOps.removeLeaf(nodes, node.refId);
    } else if (node is FolderNode) {
      TreeOps.removeFolder(nodes, node.id);
    }
  }

  void _addNode(List<TreeNode> nodes, TreeNode node, String? folderId) {
    final target = folderId == null
        ? nodes
        : TreeOps.findFolder(nodes, folderId)?.children ?? nodes;
    target.add(node);
  }

  /// Deep-clones [node], remapping each leaf refId via [idMap] (for copy) and
  /// giving folders fresh ids when [newFolderIds].
  TreeNode _remapClone(
    TreeNode node,
    Map<String, String> idMap, {
    bool newFolderIds = false,
  }) {
    if (node is LeafNode) return LeafNode(idMap[node.refId] ?? node.refId);
    final f = node as FolderNode;
    return FolderNode(
      id: newFolderIds ? newId() : f.id,
      name: f.name,
      color: f.color,
      collapsed: f.collapsed,
      children: f.children
          .map((c) => _remapClone(c, idMap, newFolderIds: newFolderIds))
          .toList(),
    );
  }

  // Section (in a notebook) --------------------------------------------------

  /// Moves a section-tree node (a section leaf, or a whole super-section
  /// subtree) from [srcNbId] into [dstNbId] under [dstFolderId] (root if null).
  /// Relocates every contained section's files when the notebook changes, and
  /// updates both notebooks' trees. Same node object is reused (ids unchanged).
  Future<void> moveSectionNode(
    String srcNbId,
    TreeNode node,
    String dstNbId, {
    String? dstFolderId,
  }) async {
    if (srcNbId != dstNbId) {
      for (final sectionId in node.collectLeafIds()) {
        await _relocateSectionDir(srcNbId, sectionId, dstNbId);
      }
    }
    final srcNb = await getNotebook(srcNbId);
    if (srcNb != null) {
      _removeNode(srcNb.nodes, node);
      await saveNotebook(srcNb);
    }
    final dstNb = await getNotebook(dstNbId);
    if (dstNb != null) {
      _addNode(dstNb.nodes, node.clone(), dstFolderId);
      await saveNotebook(dstNb);
    }
  }

  /// Duplicates a section-tree node into [dstNbId] under fresh ids.
  Future<void> copySectionNode(
    String srcNbId,
    TreeNode node,
    String dstNbId, {
    String? dstFolderId,
  }) async {
    final idMap = <String, String>{};
    for (final sectionId in node.collectLeafIds()) {
      idMap[sectionId] = await _duplicateSectionDir(srcNbId, sectionId, dstNbId);
    }
    final clone = _remapClone(node, idMap, newFolderIds: true);
    final dstNb = await getNotebook(dstNbId);
    if (dstNb != null) {
      _addNode(dstNb.nodes, clone, dstFolderId);
      await saveNotebook(dstNb);
    }
  }

  Future<void> _relocateSectionDir(
    String srcNbId,
    String sectionId,
    String dstNbId,
  ) async {
    final src = sectionDir(srcNbId, sectionId);
    final dst = sectionDir(dstNbId, sectionId);
    if (await src.exists()) {
      await dst.parent.create(recursive: true);
      try {
        await src.rename(dst.path);
      } catch (_) {
        await _copyDir(src, dst);
        await src.delete(recursive: true);
      }
    }
    await _rewriteSection(dstNbId, sectionId, dstNbId);
  }

  Future<String> _duplicateSectionDir(
    String srcNbId,
    String sectionId,
    String dstNbId,
  ) async {
    final src = sectionDir(srcNbId, sectionId);
    final newSectionId = newId();
    if (await src.exists()) {
      await _copyDir(src, sectionDir(dstNbId, newSectionId));
    }
    await _rewriteSection(dstNbId, newSectionId, dstNbId, newSectionId: newSectionId);
    return newSectionId;
  }

  /// Rewrites `notebookId` (and optionally id) in a section.json and the
  /// `notebookId`/`sectionId` of every canvas.json under it.
  Future<void> _rewriteSection(
    String notebookId,
    String sectionDirId,
    String newNotebookId, {
    String? newSectionId,
  }) async {
    final sec = await getSection(notebookId, sectionDirId);
    if (sec == null) return;
    final effectiveSectionId = newSectionId ?? sec.id;
    await _writeAtomic(
      _sectionFile(newNotebookId, sectionDirId),
      jsonEncode(
        Section(
          id: effectiveSectionId,
          deviceId: SettingsService().deviceId,
          notebookId: newNotebookId,
          name: sec.name,
          createdAt: sec.createdAt,
          color: sec.color,
          nodes: sec.nodes,
        ).toJson(),
      ),
    );
    for (final canvasId in sec.allCanvasIds) {
      final c = await getCanvas(newNotebookId, sectionDirId, canvasId);
      if (c == null) continue;
      await _writeAtomic(
        File(
          '${canvasDir(newNotebookId, sectionDirId, canvasId).path}/canvas.json',
        ),
        jsonEncode(
          Canvas(
            id: c.id,
            deviceId: SettingsService().deviceId,
            notebookId: newNotebookId,
            sectionId: effectiveSectionId,
            name: c.name,
            createdAt: c.createdAt,
            color: c.color,
            defaultPageWidth: c.defaultPageWidth,
            defaultPageHeight: c.defaultPageHeight,
            defaultBackground: c.defaultBackground,
            rows: c.rows,
            attachments: c.attachments,
            bookmarks: c.bookmarks,
          ).toJson(),
        ),
      );
    }
  }

  // Canvas (in a section) ----------------------------------------------------

  Future<void> moveCanvasNode(
    String srcNbId,
    String srcSecId,
    TreeNode node,
    String dstNbId,
    String dstSecId, {
    String? dstFolderId,
  }) async {
    final sameSection = srcNbId == dstNbId && srcSecId == dstSecId;
    if (!sameSection) {
      for (final canvasId in node.collectLeafIds()) {
        await _relocateCanvasDir(srcNbId, srcSecId, canvasId, dstNbId, dstSecId);
      }
    }
    final srcSec = await getSection(srcNbId, srcSecId);
    if (srcSec != null) {
      _removeNode(srcSec.nodes, node);
      await saveSection(srcSec);
    }
    final dstSec = await getSection(dstNbId, dstSecId);
    if (dstSec != null) {
      _addNode(dstSec.nodes, node.clone(), dstFolderId);
      await saveSection(dstSec);
    }
  }

  Future<void> copyCanvasNode(
    String srcNbId,
    String srcSecId,
    TreeNode node,
    String dstNbId,
    String dstSecId, {
    String? dstFolderId,
  }) async {
    final idMap = <String, String>{};
    for (final canvasId in node.collectLeafIds()) {
      idMap[canvasId] = await _duplicateCanvasDir(
        srcNbId,
        srcSecId,
        canvasId,
        dstNbId,
        dstSecId,
      );
    }
    final clone = _remapClone(node, idMap, newFolderIds: true);
    final dstSec = await getSection(dstNbId, dstSecId);
    if (dstSec != null) {
      _addNode(dstSec.nodes, clone, dstFolderId);
      await saveSection(dstSec);
    }
  }

  Future<void> _relocateCanvasDir(
    String srcNbId,
    String srcSecId,
    String canvasId,
    String dstNbId,
    String dstSecId,
  ) async {
    final src = canvasDir(srcNbId, srcSecId, canvasId);
    final dst = canvasDir(dstNbId, dstSecId, canvasId);
    if (await src.exists()) {
      await dst.parent.create(recursive: true);
      try {
        await src.rename(dst.path);
      } catch (_) {
        await _copyDir(src, dst);
        await src.delete(recursive: true);
      }
    }
    await _rewriteCanvas(dstNbId, dstSecId, canvasId, dstNbId, dstSecId);
  }

  Future<String> _duplicateCanvasDir(
    String srcNbId,
    String srcSecId,
    String canvasId,
    String dstNbId,
    String dstSecId,
  ) async {
    final src = canvasDir(srcNbId, srcSecId, canvasId);
    final newCanvasId = newId();
    if (await src.exists()) {
      await _copyDir(src, canvasDir(dstNbId, dstSecId, newCanvasId));
    }
    await _rewriteCanvas(
      dstNbId,
      dstSecId,
      newCanvasId,
      dstNbId,
      dstSecId,
      newCanvasId: newCanvasId,
    );
    return newCanvasId;
  }

  Future<void> _rewriteCanvas(
    String readNbId,
    String readSecId,
    String canvasDirId,
    String newNbId,
    String newSecId, {
    String? newCanvasId,
  }) async {
    final c = await getCanvas(readNbId, readSecId, canvasDirId);
    if (c == null) return;
    await _writeAtomic(
      File('${canvasDir(newNbId, newSecId, canvasDirId).path}/canvas.json'),
      jsonEncode(
        Canvas(
          id: newCanvasId ?? c.id,
          deviceId: SettingsService().deviceId,
          notebookId: newNbId,
          sectionId: newSecId,
          name: c.name,
          createdAt: c.createdAt,
          color: c.color,
          defaultPageWidth: c.defaultPageWidth,
          defaultPageHeight: c.defaultPageHeight,
          defaultBackground: c.defaultBackground,
          rows: c.rows,
          attachments: c.attachments,
          bookmarks: c.bookmarks,
        ).toJson(),
      ),
    );
  }

  // ── Pages (canvas-scoped) ──────────────────────────────────────────────

  /// Loads every page referenced by [canvas.rows]. A page whose file carries
  /// a tombstone (`deletedAt` set — soft-deleted on this or another device) is
  /// dropped from the result *and* pruned out of `canvas.rows`, so a
  /// structural row-list that lost a race against the deletion (whole-doc LWW
  /// on canvas.json) self-heals instead of resurrecting a dead page. If
  /// pruning would leave zero pages, a fresh blank page is inserted — a
  /// canvas is never allowed to end up empty.
  Future<Map<String, CanvasPage>> loadPages(Canvas canvas) async {
    final pages = <String, CanvasPage>{};
    var pruned = false;

    for (final row in List.of(canvas.rows)) {
      final keep = <String>[];
      for (final pageId in row.pageIds) {
        final file = _pageFile(canvas, pageId);
        CanvasPage? loaded;
        if (await file.exists()) {
          try {
            loaded = CanvasPage.fromJson(
              jsonDecode(await file.readAsString()) as Map<String, dynamic>,
            );
          } catch (_) {}
        }
        if (loaded != null) {
          if (loaded.deletedAt != null) {
            pruned = true; // tombstoned elsewhere — drop the dead reference
            continue;
          }
          pages[pageId] = loaded;
          keep.add(pageId);
          continue;
        }
        pages[pageId] = CanvasPage(
          id: pageId,
          deviceId: SettingsService().deviceId,
          width: canvas.defaultPageWidth,
          height: canvas.defaultPageHeight,
          background: canvas.defaultBackground,
        );
        keep.add(pageId);
      }
      if (keep.length != row.pageIds.length) {
        row.pageIds
          ..clear()
          ..addAll(keep);
      }
    }
    canvas.rows.removeWhere((r) => r.pageIds.isEmpty);

    if (canvas.rows.isEmpty) {
      final page = CanvasPage(
        id: newId(),
        deviceId: SettingsService().deviceId,
        width: canvas.defaultPageWidth,
        height: canvas.defaultPageHeight,
        background: canvas.defaultBackground,
      );
      canvas.rows.add(PageRow(id: newId(), pageIds: [page.id]));
      pages[page.id] = page;
      await savePage(canvas, page);
      pruned = true;
    }

    if (pruned) await saveCanvas(canvas);
    return pages;
  }

  Future<void> savePage(Canvas canvas, CanvasPage page) async {
    page.bumpRev(SettingsService().deviceId);
    await _writeAtomic(_pageFile(canvas, page.id), jsonEncode(page.toJson()));
  }

  Future<void> deletePageFile(Canvas canvas, String pageId) async {
    final file = _pageFile(canvas, pageId);
    if (await file.exists()) await file.delete();
  }

  // ── Assets (content-addressed, canvas-scoped) ──────────────────────────

  Future<String> putAsset(
    Canvas canvas,
    List<int> bytes,
    String extension,
  ) async {
    final hash = sha256.convert(bytes).toString();
    final assetId = '$hash.$extension';
    final file = File('${assetsDir(canvas).path}/$assetId');
    if (!await file.exists()) {
      await file.parent.create(recursive: true);
      final tmp = File('${file.path}.tmp');
      await tmp.writeAsBytes(bytes, flush: true);
      await tmp.rename(file.path);
      // Notify sync service about the new asset.
      SyncService().onLocalAssetSaved(file.path, bytes);
    }
    return assetId;
  }

  File assetFile(Canvas canvas, String assetId) =>
      File('${assetsDir(canvas).path}/$assetId');

  /// IDs unique across the app: millis + a monotonic suffix.
  static int _idSeq = 0;
  String newId() =>
      '${DateTime.now().millisecondsSinceEpoch}${(_idSeq++ % 1000).toString().padLeft(3, '0')}';

  // ── Sync helpers ───────────────────────────────────────────────────────

  /// True if [rel] (a forward-slash path relative to [appDir]) is a file that
  /// should be mirrored to Drive. Excludes temp/local-only bookkeeping files.
  static bool isSyncedRelPath(String rel) {
    if (rel.endsWith('.tmp')) return false;
    if (rel == 'notebooks.json') return true;
    if (!rel.startsWith('notebooks/')) return false;
    // Only structural JSON, page JSON, and asset blobs are synced.
    return true;
  }

  /// Relative (forward-slash) path of an absolute local path, or null if it is
  /// outside [appDir] or not a synced file.
  String? relPathOf(String absolutePath) {
    final base = appDir.path.replaceAll('\\', '/');
    final p = absolutePath.replaceAll('\\', '/');
    if (!p.startsWith(base)) return null;
    var rel = p.substring(base.length);
    if (rel.startsWith('/')) rel = rel.substring(1);
    return isSyncedRelPath(rel) ? rel : null;
  }

  File fileForRelPath(String rel) => File('${appDir.path}/$rel');

  /// Every synced file currently on disk, as forward-slash relative paths.
  Future<Set<String>> listSyncedRelPaths() async {
    final out = <String>{};
    final nb = notebooksFile;
    if (await nb.exists()) out.add('notebooks.json');
    final dir = Directory('${appDir.path}/notebooks');
    if (await dir.exists()) {
      await for (final e in dir.list(recursive: true, followLinks: false)) {
        if (e is! File) continue;
        final rel = relPathOf(e.path);
        if (rel != null) out.add(rel);
      }
    }
    return out;
  }

  // ── Recycle bin (tombstoned items, restorable for 30 days) ──────────────

  /// Everything currently soft-deleted (notebooks/sections/canvases), for the
  /// bin screen. Reads tombstoned files directly — the normal getters filter
  /// them out on purpose.
  Future<List<BinItem>> listDeletedItems() async {
    final out = <BinItem>[];
    final index = await _readIndex();
    final notebookNames = <String, String>{};
    final deletedNotebookIds = <String>{};

    for (final entry in index.entries) {
      final json = entry.value as Map<String, dynamic>;
      notebookNames[entry.key] = json['name'] as String? ?? 'Notebook';
      final deletedAt = json['deletedAt'];
      if (deletedAt is num) {
        deletedNotebookIds.add(entry.key);
        out.add(BinItem(
          type: BinItemType.notebook,
          name: notebookNames[entry.key]!,
          deletedAt: DateTime.fromMillisecondsSinceEpoch(deletedAt.toInt()),
          notebookId: entry.key,
          parentAlive: true,
          parentName: '',
        ));
      }
    }

    final nbRoot = Directory('${appDir.path}/notebooks');
    if (!await nbRoot.exists()) return out;
    await for (final nbDir in nbRoot.list(followLinks: false)) {
      if (nbDir is! Directory) continue;
      final nbId = _basename(nbDir.path);
      final nbName = notebookNames[nbId] ?? 'Notebook';
      final nbAlive =
          notebookNames.containsKey(nbId) && !deletedNotebookIds.contains(nbId);
      final secRoot = Directory('${nbDir.path}/sections');
      if (!await secRoot.exists()) continue;
      await for (final secDir in secRoot.list(followLinks: false)) {
        if (secDir is! Directory) continue;
        final secId = _basename(secDir.path);
        final secJson = await _readJsonFile(File('${secDir.path}/section.json'));
        final secDeleted = secJson?['deletedAt'];
        final secName = secJson?['name'] as String? ?? 'Section';
        if (secDeleted is num) {
          out.add(BinItem(
            type: BinItemType.section,
            name: secName,
            deletedAt:
                DateTime.fromMillisecondsSinceEpoch(secDeleted.toInt()),
            notebookId: nbId,
            sectionId: secId,
            parentAlive: nbAlive,
            parentName: nbName,
          ));
        }
        final cvRoot = Directory('${secDir.path}/canvases');
        if (!await cvRoot.exists()) continue;
        await for (final cvDir in cvRoot.list(followLinks: false)) {
          if (cvDir is! Directory) continue;
          final cvJson =
              await _readJsonFile(File('${cvDir.path}/canvas.json'));
          final cvDeleted = cvJson?['deletedAt'];
          if (cvDeleted is! num) continue;
          out.add(BinItem(
            type: BinItemType.canvas,
            name: cvJson?['name'] as String? ?? 'Canvas',
            deletedAt: DateTime.fromMillisecondsSinceEpoch(cvDeleted.toInt()),
            notebookId: nbId,
            sectionId: secId,
            canvasId: _basename(cvDir.path),
            parentAlive: nbAlive && secDeleted is! num,
            parentName: secName,
          ));
        }
      }
    }
    out.sort((a, b) => b.deletedAt.compareTo(a.deletedAt));
    return out;
  }

  Future<Map<String, dynamic>?> _readJsonFile(File f) async {
    if (!await f.exists()) return null;
    try {
      return jsonDecode(await f.readAsString()) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  /// Restores a tombstoned item: clears `deletedAt`, bumps `rev` (so the
  /// restore beats the tombstone in every device's LWW merge and propagates
  /// through sync), and re-links the tree leaf its deletion removed.
  Future<void> restoreBinItem(BinItem item) async {
    switch (item.type) {
      case BinItemType.notebook:
        final data = await _readIndex();
        final json = data[item.notebookId] as Map<String, dynamic>?;
        if (json == null) return;
        final nb = Notebook.fromJson(json);
        nb.deletedAt = null;
        nb.bumpRev(SettingsService().deviceId);
        data[item.notebookId] = nb.toJson();
        await _writeAtomic(notebooksFile, jsonEncode(data));

      case BinItemType.section:
        final json = await _readJsonFile(
            _sectionFile(item.notebookId, item.sectionId!));
        if (json == null) return;
        final sec = Section.fromJson(json);
        sec.deletedAt = null;
        await saveSection(sec); // bumps rev
        final nb = await getNotebook(item.notebookId);
        if (nb != null && !nb.allSectionIds.contains(sec.id)) {
          nb.nodes.add(LeafNode(sec.id));
          await saveNotebook(nb);
        }

      case BinItemType.canvas:
        final json = await _readJsonFile(File(
            '${canvasDir(item.notebookId, item.sectionId!, item.canvasId!).path}/canvas.json'));
        if (json == null) return;
        final c = Canvas.fromJson(json);
        c.deletedAt = null;
        await saveCanvas(c); // bumps rev
        final sec = await getSection(item.notebookId, item.sectionId!);
        if (sec != null && !sec.allCanvasIds.contains(c.id)) {
          sec.nodes.add(LeafNode(c.id));
          await saveSection(sec);
        }
    }
  }

  /// Immediately, physically deletes a binned item from local disk (Drive
  /// keeps its tombstoned copy — harmless; see GC notes).
  Future<void> purgeBinItem(BinItem item) async {
    switch (item.type) {
      case BinItemType.notebook:
        final data = await _readIndex();
        data.remove(item.notebookId);
        await _writeAtomic(notebooksFile, jsonEncode(data));
        final dir = Directory('${appDir.path}/notebooks/${item.notebookId}');
        if (await dir.exists()) await dir.delete(recursive: true);
      case BinItemType.section:
        final dir = sectionDir(item.notebookId, item.sectionId!);
        if (await dir.exists()) await dir.delete(recursive: true);
      case BinItemType.canvas:
        final dir =
            canvasDir(item.notebookId, item.sectionId!, item.canvasId!);
        if (await dir.exists()) await dir.delete(recursive: true);
    }
  }

  // ── Garbage collection (purge tombstones older than the bin window) ─────

  /// Bin retention: soft-deleted items stay restorable this long, then the
  /// GC sweep removes them permanently.
  static const Duration _kGcMaxAge = Duration(days: 30);

  /// Physically deletes tombstoned notebooks/sections/canvases/pages whose
  /// `deletedAt` is older than [maxAge], and drops old erase/delete-object
  /// tombstone *entries* from otherwise-live pages (the content they mark is
  /// long gone either way; only the tiny bookkeeping record is dropped).
  ///
  /// Local-disk only — does not delete the Drive-side copy (Drive's folder
  /// API isn't relPath-indexed the way files are, so a safe remote purge is a
  /// separate concern; see KNOWN_ISSUES). Purging only locally is harmless:
  /// at worst a later full resync re-downloads a tombstone file that was
  /// purged early, which wastes a little disk, not correctness.
  Future<void> runGarbageCollection({Duration maxAge = _kGcMaxAge}) async {
    final cutoff = DateTime.now().subtract(maxAge);
    final data = await _readIndex();
    var indexChanged = false;
    final purgeNotebookIds = <String>[];

    for (final entry in data.entries) {
      final json = entry.value as Map<String, dynamic>;
      if (_tombstoneExpired(json['deletedAt'], cutoff)) {
        purgeNotebookIds.add(entry.key);
        continue;
      }
      await _gcSectionsUnder(entry.key, cutoff);
    }
    for (final id in purgeNotebookIds) {
      data.remove(id);
      indexChanged = true;
      final dir = Directory('${appDir.path}/notebooks/$id');
      if (await dir.exists()) await dir.delete(recursive: true);
    }
    if (indexChanged) await _writeAtomic(notebooksFile, jsonEncode(data));
  }

  bool _tombstoneExpired(dynamic deletedAtField, DateTime cutoff) {
    if (deletedAtField is! num) return false;
    return DateTime.fromMillisecondsSinceEpoch(deletedAtField.toInt())
        .isBefore(cutoff);
  }

  Future<void> _gcSectionsUnder(String notebookId, DateTime cutoff) async {
    final dir = Directory('${appDir.path}/notebooks/$notebookId/sections');
    if (!await dir.exists()) return;
    await for (final entity in dir.list(followLinks: false)) {
      if (entity is! Directory) continue;
      final sectionId = _basename(entity.path);
      final file = File('${entity.path}/section.json');
      if (!await file.exists()) continue;
      Map<String, dynamic> json;
      try {
        json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      } catch (_) {
        continue;
      }
      if (_tombstoneExpired(json['deletedAt'], cutoff)) {
        await entity.delete(recursive: true);
        continue;
      }
      await _gcCanvasesUnder(notebookId, sectionId, cutoff);
    }
  }

  Future<void> _gcCanvasesUnder(
    String notebookId,
    String sectionId,
    DateTime cutoff,
  ) async {
    final dir = Directory(
      '${sectionDir(notebookId, sectionId).path}/canvases',
    );
    if (!await dir.exists()) return;
    await for (final entity in dir.list(followLinks: false)) {
      if (entity is! Directory) continue;
      final file = File('${entity.path}/canvas.json');
      if (!await file.exists()) continue;
      Map<String, dynamic> json;
      try {
        json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      } catch (_) {
        continue;
      }
      if (_tombstoneExpired(json['deletedAt'], cutoff)) {
        await entity.delete(recursive: true);
        continue;
      }
      await _gcPagesUnder(entity.path, cutoff);
    }
  }

  Future<void> _gcPagesUnder(String canvasDirPath, DateTime cutoff) async {
    final dir = Directory('$canvasDirPath/pages');
    if (!await dir.exists()) return;
    await for (final entity in dir.list(followLinks: false)) {
      if (entity is! File || !entity.path.endsWith('.json')) continue;
      Map<String, dynamic> json;
      try {
        json = jsonDecode(await entity.readAsString()) as Map<String, dynamic>;
      } catch (_) {
        continue;
      }
      if (_tombstoneExpired(json['deletedAt'], cutoff)) {
        await entity.delete();
        continue;
      }
      _compactTombstoneList(json, 'erased', cutoff);
      _compactTombstoneList(json, 'deletedObjects', cutoff);
      if (json['_gcCompacted'] == true) {
        json.remove('_gcCompacted');
        // Atomic like every other write here, but deliberately bypasses
        // SyncService.onLocalFileSaved — this is a local-only trim, not an
        // edit that needs pushing (see class doc above).
        final tmp = File('${entity.path}.tmp');
        await tmp.writeAsString(jsonEncode(json), flush: true);
        await entity.delete();
        await tmp.rename(entity.path);
      }
    }
  }

  void _compactTombstoneList(
    Map<String, dynamic> pageJson,
    String key,
    DateTime cutoff,
  ) {
    final list = List<Map<String, dynamic>>.from(pageJson[key] ?? []);
    final kept = list.where((e) => !_tombstoneExpired(e['erasedAt'], cutoff));
    if (kept.length != list.length) {
      pageJson[key] = kept.toList();
      pageJson['_gcCompacted'] = true;
    }
  }
}

// ── Recycle bin items ─────────────────────────────────────────────────────

enum BinItemType { notebook, section, canvas }

/// One soft-deleted item shown in the recycle bin.
class BinItem {
  final BinItemType type;
  final String name;
  final DateTime deletedAt;
  final String notebookId;
  final String? sectionId;
  final String? canvasId;

  /// False when the containing notebook/section is itself deleted — restoring
  /// this item alone would put it nowhere visible, so restore the parent
  /// first.
  final bool parentAlive;
  final String parentName;

  const BinItem({
    required this.type,
    required this.name,
    required this.deletedAt,
    required this.notebookId,
    this.sectionId,
    this.canvasId,
    required this.parentAlive,
    required this.parentName,
  });
}
