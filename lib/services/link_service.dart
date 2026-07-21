import '../models/link.dart';
import 'notebook_service.dart';
import 'settings_service.dart';
import 'sync_service.dart';

/// In-memory view over the Connections registry (`links.json`).
///
/// Loaded lazily on first query and re-read only when [SyncService.dataVersion]
/// has advanced since the last load (a sync pull or a store mutation) — so
/// normal drawing/typing/navigation never touches it. Local mutations update
/// the cache in place and persist through [NotebookService.saveLinksJson]
/// (atomic write → journal → upload, like any local edit).
///
/// Deletion is a tombstone (`deletedAt` + rev bump), never a map removal —
/// same durability rule as the rest of the store (a hard-removed record has
/// no envelope left to win a merge, so a live remote copy would resurrect it).
class LinkService {
  static final LinkService _instance = LinkService._internal();
  factory LinkService() => _instance;
  LinkService._internal();

  Map<String, LinkRecord> _records = {};
  int _loadedAtVersion = -1;

  Future<void> _ensureLoaded() async {
    final v = SyncService().dataVersion.value;
    if (_loadedAtVersion == v) return;
    final raw = await NotebookService().readLinksJson();
    final out = <String, LinkRecord>{};
    for (final e in raw.entries) {
      if (e.value is! Map<String, dynamic>) continue;
      final rec = LinkRecord.tryFromJson(e.value as Map<String, dynamic>);
      if (rec != null) out[rec.id] = rec;
    }
    _records = out;
    _loadedAtVersion = v;
  }

  Future<void> _persist() async {
    // Serialize every record we hold — including entries whose json we
    // couldn't parse? No: unparseable entries were dropped at load, so
    // re-serializing would lose them. Re-read the raw map and overlay ours,
    // preserving foreign/newer-schema entries untouched.
    final raw = await NotebookService().readLinksJson();
    for (final r in _records.values) {
      raw[r.id] = r.toJson();
    }
    await NotebookService().saveLinksJson(raw);
  }

  /// Every alive connection in the store — the edge set for the global graph
  /// view. Uses the same version-gated cache as the id-scoped queries, so it's
  /// cheap to re-call on a [SyncService.dataVersion] bump. Newest first.
  Future<List<LinkRecord>> allLinks() async {
    await _ensureLoaded();
    return _records.values.where((r) => r.deletedAt == null).toList()
      ..sort((x, y) => y.createdAt.compareTo(x.createdAt));
  }

  /// Alive connections where [leafId] is either side's target — the list a
  /// Connections sheet shows for one item.
  Future<List<LinkRecord>> linksOf(String leafId) async {
    await _ensureLoaded();
    return _records.values
        .where((r) =>
            r.deletedAt == null &&
            (r.a.leafId == leafId || r.b.leafId == leafId))
        .toList()
      ..sort((x, y) => y.createdAt.compareTo(x.createdAt));
  }

  /// Alive connections where either side is an element endpoint intersecting
  /// [elementIds] — the Connections list for a lasso selection (any overlap
  /// counts, so re-selecting a superset/subset still finds the link).
  Future<List<LinkRecord>> linksOfElements(List<String> elementIds) async {
    await _ensureLoaded();
    final set = elementIds.toSet();
    bool touches(LinkEndpoint e) => e.elementIds.any(set.contains);
    return _records.values
        .where((r) => r.deletedAt == null && (touches(r.a) || touches(r.b)))
        .toList()
      ..sort((x, y) => y.createdAt.compareTo(x.createdAt));
  }

  /// Alive connections touching anything inside canvas [canvasId] (the canvas
  /// itself, its pages, elements or bookmarks) — the canvas ⋯ menu's
  /// "All connections" aggregate.
  Future<List<LinkRecord>> linksTouchingCanvas(String canvasId) async {
    await _ensureLoaded();
    return _records.values
        .where((r) =>
            r.deletedAt == null &&
            (r.a.canvasId == canvasId || r.b.canvasId == canvasId))
        .toList()
      ..sort((x, y) => y.createdAt.compareTo(x.createdAt));
  }

  /// Creates (or returns the existing) connection between [from] and [to].
  /// The pair is unordered for dedup: pasting A's link into B twice — or B's
  /// into A — yields one record.
  Future<LinkRecord> addLink({
    required LinkEndpoint from,
    required LinkEndpoint to,
    String fromName = '',
    String toName = '',
  }) async {
    await _ensureLoaded();
    for (final r in _records.values) {
      if (r.deletedAt != null) continue;
      if ((r.a.sameAs(from) && r.b.sameAs(to)) ||
          (r.a.sameAs(to) && r.b.sameAs(from))) {
        return r;
      }
    }
    // A tombstoned copy of the same pair is revived (rev bumped above the
    // tombstone) instead of duplicated, so re-linking survives merges.
    for (final r in _records.values) {
      if (r.deletedAt == null) continue;
      if ((r.a.sameAs(from) && r.b.sameAs(to)) ||
          (r.a.sameAs(to) && r.b.sameAs(from))) {
        r.deletedAt = null;
        r.bumpRev(SettingsService().deviceId);
        await _persist();
        return r;
      }
    }
    final rec = LinkRecord(
      id: NotebookService().newId(),
      deviceId: SettingsService().deviceId,
      a: from,
      b: to,
      aName: fromName,
      bName: toName,
    );
    _records[rec.id] = rec;
    await _persist();
    return rec;
  }

  /// Tombstones the connection [id] — it disappears from both endpoints'
  /// lists at once (one record backs both directions).
  Future<void> removeLink(String id) async {
    await _ensureLoaded();
    final r = _records[id];
    if (r == null || r.deletedAt != null) return;
    r.deletedAt = DateTime.now();
    r.bumpRev(SettingsService().deviceId);
    await _persist();
  }

  /// Drops the visible reciprocal marker next to an element endpoint [at] —
  /// a small hyperlink pointing back at the connection's other side, so BOTH
  /// linked spots show something on their canvases. Routed through the open
  /// canvas's live controller when it's open (its autosave would clobber a
  /// disk write), else written into the page file. Null for non-element
  /// endpoints or when the target page is gone.
  Future<String?> dropMarkerNear(
    LinkEndpoint at, {
    required String uri,
    required String title,
  }) async {
    if (at.kind != LinkTargetKind.element ||
        at.sectionId == null ||
        at.canvasId == null ||
        at.pageId == null) {
      return null;
    }
    final open = await SyncService().insertMarkerInOpenCanvas(
        at.canvasId!, at.pageId!, at.elementIds, uri, title);
    if (open.handled) return open.markerId;
    return NotebookService().addLinkMarkerToPage(
      notebookId: at.notebookId,
      sectionId: at.sectionId!,
      canvasId: at.canvasId!,
      pageId: at.pageId!,
      nearIds: at.elementIds,
      uri: uri,
      title: title,
    );
  }

  /// [addLink] plus both-sides visibility: when [to] is an element endpoint,
  /// a reciprocal marker (linking back to [from]) is dropped next to its
  /// elements and its id folded into the record's target side — which is what
  /// lets that marker's ✎ retarget this very record. Dedup is by element-id
  /// OVERLAP (marker ids make exact-pair matching blind), so re-adding an
  /// existing connection never duplicates markers.
  Future<LinkRecord> addLinkWithReciprocalMarker({
    required LinkEndpoint from,
    required LinkEndpoint to,
    String fromName = '',
    String toName = '',
  }) async {
    await _ensureLoaded();
    bool matches(LinkEndpoint x, LinkEndpoint y) =>
        x.kind == LinkTargetKind.element && y.kind == LinkTargetKind.element
            ? x.elementIds.any(y.elementIds.contains)
            : x.sameAs(y);
    for (final r in _records.values) {
      if (r.deletedAt != null) continue;
      if ((matches(r.a, from) && matches(r.b, to)) ||
          (matches(r.a, to) && matches(r.b, from))) {
        return r; // already connected — no duplicate record/marker
      }
    }
    var target = to;
    if (to.kind == LinkTargetKind.element) {
      final markerId = await dropMarkerNear(
        to,
        uri: from.toUri(),
        title: fromName.isEmpty ? 'Linked item' : fromName,
      );
      if (markerId != null) {
        target = LinkEndpoint(
          notebookId: to.notebookId,
          sectionId: to.sectionId,
          canvasId: to.canvasId,
          pageId: to.pageId,
          elementIds: [...to.elementIds, markerId],
          bookmarkId: to.bookmarkId,
          folderId: to.folderId,
        );
      }
    }
    return addLink(from: from, to: target, fromName: fromName, toName: toName);
  }

  /// Rewrites the record that links [elementId]'s side to [oldTarget] so it
  /// points at [newTarget] instead — keeping the record id, the element side
  /// (all its ids, e.g. a lasso selection + its marker) and the label. Rev
  /// bump so the rewrite wins LWW. Returns false when no record matched
  /// (caller then falls back to [addLink]).
  Future<bool> retargetByElement(
    String elementId,
    LinkEndpoint oldTarget,
    LinkEndpoint newTarget,
  ) async {
    await _ensureLoaded();
    for (final r in _records.values) {
      if (r.deletedAt != null) continue;
      if (r.a.elementIds.contains(elementId) && r.b.sameAs(oldTarget)) {
        r.b = newTarget;
      } else if (r.b.elementIds.contains(elementId) && r.a.sameAs(oldTarget)) {
        r.a = newTarget;
      } else {
        continue;
      }
      r.bumpRev(SettingsService().deviceId);
      await _persist();
      return true;
    }
    return false;
  }

  /// Tombstones the record linking [elementId]'s side to [target], if any.
  Future<void> removeByElementTo(String elementId, LinkEndpoint target) async {
    await _ensureLoaded();
    for (final r in _records.values) {
      if (r.deletedAt != null) continue;
      if ((r.a.elementIds.contains(elementId) && r.b.sameAs(target)) ||
          (r.b.elementIds.contains(elementId) && r.a.sameAs(target))) {
        r.deletedAt = DateTime.now();
        r.bumpRev(SettingsService().deviceId);
        await _persist();
        return;
      }
    }
  }

  /// Updates a record from the Connections sheet's ✎: a new "other side"
  /// target and/or a custom [label]. [otherIsA] says which side is the one
  /// being retargeted (the side opposite the sheet's own item).
  Future<void> updateLink(
    String id, {
    required bool otherIsA,
    LinkEndpoint? newOther,
    String? label,
    bool clearLabel = false,
  }) async {
    await _ensureLoaded();
    final r = _records[id];
    if (r == null || r.deletedAt != null) return;
    if (newOther != null) {
      if (otherIsA) {
        r.a = newOther;
      } else {
        r.b = newOther;
      }
    }
    if (clearLabel) {
      r.label = null;
    } else if (label != null && label.trim().isNotEmpty) {
      r.label = label;
    }
    r.bumpRev(SettingsService().deviceId);
    await _persist();
  }

  /// Tombstones the connection between exactly [a] and [b] (either order),
  /// if one is alive — used when a link run is retargeted or de-linked.
  Future<void> removeLinkBetween(LinkEndpoint a, LinkEndpoint b) async {
    await _ensureLoaded();
    for (final r in _records.values) {
      if (r.deletedAt != null) continue;
      if ((r.a.sameAs(a) && r.b.sameAs(b)) ||
          (r.a.sameAs(b) && r.b.sameAs(a))) {
        r.deletedAt = DateTime.now();
        r.bumpRev(SettingsService().deviceId);
        await _persist();
        return;
      }
    }
  }

  /// Sets/clears the user label on [id].
  Future<void> setLabel(String id, String? label) async {
    await _ensureLoaded();
    final r = _records[id];
    if (r == null) return;
    r.label = (label != null && label.trim().isEmpty) ? null : label;
    r.bumpRev(SettingsService().deviceId);
    await _persist();
  }
}
