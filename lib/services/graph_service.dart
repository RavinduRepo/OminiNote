import 'package:flutter/material.dart';

import '../models/link.dart';
import '../theme/app_theme.dart';
import 'link_resolver.dart';
import 'link_service.dart';
import 'search_service.dart';

/// One node in the Connections graph — a distinct linked endpoint, keyed by its
/// canonical `omninote://link/...` URI (or the raw URL for an external target).
/// Two records pointing at the same endpoint share one node.
class GraphNode {
  /// The endpoint's canonical URI — the stable identity used to dedup nodes and
  /// match edges. Also lets positions persist across a rebuild.
  final String key;
  final String title;
  final LinkTargetKind kind;

  /// False when the target is soft-deleted / purged / absent (drawn greyed).
  final bool alive;

  /// The shell-reveal target for a node tap; null for external / dead nodes.
  final SearchResult? reveal;

  /// Set for external URL nodes (opened in the browser on tap).
  final String? externalUrl;

  /// Deterministic identity color for internal, alive nodes; null otherwise
  /// (the painter falls back to a palette color for external / dead).
  final Color? color;

  /// How many connections touch this node (drives node size).
  final int degree;

  /// Container ancestry — lets the graph be scoped/filtered by container and
  /// cross-highlighted with the filter tree. Null for the levels above the node
  /// (a section node has no canvasId) and all-null for external nodes.
  final String? notebookId;
  final String? sectionId;
  final String? canvasId;

  /// Ancestor display names (from the live reveal target); null when unknown
  /// (dead / external), so the filter tree can group them under a fallback.
  final String? notebookName;
  final String? sectionName;
  final String? canvasName;

  /// For an inside-canvas node (page/element/bookmark), the node key of its
  /// owning canvas — the target it collapses into when "abstract items to
  /// canvas" is on. Null for every other kind.
  final String? canvasKey;

  const GraphNode({
    required this.key,
    required this.title,
    required this.kind,
    required this.alive,
    required this.degree,
    this.reveal,
    this.externalUrl,
    this.color,
    this.notebookId,
    this.sectionId,
    this.canvasId,
    this.notebookName,
    this.sectionName,
    this.canvasName,
    this.canvasKey,
  });
}

/// An undirected edge between two node keys (one [LinkRecord]).
class GraphEdge {
  final String aKey;
  final String bKey;

  /// The record's user label, if any (shown on the edge later; unused for now).
  final String? label;

  const GraphEdge({required this.aKey, required this.bKey, this.label});
}

/// The whole Connections graph: distinct endpoint nodes + connection edges,
/// plus synthesized canvas nodes used only when inside-canvas items are
/// abstracted up to their canvas (for canvases that own linked items but aren't
/// themselves linked, so they have no node in [nodes]).
class GraphData {
  final List<GraphNode> nodes;
  final List<GraphEdge> edges;
  final List<GraphNode> abstractCanvasNodes;

  const GraphData({
    required this.nodes,
    required this.edges,
    this.abstractCanvasNodes = const [],
  });

  bool get isEmpty => nodes.isEmpty;
}

/// Builds the store-wide **Connections graph**: every alive connection becomes
/// an edge, and each distinct endpoint it touches becomes a node. Structural
/// containment (notebook → section → canvas) is intentionally *not* drawn —
/// this is the user's explicit-links graph, closest to Obsidian's global view.
///
/// Cost is O(edges) for the walk + one on-demand [resolveEndpoint] per *unique*
/// endpoint (each a few small structural-file reads), run bounded-concurrently.
/// Call it when the graph opens and on a debounced [SyncService.dataVersion]
/// bump — not per frame.
class GraphService {
  static final GraphService _instance = GraphService._();
  factory GraphService() => _instance;
  GraphService._();

  static const int _kResolveConcurrency = 8;

  Future<GraphData> buildGraph() async {
    final links = await LinkService().allLinks();

    // Collect distinct endpoints + edges. Endpoint identity is its URI.
    final endpoints = <String, LinkEndpoint>{};
    final fallbackNames = <String, String>{};
    final degree = <String, int>{};
    final edges = <GraphEdge>[];

    for (final r in links) {
      final aKey = r.a.toUri();
      final bKey = r.b.toUri();
      endpoints.putIfAbsent(aKey, () => r.a);
      endpoints.putIfAbsent(bKey, () => r.b);
      if (r.aName.isNotEmpty) fallbackNames.putIfAbsent(aKey, () => r.aName);
      if (r.bName.isNotEmpty) fallbackNames.putIfAbsent(bKey, () => r.bName);
      if (aKey == bKey) continue; // degenerate self-link — skip the edge
      degree[aKey] = (degree[aKey] ?? 0) + 1;
      degree[bKey] = (degree[bKey] ?? 0) + 1;
      edges.add(GraphEdge(aKey: aKey, bKey: bKey, label: r.label));
    }

    // Resolve each unique endpoint (title / aliveness / reveal target).
    final keys = endpoints.keys.toList();
    final resolved = await _mapBounded<String, GraphNode>(keys, (key) async {
      final ep = endpoints[key]!;
      final r = await resolveEndpoint(ep, fallbackName: fallbackNames[key] ?? '');
      final isExternal = ep.externalUrl != null;
      // Inside-canvas items (page/element/bookmark) can abstract up to their
      // owning canvas — precompute that canvas endpoint's URI as the target.
      final insideCanvas = !isExternal &&
          ep.canvasId != null &&
          (r.kind == LinkTargetKind.page ||
              r.kind == LinkTargetKind.element ||
              r.kind == LinkTargetKind.bookmark);
      final canvasKey = insideCanvas
          ? LinkEndpoint(
                  notebookId: ep.notebookId,
                  sectionId: ep.sectionId,
                  canvasId: ep.canvasId)
              .toUri()
          : null;
      return GraphNode(
        key: key,
        title: r.title,
        kind: r.kind,
        alive: r.alive,
        degree: degree[key] ?? 0,
        reveal: r.reveal,
        externalUrl: ep.externalUrl,
        color: (!isExternal && r.alive)
            ? AppPalette.identityColor(_colorId(ep))
            : null,
        notebookId: isExternal ? null : ep.notebookId,
        sectionId: isExternal ? null : ep.sectionId,
        canvasId: isExternal ? null : ep.canvasId,
        // Ancestor names come from the live reveal target when resolvable.
        notebookName: r.reveal?.notebook.name,
        sectionName: r.reveal?.section?.name,
        canvasName: r.reveal?.canvas?.name,
        canvasKey: canvasKey,
      );
    });

    // Synthesize canvas nodes for any canvas that owns an inside-canvas node but
    // isn't itself a node — so abstraction has something to collapse into.
    final nodeKeys = resolved.map((n) => n.key).toSet();
    final needCanvas = <String, LinkEndpoint>{};
    for (final n in resolved) {
      final ck = n.canvasKey;
      if (ck != null && !nodeKeys.contains(ck) && !needCanvas.containsKey(ck)) {
        needCanvas[ck] = LinkEndpoint(
            notebookId: n.notebookId!,
            sectionId: n.sectionId,
            canvasId: n.canvasId);
      }
    }
    final abstractCanvas = await _mapBounded<String, GraphNode>(
        needCanvas.keys.toList(), (ck) async {
      final ep = needCanvas[ck]!;
      final r = await resolveEndpoint(ep);
      return GraphNode(
        key: ck,
        title: r.title,
        kind: LinkTargetKind.canvas,
        alive: r.alive,
        degree: 0,
        reveal: r.reveal,
        color: r.alive ? AppPalette.identityColor(_colorId(ep)) : null,
        notebookId: ep.notebookId,
        sectionId: ep.sectionId,
        canvasId: ep.canvasId,
        notebookName: r.reveal?.notebook.name,
        sectionName: r.reveal?.section?.name,
        canvasName: r.reveal?.canvas?.name,
      );
    });

    return GraphData(
        nodes: resolved, edges: edges, abstractCanvasNodes: abstractCanvas);
  }

  /// The container id a node inherits its identity color from (page/element/
  /// bookmark share their canvas's color, so a canvas and its linked selections
  /// read as one family).
  static String _colorId(LinkEndpoint e) =>
      e.canvasId ?? e.sectionId ?? e.folderId ?? e.notebookId;

  /// Runs [task] over [items] with at most [_kResolveConcurrency] in flight,
  /// preserving input order (mirrors [SearchService]'s bounded map).
  Future<List<R>> _mapBounded<T, R>(
      List<T> items, Future<R> Function(T) task) async {
    final results = List<R?>.filled(items.length, null);
    var next = 0;
    Future<void> worker() async {
      while (true) {
        final i = next++;
        if (i >= items.length) break;
        results[i] = await task(items[i]);
      }
    }

    final n = items.length < _kResolveConcurrency
        ? items.length
        : _kResolveConcurrency;
    await Future.wait([for (var i = 0; i < n; i++) worker()]);
    return results.cast<R>();
  }
}
