import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/scheduler.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/link.dart';
import '../models/project.dart';
import '../models/tag.dart';
import '../services/graph_service.dart';
import '../services/link_navigator.dart';
import '../services/link_resolver.dart';
import '../services/link_service.dart';
import '../services/project_service.dart';
import '../services/settings_service.dart';
import '../services/sync_service.dart';
import '../services/tag_service.dart';
import '../theme/app_theme.dart';
import '../utils/app_toast.dart';
import '../widgets/connections_sheet.dart' show ConnectionsListView;

/// A live node in the force simulation — graph data plus physics state.
class GraphSimNode {
  final GraphNode data;
  Offset pos;
  Offset vel = Offset.zero;
  Offset force = Offset.zero;

  /// Connections touching this node in the *current* (post-filter/abstraction)
  /// graph — drives node size, so an abstracted canvas grows with the items
  /// folded into it.
  int activeDegree = 0;

  /// Pinned in place by the user (dragged and dropped): held fixed, excluded
  /// from the force integration so it stays exactly where placed instead of
  /// springing back. Preserved across rebuilds by key.
  bool fixed = false;

  GraphSimNode(this.data, this.pos);
}

/// Owns the graph's node/edge set, a force-directed layout, and the pan/zoom
/// camera — the same app-owns-the-viewport pattern as [CanvasController], so
/// screen↔world conversion and zoom-at-focal work identically.
class GraphController extends ChangeNotifier {
  // Full graph (unfiltered) + the currently-visible subset the sim runs on.
  GraphData _all = const GraphData(nodes: [], edges: []);
  final List<GraphSimNode> _nodes = [];
  final Map<String, GraphSimNode> _byKey = {};
  List<GraphEdge> _edges = [];

  // ── Filter / scope model (shared by the global tree filter today, reused by
  // an in-canvas scope toggle later) ──
  /// Container ids (notebook/section/canvas) toggled OFF in the filter tree —
  /// a node under any of them is hidden.
  final Set<String> hiddenContainers = {};

  /// When true, page/element/bookmark nodes collapse into their owning canvas
  /// node (edges rewired + deduped) for a cleaner view; when false each
  /// inside-canvas item shows individually.
  bool abstractInsideItems = true;

  /// Local-graph mode: when [centerKey] is set, [_rebuildActive] restricts the
  /// visible graph to nodes within [depthLimit] hops of it (BFS over the visible
  /// edges) plus each kept node's same-canvas cluster — so the local graph is
  /// exactly THIS global graph, scoped to a neighborhood. Null = global (no
  /// restriction). The painter draws a ring on the center node.
  String? centerKey;
  int? depthLimit;

  /// Focuses the graph on [key] with a [depth]-hop neighborhood (local-graph
  /// mode), or clears it (null [key]) for the full global graph.
  void setCenter(String? key, int? depth) {
    if (centerKey == key && depthLimit == depth) return;
    centerKey = key;
    depthLimit = depth;
    _rebuildActive();
  }

  /// Show external-URL nodes.
  bool showExternal = true;

  /// Add isolated nodes for containers that have no links (so you can spot —
  /// and create links for — unlinked notebooks/sections/canvases).
  bool showUnlinked = false;

  /// The store structure (notebook → group → section → folder → canvas) — the
  /// filter tree's source (folders included) and the unlinked-node source.
  GraphStructure? structure;

  /// Every container as an isolated GraphNode (from [structure]) — added to the
  /// graph when [showUnlinked] is on, for containers not already linked.
  List<GraphNode> _unlinkedCandidates = [];

  // ── Tag filter (AND / OR / NOT) ──
  List<TagDef> tags = const []; // all defined tags (for the filter chips)
  Map<String, Set<String>> _tagsByLeaf = const {}; // leaf id → its tag ids
  final Set<String> tagInclude = {}; // must match (per [tagMatchAll])
  final Set<String> tagExclude = {}; // must NOT be present
  bool tagMatchAll = false; // includes combine as ALL (true) or ANY (false)

  bool get hasTagFilter => tagInclude.isNotEmpty || tagExclude.isNotEmpty;

  /// 0 = off, 1 = include, 2 = exclude.
  int tagState(String id) =>
      tagInclude.contains(id) ? 1 : (tagExclude.contains(id) ? 2 : 0);

  // ── Projects (named saved selections; activating one scopes the graph) ──
  List<ProjectDef> projects = const [];
  String? activeProjectId;
  // Project membership is CONTAINER-INHERITING: selecting a section/notebook
  // includes it and everything under it — now and future — while an item can be
  // excluded to carve it back out. Both sets hold container/leaf ids; membership
  // is decided nearest-first over a node's container ancestry (a nearer choice
  // wins), so a new canvas under an included section is a member with no record
  // of its own.
  Set<String> _projIncludes = {};
  Set<String> _projExcludes = {};
  bool projectPlusLinks = false; // also show members' linked neighbors

  // ── Per-project saved layout (Feature F) ──
  /// Whether the active project pins its saved [_projLayout]. When true,
  /// [_rebuildActive] holds saved-position nodes fixed and the pin toggle
  /// restores them; the saved layout only CHANGES via "Save arrangement".
  bool projPinLayout = false;

  /// The active project's saved node positions (canonical key → world Offset),
  /// decoded from [ProjectDef.layout]. Empty when no project / no saved layout.
  Map<String, Offset> _projLayout = {};

  static Map<String, Offset> _decodeLayout(Map<String, List<double>>? raw) {
    if (raw == null) return {};
    final out = <String, Offset>{};
    for (final e in raw.entries) {
      if (e.value.length >= 2) out[e.key] = Offset(e.value[0], e.value[1]);
    }
    return out;
  }

  /// The current visible node positions as a savable map (canonical key →
  /// `[dx, dy]`). The host persists this to the active project.
  Map<String, List<double>> captureLayout() =>
      {for (final n in _nodes) n.data.key: [n.pos.dx, n.pos.dy]};

  /// Container id → its ancestry [self, parent, …, notebook], nearest first.
  /// Built from the store structure so folder/group levels are honored (an
  /// endpoint URI alone doesn't carry its parent folder). Rebuilt in
  /// [setStructure].
  Map<String, List<String>> _ancestors = {};

  /// The ancestry chain for [id] (self first), or just [id] when unknown
  /// (a dead/absent container). Used by the build-mode tri-state checkboxes.
  List<String> ancestorsOf(String id) => _ancestors[id] ?? [id];

  /// Whether [id] resolves to a member under the active project's include/
  /// exclude sets — walking its ancestry nearest-first (a nearer exclude beats a
  /// farther include and vice-versa). Also the tree-scoping predicate.
  bool isProjectMember(String id) {
    for (final a in ancestorsOf(id)) {
      if (_projExcludes.contains(a)) return false;
      if (_projIncludes.contains(a)) return true;
    }
    return false;
  }

  /// A node belongs to the active project when its deepest container resolves to
  /// a member (inside-canvas items inherit their canvas's membership).
  bool _inActiveProject(GraphNode n) {
    final id = n.deepestContainerId;
    return id != null && isProjectMember(id);
  }

  // ── Appearance (Obsidian-style sliders) ──
  double nodeSizeScale = 1.0; // 0.5–2.5
  double textSizeScale = 1.0; // 0.6–2.0
  double linkThickness = 1.0; // 0.4–3.0
  double linkOpacity = 0.6; // 0.1–1.0
  double labelOpacity = 0.95; // 0.15–1.0 (node text transparency)
  bool alwaysShowLabels = false; // keep labels visible however far you zoom out
  bool sameCanvasLinks = true; // dashed grouping links among same-canvas items
  bool pinOnDrag = false; // dragging a node pins it in place (off = springs back)
  bool autoScale = true; // auto-fit/reframe after the layout settles (off = keep zoom/pan)

  GraphController() {
    // Seed appearance + view toggles from device-local settings.
    final s = SettingsService();
    nodeSizeScale = s.graphNodeSize;
    textSizeScale = s.graphTextSize;
    linkThickness = s.graphLinkThickness;
    linkOpacity = s.graphLinkOpacity;
    labelOpacity = s.graphLabelOpacity;
    alwaysShowLabels = s.graphAlwaysLabels;
    sameCanvasLinks = s.graphSameCanvasLinks;
    pinOnDrag = s.graphPinOnDrag;
    autoScale = s.graphAutoScale;
    abstractInsideItems = s.graphAbstractItems;
    showExternal = s.graphShowExternal;
    showUnlinked = s.graphShowUnlinked;
    // Restore selection / filter / project (device-local).
    final gv = s.graphView;
    hiddenContainers.addAll(
        (gv['hidden'] as List?)?.whereType<String>() ?? const []);
    tagInclude.addAll((gv['tagInc'] as List?)?.whereType<String>() ?? const []);
    tagExclude.addAll((gv['tagExc'] as List?)?.whereType<String>() ?? const []);
    tagMatchAll = gv['tagAll'] == true;
    activeProjectId = gv['project'] as String?;
    projectPlusLinks = gv['projLinks'] == true;
  }

  /// When false, view-selection changes (hidden containers / tags / active
  /// project) are NOT written to the shared device-local blob. The local graph
  /// panel sets this — its filters are per-session and must not leak into the
  /// global graph, which seeds from that blob. Appearance settings persist
  /// regardless (they're deliberately shared global↔local via saveGraphSettings).
  bool persistView = true;

  /// Persists the selection/filter/project state to the device-local blob.
  void _saveView() {
    if (!persistView) return;
    SettingsService().patchGraphView({
      'hidden': hiddenContainers.toList(),
      'tagInc': tagInclude.toList(),
      'tagExc': tagExclude.toList(),
      'tagAll': tagMatchAll,
      'project': activeProjectId,
      'projLinks': projectPlusLinks,
    });
  }

  bool get hasActiveProject => activeProjectId != null;

  /// Fired at the end of every filter/data rebuild — the screen uses it to
  /// auto-fit the graph after the change settles.
  VoidCallback? onContentChanged;

  /// A container id hovered in the filter tree — nodes under it get a halo.
  String? highlightContainerId;

  /// Bumped only on changes the filter panel cares about (data / filter /
  /// hover) — NOT on the per-frame sim ticks that drive [notifyListeners], so
  /// the panel's tree isn't rebuilt 60×/s.
  final ValueNotifier<int> uiVersion = ValueNotifier(0);
  void _bumpUi() => uiVersion.value++;

  double zoom = 1.0;
  Offset pan = Offset.zero;
  Size screenSize = Size.zero;

  // Physics tuning (Fruchterman-Reingold-flavored with damping + cooling).
  static const double _kRepulsion = 11000;
  static const double _kSpring = 0.018;
  static const double _kRest = 96;
  static const double _kGravity = 0.006;
  static const double _kDamping = 0.86;
  static const double _kSettleSpeed = 0.06;

  GraphSimNode? _pinned; // node currently being dragged (excluded from integration)
  String? hoverKey; // node under the cursor (desktop hover highlight)
  // Whether the one-shot crossing-reduction has run since the last rebuild.
  bool _untangled = false;

  // Camera tween (animated Fit / focus): lerps pan+zoom toward a target while
  // the ticker runs, so the framing glides instead of snapping.
  Offset? _camPanTarget;
  double? _camZoomTarget;
  static const double _kCamLerp = 0.2;

  /// State sets this so the controller can restart the ticker after data
  /// changes or a drag (the [Ticker] lives in the widget for a vsync source).
  VoidCallback? onWake;

  List<GraphSimNode> get nodes => _nodes;
  List<GraphEdge> get edges => _edges;
  bool get isEmpty => _nodes.isEmpty;

  Offset screenToCanvas(Offset s) => (s - pan) / zoom;
  Offset canvasToScreen(Offset c) => c * zoom + pan;

  void setScreenSize(Size size) {
    if (size == screenSize) return;
    final wasEmpty = screenSize.isEmpty;
    screenSize = size;
    // First real size: center the world origin and fit the current layout.
    if (wasEmpty && !size.isEmpty) {
      pan = Offset(size.width / 2, size.height / 2);
      if (_nodes.isNotEmpty) fitToScreen(snap: true);
    }
  }

  /// Replaces the full graph, then rebuilds the visible subset.
  void setData(GraphData data) {
    _all = data;
    _rebuildActive();
  }

  /// Sets the store structure (drives the filter tree + unlinked nodes).
  void setStructure(GraphStructure s) {
    structure = s;
    _unlinkedCandidates = _flattenStructureNodes(s);
    _buildAncestors(s);
    _rebuildActive();
  }

  /// Records each container's ancestry (self → … → notebook) so project
  /// membership can inherit down real folder/group nesting, which endpoint URIs
  /// don't fully encode.
  void _buildAncestors(GraphStructure s) {
    final map = <String, List<String>>{};
    void walk(GraphContainer g, List<String> parentChain) {
      final chain = [g.id, ...parentChain];
      map[g.id] = chain;
      for (final ch in g.children) {
        walk(ch, chain);
      }
    }

    for (final nb in s.notebooks) {
      walk(nb, const []);
    }
    _ancestors = map;
  }

  static LinkTargetKind _kindOf(GraphContainerKind k) {
    switch (k) {
      case GraphContainerKind.notebook:
        return LinkTargetKind.notebook;
      case GraphContainerKind.sectionGroup:
      case GraphContainerKind.canvasFolder:
        return LinkTargetKind.folder;
      case GraphContainerKind.section:
        return LinkTargetKind.section;
      case GraphContainerKind.canvas:
        return LinkTargetKind.canvas;
    }
  }

  List<GraphNode> _flattenStructureNodes(GraphStructure s) {
    final out = <GraphNode>[];
    void walk(GraphContainer c) {
      out.add(GraphNode(
        key: c.endpoint.toUri(),
        title: c.name,
        kind: _kindOf(c.kind),
        alive: true,
        degree: 0,
        leafId: c.endpoint.leafId,
        reveal: c.reveal,
        color: AppPalette.identityColor(c.id),
        notebookId: c.endpoint.notebookId,
        sectionId: c.endpoint.sectionId,
        canvasId: c.endpoint.canvasId,
        folderId: c.endpoint.folderId,
      ));
      for (final ch in c.children) {
        walk(ch);
      }
    }

    for (final nb in s.notebooks) {
      walk(nb);
    }
    return out;
  }

  /// True when [n] passes the container + external filters (NOT the inside-item
  /// handling — that's abstraction, applied separately in [_rebuildActive]).
  ///
  /// Visibility keys off the node's *own deepest* container only (not every
  /// ancestor), so unchecking a section still lets you re-check individual
  /// canvases inside it — the tree checkboxes are independent, with a cascade.
  bool _passesFilter(GraphNode n, {bool ignoreContainers = false}) {
    if (n.externalUrl != null && !showExternal) return false;
    final id = n.deepestContainerId;
    if (!ignoreContainers && id != null && hiddenContainers.contains(id)) {
      return false;
    }
    // Tag filter: excludes always remove; includes must match per ALL/ANY.
    if (hasTagFilter) {
      final nt = _tagsByLeaf[n.leafId] ?? const <String>{};
      if (tagExclude.any(nt.contains)) return false;
      if (tagInclude.isNotEmpty) {
        final ok = tagMatchAll
            ? tagInclude.every(nt.contains)
            : tagInclude.any(nt.contains);
        if (!ok) return false;
      }
    }
    return true;
  }

  /// Rebuilds [_nodes]/[_edges] from [_all] under the current filter, applying
  /// canvas abstraction, recomputing active degree, and preserving positions of
  /// nodes that persist (so filtering/refresh doesn't scramble the layout).
  void _rebuildActive() {
    final old = Map<String, GraphSimNode>.of(_byKey);
    _nodes.clear();
    _byKey.clear();

    // Lookup of every candidate GraphNode by key (real nodes win over
    // synthesized canvases and unlinked-container placeholders).
    final lookup = <String, GraphNode>{for (final n in _all.nodes) n.key: n};
    // Synthesized canvas nodes are needed in two cases: when abstracting (the
    // target inside-canvas items collapse INTO), and — new — when items are
    // shown with same-canvas grouping (the weak-link hub a canvas that owns
    // linked items but isn't itself linked would otherwise lack). So include
    // them regardless of the abstraction toggle; whether they actually appear
    // is decided per-node below.
    for (final n in _all.abstractCanvasNodes) {
      lookup.putIfAbsent(n.key, () => n);
    }
    for (final n in _unlinkedCandidates) {
      lookup.putIfAbsent(n.key, () => n);
    }
    // Maps an inside-canvas node's key to its canvas node when abstracting.
    String remap(String key) {
      final n = lookup[key];
      if (n == null) return key;
      if (abstractInsideItems && n.canvasKey != null) return n.canvasKey!;
      return key;
    }

    // A project scopes the graph to its members; the container checkboxes then
    // apply ON TOP (uncheck to hide within the project). Members show even if
    // unlinked. External + tag filters always apply.
    final projectActive = activeProjectId != null;

    // Final visible node keys (post-filter, post-abstraction).
    final visibleKeys = <String>{};
    for (final n in _all.nodes) {
      if (!_passesFilter(n)) continue;
      if (projectActive && !_inActiveProject(n)) continue;
      visibleKeys.add(remap(n.key));
    }
    // Unlinked containers as isolated nodes — gated by "show items without
    // links" (in project mode this hides/shows the project's unlinked members).
    if (showUnlinked) {
      for (final n in _unlinkedCandidates) {
        if (visibleKeys.contains(n.key)) continue;
        if (!_passesFilter(n)) continue;
        if (projectActive && !_inActiveProject(n)) continue;
        visibleKeys.add(n.key);
      }
    }
    // "Project + links": also pull in members' linked neighbors (one hop).
    if (projectActive && projectPlusLinks) {
      final members = {...visibleKeys};
      for (final e in _all.edges) {
        final a = remap(e.aKey), b = remap(e.bKey);
        final aIn = members.contains(a), bIn = members.contains(b);
        if (aIn == bIn) continue;
        final add = aIn ? b : a;
        final data = lookup[add];
        if (data != null && _passesFilter(data, ignoreContainers: true)) {
          visibleKeys.add(add);
        }
      }
    }

    // When items are shown (not abstracted) with same-canvas grouping on, also
    // surface each visible item's OWNING CANVAS as a node — even if that canvas
    // isn't itself linked — so the weak dashed containment link has a hub and
    // the user can see which canvas holds each item. The item's real connection
    // edges still run item→item directly (see the edge remap below); only this
    // dashed grouping edge routes through the canvas. Under abstraction the
    // canvas absorbs the item instead, so this is skipped.
    if (!abstractInsideItems && sameCanvasLinks) {
      final hubs = <String>{};
      for (final key in visibleKeys) {
        final ck = lookup[key]?.canvasKey;
        if (ck != null && !visibleKeys.contains(ck)) hubs.add(ck);
      }
      for (final ck in hubs) {
        final data = lookup[ck];
        if (data == null) continue;
        if (!_passesFilter(data)) continue;
        if (projectActive && !_inActiveProject(data)) continue;
        visibleKeys.add(ck);
      }
    }

    // Local-graph mode: keep only the [depthLimit]-hop neighborhood of
    // [centerKey] (BFS over the visible edges), plus each kept node's
    // same-canvas cluster (so a canvas's group stays intact). The center always
    // shows. Off (null) → the whole global graph, unchanged.
    final ck = centerKey;
    final depth = depthLimit;
    if (ck != null && depth != null) {
      final center = remap(ck);
      final adj = <String, Set<String>>{};
      for (final e in _all.edges) {
        final a = remap(e.aKey), b = remap(e.bKey);
        if (a == b) continue;
        if (!visibleKeys.contains(a) || !visibleKeys.contains(b)) continue;
        adj.putIfAbsent(a, () => {}).add(b);
        adj.putIfAbsent(b, () => {}).add(a);
      }
      // Seed with the center; if it IS a canvas, also its inside items, so the
      // canvas's aggregate cluster is present (matches the Connections menu).
      final seeds = <String>{center};
      final cd = lookup[ck];
      if (cd != null &&
          cd.canvasId != null &&
          (cd.leafId == cd.canvasId || cd.kind == LinkTargetKind.canvas)) {
        for (final k in visibleKeys) {
          if (lookup[k]?.canvasId == cd.canvasId) seeds.add(k);
        }
      }
      final keep = <String>{...seeds};
      var frontier = <String>{...seeds};
      for (var d = 0; d < depth && frontier.isNotEmpty; d++) {
        final next = <String>{};
        for (final k in frontier) {
          for (final nb in adj[k] ?? const <String>{}) {
            if (keep.add(nb)) next.add(nb);
          }
        }
        frontier = next;
      }
      final canvasIds = <String>{};
      for (final k in keep) {
        final cid = lookup[k]?.canvasId;
        if (cid != null) canvasIds.add(cid);
      }
      if (canvasIds.isNotEmpty) {
        for (final k in visibleKeys) {
          final cid = lookup[k]?.canvasId;
          if (cid != null && canvasIds.contains(cid)) keep.add(k);
        }
      }
      keep.add(center);
      visibleKeys.removeWhere((k) => !keep.contains(k));
      if (lookup[center] != null) visibleKeys.add(center);
    }

    final rnd = math.Random(7);
    var i = 0;
    for (final key in visibleKeys) {
      final data = lookup[key];
      if (data == null) continue; // abstract target filtered/absent
      final prev = old[key];
      // Feature F: under a pinned project, a node with a saved position is held
      // fixed there. Existing nodes keep their LIVE position (prev.pos) so a
      // rebuild doesn't snap unsaved drags back; a NEW node seeds at its saved
      // spot. Fresh activation / pin-toggle-on snap everything via
      // [_applySavedLayout].
      final saved = projPinLayout ? _projLayout[key] : null;
      final pos = prev?.pos ??
          saved ??
          Offset(math.cos(i * 2.399) * (30 + i * 6),
                  math.sin(i * 2.399) * (30 + i * 6)) +
              Offset(rnd.nextDouble() * 8, rnd.nextDouble() * 8);
      final sim = GraphSimNode(data, pos);
      if (prev != null) {
        sim.vel = prev.vel;
        sim.fixed = prev.fixed; // keep a user-pinned node pinned across rebuilds
      }
      if (saved != null) {
        sim.fixed = true;
        if (prev == null) sim.vel = Offset.zero;
      }
      _nodes.add(sim);
      _byKey[key] = sim;
      i++;
    }

    // Remap + dedup edges; drop self-loops created by abstraction.
    final seen = <String>{};
    _edges = [];
    for (final e in _all.edges) {
      final a = remap(e.aKey);
      final b = remap(e.bKey);
      if (a == b) continue;
      if (!_byKey.containsKey(a) || !_byKey.containsKey(b)) continue;
      final id = a.compareTo(b) < 0 ? '$a|$b' : '$b|$a';
      if (!seen.add(id)) continue;
      _edges.add(GraphEdge(aKey: a, bKey: b, label: e.label));
    }

    // Active degree per node (for sizing) from the real edge set only.
    for (final e in _edges) {
      _byKey[e.aKey]?.activeDegree++;
      _byKey[e.bKey]?.activeDegree++;
    }

    // Implicit "same-canvas" grouping edges (dashed): connect every visible
    // inside-canvas item to its canvas node, so a canvas's items stay clustered
    // (and stay visible from any of them). Only when items are shown (not
    // abstracted). These don't affect node size.
    if (sameCanvasLinks && !abstractInsideItems) {
      // Map canvasId -> its canvas node key (the node whose leaf IS the canvas).
      final canvasNodeKey = <String, String>{};
      for (final n in _nodes) {
        final d = n.data;
        if (d.canvasId != null && d.leafId == d.canvasId) {
          canvasNodeKey[d.canvasId!] = d.key;
        }
      }
      final implicitSeen = <String>{};
      for (final n in _nodes) {
        final d = n.data;
        // an inside-canvas item (has a canvasId but isn't the canvas itself)
        if (d.canvasId == null || d.leafId == d.canvasId) continue;
        final hub = canvasNodeKey[d.canvasId!];
        if (hub == null || hub == d.key) continue;
        final id = d.key.compareTo(hub) < 0 ? '${d.key}|$hub' : '$hub|${d.key}';
        if (!implicitSeen.add(id) || seen.contains(id)) continue;
        _edges.add(GraphEdge(aKey: d.key, bKey: hub, implicit: true));
      }
    }

    _untangled = false; // let the layout re-untangle for the new content
    notifyListeners();
    _bumpUi();
    onWake?.call();
    onContentChanged?.call();
  }

  /// Screen-space radius of a node — grows with its active degree, scaled by the
  /// node-size slider.
  double radiusOf(GraphSimNode n) {
    final r = 5.0 + math.sqrt(n.activeDegree.toDouble()) * 2.6;
    return r.clamp(4.0, 22.0) * nodeSizeScale;
  }

  /// The full (unfiltered) node set — the filter tree builds its hierarchy from
  /// this so toggled-off containers still list.
  List<GraphNode> get allNodes => _all.nodes;

  /// Shows/hides a set of container ids at once (a checkbox toggles its whole
  /// subtree — self + descendants — so a parent cascades, but each stays
  /// independently re-checkable).
  void setSubtreeHidden(Iterable<String> ids, bool hidden) {
    var changed = false;
    for (final id in ids) {
      if (hidden) {
        changed |= hiddenContainers.add(id);
      } else {
        changed |= hiddenContainers.remove(id);
      }
    }
    if (changed) {
      _rebuildActive();
      _saveView();
    }
  }

  void setAbstractInsideItems(bool abstract, {bool persist = true}) {
    if (abstractInsideItems == abstract) return;
    abstractInsideItems = abstract;
    _rebuildActive();
    if (persist) SettingsService().saveGraphSettings(abstractItems: abstract);
  }

  void setShowExternal(bool show) {
    if (showExternal == show) return;
    showExternal = show;
    _rebuildActive();
    SettingsService().saveGraphSettings(showExternal: show);
  }

  void setShowUnlinked(bool show) {
    if (showUnlinked == show) return;
    showUnlinked = show;
    _rebuildActive();
    SettingsService().saveGraphSettings(showUnlinked: show);
  }

  /// Refreshes the tag list + per-item tag lookup (from TagService).
  void setTagData(List<TagDef> t, Map<String, Set<String>> byLeaf) {
    tags = t;
    _tagsByLeaf = byLeaf;
    final ids = t.map((x) => x.id).toSet();
    tagInclude.retainAll(ids);
    tagExclude.retainAll(ids);
    _rebuildActive();
  }

  /// Cycles a tag chip off → include → exclude → off.
  void cycleTag(String id) {
    if (tagInclude.remove(id)) {
      tagExclude.add(id);
    } else if (!tagExclude.remove(id)) {
      tagInclude.add(id);
    }
    _rebuildActive();
    _saveView();
  }

  void setTagMatchAll(bool v) {
    if (tagMatchAll == v) return;
    tagMatchAll = v;
    _rebuildActive();
    _saveView();
  }

  void clearTagFilter() {
    if (!hasTagFilter) return;
    tagInclude.clear();
    tagExclude.clear();
    _rebuildActive();
    _saveView();
  }

  void setProjects(List<ProjectDef> p) {
    projects = p;
    // Deactivate if the active project was deleted elsewhere.
    if (activeProjectId != null &&
        !p.any((d) => d.id == activeProjectId)) {
      activeProjectId = null;
      _projIncludes = {};
      _projExcludes = {};
    }
    _bumpUi();
  }

  /// Activates [id] with its include/exclude container ids (the graph scopes to
  /// the members those imply — see [isProjectMember]); pass a null [id] to
  /// deactivate.
  void setActiveProject(
      String? id, Set<String> includes, Set<String> excludes) {
    final changed = id != activeProjectId;
    activeProjectId = id;
    _projIncludes = id == null ? {} : includes;
    _projExcludes = id == null ? {} : excludes;
    // Feature F: adopt the project's saved layout + pin flag (from its def). The
    // saved layout is ALWAYS held (so a later pin-toggle can restore it without
    // a reload); it's only *applied* to node positions on a fresh activation
    // when pinned (see below). Toggling the pin never captures — only the
    // explicit "Save arrangement" persists positions.
    ProjectDef? def;
    if (id != null) {
      for (final d in projects) {
        if (d.id == id) {
          def = d;
          break;
        }
      }
    }
    projPinLayout = def?.pinLayout ?? false;
    _projLayout = def == null ? {} : _decodeLayout(def.layout);
    // Leaving a pinned arrangement (deactivate, or switch to a non-pinned
    // project) releases the pins so the force layout resumes; _rebuildActive
    // copies `fixed` by key, so clear it on the outgoing nodes first.
    if (!projPinLayout) {
      for (final n in _nodes) {
        n.fixed = false;
      }
    }
    // Switching INTO a project starts with all its items shown (checked); a
    // plain refresh (same id, e.g. on reload) preserves the user's unchecks.
    if (id != null && changed) hiddenContainers.clear();
    _rebuildActive();
    // Restore the saved arrangement only on a FRESH activation — a same-project
    // refresh (background reload) keeps live positions so unsaved drags survive.
    if (projPinLayout && changed) _applySavedLayout();
  }

  /// Snaps every node that has a saved position to it and fixes it (used on a
  /// fresh pinned activation and when the pin toggle is turned on). Does NOT
  /// capture/overwrite the saved layout — only "Save arrangement" does that.
  void _applySavedLayout() {
    for (final n in _nodes) {
      final p = _projLayout[n.data.key];
      if (p != null) {
        n.pos = p;
        n.vel = Offset.zero;
        n.fixed = true;
      }
    }
    notifyListeners();
  }

  /// Turns the active project's pin-layout on/off *live* (from the per-project
  /// pin toggle). ON restores the previously-saved arrangement and pins it; OFF
  /// releases the nodes so you can rearrange freely. Neither captures — the
  /// saved layout stays put until you press "Save arrangement" again.
  void setProjectPinLayoutActive(bool v) {
    if (activeProjectId == null || projPinLayout == v) return;
    projPinLayout = v;
    if (v) {
      _applySavedLayout();
    } else {
      for (final n in _nodes) {
        n.fixed = false;
      }
      onWake?.call();
    }
    notifyListeners();
    _bumpUi();
  }

  /// Merges [layout] (canonical key → world Offset) into the active project's
  /// in-memory saved arrangement, so a subsequent pin-toggle restores what was
  /// just saved without waiting for a store reload. The host persists it too.
  void updateSavedLayout(Map<String, List<double>> layout) {
    for (final e in layout.entries) {
      if (e.value.length >= 2) {
        _projLayout[e.key] = Offset(e.value[0], e.value[1]);
      }
    }
  }

  void setProjectPlusLinks(bool v) {
    if (projectPlusLinks == v) return;
    projectPlusLinks = v;
    _rebuildActive();
    _saveView();
  }

  void setAlwaysShowLabels(bool v) {
    if (alwaysShowLabels == v) return;
    alwaysShowLabels = v;
    notifyListeners();
    _bumpUi();
    SettingsService().saveGraphSettings(alwaysLabels: v);
  }

  void setSameCanvasLinks(bool v, {bool persist = true}) {
    if (sameCanvasLinks == v) return;
    sameCanvasLinks = v;
    _rebuildActive();
    if (persist) SettingsService().saveGraphSettings(sameCanvasLinks: v);
  }

  void setLabelOpacity(double v) {
    labelOpacity = v;
    notifyListeners();
    _bumpUi();
    SettingsService().saveGraphSettings(labelOpacity: v);
  }

  void setNodeSizeScale(double v) {
    nodeSizeScale = v;
    notifyListeners();
    _bumpUi();
    SettingsService().saveGraphSettings(nodeSize: v);
  }

  void setTextSizeScale(double v) {
    textSizeScale = v;
    notifyListeners();
    _bumpUi();
    SettingsService().saveGraphSettings(textSize: v);
  }

  void setLinkThickness(double v) {
    linkThickness = v;
    notifyListeners();
    _bumpUi();
    SettingsService().saveGraphSettings(linkThickness: v);
  }

  void setLinkOpacity(double v) {
    linkOpacity = v;
    notifyListeners();
    _bumpUi();
    SettingsService().saveGraphSettings(linkOpacity: v);
  }

  void setHighlightContainer(String? id) {
    if (highlightContainerId == id) return;
    highlightContainerId = id;
    notifyListeners();
    _bumpUi();
  }

  /// One physics iteration. Returns whether the layout is still moving (the
  /// ticker keeps running while true, or while a node is pinned/dragged).
  bool step() {
    final n = _nodes.length;
    if (n == 0) return false;
    for (final a in _nodes) {
      a.force = Offset.zero;
    }
    // Pairwise repulsion (O(n²) — fine for the modest node counts here).
    for (var i = 0; i < n; i++) {
      final a = _nodes[i];
      for (var j = i + 1; j < n; j++) {
        final b = _nodes[j];
        var d = a.pos - b.pos;
        var dist = d.distance;
        if (dist < 0.01) {
          d = Offset(0.01 * (i.isEven ? 1 : -1), 0.01);
          dist = 0.01;
        }
        final f = _kRepulsion / (dist * dist);
        final dir = d / dist;
        a.force += dir * f;
        b.force -= dir * f;
      }
    }
    // Spring attraction along edges (toward the rest length).
    for (final e in _edges) {
      final a = _byKey[e.aKey];
      final b = _byKey[e.bKey];
      if (a == null || b == null) continue;
      var d = b.pos - a.pos;
      var dist = d.distance;
      if (dist < 0.01) dist = 0.01;
      final dir = d / dist;
      final f = (dist - _kRest) * _kSpring;
      a.force += dir * f;
      b.force -= dir * f;
    }
    // Gentle gravity toward the origin so disconnected components don't drift.
    for (final a in _nodes) {
      a.force += -a.pos * _kGravity;
    }
    // Integrate.
    var maxSpeed = 0.0;
    for (final a in _nodes) {
      // The actively-dragged node and user-pinned nodes stay put (excluded
      // from integration) — this is what lets you place a node freely.
      if (identical(a, _pinned) || a.fixed) {
        a.vel = Offset.zero;
        continue;
      }
      a.vel = (a.vel + a.force) * _kDamping;
      // Clamp per-step displacement so a spike can't explode the layout.
      final speed = a.vel.distance;
      if (speed > 30) a.vel = a.vel / speed * 30;
      a.pos += a.vel;
      maxSpeed = math.max(maxSpeed, a.vel.distance);
    }
    final camMoving = _stepCamera();
    final settled =
        _pinned == null && !camMoving && maxSpeed <= _kSettleSpeed;
    // On first settle after a change, run a cheap crossing-reduction pass
    // (small graphs only) so links don't cross unless they must.
    if (settled && !_untangled) {
      _untangled = true;
      _reduceCrossings();
      notifyListeners();
      return true; // one more pass to redraw + let springs smooth
    }
    notifyListeners();
    return !settled;
  }

  /// Greedy crossing reduction for SMALL graphs: repeatedly swap the positions
  /// of two nodes when doing so lowers the total number of edge crossings. The
  /// sim has already spread the nodes, so this only relabels which node sits
  /// where. Gated by size (O(rounds·n²·edges²)) so it never costs on big graphs.
  void _reduceCrossings() {
    final n = _nodes.length;
    final m = _edges.length;
    if (n < 4 || n > 30 || m == 0 || m > 40) return;
    final idx = <String, int>{
      for (var i = 0; i < n; i++) _nodes[i].data.key: i
    };
    final ea = <int>[], eb = <int>[];
    for (final e in _edges) {
      final a = idx[e.aKey], b = idx[e.bKey];
      if (a != null && b != null && a != b) {
        ea.add(a);
        eb.add(b);
      }
    }
    final ec = ea.length;
    int crossings() {
      var x = 0;
      for (var p = 0; p < ec; p++) {
        for (var q = p + 1; q < ec; q++) {
          final a1 = ea[p], b1 = eb[p], a2 = ea[q], b2 = eb[q];
          if (a1 == a2 || a1 == b2 || b1 == a2 || b1 == b2) continue;
          if (_segIntersect(_nodes[a1].pos, _nodes[b1].pos, _nodes[a2].pos,
              _nodes[b2].pos)) {
            x++;
          }
        }
      }
      return x;
    }

    var best = crossings();
    for (var round = 0; round < 4 && best > 0; round++) {
      var improved = false;
      for (var i = 0; i < n; i++) {
        for (var j = i + 1; j < n; j++) {
          final pi = _nodes[i].pos, pj = _nodes[j].pos;
          _nodes[i].pos = pj;
          _nodes[j].pos = pi;
          final c2 = crossings();
          if (c2 < best) {
            best = c2;
            improved = true;
          } else {
            _nodes[i].pos = pi;
            _nodes[j].pos = pj;
          }
        }
      }
      if (!improved) break;
    }
  }

  /// True when segments p1p2 and p3p4 properly cross.
  static bool _segIntersect(Offset p1, Offset p2, Offset p3, Offset p4) {
    double cross(Offset o, Offset a, Offset b) =>
        (a.dx - o.dx) * (b.dy - o.dy) - (a.dy - o.dy) * (b.dx - o.dx);
    final d1 = cross(p3, p4, p1),
        d2 = cross(p3, p4, p2),
        d3 = cross(p1, p2, p3),
        d4 = cross(p1, p2, p4);
    return ((d1 > 0 && d2 < 0) || (d1 < 0 && d2 > 0)) &&
        ((d3 > 0 && d4 < 0) || (d3 < 0 && d4 > 0));
  }

  /// Lerps the camera toward its target; returns true while still animating.
  bool _stepCamera() {
    final pt = _camPanTarget;
    final zt = _camZoomTarget;
    if (pt == null || zt == null) return false;
    pan = Offset.lerp(pan, pt, _kCamLerp)!;
    zoom = zoom + (zt - zoom) * _kCamLerp;
    if ((pan - pt).distance < 0.5 && (zoom - zt).abs() < 0.001) {
      pan = pt;
      zoom = zt;
      _camPanTarget = null;
      _camZoomTarget = null;
      return false;
    }
    return true;
  }

  void _animateCameraTo(Offset targetPan, double targetZoom) {
    _camPanTarget = targetPan;
    _camZoomTarget = targetZoom;
    onWake?.call();
  }

  // ── Camera ────────────────────────────────────────────────────────────────

  void panBy(Offset delta) {
    pan += delta;
    notifyListeners();
  }

  void zoomAt(Offset screenFocal, double factor) {
    final newZoom = (zoom * factor).clamp(0.15, 6.0);
    if (newZoom == zoom) return;
    pan = screenFocal - (screenFocal - pan) * (newZoom / zoom);
    zoom = newZoom;
    notifyListeners();
  }

  /// Fits all visible nodes into the viewport (animated by default; [snap]
  /// jumps instantly for the first-size restore).
  void fitToScreen({bool snap = false}) => _fitTo(_nodes, snap: snap);

  /// Pans/zooms to frame the given nodes.
  void _fitTo(List<GraphSimNode> ns, {bool snap = false}) {
    if (ns.isEmpty || screenSize.isEmpty) return;
    var minX = double.infinity, minY = double.infinity;
    var maxX = -double.infinity, maxY = -double.infinity;
    for (final a in ns) {
      minX = math.min(minX, a.pos.dx);
      minY = math.min(minY, a.pos.dy);
      maxX = math.max(maxX, a.pos.dx);
      maxY = math.max(maxY, a.pos.dy);
    }
    final w = math.max(maxX - minX, 1);
    final h = math.max(maxY - minY, 1);
    const pad = 80.0;
    final zx = (screenSize.width - pad * 2) / w;
    final zy = (screenSize.height - pad * 2) / h;
    final targetZoom = math.min(zx, zy).clamp(0.15, 2.0);
    final cx = (minX + maxX) / 2;
    final cy = (minY + maxY) / 2;
    final targetPan = Offset(screenSize.width / 2 - cx * targetZoom,
        screenSize.height / 2 - cy * targetZoom);
    if (snap) {
      zoom = targetZoom;
      pan = targetPan;
      _camPanTarget = null;
      _camZoomTarget = null;
      notifyListeners();
    } else {
      _animateCameraTo(targetPan, targetZoom);
    }
  }

  /// Frames the visible nodes under container [id] (a filter-tree row tap).
  void focusContainer(String id) {
    final pts = _nodes
        .where((n) =>
            n.data.notebookId == id ||
            n.data.sectionId == id ||
            n.data.canvasId == id)
        .toList();
    _fitTo(pts);
  }

  GraphNode? nodeByKey(String? key) => key == null ? null : _byKey[key]?.data;

  // ── Interaction ─────────────────────────────────────────────────────────

  GraphSimNode? hitTest(Offset screenPos) {
    // Back-to-front (topmost drawn last) so the visually-on-top node wins.
    for (var i = _nodes.length - 1; i >= 0; i--) {
      final a = _nodes[i];
      final sp = canvasToScreen(a.pos);
      final r = radiusOf(a) + 6; // small tap slop
      if ((sp - screenPos).distance <= r) return a;
    }
    return null;
  }

  void beginDrag(GraphSimNode node) {
    _pinned = node;
    onWake?.call();
  }

  void dragTo(Offset screenPos) {
    final p = _pinned;
    if (p == null) return;
    p.pos = screenToCanvas(screenPos);
    p.vel = Offset.zero;
    notifyListeners();
  }

  void endDrag() {
    final p = _pinned;
    // With a project active you can always drag to ARRANGE — a dropped node
    // stays where placed (in-session) so you can lay the graph out, then press
    // "Save arrangement" to persist it. Dragging never auto-saves. With no
    // project active, the global "pin nodes on drag" fallback applies.
    final pinning = activeProjectId != null ? true : pinOnDrag;
    if (pinning) p?.fixed = true;
    _pinned = null;
    onWake?.call();
  }

  void setPinOnDrag(bool v, {bool persist = true}) {
    if (pinOnDrag == v) return;
    pinOnDrag = v;
    if (!v) {
      for (final n in _nodes) {
        n.fixed = false;
      }
      onWake?.call();
    }
    notifyListeners();
    _bumpUi(); // the filter/appearance panel rebuilds on uiVersion, not this
    if (persist) SettingsService().saveGraphSettings(pinOnDrag: v);
  }

  void setAutoScale(bool v, {bool persist = true}) {
    if (autoScale == v) return;
    autoScale = v;
    _bumpUi(); // appearance panel rebuilds on uiVersion
    if (persist) SettingsService().saveGraphSettings(autoScale: v);
  }

  /// Releases a single node back into the force layout (double-tap).
  void unfix(GraphSimNode node) {
    if (!node.fixed) return;
    node.fixed = false;
    onWake?.call();
  }

  /// Releases every pinned node — the "re-layout" action.
  void clearFixed() {
    var any = false;
    for (final n in _nodes) {
      if (n.fixed) {
        n.fixed = false;
        any = true;
      }
    }
    if (any) onWake?.call();
  }

  void setHover(String? key) {
    if (hoverKey == key) return;
    hoverKey = key;
    notifyListeners();
    _bumpUi();
  }

  @override
  void dispose() {
    uiVersion.dispose();
    super.dispose();
  }
}

/// The store-wide Connections graph (Obsidian-style). Force-directed layout,
/// pan/zoom/drag, and node-tap → reveal (or open external URLs). Backs a
/// desktop main-pane mode today; reusable as a mobile tab later.
class GraphScreen extends StatefulWidget {
  const GraphScreen({super.key});

  @override
  State<GraphScreen> createState() => _GraphScreenState();
}

class _GraphScreenState extends State<GraphScreen>
    with SingleTickerProviderStateMixin {
  final _controller = GraphController();
  late final Ticker _ticker;
  Timer? _reloadDebounce;

  bool _loading = true;
  bool _empty = false;
  bool _panelOpen = true; // filter/navigator tree panel (wide layout)
  double _mobileSheet = 0.14; // mobile bottom-panel height fraction (peek)
  // Snap resting points for the mobile sheet: peek / half / tall.
  static const _kSheetStops = [0.14, 0.5, 0.88];
  Timer? _fitDebounce; // auto-fit after a filter/data change settles

  // Drag/pan bookkeeping.
  GraphSimNode? _dragCandidate;
  bool _movedDuringGesture = false;
  double _lastScale = 1.0;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick);
    _controller.onWake = () {
      if (mounted && !_ticker.isActive) _ticker.start();
    };
    // Auto-fit the graph after any filter/data change (once the layout settles).
    _controller.onContentChanged = _scheduleAutoFit;
    _load();
    SyncService().dataVersion.addListener(_onData);
  }

  @override
  void dispose() {
    SyncService().dataVersion.removeListener(_onData);
    _reloadDebounce?.cancel();
    _fitDebounce?.cancel();
    _ticker.dispose();
    _controller.dispose();
    super.dispose();
  }

  /// Fit the graph once the sim has had a moment to settle after a change
  /// (debounced, so a burst of filter toggles coalesces into one fit).
  void _scheduleAutoFit() {
    if (!_controller.autoScale) return; // user turned off auto-scaling
    _fitDebounce?.cancel();
    _fitDebounce = Timer(const Duration(milliseconds: 700), () {
      if (mounted && _controller.autoScale) _controller.fitToScreen();
    });
  }

  void _onData() {
    // A store change may add/remove connections — rebuild, debounced so a burst
    // of edits (or a sync pull) coalesces into one walk.
    _reloadDebounce?.cancel();
    _reloadDebounce = Timer(const Duration(milliseconds: 400), _load);
  }

  Future<void> _load() async {
    final results = await Future.wait([
      GraphService().buildGraph(),
      GraphService().buildStructure(),
    ]);
    if (!mounted) return;
    final data = results[0] as GraphData;
    final structure = results[1] as GraphStructure;
    setState(() {
      _loading = false;
      // Empty only when there are no links AND nothing to show unlinked.
      _empty = data.isEmpty && structure.notebooks.isEmpty;
    });
    _controller.setStructure(structure);
    _controller.setData(data);
    // Tags (for the AND/OR/NOT filter chips + per-node lookup).
    final tags = await TagService().allTags();
    final tagsByLeaf = await TagService().tagIdsByLeaf();
    if (!mounted) return;
    _controller.setTagData(tags, tagsByLeaf);
    // Projects (list for the section; refresh the active one's members).
    final projs = await ProjectService().allProjects();
    if (!mounted) return;
    _controller.setProjects(projs);
    final active = _controller.activeProjectId;
    if (active != null) {
      final items = await ProjectService().membersOf(active);
      final inc =
          items.where((i) => !i.excluded).map((i) => i.endpoint.leafId).toSet();
      final exc =
          items.where((i) => i.excluded).map((i) => i.endpoint.leafId).toSet();
      if (mounted) _controller.setActiveProject(active, inc, exc);
    }
    // Auto-fit fires via onContentChanged (setData/setStructure/etc. above).
  }

  void _onTick(Duration _) {
    final active = _controller.step();
    if (!active) _ticker.stop();
  }

  // ── Gestures ──────────────────────────────────────────────────────────────

  void _onPointerDown(PointerDownEvent e) {
    _movedDuringGesture = false;
    _dragCandidate = _controller.hitTest(e.localPosition);
  }

  void _onSignal(PointerSignalEvent e) {
    if (e is PointerScrollEvent) {
      final factor = e.scrollDelta.dy < 0 ? 1.12 : 1 / 1.12;
      _controller.zoomAt(e.localPosition, factor);
    }
  }

  void _onScaleStart(ScaleStartDetails d) {
    _lastScale = 1.0;
    if (_dragCandidate != null && d.pointerCount == 1) {
      _controller.beginDrag(_dragCandidate!);
    }
  }

  void _onScaleUpdate(ScaleUpdateDetails d) {
    _movedDuringGesture = true;
    if (_dragCandidate != null && d.pointerCount == 1) {
      _controller.dragTo(d.localFocalPoint);
      return;
    }
    if (d.scale != 1.0) {
      _controller.zoomAt(d.localFocalPoint, d.scale / _lastScale);
      _lastScale = d.scale;
    }
    _controller.panBy(d.focalPointDelta);
  }

  void _onScaleEnd(ScaleEndDetails d) {
    if (_dragCandidate != null) _controller.endDrag();
    _dragCandidate = null;
  }

  void _onTapUp(TapUpDetails d) {
    if (_movedDuringGesture) return;
    final node = _controller.hitTest(d.localPosition);
    if (node != null) _activateNode(node);
  }

  Future<void> _activateNode(GraphSimNode node) async {
    final data = node.data;
    if (data.externalUrl != null) {
      await launchUrl(Uri.parse(data.externalUrl!),
          mode: LaunchMode.externalApplication);
      return;
    }
    if (!data.alive || data.reveal == null) {
      if (mounted) {
        showAppToast(context, 'That item was deleted — restore it to reopen.',
            error: true);
      }
      return;
    }
    _handOffElementFocus(data); // flash + precise scroll for in-canvas targets
    // Graph taps are deliberate navigation — open the actual place.
    LinkNavigator().openCanvas(data.reveal!);
  }

  void _onHover(PointerHoverEvent e) {
    final node = _controller.hitTest(e.localPosition);
    _controller.setHover(node?.data.key);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = theme.extension<AppPalette>()!;
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 640;
        final graph = _buildGraphArea(theme, palette, wide);
        if (wide) {
          // Desktop: a resizable-width side panel column.
          if (_panelOpen && !_empty && !_loading) {
            return Row(
              children: [
                Container(
                  width: 274,
                  decoration: BoxDecoration(
                    color: palette.surface2,
                    border: Border(right: BorderSide(color: palette.border)),
                  ),
                  child: _GraphFilterPanel(
                      controller: _controller, onReload: _load),
                ),
                Expanded(child: graph),
              ],
            );
          }
          return graph;
        }
        // Mobile: the graph SHRINKS into the space above a bottom panel (both
        // stay visible). Tap the handle to expand/retract the panel; the graph
        // re-fits into whatever room is left. The panel scrolls internally.
        if (_empty || _loading) return graph;
        final panelH = (constraints.maxHeight * _mobileSheet)
            .clamp(56.0, constraints.maxHeight * 0.9);
        return Column(
          children: [
            Expanded(child: graph),
            SizedBox(
                height: panelH, child: _mobileBottomPanel(constraints, palette)),
          ],
        );
      },
    );
  }

  /// Sets the mobile sheet height fraction and re-fits the graph into the space
  /// that remains (so it stays fully visible, just more zoomed out).
  void _setSheet(double v) {
    setState(() => _mobileSheet = v);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _controller.fitToScreen();
    });
  }

  Widget _mobileBottomPanel(BoxConstraints constraints, AppPalette palette) {
    return Material(
      elevation: 10,
      color: palette.surface2,
      child: Column(
        children: [
          // Handle: TAP to expand/retract (peek ↔ tall); drag for fine control,
          // snapping to peek/half/tall on release. Either way the graph re-fits.
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => _setSheet(_mobileSheet <= 0.2 ? 0.6 : 0.14),
            onVerticalDragUpdate: (d) => setState(() {
              _mobileSheet =
                  (_mobileSheet - d.primaryDelta! / constraints.maxHeight)
                      .clamp(0.1, 0.9);
            }),
            onVerticalDragEnd: (_) => _setSheet(_kSheetStops.reduce((a, b) =>
                (a - _mobileSheet).abs() < (b - _mobileSheet).abs() ? a : b)),
            child: Container(
              height: 22,
              alignment: Alignment.center,
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: palette.border,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
          ),
          Expanded(
            child: _GraphFilterPanel(
                controller: _controller, onReload: _load),
          ),
        ],
      ),
    );
  }

  Widget _buildGraphArea(ThemeData theme, AppPalette palette, bool wide) {
    return Container(
      color: palette.canvas,
      child: Stack(
        children: [
          Positioned.fill(
            child: LayoutBuilder(
              builder: (context, constraints) {
                _controller.setScreenSize(constraints.biggest);
                if (_loading) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (_empty) return _emptyState(palette);
                return MouseRegion(
                  onHover: _onHover,
                  onExit: (_) => _controller.setHover(null),
                  child: Listener(
                    onPointerDown: _onPointerDown,
                    onPointerSignal: _onSignal,
                    child: RawGestureDetector(
                      gestures: {
                        ScaleGestureRecognizer:
                            GestureRecognizerFactoryWithHandlers<
                                ScaleGestureRecognizer>(
                          () => ScaleGestureRecognizer(),
                          (r) => r
                            ..onStart = _onScaleStart
                            ..onUpdate = _onScaleUpdate
                            ..onEnd = _onScaleEnd,
                        ),
                        TapGestureRecognizer:
                            GestureRecognizerFactoryWithHandlers<
                                TapGestureRecognizer>(
                          () => TapGestureRecognizer(),
                          (r) => r..onTapUp = _onTapUp,
                        ),
                      },
                      child: CustomPaint(
                        painter: _GraphPainter(_controller, palette, theme),
                        size: Size.infinite,
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          _topBar(palette, wide),
        ],
      ),
    );
  }

  Widget _topBar(AppPalette palette, bool wide) {
    final panelShown = wide && _panelOpen;
    return Positioned(
      // Keep the floating controls below the status-bar / notch inset so they
      // don't cover the top nodes (e.g. desktop layout shown in a mobile tab).
      top: MediaQuery.of(context).padding.top + 12,
      left: 16,
      right: 16,
      child: Row(
        children: [
          // Only desktop needs a toggle — mobile always shows the bottom sheet.
          if (wide && !_empty && !_loading)
            _iconPill(
              palette,
              panelShown ? Icons.chevron_left : Icons.filter_list,
              'Filter & navigate',
              () => setState(() => _panelOpen = !_panelOpen),
            ),
          if (wide) const SizedBox(width: 8),
          Icon(Icons.hub_outlined, size: 18, color: palette.textDim),
          const SizedBox(width: 8),
          Text('Connections graph',
              style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: palette.textDim)),
          const Spacer(),
          if (!_empty && !_loading)
            _pill(palette, Icons.center_focus_strong_outlined, 'Fit',
                () => _controller.fitToScreen()),
        ],
      ),
    );
  }

  Widget _iconPill(
      AppPalette palette, IconData icon, String tooltip, VoidCallback onTap) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: palette.surface2,
        borderRadius: BorderRadius.circular(kRadius),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(kRadius),
          child: Padding(
            padding: const EdgeInsets.all(7),
            child: Icon(icon, size: 16, color: palette.textDim),
          ),
        ),
      ),
    );
  }

  Widget _pill(
      AppPalette palette, IconData icon, String label, VoidCallback onTap) {
    return Material(
      color: palette.surface2,
      borderRadius: BorderRadius.circular(kRadius),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(kRadius),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 15, color: palette.textDim),
            const SizedBox(width: 6),
            Text(label,
                style: TextStyle(fontSize: 12.5, color: palette.textDim)),
          ]),
        ),
      ),
    );
  }

  Widget _emptyState(AppPalette palette) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.hub_outlined, size: 56, color: palette.textDim),
          const SizedBox(height: 16),
          Text('No connections yet',
              style: TextStyle(fontSize: 15, color: palette.textDim)),
          const SizedBox(height: 6),
          SizedBox(
            width: 320,
            child: Text(
              'Link items with “Copy link” → paste, or the [[ trigger while '
              'typing. Connected items appear here as a graph.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12.5, color: palette.textDim),
            ),
          ),
        ],
      ),
    );
  }
}

/// Node silhouettes — one per kind so type reads at a glance.
enum _NodeShape { circle, box, triangle, diamond, pentagon, hexagon }

/// Before navigating to a graph node, hand the target's element ids to the
/// destination canvas (via the one-shot pending-focus channel) so it flashes +
/// scrolls to them — matching the Connections list's behavior. No-op for
/// non-element targets.
void _handOffElementFocus(GraphNode data) {
  final ep = LinkEndpoint.sideFrom(data.key);
  if (ep != null &&
      ep.elementIds.isNotEmpty &&
      ep.canvasId != null &&
      ep.pageId != null) {
    LinkNavigator().pendingElementFocus = (
      canvasId: ep.canvasId!,
      pageId: ep.pageId!,
      elementIds: ep.elementIds,
    );
  }
}

/// Silhouette per node kind (user request): notebook=hexagon, section=box,
/// folder=pentagon, canvas=circle, inside-canvas item (page/element/bookmark)=
/// triangle, external=diamond.
_NodeShape _shapeFor(GraphNode n) {
  switch (n.kind) {
    case LinkTargetKind.notebook:
      return _NodeShape.hexagon;
    case LinkTargetKind.section:
      return _NodeShape.box;
    case LinkTargetKind.folder:
      return _NodeShape.pentagon;
    case LinkTargetKind.canvas:
      return _NodeShape.circle;
    case LinkTargetKind.page:
    case LinkTargetKind.element:
    case LinkTargetKind.bookmark:
      return _NodeShape.triangle;
    case LinkTargetKind.external:
      return _NodeShape.diamond;
  }
}

void _paintShape(
    Canvas canvas, _NodeShape shape, Offset c, double r, Paint paint) {
  switch (shape) {
    case _NodeShape.circle:
      canvas.drawCircle(c, r, paint);
      return;
    case _NodeShape.box:
      canvas.drawRRect(
          RRect.fromRectAndRadius(
              Rect.fromCenter(center: c, width: r * 1.8, height: r * 1.8),
              Radius.circular(r * 0.32)),
          paint);
      return;
    case _NodeShape.triangle:
      canvas.drawPath(_polygon(c, r * 1.15, 3, -math.pi / 2), paint);
      return;
    case _NodeShape.diamond:
      canvas.drawPath(_polygon(c, r * 1.15, 4, -math.pi / 2), paint);
      return;
    case _NodeShape.pentagon:
      canvas.drawPath(_polygon(c, r * 1.12, 5, -math.pi / 2), paint);
      return;
    case _NodeShape.hexagon:
      canvas.drawPath(_polygon(c, r * 1.12, 6, -math.pi / 2), paint);
      return;
  }
}

/// A regular [sides]-gon centered at [c], circumradius [r], first vertex at
/// [startAngle].
Path _polygon(Offset c, double r, int sides, double startAngle) {
  final p = Path();
  for (var i = 0; i < sides; i++) {
    final a = startAngle + i * 2 * math.pi / sides;
    final pt = Offset(c.dx + r * math.cos(a), c.dy + r * math.sin(a));
    if (i == 0) {
      p.moveTo(pt.dx, pt.dy);
    } else {
      p.lineTo(pt.dx, pt.dy);
    }
  }
  p.close();
  return p;
}

class _GraphPainter extends CustomPainter {
  final GraphController c;
  final AppPalette palette;
  final ThemeData theme;

  _GraphPainter(this.c, this.palette, this.theme) : super(repaint: c);

  @override
  void paint(Canvas canvas, Size size) {
    // Precompute screen positions once (avoids an O(edges×nodes) scan).
    final screenPos = <String, Offset>{
      for (final n in c.nodes) n.data.key: c.canvasToScreen(n.pos),
    };
    final hover = c.hoverKey;
    // Neighbors of the hovered node (for emphasis).
    final Set<String> neighbors = {};
    if (hover != null) {
      for (final e in c.edges) {
        if (e.aKey == hover) neighbors.add(e.bKey);
        if (e.bKey == hover) neighbors.add(e.aKey);
      }
    }

    // Edges (thickness + opacity from the appearance sliders; textDim reads
    // brighter than dot so the opacity slider can reach clearly-visible links).
    final edgePaint = Paint()
      ..style = PaintingStyle.stroke
      ..color = palette.textDim.withValues(alpha: c.linkOpacity)
      ..strokeWidth = c.linkThickness;
    final edgeHot = Paint()
      ..style = PaintingStyle.stroke
      ..color = palette.accent.withValues(alpha: math.max(0.9, c.linkOpacity))
      ..strokeWidth = c.linkThickness * 1.6;
    // Implicit same-canvas grouping edges are drawn dashed + dimmer.
    final implicitPaint = Paint()
      ..style = PaintingStyle.stroke
      ..color = palette.textDim.withValues(alpha: c.linkOpacity * 0.55)
      ..strokeWidth = c.linkThickness * 0.8;
    for (final e in c.edges) {
      final a = screenPos[e.aKey];
      final b = screenPos[e.bKey];
      if (a == null || b == null) continue;
      if (e.implicit) {
        _dashLine(canvas, a, b, implicitPaint);
        continue;
      }
      final hot = hover != null && (e.aKey == hover || e.bKey == hover);
      canvas.drawLine(a, b, hot ? edgeHot : edgePaint);
    }

    // Nodes.
    final showLabels = c.alwaysShowLabels || c.zoom > 0.45;
    final hlContainer = c.highlightContainerId;
    for (final node in c.nodes) {
      final d = node.data;
      final sp = screenPos[d.key]!;
      final r = c.radiusOf(node);
      final isHover = d.key == hover;
      final isNeighbor = neighbors.contains(d.key);
      final isCenter = c.centerKey != null && d.key == c.centerKey;
      final dim = hover != null && !isHover && !isNeighbor && !isCenter;
      // Matches a container hovered in the filter tree.
      final treeHit = hlContainer != null &&
          (d.notebookId == hlContainer ||
              d.sectionId == hlContainer ||
              d.canvasId == hlContainer);

      Color fill;
      if (!d.alive) {
        fill = palette.textDim.withValues(alpha: 0.5);
      } else if (d.externalUrl != null) {
        fill = const Color(0xFF2AA5B5); // teal for external
      } else {
        fill = d.color ?? palette.accent;
      }
      if (dim) fill = fill.withValues(alpha: 0.28);

      // Halo — tree-hit is strongest, then hover, then neighbor.
      if (treeHit || isHover || isNeighbor) {
        final ha = treeHit ? 0.28 : (isHover ? 0.18 : 0.12);
        canvas.drawCircle(
            sp,
            r + (treeHit ? 8 : (isHover ? 6 : 3)),
            Paint()..color = palette.accent.withValues(alpha: ha));
      }
      // Local-graph center: a prominent accent ring (a soft fill + a crisp
      // stroke), so the focused node reads at a glance — not just a faint glow.
      if (isCenter) {
        canvas.drawCircle(sp, r + 9,
            Paint()..color = palette.accent.withValues(alpha: 0.14));
        canvas.drawCircle(
            sp,
            r + 9,
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = 2.5
              ..color = palette.accent);
      }

      final fillPaint = Paint()
        ..color = fill
        ..style = PaintingStyle.fill;
      _paintShape(canvas, _shapeFor(d), sp, r, fillPaint);
      // Thin canvas-colored outline so overlapping shapes stay legible, plus a
      // stronger ring for external / dead so they read at a glance.
      _paintShape(
          canvas,
          _shapeFor(d),
          sp,
          r,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = (d.externalUrl != null || !d.alive) ? 1.4 : 0.8
            ..color = (d.externalUrl != null || !d.alive)
                ? palette.canvas
                : palette.canvas.withValues(alpha: 0.6));

      // A small dot marks a user-pinned (dragged-in-place) node.
      if (node.fixed) {
        canvas.drawCircle(
            Offset(sp.dx + r * 0.72, sp.dy - r * 0.72),
            2.4,
            Paint()..color = palette.accent);
      }

      if (showLabels || isHover || treeHit) {
        _label(canvas, node, sp, r, dim && !treeHit);
      }
    }
  }

  void _dashLine(Canvas canvas, Offset a, Offset b, Paint p,
      {double dash = 5, double gap = 4}) {
    final total = (b - a).distance;
    if (total < 0.5) return;
    final dir = (b - a) / total;
    var d = 0.0;
    while (d < total) {
      final s = a + dir * d;
      final e = a + dir * math.min(d + dash, total);
      canvas.drawLine(s, e, p);
      d += dash + gap;
    }
  }

  void _label(Canvas canvas, GraphSimNode node, Offset sp, double r, bool dim) {
    var text = node.data.title;
    if (text.length > 26) text = '${text.substring(0, 25)}…';
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          fontSize: 11.5 * c.textSizeScale,
          color: (node.data.alive
                  ? theme.colorScheme.onSurface
                  : palette.textDim)
              .withValues(alpha: (dim ? 0.35 : 1.0) * c.labelOpacity),
        ),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
      ellipsis: '…',
    )..layout(maxWidth: 160);
    tp.paint(canvas, Offset(sp.dx - tp.width / 2, sp.dy + r + 3));
  }

  @override
  bool shouldRepaint(covariant _GraphPainter old) => false; // repaint: c drives
}

/// The graph's filter + navigator panel: the full store tree (notebook →
/// section-group → section → canvas-folder → canvas). Checkboxes scope which
/// nodes show; hovering a row highlights its nodes in the graph (and vice
/// versa); tapping a row frames its nodes; a link mode creates connections by
/// picking two rows. Reused as a side column (wide) and a bottom sheet (narrow).
class _GraphFilterPanel extends StatefulWidget {
  final GraphController controller;

  /// Refreshes graph data after a mutation here (links/projects persist but
  /// don't bump dataVersion). Awaited before the panel closes its editor, so
  /// the just-created project is in `controller.projects` when the list rebuilds
  /// — the global graph re-queries via `_load`, the local panel via
  /// `_loadFilters` (previously it only rebuilt nodes, so new projects never
  /// appeared in its settings — the bug this fixes).
  final Future<void> Function()? onReload;
  const _GraphFilterPanel({required this.controller, this.onReload});

  @override
  State<_GraphFilterPanel> createState() => _GraphFilterPanelState();
}

class _GraphFilterPanelState extends State<_GraphFilterPanel> {
  final Set<String> _expanded = {};
  bool _appearanceOpen = false;
  bool _filterOpen = false; // the notebook/section/canvas tree, collapsed by default
  bool _tagsOpen = false;
  bool _projectsOpen = false;
  bool _linkMode = false;
  GraphContainer? _linkFrom; // link-mode source (null until first pick)

  // Project build/edit mode (null = not editing). Membership is inheriting: an
  // include on a container covers its whole subtree, an exclude carves one out;
  // a row's checkbox reflects the *effective* state and only writes an explicit
  // marker when it differs from what's inherited (see [_toggleMember]).
  String? _peId; // null = creating a new project
  final TextEditingController _peName = TextEditingController();
  final Set<String> _peIncludes = {};
  final Set<String> _peExcludes = {};
  bool _editingProject = false;

  GraphController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    // Restore panel expand states (device-local).
    final gv = SettingsService().graphView;
    _filterOpen = gv['pFilter'] == true;
    _tagsOpen = gv['pTags'] == true;
    _projectsOpen = gv['pProjects'] == true;
    _appearanceOpen = gv['pAppearance'] == true;
    _expanded.addAll((gv['pExpanded'] as List?)?.whereType<String>() ?? const []);
  }

  void _savePanelUi() => SettingsService().patchGraphView({
        'pFilter': _filterOpen,
        'pTags': _tagsOpen,
        'pProjects': _projectsOpen,
        'pAppearance': _appearanceOpen,
        'pExpanded': _expanded.toList(),
      });

  @override
  void dispose() {
    _peName.dispose();
    super.dispose();
  }

  /// A container's own id plus every descendant container id — the set a
  /// checkbox toggles (cascade), while each stays independently re-checkable.
  List<String> _subtreeIds(GraphContainer g) {
    final out = <String>[g.id];
    for (final ch in g.children) {
      out.addAll(_subtreeIds(ch));
    }
    return out;
  }

  /// The tag filter: each chip cycles off → include → exclude, plus an
  /// ANY/ALL switch governing how the includes combine (excludes always remove).
  Widget _tagsFilterBody(AppPalette palette) {
    final error = Theme.of(context).colorScheme.error;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 0, 12, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('Match', style: TextStyle(fontSize: 11.5, color: palette.textDim)),
              const SizedBox(width: 8),
              _matchOption(palette, 'Any', !c.tagMatchAll,
                  () => c.setTagMatchAll(false)),
              const SizedBox(width: 4),
              _matchOption(palette, 'All', c.tagMatchAll,
                  () => c.setTagMatchAll(true)),
              const Spacer(),
              if (c.hasTagFilter)
                InkWell(
                  onTap: c.clearTagFilter,
                  child: Text('Clear',
                      style: TextStyle(fontSize: 11.5, color: palette.accent)),
                ),
            ],
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final t in c.tags)
                _tagChip(palette, error, t, c.tagState(t.id)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _matchOption(
      AppPalette palette, String label, bool active, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(
          color: active ? palette.accentSoft : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
              color: active ? palette.accent : palette.border),
        ),
        child: Text(label,
            style: TextStyle(
                fontSize: 11.5,
                color: active ? palette.accent : palette.textDim)),
      ),
    );
  }

  Widget _tagChip(AppPalette palette, Color error, TagDef t, int state) {
    final Color bg, fg, border;
    switch (state) {
      case 1: // include
        bg = palette.accentSoft;
        fg = palette.accent;
        border = palette.accent;
      case 2: // exclude
        bg = error.withValues(alpha: 0.12);
        fg = error;
        border = error;
      default: // off
        bg = palette.surface2;
        fg = palette.textDim;
        border = palette.border;
    }
    return InkWell(
      onTap: () => c.cycleTag(t.id),
      borderRadius: BorderRadius.circular(20),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: border),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (state == 1)
              Padding(
                padding: const EdgeInsets.only(right: 3),
                child: Icon(Icons.check, size: 12, color: fg),
              )
            else if (state == 2)
              Padding(
                padding: const EdgeInsets.only(right: 3),
                child: Icon(Icons.block, size: 12, color: fg),
              ),
            Text(t.name,
                style: TextStyle(
                    fontSize: 12,
                    color: fg,
                    decoration:
                        state == 2 ? TextDecoration.lineThrough : null)),
          ],
        ),
      ),
    );
  }

  // ── Projects ──────────────────────────────────────────────────────────────

  Map<String, GraphContainer> _containersById() {
    final out = <String, GraphContainer>{};
    void walk(GraphContainer g) {
      out[g.id] = g;
      for (final ch in g.children) {
        walk(ch);
      }
    }

    final s = c.structure;
    if (s != null) {
      for (final nb in s.notebooks) {
        walk(nb);
      }
    }
    return out;
  }

  Widget _projectsBody(AppPalette palette) {
    final onSurface = Theme.of(context).colorScheme.onSurface;
    final active = c.activeProjectId;
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 0, 8, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (active != null)
            // "Include linked neighbors" is project-specific and stays here.
            // "Show items without links" is a global view toggle (up in the View
            // section) — it drives the same c.showUnlinked, so it was a
            // confusing duplicate here and is removed.
            _toggle(palette, 'Include linked neighbors', c.projectPlusLinks,
                (v) => c.setProjectPlusLinks(v)),
          if (active != null)
            // Feature F: the pin (restore/lock) is the per-project pin icon on
            // each row. Arranging is always free while a project is active
            // (drag → stays); "Save arrangement" persists the current layout to
            // this project (synced) — it's the ONLY thing that overwrites the
            // saved positions, so a pin-toggle never loses them.
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () => _saveProjectArrangement(active),
                icon: const Icon(Icons.save_outlined, size: 15),
                label: const Text('Save arrangement',
                    style: TextStyle(fontSize: 12)),
                style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 6)),
              ),
            ),
          for (final p in c.projects)
            _projectRow(palette, onSurface, p, p.id == active),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: _startNewProject,
              icon: const Icon(Icons.add, size: 16),
              label: const Text('New project', style: TextStyle(fontSize: 12.5)),
              style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 6)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _projectRow(
      AppPalette palette, Color onSurface, ProjectDef p, bool active) {
    return InkWell(
      onTap: () => _activate(p),
      child: Container(
        color: active ? palette.accentSoft : null,
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        child: Row(
          children: [
            Icon(active ? Icons.folder_open : Icons.folder_outlined,
                size: 15, color: active ? palette.accent : palette.textDim),
            const SizedBox(width: 8),
            Expanded(
              child: Text(p.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 12.5,
                      color: active ? palette.accent : onSurface,
                      fontWeight: active ? FontWeight.w600 : FontWeight.w400)),
            ),
            // Feature F: per-project pin. Glows (filled + accent) when this
            // project's saved arrangement is pinned; tap to toggle. Turning it
            // on restores the saved positions and locks them; off frees the
            // nodes. Never overwrites the saved layout — that's "Save
            // arrangement" only. Tapping a non-active project's pin activates it.
            IconButton(
              icon: Icon(p.pinLayout ? Icons.push_pin : Icons.push_pin_outlined,
                  size: 15),
              color: p.pinLayout ? palette.accent : palette.textDim,
              visualDensity: VisualDensity.compact,
              tooltip: p.pinLayout ? 'Unpin arrangement' : 'Pin arrangement',
              onPressed: () => _togglePinForProject(p),
            ),
            IconButton(
              icon: const Icon(Icons.edit_outlined, size: 15),
              color: palette.textDim,
              visualDensity: VisualDensity.compact,
              tooltip: 'Edit project',
              onPressed: () => _editProject(p),
            ),
            IconButton(
              icon: const Icon(Icons.delete_outline, size: 15),
              color: palette.textDim,
              visualDensity: VisualDensity.compact,
              tooltip: 'Delete project',
              onPressed: () => _deleteProject(p),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _activate(ProjectDef p) async {
    if (c.activeProjectId == p.id) {
      c.setActiveProject(null, {}, {});
      return;
    }
    final items = await ProjectService().membersOf(p.id);
    final inc =
        items.where((i) => !i.excluded).map((i) => i.endpoint.leafId).toSet();
    final exc =
        items.where((i) => i.excluded).map((i) => i.endpoint.leafId).toSet();
    c.setActiveProject(p.id, inc, exc);
  }

  /// Feature F: the per-project pin toggle. Turning it ON restores that
  /// project's saved arrangement and locks it; OFF frees the nodes. It NEVER
  /// captures positions (so the saved layout is untouched until "Save
  /// arrangement"); it only flips the persisted `pinLayout` flag. Tapping a
  /// non-active project's pin activates it first so the restore is visible.
  Future<void> _togglePinForProject(ProjectDef p) async {
    final newVal = !p.pinLayout;
    if (c.activeProjectId != p.id) {
      await _activate(p); // make it active so restore/release applies live
      if (!mounted) return;
    }
    if (c.activeProjectId == p.id) c.setProjectPinLayoutActive(newVal);
    await ProjectService().setProjectPinLayout(p.id, newVal);
    if (mounted) setState(() {}); // refresh the pin glow
  }

  /// Persist the current node arrangement to [projectId] (merged into its saved
  /// layout, so a depth-scoped local save keeps off-screen nodes). This is the
  /// only path that overwrites saved positions. Keeps the current pin state.
  Future<void> _saveProjectArrangement(String projectId) async {
    final captured = c.captureLayout();
    c.updateSavedLayout(captured); // so a pin-toggle restores what we just saved
    await ProjectService()
        .setProjectLayout(projectId, captured, pinLayout: c.projPinLayout);
    if (mounted) {
      showAppToast(context, 'Arrangement saved');
    }
  }

  void _startNewProject() => setState(() {
        _peId = null;
        _peName.text = '';
        _peIncludes.clear();
        _peExcludes.clear();
        _editingProject = true;
      });

  Future<void> _editProject(ProjectDef p) async {
    final items = await ProjectService().membersOf(p.id);
    if (!mounted) return;
    setState(() {
      _peId = p.id;
      _peName.text = p.name;
      _peIncludes
        ..clear()
        ..addAll(items.where((i) => !i.excluded).map((i) => i.endpoint.leafId));
      _peExcludes
        ..clear()
        ..addAll(items.where((i) => i.excluded).map((i) => i.endpoint.leafId));
      _editingProject = true;
    });
  }

  Future<void> _deleteProject(ProjectDef p) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete project “${p.name}”?'),
        content: const Text('The items themselves are not affected.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true) return;
    if (c.activeProjectId == p.id) c.setActiveProject(null, {}, {});
    await ProjectService().deleteProject(p.id);
    await widget.onReload?.call();
    if (mounted) setState(() {});
  }

  Future<void> _saveProject() async {
    final name = _peName.text.trim();
    if (name.isEmpty) return;
    String pid;
    if (_peId == null) {
      pid = (await ProjectService().createProject(name)).id;
    } else {
      await ProjectService().renameProject(_peId!, name);
      pid = _peId!;
    }
    final byId = _containersById();
    final includes = _peIncludes
        .map((id) => byId[id]?.endpoint)
        .whereType<LinkEndpoint>()
        .toList();
    final excludes = _peExcludes
        .map((id) => byId[id]?.endpoint)
        .whereType<LinkEndpoint>()
        .toList();
    await ProjectService()
        .setMembers(pid, includes: includes, excludes: excludes);
    if (!mounted) return;
    // Refresh the project list (await) BEFORE closing the editor, so the new
    // project is present when the list rebuilds — on both graphs.
    await widget.onReload?.call();
    if (mounted) setState(() => _editingProject = false);
  }

  Widget _buildProjectEditor(AppPalette palette) {
    final onSurface = Theme.of(context).colorScheme.onSurface;
    _computeCounts();
    final rows = <Widget>[];
    final struct = c.structure;
    if (struct != null) {
      final roots = [...struct.notebooks]
        ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      for (final nb in roots) {
        _appendRows(rows, nb, 0, const <String>{}, palette, editMode: true);
      }
    }
    return SafeArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(6, 8, 8, 4),
            child: Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.chevron_left, size: 22),
                  tooltip: 'Cancel',
                  onPressed: () => setState(() => _editingProject = false),
                ),
                Text(_peId == null ? 'New project' : 'Edit project',
                    style: TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w700,
                        color: onSurface)),
                const Spacer(),
                FilledButton(
                    onPressed: _saveProject, child: const Text('Save')),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 6),
            child: TextField(
              controller: _peName,
              decoration: const InputDecoration(
                  isDense: true, hintText: 'Project name'),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 6),
            child: Text(
                'Check a section or notebook to include everything in it — '
                'new items join automatically; uncheck any to exclude it',
                style: TextStyle(fontSize: 11.5, color: palette.textDim)),
          ),
          Divider(height: 1, color: palette.border),
          Expanded(
            child: rows.isEmpty
                ? Center(
                    child: Text('No items in the store yet',
                        style:
                            TextStyle(fontSize: 12, color: palette.textDim)))
                : ListView(padding: EdgeInsets.zero, children: rows),
          ),
        ],
      ),
    );
  }

  Widget _sectionHeader(
      AppPalette palette, String label, bool open, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 6, 14, 6),
        child: Row(
          children: [
            Icon(open ? Icons.expand_more : Icons.chevron_right,
                size: 16, color: palette.textDim),
            const SizedBox(width: 4),
            Text(label,
                style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: Theme.of(context).colorScheme.onSurface)),
          ],
        ),
      ),
    );
  }

  // Per-build node-count cache (subtree-inclusive) + the raw by-container maps.
  final Map<String, int> _count = {};
  Map<String, int> _byNb = const {};
  Map<String, int> _bySec = const {};
  Map<String, int> _byCanvas = const {};

  /// Recomputes per-container node counts (subtree-inclusive via [_countOf])
  /// from the link graph — used for the tree's counts + shape coloring.
  void _computeCounts() {
    _count.clear();
    final byNb = <String, int>{}, bySec = <String, int>{},
        byCanvas = <String, int>{};
    for (final n in c.allNodes) {
      if (n.notebookId != null) {
        byNb[n.notebookId!] = (byNb[n.notebookId!] ?? 0) + 1;
      }
      if (n.sectionId != null) {
        bySec[n.sectionId!] = (bySec[n.sectionId!] ?? 0) + 1;
      }
      if (n.canvasId != null) {
        byCanvas[n.canvasId!] = (byCanvas[n.canvasId!] ?? 0) + 1;
      }
    }
    _byNb = byNb;
    _bySec = bySec;
    _byCanvas = byCanvas;
  }

  int _countOf(GraphContainer g) => _count.putIfAbsent(g.id, () {
        switch (g.kind) {
          case GraphContainerKind.notebook:
            return _byNb[g.id] ?? 0;
          case GraphContainerKind.section:
            return _bySec[g.id] ?? 0;
          case GraphContainerKind.canvas:
            return _byCanvas[g.id] ?? 0;
          case GraphContainerKind.sectionGroup:
          case GraphContainerKind.canvasFolder:
            var s = 0;
            for (final ch in g.children) {
              s += _countOf(ch);
            }
            return s;
        }
      });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = theme.extension<AppPalette>()!;
    return ValueListenableBuilder<int>(
      valueListenable: c.uiVersion,
      builder: (context, _, _) {
        _computeCounts();
        if (_editingProject) return _buildProjectEditor(palette);
        final hn = c.nodeByKey(c.hoverKey);
        final hlIds = <String>{
          if (hn?.notebookId != null) hn!.notebookId!,
          if (hn?.sectionId != null) hn!.sectionId!,
          if (hn?.canvasId != null) hn!.canvasId!,
        };
        final rows = <Widget>[];
        final struct = c.structure;
        if (struct != null) {
          final roots = [...struct.notebooks]
            ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
          for (final nb in roots) {
            _appendRows(rows, nb, 0, hlIds, palette);
          }
        }
        return SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 14, 6, 6),
                child: Row(
                  children: [
                    Text('Filter & navigate',
                        style: TextStyle(
                            fontSize: 13.5,
                            fontWeight: FontWeight.w700,
                            color: theme.colorScheme.onSurface)),
                    const Spacer(),
                    Text('${c.nodes.length}',
                        style:
                            TextStyle(fontSize: 11.5, color: palette.textDim)),
                    IconButton(
                      icon: Icon(_linkMode ? Icons.close : Icons.add_link,
                          size: 18),
                      color: _linkMode ? palette.accent : palette.textDim,
                      tooltip: _linkMode ? 'Exit link mode' : 'Create a link',
                      visualDensity: VisualDensity.compact,
                      onPressed: () => setState(() {
                        _linkMode = !_linkMode;
                        _linkFrom = null;
                      }),
                    ),
                  ],
                ),
              ),
              // Everything below the header is ONE scroll view (tree rows
              // inline, no nested Expanded) so nothing overflows even when the
              // panel is short (e.g. the mobile peek), and all settings scroll.
              Expanded(
                child: ListView(
                  padding: EdgeInsets.zero,
                  children: [
                    if (_linkMode) _linkBanner(palette),
                    _toggle(palette, 'Expand items inside canvases',
                        !c.abstractInsideItems,
                        (v) => c.setAbstractInsideItems(!v)),
                    _toggle(palette, 'External links', c.showExternal,
                        (v) => c.setShowExternal(v)),
                    _toggle(palette, 'Show items without links', c.showUnlinked,
                        (v) => c.setShowUnlinked(v)),
                    Divider(height: 1, color: palette.border),
                    if (c.tags.isNotEmpty) ...[
                      _sectionHeader(palette, 'Tags', _tagsOpen, () {
                        setState(() => _tagsOpen = !_tagsOpen);
                        _savePanelUi();
                      }),
                      if (_tagsOpen) _tagsFilterBody(palette),
                      Divider(height: 1, color: palette.border),
                    ],
                    _sectionHeader(palette, 'Projects', _projectsOpen, () {
                      setState(() => _projectsOpen = !_projectsOpen);
                      _savePanelUi();
                    }),
                    if (_projectsOpen) _projectsBody(palette),
                    Divider(height: 1, color: palette.border),
                    // The notebook → section → canvas tree (scoped by the active
                    // project); link mode forces it visible so you pick two of
                    // the shown items to connect — checkboxes still toggle view.
                    _sectionHeader(palette, 'Filter items', _filterOpen, () {
                      setState(() => _filterOpen = !_filterOpen);
                      _savePanelUi();
                    }),
                    if (_filterOpen || _linkMode)
                      if (rows.isEmpty)
                        Padding(
                          padding: const EdgeInsets.all(16),
                          child: Text('Nothing to show',
                              style: TextStyle(
                                  fontSize: 12, color: palette.textDim)),
                        )
                      else
                        ...rows,
                    Divider(height: 1, color: palette.border),
                    _appearanceSection(palette),
                    _legend(palette),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _linkBanner(AppPalette palette) {
    final from = _linkFrom;
    return Container(
      color: palette.accentSoft,
      padding: const EdgeInsets.fromLTRB(14, 6, 6, 6),
      child: Row(
        children: [
          Icon(Icons.link, size: 15, color: palette.accent),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              from == null
                  ? 'Tap an item to link from…'
                  : 'Linking from “${from.name}” — tap a target',
              style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.onSurface),
            ),
          ),
          if (from != null)
            TextButton(
              onPressed: () => setState(() => _linkFrom = null),
              style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 8)),
              child: const Text('Reset', style: TextStyle(fontSize: 12)),
            ),
        ],
      ),
    );
  }

  Future<void> _pickForLink(GraphContainer g) async {
    final from = _linkFrom;
    if (from == null) {
      setState(() => _linkFrom = g);
      return;
    }
    if (from.id == g.id) {
      setState(() => _linkFrom = null);
      return;
    }
    await LinkService().addLink(
        from: from.endpoint,
        to: g.endpoint,
        fromName: from.name,
        toName: g.name);
    if (!mounted) return;
    await widget.onReload?.call();
    if (!mounted) return;
    setState(() => _linkFrom = null);
    showAppToast(context, 'Linked “${from.name}” ↔ “${g.name}”');
  }

  /// Whether [g] (or any descendant) is a member of the active project — used
  /// to scope the Filter-items tree to the selected project.
  bool _inProjectSubtree(GraphContainer g) {
    if (!c.hasActiveProject) return true;
    if (c.isProjectMember(g.id)) return true;
    for (final ch in g.children) {
      if (_inProjectSubtree(ch)) return true;
    }
    return false;
  }

  void _appendRows(List<Widget> out, GraphContainer g, int depth,
      Set<String> hlIds, AppPalette palette,
      {bool editMode = false}) {
    final count = _countOf(g);
    if (!editMode) {
      // A selected project scopes the tree to just its items; otherwise hide
      // zero-link subtrees unless "show unlinked" is on.
      if (!_inProjectSubtree(g)) return;
      if (!c.hasActiveProject && !c.showUnlinked && count == 0) return;
    }
    final renderableChildren = editMode
        ? g.children
        : c.hasActiveProject
            ? g.children.where(_inProjectSubtree).toList()
            : (c.showUnlinked
                ? g.children
                : g.children.where((ch) => _countOf(ch) > 0).toList());
    final showChevron = renderableChildren.isNotEmpty;
    final expanded = _expanded.contains(g.id);
    out.add(_rowTile(g, depth, count, showChevron, expanded, hlIds, palette,
        editMode: editMode));
    if (showChevron && expanded) {
      final kids = [...renderableChildren]
        ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      for (final k in kids) {
        _appendRows(out, k, depth + 1, hlIds, palette, editMode: editMode);
      }
    }
  }

  Widget _rowTile(GraphContainer g, int depth, int count, bool hasChildren,
      bool expanded, Set<String> hlIds, AppPalette palette,
      {bool editMode = false}) {
    final isLinkSource = _linkFrom?.id == g.id;
    final selfHidden = c.hiddenContainers.contains(g.id);
    final member = editMode && _peEffective(g.id);
    // A checked row whose membership comes from an ancestor (not its own marker)
    // is drawn dimmer, so it reads as "included via its parent" rather than an
    // explicit pick.
    final memberInherited =
        member && !_peIncludes.contains(g.id) && !_peExcludes.contains(g.id);
    final highlighted = hlIds.contains(g.id);
    final color = AppPalette.identityColor(g.id);
    return MouseRegion(
      onEnter: (_) => c.setHighlightContainer(g.id),
      onExit: (_) {
        if (c.highlightContainerId == g.id) c.setHighlightContainer(null);
      },
      child: InkWell(
        onTap: () => editMode
            ? _toggleMember(g)
            : (_linkMode ? _pickForLink(g) : c.focusContainer(g.id)),
        child: Container(
          color: isLinkSource
              ? palette.accent.withValues(alpha: 0.28)
              : (highlighted ? palette.accentSoft : null),
          padding: EdgeInsets.only(left: 6.0 + depth * 14, right: 6),
          height: 32,
          child: Row(
            children: [
              SizedBox(
                width: 18,
                child: hasChildren
                    ? InkWell(
                        onTap: () {
                          setState(() {
                            if (!_expanded.remove(g.id)) _expanded.add(g.id);
                          });
                          _savePanelUi();
                        },
                        child: Icon(
                            expanded ? Icons.expand_more : Icons.chevron_right,
                            size: 16,
                            color: palette.textDim),
                      )
                    : null,
              ),
              _ShapeIcon(
                  shape: _shapeForContainer(g.kind),
                  color: count == 0 ? palette.textDim : color,
                  size: 13),
              const SizedBox(width: 7),
              Expanded(
                child: Text(
                  g.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12.5,
                    color: (!editMode && (selfHidden || count == 0))
                        ? palette.textDim
                        : Theme.of(context).colorScheme.onSurface,
                    fontWeight: depth == 0 ? FontWeight.w600 : FontWeight.w400,
                  ),
                ),
              ),
              if (!editMode && count > 0)
                Text('$count',
                    style: TextStyle(fontSize: 11, color: palette.textDim)),
              // A tiny link glyph hints that tapping the row picks it (the
              // checkbox still toggles visibility while linking).
              if (_linkMode && !editMode)
                Padding(
                  padding: const EdgeInsets.only(left: 2),
                  child: Icon(Icons.add_link,
                      size: 14,
                      color: isLinkSource ? palette.accent : palette.textDim),
                ),
              if (editMode)
                SizedBox(
                  width: 34,
                  child: Checkbox(
                    value: member,
                    // Inherited-from-parent checks read dimmer than explicit ones.
                    fillColor: memberInherited
                        ? WidgetStatePropertyAll(palette.textDim)
                        : null,
                    onChanged: (_) => _toggleMember(g),
                    visualDensity: VisualDensity.compact,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                )
              else
                SizedBox(
                  width: 34,
                  // Independent + cascading: toggling a row toggles its whole
                  // subtree, but each child stays re-checkable afterward.
                  child: Checkbox(
                    value: !selfHidden,
                    onChanged: (v) =>
                        c.setSubtreeHidden(_subtreeIds(g), !(v ?? true)),
                    visualDensity: VisualDensity.compact,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// Build-mode selection cascades: checking a container selects its whole
  /// subtree; you can then uncheck individual descendants.
  /// Effective build-mode membership of [id] — nearest choice over its ancestry
  /// wins (an include/exclude on a nearer container beats a farther one).
  bool _peEffective(String id) {
    for (final a in c.ancestorsOf(id)) {
      if (_peExcludes.contains(a)) return false;
      if (_peIncludes.contains(a)) return true;
    }
    return false;
  }

  /// What [id] would inherit from its ancestors alone (ignoring its own marker)
  /// — so a toggle only needs an explicit marker when it differs from this.
  bool _peInherited(String id) {
    for (final a in c.ancestorsOf(id).skip(1)) {
      if (_peExcludes.contains(a)) return false;
      if (_peIncludes.contains(a)) return true;
    }
    return false;
  }

  /// Tri-state toggle: flip [g]'s effective membership. Clears any explicit
  /// markers on [g] and its subtree first (so a parent choice re-governs the
  /// whole subtree), then writes an explicit include/exclude on [g] only if the
  /// desired state differs from what it inherits — keeping the record set
  /// minimal and letting future descendants inherit automatically.
  void _toggleMember(GraphContainer g) {
    final desired = !_peEffective(g.id);
    setState(() {
      final sub = _subtreeIds(g);
      _peIncludes.removeAll(sub);
      _peExcludes.removeAll(sub);
      if (desired != _peInherited(g.id)) {
        (desired ? _peIncludes : _peExcludes).add(g.id);
      }
    });
  }

  Widget _toggle(
      AppPalette palette, String label, bool value, ValueChanged<bool> onChanged) {
    return InkWell(
      onTap: () => onChanged(!value),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 1),
        child: Row(
          children: [
            Expanded(
                child: Text(label,
                    style: TextStyle(
                        fontSize: 12.5,
                        color: Theme.of(context).colorScheme.onSurface))),
            // Compact switch (the toggle icons read smaller, per request).
            Transform.scale(
              scale: 0.72,
              child: Switch(
                value: value,
                onChanged: onChanged,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Collapsible "Appearance" section with Obsidian-style sliders.
  Widget _appearanceSection(AppPalette palette) {
    final onSurface = Theme.of(context).colorScheme.onSurface;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          onTap: () {
            setState(() => _appearanceOpen = !_appearanceOpen);
            _savePanelUi();
          },
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 4, 14, 4),
            child: Row(
              children: [
                Icon(
                    _appearanceOpen
                        ? Icons.expand_more
                        : Icons.chevron_right,
                    size: 16,
                    color: palette.textDim),
                const SizedBox(width: 4),
                Text('Appearance',
                    style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                        color: onSurface)),
              ],
            ),
          ),
        ),
        if (_appearanceOpen) ...[
          _slider(palette, 'Node size', c.nodeSizeScale, 0.5, 2.5,
              c.setNodeSizeScale),
          _slider(palette, 'Text size', c.textSizeScale, 0.6, 2.0,
              c.setTextSizeScale),
          _slider(palette, 'Text opacity', c.labelOpacity, 0.15, 1.0,
              c.setLabelOpacity),
          _slider(palette, 'Link thickness', c.linkThickness, 0.4, 3.0,
              c.setLinkThickness),
          _slider(palette, 'Link opacity', c.linkOpacity, 0.1, 1.0,
              c.setLinkOpacity),
          _toggle(palette, 'Always show labels', c.alwaysShowLabels,
              (v) => c.setAlwaysShowLabels(v)),
          _toggle(palette, 'Link items in same canvas', c.sameCanvasLinks,
              (v) => c.setSameCanvasLinks(v)),
          _toggle(palette, 'Pin nodes where you drag them', c.pinOnDrag,
              (v) => c.setPinOnDrag(v)),
          _toggle(palette, 'Auto-scale graph to fit', c.autoScale,
              (v) => c.setAutoScale(v)),
          const SizedBox(height: 4),
        ],
      ],
    );
  }

  Widget _slider(AppPalette palette, String label, double value, double min,
      double max, ValueChanged<double> onChanged) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14),
      child: Row(
        children: [
          SizedBox(
            width: 92,
            child: Text(label,
                style: TextStyle(fontSize: 11.5, color: palette.textDim)),
          ),
          Expanded(
            child: SliderTheme(
              data: SliderThemeData(
                trackHeight: 2,
                overlayShape:
                    const RoundSliderOverlayShape(overlayRadius: 10),
                thumbShape:
                    const RoundSliderThumbShape(enabledThumbRadius: 6),
              ),
              child: Slider(
                value: value.clamp(min, max),
                min: min,
                max: max,
                onChanged: onChanged,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _legend(AppPalette palette) {
    Widget item(_NodeShape s, String label) => Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            _ShapeIcon(shape: s, color: palette.textDim, size: 12),
            const SizedBox(width: 4),
            Text(label,
                style: TextStyle(fontSize: 10.5, color: palette.textDim)),
          ]),
        );
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 6, 10, 8),
      child: Wrap(
        children: [
          item(_NodeShape.hexagon, 'Notebook'),
          item(_NodeShape.pentagon, 'Group'),
          item(_NodeShape.box, 'Section'),
          item(_NodeShape.circle, 'Canvas'),
          item(_NodeShape.triangle, 'In-canvas'),
          item(_NodeShape.diamond, 'External'),
        ],
      ),
    );
  }
}

/// The [_NodeShape] for a store-structure container kind (filter-tree rows).
_NodeShape _shapeForContainer(GraphContainerKind kind) {
  switch (kind) {
    case GraphContainerKind.notebook:
      return _NodeShape.hexagon;
    case GraphContainerKind.sectionGroup:
    case GraphContainerKind.canvasFolder:
      return _NodeShape.pentagon;
    case GraphContainerKind.section:
      return _NodeShape.box;
    case GraphContainerKind.canvas:
      return _NodeShape.circle;
  }
}

/// A tiny filled shape swatch (tree row icon + legend), reusing the painter's
/// shape geometry so it matches the graph exactly.
class _ShapeIcon extends StatelessWidget {
  final _NodeShape shape;
  final Color color;
  final double size;
  const _ShapeIcon(
      {required this.shape, required this.color, this.size = 13});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(painter: _ShapeIconPainter(shape, color)),
    );
  }
}

class _ShapeIconPainter extends CustomPainter {
  final _NodeShape shape;
  final Color color;
  _ShapeIconPainter(this.shape, this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.shortestSide / 2 - 0.5;
    _paintShape(canvas, shape, c, r, Paint()..color = color);
  }

  @override
  bool shouldRepaint(covariant _ShapeIconPainter old) =>
      old.shape != shape || old.color != color;
}

/// The floating Connections panel's two faces: the connections LIST or the
/// local GRAPH (the same global engine, scoped to the current item + depth).
enum ConnPanelView { list, graph }

/// State for the desktop floating **Connections panel** — a draggable,
/// pinnable card that shows the current item's Connections list OR its local
/// graph (toggle), persists across navigation (until closed), and stacks a
/// back/forward history as you hop between nodes. Singleton so the Connections
/// menus open it and the desktop shell hosts one instance + publishes the
/// current location.
class LocalGraphController extends ChangeNotifier {
  static final LocalGraphController _i = LocalGraphController._();
  factory LocalGraphController() => _i;
  LocalGraphController._();

  bool open = false;
  bool pinned = false; // pin ONLY keeps it visible (no dismiss on outside tap)
  int depth = 1; // hops from the center
  Offset position = const Offset(96, 96);
  Size size = const Size(380, 420);

  /// Which face is showing (list default — the panel replaces the old modal).
  ConnPanelView view = ConnPanelView.list;

  // ── Connections context (what the LIST face renders) ──
  String connTitle = '';
  LinkEndpoint? connEndpoint;
  String connEndpointName = '';
  String? connAggregateCanvasId;
  LinkEndpoint? connSelfEndpoint;
  String connSelfName = '';
  String? connInsideCanvasId;
  void Function(String? pageId)? connOnJump;
  Future<void> Function(LinkEndpoint target, ResolvedLink resolved)?
      connOnAddTarget;

  final List<({LinkEndpoint ep, String name})> _history = [];
  int _hi = -1;
  int _rev = 0; // bumped when the subgraph must rebuild
  int get revision => _rev;

  /// The app's current location (published by the shell) — the recenter target.
  ({LinkEndpoint ep, String name})? currentLocation;

  ({LinkEndpoint ep, String name})? get center =>
      (_hi >= 0 && _hi < _history.length) ? _history[_hi] : null;
  bool get canBack => _hi > 0;
  bool get canForward => _hi < _history.length - 1;

  void _bump() {
    _rev++;
    notifyListeners();
  }

  void openAt(LinkEndpoint ep, String name) {
    open = true;
    _history
      ..clear()
      ..add((ep: ep, name: name));
    _hi = 0;
    _bump();
  }

  /// Opens the panel showing the Connections LIST for [endpoint] (or a canvas
  /// aggregate). The graph face is centered on the same item, so toggling to it
  /// is instant. Called by `showConnectionsSheet` on desktop.
  void openConnections({
    required String title,
    LinkEndpoint? endpoint,
    String endpointName = '',
    String? aggregateCanvasId,
    LinkEndpoint? selfEndpoint,
    String selfName = '',
    String? insideCanvasId,
    void Function(String? pageId)? onJumpInSameCanvas,
    Future<void> Function(LinkEndpoint target, ResolvedLink resolved)?
        onAddTarget,
  }) {
    connTitle = title;
    connEndpoint = endpoint;
    connEndpointName = endpointName;
    connAggregateCanvasId = aggregateCanvasId;
    connSelfEndpoint = selfEndpoint;
    connSelfName = selfName;
    connInsideCanvasId = insideCanvasId;
    connOnJump = onJumpInSameCanvas;
    connOnAddTarget = onAddTarget;
    open = true;
    view = ConnPanelView.list;
    // Center the graph face on the item the sheet is about.
    final ep = endpoint ?? selfEndpoint;
    final name = endpoint != null ? endpointName : selfName;
    _history.clear();
    if (ep != null) {
      final e = (ep: ep, name: name.isEmpty ? title : name);
      _history.add(e);
      _hi = 0;
      currentLocation = e; // the panel's list/actions start on the opened item
    } else {
      _hi = -1;
      currentLocation = null;
    }
    _bump();
  }

  void setView(ConnPanelView v) {
    if (view == v) return;
    view = v;
    notifyListeners();
  }

  // Suppress the live-follow auto-push while a PROGRAMMATIC navigation
  // (back/forward/recenter/node-tap) echoes back through the shell's
  // setCurrentLocation — otherwise back/forward re-navigate, the echo re-pushes,
  // and the history corrupts ("freaks out", lands on the section).
  bool _suppressEcho = false;
  int _navToken = 0;
  void _beginProgrammaticNav() {
    final t = ++_navToken;
    _suppressEcho = true;
    Future.delayed(const Duration(milliseconds: 800), () {
      if (t == _navToken) _suppressEcho = false;
    });
  }

  void _push(LinkEndpoint ep, String name) {
    if (center?.ep.toUri() == ep.toUri()) return; // already here
    if (_hi < _history.length - 1) {
      _history.removeRange(_hi + 1, _history.length);
    }
    _history.add((ep: ep, name: name));
    _hi = _history.length - 1;
    _bump();
  }

  void navigateTo(LinkEndpoint ep, String name) {
    _beginProgrammaticNav();
    // Keep the LIST + copy/add in sync with a graph node tap — otherwise the
    // graph centers on the tapped item while the list/actions stay on the
    // previous item (e.g. the canvas), so a paste links the wrong thing.
    currentLocation = (ep: ep, name: name);
    _push(ep, name);
  }

  void back() {
    if (canBack) {
      _beginProgrammaticNav();
      _hi--;
      currentLocation = center; // list/title/actions follow back/forward
      _bump();
    }
  }

  void forward() {
    if (canForward) {
      _beginProgrammaticNav();
      _hi++;
      currentLocation = center;
      _bump();
    }
  }

  void setDepth(int d) {
    final n = d.clamp(1, 4);
    if (n != depth) {
      depth = n;
      // Depth is a cheap view param — the panel re-scopes the existing data
      // via GraphController.setCenter; no subgraph refetch needed.
      notifyListeners();
    }
  }

  void close() {
    open = false;
    notifyListeners();
  }

  void togglePin() {
    pinned = !pinned;
    notifyListeners();
  }

  /// Live-navigate: when on, the graph auto-follows the app's current location
  /// as you navigate manually (and records each step into back/forward). When
  /// off, the graph only moves when you tap a node or hit recenter. Distinct
  /// from pin (which just keeps the panel visible).
  bool liveNavigate = false;

  void toggleLiveNavigate() {
    liveNavigate = !liveNavigate;
    // Turning it on immediately snaps to where you are now.
    if (liveNavigate) {
      final l = currentLocation;
      if (l != null && open) {
        _push(l.ep, l.name);
        return; // _push already notifies
      }
    }
    notifyListeners();
  }

  /// The shell/canvas publishes the app's current location (selection or
  /// canvas) here. The panel's LIST + copy/add/tags always follow it (so you
  /// can select an item and copy/link it). With [liveNavigate] on it also
  /// drives the GRAPH (auto-follow) and records the step — unless we're echoing
  /// our own programmatic navigation.
  Timer? _followDebounce;
  void setCurrentLocation(LinkEndpoint ep, String name) {
    if (currentLocation?.ep.toUri() == ep.toUri()) return; // unchanged
    currentLocation = (ep: ep, name: name);
    if (open) notifyListeners(); // list/actions/title follow immediately
    if (liveNavigate && open && !_suppressEcho) {
      // Debounce the GRAPH history push so a rapid section→canvas→element switch
      // coalesces into one (the graph doesn't get stuck on an intermediate
      // section/notebook you passed through).
      _followDebounce?.cancel();
      _followDebounce = Timer(const Duration(milliseconds: 350), () {
        final l = currentLocation;
        if (l == null || !open || _suppressEcho) return;
        // Follow whatever the user has RESTED on — container levels included.
        // The 350ms debounce already coalesces a drill-through
        // (notebook→section→canvas), so we only land on the final resting
        // location; skipping containers outright meant selecting a notebook /
        // section never moved the graph off the previous node until you toggled
        // live off/on (canvases were never skipped, so they always followed).
        _push(l.ep, l.name);
      });
    }
  }

  void recenter() {
    final l = currentLocation;
    if (l != null) {
      _beginProgrammaticNav();
      _push(l.ep, l.name);
    }
  }

  void move(Offset d) {
    position += d;
    notifyListeners();
  }

  void resize(Offset d) {
    size = Size((size.width + d.dx).clamp(280.0, 680.0),
        (size.height + d.dy).clamp(240.0, 680.0));
    notifyListeners();
  }
}

/// The floating local-graph card (desktop). Include one instance in the shell's
/// top-level Stack; it shows only while [LocalGraphController.open].
class LocalGraphPanel extends StatefulWidget {
  const LocalGraphPanel({super.key});

  @override
  State<LocalGraphPanel> createState() => _LocalGraphPanelState();
}

class _LocalGraphPanelState extends State<LocalGraphPanel>
    with SingleTickerProviderStateMixin {
  final _lgc = LocalGraphController();
  late final GraphController _g;
  late final Ticker _ticker;
  Timer? _fit;
  int _builtRev = -1;
  // Feature E: the local settings panel needs the store structure + tags +
  // projects in `_g` (loaded lazily on first graph build / settings open, then
  // refreshed on store changes while the panel is open).
  bool _filtersLoaded = false;
  Timer? _filterReload;

  GraphSimNode? _dragNode;
  bool _moved = false;
  double _lastScale = 1.0;

  @override
  void initState() {
    super.initState();
    _g = GraphController();
    // A local graph ignores the main view's filters, and its own filter choices
    // (Feature E) must NOT leak into the shared blob the global graph seeds from.
    _g.persistView = false;
    _g.hiddenContainers.clear();
    _g.tagInclude.clear();
    _g.tagExclude.clear();
    _g.activeProjectId = null;
    _ticker = createTicker((_) {
      if (!_g.step()) _ticker.stop();
    });
    _g.onWake = () {
      if (mounted && !_ticker.isActive) _ticker.start();
    };
    _g.onContentChanged = () {
      if (!_g.autoScale) return; // user turned off auto-scaling
      _fit?.cancel();
      _fit = Timer(const Duration(milliseconds: 500), () {
        if (mounted && _g.autoScale) _g.fitToScreen();
      });
    };
    _lgc.addListener(_onLgc);
    SyncService().dataVersion.addListener(_onFilterData);
    _maybeRebuild();
  }

  @override
  void dispose() {
    _lgc.removeListener(_onLgc);
    SyncService().dataVersion.removeListener(_onFilterData);
    _filterReload?.cancel();
    _fit?.cancel();
    _ticker.dispose();
    _g.dispose();
    super.dispose();
  }

  /// A store change may add/remove containers, tags, or projects — refresh the
  /// filter data feeding `_g` (only while the panel is open; debounced so a sync
  /// burst coalesces). The graph nodes themselves refresh via `_maybeRebuild`.
  void _onFilterData() {
    if (!_lgc.open || !_filtersLoaded) return;
    _filterReload?.cancel();
    _filterReload = Timer(const Duration(milliseconds: 400), _loadFilters);
  }

  /// Loads the store structure + tags + projects into this panel's engine so the
  /// settings panel's filter tree / tag chips / project list are populated —
  /// mirrors `_GraphScreenState._load` but for the local `_g`. The active
  /// project (if any) starts cleared for a local graph, so its members are only
  /// refreshed once the user activates one here.
  Future<void> _loadFilters() async {
    final structure = await GraphService().buildStructure();
    if (!mounted) return;
    _g.setStructure(structure);
    final tags = await TagService().allTags();
    final tagsByLeaf = await TagService().tagIdsByLeaf();
    if (!mounted) return;
    _g.setTagData(tags, tagsByLeaf);
    final projs = await ProjectService().allProjects();
    if (!mounted) return;
    _g.setProjects(projs);
    final active = _g.activeProjectId;
    if (active != null) {
      final items = await ProjectService().membersOf(active);
      if (!mounted) return;
      final inc =
          items.where((i) => !i.excluded).map((i) => i.endpoint.leafId).toSet();
      final exc =
          items.where((i) => i.excluded).map((i) => i.endpoint.leafId).toSet();
      _g.setActiveProject(active, inc, exc);
    }
  }

  void _onLgc() {
    if (mounted) setState(() {});
    // Apply center + depth to the shared engine (cheap, re-scopes existing
    // data); a center change also refetches the full graph via _maybeRebuild.
    _g.setCenter(_lgc.center?.ep.toUri(), _lgc.depth);
    _maybeRebuild();
  }

  /// Feeds the shared engine the WHOLE graph and lets it scope to the center's
  /// depth-neighborhood (`GraphController.setCenter`) — so the local graph is
  /// literally the global graph with a depth filter, no bespoke subgraph. Only
  /// refetches the full graph on a center change (revision); depth changes
  /// re-scope in memory via [_onLgc].
  Future<void> _maybeRebuild() async {
    // Lazy: only build the graph when the graph FACE is actually shown, so
    // opening the panel to the LIST doesn't pay for a full graph build. When
    // you toggle to graph, setView → notify → this runs (revision is ahead of
    // _builtRev, so it fetches).
    if (!_lgc.open || _lgc.view != ConnPanelView.graph) return;
    if (_lgc.revision == _builtRev) return;
    _builtRev = _lgc.revision;
    // Populate the settings panel's filter data (structure/tags/projects) the
    // first time the graph is built for this session (cheap; center-independent).
    if (!_filtersLoaded) {
      _filtersLoaded = true;
      unawaited(_loadFilters());
    }
    final center = _lgc.center;
    if (center == null) return;
    final data = await GraphService().buildGraph();
    if (!mounted || _lgc.revision != _builtRev) return; // superseded
    var centerKey = center.ep.toUri();
    // If the center is an ELEMENT selection, match it to an EXISTING linked node
    // by element-id OVERLAP (a re-selected linked selection has a different URI
    // but the same ids) — so it highlights that node instead of adding a
    // duplicate "new" one.
    if (center.ep.elementIds.isNotEmpty &&
        !data.nodes.any((n) => n.key == centerKey)) {
      final set = center.ep.elementIds.toSet();
      for (final n in data.nodes) {
        final ep = LinkEndpoint.sideFrom(n.key);
        if (ep != null && ep.elementIds.any(set.contains)) {
          centerKey = n.key;
          break;
        }
      }
    }
    // Ensure the center is present even with no connections (an isolated item).
    var nodes = data.nodes;
    if (!data.nodes.any((n) => n.key == centerKey)) {
      final ep = center.ep;
      final ext = ep.externalUrl != null;
      nodes = [
        ...data.nodes,
        GraphNode(
          key: centerKey,
          title: center.name.isEmpty ? 'Item' : center.name,
          kind: ep.kind,
          alive: true,
          degree: 0,
          leafId: ep.leafId,
          externalUrl: ep.externalUrl,
          color: ext ? null : AppPalette.identityColor(ep.leafId),
          notebookId: ext ? null : ep.notebookId,
          sectionId: ep.sectionId,
          canvasId: ep.canvasId,
          folderId: ep.folderId,
        ),
      ];
    }
    // Set the focus BEFORE feeding data so the first rebuild is already scoped.
    _g.centerKey = centerKey;
    _g.depthLimit = _lgc.depth;
    _g.setData(GraphData(
      nodes: nodes,
      edges: data.edges,
      abstractCanvasNodes: data.abstractCanvasNodes,
    ));
  }

  void _back() {
    _lgc.back();
    _navigateToCenter();
  }

  void _forward() {
    _lgc.forward();
    _navigateToCenter();
  }

  /// Back/forward (and recenter) don't just re-focus the graph — they also
  /// navigate the app to the new center, like tapping the node would.
  Future<void> _navigateToCenter() async {
    final center = _lgc.center;
    if (center == null) return;
    final ep = center.ep;
    if (ep.externalUrl != null) return; // external isn't an app location
    final r = await resolveEndpoint(ep, fallbackName: center.name);
    if (!mounted || r.reveal == null) return;
    if (ep.elementIds.isNotEmpty && ep.canvasId != null && ep.pageId != null) {
      LinkNavigator().pendingElementFocus = (
        canvasId: ep.canvasId!,
        pageId: ep.pageId!,
        elementIds: ep.elementIds,
      );
    }
    LinkNavigator().openCanvas(r.reveal!);
  }

  void _onScaleStart(ScaleStartDetails d) {
    _lastScale = 1.0;
    // _dragNode was hit-tested on pointer-DOWN (exact position). Hit-testing
    // here at the scale-start focal point misses, because the recognizer only
    // fires after some movement — by then the pointer has left the node. That
    // was why nodes were hard to grab in the (smaller, zoomed-out) local card;
    // mirrors the global graph, which captures the candidate on pointer-down.
    if (_dragNode != null) _g.beginDrag(_dragNode!);
  }

  void _onScaleUpdate(ScaleUpdateDetails d) {
    _moved = true;
    if (_dragNode != null && d.pointerCount == 1) {
      _g.dragTo(d.localFocalPoint);
      return;
    }
    if (d.scale != 1.0) {
      _g.zoomAt(d.localFocalPoint, d.scale / _lastScale);
      _lastScale = d.scale;
    }
    _g.panBy(d.focalPointDelta);
  }

  void _onScaleEnd(ScaleEndDetails d) {
    if (_dragNode != null) _g.endDrag();
    _dragNode = null;
  }

  void _onTapUp(TapUpDetails d) {
    if (_moved) return;
    final node = _g.hitTest(d.localPosition);
    if (node != null) _activate(node);
  }

  Future<void> _activate(GraphSimNode node) async {
    final data = node.data;
    if (data.externalUrl != null) {
      await launchUrl(Uri.parse(data.externalUrl!),
          mode: LaunchMode.externalApplication);
      return;
    }
    if (!data.alive || data.reveal == null) return;
    final ep = LinkEndpoint.sideFrom(data.key);
    // In-canvas element target: if its canvas is already open, flash it in place
    // (re-fires on EVERY tap, incl. items in the current canvas, where opening
    // would no-op — the "doesn't glow on re-tap" fix). Otherwise open it and
    // hand off a pending focus so it flashes on arrival.
    final inCanvasEl = ep != null &&
        ep.canvasId != null &&
        ep.pageId != null &&
        ep.elementIds.isNotEmpty;
    final flashed = inCanvasEl &&
        SyncService()
            .focusElementsInOpenCanvas(ep.canvasId!, ep.pageId!, ep.elementIds);
    if (!flashed) {
      _handOffElementFocus(data); // flash + precise scroll on arrival
      // Graph taps are deliberate navigation — go to the actual place.
      LinkNavigator().openCanvas(data.reveal!);
    }
    if (ep != null) _lgc.navigateTo(ep, data.title); // stack the hop
  }

  @override
  Widget build(BuildContext context) {
    if (!_lgc.open) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final palette = theme.extension<AppPalette>()!;
    // The title follows the current item (your selection), like the list.
    final currentName = _lgc.currentLocation?.name ?? _lgc.connTitle;
    return Stack(
      children: [
        // Unpinned: a tap anywhere outside the card dismisses it (like a
        // popup). Pinned: no barrier — the card stays and the app stays usable.
        if (!_lgc.pinned)
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _lgc.close,
            ),
          ),
        Positioned(
          left: _lgc.position.dx,
          top: _lgc.position.dy,
          width: _lgc.size.width,
          height: _lgc.size.height,
          child: Material(
        elevation: 12,
        borderRadius: BorderRadius.circular(kRadius),
        color: palette.canvas,
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(kRadius),
            border: Border.all(color: palette.border),
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
            children: [
              _titleBar(palette, currentName),
              Expanded(child: _buildConnectionsBody(palette, theme)),
              _bottomBar(palette),
            ],
          ),
        ),
      ),
        ),
      ],
    );
  }

  /// The panel body: always the Connections view (so its consolidated copy /
  /// add / tags action line shows in BOTH faces), with the graph injected as
  /// its `body` in graph mode. The current item FOLLOWS the app's current
  /// location (your selection) — so you can select something, hit Copy, select
  /// another and hit + · Paste to link them. The rich opened-context (canvas
  /// aggregate / lasso onAddTarget / in-canvas jump) applies only while you're
  /// still on the item the panel was opened for.
  Widget _buildConnectionsBody(AppPalette palette, ThemeData theme) {
    final body = _lgc.view == ConnPanelView.graph
        ? _buildGraphBody(palette, theme)
        : null;
    final cur = _lgc.currentLocation;
    final openedEp = _lgc.connEndpoint ?? _lgc.connSelfEndpoint;
    bool isBareCanvas(LinkEndpoint ep) =>
        ep.externalUrl == null &&
        ep.canvasId != null &&
        ep.pageId == null &&
        ep.elementIds.isEmpty &&
        ep.bookmarkId == null &&
        ep.folderId == null;
    // When the panel was opened for a concrete ELEMENT menu (a lasso / text /
    // PDF selection, which carries an onAddTarget), a drift to the bare canvas
    // (you deselected, or the canvas screen re-published itself a beat later)
    // must NOT abandon that menu — otherwise + · Paste/Choose would fall through
    // to the default link-item box instead of the selection's own onAddTarget
    // (the "only works if the graph wasn't already open" bug). Only a different
    // CONCRETE item (element/page/…) flips the panel into follow mode.
    final openedIsElement =
        openedEp != null && openedEp.elementIds.isNotEmpty;
    final atOpened = cur == null ||
        (openedEp != null && cur.ep.sameAs(openedEp)) ||
        (openedIsElement && isBareCanvas(cur.ep));
    if (atOpened) {
      return ConnectionsListView(
        key: ValueKey('opened:${_lgc.connEndpoint?.toUri() ?? _lgc.connAggregateCanvasId ?? _lgc.connTitle}'),
        embedded: true,
        body: body,
        title: _lgc.connTitle,
        endpoint: _lgc.connEndpoint,
        endpointName: _lgc.connEndpointName,
        aggregateCanvasId: _lgc.connAggregateCanvasId,
        selfEndpoint: _lgc.connSelfEndpoint,
        selfName: _lgc.connSelfName,
        insideCanvasId: _lgc.connInsideCanvasId,
        onJumpInSameCanvas: _lgc.connOnJump,
        onAddTarget: _lgc.connOnAddTarget,
        desktop: true,
        hostContext: context,
      );
    }
    // Following the current selection/location. A CANVAS with nothing selected
    // shows the AGGREGATE of every connection inside it (element links live on
    // the element, not the canvas — so this is what makes B's list show A after
    // you linked A to an item inside B). An element/page shows its own links.
    final ep = cur.ep;
    final canvasOnly = isBareCanvas(ep);
    return ConnectionsListView(
      key: ValueKey('cur:${ep.toUri()}'),
      embedded: true,
      body: body,
      title: cur.name,
      endpointName: cur.name,
      endpoint: canvasOnly ? null : ep,
      aggregateCanvasId: canvasOnly ? ep.canvasId : null,
      selfEndpoint: canvasOnly ? ep : null,
      selfName: cur.name,
      desktop: true,
      hostContext: context,
    );
  }

  /// The local GRAPH face — the shared engine, centered + depth-scoped.
  Widget _buildGraphBody(AppPalette palette, ThemeData theme) {
    return Listener(
      // Reset the moved-flag AND capture the drag candidate at the precise
      // pointer-down position (see _onScaleStart) — this fixes both the
      // "sometimes can't tap nodes" and "hard to grab a node to drag" issues;
      // mirrors the global graph's onPointerDown.
      onPointerDown: (e) {
        _moved = false;
        _dragNode = _g.hitTest(e.localPosition);
      },
      onPointerSignal: (e) {
        if (e is PointerScrollEvent) {
          _g.zoomAt(e.localPosition, e.scrollDelta.dy < 0 ? 1.12 : 1 / 1.12);
        }
      },
      child: RawGestureDetector(
        gestures: {
          ScaleGestureRecognizer:
              GestureRecognizerFactoryWithHandlers<ScaleGestureRecognizer>(
            () => ScaleGestureRecognizer(),
            (r) => r
              ..onStart = _onScaleStart
              ..onUpdate = _onScaleUpdate
              ..onEnd = _onScaleEnd,
          ),
          TapGestureRecognizer:
              GestureRecognizerFactoryWithHandlers<TapGestureRecognizer>(
            () => TapGestureRecognizer(),
            (r) => r..onTapUp = _onTapUp,
          ),
        },
        child: LayoutBuilder(
          builder: (context, constraints) {
            // Give the controller its size so it centers/fits the subgraph.
            _g.setScreenSize(constraints.biggest);
            return CustomPaint(
              painter: _GraphPainter(_g, palette, theme),
              size: Size.infinite,
            );
          },
        ),
      ),
    );
  }

  Widget _titleBar(AppPalette palette, String name) {
    final onSurface = Theme.of(context).colorScheme.onSurface;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onPanUpdate: (d) => _lgc.move(d.delta),
      child: Container(
        height: 34,
        padding: const EdgeInsets.only(left: 10, right: 4),
        decoration: BoxDecoration(
          color: palette.surface2,
          border: Border(bottom: BorderSide(color: palette.border)),
        ),
        child: Row(
          children: [
            Icon(Icons.hub_outlined, size: 15, color: palette.textDim),
            const SizedBox(width: 6),
            Expanded(
              child: Text(name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      color: onSurface)),
            ),
            // List ⟷ graph face toggle (the active face is highlighted).
            _tinyBtn(
                palette,
                Icons.format_list_bulleted,
                'Connections list',
                _lgc.view == ConnPanelView.list
                    ? null
                    : () => _lgc.setView(ConnPanelView.list),
                active: _lgc.view == ConnPanelView.list),
            _tinyBtn(
                palette,
                Icons.hub_outlined,
                'Local graph',
                _lgc.view == ConnPanelView.graph
                    ? null
                    : () => _lgc.setView(ConnPanelView.graph),
                active: _lgc.view == ConnPanelView.graph),
            _tinyBtn(palette, Icons.arrow_back, 'Back',
                _lgc.canBack ? _back : null),
            _tinyBtn(palette, Icons.arrow_forward, 'Forward',
                _lgc.canForward ? _forward : null),
            // Graph-only settings gear → the full visual settings popup (same
            // controls the global graph has).
            if (_lgc.view == ConnPanelView.graph)
              _tinyBtn(palette, Icons.tune, 'Graph settings',
                  _openGraphSettings),
            _tinyBtn(
              palette,
              _lgc.pinned ? Icons.push_pin : Icons.push_pin_outlined,
              _lgc.pinned ? 'Pinned (stays open)' : 'Pin to keep it open',
              _lgc.togglePin,
              active: _lgc.pinned,
            ),
            _tinyBtn(palette, Icons.close, 'Close', _lgc.close),
          ],
        ),
      ),
    );
  }

  Widget _bottomBar(AppPalette palette) {
    final graph = _lgc.view == ConnPanelView.graph;
    return Container(
      height: 34,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      decoration: BoxDecoration(
        color: palette.surface2,
        border: Border(top: BorderSide(color: palette.border)),
      ),
      child: Row(
        children: [
          // Graph-face controls (recenter / re-flow / depth); the list face
          // just carries the resize grip.
          if (graph) ...[
            _tinyBtn(palette, Icons.my_location, 'Recenter on current location',
                _lgc.recenter),
            _tinyBtn(
                palette,
                _lgc.liveNavigate
                    ? Icons.gps_fixed
                    : Icons.gps_not_fixed,
                _lgc.liveNavigate
                    ? 'Live-follow on — graph follows you as you navigate'
                    : 'Live-follow off — tap to make the graph follow navigation',
                _lgc.toggleLiveNavigate,
                active: _lgc.liveNavigate),
            _tinyBtn(palette, Icons.bubble_chart_outlined,
                'Re-flow layout (release pinned nodes)', _g.clearFixed),
            const Spacer(),
            Text('Depth',
                style: TextStyle(fontSize: 11.5, color: palette.textDim)),
            _tinyBtn(palette, Icons.remove, 'Fewer hops',
                _lgc.depth > 1 ? () => _lgc.setDepth(_lgc.depth - 1) : null),
            Text('${_lgc.depth}',
                style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: palette.accent)),
            _tinyBtn(palette, Icons.add, 'More hops',
                _lgc.depth < 4 ? () => _lgc.setDepth(_lgc.depth + 1) : null),
          ] else
            const Spacer(),
          const SizedBox(width: 6),
          // Resize grip (drag to size the card) — both faces.
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onPanUpdate: (d) => _lgc.resize(d.delta),
            child: Icon(Icons.open_in_full, size: 14, color: palette.textDim),
          ),
        ],
      ),
    );
  }

  /// The graph settings popup — the same visual controls the global graph has,
  /// operating on the local `_g` (and persisting, so both stay consistent).
  void _openGraphSettings() {
    // Feature E: the local graph's settings expose the SAME full panel as the
    // global graph — the filter-items tree (groups/containers), tags, projects,
    // AND appearance — operating on this panel's own engine (`_g`). Its
    // structure/tags/projects are loaded lazily (see `_loadFilters`), so make
    // sure they're present before showing the panel.
    if (!_filtersLoaded) {
      _filtersLoaded = true;
      _loadFilters();
    }
    final h = (MediaQuery.of(context).size.height * 0.8).clamp(340.0, 640.0);
    showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        child: SizedBox(
          width: 360,
          height: h,
          // _GraphFilterPanel filters `_g` (container tree / tags / projects)
          // AND composes with the center+depth scope in `_rebuildActive`; a link
          // created here re-fetches the local graph via onReload.
          child: _GraphFilterPanel(
            controller: _g,
            onReload: () async {
              // A project/link created here persists but doesn't bump
              // dataVersion, and the local panel only re-queried on such a bump
              // — so re-run _loadFilters to refresh the project list (+ tags /
              // structure) into `_g`, mirroring the global graph's _load. Then
              // rebuild the graph nodes.
              await _loadFilters();
              if (!mounted) return;
              _builtRev = -1;
              _maybeRebuild();
            },
          ),
        ),
      ),
    );
  }

  Widget _tinyBtn(AppPalette palette, IconData icon, String tip, VoidCallback? onTap,
      {bool active = false}) {
    return IconButton(
      icon: Icon(icon, size: 16),
      color: active ? palette.accent : palette.textDim,
      tooltip: tip,
      visualDensity: VisualDensity.compact,
      padding: const EdgeInsets.all(4),
      constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
      onPressed: onTap,
    );
  }
}
