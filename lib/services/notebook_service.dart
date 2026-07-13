import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';
import '../models/canvas.dart';
import '../models/canvas_page.dart';
import '../models/notebook.dart';
import '../models/section.dart';
import '../models/tree.dart';
import 'pdf_exporter.dart';
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
    // App-managed data store (JSON structure files + content-addressed assets).
    // Uses the OS application-support dir — NOT Documents — so desktop
    // (Windows/Linux) doesn't clutter the user's Documents folder. Resolves to:
    //   Windows: %APPDATA%\Roaming\io.github.ravinduRepo\omininote
    //   macOS:   ~/Library/Containers/<bundle>/Data/Library/Application Support/<bundle>
    //   Linux:   ~/.local/share/io.github.ravinduRepo.omininote
    //   Android: /data/user/0/io.github.ravinduRepo.omininote/files (private internal)
    appDir = await getApplicationSupportDirectory();
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

  /// Creates a notebook bound to [syncTarget] (an account id, or null for
  /// "unassigned / local"). Phase 2: the account is chosen explicitly at
  /// creation — there is no implicit default.
  Future<Notebook> createNotebook(String name, {String? syncTarget}) async {
    final notebook = Notebook(
      id: newId(),
      deviceId: SettingsService().deviceId,
      name: name,
      createdAt: DateTime.now(),
      syncTarget: syncTarget,
    );
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

  /// Binds a notebook to a Google account for sync (Phase 2). [accountId] is the
  /// account's `sub`; `null` means "the default account". Synced (bumps rev via
  /// [saveNotebook]) so both devices agree on where the notebook lives.
  Future<void> setNotebookSyncTarget(String notebookId, String? accountId) async {
    final nb = await getNotebook(notebookId);
    if (nb == null) return;
    nb.syncTarget = accountId;
    await saveNotebook(nb);
  }

  /// **Move** a notebook to a *different* account by re-keying it to a fresh id.
  /// This is the load-bearing fix for cross-account collisions: the same
  /// notebook id must never live on two accounts' Drives, or edits/deletes bleed
  /// across accounts and the binding flip-flops. So a move:
  ///   1. copies the whole file subtree `notebooks/<old>/` → `notebooks/<new>/`,
  ///   2. rewrites each section's `notebookId` to the new id (fresh rev),
  ///   3. adds a new index entry (new id, `syncTarget = destAccountId`),
  ///   4. **tombstones the old entry** (keeping its old `syncTarget`) so the
  ///      source account propagates a delete and other devices drop the old id.
  /// Returns the new notebook id, or null if the notebook is gone.
  ///
  /// The caller MUST have fully synced the notebook down from its source account
  /// first (so the copy is the complete cloud+local union — no data loss).
  Future<String?> rekeyNotebookForMove(
      String oldId, String destAccountId) async {
    final data = await _readIndex();
    if (data[oldId] == null) return null;

    final newNotebookId =
        await _deepReidNotebookCopy(data, oldId, syncTarget: destAccountId);

    // Tombstone the old id (its syncTarget stays the *source* account, so the
    // source account's notebooks.json carries the delete to other devices).
    final oldNb = Notebook.fromJson(data[oldId] as Map<String, dynamic>);
    oldNb.deletedAt = DateTime.now();
    oldNb.bumpRev(SettingsService().deviceId);
    data[oldId] = oldNb.toJson();

    await writeAtomicPublic(notebooksFile, jsonEncode(data));
    return newNotebookId;
  }

  /// Deep-clones the notebook [srcId] (which must be on disk and present in the
  /// index [data]) into a fresh copy with **new notebook + section + canvas
  /// ids**, bound to [syncTarget], optionally renamed to [name]. Adds the new
  /// entry to [data] (the caller persists) and leaves the source untouched.
  /// Returns the new notebook id.
  ///
  /// New ids at every level are load-bearing: the open-canvas live-merge
  /// (`SyncService._notifyOpenCanvas`) routes pulled pages to a listener keyed
  /// by canvas id, so two notebooks sharing a canvas id would bridge edits
  /// across accounts on a device signed into both. (Page ids can stay — page
  /// files live under the now-unique canvas paths.) Shared by move + import.
  Future<String> _deepReidNotebookCopy(
    Map<String, dynamic> data,
    String srcId, {
    required String? syncTarget,
    String? name,
  }) async {
    final srcNb = Notebook.fromJson(data[srcId] as Map<String, dynamic>);
    final newNotebookId = newId();
    final sectionIdMap = <String, String>{};
    for (final oldSecId in srcNb.allSectionIds) {
      final sec = await getSection(srcId, oldSecId);
      if (sec == null) continue;
      final newSecId = newId();
      final canvasIdMap = <String, String>{};
      for (final oldCanvasId in sec.allCanvasIds) {
        canvasIdMap[oldCanvasId] = await _duplicateCanvasDir(
            srcId, oldSecId, oldCanvasId, newNotebookId, newSecId);
      }
      await _writeAtomic(
        _sectionFile(newNotebookId, newSecId),
        jsonEncode(
          Section(
            id: newSecId,
            deviceId: SettingsService().deviceId,
            notebookId: newNotebookId,
            name: sec.name,
            createdAt: sec.createdAt,
            color: sec.color,
            nodes: sec.nodes.map((n) => _remapClone(n, canvasIdMap)).toList(),
          ).toJson(),
        ),
      );
      sectionIdMap[oldSecId] = newSecId;
    }
    final newNb = Notebook(
      id: newNotebookId,
      deviceId: SettingsService().deviceId,
      name: name ?? srcNb.name,
      createdAt: srcNb.createdAt,
      color: srcNb.color,
      syncTarget: syncTarget,
      nodes: srcNb.nodes.map((n) => _remapClone(n, sectionIdMap)).toList(),
    );
    data[newNotebookId] = newNb.toJson();
    return newNotebookId;
  }

  /// Installs a just-unzipped **staging** notebook (its files already written to
  /// `notebooks/<stagingId>/`) as a brand-new notebook with fresh ids bound to
  /// [syncTarget], then removes the staging copy. [indexJson] is the bundle's
  /// original index entry — its section tree references the staged section ids.
  /// Used by notebook **import** (send-a-copy). Returns the new notebook.
  Future<Notebook?> installImportedNotebook(
    String stagingId,
    Map<String, dynamic> indexJson, {
    String? syncTarget,
  }) async {
    final data = await _readIndex();
    // A staging index entry so the deep re-id can walk the section tree.
    final staged = Notebook.fromJson(indexJson);
    data[stagingId] = Notebook(
      id: stagingId,
      deviceId: SettingsService().deviceId,
      name: staged.name,
      createdAt: staged.createdAt,
      color: staged.color,
      nodes: staged.nodes,
    ).toJson();

    final newNotebookId =
        await _deepReidNotebookCopy(data, stagingId, syncTarget: syncTarget);

    data.remove(stagingId);
    await writeAtomicPublic(notebooksFile, jsonEncode(data));
    try {
      final dir = Directory('${appDir.path}/notebooks/$stagingId');
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (_) {}
    return getNotebook(newNotebookId);
  }

  /// Every synced file on disk under one notebook, as forward-slash relative
  /// paths — used to mark a re-keyed notebook's whole subtree for upload.
  Future<List<String>> listSyncedRelPathsForNotebook(String notebookId) async {
    final out = <String>[];
    final dir = Directory('${appDir.path}/notebooks/$notebookId');
    if (await dir.exists()) {
      await for (final e in dir.list(recursive: true, followLinks: false)) {
        if (e is! File) continue;
        final rel = relPathOf(e.path);
        if (rel != null) out.add(rel);
      }
    }
    return out;
  }

  /// Marks a notebook local-only (or not) on **this device only**. Device-local
  /// (settings.json), never synced — see [SettingsService.localOnlyNotebooks].
  Future<void> setNotebookLocalOnly(String notebookId, bool local) =>
      SettingsService().setNotebookLocalOnly(notebookId, local);

  /// Removes local copies of notebooks that sync to [accountId] (keeping
  /// local-only ones and other accounts' notebooks), **without tombstoning** —
  /// so removing that account is clean and re-adding it later re-downloads them.
  /// Used when removing one account of several. Returns how many were removed.
  Future<int> purgeLocalNotebooksForAccount(
      String accountId, String? defaultAccountId) async {
    final localOnly = SettingsService().localOnlyNotebooks;
    final data = await _readIndex();
    final kept = <String, dynamic>{};
    var removed = 0;
    for (final entry in data.entries) {
      final json = entry.value as Map<String, dynamic>;
      final target = (json['syncTarget'] as String?) ?? defaultAccountId;
      if (target == accountId && !localOnly.contains(entry.key)) {
        final dir = Directory('${appDir.path}/notebooks/${entry.key}');
        if (await dir.exists()) await dir.delete(recursive: true);
        removed++;
        continue; // drop from the local index (non-tombstone)
      }
      kept[entry.key] = entry.value;
    }
    await writeAtomicPublic(notebooksFile, jsonEncode(kept));
    return removed;
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

  /// Soft-deletes a section-tree super-section to the recycle bin: the whole
  /// [FolderNode] subtree moves to `deletedFolders` (restorable/purgeable), and
  /// its sections' files stay on disk (hidden, since the tree no longer
  /// references them) until restore or purge. No hard delete — durable + sync.
  Future<void> deleteSectionFolder(Notebook notebook, String folderId) async {
    final folder = TreeOps.findFolder(notebook.nodes, folderId);
    if (folder == null) return;
    TreeOps.removeFolder(notebook.nodes, folderId);
    notebook.deletedFolders
        .add(DeletedFolder(node: folder, deletedAt: DateTime.now()));
    await saveNotebook(notebook);
  }

  /// Soft-deletes a canvas-tree super-section (mirrors [deleteSectionFolder]).
  Future<void> deleteCanvasFolder(Section section, String folderId) async {
    final folder = TreeOps.findFolder(section.nodes, folderId);
    if (folder == null) return;
    TreeOps.removeFolder(section.nodes, folderId);
    section.deletedFolders
        .add(DeletedFolder(node: folder, deletedAt: DateTime.now()));
    await saveSection(section);
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

  /// Reads a single page file directly, tombstone and all (unlike [loadPages],
  /// which filters deleted pages out). Returns null if the file is absent or
  /// unparseable. Used by the recycle-bin restore path.
  Future<CanvasPage?> loadPageFile(Canvas canvas, String pageId) async {
    final json = await _readJsonFile(_pageFile(canvas, pageId));
    if (json == null) return null;
    try {
      return CanvasPage.fromJson(json);
    } catch (_) {
      return null;
    }
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

  // ── Multi-level PDF export collection ──────────────────────────────────
  //
  // Walk the tree in display order, loading every canvas + its pages, and
  // build a flat list of [PdfExportItem]s whose `outline` path mirrors the
  // hierarchy (notebook › super-section › section › super-section › canvas) so
  // the exporter can emit a nested PDF outline (topic/sub-topic bookmarks).

  Future<List<PdfExportItem>> collectNotebookExportItems(Notebook nb) async {
    final items = <PdfExportItem>[];
    await _walkNotebookForExport(nb, nb.nodes, [nb.name], items);
    return items;
  }

  Future<List<PdfExportItem>> collectSectionExportItems(
    Section section, {
    List<String> prefix = const [],
  }) async {
    final items = <PdfExportItem>[];
    await _walkSectionForExport(
      section,
      section.nodes,
      [...prefix, section.name],
      items,
    );
    return items;
  }

  Future<void> _walkNotebookForExport(
    Notebook nb,
    List<TreeNode> nodes,
    List<String> path,
    List<PdfExportItem> out,
  ) async {
    for (final node in nodes) {
      if (node is FolderNode) {
        await _walkNotebookForExport(nb, node.children, [...path, node.name], out);
      } else if (node is LeafNode) {
        final section = await getSection(nb.id, node.refId);
        if (section == null) continue;
        await _walkSectionForExport(
          section,
          section.nodes,
          [...path, section.name],
          out,
        );
      }
    }
  }

  Future<void> _walkSectionForExport(
    Section section,
    List<TreeNode> nodes,
    List<String> path,
    List<PdfExportItem> out,
  ) async {
    for (final node in nodes) {
      if (node is FolderNode) {
        await _walkSectionForExport(
          section,
          node.children,
          [...path, node.name],
          out,
        );
      } else if (node is LeafNode) {
        final canvas = await getCanvas(
          section.notebookId,
          section.id,
          node.refId,
        );
        if (canvas == null) continue;
        final pages = await loadPages(canvas);
        out.add(PdfExportItem(
          outline: [...path, canvas.name],
          canvas: canvas,
          pages: pages,
          assetBytes: (assetId) async =>
              Uint8List.fromList(await assetFile(canvas, assetId).readAsBytes()),
        ));
      }
    }
  }

  /// Copies every asset referenced by [page] from the [src] canvas's asset dir
  /// into the [dst] canvas's asset dir (assets are content-addressed, so the
  /// id/filename is unchanged and an already-present asset is skipped). Used
  /// when pasting a page copied from another canvas.
  Future<void> copyPageAssets(
    Canvas src,
    Canvas dst,
    CanvasPage page,
  ) async {
    if (src.id == dst.id) return; // same canvas — assets already present
    for (final assetId in page.referencedAssetIds()) {
      final srcFile = assetFile(src, assetId);
      final dstFile = assetFile(dst, assetId);
      if (await dstFile.exists() || !await srcFile.exists()) continue;
      final bytes = await srcFile.readAsBytes();
      await writeAtomicBytesPublic(dstFile, bytes);
      SyncService().onLocalAssetSaved(dstFile.path, bytes);
    }
  }

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
  /// Notebook ids this device keeps local-only (device-local decision).
  Set<String> localOnlyNotebookIds() => SettingsService().localOnlyNotebooks;

  /// The `notebooks.json` content to *upload* to Drive: the local index minus
  /// this device's local-only notebooks (they must never leave the device).
  Future<String> syncedIndexJson() async {
    final data = await _readIndex();
    final localOnly = SettingsService().localOnlyNotebooks;
    final filtered = <String, dynamic>{};
    for (final e in data.entries) {
      if (localOnly.contains(e.key)) continue;
      filtered[e.key] = e.value;
    }
    return jsonEncode(filtered);
  }

  /// A notebook's effective sync target (Phase 2): its explicit `syncTarget`, or
  /// [defaultAccountId] when null. Local-only isn't considered here — that's a
  /// separate per-device override applied by the sync layer.
  static String? effectiveSyncTarget(Notebook nb, String? defaultAccountId) =>
      nb.syncTarget ?? defaultAccountId;

  /// The per-account `notebooks.json` to upload to [accountId]'s Drive: only
  /// notebooks whose **effective** target is [accountId] (explicit `syncTarget`,
  /// or null ⇒ [defaultAccountId]), minus this device's local-only ones. This
  /// generalizes [syncedIndexJson] — each account's Drive sees only its own
  /// notebooks, the same way local-only ones are withheld from every account.
  Future<String> syncedIndexJsonFor(
    String accountId, {
    String? defaultAccountId,
  }) async {
    final data = await _readIndex();
    final localOnly = SettingsService().localOnlyNotebooks;
    final filtered = <String, dynamic>{};
    for (final e in data.entries) {
      if (localOnly.contains(e.key)) continue;
      final json = e.value as Map<String, dynamic>;
      final target = (json['syncTarget'] as String?) ?? defaultAccountId;
      if (target == accountId) filtered[e.key] = e.value;
    }
    return jsonEncode(filtered);
  }

  /// The effective sync-target account id of the notebook owning [notebookId]
  /// (explicit `syncTarget`, or [defaultAccountId] when null / notebook gone).
  /// Lets the sync layer route a file to its notebook's account.
  Future<String?> syncTargetOfNotebook(
    String notebookId, {
    String? defaultAccountId,
  }) async {
    final data = await _readIndex();
    final json = data[notebookId] as Map<String, dynamic>?;
    if (json == null) return defaultAccountId;
    return (json['syncTarget'] as String?) ?? defaultAccountId;
  }

  /// The notebook id inside a synced relPath (`notebooks/<id>/...`), or null for
  /// the top-level `notebooks.json` and non-notebook paths.
  String? notebookIdOfRelPath(String rel) {
    const prefix = 'notebooks/';
    if (!rel.startsWith(prefix)) return null;
    final rest = rel.substring(prefix.length);
    final slash = rest.indexOf('/');
    return slash == -1 ? null : rest.substring(0, slash);
  }

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
      if (json['purgedAt'] != null) {
        deletedNotebookIds.add(entry.key);
        continue; // permanently purged — only the marker remains, hide it
      }
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
        continue; // a deleted notebook's folders are subsumed by it
      }
      // Alive notebook: surface its deleted section super-sections.
      for (final f
          in List<Map<String, dynamic>>.from(json['deletedFolders'] ?? [])) {
        if (f['purgedAt'] != null) continue;
        final node = f['node'] as Map<String, dynamic>;
        out.add(BinItem(
          type: BinItemType.folder,
          name: node['name'] as String? ?? 'Super-section',
          deletedAt: DateTime.fromMillisecondsSinceEpoch(f['deletedAt']),
          notebookId: entry.key,
          folderId: node['id'] as String?,
          parentAlive: true,
          parentName: notebookNames[entry.key]!,
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
        if (secDeleted is num && secJson?['purgedAt'] == null) {
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
        } else if (secDeleted is! num && secJson?['purgedAt'] == null) {
          // Alive section: surface its deleted canvas super-sections.
          for (final f in List<Map<String, dynamic>>.from(
              secJson?['deletedFolders'] ?? [])) {
            if (f['purgedAt'] != null) continue;
            final node = f['node'] as Map<String, dynamic>;
            out.add(BinItem(
              type: BinItemType.folder,
              name: node['name'] as String? ?? 'Super-section',
              deletedAt: DateTime.fromMillisecondsSinceEpoch(f['deletedAt']),
              notebookId: nbId,
              sectionId: secId,
              folderId: node['id'] as String?,
              parentAlive: nbAlive,
              parentName: secName,
            ));
          }
        }
        final cvRoot = Directory('${secDir.path}/canvases');
        if (!await cvRoot.exists()) continue;
        await for (final cvDir in cvRoot.list(followLinks: false)) {
          if (cvDir is! Directory) continue;
          final cvId = _basename(cvDir.path);
          final cvJson =
              await _readJsonFile(File('${cvDir.path}/canvas.json'));
          if (cvJson?['purgedAt'] != null) continue; // gone — hide marker
          final cvDeleted = cvJson?['deletedAt'];
          final cvName = cvJson?['name'] as String? ?? 'Canvas';
          if (cvDeleted is num) {
            // Canvas itself is deleted — its pages are subsumed by this entry
            // (restoring the canvas brings them all back), so don't list them.
            out.add(BinItem(
              type: BinItemType.canvas,
              name: cvName,
              deletedAt: DateTime.fromMillisecondsSinceEpoch(cvDeleted.toInt()),
              notebookId: nbId,
              sectionId: secId,
              canvasId: cvId,
              parentAlive: nbAlive && secDeleted is! num,
              parentName: secName,
            ));
            continue;
          }
          // Alive canvas: surface individually-deleted pages.
          final cvAlive = nbAlive && secDeleted is! num;
          final pagesDir = Directory('${cvDir.path}/pages');
          if (!await pagesDir.exists()) continue;
          await for (final pf in pagesDir.list(followLinks: false)) {
            if (pf is! File || !pf.path.endsWith('.json')) continue;
            final pj = await _readJsonFile(pf);
            final pDeleted = pj?['deletedAt'];
            if (pDeleted is! num || pj?['purgedAt'] != null) continue;
            out.add(BinItem(
              type: BinItemType.page,
              name: 'Page',
              deletedAt: DateTime.fromMillisecondsSinceEpoch(pDeleted.toInt()),
              notebookId: nbId,
              sectionId: secId,
              canvasId: cvId,
              pageId: _basename(pf.path).replaceAll('.json', ''),
              parentAlive: cvAlive,
              parentName: cvName,
            ));
          }
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
        if (json == null || json['purgedAt'] != null) return;
        final nb = Notebook.fromJson(json);
        nb.deletedAt = null;
        nb.bumpRev(SettingsService().deviceId);
        data[item.notebookId] = nb.toJson();
        await _writeAtomic(notebooksFile, jsonEncode(data));

      case BinItemType.section:
        final json = await _readJsonFile(
            _sectionFile(item.notebookId, item.sectionId!));
        if (json == null || json['purgedAt'] != null) return;
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
        if (json == null || json['purgedAt'] != null) return;
        final c = Canvas.fromJson(json);
        c.deletedAt = null;
        await saveCanvas(c); // bumps rev
        final sec = await getSection(item.notebookId, item.sectionId!);
        if (sec != null && !sec.allCanvasIds.contains(c.id)) {
          sec.nodes.add(LeafNode(c.id));
          await saveSection(sec);
        }

      case BinItemType.page:
        await restorePage(
            item.notebookId, item.sectionId!, item.canvasId!, item.pageId!);

      case BinItemType.folder:
        await restoreFolder(
            item.notebookId, item.sectionId, item.folderId!);
    }
  }

  /// Restores a soft-deleted super-section: moves its [FolderNode] subtree out
  /// of `deletedFolders` and re-appends it to the tree (its contained items'
  /// files were never touched, so they reappear intact).
  Future<void> restoreFolder(
      String notebookId, String? sectionId, String folderId) async {
    if (sectionId == null) {
      final nb = await getNotebook(notebookId);
      if (nb == null) return;
      final idx = nb.deletedFolders
          .indexWhere((f) => f.node.id == folderId && f.purgedAt == null);
      if (idx < 0) return;
      nb.nodes.add(nb.deletedFolders.removeAt(idx).node);
      await saveNotebook(nb);
    } else {
      final sec = await getSection(notebookId, sectionId);
      if (sec == null) return;
      final idx = sec.deletedFolders
          .indexWhere((f) => f.node.id == folderId && f.purgedAt == null);
      if (idx < 0) return;
      sec.nodes.add(sec.deletedFolders.removeAt(idx).node);
      await saveSection(sec);
    }
  }

  /// Restores a soft-deleted page: clears its tombstone (bumped rev, so it
  /// beats the deletion in every device's LWW merge) and re-links it as a
  /// fresh row appended at the bottom of the canvas — the page's original
  /// position is unrecoverable once the canvas has been restructured, so we
  /// append (mirroring how sections/canvases restore to the end of the tree,
  /// not their original slot).
  ///
  /// If the canvas is currently **open**, the restore is routed through its
  /// live [CanvasController] instead — writing canvas.json from disk here would
  /// be clobbered by the controller's own autosave (its in-memory rows may be
  /// ahead of disk), and the user wouldn't see the page appear.
  Future<void> restorePage(
      String notebookId, String sectionId, String canvasId, String pageId) async {
    if (await SyncService().restorePageInOpenCanvas(canvasId, pageId)) return;
    final canvas = await getCanvas(notebookId, sectionId, canvasId);
    if (canvas == null) return; // canvas deleted/purged — nowhere to restore to
    final page = await loadPageFile(canvas, pageId);
    if (page == null || page.purgedAt != null || page.deletedAt == null) return;
    page.deletedAt = null;
    await savePage(canvas, page); // bumps rev + journals the upload
    final referenced = {for (final r in canvas.rows) ...r.pageIds};
    if (!referenced.contains(pageId)) {
      canvas.rows.add(PageRow(id: newId(), pageIds: [pageId]));
      await saveCanvas(canvas); // bumps rev + journals the structural upload
    }
  }

  // ── Purge (stage 2 — permanent, all devices + Drive) ────────────────────
  //
  // A purge upgrades an existing tombstone to a *terminal* `purgedAt` marker:
  // the heavy content subtree is hard-deleted from local disk and Drive, and
  // only the tiny marker doc survives (the notebooks.json entry / a stripped
  // section.json / canvas.json). The marker is grow-only in merges — once any
  // device purges, a racing restore or a stale live copy loses — and it is
  // never GC'd, which is what makes the purge stick forever. Other devices
  // apply the purge when they pull the marker (SyncService calls the
  // `apply*PurgeLocally` methods below).

  /// Local cache of purged path-prefixes (`nbId`, `nbId/secId`,
  /// `nbId/secId/cvId`) used by SyncService's push/pull filters. Device-local
  /// (`purged_index.json`, not synced — [isSyncedRelPath] excludes it);
  /// repopulated during every GC walk.
  Set<String>? _purgedPaths;
  File get _purgedIndexFile => File('${appDir.path}/purged_index.json');

  Future<Set<String>> purgedPaths() async {
    if (_purgedPaths != null) return _purgedPaths!;
    final json = await _readJsonFile(_purgedIndexFile);
    _purgedPaths = {...List<String>.from(json?['purged'] ?? const [])};
    return _purgedPaths!;
  }

  Future<void> _addPurgedPath(String path) async {
    final set = await purgedPaths();
    if (!set.add(path)) return;
    await _writeAtomic(
        _purgedIndexFile, jsonEncode({'purged': set.toList()..sort()}));
  }

  /// True when [rel] is *content under a purged item* — the sync layer must
  /// neither upload nor download it. The surviving marker files themselves
  /// (`section.json` / `canvas.json` of the purged item) return false: they
  /// are how the purge propagates. Pure; unit-tested.
  static bool isPurgedContentPath(String rel, Set<String> purged) {
    if (purged.isEmpty || !rel.startsWith('notebooks/')) return false;
    final parts = rel.split('/');
    if (parts.length < 2) return false;
    final nb = parts[1];
    if (purged.contains(nb)) return true; // notebook marker lives outside
    if (parts.length >= 4 && parts[2] == 'sections') {
      final sec = '$nb/${parts[3]}';
      if (purged.contains(sec)) {
        return !(parts.length == 5 && parts[4] == 'section.json');
      }
      if (parts.length >= 6 && parts[4] == 'canvases') {
        final cv = '$sec/${parts[5]}';
        if (purged.contains(cv)) {
          return !(parts.length == 7 && parts[6] == 'canvas.json');
        }
      }
    }
    return false;
  }

  /// Permanently deletes a binned item everywhere: writes the terminal marker
  /// (which syncs to every device), wipes local content now, and queues the
  /// Drive-side folder deletion. Not undoable.
  Future<void> purgeBinItem(BinItem item) async {
    switch (item.type) {
      case BinItemType.notebook:
        await purgeNotebook(item.notebookId);
      case BinItemType.section:
        await purgeSection(item.notebookId, item.sectionId!);
      case BinItemType.canvas:
        await purgeCanvas(item.notebookId, item.sectionId!, item.canvasId!);
      case BinItemType.page:
        await purgePage(item.notebookId, item.sectionId!, item.canvasId!,
            item.pageId!);
      case BinItemType.folder:
        await purgeFolder(item.notebookId, item.sectionId, item.folderId!);
    }
  }

  /// Permanently purges a soft-deleted super-section: drops its `deletedFolders`
  /// record and purges every leaf inside it (their files are deleted from local
  /// disk + Drive). Structural LWW carries the removal to other devices.
  Future<void> purgeFolder(
      String notebookId, String? sectionId, String folderId) async {
    if (sectionId == null) {
      final nb = await getNotebook(notebookId);
      if (nb == null) return;
      final idx = nb.deletedFolders.indexWhere((f) => f.node.id == folderId);
      if (idx < 0) return;
      final leafIds = nb.deletedFolders[idx].node.collectLeafIds();
      nb.deletedFolders.removeAt(idx);
      await saveNotebook(nb);
      for (final secId in leafIds) {
        await purgeSection(notebookId, secId);
      }
    } else {
      final sec = await getSection(notebookId, sectionId);
      if (sec == null) return;
      final idx = sec.deletedFolders.indexWhere((f) => f.node.id == folderId);
      if (idx < 0) return;
      final leafIds = sec.deletedFolders[idx].node.collectLeafIds();
      sec.deletedFolders.removeAt(idx);
      await saveSection(sec);
      for (final cvId in leafIds) {
        await purgeCanvas(notebookId, sectionId, cvId);
      }
    }
  }

  /// Permanently purges a single page. Unlike the container levels a page has
  /// no subtree/folder — the page file *is* the marker, so we strip its content
  /// in place, stamp `purgedAt`, and re-save. The tiny stub re-uploads through
  /// the normal page-merge path (no Drive folder-delete needed) and survives
  /// forever so a stale device can't resurrect the page; the purge propagates
  /// because [MergeEngine.mergePage] treats `purgedAt` as terminal.
  Future<void> purgePage(
      String notebookId, String sectionId, String canvasId, String pageId) async {
    final file = File(
        '${canvasDir(notebookId, sectionId, canvasId).path}/pages/$pageId.json');
    // Local-only notebooks have no Drive copy and no other-device presence —
    // a plain local file delete is the whole purge (no resurrection risk).
    if (localOnlyNotebookIds().contains(notebookId)) {
      if (await file.exists()) await file.delete();
      return;
    }
    final json = await _readJsonFile(file);
    if (json == null) return;
    final page = CanvasPage.fromJson(json);
    page.deletedAt ??= DateTime.now();
    page.purgedAt ??= DateTime.now();
    page.strokes.clear();
    page.erased.clear();
    page.objects.clear();
    page.deletedObjects.clear();
    page.source = null; // content gone; keep the marker tiny
    page.bumpRev(SettingsService().deviceId);
    await _writeAtomic(file, jsonEncode(page.toJson())); // journals the upload
  }

  Future<void> purgeNotebook(String notebookId) async {
    final data = await _readIndex();
    // Local-only notebooks have no Drive copy and no other-device presence —
    // a plain local removal is the whole purge (today's pre-marker behavior).
    if (localOnlyNotebookIds().contains(notebookId)) {
      data.remove(notebookId);
      await _writeAtomic(notebooksFile, jsonEncode(data));
      final dir = Directory('${appDir.path}/notebooks/$notebookId');
      if (await dir.exists()) await dir.delete(recursive: true);
      return;
    }
    final json = data[notebookId] as Map<String, dynamic>?;
    if (json != null) {
      final nb = Notebook.fromJson(json);
      nb.deletedAt ??= DateTime.now();
      nb.purgedAt ??= DateTime.now();
      nb.nodes.clear(); // content is gone; keep the marker tiny
      nb.bumpRev(SettingsService().deviceId);
      data[notebookId] = nb.toJson();
      await _writeAtomic(notebooksFile, jsonEncode(data)); // journals upload
    }
    await applyNotebookPurgeLocally(notebookId);
  }

  Future<void> purgeSection(String notebookId, String sectionId) async {
    if (localOnlyNotebookIds().contains(notebookId)) {
      final dir = sectionDir(notebookId, sectionId);
      if (await dir.exists()) await dir.delete(recursive: true);
      return;
    }
    final json = await _readJsonFile(_sectionFile(notebookId, sectionId));
    if (json != null) {
      final sec = Section.fromJson(json);
      sec.deletedAt ??= DateTime.now();
      sec.purgedAt ??= DateTime.now();
      sec.nodes.clear();
      await saveSection(sec); // bumps rev + journals the marker upload
    }
    await applySectionPurgeLocally(notebookId, sectionId);
  }

  Future<void> purgeCanvas(
      String notebookId, String sectionId, String canvasId) async {
    if (localOnlyNotebookIds().contains(notebookId)) {
      final dir = canvasDir(notebookId, sectionId, canvasId);
      if (await dir.exists()) await dir.delete(recursive: true);
      return;
    }
    final json = await _readJsonFile(
        File('${canvasDir(notebookId, sectionId, canvasId).path}/canvas.json'));
    if (json != null) {
      final c = Canvas.fromJson(json);
      c.deletedAt ??= DateTime.now();
      c.purgedAt ??= DateTime.now();
      c.rows.clear();
      c.attachments.clear();
      c.bookmarks.clear();
      await saveCanvas(c);
    }
    await applyCanvasPurgeLocally(notebookId, sectionId, canvasId);
  }

  /// Local half of a purge — also called by SyncService when a pulled marker
  /// carries `purgedAt` (that's how a purge on device A lands on device B).
  /// Wipes the content subtree, records the purged prefix for the sync
  /// filters, and hands the (idempotent) Drive folder deletions to sync.
  Future<void> applyNotebookPurgeLocally(String notebookId) async {
    final dir = Directory('${appDir.path}/notebooks/$notebookId');
    if (await dir.exists()) await dir.delete(recursive: true);
    await _addPurgedPath(notebookId);
    SyncService()
        .onItemPurged(notebookId, ['notebooks/$notebookId']);
  }

  Future<void> applySectionPurgeLocally(
      String notebookId, String sectionId) async {
    final dir =
        Directory('${sectionDir(notebookId, sectionId).path}/canvases');
    if (await dir.exists()) await dir.delete(recursive: true);
    await _addPurgedPath('$notebookId/$sectionId');
    SyncService().onItemPurged(
        notebookId, ['notebooks/$notebookId/sections/$sectionId/canvases']);
  }

  Future<void> applyCanvasPurgeLocally(
      String notebookId, String sectionId, String canvasId) async {
    final base = canvasDir(notebookId, sectionId, canvasId).path;
    for (final sub in ['pages', 'assets']) {
      final dir = Directory('$base/$sub');
      if (await dir.exists()) await dir.delete(recursive: true);
    }
    await _addPurgedPath('$notebookId/$sectionId/$canvasId');
    final relBase =
        'notebooks/$notebookId/sections/$sectionId/canvases/$canvasId';
    SyncService()
        .onItemPurged(notebookId, ['$relBase/pages', '$relBase/assets']);
  }

  // ── Garbage collection (purge tombstones older than the bin window) ─────

  /// Bin retention: soft-deleted items stay restorable this long, then the
  /// GC sweep removes them permanently.
  static const Duration _kGcMaxAge = Duration(days: 30);

  /// Purges tombstoned notebooks/sections/canvases whose `deletedAt` is older
  /// than [maxAge] — through the same terminal-marker purge as the bin's
  /// "delete permanently" (content wiped locally *and* Drive-side, tiny
  /// marker kept forever) — deletes expired tombstoned pages, and drops old
  /// erase/delete-object tombstone *entries* from otherwise-live pages.
  ///
  /// Already-purged markers are left untouched (they're what keeps a purge
  /// durable against stale devices), but their purged-path prefixes are
  /// re-recorded so the sync filters' local cache self-heals each launch.
  Future<void> runGarbageCollection({Duration maxAge = _kGcMaxAge}) async {
    final cutoff = DateTime.now().subtract(maxAge);
    final data = await _readIndex();

    for (final entry in data.entries.toList()) {
      final json = entry.value as Map<String, dynamic>;
      if (json['purgedAt'] != null) {
        // Marker stays; make sure local content is gone + cache knows.
        final dir = Directory('${appDir.path}/notebooks/${entry.key}');
        if (await dir.exists()) await dir.delete(recursive: true);
        await _addPurgedPath(entry.key);
        continue;
      }
      if (_tombstoneExpired(json['deletedAt'], cutoff)) {
        await purgeNotebook(entry.key);
        continue;
      }
      // Expired deleted section super-sections in this (alive) notebook.
      for (final f
          in List<Map<String, dynamic>>.from(json['deletedFolders'] ?? [])) {
        if (f['purgedAt'] == null && _tombstoneExpired(f['deletedAt'], cutoff)) {
          await purgeFolder(entry.key, null,
              (f['node'] as Map<String, dynamic>)['id'] as String);
        }
      }
      await _gcSectionsUnder(entry.key, cutoff);
    }
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
      if (json['purgedAt'] != null) {
        final cvDir = Directory('${entity.path}/canvases');
        if (await cvDir.exists()) await cvDir.delete(recursive: true);
        await _addPurgedPath('$notebookId/$sectionId');
        continue; // marker stays
      }
      if (_tombstoneExpired(json['deletedAt'], cutoff)) {
        await purgeSection(notebookId, sectionId);
        continue;
      }
      // Expired deleted canvas super-sections in this (alive) section.
      for (final f
          in List<Map<String, dynamic>>.from(json['deletedFolders'] ?? [])) {
        if (f['purgedAt'] == null && _tombstoneExpired(f['deletedAt'], cutoff)) {
          await purgeFolder(notebookId, sectionId,
              (f['node'] as Map<String, dynamic>)['id'] as String);
        }
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
      final canvasId = _basename(entity.path);
      final file = File('${entity.path}/canvas.json');
      if (!await file.exists()) continue;
      Map<String, dynamic> json;
      try {
        json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      } catch (_) {
        continue;
      }
      if (json['purgedAt'] != null) {
        for (final sub in ['pages', 'assets']) {
          final d = Directory('${entity.path}/$sub');
          if (await d.exists()) await d.delete(recursive: true);
        }
        await _addPurgedPath('$notebookId/$sectionId/$canvasId');
        continue; // marker stays
      }
      if (_tombstoneExpired(json['deletedAt'], cutoff)) {
        await purgeCanvas(notebookId, sectionId, canvasId);
        continue;
      }
      await _gcPagesUnder(notebookId, sectionId, canvasId, cutoff);
    }
  }

  Future<void> _gcPagesUnder(String notebookId, String sectionId,
      String canvasId, DateTime cutoff) async {
    final dir = Directory(
        '${canvasDir(notebookId, sectionId, canvasId).path}/pages');
    if (!await dir.exists()) return;
    await for (final entity in dir.list(followLinks: false)) {
      if (entity is! File || !entity.path.endsWith('.json')) continue;
      Map<String, dynamic> json;
      try {
        json = jsonDecode(await entity.readAsString()) as Map<String, dynamic>;
      } catch (_) {
        continue;
      }
      if (json['purgedAt'] != null) continue; // terminal marker — leave it
      if (_tombstoneExpired(json['deletedAt'], cutoff)) {
        // Route through the terminal purge (strip + `purgedAt` marker,
        // Drive-reclaiming) instead of a bare local delete — a local-only
        // delete left the tombstoned page live on Drive forever and let it
        // re-download on the next full resync.
        final pageId = _basename(entity.path).replaceAll('.json', '');
        await purgePage(notebookId, sectionId, canvasId, pageId);
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

enum BinItemType { notebook, section, canvas, page, folder }

/// One soft-deleted item shown in the recycle bin.
class BinItem {
  final BinItemType type;
  final String name;
  final DateTime deletedAt;
  final String notebookId;
  final String? sectionId;
  final String? canvasId;
  final String? pageId;

  /// Set for a deleted super-section. `sectionId == null` → a section-folder
  /// (in the notebook); non-null → a canvas-folder (in that section).
  final String? folderId;

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
    this.pageId,
    this.folderId,
    required this.parentAlive,
    required this.parentName,
  });
}
