import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import '../models/canvas_page.dart';
import '../models/element.dart';
import '../models/canvas.dart';
import '../services/notebook_service.dart';
import '../services/render_cache.dart';
import '../services/settings_service.dart';
import '../services/sync/merge_engine.dart';
import '../services/sync_service.dart';
import 'canvas_layout.dart';
import 'rich_text_controller.dart';
import 'text_measure.dart';

/// The active tool on the canvas.
enum CanvasTool { pen, highlighter, eraser, lasso, text }

/// What a pointer drag over the current selection does.
enum SelectionHit { none, move, resizeTL, resizeTR, resizeBL, resizeBR, rotate }

/// Where to place an inserted blank page / PDF.
enum InsertPosition { top, aboveCurrent, belowCurrent, end }

/// One undoable operation. [apply] must be re-runnable (redo) and [revert]
/// must exactly restore prior state; both capture deep-copied snapshots, not
/// live references, wherever elements are involved.
class _CanvasOp {
  final String label;
  final VoidCallback apply;
  final VoidCallback revert;
  final Set<String> dirtyPageIds;
  final bool structural;

  _CanvasOp({
    required this.label,
    required this.apply,
    required this.revert,
    this.dirtyPageIds = const {},
    this.structural = false,
  });
}

/// All canvas state + behavior: app-owned viewport (pan/zoom over the page
/// layout), tool gestures in page-local points, op-based undo/redo, lasso
/// selection with live transforms, clipboard, page/row structure edits, and
/// debounced persistence. The screen widget is a thin shell around this.
class CanvasController extends ChangeNotifier {
  CanvasController({required this.canvas, required this.pages})
    : _service = NotebookService() {
    renderCache = RenderCache(onUpdated: notifyListeners);
    _relayout();
    // Live merge: pulled remote changes to this canvas land here directly
    // instead of only on disk (where the next autosave would clobber them).
    SyncService().registerCanvasListener(
      canvas.id,
      CanvasSyncListener(
        onPage: applyRemotePage,
        onStructure: () => unawaited(applyRemoteStructure()),
      ),
    );
  }

  final Canvas canvas;
  final Map<String, CanvasPage> pages;
  final NotebookService _service;
  late final RenderCache renderCache;

  // ── Layout & viewport ──────────────────────────────────────────────────

  CanvasLayout layout = const CanvasLayout(pages: [], size: Size.zero);
  Size screenSize = Size.zero;
  double zoom = 1.0;
  Offset pan = Offset.zero;
  bool _viewportInitialized = false;

  static const double minZoom = 0.25;
  static const double maxZoom = 8.0;
  static const double _panMargin = 60;

  Matrix4 get viewportMatrix => Matrix4.identity()
    ..translateByDouble(pan.dx, pan.dy, 0, 1)
    ..scaleByDouble(zoom, zoom, 1, 1);

  Offset screenToCanvas(Offset s) => (s - pan) / zoom;
  Offset canvasToScreen(Offset c) => c * zoom + pan;

  Rect pageScreenRect(String pageId, Rect localRect) {
    final l = layout.layoutOf(pageId);
    if (l == null) return Rect.zero;
    final canvasRect = localRect.shift(l.rect.topLeft);
    return Rect.fromPoints(
      canvasToScreen(canvasRect.topLeft),
      canvasToScreen(canvasRect.bottomRight),
    );
  }

  void _relayout() {
    layout = computeLayout(canvas, pages);
  }

  /// Called from build/layout — mutates only, never notifies (the painter
  /// reads state at paint time, which happens after build anyway).
  void setScreenSize(Size size) {
    if (size == screenSize) return;
    screenSize = size;
    if (!_viewportInitialized && layout.pages.isNotEmpty && !size.isEmpty) {
      _viewportInitialized = true;
      // Reopen where the user left this canvas (device-local memory);
      // first-ever open falls back to fitting the first page.
      final saved = SettingsService().viewportFor(canvas.id);
      if (saved != null) {
        zoom = saved.zoom.clamp(minZoom, maxZoom);
        pan = Offset(saved.panX, saved.panY);
        _clampPan();
      } else {
        fitPageWidth(layout.pages.first.pageId, notify: false);
      }
    } else {
      _clampPan();
    }
  }

  /// Zooms so [pageId] spans the screen width (with padding) and scrolls its
  /// top into view.
  void fitPageWidth(String pageId, {bool notify = true}) {
    final l = layout.layoutOf(pageId);
    if (l == null || screenSize.isEmpty) return;
    const pad = 16.0;
    zoom = ((screenSize.width - pad * 2) / l.rect.width).clamp(
      minZoom,
      maxZoom,
    );
    pan = Offset(
      (screenSize.width - l.rect.width * zoom) / 2 - l.rect.left * zoom,
      pad - l.rect.top * zoom,
    );
    stopScrollAnimation();
    _clampPan();
    if (notify) notifyListeners();
  }

  void jumpToPage(String pageId) => fitPageWidth(pageId);

  // ── Smooth scrolling (ticker-driven) ─────────────────────────────────
  //
  // Touch drag pans 1:1 (no lag); the momentum lives in the release fling.
  // Wheel scrolling glides toward a target with exponential smoothing so it
  // isn't a hard step per notch. One ticker serves both, switching between
  // "smooth-to-target" and "fling" modes.

  Ticker? _scrollTicker;
  Duration _lastTickElapsed = Duration.zero;
  Offset _panTarget = Offset.zero;
  Offset _flingVelocity = Offset.zero;
  bool _flinging = false;

  static const double _smoothStiffness = 18.0; // higher = snappier glide
  static const double _flingDrag = 4.5; // higher = stops sooner
  static const double _maxFlingSpeed = 6000; // px/s

  void _startTicker() {
    _scrollTicker ??= Ticker(_onScrollTick);
    _lastTickElapsed = Duration.zero;
    if (!_scrollTicker!.isActive) _scrollTicker!.start();
  }

  /// Halts any in-flight momentum/glide (e.g. when the user grabs again).
  void stopScrollAnimation() {
    _flinging = false;
    _flingVelocity = Offset.zero;
    _panTarget = pan;
    if (_scrollTicker?.isActive ?? false) _scrollTicker!.stop();
  }

  void _onScrollTick(Duration elapsed) {
    final dt = _lastTickElapsed == Duration.zero
        ? 1 / 60
        : ((elapsed - _lastTickElapsed).inMicroseconds / 1e6).clamp(0.0, 0.05);
    _lastTickElapsed = elapsed;

    if (_flinging) {
      var next = _clamped(pan + _flingVelocity * dt);
      // Kill velocity on the axis that hit an edge so it doesn't "stick".
      if (next.dx == pan.dx) _flingVelocity = Offset(0, _flingVelocity.dy);
      if (next.dy == pan.dy) _flingVelocity = Offset(_flingVelocity.dx, 0);
      pan = next;
      _flingVelocity *= math.exp(-dt * _flingDrag);
      if (_flingVelocity.distance < 16) {
        _flinging = false;
        _panTarget = pan;
        _scrollTicker!.stop();
      }
    } else {
      final t = 1 - math.exp(-dt * _smoothStiffness);
      pan = _clamped(
        Offset(
          pan.dx + (_panTarget.dx - pan.dx) * t,
          pan.dy + (_panTarget.dy - pan.dy) * t,
        ),
      );
      if ((_panTarget - pan).distance < 0.5) {
        pan = _clamped(_panTarget);
        _scrollTicker!.stop();
      }
    }
    notifyListeners();
  }

  /// Touch-drag pan: immediate, 1:1. Returns the unconsumed delta (fed to the
  /// over-scroll gesture).
  Offset panImmediate(Offset screenDelta) {
    final before = pan;
    pan = _clamped(pan + screenDelta);
    _panTarget = pan;
    notifyListeners();
    return screenDelta - (pan - before);
  }

  /// Mouse-wheel / trackpad scroll: glide toward an accumulating target.
  void scrollByWheel(Offset delta) {
    _panTarget = _clamped((_flinging ? pan : _panTarget) + delta);
    _flinging = false;
    _startTicker();
  }

  /// Inertial fling from a touch release velocity (px/s).
  void flingBy(Offset velocity) {
    if (velocity.distance < 140) {
      _panTarget = pan;
      return;
    }
    _flingVelocity = Offset(
      velocity.dx.clamp(-_maxFlingSpeed, _maxFlingSpeed),
      velocity.dy.clamp(-_maxFlingSpeed, _maxFlingSpeed),
    );
    _flinging = true;
    _startTicker();
  }

  void zoomAt(Offset screenFocal, double factor) {
    final newZoom = (zoom * factor).clamp(minZoom, maxZoom);
    if (newZoom == zoom) return;
    pan = _clamped(screenFocal - (screenFocal - pan) * (newZoom / zoom));
    zoom = newZoom;
    _panTarget = pan;
    notifyListeners();
  }

  Offset _clamped(Offset p) {
    if (screenSize.isEmpty) return p;
    final contentW = layout.size.width * zoom;
    final contentH = layout.size.height * zoom;

    double axis(double v, double content, double screen) {
      if (content <= screen) return (screen - content) / 2;
      return v.clamp(screen - content - _panMargin, _panMargin);
    }

    return Offset(
      axis(p.dx, contentW, screenSize.width),
      axis(p.dy, contentH, screenSize.height),
    );
  }

  void _clampPan() {
    pan = _clamped(pan);
    _panTarget = pan;
  }

  // ── Scrollbars ────────────────────────────────────────────────────────

  static const double scrollbarThickness = 6;
  static const double _scrollbarMinThumb = 32;
  static const double _scrollbarInset = 2;

  Rect? verticalScrollbarThumb() {
    if (screenSize.isEmpty) return null;
    final contentH = layout.size.height * zoom;
    final trackH = screenSize.height;
    if (contentH <= trackH + 1) return null;
    final thumbH = math.max(_scrollbarMinThumb, trackH * trackH / contentH);
    final maxScroll = contentH - trackH;
    final scrolled = (-pan.dy).clamp(0.0, maxScroll);
    final top = maxScroll <= 0 ? 0.0 : scrolled / maxScroll * (trackH - thumbH);
    return Rect.fromLTWH(
      screenSize.width - scrollbarThickness - _scrollbarInset,
      top,
      scrollbarThickness,
      thumbH,
    );
  }

  Rect? horizontalScrollbarThumb() {
    if (screenSize.isEmpty) return null;
    final contentW = layout.size.width * zoom;
    final trackW = screenSize.width;
    if (contentW <= trackW + 1) return null;
    final thumbW = math.max(_scrollbarMinThumb, trackW * trackW / contentW);
    final maxScroll = contentW - trackW;
    final scrolled = (-pan.dx).clamp(0.0, maxScroll);
    final left = maxScroll <= 0 ? 0.0 : scrolled / maxScroll * (trackW - thumbW);
    return Rect.fromLTWH(
      left,
      screenSize.height - scrollbarThickness - _scrollbarInset,
      thumbW,
      scrollbarThickness,
    );
  }

  String? _scrollbarAxis;
  double _scrollbarGrab = 0;

  bool get isDraggingScrollbar => _scrollbarAxis != null;

  /// Begins a scrollbar-thumb drag if [pos] hits a thumb (called for mouse).
  bool beginScrollbarDrag(Offset pos) {
    final v = verticalScrollbarThumb();
    if (v != null && v.inflate(8).contains(pos)) {
      stopScrollAnimation();
      _scrollbarAxis = 'v';
      _scrollbarGrab = pos.dy - v.top;
      return true;
    }
    final h = horizontalScrollbarThumb();
    if (h != null && h.inflate(8).contains(pos)) {
      stopScrollAnimation();
      _scrollbarAxis = 'h';
      _scrollbarGrab = pos.dx - h.left;
      return true;
    }
    return false;
  }

  void updateScrollbarDrag(Offset pos) {
    if (_scrollbarAxis == 'v') {
      final contentH = layout.size.height * zoom;
      final trackH = screenSize.height;
      final thumbH = math.max(_scrollbarMinThumb, trackH * trackH / contentH);
      final maxThumb = trackH - thumbH;
      final top = (pos.dy - _scrollbarGrab).clamp(0.0, maxThumb);
      final frac = maxThumb <= 0 ? 0.0 : top / maxThumb;
      pan = _clamped(Offset(pan.dx, -frac * (contentH - trackH)));
    } else if (_scrollbarAxis == 'h') {
      final contentW = layout.size.width * zoom;
      final trackW = screenSize.width;
      final thumbW = math.max(_scrollbarMinThumb, trackW * trackW / contentW);
      final maxThumb = trackW - thumbW;
      final left = (pos.dx - _scrollbarGrab).clamp(0.0, maxThumb);
      final frac = maxThumb <= 0 ? 0.0 : left / maxThumb;
      pan = _clamped(Offset(-frac * (contentW - trackW), pan.dy));
    }
    _panTarget = pan;
    notifyListeners();
  }

  void endScrollbarDrag() => _scrollbarAxis = null;

  /// The page under the viewport center — target for "current page" actions.
  PageLayout? get currentPageLayout {
    final center = screenToCanvas(
      Offset(screenSize.width / 2, screenSize.height / 2),
    );
    return layout.pageAt(center) ?? layout.nearestPage(center);
  }

  // ── Tool & style state ─────────────────────────────────────────────────

  CanvasTool tool = CanvasTool.pen;

  // Per-tool style memory: pen, highlighter, and text each keep their own
  // color (and the two ink tools their own width) — switching tools restores
  // that tool's last choice instead of sharing one global color.
  Color penColor = const Color(0xFFD9553B); // red default
  Color highlighterColor = const Color(0xFFF2C230); // amber default
  Color textColor = const Color(0xFF17171A);
  double penSize = 4.0;
  double highlighterSize = 6.0;

  /// The active tool's color (pen color for eraser/lasso, where it only
  /// matters as the "apply color to selection" source).
  Color get color => switch (tool) {
        CanvasTool.highlighter => highlighterColor,
        CanvasTool.text => textColor,
        _ => penColor,
      };

  set color(Color v) {
    switch (tool) {
      case CanvasTool.highlighter:
        highlighterColor = v;
      case CanvasTool.text:
        textColor = v;
      default:
        penColor = v;
    }
  }

  double get strokeSize =>
      tool == CanvasTool.highlighter ? highlighterSize : penSize;

  set strokeSize(double v) {
    if (tool == CanvasTool.highlighter) {
      highlighterSize = v;
    } else {
      penSize = v;
    }
  }

  // Current text style — the single source of truth for the toolbar. Applies
  // to the element being edited (live), else the text selection (undoable),
  // else it's just the default for the next new text box.
  String textFontFamily = 'sans';
  double textFontSize = 18;
  bool textBold = false;
  bool textItalic = false;
  TextAlignOption textAlign = TextAlignOption.left;

  TextElement? _editingElement;
  RichTextController? _richController;

  bool get isEditingText => _editingElement != null;

  /// Sets the text element open in the editing overlay (and its rich-text
  /// controller) so style changes target the in-box selection. Pass nulls
  /// when editing ends.
  void setEditing(TextElement? element, RichTextController? controller) {
    _editingElement = element;
    _richController = controller;
    editingElementId = element?.id;
    if (element != null) {
      textFontFamily = element.fontFamily;
      textFontSize = element.fontSize;
      textBold = element.bold;
      textItalic = element.italic;
      textAlign = element.align;
    }
    notifyListeners();
  }

  /// Whether the active tool's options panel (colors/size, selection actions,
  /// text style, etc.) is expanded. Tapping the already-active tool again
  /// toggles this; switching to a different tool always closes it — so
  /// options only ever appear on a deliberate re-tap, in both the normal
  /// toolbar and the full-screen floating tool control.
  bool toolOptionsOpen = false;

  void setTool(CanvasTool t) {
    if (tool == t) {
      toolOptionsOpen = !toolOptionsOpen;
      notifyListeners();
      return;
    }
    if (t != CanvasTool.lasso) clearSelection(notify: false);
    tool = t;
    toolOptionsOpen = false;
    notifyListeners();
  }

  /// Closes the tool options panel (e.g. on an outside tap). No-op if already
  /// closed, so callers don't need to check first.
  void closeToolOptions() {
    if (!toolOptionsOpen) return;
    toolOptionsOpen = false;
    notifyListeners();
  }

  /// Public nudge for widgets that mutate simple style fields directly
  /// (color, sizes) and need the toolbar/painter to refresh.
  void notifyRepaint() => notifyListeners();

  // ── Text style application ───────────────────────────────────────────
  //
  // Each setter updates the default, then applies to the editing element
  // (live, folded into the eventual edit op) or the selected text (its own
  // undoable op). Re-measures the box so size/family changes reflow it.

  void setTextFontSize(double size) {
    textFontSize = size.clamp(8, 96);
    _applyTextStyle(
      attr: (a) => a.fontSize = textFontSize,
      run: (r) => r.fontSize = textFontSize,
    );
  }

  void setTextFontFamily(String family) {
    textFontFamily = family;
    _applyTextStyle(
      attr: (a) => a.family = family,
      run: (r) => r.fontFamily = family,
    );
  }

  void setTextColor(Color value) {
    textColor = value;
    _applyTextStyle(attr: (a) => a.color = value, run: (r) => r.color = value);
  }

  void toggleTextBold() {
    textBold = !textBold;
    _applyTextStyle(attr: (a) => a.bold = textBold, run: (r) => r.bold = textBold);
  }

  void toggleTextItalic() {
    textItalic = !textItalic;
    _applyTextStyle(
      attr: (a) => a.italic = textItalic,
      run: (r) => r.italic = textItalic,
    );
  }

  /// Alignment is paragraph-level (whole box), not per-run.
  void cycleTextAlign() {
    textAlign = TextAlignOption
        .values[(textAlign.index + 1) % TextAlignOption.values.length];
    if (_editingElement != null) {
      _editingElement!.align = textAlign;
      notifyListeners();
    } else if (selectionIsTextOnly) {
      updateSelectedText((t) => t.align = textAlign);
    } else {
      notifyListeners();
    }
  }

  /// Routes a style change to the in-box text selection while editing, else to
  /// the whole selected box(es), else just updates the default for new text.
  void _applyTextStyle({
    required void Function(CharAttr) attr,
    required void Function(TextRun) run,
  }) {
    if (_richController != null) {
      _richController!.applyToSelection(attr); // re-measure via onStyleChanged
    } else if (selectionIsTextOnly) {
      updateSelectedText((t) {
        for (final r in t.runs) {
          run(r);
        }
      });
    } else {
      notifyListeners(); // just changed the default for new text
    }
  }

  /// Applies [mutate] to every selected text element as one undoable op,
  /// re-measuring each box afterward.
  void updateSelectedText(void Function(TextElement) mutate) {
    final pageId = selectionPageId;
    if (pageId == null || !selectionIsTextOnly) return;
    final before = [for (final el in selection) el.deepCopy()];
    for (final el in selection) {
      if (el is TextElement) {
        mutate(el);
        _remeasureText(el, pageId);
      }
    }
    _stamp(selection.whereType<TextElement>());
    final after = [for (final el in selection) el.deepCopy()];
    var applied = true;
    _doOp(
      _CanvasOp(
        label: 'Text style',
        dirtyPageIds: {pageId},
        apply: () {
          if (applied) {
            applied = false;
            return;
          }
          _replaceElements(pageId, after);
        },
        revert: () => _replaceElements(pageId, before),
      ),
    );
  }

  void _remeasureText(TextElement el, String pageId) {
    final page = pages[pageId];
    if (page == null) return;
    final maxWidth = page.width - el.rect.left - 6;
    el.rect = autoTextRect(el, maxWidth);
  }

  // ── Undo / redo ────────────────────────────────────────────────────────

  final List<_CanvasOp> _undoStack = [];
  final List<_CanvasOp> _redoStack = [];
  static const int _maxOps = 100;

  bool get canUndo => _undoStack.isNotEmpty;
  bool get canRedo => _redoStack.isNotEmpty;

  void _doOp(_CanvasOp op) {
    op.apply();
    _undoStack.add(op);
    if (_undoStack.length > _maxOps) _undoStack.removeAt(0);
    _redoStack.clear();
    _afterMutation(op);
  }

  void undo() {
    if (_undoStack.isEmpty) return;
    final op = _undoStack.removeLast();
    op.revert();
    _redoStack.add(op);
    clearSelection(notify: false);
    _afterMutation(op);
  }

  void redo() {
    if (_redoStack.isEmpty) return;
    final op = _redoStack.removeLast();
    op.apply();
    _undoStack.add(op);
    clearSelection(notify: false);
    _afterMutation(op);
  }

  void _afterMutation(_CanvasOp op) {
    if (op.structural) _relayout();
    _markDirty(op.dirtyPageIds, structural: op.structural);
    notifyListeners();
  }

  // ── Persistence (debounced, per-page) ──────────────────────────────────

  final Set<String> _dirtyPages = {};
  bool _dirtyStructure = false;
  Timer? _saveTimer;

  void _markDirty(Set<String> pageIds, {bool structural = false}) {
    _dirtyPages.addAll(pageIds);
    if (structural) _dirtyStructure = true;
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 500), flushSaves);
  }

  Future<void> flushSaves() async {
    _saveTimer?.cancel();
    final pageIds = Set.of(_dirtyPages);
    final structure = _dirtyStructure;
    _dirtyPages.clear();
    _dirtyStructure = false;
    for (final id in pageIds) {
      final page = pages[id];
      if (page != null) await _service.savePage(canvas, page);
    }
    if (structure) await _service.saveCanvas(canvas);
  }

  // ── Drawing (pen / highlighter) ────────────────────────────────────────

  StrokeElement? activeStroke;
  String? activeStrokePageId;

  // Eraser accumulation for the current gesture: pageId → removed (index, el).
  final Map<String, List<(int, CanvasElement)>> _eraseAccum = {};
  static const double _eraseRadius = 10.0; // page points

  // Lasso in progress (page-local points on _gesturePageId).
  List<Offset>? lassoPoints;
  String? _gesturePageId;

  /// Tool resolved at gesture start (S-Pen side button can force the eraser
  /// regardless of the selected tool) — drives update/end routing.
  CanvasTool? _activeGestureTool;

  /// Page the in-progress lasso belongs to (painter reads this).
  String? get gesturePageId => _gesturePageId;

  /// Element currently being edited in the text overlay — the painter skips
  /// it so the TextField isn't doubled by the painted text underneath.
  String? editingElementId;

  /// Resolves an assetId to its file in this canvas's assets dir.
  File assetFileOf(String assetId) => _service.assetFile(canvas, assetId);

  bool get hasActiveGesture =>
      activeStroke != null ||
      lassoPoints != null ||
      _eraseAccum.isNotEmpty ||
      _dragMode != SelectionHit.none;

  Offset _clampToPage(Offset local, CanvasPage page) => Offset(
    local.dx.clamp(0.0, page.width),
    local.dy.clamp(0.0, page.height),
  );

  /// Pointer down for a drawing-capable device (stylus / mouse). Returns true
  /// if the event was consumed by a tool gesture.
  bool startToolGesture(
    Offset screenPos,
    double pressure, {
    bool forceEraser = false,
  }) {
    final canvasPos = screenToCanvas(screenPos);
    final effectiveTool = forceEraser ? CanvasTool.eraser : tool;

    // A live selection intercepts drags (move/resize/rotate) in lasso mode.
    if (selection.isNotEmpty && !forceEraser) {
      final hit = hitTestSelection(screenPos);
      if (hit != SelectionHit.none) {
        _beginSelectionDrag(hit, canvasPos);
        return true;
      }
      if (effectiveTool == CanvasTool.lasso) clearSelection();
    }

    final pageLayout = layout.pageAt(canvasPos);
    if (pageLayout == null) return false;
    final page = pages[pageLayout.pageId]!;
    final local = canvasPos - pageLayout.rect.topLeft;

    switch (effectiveTool) {
      case CanvasTool.pen:
      case CanvasTool.highlighter:
        final p = _clampToPage(local, page);
        activeStrokePageId = page.id;
        activeStroke = StrokeElement(
          id: newModelId('el'),
          deviceId: SettingsService().deviceId,
          z: '0|a0:',
          tool: effectiveTool == CanvasTool.highlighter
              ? StrokeTool.highlighter
              : StrokeTool.pen,
          color: color,
          size: strokeSize,
          points: [StrokePoint(p.dx, p.dy, pressure)],
        );
        _activeGestureTool = effectiveTool;
        notifyListeners();
        return true;
      case CanvasTool.eraser:
        _eraseAccum.clear();
        _activeGestureTool = CanvasTool.eraser;
        _eraseAt(canvasPos);
        return true;
      case CanvasTool.lasso:
        _gesturePageId = page.id;
        lassoPoints = [local];
        _activeGestureTool = CanvasTool.lasso;
        notifyListeners();
        return true;
      case CanvasTool.text:
        // Text placement happens on pointer-up (tap) in the screen widget.
        return false;
    }
  }

  void updateToolGesture(Offset screenPos, double pressure) {
    final canvasPos = screenToCanvas(screenPos);

    if (_dragMode != SelectionHit.none) {
      _updateSelectionDrag(canvasPos);
      return;
    }

    switch (_activeGestureTool) {
      case CanvasTool.pen:
      case CanvasTool.highlighter:
        final stroke = activeStroke;
        if (stroke == null) return;
        final l = layout.layoutOf(activeStrokePageId!);
        final page = pages[activeStrokePageId!];
        if (l != null && page != null) {
          final p = _clampToPage(canvasPos - l.rect.topLeft, page);
          stroke.points.add(StrokePoint(p.dx, p.dy, pressure));
          stroke.invalidateCache();
          notifyListeners();
        }
      case CanvasTool.eraser:
        _eraseAt(canvasPos);
      case CanvasTool.lasso:
        final lasso = lassoPoints;
        if (lasso == null || _gesturePageId == null) return;
        final l = layout.layoutOf(_gesturePageId!);
        if (l != null) {
          lasso.add(canvasPos - l.rect.topLeft);
          notifyListeners();
        }
      case CanvasTool.text:
      case null:
        return;
    }
  }

  void endToolGesture() {
    if (_dragMode != SelectionHit.none) {
      _endSelectionDrag();
      return;
    }
    final gestureTool = _activeGestureTool;
    _activeGestureTool = null;

    switch (gestureTool) {
      case CanvasTool.pen:
      case CanvasTool.highlighter:
        final stroke = activeStroke;
        if (stroke == null) return;
        final pageId = activeStrokePageId!;
        activeStroke = null;
        activeStrokePageId = null;
        if (stroke.points.length > 1) {
          _doOp(_addElementsOp('Draw', pageId, [stroke]));
        } else {
          notifyListeners();
        }
      case CanvasTool.eraser:
        _commitErase();
      case CanvasTool.lasso:
        _finishLasso();
      case CanvasTool.text:
      case null:
        return;
    }
  }

  void cancelToolGesture() {
    _activeGestureTool = null;
    activeStroke = null;
    activeStrokePageId = null;
    lassoPoints = null;
    _gesturePageId = null;
    // Erase already applied live — commit what happened rather than losing it.
    if (_eraseAccum.isNotEmpty) {
      _commitErase();
      return;
    }
    _dragMode = SelectionHit.none;
    notifyListeners();
  }

  // ── Eraser (whole-stroke, live) ────────────────────────────────────────

  void _eraseAt(Offset canvasPos) {
    final pageLayout = layout.pageAt(canvasPos);
    if (pageLayout == null) return;
    final page = pages[pageLayout.pageId]!;
    final local = canvasPos - pageLayout.rect.topLeft;

    var removedAny = false;
    for (var i = page.strokes.length - 1; i >= 0; i--) {
      final el = page.strokes[i];
      if (_strokeHit(el, local)) {
        page.strokes.removeAt(i);
        _eraseAccum.putIfAbsent(page.id, () => []).add((i, el));
        removedAny = true;
      }
    }
    if (removedAny) notifyListeners();
  }

  void _commitErase() {
    final accum = Map.of(_eraseAccum);
    _eraseAccum.clear();
    if (accum.isEmpty) return;

    // The live gesture (_eraseAt) already removed the strokes from the
    // array, but tombstones MUST be written on this first apply too — the
    // array removal alone syncs as "stroke missing, no tombstone", which the
    // other device's union merge treats as "I still have it" and resurrects.
    // removeWhere on already-removed ids is a no-op, so apply is safely
    // idempotent for both the first run and redo.
    _doOp(
      _CanvasOp(
        label: 'Erase',
        dirtyPageIds: accum.keys.toSet(),
        apply: () {
          for (final entry in accum.entries) {
            final page = pages[entry.key];
            if (page == null) continue;
            final ids = entry.value.map((r) => r.$2.id).toSet();
            for (final el in entry.value) {
              page.erased.add(EraseTombstone(
                strokeId: el.$2.id,
                erasedAt: DateTime.now(),
                deviceId: SettingsService().deviceId,
              ));
            }
            page.strokes.removeWhere((e) => ids.contains(e.id));
          }
        },
        revert: () {
          for (final entry in accum.entries) {
            final page = pages[entry.key];
            if (page == null) continue;
            // Re-insert in ascending index order to restore z-positions.
            final sorted = [...entry.value]
              ..sort((a, b) => a.$1.compareTo(b.$1));
            final ids = entry.value.map((r) => r.$2.id).toSet();
            page.erased.removeWhere((e) => ids.contains(e.strokeId));
            for (final (index, el) in sorted) {
              page.strokes.insert(
                math.min(index, page.strokes.length),
                el as StrokeElement,
              );
            }
          }
        },
      ),
    );
  }

  bool _strokeHit(StrokeElement stroke, Offset point) {
    final radius = _eraseRadius + stroke.size / 2;
    final pts = stroke.points;
    if (pts.isEmpty) return false;
    if (pts.length == 1) {
      return (Offset(pts[0].x, pts[0].y) - point).distance <= radius;
    }
    for (var i = 0; i < pts.length - 1; i++) {
      if (_distToSegment(
            point,
            Offset(pts[i].x, pts[i].y),
            Offset(pts[i + 1].x, pts[i + 1].y),
          ) <=
          radius) {
        return true;
      }
    }
    return false;
  }

  double _distToSegment(Offset p, Offset a, Offset b) {
    final ab = b - a;
    final lengthSq = ab.dx * ab.dx + ab.dy * ab.dy;
    if (lengthSq == 0) return (p - a).distance;
    final t = (((p.dx - a.dx) * ab.dx + (p.dy - a.dy) * ab.dy) / lengthSq)
        .clamp(0.0, 1.0);
    return (p - Offset(a.dx + t * ab.dx, a.dy + t * ab.dy)).distance;
  }

  // ── Selection (lasso) ──────────────────────────────────────────────────

  /// Live references into the selected page's element list.
  List<CanvasElement> selection = [];
  String? selectionPageId;
  Rect? selectionBounds; // page-local

  SelectionHit _dragMode = SelectionHit.none;
  Offset _dragLast = Offset.zero; // canvas space
  List<CanvasElement> _dragBefore = [];

  void clearSelection({bool notify = true}) {
    selection = [];
    selectionPageId = null;
    selectionBounds = null;
    _dragMode = SelectionHit.none;
    if (notify) notifyListeners();
  }

  void _finishLasso() {
    final pts = lassoPoints;
    final pageId = _gesturePageId;
    lassoPoints = null;
    _gesturePageId = null;
    if (pts == null || pageId == null || pts.length < 3) {
      notifyListeners();
      return;
    }
    final page = pages[pageId]!;
    final hit = <CanvasElement>[];
    for (final el in [...page.strokes, ...page.objects]) {
      if (_lassoHits(pts, el)) hit.add(el);
    }
    if (hit.isEmpty) {
      clearSelection();
      return;
    }
    selection = hit;
    selectionPageId = pageId;
    _recomputeSelectionBounds();
    notifyListeners();
  }

  bool _lassoHits(List<Offset> polygon, CanvasElement el) {
    switch (el) {
      case StrokeElement():
        // Sample points (cap the work for very long strokes).
        final step = math.max(1, el.points.length ~/ 64);
        for (var i = 0; i < el.points.length; i += step) {
          if (_pointInPolygon(
            Offset(el.points[i].x, el.points[i].y),
            polygon,
          )) {
            return true;
          }
        }
        return false;
      case TextElement(:final rect):
      case ImageElement(:final rect):
      case AttachmentElement(:final rect):
        for (final corner in [
          rect.topLeft,
          rect.topRight,
          rect.bottomLeft,
          rect.bottomRight,
          rect.center,
        ]) {
          if (_pointInPolygon(corner, polygon)) return true;
        }
        return false;
    }
  }

  bool _pointInPolygon(Offset p, List<Offset> polygon) {
    var inside = false;
    for (var i = 0, j = polygon.length - 1; i < polygon.length; j = i++) {
      final a = polygon[i], b = polygon[j];
      if ((a.dy > p.dy) != (b.dy > p.dy) &&
          p.dx < (b.dx - a.dx) * (p.dy - a.dy) / (b.dy - a.dy) + a.dx) {
        inside = !inside;
      }
    }
    return inside;
  }

  void _recomputeSelectionBounds() {
    if (selection.isEmpty) {
      selectionBounds = null;
      return;
    }
    var rect = selection.first.bounds;
    for (final el in selection.skip(1)) {
      rect = rect.expandToInclude(el.bounds);
    }
    selectionBounds = rect;
  }

  /// Selection bbox in screen space (for handle hit-testing and overlay UI).
  Rect? get selectionScreenRect {
    final b = selectionBounds;
    final pageId = selectionPageId;
    if (b == null || pageId == null) return null;
    return pageScreenRect(pageId, b);
  }

  static const double _handleHitRadius = 22; // screen px

  SelectionHit hitTestSelection(Offset screenPos) {
    final rect = selectionScreenRect;
    if (rect == null) return SelectionHit.none;

    bool near(Offset p) => (p - screenPos).distance <= _handleHitRadius;
    // Text boxes have no resize corners (they auto-size); only move + rotate.
    if (!selectionIsTextOnly) {
      if (near(rect.topLeft)) return SelectionHit.resizeTL;
      if (near(rect.topRight)) return SelectionHit.resizeTR;
      if (near(rect.bottomLeft)) return SelectionHit.resizeBL;
      if (near(rect.bottomRight)) return SelectionHit.resizeBR;
    }
    if (near(rect.topCenter - const Offset(0, 36))) return SelectionHit.rotate;
    if (rect.inflate(8).contains(screenPos)) return SelectionHit.move;
    return SelectionHit.none;
  }

  bool get selectionIsTextOnly =>
      selection.isNotEmpty && selection.every((e) => e is TextElement);

  /// Selects exactly one element (used by text-mode tap/drag-to-move).
  void selectSingle(String pageId, CanvasElement element) {
    selectionPageId = pageId;
    selection = [element];
    _recomputeSelectionBounds();
    notifyListeners();
  }

  void _beginSelectionDrag(SelectionHit hit, Offset canvasPos) {
    _dragMode = hit;
    _dragLast = canvasPos;
    _dragBefore = [for (final el in selection) el.deepCopy()];
  }

  void _updateSelectionDrag(Offset canvasPos) {
    final pageLayout = layout.layoutOf(selectionPageId!);
    final bounds = selectionBounds;
    if (pageLayout == null || bounds == null) return;
    final delta = canvasPos - _dragLast;

    switch (_dragMode) {
      case SelectionHit.move:
        for (final el in selection) {
          el.translate(delta.dx, delta.dy);
        }
      case SelectionHit.resizeTL:
      case SelectionHit.resizeTR:
      case SelectionHit.resizeBL:
      case SelectionHit.resizeBR:
        final anchor = switch (_dragMode) {
          SelectionHit.resizeTL => bounds.bottomRight,
          SelectionHit.resizeTR => bounds.bottomLeft,
          SelectionHit.resizeBL => bounds.topRight,
          _ => bounds.topLeft,
        };
        final localPos = canvasPos - pageLayout.rect.topLeft;
        final localLast = _dragLast - pageLayout.rect.topLeft;
        final distNow = (localPos - anchor).distance;
        final distLast = (localLast - anchor).distance;
        if (distLast > 1e-3 && distNow > 1e-3) {
          final factor = distNow / distLast;
          // Don't collapse the selection into a point.
          final size = math.max(bounds.width, bounds.height);
          if (size * factor > 8 || factor > 1) {
            for (final el in selection) {
              el.scaleBy(factor, anchor);
            }
          }
        }
      case SelectionHit.rotate:
        final center = bounds.center;
        final localPos = canvasPos - pageLayout.rect.topLeft;
        final localLast = _dragLast - pageLayout.rect.topLeft;
        final angle =
            math.atan2(localPos.dy - center.dy, localPos.dx - center.dx) -
            math.atan2(localLast.dy - center.dy, localLast.dx - center.dx);
        for (final el in selection) {
          el.rotateBy(angle, center);
        }
      case SelectionHit.none:
        return;
    }

    _dragLast = canvasPos;
    _recomputeSelectionBounds();
    notifyListeners();
  }

  /// Marks mutated elements as "edited now" for sync LWW. Without this every
  /// element kept rev 1 / its creation timestamp forever, so two devices'
  /// copies always tied in the (rev, updatedAt, deviceId) comparison and each
  /// kept its own version — moved/edited elements never converged.
  void _stamp(Iterable<CanvasElement> els) {
    final dev = SettingsService().deviceId;
    for (final el in els) {
      el.bumpRev(dev);
    }
  }

  void _endSelectionDrag() {
    _dragMode = SelectionHit.none;
    final pageId = selectionPageId;
    if (pageId == null || selection.isEmpty) {
      _dragBefore = [];
      return;
    }
    final before = _dragBefore;
    _dragBefore = [];

    // If a move dropped the selection over a different page, reparent it there
    // (elements are otherwise stuck in the source page's list and get clipped
    // to it — the "items end up below the page" bug).
    final target = _dropTargetPage(pageId);
    if (target != null && target != pageId) {
      _reparentSelection(pageId, target, before);
      return;
    }

    _stamp(selection);
    final after = [for (final el in selection) el.deepCopy()];
    var applied = true;
    _doOp(
      _CanvasOp(
        label: 'Transform',
        dirtyPageIds: {pageId},
        apply: () {
          if (applied) {
            applied = false; // live mutation already happened
            return;
          }
          _replaceElements(pageId, after);
        },
        revert: () => _replaceElements(pageId, before),
      ),
    );
  }

  /// The page currently under the selection's center (canvas space), or null.
  String? _dropTargetPage(String sourcePageId) {
    final sourceLayout = layout.layoutOf(sourcePageId);
    final bounds = selectionBounds;
    if (sourceLayout == null || bounds == null) return null;
    final canvasCenter = sourceLayout.rect.topLeft + bounds.center;
    return layout.pageAt(canvasCenter)?.pageId;
  }

  /// Moves the selected elements from [sourceId] to [targetId], converting
  /// their coordinates into the target page's local space and appending them
  /// on top. One undoable op covering both pages.
  void _reparentSelection(
    String sourceId,
    String targetId,
    List<CanvasElement> movingBeforeDrag,
  ) {
    final source = pages[sourceId];
    final target = pages[targetId];
    final sourceLayout = layout.layoutOf(sourceId);
    final targetLayout = layout.layoutOf(targetId);
    if (source == null ||
        target == null ||
        sourceLayout == null ||
        targetLayout == null) {
      return;
    }

    final movedIds = selection.map((e) => e.id).toSet();
    // source-local → target-local: add the difference of page origins.
    final shift = sourceLayout.rect.topLeft - targetLayout.rect.topLeft;

    // Pre-drag snapshots (moving elements restored to their start positions).
    final beforeById = {for (final b in movingBeforeDrag) b.id: b};
    final sourceElements = [...source.strokes, ...source.objects];
    final targetElements = [...target.strokes, ...target.objects];
    final sourceBefore = [
      for (final e in sourceElements)
        (beforeById[e.id] ?? e).deepCopy(),
    ];
    final targetBefore = [for (final e in targetElements) e.deepCopy()];

    // After: moving elements leave the source, land on the target shifted.
    final sourceAfter = [
      for (final e in sourceElements)
        if (!movedIds.contains(e.id)) e.deepCopy(),
    ];
    final movingAfter = [
      for (final e in sourceElements)
        if (movedIds.contains(e.id)) e.deepCopy()..translate(shift.dx, shift.dy),
    ];
    // Moved elements are edits for sync LWW — the copy that landed on the
    // target must beat any stale remote copy of them.
    _stamp(movingAfter);
    final targetAfter = [
      for (final e in targetElements) e.deepCopy(),
      ...movingAfter,
    ];

    clearSelection(notify: false);
    _doOp(
      _CanvasOp(
        label: 'Move to page',
        dirtyPageIds: {sourceId, targetId},
        apply: () {
          _setPageElements(sourceId, sourceAfter);
          _setPageElements(targetId, targetAfter);
          // The moved ids vanished from the source page — tombstone them
          // there, or a stale remote copy of the source page resurrects them
          // on merge (→ duplicates, since they're also live on the target).
          // On the target they're live: clear any old tombstones for them.
          final dev = SettingsService().deviceId;
          final now = DateTime.now();
          for (final el in movingAfter) {
            final t = EraseTombstone(
                strokeId: el.id, erasedAt: now, deviceId: dev);
            if (el is StrokeElement) {
              source.erased.add(t);
              target.erased.removeWhere((e) => e.strokeId == el.id);
            } else {
              source.deletedObjects.add(t);
              target.deletedObjects.removeWhere((e) => e.strokeId == el.id);
            }
          }
        },
        revert: () {
          _setPageElements(sourceId, sourceBefore);
          _setPageElements(targetId, targetBefore);
          for (final id in movedIds) {
            source.erased.removeWhere((e) => e.strokeId == id);
            source.deletedObjects.removeWhere((e) => e.strokeId == id);
          }
        },
      ),
    );

    // Reselect the moved elements on the target page.
    selectionPageId = targetId;
    selection = [...target.strokes, ...target.objects].where((e) => movedIds.contains(e.id)).toList();
    _recomputeSelectionBounds();
    notifyListeners();
  }

  void _setPageElements(String pageId, List<CanvasElement> copies) {
    final page = pages[pageId];
    if (page == null) return;
    page.strokes.clear();
    page.objects.clear();
    for (final c in copies) {
      final copy = c.deepCopy();
      if (copy is StrokeElement) page.strokes.add(copy);
      else page.objects.add(copy);
    }
  }

  void _replaceElements(String pageId, List<CanvasElement> copies) {
    final page = pages[pageId];
    if (page == null) return;
    for (final copy in copies) {
      if (copy is StrokeElement) {
        final i = page.strokes.indexWhere((e) => e.id == copy.id);
        if (i >= 0) page.strokes[i] = copy.deepCopy() as StrokeElement;
      } else {
        final i = page.objects.indexWhere((e) => e.id == copy.id);
        if (i >= 0) page.objects[i] = copy.deepCopy();
      }
    }
    // Selection may hold stale refs after replacement.
    if (selectionPageId == pageId && selection.isNotEmpty) {
      final ids = selection.map((e) => e.id).toSet();
      selection = [...page.strokes, ...page.objects].where((e) => ids.contains(e.id)).toList();
      _recomputeSelectionBounds();
    }
  }

  // ── Selection actions ──────────────────────────────────────────────────

  static List<CanvasElement> _appClipboard = [];
  static bool get clipboardHasContent => _appClipboard.isNotEmpty;

  /// Set by the screen: mirrors a copy to the OS clipboard (text or a PNG of
  /// the selection) and handles paste when the internal clipboard is empty
  /// (OS image/text). Kept as hooks because capturing pixels needs the
  /// widget tree (RepaintBoundary), which the controller doesn't own.
  Future<void> Function()? systemCopyHook;
  Future<void> Function()? systemPasteFallback;

  void deleteSelection() {
    final pageId = selectionPageId;
    if (pageId == null || selection.isEmpty) return;
    final page = pages[pageId]!;
    final removedStrokes = <(int, StrokeElement)>[];
    final removedObjects = <(int, CanvasElement)>[];
    for (final el in selection) {
      if (el is StrokeElement) {
        final i = page.strokes.indexOf(el);
        if (i >= 0) removedStrokes.add((i, el));
      } else {
        final i = page.objects.indexOf(el);
        if (i >= 0) removedObjects.add((i, el));
      }
    }
    clearSelection(notify: false);
    _doOp(
      _CanvasOp(
        label: 'Delete',
        dirtyPageIds: {pageId},
        apply: () {
          final dev = SettingsService().deviceId;
          final now = DateTime.now();
          final strokeIds = removedStrokes.map((r) => r.$2.id).toSet();
          final objectIds = removedObjects.map((r) => r.$2.id).toSet();
          for (final id in strokeIds) {
            page.erased.add(EraseTombstone(strokeId: id, erasedAt: now, deviceId: dev));
          }
          for (final id in objectIds) {
            page.deletedObjects.add(EraseTombstone(strokeId: id, erasedAt: now, deviceId: dev));
          }
          page.strokes.removeWhere((e) => strokeIds.contains(e.id));
          page.objects.removeWhere((e) => objectIds.contains(e.id));
        },
        revert: () {
          final strokeIds = removedStrokes.map((r) => r.$2.id).toSet();
          final objectIds = removedObjects.map((r) => r.$2.id).toSet();
          page.erased.removeWhere((e) => strokeIds.contains(e.strokeId));
          page.deletedObjects.removeWhere((e) => objectIds.contains(e.strokeId));
          final sortedStrokes = [...removedStrokes]..sort((a, b) => a.$1.compareTo(b.$1));
          for (final (index, el) in sortedStrokes) {
            page.strokes.insert(math.min(index, page.strokes.length), el);
          }
          final sortedObjects = [...removedObjects]..sort((a, b) => a.$1.compareTo(b.$1));
          for (final (index, el) in sortedObjects) {
            page.objects.insert(math.min(index, page.objects.length), el);
          }
        },
      ),
    );
  }

  void copySelection() {
    _appClipboard = [for (final el in selection) el.deepCopy()];
    unawaited(systemCopyHook?.call()); // mirror to the OS clipboard
    notifyListeners();
  }

  void cutSelection() {
    copySelection();
    deleteSelection();
  }

  void duplicateSelection() {
    final pageId = selectionPageId;
    if (pageId == null || selection.isEmpty) return;
    final copies = [
      for (final el in selection) el.deepCopy(withNewId: true)..translate(16, 16),
    ];
    _doOp(_addElementsOp('Duplicate', pageId, copies));
    final page = pages[pageId]!;
    selection = [...page.strokes, ...page.objects].where((e) => copies.any((c) => c.id == e.id)).toList();
    _recomputeSelectionBounds();
    notifyListeners();
  }

  /// Paste the internal clipboard centered in the current page; falls back to
  /// the OS clipboard (image, then text) when the internal one is empty.
  void pasteClipboard() {
    if (_appClipboard.isEmpty) {
      unawaited(systemPasteFallback?.call());
      return;
    }
    final target = currentPageLayout;
    if (target == null) return;
    final page = pages[target.pageId]!;

    final copies = [for (final el in _appClipboard) el.deepCopy(withNewId: true)];
    var bbox = copies.first.bounds;
    for (final el in copies.skip(1)) {
      bbox = bbox.expandToInclude(el.bounds);
    }
    final targetCenter = Offset(page.width / 2, page.height / 2);
    final shift = targetCenter - bbox.center;
    for (final el in copies) {
      el.translate(shift.dx, shift.dy);
    }

    _doOp(_addElementsOp('Paste', target.pageId, copies));
    selectionPageId = target.pageId;
    selection = [...page.strokes, ...page.objects].where((e) => copies.any((c) => c.id == e.id)).toList();
    _recomputeSelectionBounds();
    tool = CanvasTool.lasso;
    toolOptionsOpen = false;
    notifyListeners();
  }

  void bringSelectionToFront() => _reorderSelection(front: true);
  void sendSelectionToBack() => _reorderSelection(front: false);

  void _reorderSelection({required bool front}) {
    final pageId = selectionPageId;
    if (pageId == null || selection.isEmpty) return;
    final page = pages[pageId]!;
    final beforeStrokes = List.of(page.strokes);
    final beforeObjects = List.of(page.objects);
    final selectedStrokes = selection.whereType<StrokeElement>().toList();
    final selectedObjects = selection.where((e) => e is! StrokeElement).toList();

    final restStrokes = page.strokes.where((e) => !selectedStrokes.contains(e)).toList();
    final restObjects = page.objects.where((e) => !selectedObjects.contains(e)).toList();

    final afterStrokes = front ? [...restStrokes, ...selectedStrokes] : [...selectedStrokes, ...restStrokes];
    final afterObjects = front ? [...restObjects, ...selectedObjects] : [...selectedObjects, ...restObjects];

    // zIndex is what actually moves the selection across the stroke/object
    // split (an image behind ink, ink above an image); the list reorder above
    // only settles ties within each list.
    final all = [...page.strokes, ...page.objects];
    var minZ = 0.0, maxZ = 0.0;
    for (final el in all) {
      if (el.zIndex < minZ) minZ = el.zIndex;
      if (el.zIndex > maxZ) maxZ = el.zIndex;
    }
    final newZ = front ? maxZ + 1 : minZ - 1;
    final beforeZ = {for (final el in selection) el.id: el.zIndex};
    final selected = List.of(selection);
    _stamp(selected); // z change must sync (LWW needs a newer rev)

    _doOp(
      _CanvasOp(
        label: front ? 'Bring to front' : 'Send to back',
        dirtyPageIds: {pageId},
        apply: () {
          page.strokes..clear()..addAll(afterStrokes);
          page.objects..clear()..addAll(afterObjects);
          for (final el in selected) {
            el.zIndex = newZ;
          }
        },
        revert: () {
          page.strokes..clear()..addAll(beforeStrokes);
          page.objects..clear()..addAll(beforeObjects);
          for (final el in selected) {
            el.zIndex = beforeZ[el.id] ?? 0;
          }
        },
      ),
    );
  }

  /// Applies the current toolbar color to the selected strokes/text.
  void applyColorToSelection() {
    final pageId = selectionPageId;
    if (pageId == null || selection.isEmpty) return;
    final before = [for (final el in selection) el.deepCopy()];
    for (final el in selection) {
      switch (el) {
        case StrokeElement():
          el.color = color;
          el.invalidateCache();
        case TextElement():
          el.color = color;
        case ImageElement():
        case AttachmentElement():
          break;
      }
    }
    _stamp(selection.where((e) => e is StrokeElement || e is TextElement));
    final after = [for (final el in selection) el.deepCopy()];
    var applied = true;
    _doOp(
      _CanvasOp(
        label: 'Recolor',
        dirtyPageIds: {pageId},
        apply: () {
          if (applied) {
            applied = false;
            return;
          }
          _replaceElements(pageId, after);
        },
        revert: () => _replaceElements(pageId, before),
      ),
    );
  }

  // ── Element insertion (text / image / generic) ─────────────────────────

  /// Inserts [elements] (apply = do/redo, revert = undo the insert).
  ///
  /// Once an element could have synced, undoing its insert must still record
  /// a tombstone alongside the physical removal — a stale remote copy would
  /// otherwise resurrect it on the next merge. `apply` (redo) clears the
  /// tombstone and re-adds if missing.
  _CanvasOp _addElementsOp(
    String label,
    String pageId,
    List<CanvasElement> elements,
  ) {
    final page = pages[pageId]!;
    return _CanvasOp(
      label: label,
      dirtyPageIds: {pageId},
      apply: () {
        for (final el in elements) {
          if (el is StrokeElement) {
            page.erased.removeWhere((e) => e.strokeId == el.id);
            if (!page.strokes.any((e) => e.id == el.id)) page.strokes.add(el);
          } else {
            page.deletedObjects.removeWhere((e) => e.strokeId == el.id);
            if (!page.objects.any((e) => e.id == el.id)) page.objects.add(el);
          }
        }
      },
      revert: () {
        final dev = SettingsService().deviceId;
        final now = DateTime.now();
        final ids = elements.map((e) => e.id).toSet();
        for (final el in elements) {
          if (el is StrokeElement) {
            page.erased.add(EraseTombstone(strokeId: el.id, erasedAt: now, deviceId: dev));
          } else {
            page.deletedObjects.add(EraseTombstone(strokeId: el.id, erasedAt: now, deviceId: dev));
          }
        }
        page.strokes.removeWhere((e) => ids.contains(e.id));
        page.objects.removeWhere((e) => ids.contains(e.id));
      },
    );
  }

  void addElement(String pageId, CanvasElement element) {
    _doOp(_addElementsOp('Insert', pageId, [element]));
  }

  /// Drops an attachment chip near the top of the current page (stacking
  /// downward if others already sit there).
  void addAttachmentChip(String assetId, String name, String mime) {
    final target = currentPageLayout;
    if (target == null) return;
    final page = pages[target.pageId]!;
    const w = 180.0, h = 44.0, gap = 10.0;
    var top = 24.0;
    final left = (page.width - w) / 2;
    // Avoid stacking exactly on an existing chip.
    while (page.objects.any((e) =>
        e is AttachmentElement && (e.rect.top - top).abs() < h / 2)) {
      top += h + gap;
    }
    addElement(
      target.pageId,
      AttachmentElement(
        id: newModelId('el'),
        deviceId: SettingsService().deviceId,
        rect: Rect.fromLTWH(left, top, w, h),
        assetId: assetId,
        name: name,
        mime: mime,
      ),
    );
  }

  void updateTextElement(
    String pageId,
    TextElement before,
    TextElement after,
  ) {
    _stamp([after]);
    final beforeCopy = before.deepCopy();
    final afterCopy = after.deepCopy();
    _doOp(
      _CanvasOp(
        label: 'Edit text',
        dirtyPageIds: {pageId},
        apply: () => _replaceElements(pageId, [afterCopy]),
        revert: () => _replaceElements(pageId, [beforeCopy]),
      ),
    );
  }

  void removeElement(String pageId, CanvasElement element) {
    final page = pages[pageId];
    if (page == null) return;
    final dev = SettingsService().deviceId;
    if (element is StrokeElement) {
      final index = page.strokes.indexWhere((e) => e.id == element.id);
      if (index < 0) return;
      final el = page.strokes[index];
      _doOp(
        _CanvasOp(
          label: 'Remove',
          dirtyPageIds: {pageId},
          apply: () {
            page.erased.add(EraseTombstone(strokeId: el.id, erasedAt: DateTime.now(), deviceId: dev));
            page.strokes.removeWhere((e) => e.id == el.id);
          },
          revert: () {
            page.erased.removeWhere((e) => e.strokeId == el.id);
            page.strokes.insert(math.min(index, page.strokes.length), el);
          },
        ),
      );
    } else {
      final index = page.objects.indexWhere((e) => e.id == element.id);
      if (index < 0) return;
      final el = page.objects[index];
      _doOp(
        _CanvasOp(
          label: 'Remove',
          dirtyPageIds: {pageId},
          apply: () {
            page.deletedObjects.add(EraseTombstone(strokeId: el.id, erasedAt: DateTime.now(), deviceId: dev));
            page.objects.removeWhere((e) => e.id == el.id);
          },
          revert: () {
            page.deletedObjects.removeWhere((e) => e.strokeId == el.id);
            page.objects.insert(math.min(index, page.objects.length), el);
          },
        ),
      );
    }
  }

  // ── Page / row structure ───────────────────────────────────────────────

  int _rowInsertIndexFor(InsertPosition position) {
    final current = currentPageLayout;
    switch (position) {
      case InsertPosition.top:
        return 0;
      case InsertPosition.aboveCurrent:
        return current?.rowIndex ?? 0;
      case InsertPosition.belowCurrent:
        return (current?.rowIndex ?? canvas.rows.length - 1) + 1;
      case InsertPosition.end:
        return canvas.rows.length;
    }
  }

  /// Adds one blank page in its own new row.
  void addBlankPage(InsertPosition position) {
    final rowIndex = _rowInsertIndexFor(position);
    final page = CanvasPage(
      id: newModelId('pg'),
      deviceId: SettingsService().deviceId,
      width: canvas.defaultPageWidth,
      height: canvas.defaultPageHeight,
      background: canvas.defaultBackground,
    );
    final row = PageRow(id: _service.newId(), pageIds: [page.id]);

    _doOp(
      _CanvasOp(
        label: 'Add page',
        structural: true,
        dirtyPageIds: {page.id},
        apply: () {
          pages[page.id] = page;
          canvas.rows.insert(
            math.min(rowIndex, canvas.rows.length),
            row,
          );
        },
        revert: () {
          canvas.rows.remove(row);
          pages.remove(page.id);
        },
      ),
    );
  }

  /// Appends a page to the right end of a row (same size as the row's origin
  /// page) — the "extend horizontally" action.
  void addHorizontalPage(int rowIndex) {
    if (rowIndex < 0 || rowIndex >= canvas.rows.length) return;
    final row = canvas.rows[rowIndex];
    final origin = pages[row.pageIds.first];
    final page = CanvasPage(
      id: newModelId('pg'),
      deviceId: SettingsService().deviceId,
      width: origin?.width ?? canvas.defaultPageWidth,
      height: origin?.height ?? canvas.defaultPageHeight,
      background: canvas.defaultBackground,
    );

    _doOp(
      _CanvasOp(
        label: 'Add horizontal page',
        structural: true,
        dirtyPageIds: {page.id},
        apply: () {
          pages[page.id] = page;
          row.pageIds.add(page.id);
        },
        revert: () {
          row.pageIds.remove(page.id);
          pages.remove(page.id);
        },
      ),
    );
  }

  /// Inserts an imported PDF as consecutive PDF-backed rows.
  void insertPdfPages(
    String assetId,
    List<Size> pageSizes,
    InsertPosition position,
  ) {
    final rowIndex = _rowInsertIndexFor(position);
    final newPages = <CanvasPage>[];
    final newRows = <PageRow>[];
    // Normalize every PDF page to the canvas's default width (aspect ratio
    // preserved) so the canvas stays a clean, uniform-width column.
    final targetWidth = canvas.defaultPageWidth;
    for (var i = 0; i < pageSizes.length; i++) {
      final src = pageSizes[i];
      final scale = src.width > 0 ? targetWidth / src.width : 1.0;
      final page = CanvasPage(
        id: newModelId('pg'),
        deviceId: SettingsService().deviceId,
        width: targetWidth,
        height: src.height * scale,
        background: const PageBackground(),
        source: PdfSource(assetId: assetId, pageIndex: i),
      );
      newPages.add(page);
      newRows.add(PageRow(id: _service.newId(), pageIds: [page.id]));
    }

    _doOp(
      _CanvasOp(
        label: 'Insert PDF',
        structural: true,
        dirtyPageIds: newPages.map((p) => p.id).toSet(),
        apply: () {
          for (final p in newPages) {
            pages[p.id] = p;
          }
          canvas.rows.insertAll(
            math.min(rowIndex, canvas.rows.length),
            newRows,
          );
        },
        revert: () {
          for (final r in newRows) {
            canvas.rows.remove(r);
          }
          for (final p in newPages) {
            pages.remove(p.id);
          }
        },
      ),
    );
  }

  /// Deletes a page (refuses to delete the last remaining page).
  bool deletePage(String pageId) {
    if (layout.pages.length <= 1) return false;
    final l = layout.layoutOf(pageId);
    if (l == null) return false;
    final row = canvas.rows[l.rowIndex];
    final page = pages[pageId]!;
    final colIndex = row.pageIds.indexOf(pageId);
    final rowIndex = l.rowIndex;
    final rowBecomesEmpty = row.pageIds.length == 1;

    _doOp(
      _CanvasOp(
        label: 'Delete page',
        structural: true,
        apply: () {
          // The page leaves `pages` here, so the normal dirty-flush (which
          // looks the id up in `pages`) would never persist this. Tombstone
          // + save explicitly so the deletion actually reaches Drive instead
          // of silently staying live in the last-saved copy on disk.
          page.deletedAt = DateTime.now();
          page.bumpRev(SettingsService().deviceId);
          unawaited(_service.savePage(canvas, page));
          row.pageIds.remove(pageId);
          pages.remove(pageId);
          if (rowBecomesEmpty) canvas.rows.remove(row);
        },
        revert: () {
          page.deletedAt = null;
          page.bumpRev(SettingsService().deviceId);
          pages[pageId] = page;
          if (rowBecomesEmpty) {
            canvas.rows.insert(
              math.min(rowIndex, canvas.rows.length),
              row,
            );
          }
          if (!row.pageIds.contains(pageId)) {
            row.pageIds.insert(
              math.min(colIndex, row.pageIds.length),
              pageId,
            );
          }
          // Restored to `pages` — the normal dirty-flush will persist it
          // (dirtyPageIds below covers this).
        },
        dirtyPageIds: {pageId},
      ),
    );
    return true;
  }

  /// Duplicates a page into its own new row directly below.
  void duplicatePage(String pageId) {
    final l = layout.layoutOf(pageId);
    final src = pages[pageId];
    if (l == null || src == null) return;
    final copy = CanvasPage(
      id: newModelId('pg'),
      deviceId: SettingsService().deviceId,
      width: src.width,
      height: src.height,
      background: src.background,
      source: src.source,
      strokes: [
        for (final el in src.strokes) el.deepCopy(withNewId: true),
      ],
      objects: [
        for (final el in src.objects) el.deepCopy(withNewId: true),
      ],
      erased: [
        for (final el in src.erased)
          EraseTombstone(strokeId: el.strokeId, erasedAt: el.erasedAt, deviceId: el.deviceId, rev: el.rev)
      ],
    );
    final row = PageRow(id: _service.newId(), pageIds: [copy.id]);
    final insertAt = l.rowIndex + 1;

    _doOp(
      _CanvasOp(
        label: 'Duplicate page',
        structural: true,
        dirtyPageIds: {copy.id},
        apply: () {
          pages[copy.id] = copy;
          canvas.rows.insert(
            math.min(insertAt, canvas.rows.length),
            row,
          );
        },
        revert: () {
          canvas.rows.remove(row);
          pages.remove(copy.id);
        },
      ),
    );
  }

  void moveRow(int rowIndex, int direction) {
    final target = rowIndex + direction;
    if (rowIndex < 0 ||
        rowIndex >= canvas.rows.length ||
        target < 0 ||
        target >= canvas.rows.length) {
      return;
    }
    _doOp(
      _CanvasOp(
        label: 'Move row',
        structural: true,
        apply: () {
          final row = canvas.rows.removeAt(rowIndex);
          canvas.rows.insert(target, row);
        },
        revert: () {
          final row = canvas.rows.removeAt(target);
          canvas.rows.insert(rowIndex, row);
        },
      ),
    );
  }

  /// Sets [pageId]'s background, or — when [asSectionDefault] is ticked —
  /// sets the canvas's default *and* retroactively applies it to every page
  /// currently in the canvas (not just future new pages).
  void setPageBackground(
    String pageId,
    PageBackground background, {
    bool asSectionDefault = false,
  }) {
    if (asSectionDefault) {
      final previousDefault = canvas.defaultBackground;
      final previousPerPage = {
        for (final entry in pages.entries) entry.key: entry.value.background,
      };
      _doOp(
        _CanvasOp(
          label: 'Background (all pages)',
          dirtyPageIds: pages.keys.toSet(),
          structural: true,
          apply: () {
            canvas.defaultBackground = background;
            for (final page in pages.values) {
              page.background = background;
            }
          },
          revert: () {
            canvas.defaultBackground = previousDefault;
            for (final entry in previousPerPage.entries) {
              pages[entry.key]?.background = entry.value;
            }
          },
        ),
      );
      return;
    }

    final page = pages[pageId];
    if (page == null) return;
    final before = page.background;
    _doOp(
      _CanvasOp(
        label: 'Background',
        dirtyPageIds: {pageId},
        apply: () => page.background = background,
        revert: () => page.background = before,
      ),
    );
  }

  // ── Attachments ────────────────────────────────────────────────────────

  void addAttachment(Attachment attachment) {
    canvas.attachments.add(attachment);
    _markDirty(const {}, structural: true);
    notifyListeners();
  }

  void removeAttachment(Attachment attachment) {
    canvas.attachments.remove(attachment);
    _markDirty(const {}, structural: true);
    notifyListeners();
  }

  // ── Bookmarks (stored in canvas.json → synced) ─────────────────────────

  /// Bookmarks the page currently centered in the viewport.
  Bookmark? addBookmarkHere(String name) {
    final current = currentPageLayout;
    if (current == null) return null;
    final bm = Bookmark(
      id: newModelId('bm'),
      name: name,
      pageId: current.pageId,
      createdAt: DateTime.now(),
    );
    canvas.bookmarks.add(bm);
    _markDirty(const {}, structural: true);
    notifyListeners();
    return bm;
  }

  void removeBookmark(Bookmark bm) {
    canvas.bookmarks.removeWhere((b) => b.id == bm.id);
    _markDirty(const {}, structural: true);
    notifyListeners();
  }

  /// Jumps to a bookmark's page (no-op if that page is gone).
  void jumpToBookmark(Bookmark bm) {
    if (layout.layoutOf(bm.pageId) == null) return;
    jumpToPage(bm.pageId);
  }

  /// 1-based page ordinal for labels ("Page 3"), or null if not found.
  int? pageOrdinalOf(String pageId) {
    for (var i = 0; i < layout.pages.length; i++) {
      if (layout.pages[i].pageId == pageId) return i + 1;
    }
    return null;
  }

  // ── Over-scroll page adding (Samsung-Notes-style) ──────────────────────

  double overscrollRight = 0;
  double overscrollBottom = 0;
  static const double overscrollThreshold = 96; // screen px

  /// Feed the unconsumed pan from [panBy] during a touch pan gesture.
  void accumulateOverscroll(Offset unconsumed) {
    var changed = false;
    if (unconsumed.dx < 0) {
      overscrollRight = math.min(
        overscrollRight - unconsumed.dx,
        overscrollThreshold * 1.4,
      );
      changed = true;
    }
    if (unconsumed.dy < 0) {
      overscrollBottom = math.min(
        overscrollBottom - unconsumed.dy,
        overscrollThreshold * 1.4,
      );
      changed = true;
    }
    if (changed) notifyListeners();
  }

  /// Called at touch-pan end: adds a page if the user over-scrolled far
  /// enough past an edge. Returns true if a page was added (so the caller
  /// skips the inertial fling).
  bool settleOverscroll() {
    final addRight = overscrollRight >= overscrollThreshold;
    final addBottom = overscrollBottom >= overscrollThreshold;
    overscrollRight = 0;
    overscrollBottom = 0;

    if (addRight) {
      final current = currentPageLayout;
      if (current != null) addHorizontalPage(current.rowIndex);
      return true;
    } else if (addBottom) {
      addBlankPage(InsertPosition.end);
      return true;
    }
    notifyListeners();
    return false;
  }

  // ── Live merge of pulled remote changes (open-canvas sync) ─────────────

  /// Merges a pulled remote [remote] page into the live in-memory page.
  ///
  /// Without this, a canvas open during a pull kept stale in-memory state and
  /// its next 500 ms autosave overwrote the merged file on disk *without* the
  /// remote device's tombstones — resurrecting deleted strokes forever
  /// (each device kept re-pushing what the other kept deleting).
  void applyRemotePage(CanvasPage remote) {
    final local = pages[remote.id];
    if (local == null) return; // structure listener brings in new pages

    if (remote.deletedAt != null) {
      _removePageDeletedRemotely(remote.id);
      return;
    }

    final merged = MergeEngine.mergePage(local, remote);
    final mergedSig = MergeEngine.pageSignature(merged);
    final localChanged = mergedSig != MergeEngine.pageSignature(local);
    final contributed = mergedSig != MergeEngine.pageSignature(remote);

    if (localChanged) {
      // Mutate the existing instance in place — undo ops and the painter hold
      // references to it. Elements keep local identity where local won.
      final sizeChanged =
          local.width != merged.width || local.height != merged.height;
      local
        ..rev = merged.rev
        ..updatedAt = merged.updatedAt
        ..deviceId = merged.deviceId
        ..deletedAt = merged.deletedAt
        ..width = merged.width
        ..height = merged.height
        ..background = merged.background
        ..source = merged.source;
      local.strokes
        ..clear()
        ..addAll(merged.strokes);
      local.erased
        ..clear()
        ..addAll(merged.erased);
      local.objects
        ..clear()
        ..addAll(merged.objects);
      local.deletedObjects
        ..clear()
        ..addAll(merged.deletedObjects);

      // Selection/drag may reference instances the merge replaced.
      if (selectionPageId == remote.id) {
        clearSelection(notify: false);
        _dragMode = SelectionHit.none;
      }
      if (sizeChanged) _relayout();
      notifyListeners();
    }

    // Only push when the union holds something Drive lacks — pushing a
    // merged==remote page would just echo revisions back and forth.
    if (contributed) {
      _markDirty({remote.id});
    }
  }

  /// A page tombstoned on another device: drop it from the open canvas (no
  /// undo op — deletion already happened elsewhere; disk merge kept it).
  void _removePageDeletedRemotely(String pageId) {
    if (!pages.containsKey(pageId)) return;
    if (layout.pages.length <= 1) return; // never leave a canvas empty
    for (final row in List.of(canvas.rows)) {
      row.pageIds.remove(pageId);
      if (row.pageIds.isEmpty) canvas.rows.remove(row);
    }
    pages.remove(pageId);
    if (selectionPageId == pageId) clearSelection(notify: false);
    _relayout();
    notifyListeners();
  }

  /// canvas.json changed on disk from a pull — refresh structure (rows,
  /// defaults, attachments) and load any newly-referenced pages from disk.
  /// Skipped while local structural edits are still waiting to flush; LWW on
  /// the next round trip reconciles that case.
  Future<void> applyRemoteStructure() async {
    if (_dirtyStructure) return;
    final fresh =
        await _service.getCanvas(canvas.notebookId, canvas.sectionId, canvas.id);
    if (fresh == null) return; // canvas deleted remotely — shell reload handles

    canvas
      ..name = fresh.name
      ..color = fresh.color
      ..rev = fresh.rev
      ..updatedAt = fresh.updatedAt
      ..deviceId = fresh.deviceId
      ..defaultPageWidth = fresh.defaultPageWidth
      ..defaultPageHeight = fresh.defaultPageHeight
      ..defaultBackground = fresh.defaultBackground;
    canvas.rows
      ..clear()
      ..addAll(fresh.rows);
    canvas.attachments
      ..clear()
      ..addAll(fresh.attachments);
    canvas.bookmarks
      ..clear()
      ..addAll(fresh.bookmarks);

    // Keep live in-memory pages (they may be ahead of disk); read only the
    // ones we don't have yet, and drop ones no row references anymore.
    final referenced = <String>{
      for (final row in canvas.rows) ...row.pageIds,
    };
    final fromDisk = await _service.loadPages(canvas);
    for (final entry in fromDisk.entries) {
      pages.putIfAbsent(entry.key, () => entry.value);
    }
    pages.removeWhere((id, _) => !referenced.contains(id));
    if (selectionPageId != null && !pages.containsKey(selectionPageId)) {
      clearSelection(notify: false);
    }
    _relayout();
    notifyListeners();
  }

  @override
  void dispose() {
    // Remember where this canvas was left (device-local, not synced).
    if (_viewportInitialized) {
      SettingsService().saveCanvasViewport(canvas.id, zoom, pan.dx, pan.dy);
    }
    SyncService().unregisterCanvasListener(canvas.id);
    _scrollTicker?.dispose();
    _saveTimer?.cancel();
    flushSaves();
    renderCache.dispose();
    super.dispose();
  }
}
