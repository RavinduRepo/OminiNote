import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'package:googleapis/drive/v3.dart' as gd;
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'auth_service.dart';

/// Thin wrapper over the Drive v3 REST API.
///
/// All paths are relative to a root folder named "omininote" that we create
/// (or find) at the top level of the user's My Drive. The `drive.file` scope
/// means we only ever see files this app created — so a single paginated
/// `files.list` enumerates the whole tree cheaply.
///
/// A local `drive_index.json` caches, per relative path, the Drive `fileId`
/// and the `headRevisionId` of the version we last saw. The head is used for
/// echo suppression (skip re-downloading our own uploads), and the reverse
/// `fileId → path` map lets the Changes-API poller locate incoming edits.
/// Registry of per-account [DriveService] instances. Phase 2 makes Drive
/// account-scoped: each connected account has its own `omininote/` root, its own
/// `drive_index_<accountId>.json`, its own folder cache, and its own changes
/// token — so several accounts sync independently and in parallel. Instances are
/// cached by account id (the Google `sub`) and created lazily.
class DriveManager {
  DriveManager._();
  static final Map<String, DriveService> _instances = {};

  /// The Drive client for [accountId], creating (but not initializing) it on
  /// first use. Call [DriveService.init] before using it.
  static DriveService forAccount(String accountId) =>
      _instances.putIfAbsent(accountId, () => DriveService(accountId));

  /// Drops a removed account's Drive client (its index file is cleared
  /// separately via [DriveService.resetIndex]).
  static void remove(String accountId) => _instances.remove(accountId);

  static Iterable<DriveService> get all => _instances.values;
}

class DriveService {
  /// The Google account (`sub`) this Drive tree belongs to.
  final String accountId;
  DriveService(this.accountId);

  static const _kRootFolderName = 'omininote';
  static const _kAppMimeFolder = 'application/vnd.google-apps.folder';

  gd.DriveApi? _api;
  String? _rootFolderId;

  // relPath → (fileId, headRevisionId)
  final Map<String, _IndexEntry> _index = {};
  final Map<String, String> _fileIdToPath = {};

  // Folder path ("a/b/c", relative to root) → folder id. Without this, every
  // upload of a not-yet-indexed file re-resolved its whole folder chain with
  // one sequential files.list round trip per segment — the main reason a
  // fresh canvas took ages to push (4+ files × ~6 calls each).
  final Map<String, String> _folderIds = {};

  // Reverse of [_folderIds]: folder id → path. Lets [resolveFileId] stop its
  // parent walk as soon as it reaches a known folder.
  final Map<String, String> _folderPathById = {};

  void _cacheFolder(String path, String id) {
    _folderIds[path] = id;
    _folderPathById[id] = path;
  }
  File? _indexFile;
  bool _initialized = false;

  // ── Init ──────────────────────────────────────────────────────────────────

  Future<void> init() async {
    if (_initialized) {
      _buildClient();
      return;
    }
    _initialized = true;
    await _loadIndex();
    _buildClient();
  }

  void _buildClient() {
    // The client is lazy — it fetches this account's auth headers per request,
    // so a not-yet-connected account just fails individual calls (handled by
    // the sync layer) rather than needing a signed-in gate here.
    _api = gd.DriveApi(_AuthedClient(accountId));
  }

  gd.DriveApi get _drive {
    if (_api == null) throw const DriveException('Not authenticated');
    return _api!;
  }

  gd.DriveApi get api => _drive;

  // ── Root folder ───────────────────────────────────────────────────────────

  /// The canonical root. If duplicate "omininote" folders exist (create/create
  /// race between two devices), pick the lexicographically smallest id so every
  /// device converges on the same one.
  Future<String> get rootFolderId async {
    if (_rootFolderId != null) return _rootFolderId!;
    final result = await _drive.files.list(
      q: "mimeType='$_kAppMimeFolder' and name='$_kRootFolderName' "
          "and trashed=false",
      spaces: 'drive',
      $fields: 'files(id)',
    );
    final ids = (result.files ?? [])
        .map((f) => f.id)
        .whereType<String>()
        .toList()
      ..sort();
    if (ids.isNotEmpty) {
      _rootFolderId = ids.first;
      return _rootFolderId!;
    }
    final meta = gd.File()
      ..name = _kRootFolderName
      ..mimeType = _kAppMimeFolder;
    final created = await _drive.files.create(meta, $fields: 'id');
    _rootFolderId = created.id!;
    return _rootFolderId!;
  }

  // ── Folder helpers ────────────────────────────────────────────────────────

  Future<String> _findOrCreateFolder(String name, String parentId) async {
    final q = "mimeType='$_kAppMimeFolder' and name='$name' "
        "and '$parentId' in parents and trashed=false";
    final result = await _drive.files.list(
      q: q,
      spaces: 'drive',
      $fields: 'files(id)',
    );
    if (result.files != null && result.files!.isNotEmpty) {
      final ids = result.files!.map((f) => f.id!).toList()..sort();
      return ids.first;
    }
    final meta = gd.File()
      ..name = name
      ..mimeType = _kAppMimeFolder
      ..parents = [parentId];
    final created = await _drive.files.create(meta, $fields: 'id');
    return created.id!;
  }

  /// Resolves (creating as needed) the parent folder of [drivePath], walking
  /// only the segments the cache doesn't already know.
  Future<String> _ensureParentFolder(String drivePath) async {
    final parts = drivePath.replaceAll('\\', '/').split('/');
    String parentId = await rootFolderId;
    var pathSoFar = '';
    for (final part in parts.sublist(0, parts.length - 1)) {
      pathSoFar = pathSoFar.isEmpty ? part : '$pathSoFar/$part';
      final cached = _folderIds[pathSoFar];
      if (cached != null) {
        parentId = cached;
        continue;
      }
      parentId = await _findOrCreateFolder(part, parentId);
      _cacheFolder(pathSoFar, parentId);
    }
    return parentId;
  }

  Future<String?> _findFileId(String drivePath) async {
    final cached = _index[drivePath];
    if (cached != null) return cached.id;
    final fileName = drivePath.replaceAll('\\', '/').split('/').last;
    final parentId = await _ensureParentFolder(drivePath);
    final result = await _drive.files.list(
      q: "name='$fileName' and '$parentId' in parents and trashed=false",
      spaces: 'drive',
      $fields: 'files(id,headRevisionId)',
    );
    if (result.files != null && result.files!.isNotEmpty) {
      final f = result.files!.first;
      _record(drivePath, f.id!, f.headRevisionId);
      return f.id;
    }
    return null;
  }

  // ── Uploads ──────────────────────────────────────────────────────────────

  /// Uploads (create or update) a JSON file. Returns its headRevisionId.
  Future<String?> uploadJson(String drivePath, String content) async {
    final bytes = utf8.encode(content);
    return _upload(drivePath, bytes, 'application/json');
  }

  /// Uploads already-encoded JSON bytes (create or update) — skips the
  /// main-isolate utf8 round-trip for callers that have the file bytes.
  Future<String?> uploadJsonBytes(String drivePath, List<int> bytes) =>
      _upload(drivePath, bytes, 'application/json');

  /// Uploads a binary asset. Content-addressed: if a file already exists at the
  /// path we treat it as identical (assets never change) and skip.
  Future<String?> uploadBinary(String drivePath, List<int> bytes) async {
    final existing = await _findFileId(drivePath);
    if (existing != null) return _index[drivePath]?.head;
    return _upload(drivePath, bytes, 'application/octet-stream');
  }

  Future<String?> _upload(
    String drivePath,
    List<int> bytes,
    String mime,
  ) async {
    final fileName = drivePath.replaceAll('\\', '/').split('/').last;
    final existing = await _findFileId(drivePath);

    if (existing != null) {
      final media = gd.Media(Stream.value(bytes), bytes.length,
          contentType: mime);
      try {
        final updated = await _drive.files.update(
          gd.File()..name = fileName,
          existing,
          uploadMedia: media,
          $fields: 'id,headRevisionId',
        );
        _record(drivePath, updated.id ?? existing, updated.headRevisionId);
        return updated.headRevisionId;
      } on gd.DetailedApiRequestError catch (e) {
        // Stale index: file was trashed/deleted remotely → create fresh.
        if (e.status != 404) rethrow;
        _forget(drivePath);
      }
    }

    // Parent chain is warm in _folderIds after _findFileId's walk.
    final parentId = await _ensureParentFolder(drivePath);
    final media = gd.Media(Stream.value(bytes), bytes.length,
        contentType: mime);
    final created = await _drive.files.create(
      gd.File()
        ..name = fileName
        ..parents = [parentId],
      uploadMedia: media,
      $fields: 'id,headRevisionId',
    );
    _record(drivePath, created.id!, created.headRevisionId);
    return created.headRevisionId;
  }

  /// Uploads a share bundle to `omininote/shared/` and makes it public
  /// ("anyone with the link" can read), returning its Drive file id — used for
  /// the `omninote://` share link. It's kept OUT of the synced tree (its path
  /// isn't index-tracked), so the sync loop ignores it. The recipient downloads
  /// it over plain HTTPS: a `drive.file`-scoped app can't see another user's
  /// shared file through the API, but a public link needs no auth.
  Future<String?> uploadSharedBundle(String name, List<int> bytes) async {
    final root = await rootFolderId;
    final folder = await _findOrCreateFolder('shared', root);
    final media = gd.Media(Stream.value(bytes), bytes.length,
        contentType: 'application/octet-stream');
    final created = await _drive.files.create(
      gd.File()
        ..name = name
        ..parents = [folder],
      uploadMedia: media,
      $fields: 'id',
    );
    final id = created.id;
    if (id == null) return null;
    await _drive.permissions.create(
      gd.Permission()
        ..type = 'anyone'
        ..role = 'reader',
      id,
    );
    return id;
  }

  // ── Downloads ──────────────────────────────────────────────────────────────

  Future<List<int>?> downloadById(String fileId) async {
    final media = await _drive.files.get(
      fileId,
      downloadOptions: gd.DownloadOptions.fullMedia,
    ) as gd.Media;
    return _collect(media.stream);
  }

  /// Bytes above this hop to a background isolate for the utf8 decode
  /// (matches SyncService's merge offload gate); smaller stay inline.
  static const int _kDecodeOffloadBytes = 256 * 1024;

  Future<String?> downloadJsonById(String fileId) async {
    final bytes = await downloadById(fileId);
    if (bytes == null) return null;
    if (bytes.length < _kDecodeOffloadBytes) return utf8.decode(bytes);
    try {
      return await Isolate.run(() => utf8.decode(bytes));
    } catch (_) {
      return utf8.decode(bytes);
    }
  }

  Future<void> deleteFile(String drivePath) async {
    final id = await _findFileId(drivePath);
    if (id == null) return;
    await _drive.files.delete(id);
    _forget(drivePath);
  }

  /// Resolves a *folder* path (relative to root) to its Drive id without
  /// creating anything along the way — unlike [_ensureParentFolder], a missing
  /// segment returns null instead of materializing the chain.
  Future<String?> _findFolderId(String folderPath) async {
    final parts = folderPath.replaceAll('\\', '/').split('/');
    String parentId = await rootFolderId;
    var pathSoFar = '';
    for (final part in parts) {
      pathSoFar = pathSoFar.isEmpty ? part : '$pathSoFar/$part';
      final cached = _folderIds[pathSoFar];
      if (cached != null) {
        parentId = cached;
        continue;
      }
      final result = await _drive.files.list(
        q: "mimeType='$_kAppMimeFolder' and name='$part' "
            "and '$parentId' in parents and trashed=false",
        spaces: 'drive',
        $fields: 'files(id)',
      );
      final ids = (result.files ?? [])
          .map((f) => f.id)
          .whereType<String>()
          .toList()
        ..sort();
      if (ids.isEmpty) return null;
      parentId = ids.first;
      _cacheFolder(pathSoFar, parentId);
    }
    return parentId;
  }

  /// Deletes a folder and everything under it on Drive, **best-effort**, then
  /// drops all index/cache entries under it.
  ///
  /// We can't use a single cascading `files.delete(folderId)`: under the
  /// `drive.file` scope Drive refuses to recursively delete a folder unless it
  /// can confirm write access to *every* descendant (403 "not granted write
  /// access to all of the children"). So instead we walk the subtree and delete
  /// each app-created file/subfolder **individually** — which `drive.file` does
  /// allow — bottom-up. A 404 (already gone) or 403 (a genuinely non-owned
  /// leftover we can't touch) is skipped, not fatal: this is downstream
  /// *cleanup*, so removing what we own and moving on is correct — the purge
  /// itself is enforced by the grow-only `purgedAt` marker + content-path
  /// filtering, never by this delete succeeding. Network errors propagate so
  /// the caller keeps it queued for retry. Idempotent: a re-run 404s on
  /// already-deleted ids.
  Future<void> deleteFolder(String folderPath) async {
    final id = await _findFolderId(folderPath);
    if (id != null) {
      await _deleteSubtree(id); // descendants first (app-owned files/folders)
      await _deleteOne(id); // then the folder itself
    }
    forgetUnder(folderPath);
  }

  /// Deletes every descendant of [folderId] bottom-up (recurses into subfolders
  /// before deleting them). Does not delete [folderId] itself.
  Future<void> _deleteSubtree(String folderId) async {
    final children = <gd.File>[];
    String? token;
    do {
      final resp = await _drive.files.list(
        q: "'$folderId' in parents and trashed=false",
        spaces: 'drive',
        pageSize: 1000,
        pageToken: token,
        $fields: 'nextPageToken,files(id,mimeType)',
      );
      children.addAll(resp.files ?? const []);
      token = resp.nextPageToken;
    } while (token != null);

    for (final c in children) {
      final cid = c.id;
      if (cid == null) continue;
      if (c.mimeType == _kAppMimeFolder) await _deleteSubtree(cid);
      await _deleteOne(cid);
    }
  }

  /// Deletes one file/folder id, swallowing 404 (already gone) and 403 (a
  /// non-owned item we can't delete under `drive.file`). Other errors (incl.
  /// [SocketException]) propagate.
  Future<void> _deleteOne(String id) async {
    try {
      await _drive.files.delete(id);
    } on gd.DetailedApiRequestError catch (e) {
      if (e.status != 404 && e.status != 403) rethrow;
    }
  }

  /// Drops file-index and folder-cache entries at or under [prefix].
  void forgetUnder(String prefix) {
    final p = '$prefix/';
    _index.removeWhere((k, _) => k == prefix || k.startsWith(p));
    final droppedFolders = _folderIds.keys
        .where((k) => k == prefix || k.startsWith(p))
        .toList();
    for (final k in droppedFolders) {
      _folderPathById.remove(_folderIds.remove(k));
    }
    _saveIndexSoon();
  }

  // ── Full-tree listing (bootstrap / resync / duplicate healing) ─────────────

  /// Enumerates every file under any "omininote" root, keyed by relative path.
  /// Duplicate roots collapse onto the same relative paths, which the merge
  /// engine then reconciles — self-healing the create/create race.
  Future<Map<String, RemoteFile>> listAllFiles() async {
    final all = <gd.File>[];
    String? token;
    do {
      final resp = await _drive.files.list(
        q: 'trashed=false',
        spaces: 'drive',
        pageSize: 1000,
        pageToken: token,
        $fields:
            'nextPageToken,files(id,name,parents,mimeType,headRevisionId)',
      );
      all.addAll(resp.files ?? const []);
      token = resp.nextPageToken;
    } while (token != null);

    final folders = <String, gd.File>{};
    final rootIds = <String>{};
    for (final f in all) {
      if (f.mimeType != _kAppMimeFolder) continue;
      folders[f.id!] = f;
    }
    // Any "omininote" folder that is not nested inside another of our folders
    // is a logical root.
    for (final f in folders.values) {
      if (f.name != _kRootFolderName) continue;
      final parent = (f.parents?.isNotEmpty ?? false) ? f.parents!.first : null;
      if (parent == null || !folders.containsKey(parent)) {
        rootIds.add(f.id!);
      }
    }

    String? relPathFor(gd.File f) {
      final parts = <String>[f.name!];
      var parentId = (f.parents?.isNotEmpty ?? false) ? f.parents!.first : null;
      var guard = 0;
      while (parentId != null && !rootIds.contains(parentId) && guard++ < 64) {
        final parent = folders[parentId];
        if (parent == null) return null; // outside our tree
        parts.insert(0, parent.name!);
        parentId =
            (parent.parents?.isNotEmpty ?? false) ? parent.parents!.first : null;
      }
      if (parentId == null || !rootIds.contains(parentId)) return null;
      return parts.join('/');
    }

    // Warm the folder cache so subsequent uploads skip the per-segment
    // files.list walk entirely (and resolveFileId can stop its parent walk).
    for (final f in folders.values) {
      if (rootIds.contains(f.id)) continue;
      final rel = relPathFor(f);
      if (rel != null && !_folderIds.containsKey(rel)) {
        _cacheFolder(rel, f.id!);
      }
    }

    final out = <String, RemoteFile>{};
    for (final f in all) {
      if (f.mimeType == _kAppMimeFolder) continue;
      if (f.id == null || f.name == null) continue;
      final rel = relPathFor(f);
      if (rel == null) continue;
      // If two roots hold the same path, keep the one whose head we already
      // track (canonical), else first seen; merge engine handles the rest.
      out.putIfAbsent(
        rel,
        () => RemoteFile(
          id: f.id!,
          headRevisionId: f.headRevisionId,
          mimeType: f.mimeType,
        ),
      );
    }
    for (final e in out.entries) {
      // Record/refresh the id mapping but KEEP the previously-reconciled
      // head (or none if the id changed): the head must only advance after a
      // pull actually reconciles that revision. Stamping the listing's
      // current head here would make the resync's own unchanged-file check
      // skip every file — including the changed ones it exists to fetch.
      final prev = _index[e.key];
      final keepHead =
          (prev != null && prev.id == e.value.id) ? prev.head : null;
      _record(e.key, e.value.id, keepHead);
    }
    return out;
  }

  // ── Changes API ───────────────────────────────────────────────────────────

  Future<String> getChangesStartToken() async {
    final resp =
        await _drive.changes.getStartPageToken($fields: 'startPageToken');
    return resp.startPageToken ?? '';
  }

  Future<({List<DriveChange> changes, String nextPageToken})> pollChanges(
    String pageToken,
  ) async {
    final resp = await _drive.changes.list(
      pageToken,
      spaces: 'drive',
      pageSize: 1000,
      $fields: 'nextPageToken,newStartPageToken,'
          'changes(fileId,removed,file(id,name,parents,mimeType,'
          'headRevisionId,trashed))',
      includeItemsFromAllDrives: false,
      supportsAllDrives: false,
    );
    final changes = <DriveChange>[];
    for (final c in resp.changes ?? const []) {
      if (c.fileId == null) continue;
      changes.add(DriveChange(
        fileId: c.fileId!,
        removed: (c.removed ?? false) || (c.file?.trashed ?? false),
        fileName: c.file?.name,
        mimeType: c.file?.mimeType,
        headRevisionId: c.file?.headRevisionId,
      ));
    }
    final next = resp.nextPageToken ?? resp.newStartPageToken ?? pageToken;
    return (changes: changes, nextPageToken: next);
  }

  // ── Index (relPath ↔ fileId ↔ head) ────────────────────────────────────────

  String? relPathForFileId(String fileId) => _fileIdToPath[fileId];
  String? headForPath(String relPath) => _index[relPath]?.head;

  /// True once we have a populated path↔fileId index (i.e. this install has
  /// synced at least once). Used to decide whether a bootstrap is needed.
  bool get hasIndex => _index.isNotEmpty;

  /// Records the id/head we just observed for [relPath] (used by the poller
  /// after downloading a remote change, for echo suppression).
  void recordRemote(String relPath, String id, String? head) =>
      _record(relPath, id, head);

  /// Resolves an unknown fileId (a file another device just created) to its
  /// relative path by walking its parent chain — a handful of cheap
  /// `files.get` calls (usually one, thanks to the folder cache) instead of
  /// the full-tree resync this used to force. Returns the file's metadata and
  /// records the path↔id mapping on success; null if the file isn't under our
  /// root (or was trashed / is a folder).
  Future<RemoteFile?> resolveFileId(String fileId) async {
    gd.File f;
    try {
      f = await _drive.files.get(
        fileId,
        $fields: 'id,name,parents,mimeType,headRevisionId,trashed',
      ) as gd.File;
    } catch (_) {
      return null;
    }
    if (f.trashed == true || f.name == null) return null;
    if (f.mimeType == _kAppMimeFolder) return null;

    final root = await rootFolderId;
    // Walk up, collecting unknown folders until the root or a cached folder.
    final walked = <({String id, String name})>[]; // bottom-up
    String? basePath; // path of the cached folder we stopped at, '' for root
    var parentId = (f.parents?.isNotEmpty ?? false) ? f.parents!.first : null;
    var guard = 0;
    while (guard++ < 16) {
      if (parentId == null) return null; // detached — not ours
      if (parentId == root) {
        basePath = '';
        break;
      }
      final known = _folderPathById[parentId];
      if (known != null) {
        basePath = known;
        break;
      }
      gd.File parent;
      try {
        parent = await _drive.files.get(
          parentId,
          $fields: 'id,name,parents',
        ) as gd.File;
      } catch (_) {
        return null;
      }
      if (parent.name == null) return null;
      walked.add((id: parentId, name: parent.name!));
      parentId = (parent.parents?.isNotEmpty ?? false)
          ? parent.parents!.first
          : null;
    }
    if (basePath == null) return null; // guard tripped

    // Cache the walked chain (top-down) and build the file's path.
    var path = basePath;
    for (final folder in walked.reversed) {
      path = path.isEmpty ? folder.name : '$path/${folder.name}';
      _cacheFolder(path, folder.id);
    }
    final rel = path.isEmpty ? f.name! : '$path/${f.name!}';
    // Record the mapping with NO head: we haven't reconciled this revision
    // yet, and recording the current head here would make the caller's echo
    // suppression skip the very download that's about to happen. The head is
    // recorded after the pull reconciles it.
    _record(rel, fileId, null);
    return RemoteFile(
        id: fileId, headRevisionId: f.headRevisionId, mimeType: f.mimeType);
  }

  void _record(String relPath, String id, String? head) {
    _index[relPath] = _IndexEntry(id, head);
    _fileIdToPath[id] = relPath;
    _saveIndexSoon();
  }

  void _forget(String relPath) {
    final e = _index.remove(relPath);
    if (e != null) _fileIdToPath.remove(e.id);
    _saveIndexSoon();
  }

  Timer? _saveDebounce;
  void _saveIndexSoon() {
    _saveDebounce?.cancel();
    _saveDebounce = Timer(const Duration(seconds: 2), _saveIndex);
  }

  Future<void> _loadIndex() async {
    try {
      final dir = await getApplicationSupportDirectory();
      _indexFile = File('${dir.path}/drive_index_$accountId.json');
      if (!await _indexFile!.exists()) {
        // One-time migration: the pre-multi-account single `drive_index.json`
        // belongs to the default account. Adopt it so that account resumes
        // incrementally instead of re-bootstrapping the whole tree.
        final legacy = File('${dir.path}/drive_index.json');
        if (await legacy.exists() &&
            AuthService().defaultAccountId == accountId) {
          try {
            await legacy.rename(_indexFile!.path);
          } catch (_) {}
        }
      }
      if (await _indexFile!.exists()) {
        final map = jsonDecode(await _indexFile!.readAsString())
            as Map<String, dynamic>;
        map.forEach((k, v) {
          final m = v as Map<String, dynamic>;
          final e = _IndexEntry(m['id'] as String, m['head'] as String?);
          _index[k] = e;
          _fileIdToPath[e.id] = k;
        });
      }
    } catch (_) {}
  }

  /// Forgets the reconciled `head` for every file under a notebook (keeping the
  /// fileId mapping), so the next pull/resync re-downloads and merges them.
  /// Used when re-enabling sync on a notebook that was local-only: its files
  /// were listed (heads recorded) but their content was never applied, so
  /// without this the unchanged-file check would wrongly skip them.
  Future<void> forgetNotebookHeads(String notebookId) async {
    final prefix = 'notebooks/$notebookId/';
    for (final key in _index.keys.toList()) {
      if (key.startsWith(prefix)) {
        _index[key] = _IndexEntry(_index[key]!.id, null);
      }
    }
    await _saveIndex();
  }

  /// Clears the path↔fileId↔head index (and deletes its file). Used when an
  /// account is removed / signs out, so a later re-add bootstraps fresh instead
  /// of resuming against stale Drive mappings.
  Future<void> resetIndex() async {
    _saveDebounce?.cancel();
    _index.clear();
    _fileIdToPath.clear();
    _rootFolderId = null;
    _folderIds.clear();
    _folderPathById.clear();
    try {
      if (_indexFile != null && await _indexFile!.exists()) {
        await _indexFile!.delete();
      }
    } catch (_) {}
  }

  Future<void> _saveIndex() async {
    try {
      _indexFile ??= File(
          '${(await getApplicationSupportDirectory()).path}/drive_index_$accountId.json');
      final map = _index.map(
        (k, v) => MapEntry(k, {'id': v.id, 'head': v.head}),
      );
      await _indexFile!.writeAsString(jsonEncode(map), flush: true);
    } catch (_) {}
  }

  Future<List<int>> _collect(Stream<List<int>> stream) async {
    final out = <int>[];
    await for (final chunk in stream) {
      out.addAll(chunk);
    }
    return out;
  }
}

// ── Data classes ─────────────────────────────────────────────────────────────

class _IndexEntry {
  final String id;
  final String? head;
  const _IndexEntry(this.id, this.head);
}

class RemoteFile {
  final String id;
  final String? headRevisionId;
  final String? mimeType;
  const RemoteFile({required this.id, this.headRevisionId, this.mimeType});
}

class DriveChange {
  final String fileId;
  final bool removed;
  final String? fileName;
  final String? mimeType;
  final String? headRevisionId;

  const DriveChange({
    required this.fileId,
    required this.removed,
    this.fileName,
    this.mimeType,
    this.headRevisionId,
  });
}

class DriveException implements Exception {
  final String message;
  const DriveException(this.message);
  @override
  String toString() => 'DriveException: $message';
}

// ── HTTP client that injects a fresh auth header per request ──────────────────

/// Fetches auth headers for its specific account on every request, so a
/// proactively refreshed access token is always used (headers aren't cached)
/// and each account's Drive calls carry that account's token.
class _AuthedClient extends http.BaseClient {
  final String accountId;
  _AuthedClient(this.accountId);
  final http.Client _inner = http.Client();

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final headers = await AuthService().getAuthHeaders(accountId);
    request.headers.addAll(headers);
    return _inner.send(request);
  }

  @override
  void close() => _inner.close();
}
