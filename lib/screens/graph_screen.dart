import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/scheduler.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/link.dart';
import '../services/graph_service.dart';
import '../services/link_navigator.dart';
import '../services/sync_service.dart';
import '../theme/app_theme.dart';
import '../utils/app_toast.dart';

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

  /// Show external-URL nodes.
  bool showExternal = true;

  // ── Appearance (Obsidian-style sliders) ──
  double nodeSizeScale = 1.0; // 0.5–2.5
  double textSizeScale = 1.0; // 0.6–2.0
  double linkThickness = 1.0; // 0.4–3.0
  double linkOpacity = 0.55; // 0.1–1.0

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

  /// True when [n] passes the container + external filters (NOT the inside-item
  /// handling — that's abstraction, applied separately in [_rebuildActive]).
  bool _passesFilter(GraphNode n) {
    if (n.externalUrl != null) return showExternal;
    if (n.notebookId != null && hiddenContainers.contains(n.notebookId)) {
      return false;
    }
    if (n.sectionId != null && hiddenContainers.contains(n.sectionId)) {
      return false;
    }
    if (n.canvasId != null && hiddenContainers.contains(n.canvasId)) {
      return false;
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

    // Lookup of every candidate GraphNode by key (real + synthesized canvases).
    final lookup = <String, GraphNode>{for (final n in _all.nodes) n.key: n};
    if (abstractInsideItems) {
      for (final n in _all.abstractCanvasNodes) {
        lookup.putIfAbsent(n.key, () => n);
      }
    }
    // Maps an inside-canvas node's key to its canvas node when abstracting.
    String remap(String key) {
      final n = lookup[key];
      if (n == null) return key;
      if (abstractInsideItems && n.canvasKey != null) return n.canvasKey!;
      return key;
    }

    // Final visible node keys (post-filter, post-abstraction).
    final visibleKeys = <String>{};
    for (final n in _all.nodes) {
      if (!_passesFilter(n)) continue;
      visibleKeys.add(remap(n.key));
    }

    final rnd = math.Random(7);
    var i = 0;
    for (final key in visibleKeys) {
      final data = lookup[key];
      if (data == null) continue; // abstract target filtered/absent
      final prev = old[key];
      final pos = prev?.pos ??
          Offset(math.cos(i * 2.399) * (30 + i * 6),
                  math.sin(i * 2.399) * (30 + i * 6)) +
              Offset(rnd.nextDouble() * 8, rnd.nextDouble() * 8);
      final sim = GraphSimNode(data, pos);
      if (prev != null) sim.vel = prev.vel;
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

    // Active degree per node (for sizing) from the final edge set.
    for (final e in _edges) {
      _byKey[e.aKey]?.activeDegree++;
      _byKey[e.bKey]?.activeDegree++;
    }

    notifyListeners();
    _bumpUi();
    onWake?.call();
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

  void setContainerHidden(String id, bool hidden) {
    if (hidden) {
      if (!hiddenContainers.add(id)) return;
    } else {
      if (!hiddenContainers.remove(id)) return;
    }
    _rebuildActive();
  }

  void setAbstractInsideItems(bool abstract) {
    if (abstractInsideItems == abstract) return;
    abstractInsideItems = abstract;
    _rebuildActive();
  }

  void setShowExternal(bool show) {
    if (showExternal == show) return;
    showExternal = show;
    _rebuildActive();
  }

  void setNodeSizeScale(double v) {
    nodeSizeScale = v;
    notifyListeners();
    _bumpUi();
  }

  void setTextSizeScale(double v) {
    textSizeScale = v;
    notifyListeners();
    _bumpUi();
  }

  void setLinkThickness(double v) {
    linkThickness = v;
    notifyListeners();
    _bumpUi();
  }

  void setLinkOpacity(double v) {
    linkOpacity = v;
    notifyListeners();
    _bumpUi();
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
      if (identical(a, _pinned)) {
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
    notifyListeners();
    return _pinned != null || camMoving || maxSpeed > _kSettleSpeed;
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
    _pinned = null;
    onWake?.call();
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
  bool _didInitialFit = false;
  bool _panelOpen = true; // filter/navigator tree panel (wide layout)

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
    _load();
    SyncService().dataVersion.addListener(_onData);
  }

  @override
  void dispose() {
    SyncService().dataVersion.removeListener(_onData);
    _reloadDebounce?.cancel();
    _ticker.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _onData() {
    // A store change may add/remove connections — rebuild, debounced so a burst
    // of edits (or a sync pull) coalesces into one walk.
    _reloadDebounce?.cancel();
    _reloadDebounce = Timer(const Duration(milliseconds: 400), _load);
  }

  Future<void> _load() async {
    final data = await GraphService().buildGraph();
    if (!mounted) return;
    setState(() {
      _loading = false;
      _empty = data.isEmpty;
    });
    _controller.setData(data);
    // Frame the whole graph once the first layout has had a moment to spread.
    if (!_didInitialFit && !data.isEmpty) {
      _didInitialFit = true;
      Future.delayed(const Duration(milliseconds: 650), () {
        if (mounted) _controller.fitToScreen();
      });
    }
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
    LinkNavigator().reveal(data.reveal!);
  }

  void _onHover(PointerHoverEvent e) {
    final node = _controller.hitTest(e.localPosition);
    _controller.setHover(node?.data.key);
  }

  void _openFilterSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => FractionallySizedBox(
        heightFactor: 0.8,
        child: _GraphFilterPanel(controller: _controller),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = theme.extension<AppPalette>()!;
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 640;
        final showSidePanel = wide && _panelOpen && !_empty && !_loading;
        final graph = _buildGraphArea(theme, palette, wide);
        if (!showSidePanel) return graph;
        return Row(
          children: [
            Container(
              width: 274,
              decoration: BoxDecoration(
                color: palette.surface2,
                border: Border(right: BorderSide(color: palette.border)),
              ),
              child: _GraphFilterPanel(controller: _controller),
            ),
            Expanded(child: graph),
          ],
        );
      },
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
      top: 12,
      left: 16,
      right: 16,
      child: Row(
        children: [
          if (!_empty && !_loading)
            _iconPill(
              palette,
              wide
                  ? (panelShown ? Icons.chevron_left : Icons.filter_list)
                  : Icons.filter_list,
              'Filter & navigate',
              () {
                if (wide) {
                  setState(() => _panelOpen = !_panelOpen);
                } else {
                  _openFilterSheet();
                }
              },
            ),
          const SizedBox(width: 8),
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

    // Edges (thickness + opacity from the appearance sliders).
    final edgePaint = Paint()
      ..style = PaintingStyle.stroke
      ..color = palette.dot.withValues(alpha: c.linkOpacity)
      ..strokeWidth = c.linkThickness;
    final edgeHot = Paint()
      ..style = PaintingStyle.stroke
      ..color = palette.accent.withValues(alpha: math.max(0.9, c.linkOpacity))
      ..strokeWidth = c.linkThickness * 1.6;
    for (final e in c.edges) {
      final a = screenPos[e.aKey];
      final b = screenPos[e.bKey];
      if (a == null || b == null) continue;
      final hot = hover != null && (e.aKey == hover || e.bKey == hover);
      canvas.drawLine(a, b, hot ? edgeHot : edgePaint);
    }

    // Nodes.
    final showLabels = c.zoom > 0.45;
    final hlContainer = c.highlightContainerId;
    for (final node in c.nodes) {
      final d = node.data;
      final sp = screenPos[d.key]!;
      final r = c.radiusOf(node);
      final isHover = d.key == hover;
      final isNeighbor = neighbors.contains(d.key);
      final dim = hover != null && !isHover && !isNeighbor;
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

      if (showLabels || isHover || treeHit) {
        _label(canvas, node, sp, r, dim && !treeHit);
      }
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
              .withValues(alpha: dim ? 0.35 : 0.95),
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

/// A container in the filter tree (notebook → section → canvas), holding a
/// count of graph nodes under it.
class _Ct {
  final String id;
  final String name;
  final LinkTargetKind kind;
  final Map<String, _Ct> children = {};
  int count = 0;
  _Ct(this.id, this.name, this.kind);
}

/// The graph's filter + navigator panel: a notebook → section → canvas tree of
/// the containers that appear in the graph. Checkboxes scope which nodes show;
/// hovering a row highlights its nodes in the graph (and hovering a node
/// highlights its path here); tapping a row label frames its nodes. Reused as a
/// side column (wide) and a bottom sheet (narrow).
class _GraphFilterPanel extends StatefulWidget {
  final GraphController controller;
  const _GraphFilterPanel({required this.controller});

  @override
  State<_GraphFilterPanel> createState() => _GraphFilterPanelState();
}

class _GraphFilterPanelState extends State<_GraphFilterPanel> {
  final Set<String> _expanded = {};
  bool _appearanceOpen = false;
  GraphController get c => widget.controller;

  ({List<_Ct> roots, int external}) _buildTree() {
    final roots = <String, _Ct>{};
    var external = 0;
    for (final n in c.allNodes) {
      if (n.notebookId == null) {
        external++;
        continue;
      }
      final nb = roots.putIfAbsent(n.notebookId!,
          () => _Ct(n.notebookId!, n.notebookName ?? 'Notebook',
              LinkTargetKind.notebook));
      nb.count++;
      if (n.sectionId != null) {
        final sec = nb.children.putIfAbsent(n.sectionId!,
            () => _Ct(n.sectionId!, n.sectionName ?? 'Section',
                LinkTargetKind.section));
        sec.count++;
        if (n.canvasId != null) {
          sec.children
              .putIfAbsent(
                  n.canvasId!,
                  () => _Ct(n.canvasId!, n.canvasName ?? 'Canvas',
                      LinkTargetKind.canvas))
              .count++;
        }
      }
    }
    final list = roots.values.toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return (roots: list, external: external);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = theme.extension<AppPalette>()!;
    return ValueListenableBuilder<int>(
      valueListenable: c.uiVersion,
      builder: (context, _, _) {
        final tree = _buildTree();
        final hn = c.nodeByKey(c.hoverKey);
        final hlIds = <String>{
          if (hn?.notebookId != null) hn!.notebookId!,
          if (hn?.sectionId != null) hn!.sectionId!,
          if (hn?.canvasId != null) hn!.canvasId!,
        };
        final rows = <Widget>[];
        for (final root in tree.roots) {
          _appendRows(rows, root, 0, false, hlIds, palette);
        }
        return SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 14, 8, 8),
                child: Row(
                  children: [
                    Text('Filter & navigate',
                        style: TextStyle(
                            fontSize: 13.5,
                            fontWeight: FontWeight.w700,
                            color: theme.colorScheme.onSurface)),
                    const Spacer(),
                    Text('${c.nodes.length}/${c.allNodes.length}',
                        style:
                            TextStyle(fontSize: 11.5, color: palette.textDim)),
                  ],
                ),
              ),
              _toggle(palette, 'Expand items inside canvases',
                  !c.abstractInsideItems, (v) => c.setAbstractInsideItems(!v)),
              _toggle(palette, 'External links', c.showExternal,
                  (v) => c.setShowExternal(v)),
              _appearanceSection(palette),
              Divider(height: 1, color: palette.border),
              Expanded(
                child: rows.isEmpty
                    ? Center(
                        child: Text('Nothing to filter',
                            style: TextStyle(
                                fontSize: 12, color: palette.textDim)))
                    : ListView(padding: EdgeInsets.zero, children: rows),
              ),
              Divider(height: 1, color: palette.border),
              _legend(palette),
            ],
          ),
        );
      },
    );
  }

  void _appendRows(List<Widget> out, _Ct node, int depth, bool ancestorHidden,
      Set<String> hlIds, AppPalette palette) {
    final selfHidden = c.hiddenContainers.contains(node.id);
    final effectiveHidden = ancestorHidden || selfHidden;
    final hasChildren = node.children.isNotEmpty;
    final expanded = _expanded.contains(node.id);
    out.add(_rowTile(node, depth, effectiveHidden, ancestorHidden, hasChildren,
        expanded, hlIds, palette));
    if (hasChildren && expanded) {
      final kids = node.children.values.toList()
        ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      for (final k in kids) {
        _appendRows(out, k, depth + 1, effectiveHidden, hlIds, palette);
      }
    }
  }

  Widget _rowTile(
      _Ct node,
      int depth,
      bool effectiveHidden,
      bool ancestorHidden,
      bool hasChildren,
      bool expanded,
      Set<String> hlIds,
      AppPalette palette) {
    final highlighted = hlIds.contains(node.id);
    final color = AppPalette.identityColor(node.id);
    return MouseRegion(
      onEnter: (_) => c.setHighlightContainer(node.id),
      onExit: (_) {
        if (c.highlightContainerId == node.id) c.setHighlightContainer(null);
      },
      child: InkWell(
        onTap: () => c.focusContainer(node.id),
        child: Container(
          color: highlighted ? palette.accentSoft : null,
          padding: EdgeInsets.only(left: 6.0 + depth * 14, right: 6),
          height: 32,
          child: Row(
            children: [
              SizedBox(
                width: 18,
                child: hasChildren
                    ? InkWell(
                        onTap: () => setState(() {
                          if (!_expanded.remove(node.id)) {
                            _expanded.add(node.id);
                          }
                        }),
                        child: Icon(
                            expanded
                                ? Icons.expand_more
                                : Icons.chevron_right,
                            size: 16,
                            color: palette.textDim),
                      )
                    : null,
              ),
              _ShapeIcon(shape: _shapeForKind(node.kind), color: color, size: 13),
              const SizedBox(width: 7),
              Expanded(
                child: Text(
                  node.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12.5,
                    color: effectiveHidden
                        ? palette.textDim
                        : Theme.of(context).colorScheme.onSurface,
                    fontWeight: depth == 0 ? FontWeight.w600 : FontWeight.w400,
                  ),
                ),
              ),
              Text('${node.count}',
                  style: TextStyle(fontSize: 11, color: palette.textDim)),
              SizedBox(
                width: 34,
                child: Checkbox(
                  value: !effectiveHidden,
                  // Can't re-enable a row hidden by an ancestor.
                  onChanged: ancestorHidden
                      ? null
                      : (v) => c.setContainerHidden(node.id, !(v ?? true)),
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
          onTap: () => setState(() => _appearanceOpen = !_appearanceOpen),
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
          _slider(palette, 'Link thickness', c.linkThickness, 0.4, 3.0,
              c.setLinkThickness),
          _slider(palette, 'Link opacity', c.linkOpacity, 0.1, 1.0,
              c.setLinkOpacity),
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

/// The [_NodeShape] for a container kind (the tree only ever holds
/// notebook/section/canvas, but kept general).
_NodeShape _shapeForKind(LinkTargetKind kind) {
  switch (kind) {
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
