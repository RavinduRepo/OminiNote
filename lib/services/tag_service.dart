import '../models/link.dart';
import '../models/tag.dart';
import 'notebook_service.dart';
import 'settings_service.dart';
import 'sync_service.dart';

/// In-memory view over the tag registry (`tags.json`). Lazy, re-read only when
/// [SyncService.dataVersion] advances (a sync pull or store mutation) — like
/// [LinkService]. Holds tag definitions + their per-item assignments; mutations
/// persist through [NotebookService.saveTagsJson] (atomic write → journal →
/// upload). Deletion is always a tombstone, never a map removal.
class TagService {
  static final TagService _instance = TagService._();
  factory TagService() => _instance;
  TagService._();

  final Map<String, TagDef> _defs = {};
  final Map<String, TagAssignment> _assigns = {};
  int _loadedAtVersion = -1;

  Future<void> _ensureLoaded() async {
    final v = SyncService().dataVersion.value;
    if (_loadedAtVersion == v) return;
    _defs.clear();
    _assigns.clear();
    final raw = await NotebookService().readTagsJson();
    for (final e in raw.entries) {
      final val = e.value;
      if (val is! Map<String, dynamic>) continue;
      if (val['t'] == 'a') {
        final a = TagAssignment.tryFromJson(val);
        if (a != null) _assigns[a.id] = a;
      } else {
        final d = TagDef.tryFromJson(val);
        if (d != null) _defs[d.id] = d;
      }
    }
    _loadedAtVersion = v;
  }

  Future<void> _persist() async {
    final raw = await NotebookService().readTagsJson();
    for (final d in _defs.values) {
      raw[d.id] = d.toJson();
    }
    for (final a in _assigns.values) {
      raw[a.id] = a.toJson();
    }
    await NotebookService().saveTagsJson(raw);
  }

  String get _dev => SettingsService().deviceId;

  /// All alive tag definitions, newest first.
  Future<List<TagDef>> allTags() async {
    await _ensureLoaded();
    return _defs.values.where((d) => d.deletedAt == null).toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  }

  /// The alive tag definitions assigned to the item whose endpoint leaf is
  /// [leafId] — the chips shown in that item's Connections menu.
  Future<List<TagDef>> tagsOf(String leafId) async {
    await _ensureLoaded();
    final ids = <String>{};
    for (final a in _assigns.values) {
      if (a.deletedAt == null && a.endpoint.leafId == leafId) ids.add(a.tagId);
    }
    return _defs.values
        .where((d) => d.deletedAt == null && ids.contains(d.id))
        .toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  }

  /// Map of item leaf id → set of alive tag ids on it — the graph's per-node
  /// tag lookup for filtering.
  Future<Map<String, Set<String>>> tagIdsByLeaf() async {
    await _ensureLoaded();
    final aliveTagIds = _defs.values
        .where((d) => d.deletedAt == null)
        .map((d) => d.id)
        .toSet();
    final out = <String, Set<String>>{};
    for (final a in _assigns.values) {
      if (a.deletedAt != null || !aliveTagIds.contains(a.tagId)) continue;
      (out[a.endpoint.leafId] ??= <String>{}).add(a.tagId);
    }
    return out;
  }

  Future<TagDef> createTag(String name) async {
    await _ensureLoaded();
    final def = TagDef(
        id: NotebookService().newId(), deviceId: _dev, name: name.trim());
    _defs[def.id] = def;
    await _persist();
    return def;
  }

  Future<void> renameTag(String id, String name) async {
    await _ensureLoaded();
    final d = _defs[id];
    if (d == null) return;
    d.name = name.trim();
    d.bumpRev(_dev);
    await _persist();
  }

  /// Deletes a tag everywhere: tombstones the definition AND every assignment
  /// of it, so it disappears from all items (per the agreed behavior).
  Future<void> deleteTag(String id) async {
    await _ensureLoaded();
    final d = _defs[id];
    if (d == null) return;
    d.deletedAt = DateTime.now();
    d.bumpRev(_dev);
    for (final a in _assigns.values) {
      if (a.tagId == id && a.deletedAt == null) {
        a.deletedAt = DateTime.now();
        a.bumpRev(_dev);
      }
    }
    await _persist();
  }

  /// Attaches [tagId] to the item at [endpoint] (idempotent — reuses/revives an
  /// existing assignment for the same pair rather than duplicating).
  Future<void> assign(String tagId, LinkEndpoint endpoint) async {
    await _ensureLoaded();
    for (final a in _assigns.values) {
      if (a.tagId == tagId && a.endpoint.sameAs(endpoint)) {
        if (a.deletedAt != null) {
          a.deletedAt = null;
          a.bumpRev(_dev);
          await _persist();
        }
        return;
      }
    }
    final a = TagAssignment(
        id: NotebookService().newId(),
        deviceId: _dev,
        tagId: tagId,
        endpoint: endpoint);
    _assigns[a.id] = a;
    await _persist();
  }

  /// Removes [tagId] from the item at [endpoint] (tombstones the assignment).
  Future<void> unassign(String tagId, LinkEndpoint endpoint) async {
    await _ensureLoaded();
    for (final a in _assigns.values) {
      if (a.deletedAt == null &&
          a.tagId == tagId &&
          a.endpoint.sameAs(endpoint)) {
        a.deletedAt = DateTime.now();
        a.bumpRev(_dev);
        await _persist();
        return;
      }
    }
  }
}
