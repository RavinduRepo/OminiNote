import 'dart:async';
import 'dart:convert';
import 'dart:io';
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

  const CanvasSyncListener({required this.onPage, required this.onStructure});
}

/// Orchestrates two-way sync between local storage and Google Drive.
///
/// The Drive tree mirrors local storage. Each file carries a `(rev, updatedAt,
/// deviceId)` envelope; the [MergeEngine] reconciles remote and local versions
/// so nothing is silently lost:
///
/// * **Bootstrap / repair** ([fullResync]) — on sign-in (and via "Repair
///   sync") the whole Drive tree is listed and reconciled with local both ways.
///   This is what lets a fresh device download everything and an existing
///   device contribute what Drive lacks, without clobbering either side.
/// * **Push** — every local atomic write marks a relative path dirty in a
///   persistent journal (`sync_journal.json`); dirty files are debounced and
///   uploaded with retry + backoff. The journal survives process death.
/// * **Pull** — the Drive Changes API is polled every 30 s. Known files are
///   downloaded and merged in place; an unknown file id (something a *new*
///   device created) triggers a debounced [fullResync]. Our own uploads are
///   skipped via `headRevisionId` echo suppression.
class SyncService {
  static final SyncService _instance = SyncService._internal();
  factory SyncService() => _instance;
  SyncService._internal();

  final ValueNotifier<SyncStatus> status = ValueNotifier(SyncStatus.idle);
  final ValueNotifier<DateTime?> lastSyncAt = ValueNotifier(null);

  /// Bumped whenever a remote change is written to local disk, so screens can
  /// reload their lists / pages.
  final ValueNotifier<int> dataVersion = ValueNotifier(0);

  // Persistent dirty journal: relative paths awaiting upload.
  final Set<String> _dirty = {};
  File? _journalFile;

  // Open canvases wanting live merge of pulled changes, keyed by canvas id.
  final Map<String, CanvasSyncListener> _canvasListeners = {};

  void registerCanvasListener(String canvasId, CanvasSyncListener l) =>
      _canvasListeners[canvasId] = l;

  void unregisterCanvasListener(String canvasId) =>
      _canvasListeners.remove(canvasId);

  Timer? _pushDebounce;
  Timer? _pollTimer;
  Timer? _resyncDebounce;
  bool _pushing = false;
  bool _pulling = false;
  bool _resyncing = false;

  // 15 s: changes.list is a cheap delta call; halving the worst-case
  // cross-device latency is worth the extra poll.
  static const _kPollInterval = Duration(seconds: 15);
  static const _kPushDebounce = Duration(milliseconds: 1500);

  // ── Init / dispose ──────────────────────────────────────────────────────────

  Future<void> init() async {
    await _loadJournal();
    lastSyncAt.value = SettingsService().lastSyncAt;
    AuthService().account.addListener(_onAuthChanged);
    if (AuthService().isSignedIn) unawaited(_onSignedIn());
  }

  void dispose() {
    _pushDebounce?.cancel();
    _pollTimer?.cancel();
    _resyncDebounce?.cancel();
    AuthService().account.removeListener(_onAuthChanged);
  }

  void _onAuthChanged() {
    if (AuthService().isSignedIn) {
      unawaited(_onSignedIn());
    } else {
      _pollTimer?.cancel();
      status.value = SyncStatus.idle;
    }
  }

  Future<void> _onSignedIn() async {
    await DriveService().init();
    // Bootstrap (full download+merge) only when this install has never synced —
    // i.e. no changes token yet, or no local Drive index to poll against.
    // Otherwise resume from the stored token: cheap incremental catch-up plus a
    // journal replay of anything edited while offline.
    final needsBootstrap = SettingsService().driveChangesToken.isEmpty ||
        !DriveService().hasIndex;
    if (needsBootstrap) {
      await fullResync();
    } else {
      await _doPull();
      if (_dirty.isNotEmpty) unawaited(_flushPush());
    }
    _startPolling();
  }

  void _startPolling() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(_kPollInterval, (_) => _doPull());
  }

  // ── Public triggers ─────────────────────────────────────────────────────────

  /// Manual "Sync now": push pending, then pull deltas.
  Future<void> syncNow() async {
    if (!AuthService().isSignedIn) return;
    await _flushPush();
    await _doPull();
  }

  /// "Repair sync" — full two-way reconcile against the whole Drive tree.
  Future<void> repair() => fullResync();

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
    _dirty.add(rel);
    unawaited(_saveJournal());
    if (!AuthService().isSignedIn) return;
    _pushDebounce?.cancel();
    _pushDebounce = Timer(_kPushDebounce, _flushPush);
  }

  Future<void> _flushPush() async {
    if (_pushing || !AuthService().isSignedIn || _dirty.isEmpty) return;
    _pushing = true;
    status.value = SyncStatus.syncing;
    try {
      // Snapshot so concurrent edits during the drain aren't lost.
      final pending = List<String>.from(_dirty);
      for (final rel in pending) {
        final file = NotebookService().fileForRelPath(rel);
        if (!await file.exists()) {
          _dirty.remove(rel);
          continue;
        }
        await _uploadWithRetry(rel, file);
        _dirty.remove(rel);
        await _saveJournal();
      }
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
        _pushDebounce?.cancel();
        _pushDebounce = Timer(_kPushDebounce, _flushPush);
      }
    }
  }

  Future<void> _uploadWithRetry(String rel, File file, {int attempt = 0}) async {
    try {
      if (_isAsset(rel)) {
        await DriveService().uploadBinary(rel, await file.readAsBytes());
      } else {
        await DriveService().uploadJson(rel, await file.readAsString());
      }
    } catch (e) {
      if (e is SocketException) rethrow;
      if (attempt >= 4) rethrow;
      // Exponential backoff with jitter: ~2,4,8,16 s.
      final base = (2 << attempt) * 1000;
      await Future.delayed(Duration(milliseconds: base + Random().nextInt(500)));
      await _uploadWithRetry(rel, file, attempt: attempt + 1);
    }
  }

  // ── Pull (incremental) ────────────────────────────────────────────────────────

  Future<void> _doPull() async {
    if (!AuthService().isSignedIn || _pulling || _resyncing) return;
    final token = SettingsService().driveChangesToken;
    if (token.isEmpty) {
      await fullResync();
      return;
    }
    _pulling = true;
    status.value = SyncStatus.syncing;
    try {
      final res = await DriveService().pollChanges(token);
      var changed = false;
      for (final c in res.changes) {
        if (c.mimeType == 'application/vnd.google-apps.folder') continue;
        if (await _applyChange(c)) changed = true;
      }
      await SettingsService().setDriveChangesToken(res.nextPageToken);
      _finishOk();
      if (changed) _bumpData();
      if (_dirty.isNotEmpty) _markDirty(_dirty.first); // re-arm push
    } on SocketException {
      status.value = SyncStatus.offline;
    } catch (e) {
      if (_isGone(e)) {
        _pulling = false;
        await fullResync();
        return;
      }
      debugPrint('Sync pull error: $e');
      status.value = SyncStatus.error;
    } finally {
      _pulling = false;
    }
  }

  Future<bool> _applyChange(DriveChange c) async {
    if (c.removed) return false; // deletions propagate via structural merge
    var rel = DriveService().relPathForFileId(c.fileId);
    if (rel == null) {
      // A file this device has never seen — created on another device.
      // Resolve just this file via its parent chain (a couple of cheap
      // files.get calls) instead of forcing a full-tree resync; the old
      // resync-only path was heavy, raced with further changes, and losing it
      // meant the file never arrived until a manual "Repair sync".
      final resolved = await DriveService().resolveFileId(c.fileId);
      if (resolved == null) {
        _scheduleResync(); // genuinely can't place it — fall back
        return false;
      }
      rel = DriveService().relPathForFileId(c.fileId);
      if (rel == null) return false;
    }
    if (!NotebookService.isSyncedRelPath(rel)) return false;
    // Echo suppression: skip our own most-recent upload.
    if (c.headRevisionId != null &&
        DriveService().headForPath(rel) == c.headRevisionId) {
      return false;
    }
    return _pullFile(
      rel,
      RemoteFile(
        id: c.fileId,
        headRevisionId: c.headRevisionId,
        mimeType: c.mimeType,
      ),
    );
  }

  // ── Full resync (bootstrap / repair / 410 recovery) ──────────────────────────

  Future<void> fullResync() async {
    if (!AuthService().isSignedIn || _resyncing) return;
    _resyncing = true;
    status.value = SyncStatus.syncing;
    try {
      // Take the changes baseline BEFORE listing: anything pushed by another
      // device while this (possibly long) resync runs is then re-delivered by
      // the next poll. Taking it after the listing silently skipped those
      // changes forever — the "have to press Repair again" loop.
      final tok = await DriveService().getChangesStartToken();

      final remote = await DriveService().listAllFiles();
      final localPaths = await NotebookService().listSyncedRelPaths();

      var changed = false;
      for (final entry in remote.entries) {
        if (await _pullFile(entry.key, entry.value)) changed = true;
      }
      // Anything local that Drive lacks gets pushed.
      for (final rel in localPaths) {
        if (!remote.containsKey(rel)) _dirty.add(rel);
      }
      await _saveJournal();

      await SettingsService().setDriveChangesToken(tok);

      _resyncing = false;
      await _flushPush();
      _finishOk();
      if (changed) _bumpData();
      // Best point to sweep old tombstones: everything just reconciled, so
      // what's left tombstoned+expired really is old news everywhere this
      // device can see.
      unawaited(NotebookService().runGarbageCollection());
    } on SocketException {
      status.value = SyncStatus.offline;
    } catch (e) {
      debugPrint('Sync resync error: $e');
      status.value = SyncStatus.error;
    } finally {
      _resyncing = false;
    }
  }

  void _scheduleResync() {
    _resyncDebounce?.cancel();
    _resyncDebounce = Timer(const Duration(seconds: 3), fullResync);
  }

  // ── Reconcile one file from Drive → local ────────────────────────────────────

  /// Downloads [rf] and merges it into the local file at [rel]. Returns true if
  /// local disk changed. Records the head for echo suppression and marks the
  /// path dirty when the merge produced something Drive still lacks.
  Future<bool> _pullFile(String rel, RemoteFile rf) async {
    final file = NotebookService().fileForRelPath(rel);

    if (_isAsset(rel)) {
      // Content-addressed & immutable: fetch only if we don't have it.
      if (await file.exists()) {
        DriveService().recordRemote(rel, rf.id, rf.headRevisionId);
        return false;
      }
      final bytes = await DriveService().downloadById(rf.id);
      if (bytes == null) return false;
      await NotebookService().writeAtomicBytesPublic(file, bytes);
      DriveService().recordRemote(rel, rf.id, rf.headRevisionId);
      return true;
    }

    // Unchanged since we last reconciled it (same head, file on disk): skip
    // the download. Makes fullResync/Repair proportional to what actually
    // changed instead of re-downloading the entire tree every time.
    if (rf.headRevisionId != null &&
        DriveService().headForPath(rel) == rf.headRevisionId &&
        await file.exists()) {
      return false;
    }

    final remoteText = await DriveService().downloadJsonById(rf.id);
    if (remoteText == null) return false;
    final localText = await file.exists() ? await file.readAsString() : null;

    final result = MergeEngine.reconcile(rel, localText, remoteText);
    DriveService().recordRemote(rel, rf.id, rf.headRevisionId);

    if (result.changedLocal) {
      await NotebookService().writeAtomicPublic(file, result.content);
    }
    if (result.localContributed) {
      _markDirty(rel);
    }
    _notifyOpenCanvas(rel, result.content);
    return result.changedLocal;
  }

  /// Routes a pulled file to the open canvas's live listener (if any), so the
  /// in-memory controller merges the change instead of its next autosave
  /// clobbering the merged file on disk with stale state.
  void _notifyOpenCanvas(String rel, String mergedContent) {
    // rel: notebooks/<nb>/sections/<sec>/canvases/<cid>/(canvas.json|pages/<pid>.json)
    final m = RegExp(r'/canvases/([^/]+)/(canvas\.json|pages/[^/]+\.json)$')
        .firstMatch(rel);
    if (m == null) return;
    final listener = _canvasListeners[m.group(1)];
    if (listener == null) return;
    try {
      if (m.group(2) == 'canvas.json') {
        listener.onStructure();
      } else {
        final page = CanvasPage.fromJson(
            jsonDecode(mergedContent) as Map<String, dynamic>);
        listener.onPage(page);
      }
    } catch (e) {
      debugPrint('Live-merge listener error: $e');
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
      }
    } catch (_) {}
  }

  Future<void> _saveJournal() async {
    try {
      _journalFile ??=
          File('${NotebookService().appDir.path}/sync_journal.json');
      await _journalFile!
          .writeAsString(jsonEncode({'dirty': _dirty.toList()}), flush: true);
    } catch (_) {}
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
