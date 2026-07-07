import 'dart:convert';

import '../../models/canvas_page.dart';
import '../../models/element.dart';

/// Outcome of reconciling a local + remote version of one JSON file.
///
/// [content] is the JSON that should live on disk after the merge.
/// [changedLocal]     — merged ≠ local  ⇒ write [content] to disk.
/// [localContributed] — merged ≠ remote ⇒ re-upload [content] to Drive.
class MergeResult {
  final String content;
  final bool changedLocal;
  final bool localContributed;

  const MergeResult({
    required this.content,
    required this.changedLocal,
    required this.localContributed,
  });
}

/// Pure, side-effect-free merge logic for Sync v2.
///
/// Policy:
///   • `notebooks.json` — union map keyed by notebook id; per-id LWW by
///     `(rev, updatedAt, deviceId)`. Union means two devices' distinct
///     notebooks both survive a first sync (no whole-file clobber).
///   • `section.json` / `canvas.json` — single-document LWW by the same tuple.
///   • page files — set-union of immutable strokes + grow-only erase
///     tombstones, LWW for text/image objects and page background.
///   • assets — content-addressed and immutable; handled outside the engine
///     (download-if-missing, never merged).
class MergeEngine {
  const MergeEngine._();

  /// Compares two metadata tuples to determine which version wins
  /// deterministically. Returns > 0 if A wins, < 0 if B wins, 0 if identical.
  /// Tie-breaker rule: `rev` > `updatedAt` > `deviceId`.
  static int compareRevisions({
    required int revA,
    required DateTime updatedAtA,
    required String deviceIdA,
    required int revB,
    required DateTime updatedAtB,
    required String deviceIdB,
  }) {
    if (revA != revB) return revA.compareTo(revB);
    final timeA = updatedAtA.millisecondsSinceEpoch;
    final timeB = updatedAtB.millisecondsSinceEpoch;
    if (timeA != timeB) return timeA.compareTo(timeB);
    return deviceIdA.compareTo(deviceIdB);
  }

  /// True if A is strictly newer than B.
  static bool wins(
    int revA,
    DateTime updatedAtA,
    String deviceIdA,
    int revB,
    DateTime updatedAtB,
    String deviceIdB,
  ) {
    return compareRevisions(
          revA: revA,
          updatedAtA: updatedAtA,
          deviceIdA: deviceIdA,
          revB: revB,
          updatedAtB: updatedAtB,
          deviceIdB: deviceIdB,
        ) >
        0;
  }

  // ── Dispatcher ─────────────────────────────────────────────────────────

  /// Reconciles the local and remote text of a synced JSON file identified by
  /// its forward-slash relative path. [local] is null when the file does not
  /// exist locally yet (fresh-device bootstrap).
  static MergeResult reconcile(String relPath, String? local, String remote) {
    if (relPath == 'notebooks.json') {
      return mergeNotebooksIndex(local, remote);
    }
    if (relPath.endsWith('/pages/') || _isPagePath(relPath)) {
      return _mergePageJson(local, remote);
    }
    // section.json, canvas.json, and any other enveloped single document.
    return _mergeSingleDoc(local, remote);
  }

  static bool _isPagePath(String relPath) =>
      relPath.contains('/pages/') && relPath.endsWith('.json');

  // ── notebooks.json (union map) ───────────────────────────────────────────

  static MergeResult mergeNotebooksIndex(String? local, String remote) {
    final Map<String, dynamic> localMap = _decodeMap(local);
    final Map<String, dynamic> remoteMap = _decodeMap(remote);

    final merged = <String, dynamic>{};
    var localContributed = false;
    var changedLocal = false;

    final ids = <String>{...localMap.keys, ...remoteMap.keys};
    for (final id in ids) {
      final l = localMap[id] as Map<String, dynamic>?;
      final r = remoteMap[id] as Map<String, dynamic>?;
      if (l == null) {
        merged[id] = r;
        changedLocal = true; // remote has a notebook we lack
      } else if (r == null) {
        merged[id] = l;
        localContributed = true; // we have a notebook remote lacks
      } else {
        final localWins = _envelopeWins(l, r);
        merged[id] = localWins ? l : r;
        if (localWins && !_sameEnvelope(l, r)) localContributed = true;
        if (!localWins && !_sameEnvelope(l, r)) changedLocal = true;
      }
    }

    return MergeResult(
      content: jsonEncode(merged),
      changedLocal: changedLocal,
      localContributed: localContributed,
    );
  }

  // ── section.json / canvas.json (single doc LWW) ──────────────────────────

  static MergeResult _mergeSingleDoc(String? local, String remote) {
    if (local == null) {
      return MergeResult(
        content: remote,
        changedLocal: true,
        localContributed: false,
      );
    }
    final l = _decodeMap(local);
    final r = _decodeMap(remote);
    if (_sameEnvelope(l, r)) {
      return MergeResult(
        content: remote,
        changedLocal: false,
        localContributed: false,
      );
    }
    final localWins = _envelopeWins(l, r);
    return MergeResult(
      content: localWins ? local : remote,
      changedLocal: !localWins,
      localContributed: localWins,
    );
  }

  // ── page files (set union) ───────────────────────────────────────────────

  static MergeResult _mergePageJson(String? local, String remote) {
    if (local == null) {
      return MergeResult(
        content: remote,
        changedLocal: true,
        localContributed: false,
      );
    }
    final localPage = CanvasPage.fromJson(_decodeMap(local));
    final remotePage = CanvasPage.fromJson(_decodeMap(remote));
    final merged = mergePage(localPage, remotePage);

    final mergedSig = _pageSignature(merged);
    final localSig = _pageSignature(localPage);
    final remoteSig = _pageSignature(remotePage);

    return MergeResult(
      content: jsonEncode(merged.toJson()),
      changedLocal: mergedSig != localSig,
      localContributed: mergedSig != remoteSig,
    );
  }

  /// Merges two CanvasPages into a new instance (Set Union for strokes/erased,
  /// LWW for objects/background). Pure — does not mutate [local] or [remote].
  static CanvasPage mergePage(CanvasPage local, CanvasPage remote) {
    final bool remotePageWins = wins(
      remote.rev,
      remote.updatedAt,
      remote.deviceId,
      local.rev,
      local.updatedAt,
      local.deviceId,
    );

    // Set Union for strokes (id ⇒ immutable points; props resolved by winner).
    final Map<String, StrokeElement> mergedStrokes = {};
    for (final s in local.strokes) {
      mergedStrokes[s.id] = s;
    }
    for (final rs in remote.strokes) {
      final ls = mergedStrokes[rs.id];
      if (ls == null ||
          wins(rs.rev, rs.updatedAt, rs.deviceId, ls.rev, ls.updatedAt,
              ls.deviceId)) {
        mergedStrokes[rs.id] = rs;
      }
    }

    // Grow-only union for erase tombstones.
    final Map<String, EraseTombstone> mergedErased = {};
    for (final e in local.erased) {
      mergedErased[e.strokeId] = e;
    }
    for (final re in remote.erased) {
      final le = mergedErased[re.strokeId];
      if (le == null ||
          wins(re.rev, re.erasedAt, re.deviceId, le.rev, le.erasedAt,
              le.deviceId)) {
        mergedErased[re.strokeId] = re;
      }
    }

    // Erased strokes stay out of `strokes` (but their tombstone lives on).
    final filteredStrokes = mergedStrokes.values
        .where((s) => !mergedErased.containsKey(s.id))
        .toList();

    // LWW for objects (text/image) among the live copies on each side.
    final Map<String, CanvasElement> mergedObjects = {};
    for (final o in local.objects) {
      mergedObjects[o.id] = o;
    }
    for (final ro in remote.objects) {
      final lo = mergedObjects[ro.id];
      if (lo == null ||
          wins(ro.rev, ro.updatedAt, ro.deviceId, lo.rev, lo.updatedAt,
              lo.deviceId)) {
        mergedObjects[ro.id] = ro;
      }
    }

    // Grow-only union for object-delete tombstones — same idea as [erased]
    // for strokes. An object present on one side but tombstoned on the other
    // must stay gone; it must never resurrect just because one side's copy
    // still lists it live.
    final Map<String, EraseTombstone> mergedDeletedObjects = {};
    for (final d in local.deletedObjects) {
      mergedDeletedObjects[d.strokeId] = d;
    }
    for (final rd in remote.deletedObjects) {
      final ld = mergedDeletedObjects[rd.strokeId];
      if (ld == null ||
          wins(rd.rev, rd.erasedAt, rd.deviceId, ld.rev, ld.erasedAt,
              ld.deviceId)) {
        mergedDeletedObjects[rd.strokeId] = rd;
      }
    }

    final filteredObjects = mergedObjects.values
        .where((o) => !mergedDeletedObjects.containsKey(o.id))
        .toList();

    return CanvasPage(
      schemaVersion:
          remotePageWins ? remote.schemaVersion : local.schemaVersion,
      id: local.id,
      rev: remotePageWins ? remote.rev : local.rev,
      updatedAt: remotePageWins ? remote.updatedAt : local.updatedAt,
      deviceId: remotePageWins ? remote.deviceId : local.deviceId,
      deletedAt: remotePageWins ? remote.deletedAt : local.deletedAt,
      width: remotePageWins ? remote.width : local.width,
      height: remotePageWins ? remote.height : local.height,
      background: remotePageWins ? remote.background : local.background,
      source: remotePageWins ? remote.source : local.source,
      strokes: filteredStrokes,
      erased: mergedErased.values.toList(),
      objects: filteredObjects,
      deletedObjects: mergedDeletedObjects.values.toList(),
    );
  }

  // ── helpers ───────────────────────────────────────────────────────────────

  /// A content signature that ignores element ordering but captures which
  /// strokes/objects/tombstones (and revisions) are present, plus page meta.
  /// Public so the live-merge path (open canvas receiving a pulled page) can
  /// decide whether anything actually changed / whether local contributed.
  static String pageSignature(CanvasPage p) => _pageSignature(p);

  static String _pageSignature(CanvasPage p) {
    final strokes = p.strokes.map((s) => '${s.id}:${s.rev}').toList()..sort();
    final erased = p.erased.map((e) => '${e.strokeId}:${e.rev}').toList()
      ..sort();
    final objects = p.objects.map((o) => '${o.id}:${o.rev}').toList()..sort();
    final deletedObjects =
        p.deletedObjects.map((e) => '${e.strokeId}:${e.rev}').toList()..sort();
    return [
      'w${p.width}h${p.height}',
      'bg${p.background.color.toARGB32()}/${p.background.pattern.name}',
      'del${p.deletedAt?.millisecondsSinceEpoch}',
      's:${strokes.join(',')}',
      'e:${erased.join(',')}',
      'o:${objects.join(',')}',
      'do:${deletedObjects.join(',')}',
    ].join('|');
  }

  static bool _envelopeWins(Map<String, dynamic> a, Map<String, dynamic> b) {
    return compareRevisions(
          revA: (a['rev'] as num?)?.toInt() ?? 1,
          updatedAtA: _ts(a['updatedAt']),
          deviceIdA: a['deviceId'] as String? ?? 'unknown',
          revB: (b['rev'] as num?)?.toInt() ?? 1,
          updatedAtB: _ts(b['updatedAt']),
          deviceIdB: b['deviceId'] as String? ?? 'unknown',
        ) >
        0;
  }

  static bool _sameEnvelope(Map<String, dynamic> a, Map<String, dynamic> b) {
    return ((a['rev'] as num?)?.toInt() ?? 1) ==
            ((b['rev'] as num?)?.toInt() ?? 1) &&
        _ts(a['updatedAt']) == _ts(b['updatedAt']) &&
        (a['deviceId'] as String? ?? 'unknown') ==
            (b['deviceId'] as String? ?? 'unknown');
  }

  static DateTime _ts(dynamic v) => v is num
      ? DateTime.fromMillisecondsSinceEpoch(v.toInt())
      : DateTime.fromMillisecondsSinceEpoch(0);

  static Map<String, dynamic> _decodeMap(String? s) {
    if (s == null || s.isEmpty) return {};
    try {
      final d = jsonDecode(s);
      return d is Map<String, dynamic> ? d : {};
    } catch (_) {
      return {};
    }
  }
}
