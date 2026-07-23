import '../models/link.dart';
import '../models/project.dart';
import 'notebook_service.dart';
import 'settings_service.dart';
import 'sync_service.dart';

/// In-memory view over the project registry (`projects.json`) — lazy,
/// dataVersion-gated, mirroring [TagService]/[LinkService]. A project is a
/// named set of item endpoints (containers); membership is stored as separate
/// records so concurrent edits on two devices union rather than clobber.
class ProjectService {
  static final ProjectService _instance = ProjectService._();
  factory ProjectService() => _instance;
  ProjectService._();

  final Map<String, ProjectDef> _defs = {};
  final Map<String, ProjectItem> _items = {};
  int _loadedAtVersion = -1;

  Future<void> _ensureLoaded() async {
    final v = SyncService().dataVersion.value;
    if (_loadedAtVersion == v) return;
    _defs.clear();
    _items.clear();
    final raw = await NotebookService().readProjectsJson();
    for (final e in raw.entries) {
      final val = e.value;
      if (val is! Map<String, dynamic>) continue;
      if (val['t'] == 'pi') {
        final i = ProjectItem.tryFromJson(val);
        if (i != null) _items[i.id] = i;
      } else {
        final d = ProjectDef.tryFromJson(val);
        if (d != null) _defs[d.id] = d;
      }
    }
    _loadedAtVersion = v;
  }

  Future<void> _persist() async {
    final raw = await NotebookService().readProjectsJson();
    for (final d in _defs.values) {
      raw[d.id] = d.toJson();
    }
    for (final i in _items.values) {
      raw[i.id] = i.toJson();
    }
    await NotebookService().saveProjectsJson(raw);
  }

  String get _dev => SettingsService().deviceId;

  Future<List<ProjectDef>> allProjects() async {
    await _ensureLoaded();
    return _defs.values.where((d) => d.deletedAt == null).toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  }

  /// The alive membership records of [projectId] — includes AND excludes (read
  /// `.excluded` to tell them apart). Container inheritance is applied by the
  /// caller (the graph controller walks each node's ancestry against these).
  Future<List<ProjectItem>> membersOf(String projectId) async {
    await _ensureLoaded();
    return _items.values
        .where((i) => i.deletedAt == null && i.projectId == projectId)
        .toList();
  }

  Future<ProjectDef> createProject(String name) async {
    await _ensureLoaded();
    final def = ProjectDef(
        id: NotebookService().newId(), deviceId: _dev, name: name.trim());
    _defs[def.id] = def;
    await _persist();
    return def;
  }

  Future<void> renameProject(String id, String name) async {
    await _ensureLoaded();
    final d = _defs[id];
    if (d == null) return;
    d.name = name.trim();
    d.bumpRev(_dev);
    await _persist();
  }

  /// Feature F: saves [projectId]'s arranged node [layout] (canonical node key →
  /// `[dx, dy]`) and its [pinLayout] flag. Synced via projects.json (LWW on the
  /// def). By default [merge]s the given positions INTO the stored layout
  /// (updating supplied nodes, keeping the rest) — so a "Save arrangement" from a
  /// depth-scoped local graph, which only sees a subset of nodes, doesn't drop
  /// the positions of nodes it isn't showing. Pass merge:false to replace whole.
  Future<void> setProjectLayout(
    String projectId,
    Map<String, List<double>> layout, {
    required bool pinLayout,
    bool merge = true,
  }) async {
    await _ensureLoaded();
    final d = _defs[projectId];
    if (d == null) return;
    d.layout = merge ? {...d.layout, ...layout} : layout;
    d.pinLayout = pinLayout;
    d.bumpRev(_dev);
    await _persist();
  }

  /// Toggles a project's [pinLayout] flag WITHOUT touching its saved positions —
  /// so turning it back on restores the same arrangement.
  Future<void> setProjectPinLayout(String projectId, bool pinLayout) async {
    await _ensureLoaded();
    final d = _defs[projectId];
    if (d == null || d.pinLayout == pinLayout) return;
    d.pinLayout = pinLayout;
    d.bumpRev(_dev);
    await _persist();
  }

  /// Tombstones the project + all its memberships.
  Future<void> deleteProject(String id) async {
    await _ensureLoaded();
    final d = _defs[id];
    if (d == null) return;
    d.deletedAt = DateTime.now();
    d.bumpRev(_dev);
    for (final i in _items.values) {
      if (i.projectId == id && i.deletedAt == null) {
        i.deletedAt = DateTime.now();
        i.bumpRev(_dev);
      }
    }
    await _persist();
  }

  /// Replaces [projectId]'s membership with the given [includes] + [excludes]
  /// (container/leaf endpoints keyed by [LinkEndpoint.leafId]) — adds new ones,
  /// flips an existing record's include/exclude sense in place, tombstones
  /// removed ones, revives previously-removed matches. Used by the build-mode
  /// save. An id can be an include OR an exclude, not both (excludes win the
  /// merge below, but the panel never emits the same id in both lists).
  Future<void> setMembers(
    String projectId, {
    required List<LinkEndpoint> includes,
    List<LinkEndpoint> excludes = const [],
  }) async {
    await _ensureLoaded();
    final wanted = <String, ({LinkEndpoint ep, bool ex})>{};
    for (final e in includes) {
      wanted[e.leafId] = (ep: e, ex: false);
    }
    for (final e in excludes) {
      wanted[e.leafId] = (ep: e, ex: true);
    }
    // Tombstone / revive / re-sense existing.
    final seen = <String>{};
    for (final i in _items.values) {
      if (i.projectId != projectId) continue;
      final key = i.endpoint.leafId;
      final w = wanted[key];
      if (w != null) {
        seen.add(key);
        if (i.deletedAt != null || i.excluded != w.ex) {
          i.deletedAt = null;
          i.excluded = w.ex;
          i.bumpRev(_dev);
        }
      } else if (i.deletedAt == null) {
        i.deletedAt = DateTime.now();
        i.bumpRev(_dev);
      }
    }
    // Add brand-new.
    for (final entry in wanted.entries) {
      if (seen.contains(entry.key)) continue;
      final item = ProjectItem(
          id: NotebookService().newId(),
          deviceId: _dev,
          projectId: projectId,
          endpoint: entry.value.ep,
          excluded: entry.value.ex);
      _items[item.id] = item;
    }
    await _persist();
  }
}
