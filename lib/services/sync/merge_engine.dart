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
///   • `section.json` / `canvas.json` — **structure-aware** merge: LWW by the
///     same tuple for all scalar/metadata fields, but the *membership* lists
///     (a section's canvas leaves; a canvas's page rows, bookmarks and
///     attachments) are **unioned** so a canvas/page/bookmark added
///     concurrently on two devices is never dropped by the whole-doc clobber.
///     The losing side's new items are appended (leaves at the top level,
///     pages as new rows at the bottom) with deterministic ids/order so both
///     devices converge to byte-identical output. Deletion is unaffected:
///     item-level tombstones (`deletedAt`) in the separate section/canvas/page
///     files remain the durable delete signal, and the UI already filters
///     leaves whose backing item is tombstoned — so a unioned-in leaf that
///     points at a deleted item is invisible, never a resurrection. Concurrent
///     *folder* (super-section) grouping stays LWW (a loser's brand-new folder
///     loses its grouping, but its canvases survive at the top level).
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
    if (relPath.endsWith('/section.json')) {
      return _mergeStructuredDoc(local, remote, _foldSectionMembership);
    }
    if (relPath.endsWith('/canvas.json')) {
      return _mergeStructuredDoc(local, remote, _foldCanvasMembership);
    }
    // Any other enveloped single document.
    return _mergeSingleDoc(local, remote);
  }

  static bool _isPagePath(String relPath) =>
      relPath.contains('/pages/') && relPath.endsWith('.json');

  // ── Purge override (grow-only, terminal) ─────────────────────────────────

  /// Once either side of a doc merge carries `purgedAt`, the merged doc keeps
  /// it (earliest if both) and stays deleted — purge is terminal, so a restore
  /// racing a purge loses deterministically regardless of the LWW tuple.
  /// Returns null when the winner already reflects the purge (no override
  /// needed); callers must flag both `changedLocal` and `localContributed`
  /// when an override is returned, so the corrected doc propagates both ways.
  static Map<String, dynamic>? _withPurgeOverride(
    Map<String, dynamic> winner,
    Map<String, dynamic>? l,
    Map<String, dynamic>? r,
  ) {
    final lp = l?['purgedAt'] as num?;
    final rp = r?['purgedAt'] as num?;
    if (lp == null && rp == null) return null;
    final purged =
        (lp != null && rp != null) ? (lp < rp ? lp : rp) : (lp ?? rp)!;
    if (winner['purgedAt'] == purged && winner['deletedAt'] != null) {
      return null;
    }
    final out = Map<String, dynamic>.from(winner);
    out['purgedAt'] = purged;
    out['deletedAt'] = (winner['deletedAt'] as num?) ?? purged;
    return out;
  }

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
        final winner = localWins ? l : r;
        final purged = _withPurgeOverride(winner, l, r);
        merged[id] = purged ?? winner;
        if (purged != null) {
          localContributed = true;
          changedLocal = true;
        } else {
          if (localWins && !_sameEnvelope(l, r)) localContributed = true;
          if (!localWins && !_sameEnvelope(l, r)) changedLocal = true;
        }
      }
    }

    return MergeResult(
      content: jsonEncode(merged),
      changedLocal: changedLocal,
      localContributed: localContributed,
    );
  }

  /// Phase 2 per-account variant. Each account's Drive holds a `notebooks.json`
  /// with only **that account's** notebooks, so [remote] is a *subset* of the
  /// full local index. This reconciles only the ids the account is responsible
  /// for — [ownedIds] (its local notebooks) plus [remote]'s ids — and leaves
  /// every other entry (other accounts', local-only) exactly as local. Ids in
  /// [excludeIds] (this device's local-only) are preserved untouched even if
  /// they appear in [remote].
  ///
  /// Crucially, untouched entries do **not** set `changedLocal`/`localContributed`.
  /// The plain union merge would flag every foreign notebook as "local has
  /// something remote lacks" on every pull → a perpetual re-push loop; scoping
  /// the comparison to the account's own notebooks stops that.
  static MergeResult mergeNotebooksIndexScoped(
    String? local,
    String remote, {
    required Set<String> ownedIds,
    Set<String> excludeIds = const {},
  }) {
    final Map<String, dynamic> localMap = _decodeMap(local);
    final Map<String, dynamic> remoteMap = _decodeMap(remote);

    final merged = <String, dynamic>{...localMap}; // preserve everything local
    var localContributed = false;
    var changedLocal = false;

    final ids = <String>{...ownedIds, ...remoteMap.keys}
      ..removeAll(excludeIds);
    for (final id in ids) {
      final l = localMap[id] as Map<String, dynamic>?;
      final r = remoteMap[id] as Map<String, dynamic>?;
      if (l == null && r == null) continue;
      if (l == null) {
        merged[id] = r;
        changedLocal = true; // account's Drive has a notebook we lack
      } else if (r == null) {
        merged[id] = l;
        localContributed = true; // ours, the account's Drive lacks it → push
      } else {
        final localWins = _envelopeWins(l, r);
        final winner = localWins ? l : r;
        final purged = _withPurgeOverride(winner, l, r);
        merged[id] = purged ?? winner;
        if (purged != null) {
          localContributed = true;
          changedLocal = true;
        } else {
          if (localWins && !_sameEnvelope(l, r)) localContributed = true;
          if (!localWins && !_sameEnvelope(l, r)) changedLocal = true;
        }
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
    final winner = localWins ? l : r;
    final purged = _withPurgeOverride(winner, l, r);
    if (purged != null) {
      return MergeResult(
        content: jsonEncode(purged),
        changedLocal: true,
        localContributed: true,
      );
    }
    return MergeResult(
      content: localWins ? local : remote,
      changedLocal: !localWins,
      localContributed: localWins,
    );
  }

  // ── section.json / canvas.json (LWW metadata + membership union) ──────────

  /// Merges an enveloped structural doc: LWW picks the winner for every scalar
  /// field, then [foldMembership] folds the loser's *new* membership (canvas
  /// leaves / page rows / bookmarks / attachments) into the winner so nothing
  /// added concurrently is lost. Purge stays terminal (content is gone, so no
  /// membership to union). The merge is symmetric and does **not** bump `rev`,
  /// so both devices compute byte-identical output and converge in one round
  /// (a subsequent merge of the identical docs is a no-op → no push loop).
  static MergeResult _mergeStructuredDoc(
    String? local,
    String remote,
    void Function(Map<String, dynamic> merged, Map<String, dynamic> loser)
        foldMembership,
  ) {
    if (local == null) {
      return MergeResult(
        content: remote,
        changedLocal: true,
        localContributed: false,
      );
    }
    final l = _decodeMap(local);
    final r = _decodeMap(remote);
    final localWins = _envelopeWins(l, r);
    final winner = localWins ? l : r;

    // Terminal purge: content is permanently stripped, so there is no
    // membership to union — fall back to the single-doc purge/LWW handling.
    if (l['purgedAt'] != null || r['purgedAt'] != null) {
      final purged = _withPurgeOverride(winner, l, r);
      if (purged != null) {
        return MergeResult(
          content: jsonEncode(purged),
          changedLocal: true,
          localContributed: true,
        );
      }
      return MergeResult(
        content: localWins ? local : remote,
        changedLocal: !localWins,
        localContributed: localWins,
      );
    }

    final loser = localWins ? r : l;
    final merged = Map<String, dynamic>.from(winner);
    foldMembership(merged, loser);

    return MergeResult(
      content: jsonEncode(merged),
      changedLocal: !_jsonEquals(merged, l),
      localContributed: !_jsonEquals(merged, r),
    );
  }

  /// Union a section's canvas leaves: any leaf refId present on the loser but
  /// not the winner is appended as a top-level [LeafNode] (deterministic id
  /// order). Folder grouping is the winner's (LWW) — see the class policy.
  static void _foldSectionMembership(
    Map<String, dynamic> merged,
    Map<String, dynamic> loser,
  ) {
    final winnerNodes = (merged['nodes'] as List?) ?? const [];
    final winnerLeaves = <String>{};
    final winnerFolders = <String>{};
    _collectNodeIds(winnerNodes, winnerLeaves, winnerFolders);
    final loserLeaves = <String>{};
    final ignoredFolders = <String>{};
    _collectNodeIds(
        (loser['nodes'] as List?) ?? const [], loserLeaves, ignoredFolders);

    final orphans = loserLeaves.difference(winnerLeaves).toList()..sort();
    if (orphans.isEmpty) return;
    merged['nodes'] = [
      ...winnerNodes,
      for (final id in orphans) {'type': 'leaf', 'refId': id},
    ];
  }

  /// Union a canvas's structure: pageIds absent from the winner's rows are
  /// appended as new single-page rows (stable, derived row ids so both devices
  /// agree); bookmarks and attachments are unioned by id. A unioned-in page
  /// whose page file is tombstoned is pruned by `loadPages`, so this never
  /// resurrects a deleted page.
  static void _foldCanvasMembership(
    Map<String, dynamic> merged,
    Map<String, dynamic> loser,
  ) {
    final winnerRows = (merged['rows'] as List?) ?? const [];
    final winnerPages = <String>{};
    for (final row in winnerRows) {
      for (final pid in (row is Map ? row['pageIds'] as List? : null) ??
          const []) {
        if (pid is String) winnerPages.add(pid);
      }
    }
    final loserPages = <String>{};
    for (final row in (loser['rows'] as List?) ?? const []) {
      for (final pid in (row is Map ? row['pageIds'] as List? : null) ??
          const []) {
        if (pid is String) loserPages.add(pid);
      }
    }
    final orphanPages = loserPages.difference(winnerPages).toList()..sort();
    if (orphanPages.isNotEmpty) {
      merged['rows'] = [
        ...winnerRows,
        for (final pid in orphanPages)
          {'id': 'r-$pid', 'pageIds': [pid]},
      ];
    }

    final bmExtra = _extraById(merged['bookmarks'], loser['bookmarks']);
    if (bmExtra.isNotEmpty) {
      merged['bookmarks'] = [
        ...((merged['bookmarks'] as List?) ?? const []),
        ...bmExtra,
      ];
    }
    final atExtra = _extraById(merged['attachments'], loser['attachments']);
    if (atExtra.isNotEmpty) {
      merged['attachments'] = [
        ...((merged['attachments'] as List?) ?? const []),
        ...atExtra,
      ];
    }
  }

  /// The elements of [loserList] (id-keyed maps) whose `id` is absent from
  /// [winnerList]. Returns const-empty when there is nothing to add, so the
  /// caller can leave the winner's field byte-identical (no spurious diff).
  static List _extraById(dynamic winnerList, dynamic loserList) {
    final w = (winnerList as List?) ?? const [];
    final l = (loserList as List?) ?? const [];
    if (l.isEmpty) return const [];
    final ids = {for (final e in w) if (e is Map) e['id']};
    return [for (final e in l) if (e is Map && !ids.contains(e['id'])) e];
  }

  /// Collects leaf refIds and folder ids from a nodes tree (JSON form),
  /// depth-first, accepting the legacy `group`/`sectionId` tags.
  static void _collectNodeIds(
    List nodes,
    Set<String> leaves,
    Set<String> folders,
  ) {
    for (final n in nodes) {
      if (n is! Map) continue;
      final type = n['type'];
      if (type == 'folder' || type == 'group') {
        final id = n['id'];
        if (id is String) folders.add(id);
        final children = n['children'];
        if (children is List) _collectNodeIds(children, leaves, folders);
      } else {
        final ref = n['refId'] ?? n['sectionId'] ?? n['id'];
        if (ref is String && ref.isNotEmpty) leaves.add(ref);
      }
    }
  }

  /// Deep structural equality for JSON-decoded maps/lists/scalars — used to set
  /// the changed/contributed flags without depending on key order.
  static bool _jsonEquals(dynamic a, dynamic b) {
    if (identical(a, b)) return true;
    if (a is Map && b is Map) {
      if (a.length != b.length) return false;
      for (final k in a.keys) {
        if (!b.containsKey(k) || !_jsonEquals(a[k], b[k])) return false;
      }
      return true;
    }
    if (a is List && b is List) {
      if (a.length != b.length) return false;
      for (var i = 0; i < a.length; i++) {
        if (!_jsonEquals(a[i], b[i])) return false;
      }
      return true;
    }
    return a == b;
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

    // Terminal purge: once either side is purged, the merged page keeps the
    // purge (earliest wins) and its content stays permanently stripped —
    // exactly like [_withPurgeOverride] for the enveloped docs. A purge beats
    // a concurrent restore or a stale device's live copy deterministically,
    // regardless of the LWW tuple. The tiny stub survives forever so it can't
    // resurrect.
    final lp = local.purgedAt, rp = remote.purgedAt;
    if (lp != null || rp != null) {
      final purged = (lp != null && rp != null)
          ? (lp.isBefore(rp) ? lp : rp)
          : (lp ?? rp)!;
      final meta = remotePageWins ? remote : local;
      return CanvasPage(
        schemaVersion: meta.schemaVersion,
        id: local.id,
        rev: remotePageWins ? remote.rev : local.rev,
        updatedAt: remotePageWins ? remote.updatedAt : local.updatedAt,
        deviceId: remotePageWins ? remote.deviceId : local.deviceId,
        deletedAt: meta.deletedAt ?? purged,
        purgedAt: purged,
        width: meta.width,
        height: meta.height,
        background: meta.background,
        strokes: <StrokeElement>[],
        erased: <EraseTombstone>[],
        objects: <CanvasElement>[],
        deletedObjects: <EraseTombstone>[],
      );
    }

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

    // Rev-based (LWW) deletion: an erased stroke stays out of `strokes` unless
    // its own rev has climbed ABOVE its tombstone's rev — i.e. it was revived
    // (undo/move-back bumps rev) or edited after the erase. A passive copy at
    // rev <= tombstone.rev stays dead. The tombstone always lives on.
    final filteredStrokes = mergedStrokes.values.where((s) {
      final t = mergedErased[s.id];
      return t == null || s.rev > t.rev;
    }).toList();

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

    // Rev-based (LWW) deletion, same rule as strokes above.
    final filteredObjects = mergedObjects.values.where((o) {
      final t = mergedDeletedObjects[o.id];
      return t == null || o.rev > t.rev;
    }).toList();

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
      'purge${p.purgedAt?.millisecondsSinceEpoch}',
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
