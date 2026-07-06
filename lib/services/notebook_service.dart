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

  Future<Map<String, dynamic>> _readIndex() async =>
      jsonDecode(await notebooksFile.readAsString()) as Map<String, dynamic>;

  Future<List<Notebook>> getNotebooks() async {
    final data = await _readIndex();
    return data.values
        .map((json) => Notebook.fromJson(json as Map<String, dynamic>))
        .toList();
  }

  Future<Notebook?> getNotebook(String notebookId) async {
    final data = await _readIndex();
    final json = data[notebookId] as Map<String, dynamic>?;
    return json == null ? null : Notebook.fromJson(json);
  }

  Future<Notebook> createNotebook(String name) async {
    final notebook = Notebook(id: newId(), name: name, createdAt: DateTime.now());
    final data = await _readIndex();
    data[notebook.id] = notebook.toJson();
    await _writeAtomic(notebooksFile, jsonEncode(data));
    return notebook;
  }

  /// Persists a notebook's full metadata (name, color, section tree). The
  /// in-memory [Notebook] is the source of truth — mutate then call this.
  Future<void> saveNotebook(Notebook notebook) async {
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

  Future<void> deleteNotebook(String notebookId) async {
    final data = await _readIndex();
    data.remove(notebookId);
    await _writeAtomic(notebooksFile, jsonEncode(data));
    final dir = Directory('${appDir.path}/notebooks/$notebookId');
    if (await dir.exists()) await dir.delete(recursive: true);
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
      return Section.fromJson(
        jsonDecode(await file.readAsString()) as Map<String, dynamic>,
      );
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

  Future<void> deleteSection(String notebookId, String sectionId) async {
    final dir = sectionDir(notebookId, sectionId);
    if (await dir.exists()) await dir.delete(recursive: true);
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
    defaultBackground: SettingsService().defaultPageBackground.value,
  );

  Future<void> _writeCanvasWithDefaultPage(Canvas canvas) async {
    final page = CanvasPage(
      id: newId(),
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
      return Canvas.fromJson(
        jsonDecode(await file.readAsString()) as Map<String, dynamic>,
      );
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

  Future<void> deleteCanvas(Section section, String canvasId) async {
    final dir = canvasDir(section.notebookId, section.id, canvasId);
    if (await dir.exists()) await dir.delete(recursive: true);
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
        ).toJson(),
      ),
    );
  }

  // ── Pages (canvas-scoped) ──────────────────────────────────────────────

  Future<Map<String, CanvasPage>> loadPages(Canvas canvas) async {
    final pages = <String, CanvasPage>{};
    for (final row in canvas.rows) {
      for (final pageId in row.pageIds) {
        final file = _pageFile(canvas, pageId);
        if (await file.exists()) {
          try {
            pages[pageId] = CanvasPage.fromJson(
              jsonDecode(await file.readAsString()) as Map<String, dynamic>,
            );
            continue;
          } catch (_) {}
        }
        pages[pageId] = CanvasPage(
          id: pageId,
          width: canvas.defaultPageWidth,
          height: canvas.defaultPageHeight,
          background: canvas.defaultBackground,
        );
      }
    }
    return pages;
  }

  Future<void> savePage(Canvas canvas, CanvasPage page) async {
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
    }
    return assetId;
  }

  File assetFile(Canvas canvas, String assetId) =>
      File('${assetsDir(canvas).path}/$assetId');

  /// IDs unique across the app: millis + a monotonic suffix.
  static int _idSeq = 0;
  String newId() =>
      '${DateTime.now().millisecondsSinceEpoch}${(_idSeq++ % 1000).toString().padLeft(3, '0')}';
}
