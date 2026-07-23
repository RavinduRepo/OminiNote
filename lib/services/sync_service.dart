import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'package:flutter/foundation.dart';
import '../models/canvas_page.dart';
import 'auth_service.dart';
import 'drive_service.dart';
import 'notebook_service.dart';
import 'settings_service.dart';
import 'sync/merge_engine.dart';

enum SyncStatus { idle, syncing, error, offline }

/// Callbacks an open canvas registers so pulled changes reach its live
/// in-memory state instead of only the files on disk (which its own autosave
/// would then overwrite — the delete-resurrection bug).
class CanvasSyncListener {
  /// Called with the merged page after a page file of this canvas is pulled.
  final void Function(CanvasPage merged) onPage;

  /// Called after this canvas's canvas.json changed on disk from a pull
  /// (structure: rows/defaults/attachments).
  final void Function() onStructure;

  /// Called when a soft-deleted page of this canvas is restored from the
  /// recycle bin while the canvas is open — the controller re-links it in
  /// memory (and flushes to disk) so its own autosave doesn't clobber a
  /// disk-level restore. Awaited so the bin sees a fresh state on reload.
  final Future<void> Function(String pageId)? onRestorePage;

  /// Called to drop a link-marker text element next to elements of this OPEN
  /// canvas (the reciprocal "there is a link here" marker on the other side
  /// of a new connection) — in memory, so the canvas's own autosave can't
  /// clobber a disk write. Returns the marker element's id, or null.
  final Future<String?> Function(
          String pageId, List<String> nearIds, String uri, String title)?
      onInsertMarker;

  /// Called to delete standalone link markers among [ids] on [pageId] of this
  /// OPEN canvas — the marker-cleanup half of a connection removal (Model A),
  /// done in memory so the canvas's own autosave can't clobber a disk write.
  final Future<void> Function(String pageId, List<String> ids)? onRemoveMarker;

  /// Called to rewrite link-run URIs on [pageId] of this OPEN canvas that point
  /// at a moved element — the cross-canvas half of "a linked item moved pages"
  /// when the far canvas is open in a split (done in memory, not on disk).
  final Future<void> Function(String pageId, Set<String> movedIds,
      String movedCanvasId, String fromPage, String toPage)? onRemapMarkerUris;

  /// Called to flash + scroll to elements of this OPEN canvas (a graph node tap
  /// targeting the already-open canvas) — so the glow re-fires on every tap,
  /// including items in the current canvas, where opening it would no-op.
  final void Function(String pageId, List<String> elementIds)? onFocusElements;

  const CanvasSyncListener({
    required this.onPage,
    required this.onStructure,
    this.onRestorePage,
    this.onInsertMarker,
    this.onRemoveMarker,
    this.onRemapMarkerUris,
    this.onFocusElements,
  });
}

/// Per-account sync state. Phase 2 runs one of these per connected account, each
/// with its own [DriveService] (own Drive root, index, changes token) and its
/// own in-flight guards — so one account's pull/resync never blocks another's.
class _AccountSync {
  final String accountId;
  bool pulling = false;
  bool resyncing = false;
  Timer? resyncDebounce;
  _AccountSync(this.accountId);

  DriveService get drive => DriveManager.forAccount(accountId);
}

/// Orchestrates two-way sync between local storage and Google Drive, **per
/// account** (Phase 2). Each notebook syncs to its `syncTarget` account (or the
/// default when null); each account's Drive tree mirrors the subset of local
/// storage that belongs to it. Every file carries a `(rev, updatedAt,
/// deviceId)` envelope reconciled by the [MergeEngine].
///
/// * **Bootstrap / repair** ([repair]) lists+reconciles each account's whole
///   Drive tree both ways.
/// * **Push** — every local atomic write marks a relative path dirty in a
///   persistent journal; a debounced drain routes each file to *its notebook's
///   account's* Drive. `notebooks.json` is uploaded to every account, filtered
///   to that account's own notebooks.
/// * **Pull** — each account's Drive Changes API is polled (one timer iterates
///   all accounts). Known files are merged in place; unknown ids are resolved
///   via their parent chain. Our own uploads are echo-suppressed by head.
class SyncService {
  static final SyncService _instance = SyncService._internal();
  factory SyncService() => _instance;
  SyncService._internal();

  final ValueNotifier<SyncStatus> status = ValueNotifier(SyncStatus.idle);
  final ValueNotifier<DateTime?> lastSyncAt = ValueNotifier(null);

  /// Bumped whenever a remote change is written to local disk, so screens can
  /// reload their lists / pages.
  final ValueNotifier<int> dataVersion = ValueNotifier(0);

  // Persistent dirty journal: relative paths awaiting upload (across accounts).
  final Set<String> _dirty = {};
  File? _journalFile;

  /// True only in the **sync-owner** window (elected by `SyncCoordinator`). A
  /// non-owner window never runs the poll/push loop and never journals — that
  /// would put two writers on the shared journal/index. `init()` is only called
  /// on the owner, so a single instance is always active (unchanged behavior).
  bool _active = false;
  bool get active => _active;

  // Open canvases wanting live merge of pulled changes, keyed by canvas id.
  final Map<String, CanvasSyncListener> _canvasListeners = {};

  void registerCanvasListener(String canvasId, CanvasSyncListener l) =>
      _canvasListeners[canvasId] = l;

  void unregisterCanvasListener(String canvasId) =>
      _canvasListeners.remove(canvasId);

  /// If the named canvas is open, restore [pageId] through its live controller
  /// and return true; otherwise return false so the caller does a disk-level
  /// restore. Keeps a bin-restore from being clobbered by the open canvas's
  /// autosave (its in-memory rows can be ahead of disk). Awaits the controller
  /// so the on-disk tombstone is cleared before the bin reloads its list.
  Future<bool> restorePageInOpenCanvas(String canvasId, String pageId) async {
    final cb = _canvasListeners[canvasId]?.onRestorePage;
    if (cb == null) return false;
    await cb(pageId);
    return true;
  }

  /// If the named canvas is open, drop a link marker through its live
  /// controller (see [CanvasSyncListener.onInsertMarker]); `handled: false`
  /// means "not open" — the caller then edits the page file directly.
  Future<({bool handled, String? markerId})> insertMarkerInOpenCanvas(
    String canvasId,
    String pageId,
    List<String> nearIds,
    String uri,
    String title,
  ) async {
    final cb = _canvasListeners[canvasId]?.onInsertMarker;
    if (cb == null) return (handled: false, markerId: null);
    return (handled: true, markerId: await cb(pageId, nearIds, uri, title));
  }

  /// If the named canvas is open, delete the standalone link markers among
  /// [ids] on [pageId] through its live controller and return true; false means
  /// "not open" so the caller edits the page file. Mirrors
  /// [insertMarkerInOpenCanvas].
  Future<bool> removeMarkersInOpenCanvas(
      String canvasId, String pageId, List<String> ids) async {
    final cb = _canvasListeners[canvasId]?.onRemoveMarker;
    if (cb == null) return false;
    await cb(pageId, ids);
    return true;
  }

  /// If the named canvas is open, rewrite its link-run URIs pointing at the
  /// moved element through its live controller and return true; false → not
  /// open (the caller edits the page file). Mirrors [removeMarkersInOpenCanvas].
  Future<bool> remapMarkerUrisInOpenCanvas(String canvasId, String pageId,
      Set<String> movedIds, String movedCanvasId, String fromPage,
      String toPage) async {
    final cb = _canvasListeners[canvasId]?.onRemapMarkerUris;
    if (cb == null) return false;
    await cb(pageId, movedIds, movedCanvasId, fromPage, toPage);
    return true;
  }

  /// If the named canvas is open, flash + scroll to [elementIds] on [pageId]
  /// through its live controller and return true; false → not open (the caller
  /// navigates + hands off a pending focus instead). Lets a graph node tap
  /// re-glow the current canvas on every tap.
  bool focusElementsInOpenCanvas(
      String canvasId, String pageId, List<String> elementIds) {
    final cb = _canvasListeners[canvasId]?.onFocusElements;
    if (cb == null) return false;
    cb(pageId, elementIds);
    return true;
  }

  // Per-account sync state, keyed by account id (Google `sub`).
  final Map<String, _AccountSync> _accountSyncs = {};

  Timer? _pushDebounce;
  Timer? _pollTimer;
  bool _pushing = false;

  static const _kPollInterval = Duration(seconds: 15);
  static const _kPushDebounce = Duration(milliseconds: 1500);

  String? get _defaultId => AuthService().defaultAccountId;
  List<String> _connectedAccountIds() =>
      AuthService().accounts.value.map((a) => a.id).toList();

  // ── Init / dispose ──────────────────────────────────────────────────────────

  Future<void> init() async {
    if (_active) return; // idempotent (initial-owner + handover both call it)
    _active = true;
    await _loadJournal();
    lastSyncAt.value = SettingsService().lastSyncAt;
    AuthService().accounts.addListener(_onAccountsChangedListener);
    if (AuthService().isSignedIn) unawaited(_onAccountsChanged());
  }

  void dispose() {
    _pushDebounce?.cancel();
    _pollTimer?.cancel();
    for (final as in _accountSyncs.values) {
      as.resyncDebounce?.cancel();
    }
    AuthService().accounts.removeListener(_onAccountsChangedListener);
  }

  void _onAccountsChangedListener() => unawaited(_onAccountsChanged());

  /// Reconciles the running per-account sync units with the current account
  /// list: tears down removed accounts, brings up new ones, (re)starts polling.
  Future<void> _onAccountsChanged() async {
    final current = _connectedAccountIds().toSet();

    // Teardown accounts that went away: stop their timers and clean up their
    // Drive index + changes token so a re-add bootstraps fresh (rather than
    // resuming against stale mappings or leaving orphan index files). Reset
    // before dropping the instance, since forAccount would otherwise recreate it.
    for (final id in _accountSyncs.keys.toList()) {
      if (current.contains(id)) continue;
      _accountSyncs.remove(id)!.resyncDebounce?.cancel();
      await DriveManager.forAccount(id).resetIndex();
      await SettingsService().removeDriveChangesToken(id);
      DriveManager.remove(id);
    }

    // Bring up newly-added accounts.
    for (final id in current) {
      if (_accountSyncs.containsKey(id)) continue;
      final as = _AccountSync(id);
      _accountSyncs[id] = as;
      unawaited(_bringUpAccount(as));
    }

    if (current.isEmpty) {
      _pollTimer?.cancel();
      status.value = SyncStatus.idle;
    } else {
      _startPolling();
    }
  }

  Future<void> _bringUpAccount(_AccountSync as) async {
    // Fresh session for this account: clear any stale guard.
    as.pulling = false;
    as.resyncing = false;
    await as.drive.init();

    // One-time migration of the pre-multi-account single changes token to the
    // default account (its drive_index.json is adopted in DriveService).
    if (as.accountId == _defaultId &&
        SettingsService().driveChangesTokenFor(as.accountId).isEmpty &&
        SettingsService().legacyDriveChangesToken.isNotEmpty) {
      await SettingsService().setDriveChangesTokenFor(
          as.accountId, SettingsService().legacyDriveChangesToken);
      await SettingsService().clearLegacyDriveChangesToken();
    }

    // Bootstrap only when this account has never synced on this install.
    final needsBootstrap =
        SettingsService().driveChangesTokenFor(as.accountId).isEmpty ||
            !as.drive.hasIndex;
    if (needsBootstrap) {
      await _fullResync(as);
    } else {
      await _doPull(as);
    }
    if (_dirty.isNotEmpty) _armPush();
  }

  void _startPolling() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(_kPollInterval, (_) => _pollAll());
  }

  Future<void> _pollAll() async {
    for (final as in _accountSyncs.values.toList()) {
      await _doPull(as);
    }
  }

  // ── Public triggers ─────────────────────────────────────────────────────────

  /// Manual "Sync now": push pending, then pull deltas for every account.
  Future<void> syncNow() async {
    if (!AuthService().isSignedIn) return;
    await _flushPush();
    await _pollAll();
  }

  /// "Repair sync" — full two-way reconcile of every account's Drive tree.
  Future<void> repair() => _fullResyncAll();

  Future<void> _fullResyncAll() async {
    for (final as in _accountSyncs.values.toList()) {
      await _fullResync(as);
    }
  }

  /// True when edits haven't yet reached Drive (used to warn on sign-out).
  bool get hasPendingUploads => _dirty.isNotEmpty;

  /// Re-connects a notebook that was local-only on this device: forgets the
  /// reconciled heads of its files on **its account's** Drive and resyncs that
  /// account so anything missed while disconnected is pulled + merged.
  Future<void> reenableNotebookSync(String notebookId) async {
    if (!AuthService().isSignedIn) return;
    final target = await NotebookService()
        .syncTargetOfNotebook(notebookId, defaultAccountId: _defaultId);
    final as = target == null ? null : _accountSyncs[target];
    if (as == null) return;
    await as.drive.forgetNotebookHeads(notebookId);
    if (as.resyncing) {
      _scheduleResync(as);
    } else {
      unawaited(_fullResync(as));
    }
  }

  /// **Moves** a notebook to [destAccountId] without data loss. A notebook id
  /// must never live on two accounts' Drives (or edits/deletes bleed across
  /// accounts), so this: (1) fully syncs the notebook DOWN from its current
  /// account so the local copy is the complete cloud+local union, then
  /// (2) re-keys it to a new id bound to the destination and tombstones the old
  /// id on the source, then (3) pushes the new subtree + index. Returns
  /// `(ok, error, newId)`; on a sync-down failure it refuses rather than lose
  /// cloud-only pages.
  Future<({bool ok, String? error, String? newId})> moveNotebookToAccount(
      String notebookId, String destAccountId) async {
    if (!AuthService().isSignedIn) {
      return (ok: false, error: 'Not signed in.', newId: null);
    }
    final source = await NotebookService()
        .syncTargetOfNotebook(notebookId, defaultAccountId: _defaultId);
    if (source == destAccountId) {
      return (ok: true, error: null, newId: notebookId); // already there
    }

    // 1. Fully pull the notebook from its source account first so nothing that
    //    only exists in the cloud is dropped by the re-key.
    if (source != null) {
      final as = _accountSyncs[source];
      if (as == null) {
        return (
          ok: false,
          error: 'Sign into the notebook\'s current account to move it.',
          newId: null
        );
      }
      final complete = await _syncDownNotebook(notebookId, as);
      if (!complete) {
        return (
          ok: false,
          error: 'Couldn\'t fetch all of this notebook\'s cloud data — check '
              'your connection and try again.',
          newId: null
        );
      }
    }

    // 2. Re-key locally (copy subtree, tombstone old, bind new to destination).
    final newId =
        await NotebookService().rekeyNotebookForMove(notebookId, destAccountId);
    if (newId == null) return (ok: false, error: 'Move failed.', newId: null);

    // 3. Queue the new subtree + index for upload and push now.
    final rels = await NotebookService().listSyncedRelPathsForNotebook(newId);
    _dirty.addAll(rels);
    _dirty.add('notebooks.json');
    await _saveJournal();
    _bumpData();
    unawaited(_flushPush());
    return (ok: true, error: null, newId: newId);
  }

  /// Downloads every `notebooks/<notebookId>/**` file the account's Drive has
  /// that we lack (or that changed), so the local copy is complete before a
  /// move. Returns false on network failure (caller must abort the move).
  Future<bool> _syncDownNotebook(String notebookId, _AccountSync as) async {
    try {
      final remote = await as.drive.listAllFiles();
      final prefix = 'notebooks/$notebookId/';
      for (final e in remote.entries) {
        if (!e.key.startsWith(prefix)) continue;
        await _pullFile(as, e.key, e.value);
      }
      return true;
    } on SocketException {
      return false;
    } catch (e) {
      debugPrint('syncDownNotebook error: $e');
      return false;
    }
  }

  /// Queues a whole notebook's file subtree + the index for upload and pushes
  /// now — used after importing a notebook bundle (its files were written
  /// directly, not through the dirty-marking save path).
  Future<void> uploadNotebook(String notebookId) async {
    if (!AuthService().isSignedIn) return;
    final rels =
        await NotebookService().listSyncedRelPathsForNotebook(notebookId);
    _dirty.addAll(rels);
    _dirty.add('notebooks.json');
    await _saveJournal();
    unawaited(_flushPush());
  }

  /// Bumps the data-changed signal so open list screens reload — used after a
  /// notebook is created outside the normal sync path (e.g. an import).
  void notifyDataChanged() => _bumpData();

  /// Flush pending uploads immediately (e.g. when the app is backgrounded).
  Future<void> flushPending() => _flushPush();

  // ── Push ─────────────────────────────────────────────────────────────────────

  /// Called by [NotebookService] after every atomic JSON write.
  void onLocalFileSaved(String localPath, String content) {
    final rel = NotebookService().relPathOf(localPath);
    if (rel != null) _markDirty(rel);
  }

  /// Called by [NotebookService] after an asset file is stored.
  void onLocalAssetSaved(String localPath, List<int> bytes) {
    final rel = NotebookService().relPathOf(localPath);
    if (rel != null) _markDirty(rel);
  }

  void _markDirty(String rel) {
    // Non-owner windows edit local files but must NOT journal or push (two
    // writers on the shared journal/index corrupt them). Their edits sync once
    // this window becomes the owner and the file is touched again. See
    // KNOWN_ISSUES for that limitation.
    if (!_active) return;
    _dirty.add(rel);
    unawaited(_saveJournal());
    if (!AuthService().isSignedIn) return;
    _armPush();
  }

  void _armPush() {
    _pushDebounce?.cancel();
    _pushDebounce = Timer(_kPushDebounce, _flushPush);
  }

  Future<void> _flushPush() async {
    if (_pushing || !AuthService().isSignedIn || _dirty.isEmpty) return;
    _pushing = true;
    status.value = SyncStatus.syncing;
    // Persist the journal in batches, not after every file: the journal can be
    // large, and an `await _saveJournal()` (a flushed ~100 KB write) per file
    // made a big backlog drain at a crawl and starved live edits. A crash
    // between batches only re-uploads a few already-synced files (idempotent).
    var sinceSave = 0;
    Future<void> batchedSave() async {
      if (++sinceSave >= 25) {
        sinceSave = 0;
        await _saveJournal();
      }
    }

    try {
      final localOnly = NotebookService().localOnlyNotebookIds();
      final purged = await NotebookService().purgedPaths();
      final defaultId = _defaultId;
      final connected = _connectedAccountIds().toSet();
      // Snapshot so concurrent edits during the drain aren't lost.
      final pending = List<String>.from(_dirty);
      for (final rel in pending) {
        if (NotebookService.isPurgedContentPath(rel, purged)) {
          _dirty.remove(rel); // content of a purged item — never upload
          continue;
        }
        if (rel == 'notebooks.json') {
          // Upload each account's own (filtered) index to its own Drive.
          for (final id in connected) {
            final content = await NotebookService()
                .syncedIndexJsonFor(id, defaultAccountId: defaultId);
            await DriveManager.forAccount(id).uploadJson(rel, content);
          }
          _dirty.remove(rel);
          await batchedSave();
          continue;
        }
        if (rel == 'links.json' ||
            rel == 'tags.json' ||
            rel == 'projects.json') {
          // Connections + tag + project registries: uploaded whole to every account
          // (records are tiny id tuples; the union merge makes any account's
          // copy safe to reconcile against, and endpoints an account lacks
          // resolve as dead).
          final file = NotebookService().fileForRelPath(rel);
          if (await file.exists()) {
            final content = await file.readAsString();
            for (final id in connected) {
              await DriveManager.forAccount(id).uploadJson(rel, content);
            }
          }
          _dirty.remove(rel);
          await batchedSave();
          continue;
        }
        final nbId = NotebookService().notebookIdOfRelPath(rel);
        if (nbId != null && localOnly.contains(nbId)) {
          _dirty.remove(rel); // content of a local-only notebook — never upload
          continue;
        }
        final target = await NotebookService()
            .syncTargetOfNotebook(nbId ?? '', defaultAccountId: defaultId);
        if (target == null || !connected.contains(target)) {
          // No connected account owns this file (e.g. bound to an account not
          // signed in here). Defer to that account's next resync, which pushes
          // local files its Drive lacks; drop from the journal to avoid a tight
          // retry loop. The file stays on disk.
          _dirty.remove(rel);
          await batchedSave();
          continue;
        }
        final file = NotebookService().fileForRelPath(rel);
        if (!await file.exists()) {
          _dirty.remove(rel);
          continue;
        }
        await _uploadWithRetry(target, rel, file);
        _dirty.remove(rel);
        await batchedSave();
      }
      // After the files (so purge markers upload before their folders go).
      await _drainRemotePurges(connected, defaultId);
      _finishOk();
    } on SocketException {
      status.value = SyncStatus.offline;
    } catch (e) {
      debugPrint('Sync push error: $e');
      status.value = SyncStatus.error;
    } finally {
      _pushing = false;
      await _saveJournal();
      // An edit that landed mid-drain wasn't in the snapshot — re-arm so it
      // isn't stranded (only after a clean drain, to avoid a tight retry loop).
      if (_dirty.isNotEmpty && status.value == SyncStatus.idle) {
        _armPush();
      }
    }
  }

  Future<void> _uploadWithRetry(
    String accountId,
    String rel,
    File file, {
    int attempt = 0,
  }) async {
    try {
      final drive = DriveManager.forAccount(accountId);
      if (_isAsset(rel)) {
        await drive.uploadBinary(rel, await file.readAsBytes());
      } else {
        // Bytes straight through — readAsString + uploadJson's utf8.encode
        // was a decode+re-encode round-trip of the whole file on the main
        // isolate (real CPU for dense pages while the user is drawing).
        await drive.uploadJsonBytes(rel, await file.readAsBytes());
      }
    } catch (e) {
      if (e is SocketException) rethrow;
      if (attempt >= 4) rethrow;
      // Exponential backoff with jitter: ~2,4,8,16 s.
      final base = (2 << attempt) * 1000;
      await Future.delayed(Duration(milliseconds: base + Random().nextInt(500)));
      await _uploadWithRetry(accountId, rel, file, attempt: attempt + 1);
    }
  }

  // ── Pull (incremental) ────────────────────────────────────────────────────────

  Future<void> _doPull(_AccountSync as) async {
    if (!AuthService().isSignedIn || as.pulling || as.resyncing) return;
    final token = SettingsService().driveChangesTokenFor(as.accountId);
    if (token.isEmpty) {
      await _fullResync(as);
      return;
    }
    as.pulling = true;
    status.value = SyncStatus.syncing;
    try {
      final res = await as.drive.pollChanges(token);
      var changed = false;
      for (final c in res.changes) {
        if (c.mimeType == 'application/vnd.google-apps.folder') continue;
        if (await _applyChange(as, c)) changed = true;
      }
      await SettingsService()
          .setDriveChangesTokenFor(as.accountId, res.nextPageToken);
      _finishOk();
      if (changed) _bumpData();
      if (_dirty.isNotEmpty) _armPush();
    } on SocketException {
      status.value = SyncStatus.offline;
    } catch (e) {
      if (_isGone(e)) {
        as.pulling = false;
        await _fullResync(as);
        return;
      }
      debugPrint('Sync pull error: $e');
      status.value = SyncStatus.error;
    } finally {
      as.pulling = false;
    }
  }

  Future<bool> _applyChange(_AccountSync as, DriveChange c) async {
    if (c.removed) return false; // deletions propagate via structural merge
    var rel = as.drive.relPathForFileId(c.fileId);
    if (rel == null) {
      // A file this account has never seen — created on another device.
      final resolved = await as.drive.resolveFileId(c.fileId);
      if (resolved == null) {
        _scheduleResync(as); // genuinely can't place it — fall back
        return false;
      }
      rel = as.drive.relPathForFileId(c.fileId);
      if (rel == null) return false;
    }
    if (!NotebookService.isSyncedRelPath(rel)) return false;
    // Echo suppression: skip our own most-recent upload.
    if (c.headRevisionId != null &&
        as.drive.headForPath(rel) == c.headRevisionId) {
      return false;
    }
    return _pullFile(
      as,
      rel,
      RemoteFile(
        id: c.fileId,
        headRevisionId: c.headRevisionId,
        mimeType: c.mimeType,
      ),
    );
  }

  // ── Full resync (bootstrap / repair / 410 recovery) — one account ───────────

  Future<void> _fullResync(_AccountSync as) async {
    if (!AuthService().isSignedIn || as.resyncing) return;
    as.resyncing = true;
    status.value = SyncStatus.syncing;
    try {
      // Take the changes baseline BEFORE listing so changes pushed during a slow
      // resync are re-delivered by the next poll.
      final tok = await as.drive.getChangesStartToken();

      final remote = await as.drive.listAllFiles();
      final localPaths = await NotebookService().listSyncedRelPaths();
      final defaultId = _defaultId;
      final localOnly = NotebookService().localOnlyNotebookIds();

      var changed = false;
      for (final entry in remote.entries) {
        // Only pull files that belong to the synced store. `listAllFiles` walks
        // the whole `omininote/` Drive folder, which also contains the public
        // `shared/*.omninote` bundles ("send a link") — binary ZIPs that would
        // blow up `downloadJsonById`'s utf8.decode ("Unexpected extension
        // byte") if pulled as JSON. The incremental path already gates on this;
        // the resync loop must too. (Belt-and-suspenders: a per-file try/catch
        // keeps one unreadable file from aborting the entire resync.)
        if (!NotebookService.isSyncedRelPath(entry.key)) continue;
        try {
          if (await _pullFile(as, entry.key, entry.value)) changed = true;
        } catch (e) {
          debugPrint('Sync resync: skipping ${entry.key}: $e');
        }
      }
      // Push local files this account OWNS that its Drive lacks.
      for (final rel in localPaths) {
        if (remote.containsKey(rel)) continue;
        if (rel == 'notebooks.json' ||
            rel == 'links.json' ||
            rel == 'tags.json' ||
            rel == 'projects.json') {
          _dirty.add(rel); // uploaded per-account by the push drain
          continue;
        }
        final nbId = NotebookService().notebookIdOfRelPath(rel);
        if (nbId != null && localOnly.contains(nbId)) continue;
        final target = await NotebookService()
            .syncTargetOfNotebook(nbId ?? '', defaultAccountId: defaultId);
        if (target == as.accountId) _dirty.add(rel);
      }
      await _saveJournal();

      await SettingsService().setDriveChangesTokenFor(as.accountId, tok);

      as.resyncing = false;
      await _flushPush();
      _finishOk();
      if (changed) _bumpData();
      // Sweep old tombstones once everything just reconciled.
      unawaited(NotebookService().runGarbageCollection());
    } on SocketException {
      status.value = SyncStatus.offline;
    } catch (e) {
      debugPrint('Sync resync error: $e');
      status.value = SyncStatus.error;
    } finally {
      as.resyncing = false;
    }
  }

  void _scheduleResync(_AccountSync as) {
    as.resyncDebounce?.cancel();
    as.resyncDebounce =
        Timer(const Duration(seconds: 3), () => _fullResync(as));
  }

  // ── Reconcile one file from an account's Drive → local ──────────────────────

  Future<bool> _pullFile(_AccountSync as, String rel, RemoteFile rf) async {
    final file = NotebookService().fileForRelPath(rel);
    final drive = as.drive;

    // A local-only notebook is disconnected on this device — never apply pulled
    // content for it (blocks the download direction). Re-enabling triggers a
    // resync to catch up.
    final nbId = NotebookService().notebookIdOfRelPath(rel);
    if (nbId != null &&
        NotebookService().localOnlyNotebookIds().contains(nbId)) {
      return false;
    }

    // Content of a purged item (e.g. re-uploaded by a device that was offline
    // when the purge happened): record the head so it isn't re-offered, but
    // never materialize it locally.
    if (NotebookService.isPurgedContentPath(
        rel, await NotebookService().purgedPaths())) {
      drive.recordRemote(rel, rf.id, rf.headRevisionId);
      return false;
    }

    if (_isAsset(rel)) {
      // Content-addressed & immutable: fetch only if we don't have it.
      if (await file.exists()) {
        drive.recordRemote(rel, rf.id, rf.headRevisionId);
        return false;
      }
      final bytes = await drive.downloadById(rf.id);
      if (bytes == null) return false;
      await NotebookService().writeAtomicBytesPublic(file, bytes);
      drive.recordRemote(rel, rf.id, rf.headRevisionId);
      return true;
    }

    // Unchanged since we last reconciled it (same head, file on disk): skip.
    if (rf.headRevisionId != null &&
        drive.headForPath(rel) == rf.headRevisionId &&
        await file.exists()) {
      return false;
    }

    final remoteText = await drive.downloadJsonById(rf.id);
    if (remoteText == null) return false;
    final localText = await file.exists() ? await file.readAsString() : null;

    final MergeResult result;
    if (rel == 'notebooks.json') {
      // Per-account scoped merge: the account's Drive holds only its own
      // notebooks, so reconcile just those and preserve every other entry.
      // The main-isolate state it needs (default account, local-only set) is
      // captured as plain data so the merge itself is pure.
      final accountId = as.accountId;
      final defaultId = _defaultId;
      final localOnly = NotebookService().localOnlyNotebookIds();
      result = await _runMerge(
          localText,
          remoteText,
          () => _mergeIndexScoped(
              accountId, defaultId, localOnly, localText, remoteText));
    } else {
      result = await _runMerge(localText, remoteText,
          () => MergeEngine.reconcile(rel, localText, remoteText));
    }
    drive.recordRemote(rel, rf.id, rf.headRevisionId);

    if (result.changedLocal) {
      await NotebookService().writeAtomicPublic(file, result.content);
    }
    if (result.localContributed) {
      _markDirty(rel);
    }
    await _applyPurgeMarkers(rel, result.content);
    await _notifyOpenCanvas(rel, result.content);
    return result.changedLocal;
  }

  /// Combined local+remote JSON size above which a merge is worth one
  /// background-isolate hop (mirrors NotebookService's page-decode gate);
  /// smaller files merge inline — the isolate spawn + copy would cost more
  /// than the merge itself.
  static const int _kMergeOffloadChars = 256 * 1024;

  /// Runs a pure [merge] inline for small inputs, else via [Isolate.run];
  /// falls back to inline on any isolate failure — an isolate hiccup must
  /// never drop a merge. Static (like NotebookService's decode helper) and
  /// call sites build [merge] from locals + statics only, so nothing drags
  /// `this` across the isolate boundary.
  static Future<MergeResult> _runMerge(
    String? localText,
    String remoteText,
    MergeResult Function() merge,
  ) async {
    if ((localText?.length ?? 0) + remoteText.length < _kMergeOffloadChars) {
      return merge();
    }
    try {
      return await Isolate.run(merge);
    } catch (_) {
      return merge();
    }
  }

  /// Scoped `notebooks.json` merge for [accountId]: the ids this account owns
  /// (its local notebooks whose effective target is [accountId]) are reconciled
  /// with the account's subset-remote; local-only ids are excluded; all other
  /// entries (other accounts') are preserved untouched. Pure + isolate-safe:
  /// [defaultId]/[localOnly] are passed in rather than read from services.
  static MergeResult _mergeIndexScoped(
    String accountId,
    String? defaultId,
    Set<String> localOnly,
    String? localText,
    String remoteText,
  ) {
    final localMap = localText == null
        ? <String, dynamic>{}
        : jsonDecode(localText) as Map<String, dynamic>;
    final ownedIds = <String>{};
    for (final e in localMap.entries) {
      if (localOnly.contains(e.key)) continue;
      final t = ((e.value as Map<String, dynamic>)['syncTarget'] as String?) ??
          defaultId;
      if (t == accountId) ownedIds.add(e.key);
    }
    return MergeEngine.mergeNotebooksIndexScoped(
      localText,
      remoteText,
      ownedIds: ownedIds,
      excludeIds: localOnly,
    );
  }

  /// Routes a pulled file to the open canvas's live listener (if any).
  ///
  /// This fires exactly when the user has the pulled canvas open (likely
  /// drawing on it), so the dense-page `jsonDecode` is offloaded above the
  /// same size gate as the merge; `CanvasPage.fromJson` + the live merge stay
  /// on-main (they build/touch live ui/model objects).
  Future<void> _notifyOpenCanvas(String rel, String mergedContent) async {
    final m = RegExp(r'/canvases/([^/]+)/(canvas\.json|pages/[^/]+\.json)$')
        .firstMatch(rel);
    if (m == null) return;
    final listener = _canvasListeners[m.group(1)];
    if (listener == null) return;
    try {
      if (m.group(2) == 'canvas.json') {
        listener.onStructure();
      } else {
        final page = CanvasPage.fromJson(await _decodeJsonMap(mergedContent));
        listener.onPage(page);
      }
    } catch (e) {
      debugPrint('Live-merge listener error: $e');
    }
  }

  /// Decodes a JSON object, hopping to a background isolate above the merge
  /// size gate; inline below it and on any isolate failure.
  static Future<Map<String, dynamic>> _decodeJsonMap(String text) async {
    if (text.length < _kMergeOffloadChars) {
      return jsonDecode(text) as Map<String, dynamic>;
    }
    try {
      return await Isolate.run(
          () => jsonDecode(text) as Map<String, dynamic>);
    } catch (_) {
      return jsonDecode(text) as Map<String, dynamic>;
    }
  }

  // ── Journal persistence ──────────────────────────────────────────────────────

  Future<void> _loadJournal() async {
    try {
      _journalFile = File('${NotebookService().appDir.path}/sync_journal.json');
      if (await _journalFile!.exists()) {
        final map = jsonDecode(await _journalFile!.readAsString())
            as Map<String, dynamic>;
        _dirty.addAll(List<String>.from(map['dirty'] ?? const []));
        for (final e in List.from(map['purges'] ?? const [])) {
          _pendingPurges.add(Map<String, String>.from(e as Map));
        }
      }
    } catch (_) {}
  }

  Future<void> _saveJournal() async {
    try {
      _journalFile ??=
          File('${NotebookService().appDir.path}/sync_journal.json');
      await _journalFile!.writeAsString(
          jsonEncode({
            'dirty': _dirty.toList(),
            if (_pendingPurges.isNotEmpty) 'purges': _pendingPurges,
          }),
          flush: true);
    } catch (_) {}
  }

  // ── Remote purge (Drive-side folder deletion for purged items) ────────────

  /// Drive folder deletions still owed, `{nb: notebookId, path: relFolder}`.
  /// Persisted in the journal (survives kill/offline) and retried each push
  /// drain until they succeed; deletion is idempotent (404 = someone else's
  /// device already did it), so every device that sees a purge marker may
  /// safely queue the same folder.
  final List<Map<String, String>> _pendingPurges = [];

  /// Called by [NotebookService] when an item is purged — locally by the user
  /// or by a pulled marker. Prunes journaled uploads under the purged subtree
  /// (stale edits must never repopulate Drive), queues the remote folder
  /// deletions, and drops stale Drive-index entries.
  void onItemPurged(String notebookId, List<String> folderRelPaths) {
    for (final folder in folderRelPaths) {
      final p = '$folder/';
      _dirty.removeWhere((rel) => rel == folder || rel.startsWith(p));
      if (!_pendingPurges.any((e) => e['path'] == folder)) {
        _pendingPurges.add({'nb': notebookId, 'path': folder});
      }
      for (final id in _connectedAccountIds()) {
        DriveManager.forAccount(id).forgetUnder(folder);
      }
    }
    unawaited(_saveJournal());
    if (AuthService().isSignedIn) _armPush();
  }

  Future<void> _drainRemotePurges(
      Set<String> connected, String? defaultId) async {
    if (_pendingPurges.isEmpty) return;
    for (final entry in List.of(_pendingPurges)) {
      final target = await NotebookService()
          .syncTargetOfNotebook(entry['nb']!, defaultAccountId: defaultId);
      if (target == null || !connected.contains(target)) {
        continue; // that account isn't signed in here — retry later
      }
      try {
        await DriveManager.forAccount(target).deleteFolder(entry['path']!);
        _pendingPurges.remove(entry);
      } on SocketException {
        rethrow; // offline — stays queued
      } catch (e) {
        debugPrint('Remote purge failed (${entry['path']}): $e');
      }
    }
    await _saveJournal();
  }

  /// If a pulled/merged doc carries `purgedAt`, enact the purge on this
  /// device (wipe the content subtree, update the sync filters) — this is how
  /// a purge made on another device lands here. Idempotent via the
  /// purged-paths cache.
  Future<void> _applyPurgeMarkers(String rel, String mergedContent) async {
    try {
      final known = await NotebookService().purgedPaths();
      if (rel == 'notebooks.json') {
        final map = jsonDecode(mergedContent) as Map<String, dynamic>;
        for (final e in map.entries) {
          final j = e.value as Map<String, dynamic>;
          if (j['purgedAt'] != null && !known.contains(e.key)) {
            await NotebookService().applyNotebookPurgeLocally(e.key);
          }
        }
        return;
      }
      final m = RegExp(
              r'^notebooks/([^/]+)/sections/([^/]+)/(section\.json|canvases/([^/]+)/canvas\.json)$')
          .firstMatch(rel);
      if (m == null) return;
      final j = jsonDecode(mergedContent) as Map<String, dynamic>;
      if (j['purgedAt'] == null) return;
      final nb = m.group(1)!, sec = m.group(2)!;
      if (m.group(3) == 'section.json') {
        if (!known.contains('$nb/$sec')) {
          await NotebookService().applySectionPurgeLocally(nb, sec);
        }
      } else {
        final cv = m.group(4)!;
        if (!known.contains('$nb/$sec/$cv')) {
          await NotebookService().applyCanvasPurgeLocally(nb, sec, cv);
        }
      }
    } catch (e) {
      debugPrint('Purge marker application error: $e');
    }
  }

  // ── Helpers ──────────────────────────────────────────────────────────────────

  bool _isAsset(String rel) => rel.contains('/assets/');

  bool _isGone(Object e) => e.toString().contains('410');

  void _bumpData() => dataVersion.value = dataVersion.value + 1;

  void _finishOk() {
    lastSyncAt.value = DateTime.now();
    SettingsService().setLastSyncAt(lastSyncAt.value!);
    status.value = SyncStatus.idle;
  }
}
