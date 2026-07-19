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
