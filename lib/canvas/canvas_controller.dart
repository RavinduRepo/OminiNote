import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import '../models/canvas_page.dart';
import '../models/element.dart';
import '../models/canvas.dart';
import '../models/shape_template.dart';
import '../services/audio_playback_service.dart';
import '../services/audio_recorder_service.dart';
import '../services/notebook_service.dart';
import '../services/page_clipboard.dart';
import '../services/pdf_text_extractor.dart';
import '../services/render_cache.dart';
import '../services/settings_service.dart';
import '../services/sync/merge_engine.dart';
import '../services/sync_service.dart';
import '../services/tts_service.dart';
import '../utils/audio_sync.dart';
import '../utils/ink_contrast.dart';
import '../utils/readable_text.dart';
import '../utils/url_text.dart';
import 'canvas_layout.dart';
import 'shape_recognizer.dart';
import 'page_picture_cache.dart';
import 'rich_text_controller.dart';
import 'text_measure.dart';

/// The active tool on the canvas.
enum CanvasTool { pen, highlighter, eraser, lasso, text, shape }

/// What a pointer drag over the current selection does. The corner handles
/// scale uniformly; the side handles (`resizeL/R/T/B`) stretch/squash along one
/// axis (non-uniform).
enum SelectionHit {
  none,
  move,
  resizeTL,
  resizeTR,
  resizeBL,
  resizeBR,
  resizeL,
  resizeR,
  resizeT,
  resizeB,
  rotate,
}

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

/// Vertical breathing room between an image pasted at the caret and the text
/// above/below it. See [CanvasController.insertImageAtCaret].
const double kImageBlockGap = 6.0;

/// Slack kept below the last line of text on a page before it's treated as
/// overflowing — matches the `page.height - 8` the typing-overflow check uses.
const double kPageTextMargin = 8.0;

/// A revivable element slot for undo/redo. Holds the (mutable) element — its
/// `rev` is bumped above the tombstone on revive, keeping the same id — and
/// its insertion index (-1 = append). See [CanvasController._reviveSlots].
class _ElSlot {
  final CanvasElement el;
  final int index;
  _ElSlot(this.el, [this.index = -1]);
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
        onRestorePage: restorePage,
      ),
    );
  }

  final Canvas canvas;
  final Map<String, CanvasPage> pages;
  final NotebookService _service;
  late final RenderCache renderCache;

  /// Committed-elements picture per page (painter replays instead of
  /// redrawing every element each frame). Every path that visually mutates a
  /// page's committed elements must invalidate its entry — committed ops ride
  /// `_markDirty`; the live eraser, live selection drags, and remote merges
  /// invalidate explicitly.
  final pictureCache = PagePictureCache();

  // ── Layout & viewport ──────────────────────────────────────────────────

  CanvasLayout layout = const CanvasLayout(pages: [], size: Size.zero);
  Size screenSize = Size.zero;
  double zoom = 1.0;
  Offset pan = Offset.zero;
  bool _viewportInitialized = false;

  static const double minZoom = 0.1;
  static const double maxZoom = 10.0;

  /// Pan slack (px) past every edge when the content exceeds the viewport — the
  /// rubber-band "give" you can push the page past its edges while zoomed in.
  /// Kept small so a fast scroll can't fling the page off past a big empty
  /// gutter; the far edges still over-scroll-to-add a page (that accumulates
  /// beyond this margin regardless). When the content is *smaller* than the
  /// viewport it's centered instead — unaffected, so zooming out is unchanged.
  static const double _panMargin = 3;

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
    const pad = 3.0;
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

  /// Pans (keeping zoom) the minimum amount needed to bring [canvasRect] (in
  /// canvas coords) inside the viewport with a small [margin]. A no-op when it's
  /// already visible — so read-aloud page-follow never jitters a visible page.
  void ensureCanvasRectVisible(Rect canvasRect, {double margin = 48}) {
    if (screenSize.isEmpty) return;
    final tl = canvasToScreen(canvasRect.topLeft);
    final br = canvasToScreen(canvasRect.bottomRight);
    double dx = 0, dy = 0;
    if (tl.dy < margin) {
      dy = margin - tl.dy;
    } else if (br.dy > screenSize.height - margin) {
      dy = (screenSize.height - margin) - br.dy;
      if (tl.dy + dy < margin) dy = margin - tl.dy; // keep the top visible
    }
    if (tl.dx < margin) {
      dx = margin - tl.dx;
    } else if (br.dx > screenSize.width - margin) {
      dx = (screenSize.width - margin) - br.dx;
      if (tl.dx + dx < margin) dx = margin - tl.dx;
    }
    if (dx == 0 && dy == 0) return;
    pan = pan + Offset(dx, dy);
    stopScrollAnimation();
    _clampPan();
    notifyListeners();
  }

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
    final left = maxScroll <= 0
        ? 0.0
        : scrolled / maxScroll * (trackW - thumbW);
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

  // ── Narrow UI-chrome notifiers ──────────────────────────────────────────
  // Mirror specific fields below (tool/toolOptionsOpen/selection/drag-mode/
  // editing) but are updated ONLY at their existing discrete mutation
  // points — never from the per-point drawing path (updateToolGesture,
  // _eraseAt, the hold-timer, snap-adjust). Chrome widgets (toolbar,
  // popovers, floating menus) must listen to these instead of the whole
  // controller: a fast pen stroke calls notifyListeners() on every sampled
  // point, and a widget listening to the whole controller rebuilds on every
  // one of those — the exact jank this was introduced to fix.
  final ValueNotifier<CanvasTool> toolNotifier = ValueNotifier(CanvasTool.text);
  final ValueNotifier<bool> toolOptionsOpenNotifier = ValueNotifier(false);
  final ValueNotifier<bool> hasSelectionNotifier = ValueNotifier(false);
  final ValueNotifier<bool> isDraggingSelectionNotifier = ValueNotifier(false);
  final ValueNotifier<bool> isEditingTextNotifier = ValueNotifier(false);
  final ValueNotifier<bool> clipboardNotifier = ValueNotifier(false);

  /// True while a voice recording is in progress (drives the recording bar).
  final ValueNotifier<bool> isRecordingAudioNotifier = ValueNotifier(false);

  /// Bumped whenever an open popover's own content may have changed (a
  /// color/size pick, a completed op) — a content-only refresh signal,
  /// deliberately separate from the visibility notifiers above.
  final ValueNotifier<int> chromeContentTick = ValueNotifier(0);

  // ── Tool & style state ─────────────────────────────────────────────────

  CanvasTool _tool = CanvasTool.text;
  CanvasTool get tool => _tool;
  set tool(CanvasTool t) {
    _tool = t;
    toolNotifier.value = t;
  }

  /// The one automatic tool switch: an S-Pen / stylus touching the canvas while
  /// the Text tool is active switches to the Pen (draw) tool. Only from Text —
  /// any deliberately-chosen tool is left alone — and there's no restore on
  /// lift (finger/mouse never draw unless Pen was explicitly picked).
  void handleStylusInput() {
    if (tool == CanvasTool.text) setTool(CanvasTool.pen);
  }

  // Per-tool style memory: pen, highlighter, and text each keep their own
  // color (and the two ink tools their own width) — switching tools restores
  // that tool's last choice instead of sharing one global color.
  // Initial ink/text colors follow the current theme so they're always visible
  // against the default page background: dark on light pages, light on dark.
  Color penColor = SettingsService().effectiveBrightness == Brightness.dark
      ? const Color(0xFFE8E8E8)
      : const Color(0xFF17171A);
  Color highlighterColor = const Color(0xFFF2C230); // amber — works on both
  Color textColor = SettingsService().effectiveBrightness == Brightness.dark
      ? const Color(0xFFE8E8E8)
      : const Color(0xFF17171A);
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
    isEditingTextNotifier.value = element != null;
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
  bool _toolOptionsOpen = false;
  bool get toolOptionsOpen => _toolOptionsOpen;
  set toolOptionsOpen(bool v) {
    _toolOptionsOpen = v;
    toolOptionsOpenNotifier.value = v;
  }

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
  void notifyRepaint() {
    chromeContentTick.value++;
    notifyListeners();
  }

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
    _applyTextStyle(
      attr: (a) => a.bold = textBold,
      run: (r) => r.bold = textBold,
    );
  }

  void toggleTextItalic() {
    textItalic = !textItalic;
    _applyTextStyle(
      attr: (a) => a.italic = textItalic,
      run: (r) => r.italic = textItalic,
    );
  }

  /// Toggles a list glyph (bullet/star, or the checkbox cycle) on the lines
  /// the in-box selection touches. Only meaningful while editing — the
  /// prefixes are plain characters in the text itself.
  void toggleTextListPrefix(String prefix, {bool cycle = false}) {
    _richController?.toggleLinePrefix(prefix, cycle: cycle);
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

  /// Flips a line-leading checkbox glyph (☐↔☑) at [charOffset] in a text
  /// element — the tap-on-canvas toggle (no editor opens). One undoable op;
  /// stamps the element for sync.
  void toggleCheckboxAt(String pageId, String elementId, int charOffset) {
    final page = pages[pageId];
    if (page == null) return;
    final el = page.objects
        .whereType<TextElement>()
        .cast<TextElement?>()
        .firstWhere((e) => e!.id == elementId, orElse: () => null);
    if (el == null) return;

    var acc = 0;
    for (final r in el.runs) {
      final end = acc + r.text.length;
      if (charOffset < end) {
        final i = charOffset - acc;
        final ch = r.text[i];
        if (ch != '☐' && ch != '☑') return;
        final before = [el.deepCopy()];
        r.text = r.text.replaceRange(i, i + 1, ch == '☐' ? '☑' : '☐');
        _remeasureText(el, pageId);
        _stamp([el]);
        final after = [el.deepCopy()];
        var applied = true;
        _doOp(
          _CanvasOp(
            label: 'Toggle checkbox',
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
        return;
      }
      acc = end;
    }
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
    if (op.structural) {
      _relayout();
      // A structural change can shrink the document — a page deleted from the
      // page menu, or an add-page undone — and leave the viewport stranded far
      // past the (now shorter) end, where the very next scroll immediately
      // over-scroll-adds another page. Halt any momentum and pull the viewport
      // back onto real content so the user always lands somewhere safe.
      stopScrollAnimation();
      _clampPan();
    }
    _markDirty(op.dirtyPageIds, structural: op.structural);
    chromeContentTick.value++;
    notifyListeners();
  }

  // ── Persistence (debounced, per-page) ──────────────────────────────────

  final Set<String> _dirtyPages = {};
  bool _dirtyStructure = false;
  Timer? _saveTimer;

  void _markDirty(Set<String> pageIds, {bool structural = false}) {
    for (final id in pageIds) {
      pictureCache.invalidate(id);
    }
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

  // ── Hold-to-snap shapes (device-local `shapeSnap`) ──────────────────────
  // While drawing with the pen, pausing without lifting recognizes the stroke
  // as a clean shape (see shape_recognizer.dart / SHAPES_PLAN Phase 1). The
  // recognized shape replaces the live stroke's points as a preview; lift then
  // commits it as two undo ops (undo #1 restores the freehand ink, undo #2
  // removes the stroke — Apple Notes semantics).
  static const Duration _kHoldDuration = Duration(milliseconds: 450);
  static const double _kHoldSlopScreen = 9.0; // screen px; /zoom → page-local
  static const double _kAdjustStartSlop = 6.0; // page pts before a grab begins
  Timer? _holdTimer;
  Offset? _holdAnchorLocal; // page-local point the slop is measured from
  List<StrokePoint>? _preSnapPoints; // freehand backup for undo-to-freehand
  bool _snapped = false; // shape currently previewed in [activeStroke]
  int _holdRetries = 0;
  ShapeFit? _snappedFit; // the recognized fit while snapped (for adjust)
  Offset?
  _adjustStart; // pen pos at snap; adjust begins once it moves past slop
  int? _adjustAnchor; // grabbed anchor once adjusting

  // ── Shapes tool (drag-to-draw a chosen kind or a saved template) ─────────
  /// Last-used shape kind for the Shapes tool (persisted device-local).
  ShapeToolKind shapeToolKind = SettingsService().shapeToolKind;

  /// When non-null the Shapes tool stamps this saved template instead of a
  /// predefined kind (Phase 3). Selecting a predefined kind clears it.
  ShapeTemplate? shapeToolTemplate;

  Offset? _shapeStartLocal; // drag anchor (page-local) for the shapes tool

  /// Multi-stroke live preview for a template drag (the painter draws these on
  /// [activeStrokePageId]; committed as one op on lift).
  List<StrokeElement> previewStrokes = [];

  void setShapeToolKind(ShapeToolKind kind) {
    final changed = shapeToolKind != kind || shapeToolTemplate != null;
    shapeToolTemplate = null;
    shapeToolKind = kind;
    SettingsService().setShapeToolKind(kind);
    // notifyRepaint bumps chromeContentTick so the (narrow-listening) shape
    // options popover refreshes its selected-kind highlight immediately —
    // a plain notifyListeners() wouldn't reach it.
    if (changed) notifyRepaint();
  }

  void setShapeToolTemplate(ShapeTemplate? t) {
    shapeToolTemplate = t;
    notifyRepaint();
  }

  Future<void> deleteShapeTemplate(String id) async {
    if (shapeToolTemplate?.id == id) shapeToolTemplate = null;
    await SettingsService().removeShapeTemplate(id);
    notifyRepaint();
  }

  bool get selectionIsStrokesOnly =>
      selection.isNotEmpty && selection.every((e) => e is StrokeElement);

  /// Saves the current strokes-only selection as a device-local template,
  /// normalized into the unit box (geometry only — the stamped copies take the
  /// pen's colour/size). No-op if the selection isn't strokes-only.
  Future<void> saveSelectionAsShape(String name) async {
    final strokes = selection.whereType<StrokeElement>().toList();
    if (strokes.isEmpty) return;
    var minX = double.infinity, minY = double.infinity;
    var maxX = -double.infinity, maxY = -double.infinity;
    for (final s in strokes) {
      for (final p in s.points) {
        minX = math.min(minX, p.x);
        minY = math.min(minY, p.y);
        maxX = math.max(maxX, p.x);
        maxY = math.max(maxY, p.y);
      }
    }
    final w = (maxX - minX).abs() < 1e-6 ? 1.0 : maxX - minX;
    final h = (maxY - minY).abs() < 1e-6 ? 1.0 : maxY - minY;
    final polylines = [
      for (final s in strokes)
        [for (final p in s.points) Offset((p.x - minX) / w, (p.y - minY) / h)],
    ];
    await SettingsService().addShapeTemplate(
      ShapeTemplate(
        id: newModelId('tmpl'),
        name: name.trim().isEmpty ? 'Shape' : name.trim(),
        polylines: polylines,
        createdAt: DateTime.now(),
      ),
    );
    notifyListeners();
  }

  bool _shiftDown() => HardwareKeyboard.instance.logicalKeysPressed.any(
    (k) =>
        k == LogicalKeyboardKey.shiftLeft || k == LogicalKeyboardKey.shiftRight,
  );

  /// Builds the stamped strokes for [t] scaled into [rect] (Rect.fromPoints
  /// normalizes it). [uniform] (Shift) preserves the template's aspect,
  /// centered in the box. Each polyline becomes one stroke in the pen's ink.
  List<StrokeElement> _templateStrokes(
    ShapeTemplate t,
    Rect rect, {
    bool uniform = false,
  }) {
    var w = rect.width, h = rect.height, ox = rect.left, oy = rect.top;
    if (uniform) {
      final s = math.min(w, h);
      ox = rect.left + (w - s) / 2;
      oy = rect.top + (h - s) / 2;
      w = s;
      h = s;
    }
    final out = <StrokeElement>[];
    for (final poly in t.polylines) {
      if (poly.length < 2) continue;
      out.add(
        StrokeElement(
          id: newModelId('el'),
          deviceId: SettingsService().deviceId,
          z: '0|a0:',
          tool: StrokeTool.pen,
          color: penColor,
          size: penSize,
          points: [
            for (final u in poly)
              StrokePoint(ox + u.dx * w, oy + u.dy * h, 0.5),
          ],
        ),
      );
    }
    return out;
  }

  /// True while a recognized shape is being previewed under the held pen — the
  /// screen suppresses its own tap handling for that pointer-up.
  bool get isShapeSnapped => _snapped;

  // Eraser accumulation for the current gesture: pageId → removed (index, el).
  final Map<String, List<(int, CanvasElement)>> _eraseAccum = {};

  // Partial-mode accumulation: pageId → surviving segment strokes added live
  // this gesture (new ids; committed together with the removals as one op).
  final Map<String, List<StrokeElement>> _segAccum = {};

  // Pages whose ink changed during the in-progress erase gesture. While a page
  // is in here the painter draws its committed elements DIRECTLY rather than
  // re-recording the page picture on every erased stroke; the set is cleared
  // and the pages re-recorded once when the gesture commits/cancels.
  final Set<String> _erasingPageIds = {};

  /// True while [pageId] is mid-erase (painter bypasses its picture cache).
  bool isErasingPage(String pageId) => _erasingPageIds.contains(pageId);

  /// Partial mode splits strokes at the erased gap instead of removing them
  /// whole. Device-local preference (screen persists via SettingsService).
  bool eraserPartial = false;

  /// Eraser radius in page points (screen persists via SettingsService).
  double eraserSize = 10.0;

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

  Offset _clampToPage(Offset local, CanvasPage page) =>
      Offset(local.dx.clamp(0.0, page.width), local.dy.clamp(0.0, page.height));

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
        // Arm hold-to-snap (pen or highlighter).
        _snapped = false;
        _preSnapPoints = null;
        _snappedFit = null;
        _adjustAnchor = null;
        _adjustStart = null;
        _holdRetries = 0;
        if (SettingsService().shapeSnap) {
          _holdAnchorLocal = p;
          _armHoldTimer();
        }
        notifyListeners();
        return true;
      case CanvasTool.eraser:
        _eraseAccum.clear();
        _segAccum.clear();
        _activeGestureTool = CanvasTool.eraser;
        _eraseAt(canvasPos);
        return true;
      case CanvasTool.lasso:
        _gesturePageId = page.id;
        lassoPoints = [local];
        _activeGestureTool = CanvasTool.lasso;
        notifyListeners();
        return true;
      case CanvasTool.shape:
        final p = _clampToPage(local, page);
        activeStrokePageId = page.id;
        _shapeStartLocal = p;
        previewStrokes = [];
        // Predefined kind uses a single activeStroke preview; a template uses
        // the multi-stroke previewStrokes list instead.
        activeStroke = shapeToolTemplate != null
            ? null
            : StrokeElement(
                id: newModelId('el'),
                deviceId: SettingsService().deviceId,
                z: '0|a0:',
                tool: StrokeTool.pen,
                color: penColor,
                size: penSize,
                points: [StrokePoint(p.dx, p.dy, 0.5)],
              );
        _activeGestureTool = CanvasTool.shape;
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
        if (_snapped) {
          _adjustSnappedShape(canvasPos);
          return;
        }
        final l = layout.layoutOf(activeStrokePageId!);
        final page = pages[activeStrokePageId!];
        if (l != null && page != null) {
          final p = _clampToPage(canvasPos - l.rect.topLeft, page);
          stroke.points.add(StrokePoint(p.dx, p.dy, pressure));
          stroke.invalidateCache();
          // Moving beyond the slop means the pen is still travelling — re-arm
          // the hold timer so it only fires on a genuine pause.
          final anchor = _holdAnchorLocal;
          if (_holdTimer != null && anchor != null) {
            if ((p - anchor).distance > _kHoldSlopScreen / zoom) {
              _holdAnchorLocal = p;
              _armHoldTimer();
            }
          }
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
      case CanvasTool.shape:
        final start = _shapeStartLocal;
        if (start == null) return;
        final l = layout.layoutOf(activeStrokePageId!);
        final page = pages[activeStrokePageId!];
        if (l == null || page == null) return;
        final p = _clampToPage(canvasPos - l.rect.topLeft, page);
        final shift = _shiftDown();
        final tmpl = shapeToolTemplate;
        if (tmpl != null) {
          previewStrokes = _templateStrokes(
            tmpl,
            Rect.fromPoints(start, p),
            uniform: shift,
          );
        } else {
          final stroke = activeStroke;
          if (stroke == null) return;
          stroke.points = pointsForShape(
            shapeToolFit(shapeToolKind, start, p, constrain: shift),
          );
          stroke.invalidateCache();
        }
        notifyListeners();
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
        _holdTimer?.cancel();
        _holdTimer = null;
        final stroke = activeStroke;
        if (stroke == null) return;
        final pageId = activeStrokePageId!;
        activeStroke = null;
        activeStrokePageId = null;
        final pre = _preSnapPoints;
        if (_snapped && pre != null && pre.length > 1) {
          _commitSnappedShape(pageId, stroke, pre);
        } else if (stroke.points.length > 1) {
          _doOp(_addElementsOp('Draw', pageId, [stroke]));
        } else {
          notifyListeners();
        }
        _snapped = false;
        _preSnapPoints = null;
        _snappedFit = null;
        _adjustAnchor = null;
        _adjustStart = null;
        _holdAnchorLocal = null;
      case CanvasTool.eraser:
        _commitErase();
      case CanvasTool.lasso:
        _finishLasso();
      case CanvasTool.shape:
        final stroke = activeStroke;
        final pageId = activeStrokePageId;
        final start = _shapeStartLocal;
        final preview = previewStrokes;
        final template = shapeToolTemplate;
        activeStroke = null;
        activeStrokePageId = null;
        _shapeStartLocal = null;
        previewStrokes = [];
        if (pageId == null || start == null) {
          notifyListeners();
          return;
        }
        if (template != null) {
          // A click with no drag stamps nothing.
          if (preview.isNotEmpty) {
            _doOp(_addElementsOp('Shape', pageId, preview));
          } else {
            notifyListeners();
          }
        } else if (stroke != null && stroke.points.length > 1) {
          _doOp(_addElementsOp('Shape', pageId, [stroke]));
        } else {
          notifyListeners();
        }
      case CanvasTool.text:
      case null:
        return;
    }
  }

  void cancelToolGesture() {
    _holdTimer?.cancel();
    _holdTimer = null;
    _snapped = false;
    _preSnapPoints = null;
    _snappedFit = null;
    _adjustAnchor = null;
    _adjustStart = null;
    _holdAnchorLocal = null;
    _shapeStartLocal = null;
    previewStrokes = [];
    _activeGestureTool = null;
    activeStroke = null;
    activeStrokePageId = null;
    lassoPoints = null;
    _gesturePageId = null;
    // Erase already applied live — commit what happened rather than losing it.
    // (_erasingPageIds guards the case where only own-segments changed, so the
    // painter's direct-draw bypass is always torn down.)
    if (_eraseAccum.isNotEmpty ||
        _segAccum.isNotEmpty ||
        _erasingPageIds.isNotEmpty) {
      _commitErase();
      return;
    }
    _dragMode = SelectionHit.none;
    isDraggingSelectionNotifier.value = false;
    notifyListeners();
  }

  // ── Hold-to-snap ─────────────────────────────────────────────────────────

  void _armHoldTimer() {
    _holdTimer?.cancel();
    _holdTimer = Timer(_kHoldDuration, _onHoldFired);
  }

  /// The pen paused mid-stroke: try to recognize the in-progress ink as a
  /// shape. On success the live stroke's points become the perfect shape (a
  /// preview); on failure re-arm once (a longer pause after more ink may yet
  /// resolve), then give up for this gesture. Fires between frames, so
  /// notifying is safe.
  void _onHoldFired() {
    _holdTimer = null;
    final t = _activeGestureTool;
    if ((t != CanvasTool.pen && t != CanvasTool.highlighter) || _snapped) {
      return;
    }
    final stroke = activeStroke;
    if (stroke == null) return;
    final fit = recognizeShape(stroke.points);
    if (fit == null) {
      if (_holdRetries < 1) {
        _holdRetries++;
        _armHoldTimer();
      }
      return;
    }
    _preSnapPoints = [
      for (final p in stroke.points) StrokePoint(p.x, p.y, p.p),
    ];
    _snappedFit = fit;
    _adjustAnchor = null;
    final lastPt = stroke.points.last;
    _adjustStart = Offset(lastPt.x, lastPt.y); // pen pos at snap (page-local)
    stroke.points = pointsForShape(fit);
    stroke.invalidateCache();
    _snapped = true;
    HapticFeedback.mediumImpact();
    notifyListeners();
  }

  /// While a shape is snapped and the pen is still down, dragging adjusts it:
  /// the nearest anchor follows the pen (line endpoint, rect/ellipse via the
  /// grabbed corner/axis, circle radius). The grab only begins once the pen has
  /// moved past a small slop from the snap position, so a shape doesn't jump on
  /// the tiniest jitter.
  void _adjustSnappedShape(Offset canvasPos) {
    final fit = _snappedFit;
    final stroke = activeStroke;
    if (fit == null || stroke == null) return;
    final l = layout.layoutOf(activeStrokePageId!);
    final page = pages[activeStrokePageId!];
    if (l == null || page == null) return;
    final p = _clampToPage(canvasPos - l.rect.topLeft, page);
    if (_adjustAnchor == null) {
      if (_adjustStart != null &&
          (p - _adjustStart!).distance < _kAdjustStartSlop) {
        return; // still within slop — leave the snapped shape untouched
      }
      _adjustAnchor = nearestAnchorIndex(fit, _adjustStart ?? p);
    }
    final newFit = moveAnchor(fit, _adjustAnchor!, p);
    _snappedFit = newFit;
    stroke.points = pointsForShape(newFit);
    stroke.invalidateCache();
    notifyListeners();
  }

  /// Commits a held-and-snapped stroke as **two ops**: op1 adds the original
  /// freehand stroke, op2 swaps its points to the recognized shape. So undo #1
  /// restores the freehand ink and undo #2 removes the stroke entirely (Apple
  /// Notes semantics). Both ops run in one synchronous frame, so the
  /// intermediate freehand state never paints and the debounced save only ever
  /// flushes the final shape. Sync-safe: op2 `_stamp`s (rev climbs across
  /// undo↔redo) and op1 tombstones on revert — see SHAPES_PLAN §1.4.
  void _commitSnappedShape(
    String pageId,
    StrokeElement stroke,
    List<StrokePoint> freehand,
  ) {
    final shapePoints = stroke.points;
    stroke.points = [for (final p in freehand) StrokePoint(p.x, p.y, p.p)];
    stroke.invalidateCache();
    _doOp(_addElementsOp('Draw', pageId, [stroke]));
    _doOp(
      _swapPointsOp(
        'Shape',
        pageId,
        stroke,
        before: freehand,
        after: shapePoints,
      ),
    );
  }

  /// Test seam: runs the two-op snapped-shape commit as the hold gesture would
  /// (the timer/gesture plumbing needs a screen+layout, which unit tests don't
  /// set up). [strokeWithShapePoints] must carry the generated shape points;
  /// [freehand] is the pre-snap ink.
  @visibleForTesting
  void debugCommitSnap(
    String pageId,
    StrokeElement strokeWithShapePoints,
    List<StrokePoint> freehand,
  ) => _commitSnappedShape(pageId, strokeWithShapePoints, freehand);

  /// Undoable op that swaps a stroke's points (freehand ↔ shape), stamping on
  /// both apply and revert so rev climbs monotonically (LWW-safe). Snapshots
  /// deep copies of both point lists — never live refs (the op-correctness
  /// rule).
  _CanvasOp _swapPointsOp(
    String label,
    String pageId,
    StrokeElement stroke, {
    required List<StrokePoint> before,
    required List<StrokePoint> after,
  }) {
    final beforeCopy = [for (final p in before) StrokePoint(p.x, p.y, p.p)];
    final afterCopy = [for (final p in after) StrokePoint(p.x, p.y, p.p)];
    void write(List<StrokePoint> pts) {
      final page = pages[pageId];
      if (page == null) return;
      final i = page.strokes.indexWhere((e) => e.id == stroke.id);
      if (i < 0) return;
      final el = page.strokes[i];
      el.points = [for (final p in pts) StrokePoint(p.x, p.y, p.p)];
      el.invalidateCache();
      _stamp([el]);
    }

    return _CanvasOp(
      label: label,
      dirtyPageIds: {pageId},
      apply: () => write(afterCopy),
      revert: () => write(beforeCopy),
    );
  }

  // ── Eraser (whole-stroke or partial, live) ─────────────────────────────

  void _eraseAt(Offset canvasPos) {
    final pageLayout = layout.pageAt(canvasPos);
    if (pageLayout == null) return;
    final page = pages[pageLayout.pageId]!;
    final local = canvasPos - pageLayout.rect.topLeft;

    var changed = false;
    for (var i = page.strokes.length - 1; i >= 0; i--) {
      final el = page.strokes[i];
      // Cheap bbox reject before the per-segment scan. `el.bounds` is padded by
      // the stroke's own width, so inflating by the eraser radius stays
      // conservative — anything `_strokeHit` could hit is inside this rect.
      if (!el.bounds.inflate(eraserSize + el.size / 2).contains(local)) {
        continue;
      }
      if (!_strokeHit(el, local)) continue;
      changed = true;

      // A segment WE created earlier in this gesture isn't persisted yet —
      // splitting it again just replaces it in the added set, no tombstone.
      final gestureSegs = _segAccum[page.id];
      final isOwnSegment = gestureSegs?.any((s) => s.id == el.id) ?? false;

      page.strokes.removeAt(i);
      if (isOwnSegment) {
        gestureSegs!.removeWhere((s) => s.id == el.id);
      } else {
        _eraseAccum.putIfAbsent(page.id, () => []).add((i, el));
      }

      if (eraserPartial) {
        final survivors = _splitStrokeAround(el, local);
        if (survivors.isNotEmpty) {
          page.strokes.insertAll(i, survivors);
          _segAccum.putIfAbsent(page.id, () => []).addAll(survivors);
        }
      }
    }
    if (changed) {
      // Don't re-record the whole page picture mid-gesture — mark the page as
      // erasing so the painter draws its (now-reduced) ink directly, and defer
      // a single re-record to _commitErase.
      _erasingPageIds.add(page.id);
      notifyListeners();
    }
  }

  /// Splits [stroke] into the point runs that survive an erase at [center]:
  /// points within the eraser radius are dropped (both endpoints of any
  /// segment the eraser crosses count as hit), and each surviving run of 2+
  /// points becomes a fresh stroke with the original's style and z. An empty
  /// result means nothing survives — the whole-stroke removal stands.
  List<StrokeElement> _splitStrokeAround(StrokeElement stroke, Offset center) {
    final pts = stroke.points;
    final radius = eraserSize + stroke.size / 2;
    final hit = List<bool>.filled(pts.length, false);
    for (var j = 0; j < pts.length; j++) {
      if ((Offset(pts[j].x, pts[j].y) - center).distance <= radius) {
        hit[j] = true;
      }
    }
    for (var j = 0; j < pts.length - 1; j++) {
      if (_distToSegment(
            center,
            Offset(pts[j].x, pts[j].y),
            Offset(pts[j + 1].x, pts[j + 1].y),
          ) <=
          radius) {
        hit[j] = true;
        hit[j + 1] = true;
      }
    }

    final out = <StrokeElement>[];
    var runStart = -1;
    void flush(int end) {
      if (runStart >= 0 && end - runStart >= 2) {
        out.add(
          StrokeElement(
            id: newModelId('el'),
            deviceId: SettingsService().deviceId,
            z: stroke.z,
            tool: stroke.tool,
            color: stroke.color,
            size: stroke.size,
            points: [
              for (var j = runStart; j < end; j++)
                StrokePoint(pts[j].x, pts[j].y, pts[j].p),
            ],
          )..zIndex = stroke.zIndex,
        );
      }
      runStart = -1;
    }

    for (var j = 0; j < pts.length; j++) {
      if (hit[j]) {
        flush(j);
      } else if (runStart < 0) {
        runStart = j;
      }
    }
    flush(pts.length);
    return out;
  }

  void _commitErase() {
    // End the painter's direct-draw bypass and refresh the picture from the
    // final ink. Invalidate here (not per erased stroke) so the whole-page
    // re-record happens once. The op below re-invalidates its dirty pages too;
    // a redundant invalidate is a no-op, but this also covers any erasing page
    // the op's dirty set might miss.
    final erasingPages = Set.of(_erasingPageIds);
    _erasingPageIds.clear();
    for (final id in erasingPages) {
      pictureCache.invalidate(id);
    }

    final accum = Map.of(_eraseAccum);
    final segs = Map.of(_segAccum);
    _eraseAccum.clear();
    _segAccum.clear();
    if (accum.isEmpty && segs.isEmpty) {
      if (erasingPages.isNotEmpty) notifyListeners();
      return;
    }

    // The live gesture (_eraseAt) already removed the erased strokes and added
    // the survivor segments; this op just makes it undoable and sync-safe.
    // Erase = tombstone the originals; partial-mode survivor segments are the
    // "added" side. Undo is the symmetric swap (tombstone segments, revive
    // originals). All rev-based via the shared helpers — reviving bumps the
    // original's rev above its tombstone (same id), which is what restores the
    // WHOLE line on the remote device after an undo-across-sync (the fresh-id
    // approach broke the undo chain; this doesn't).
    final pageIds = {...accum.keys, ...segs.keys};
    final originals = {
      for (final pid in pageIds)
        pid: [
          for (final (i, el) in (accum[pid] ?? const <(int, CanvasElement)>[]))
            _ElSlot(el, i),
        ],
    };
    final segments = {
      for (final pid in pageIds)
        pid: [
          for (final s in (segs[pid] ?? const <StrokeElement>[])) _ElSlot(s),
        ],
    };

    _doOp(
      _CanvasOp(
        label: 'Erase',
        dirtyPageIds: pageIds,
        apply: () {
          for (final pid in pageIds) {
            final page = pages[pid];
            if (page == null) continue;
            _tombstoneSlots(page, originals[pid]!);
            _reviveSlots(page, segments[pid]!);
          }
        },
        revert: () {
          for (final pid in pageIds) {
            final page = pages[pid];
            if (page == null) continue;
            _tombstoneSlots(page, segments[pid]!);
            _reviveSlots(page, originals[pid]!);
          }
        },
      ),
    );
  }

  bool _strokeHit(StrokeElement stroke, Offset point) {
    final radius = eraserSize + stroke.size / 2;
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
  List<CanvasElement> _selection = [];
  List<CanvasElement> get selection => _selection;
  set selection(List<CanvasElement> v) {
    _selection = v;
    hasSelectionNotifier.value = v.isNotEmpty;
  }

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
    isDraggingSelectionNotifier.value = false;
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
    // All selections (text included) get corner handles. For text the corner
    // drag changes the box's wrap WIDTH only — never the font size (see
    // _updateSelectionDrag).
    if (near(rect.topLeft)) return SelectionHit.resizeTL;
    if (near(rect.topRight)) return SelectionHit.resizeTR;
    if (near(rect.bottomLeft)) return SelectionHit.resizeBL;
    if (near(rect.bottomRight)) return SelectionHit.resizeBR;
    // Side handles (non-uniform stretch), only when the box is big enough on
    // that axis so they don't overlap the corners. Text has no vertical
    // handles (its height follows the wrapped content — a T/B drag is a no-op).
    const minForSide = 48.0;
    if (rect.width >= minForSide) {
      if (near(rect.centerLeft)) return SelectionHit.resizeL;
      if (near(rect.centerRight)) return SelectionHit.resizeR;
    }
    if (rect.height >= minForSide && !selectionIsTextOnly) {
      if (near(rect.topCenter)) return SelectionHit.resizeT;
      if (near(rect.bottomCenter)) return SelectionHit.resizeB;
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

  /// Tap-to-select in the lasso tool: selects the single topmost element under
  /// a screen point (stroke, image, text box, or attachment chip), or clears
  /// the selection if the tap missed everything. Returns the hit element.
  CanvasElement? selectAt(Offset screenPos) {
    final canvasPos = screenToCanvas(screenPos);
    final pageLayout = layout.pageAt(canvasPos);
    if (pageLayout == null) {
      clearSelection();
      return null;
    }
    final page = pages[pageLayout.pageId]!;
    final local = canvasPos - pageLayout.rect.topLeft;
    // Topmost first, so a tap grabs what's visually on top.
    for (final el in zOrderedElements(page).reversed) {
      if (_tapHitsElement(el, local)) {
        selectSingle(pageLayout.pageId, el);
        return el;
      }
    }
    clearSelection();
    return null;
  }

  bool _tapHitsElement(CanvasElement el, Offset local) => switch (el) {
    StrokeElement() => _strokeHit(el, local),
    TextElement(:final rect) => rect.inflate(6).contains(local),
    ImageElement(:final rect) => rect.contains(local),
    AttachmentElement(:final rect) => rect.inflate(4).contains(local),
  };

  void _beginSelectionDrag(SelectionHit hit, Offset canvasPos) {
    _dragMode = hit;
    isDraggingSelectionNotifier.value = true;
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
        // Text boxes resize by wrap WIDTH only (font size never changes); the
        // height follows the re-wrapped content. A left-side handle also moves
        // the left edge; a right-side handle keeps the left edge fixed.
        if (selectionIsTextOnly && selection.length == 1) {
          final el = selection.first as TextElement;
          final page = pages[selectionPageId!];
          if (page == null) break;
          final localPos = canvasPos - pageLayout.rect.topLeft;
          final leftSide =
              _dragMode == SelectionHit.resizeTL ||
              _dragMode == SelectionHit.resizeBL;
          const minW = 40.0;
          double newLeft = el.rect.left;
          double newWidth;
          if (leftSide) {
            final right = el.rect.right;
            newLeft = localPos.dx.clamp(0.0, right - minW);
            newWidth = right - newLeft;
          } else {
            newWidth = (localPos.dx - el.rect.left).clamp(
              minW,
              page.width - el.rect.left,
            );
          }
          el.manualWidth = newWidth;
          el.rect = Rect.fromLTWH(
            newLeft,
            el.rect.top,
            newWidth,
            el.rect.height,
          );
          el.rect = autoTextRect(el, page.width - newLeft - 6);
          _dragLast = canvasPos;
          _recomputeSelectionBounds();
          pictureCache.invalidate(selectionPageId!);
          notifyListeners();
          return;
        }
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
      case SelectionHit.resizeL:
      case SelectionHit.resizeR:
      case SelectionHit.resizeT:
      case SelectionHit.resizeB:
        final horizontal =
            _dragMode == SelectionHit.resizeL ||
            _dragMode == SelectionHit.resizeR;
        // Text: a horizontal side handle changes the wrap width (same as a
        // corner); a vertical one does nothing (height follows the content).
        if (selectionIsTextOnly && selection.length == 1) {
          if (!horizontal) return;
          final el = selection.first as TextElement;
          final page = pages[selectionPageId!];
          if (page == null) break;
          final localPos = canvasPos - pageLayout.rect.topLeft;
          final leftSide = _dragMode == SelectionHit.resizeL;
          const minW = 40.0;
          double newLeft = el.rect.left;
          double newWidth;
          if (leftSide) {
            final right = el.rect.right;
            newLeft = localPos.dx.clamp(0.0, right - minW);
            newWidth = right - newLeft;
          } else {
            newWidth = (localPos.dx - el.rect.left).clamp(
              minW,
              page.width - el.rect.left,
            );
          }
          el.manualWidth = newWidth;
          el.rect = Rect.fromLTWH(
            newLeft,
            el.rect.top,
            newWidth,
            el.rect.height,
          );
          el.rect = autoTextRect(el, page.width - newLeft - 6);
          _dragLast = canvasPos;
          _recomputeSelectionBounds();
          pictureCache.invalidate(selectionPageId!);
          notifyListeners();
          return;
        }
        final localPos = canvasPos - pageLayout.rect.topLeft;
        final localLast = _dragLast - pageLayout.rect.topLeft;
        var sx = 1.0, sy = 1.0;
        late Offset anchor;
        switch (_dragMode) {
          case SelectionHit.resizeR:
            final a = bounds.left;
            final now = localPos.dx - a, last = localLast.dx - a;
            if (last.abs() > 1e-3) sx = now / last;
            anchor = Offset(a, bounds.top);
          case SelectionHit.resizeL:
            final a = bounds.right;
            final now = a - localPos.dx, last = a - localLast.dx;
            if (last.abs() > 1e-3) sx = now / last;
            anchor = Offset(a, bounds.top);
          case SelectionHit.resizeB:
            final a = bounds.top;
            final now = localPos.dy - a, last = localLast.dy - a;
            if (last.abs() > 1e-3) sy = now / last;
            anchor = Offset(bounds.left, a);
          default: // resizeT
            final a = bounds.bottom;
            final now = a - localPos.dy, last = a - localLast.dy;
            if (last.abs() > 1e-3) sy = now / last;
            anchor = Offset(bounds.left, a);
        }
        // Don't collapse (or flip) the axis being stretched.
        final axisSize = horizontal ? bounds.width : bounds.height;
        final axisFactor = horizontal ? sx : sy;
        if (axisSize * axisFactor > 8 || axisFactor > 1) {
          for (final el in selection) {
            el.scaleXY(sx, sy, anchor);
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
    pictureCache.invalidate(selectionPageId!);
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
    isDraggingSelectionNotifier.value = false;
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
      for (final e in sourceElements) (beforeById[e.id] ?? e).deepCopy(),
    ];
    final targetBefore = [for (final e in targetElements) e.deepCopy()];

    // After: moving elements leave the source, land on the target shifted.
    final sourceAfter = [
      for (final e in sourceElements)
        if (!movedIds.contains(e.id)) e.deepCopy(),
    ];
    final movingAfter = [
      for (final e in sourceElements)
        if (movedIds.contains(e.id))
          e.deepCopy()..translate(shift.dx, shift.dy),
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
        // A move is delete-on-source + add-on-target (same ids), symmetric on
        // undo. Rev-based, so nothing is un-tombstoned: the landed copy is
        // bumped ABOVE any tombstone on its page (this is what lets a
        // move-BACK out-rev the stale origin tombstone — the reported bug),
        // and the side it left tombstones the ids at the landed rev.
        apply: () {
          _setPageElements(sourceId, sourceAfter);
          _setPageElements(targetId, targetAfter);
          // Source: the ids left → tombstone them (a stale remote source copy
          // must not resurrect them). Landed rev is recorded so a future
          // return out-revs it.
          for (final el in movingAfter) {
            _tombstoneFor(source, el);
          }
          // Target: the landed copies must out-rev any pre-existing tombstone
          // for their id on this page (e.g. from an earlier move here).
          for (final el in [...target.strokes, ...target.objects]) {
            if (movedIds.contains(el.id)) _bumpAliveOn(target, el);
          }
        },
        revert: () {
          // Target: tombstone the moved ids at their CURRENT (pushed) rev —
          // captured from the live target copies BEFORE they're removed, so a
          // remote that already pulled the move drops them too.
          for (final el in [...target.strokes, ...target.objects]) {
            if (movedIds.contains(el.id)) _tombstoneFor(target, el);
          }
          _setPageElements(sourceId, sourceBefore);
          _setPageElements(targetId, targetBefore);
          // Source: the restored copies must out-rev the source tombstone that
          // apply added (kept — grow-only).
          for (final el in [...source.strokes, ...source.objects]) {
            if (movedIds.contains(el.id)) _bumpAliveOn(source, el);
          }
        },
      ),
    );

    // Reselect the moved elements on the target page.
    selectionPageId = targetId;
    selection = [
      ...target.strokes,
      ...target.objects,
    ].where((e) => movedIds.contains(e.id)).toList();
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
      if (copy is StrokeElement)
        page.strokes.add(copy);
      else
        page.objects.add(copy);
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
      selection = [
        ...page.strokes,
        ...page.objects,
      ].where((e) => ids.contains(e.id)).toList();
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
    final slots = <_ElSlot>[];
    for (final el in selection) {
      if (el is StrokeElement) {
        final i = page.strokes.indexOf(el);
        if (i >= 0) slots.add(_ElSlot(el, i));
      } else {
        final i = page.objects.indexOf(el);
        if (i >= 0) slots.add(_ElSlot(el, i));
      }
    }
    clearSelection(notify: false);
    _doOp(
      _CanvasOp(
        label: 'Delete',
        dirtyPageIds: {pageId},
        // Delete = tombstone; undo = revive (fresh id if the tombstone
        // already synced — see [_reviveSlots]).
        apply: () => _tombstoneSlots(page, slots),
        revert: () => _reviveSlots(page, slots),
      ),
    );
  }

  void copySelection() {
    _appClipboard = [for (final el in selection) el.deepCopy()];
    clipboardNotifier.value = clipboardHasContent;
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
      for (final el in selection)
        el.deepCopy(withNewId: true)..translate(16, 16),
    ];
    _doOp(_addElementsOp('Duplicate', pageId, copies));
    final page = pages[pageId]!;
    selection = [
      ...page.strokes,
      ...page.objects,
    ].where((e) => copies.any((c) => c.id == e.id)).toList();
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

    // A single text element taller than the page (e.g. a cut linked text)
    // re-flows through the split pipeline instead of pasting clipped.
    if (_appClipboard.length == 1 && _appClipboard.single is TextElement) {
      final t = _appClipboard.single as TextElement;
      final maxW = page.width * 0.85;
      final measured = autoTextRect(t, maxW); // pure measure, no mutation
      if (measured.height > page.height - 48) {
        insertRunsAsText(target.pageId, [for (final r in t.runs) r.clone()]);
        return;
      }
    }

    final copies = [
      for (final el in _appClipboard) el.deepCopy(withNewId: true),
    ];
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
    selection = [
      ...page.strokes,
      ...page.objects,
    ].where((e) => copies.any((c) => c.id == e.id)).toList();
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
    final selectedObjects = selection
        .where((e) => e is! StrokeElement)
        .toList();

    final restStrokes = page.strokes
        .where((e) => !selectedStrokes.contains(e))
        .toList();
    final restObjects = page.objects
        .where((e) => !selectedObjects.contains(e))
        .toList();

    final afterStrokes = front
        ? [...restStrokes, ...selectedStrokes]
        : [...selectedStrokes, ...restStrokes];
    final afterObjects = front
        ? [...restObjects, ...selectedObjects]
        : [...selectedObjects, ...restObjects];

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
          page.strokes
            ..clear()
            ..addAll(afterStrokes);
          page.objects
            ..clear()
            ..addAll(afterObjects);
          for (final el in selected) {
            el.zIndex = newZ;
          }
        },
        revert: () {
          page.strokes
            ..clear()
            ..addAll(beforeStrokes);
          page.objects
            ..clear()
            ..addAll(beforeObjects);
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

  /// Reflects ink lightness (keep hue) so it stays visible after a page
  /// background crosses light↔dark. Applies to the enabled types — [pen]
  /// strokes, [highlighter] strokes, [text] (box + each run) — across
  /// [pageIds]. One undoable op that `_stamp`s every mutated element, so it
  /// syncs like any recolor. Mirrors [applyColorToSelection]'s do/redo/undo
  /// shape (mutate-in-place + guarded replace), extended to many pages.
  void adjustInkForContrast(
    Set<String> pageIds, {
    bool pen = false,
    bool highlighter = false,
    bool text = false,
  }) {
    if (!pen && !highlighter && !text) return;

    final targetsByPage = <String, List<CanvasElement>>{};
    final before = <String, List<CanvasElement>>{};
    for (final pid in pageIds) {
      final page = pages[pid];
      if (page == null) continue;
      final targets = <CanvasElement>[];
      for (final s in page.strokes) {
        final isHl = s.tool == StrokeTool.highlighter;
        if ((isHl && highlighter) || (!isHl && pen)) targets.add(s);
      }
      if (text) {
        for (final o in page.objects) {
          if (o is TextElement) targets.add(o);
        }
      }
      if (targets.isEmpty) continue;
      targetsByPage[pid] = targets;
      before[pid] = [for (final el in targets) el.deepCopy()];
    }
    if (targetsByPage.isEmpty) return;

    final touched = <CanvasElement>[];
    targetsByPage.forEach((pid, targets) {
      for (final el in targets) {
        switch (el) {
          case StrokeElement():
            el.color = reflectLightnessForContrast(el.color);
            el.invalidateCache();
          case TextElement():
            el.color = reflectLightnessForContrast(el.color);
            for (final r in el.runs) {
              r.color = reflectLightnessForContrast(r.color);
            }
          default:
            break;
        }
        touched.add(el);
      }
    });
    _stamp(touched);

    final after = <String, List<CanvasElement>>{
      for (final pid in targetsByPage.keys)
        pid: [for (final el in targetsByPage[pid]!) el.deepCopy()],
    };
    final dirty = targetsByPage.keys.toSet();
    var applied = true;
    _doOp(
      _CanvasOp(
        label: 'Adjust ink for contrast',
        dirtyPageIds: dirty,
        apply: () {
          if (applied) {
            applied = false;
            return;
          }
          for (final pid in after.keys) {
            _replaceElements(pid, after[pid]!);
          }
        },
        revert: () {
          for (final pid in before.keys) {
            _replaceElements(pid, before[pid]!);
          }
        },
      ),
    );
  }

  // ── Element insertion (text / image / generic) ─────────────────────────

  /// Inserts [elements] (apply = do/redo, revert = undo the insert).
  ///
  /// Once an element could have synced, undoing its insert must still record
  /// a tombstone alongside the physical removal — a stale remote copy would
  /// otherwise resurrect it on the next merge. `apply` (redo) clears the
  // ── Tombstone-safe undo/redo primitives (rev-based LWW deletion) ────────
  //
  // Deletion is rev-based, like the Recycle bin: a tombstone records the
  // element's `rev` at delete time, and the merge filter keeps an element dead
  // only while `element.rev <= tombstone.rev`. So undo/redo NEVER removes a
  // tombstone (grow-only, durable across sync — a device that pulled it would
  // otherwise re-delete on merge). Instead:
  //   - tombstone = record the element's current rev (redo, on a bumped
  //     element, produces a higher tombstone → dead again);
  //   - revive = keep the SAME id, bump the element's rev above its tombstone
  //     (alive again, survives sync, undo stack stays intact — no id swap).
  // rev climbs monotonically across undo↔redo, so each action out-revs the
  // last. Verified against the partial-eraser undo-across-sync round trip.

  void _tombstoneFor(CanvasPage page, CanvasElement el) {
    final list = el is StrokeElement ? page.erased : page.deletedObjects;
    // Dedup: raise (never lower) the tombstone's rev to the element's current
    // rev. Local remove-then-add is safe — the merge takes the higher rev.
    list.removeWhere((e) => e.strokeId == el.id);
    list.add(
      EraseTombstone(
        strokeId: el.id,
        rev: el.rev,
        erasedAt: DateTime.now(),
        deviceId: SettingsService().deviceId,
      ),
    );
  }

  /// Bumps [el]'s rev above the highest tombstone for its id on [page], so the
  /// merge filter keeps it ALIVE. The tombstone itself stays (grow-only).
  void _bumpAliveOn(CanvasPage page, CanvasElement el) {
    final list = el is StrokeElement ? page.erased : page.deletedObjects;
    final tomb = list
        .where((e) => e.strokeId == el.id)
        .fold<int?>(null, (m, e) => m == null || e.rev > m ? e.rev : m);
    if (tomb == null) return;
    final dev = SettingsService().deviceId;
    while (el.rev <= tomb) {
      el.bumpRev(dev);
    }
  }

  void _tombstoneSlots(CanvasPage page, List<_ElSlot> slots) {
    for (final s in slots) {
      _tombstoneFor(page, s.el);
    }
    final ids = slots.map((s) => s.el.id).toSet();
    page.strokes.removeWhere((e) => ids.contains(e.id));
    page.objects.removeWhere((e) => ids.contains(e.id));
  }

  void _reviveSlots(CanvasPage page, List<_ElSlot> slots) {
    final ordered = [...slots]..sort((a, b) => a.index.compareTo(b.index));
    for (final s in ordered) {
      final el = s.el;
      _bumpAliveOn(page, el);
      if (el is StrokeElement) {
        if (!page.strokes.any((e) => e.id == el.id)) {
          s.index < 0
              ? page.strokes.add(el)
              : page.strokes.insert(math.min(s.index, page.strokes.length), el);
        }
      } else {
        if (!page.objects.any((e) => e.id == el.id)) {
          s.index < 0
              ? page.objects.add(el)
              : page.objects.insert(math.min(s.index, page.objects.length), el);
        }
      }
    }
  }

  _CanvasOp _addElementsOp(
    String label,
    String pageId,
    List<CanvasElement> elements,
  ) {
    final page = pages[pageId]!;
    final slots = [for (final el in elements) _ElSlot(el)];
    return _CanvasOp(
      label: label,
      dirtyPageIds: {pageId},
      apply: () => _reviveSlots(page, slots),
      revert: () => _tombstoneSlots(page, slots),
    );
  }

  void addElement(String pageId, CanvasElement element) {
    _doOp(_addElementsOp('Insert', pageId, [element]));
  }

  /// Splices an internal link run into a committed text box at [caret] —
  /// the `[[` trigger's landing. Replaces the `[[` marker (the two chars
  /// before [caret]) with [title] linked to [uri] plus a trailing plain
  /// space, styled like the character before the marker. One undoable op.
  void insertLinkIntoText(
    String pageId,
    String elementId,
    int caret,
    String title,
    String uri,
  ) {
    final page = pages[pageId];
    if (page == null || caret < 2) return;
    TextElement? el;
    for (final o in page.objects) {
      if (o.id == elementId && o is TextElement) {
        el = o;
        break;
      }
    }
    if (el == null || caret > el.text.length) return;
    if (el.text.substring(caret - 2, caret) != '[[') return;
    // Style the link like its surroundings: the run containing the marker.
    TextRun styleSource = el.runs.isEmpty
        ? TextRun(
            text: '',
            fontSize: el.fontSize,
            bold: el.bold,
            italic: el.italic,
            color: el.color,
            fontFamily: el.fontFamily,
          )
        : el.runs.first;
    var pos = 0;
    for (final r in el.runs) {
      if (caret - 2 < pos + r.text.length) {
        styleSource = r;
        break;
      }
      pos += r.text.length;
    }
    final before = <CanvasElement>[el.deepCopy()];
    el.runs = replaceRunRange(el.runs, caret - 2, caret, [
      styleSource.clone()
        ..text = title
        ..link = uri,
      styleSource.clone()
        ..text = ' '
        ..link = null,
    ]);
    el.rect = autoTextRect(el, page.width - el.rect.left - 6);
    _stamp([el]);
    final after = <CanvasElement>[el.deepCopy()];
    var applied = true;
    _doOp(
      _CanvasOp(
        label: 'Insert link',
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

  /// Edits one link run of a text box (the ✎ affordance): new display text
  /// and/or destination; a null [newLink] removes the link (the text stays).
  /// One undoable, `_stamp`ed op; the box re-auto-sizes to the new text.
  void editLinkRun(
    String pageId,
    String elementId,
    int runIndex, {
    required String newText,
    required String? newLink,
  }) {
    final page = pages[pageId];
    if (page == null) return;
    TextElement? el;
    for (final o in page.objects) {
      if (o.id == elementId && o is TextElement) {
        el = o;
        break;
      }
    }
    if (el == null || runIndex < 0 || runIndex >= el.runs.length) return;
    final before = <CanvasElement>[el.deepCopy()];
    final run = el.runs[runIndex];
    run.text = newText.isEmpty ? run.text : newText;
    run.link = newLink;
    el.rect = autoTextRect(el, page.width - el.rect.left - 6);
    _stamp([el]);
    final after = <CanvasElement>[el.deepCopy()];
    var applied = true;
    _doOp(
      _CanvasOp(
        label: 'Edit link',
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

  /// Pastes an internal Connections link as a small tappable "link item": one
  /// auto-sized text box whose single run carries [uri] as its link, showing
  /// [title]. A trailing non-link space keeps the box grabbable/editable
  /// (same affordance linkifyRuns adds to all-link boxes). Returns the
  /// created element so the caller can register the connection.
  ///
  /// [nearBounds] (page-local) anchors the box just under that rect instead
  /// of the page centre — the visible marker a linked lasso selection gets,
  /// so the link is *seen* next to the ink it belongs to (and, being an
  /// ordinary text element, can be moved out of the way).
  TextElement? insertLinkItem(String pageId, String uri, String title,
      {Rect? nearBounds}) {
    final page = pages[pageId];
    if (page == null) return null;
    TextRun run(String text, {String? link}) => TextRun(
          text: text,
          fontSize: textFontSize,
          bold: false,
          italic: false,
          color: textColor,
          fontFamily: textFontFamily,
          link: link,
        );
    final el = TextElement(
      id: newModelId('el'),
      deviceId: SettingsService().deviceId,
      rect: const Rect.fromLTWH(0, 0, 10, 10),
      runs: [run(title, link: uri), run(' ')],
      fontFamily: textFontFamily,
      fontSize: textFontSize,
      color: textColor,
    );
    el.rect = autoTextRect(el, page.width * 0.85);
    final Offset shift;
    if (nearBounds != null) {
      shift = Offset(nearBounds.left, nearBounds.bottom + 4) - el.rect.topLeft;
    } else {
      shift = Offset(page.width / 2, page.height / 2) - el.rect.center;
    }
    el.translate(shift.dx, shift.dy);
    if (el.rect.top < 16) el.translate(0, 16 - el.rect.top);
    // Clamp onto the page (a marker under a selection near the bottom/right
    // edge must stay visible).
    if (el.rect.bottom > page.height) {
      el.translate(0, page.height - el.rect.bottom);
    }
    if (el.rect.right > page.width) el.translate(page.width - el.rect.right, 0);
    if (el.rect.left < 0) el.translate(-el.rect.left, 0);
    _doOp(_addElementsOp('Paste link', pageId, [el]));
    return el;
  }

  /// Pastes [runs] as text starting on [pageId]. Fits on the page → one
  /// auto-sized box centered there (the classic paste). Taller than the page
  /// → split at line boundaries into **linked** continuation boxes
  /// ([TextElement.linkId]), each on its own **new** page — appended to the
  /// right within the same row when the target row already flows
  /// horizontally, else as new rows directly below — all one undoable op.
  /// Returns the number of boxes created.
  int insertRunsAsText(String pageId, List<TextRun> runsIn) {
    final page = pages[pageId];
    if (page == null || runsIn.isEmpty) return 0;
    // Auto-link URLs in pasted/inserted text.
    final runs = linkifyRuns(runsIn);
    const margin = 24.0;
    final maxW = page.width * 0.85;
    final left = (page.width - maxW) / 2;

    TextElement build(List<TextRun> chunk, {String? linkId}) {
      final el = TextElement(
        id: newModelId('el'),
        deviceId: SettingsService().deviceId,
        rect: Rect.fromLTWH(left, margin, 10, 10),
        runs: [for (final r in chunk) r.clone()],
        linkId: linkId,
        fontFamily: textFontFamily,
        fontSize: textFontSize,
        color: textColor,
      );
      el.rect = autoTextRect(el, maxW);
      return el;
    }

    final chunks = splitRunsByHeight(runs, maxW, page.height - margin * 2);
    if (chunks.length == 1) {
      final el = build(chunks.single);
      final shift = Offset(page.width / 2, page.height / 2) - el.rect.center;
      el.translate(shift.dx, shift.dy);
      if (el.rect.top < 16) el.translate(0, 16 - el.rect.top);
      _doOp(_addElementsOp('Paste text', pageId, [el]));
      return 1;
    }

    // Multi-page: continuation pages sized like the target, direction from
    // the target row's shape.
    final linkId = newModelId('lnk');
    final parts = [for (final c in chunks) build(c, linkId: linkId)];

    final rowIndex = canvas.rows.indexWhere((r) => r.pageIds.contains(pageId));
    if (rowIndex < 0) return 0;
    final row = canvas.rows[rowIndex];
    final horizontal = row.pageIds.length > 1;

    final newPages = <CanvasPage>[];
    for (var i = 1; i < parts.length; i++) {
      newPages.add(
        CanvasPage(
          id: newModelId('pg'),
          deviceId: SettingsService().deviceId,
          width: page.width,
          height: page.height,
          background: canvas.defaultBackground,
        ),
      );
    }
    final newRows = horizontal
        ? const <PageRow>[]
        : [
            for (final p in newPages)
              PageRow(id: _service.newId(), pageIds: [p.id]),
          ];
    final targetPageIds = [pageId, ...newPages.map((p) => p.id)];

    _doOp(
      _CanvasOp(
        label: 'Paste text across pages',
        structural: true,
        dirtyPageIds: targetPageIds.toSet(),
        apply: () {
          for (final p in newPages) {
            pages[p.id] = p;
          }
          if (horizontal) {
            final at = row.pageIds.indexOf(pageId) + 1;
            for (var i = 0; i < newPages.length; i++) {
              if (!row.pageIds.contains(newPages[i].id)) {
                row.pageIds.insert(at + i, newPages[i].id);
              }
            }
          } else {
            if (!canvas.rows.any((r) => identical(r, newRows.firstOrNull))) {
              canvas.rows.insertAll(
                math.min(rowIndex + 1, canvas.rows.length),
                newRows,
              );
            }
          }
          for (var i = 0; i < parts.length; i++) {
            final target = pages[targetPageIds[i]]!;
            _bumpAliveOn(target, parts[i]); // out-rev any tombstone (redo)
            if (!target.objects.any((e) => e.id == parts[i].id)) {
              target.objects.add(parts[i]);
            }
          }
        },
        revert: () {
          for (var i = 0; i < parts.length; i++) {
            final target = pages[targetPageIds[i]];
            if (target == null) continue;
            _tombstoneFor(target, parts[i]); // rev-based; keeps the tombstone
            target.objects.removeWhere((e) => e.id == parts[i].id);
          }
          if (horizontal) {
            row.pageIds.removeWhere((id) => newPages.any((p) => p.id == id));
          } else {
            canvas.rows.removeWhere((r) => newRows.contains(r));
          }
          for (final p in newPages) {
            pages.remove(p.id);
          }
        },
      ),
    );
    return parts.length;
  }

  /// Places typing-overflow text on the page after [pageId] — the live-typing
  /// counterpart of the paste-time splitter (spec: overflow flows forward,
  /// never rebalances back). Marks [source] as linked (assigning a linkId if
  /// needed) and, in order of preference:
  /// 1. **prepends** to an existing linked continuation on the next page
  ///    (repeat overflow while editing the same box),
  /// 2. drops a new linked box onto the next page **if it's empty** (blank,
  ///    no ink/objects, not PDF-backed),
  /// 3. else **inserts a fresh page** right after the current one (in-row for
  ///    horizontal rows, else a new row below) and puts the box there.
  /// One undoable op; returns `(pageId, element)` of the continuation, or
  /// null when the page's row can't be found.
  (String, TextElement)? insertTypingContinuation(
    String pageId,
    TextElement source,
    List<TextRun> overflowRuns,
  ) {
    final built = _buildContinuation(pageId, source, overflowRuns);
    if (built == null) return null;
    _doOp(built.op);
    return (built.pageId, built.el);
  }

  /// [insertTypingContinuation]'s body, returning its op instead of running it
  /// so a caller can fold the continuation into a LARGER op — image-at-caret
  /// paste has to place the image, truncate the box and flow the leftover text
  /// as ONE undo. Building already mutates (branch 1 edits the existing
  /// continuation in place and no-ops its first apply, exactly as before), so
  /// the returned op MUST be handed to [_doOp] exactly once.
  ({_CanvasOp op, String pageId, TextElement el})? _buildContinuation(
    String pageId,
    TextElement source,
    List<TextRun> overflowRuns,
  ) {
    final page = pages[pageId];
    if (page == null || overflowRuns.isEmpty) return null;
    final rowIndex = canvas.rows.indexWhere((r) => r.pageIds.contains(pageId));
    if (rowIndex < 0) return null;
    final row = canvas.rows[rowIndex];
    final horizontal = row.pageIds.length > 1;

    source.linkId ??= newModelId('lnk');
    final linkId = source.linkId!;

    String? nextId;
    if (horizontal) {
      final at = row.pageIds.indexOf(pageId);
      if (at + 1 < row.pageIds.length) nextId = row.pageIds[at + 1];
    } else if (rowIndex + 1 < canvas.rows.length) {
      final ids = canvas.rows[rowIndex + 1].pageIds;
      if (ids.isNotEmpty) nextId = ids.first;
    }
    final next = nextId == null ? null : pages[nextId];

    // 1. A linked continuation already lives on the next page: prepend.
    if (next != null && nextId != null) {
      final nid = nextId;
      final existing = next.objects
          .whereType<TextElement>()
          .cast<TextElement?>()
          .firstWhere((e) => e!.linkId == linkId, orElse: () => null);
      if (existing != null) {
        final before = existing.deepCopy();
        existing.runs = [
          for (final r in overflowRuns) r.clone(),
          ...existing.runs,
        ];
        _remeasureText(existing, nid);
        _stamp([existing]);
        final after = existing.deepCopy();
        var applied = true;
        return (
          op: _CanvasOp(
            label: 'Continue text',
            dirtyPageIds: {nid},
            apply: () {
              if (applied) {
                applied = false;
                return;
              }
              _replaceElements(nid, [after]);
            },
            revert: () => _replaceElements(nid, [before]),
          ),
          pageId: nid,
          el: existing,
        );
      }
    }

    TextElement buildBox(CanvasPage host) {
      final el = TextElement(
        id: newModelId('el'),
        deviceId: SettingsService().deviceId,
        rect: Rect.fromLTWH(source.rect.left, 24, 10, 10),
        runs: [for (final r in overflowRuns) r.clone()],
        linkId: linkId,
        fontFamily: textFontFamily,
        fontSize: textFontSize,
        color: textColor,
      );
      el.rect = autoTextRect(el, host.width - el.rect.left - 6);
      return el;
    }

    // 2. Next page exists and is empty: use it, no structural change.
    if (next != null &&
        nextId != null &&
        next.deletedAt == null &&
        next.source == null &&
        next.strokes.isEmpty &&
        next.objects.isEmpty) {
      final el = buildBox(next);
      return (
        op: _addElementsOp('Continue text', nextId, [el]),
        pageId: nextId,
        el: el,
      );
    }

    // 3. Insert a fresh page right after this one.
    final newPage = CanvasPage(
      id: newModelId('pg'),
      deviceId: SettingsService().deviceId,
      width: page.width,
      height: page.height,
      background: canvas.defaultBackground,
    );
    final el = buildBox(newPage);
    final newRow = horizontal
        ? null
        : PageRow(id: _service.newId(), pageIds: [newPage.id]);
    return (
      op: _CanvasOp(
        label: 'Continue text on new page',
        structural: true,
        dirtyPageIds: {pageId, newPage.id},
        apply: () {
          pages[newPage.id] = newPage;
          if (horizontal) {
            if (!row.pageIds.contains(newPage.id)) {
              row.pageIds.insert(row.pageIds.indexOf(pageId) + 1, newPage.id);
            }
          } else if (newRow != null &&
              !canvas.rows.any((r) => identical(r, newRow))) {
            canvas.rows.insert(
              math.min(rowIndex + 1, canvas.rows.length),
              newRow,
            );
          }
          newPage.deletedObjects.removeWhere((t) => t.strokeId == el.id);
          _bumpAliveOn(newPage, el); // out-rev any tombstone (redo)
          if (!newPage.objects.any((e) => e.id == el.id)) {
            newPage.objects.add(el);
          }
        },
        revert: () {
          _tombstoneFor(newPage, el); // rev-based; keeps the tombstone
          newPage.objects.removeWhere((e) => e.id == el.id);
          if (horizontal) {
            row.pageIds.remove(newPage.id);
          } else if (newRow != null) {
            canvas.rows.remove(newRow);
          }
          pages.remove(newPage.id);
        },
      ),
      pageId: newPage.id,
      el: el,
    );
  }

  /// True when the lasso selection holds a text box that is part of a split
  /// pasted text (has a [TextElement.linkId]) — enables the linked actions.
  bool get selectionHasLinkedText =>
      selection.any((e) => e is TextElement && e.linkId != null);

  /// All parts of the linked texts in the current selection, in document
  /// (row → page → object) order, with the page each lives on.
  List<(String pageId, TextElement el)> _linkedParts() {
    final ids = {
      for (final e in selection)
        if (e is TextElement && e.linkId != null) e.linkId!,
    };
    if (ids.isEmpty) return const [];
    final out = <(String, TextElement)>[];
    for (final row in canvas.rows) {
      for (final pid in row.pageIds) {
        final p = pages[pid];
        if (p == null) continue;
        for (final el in p.objects) {
          if (el is TextElement && ids.contains(el.linkId)) out.add((pid, el));
        }
      }
    }
    return out;
  }

  /// Deletes every part of the selected linked text (all pages), one op.
  /// The continuation pages themselves stay — they may hold other content.
  void deleteLinkedText() {
    final parts = _linkedParts();
    if (parts.isEmpty) return;
    clearSelection(notify: false);
    // Rev-based (like every delete): tombstone each part at its rev; undo
    // revives the same ids with a bumped rev (never un-tombstones), so the
    // parts survive an undo-across-sync just like the eraser does.
    final slotsByPage = <String, List<_ElSlot>>{};
    for (final (pid, el) in parts) {
      slotsByPage.putIfAbsent(pid, () => []).add(_ElSlot(el));
    }
    _doOp(
      _CanvasOp(
        label: 'Delete linked text',
        dirtyPageIds: slotsByPage.keys.toSet(),
        apply: () {
          slotsByPage.forEach((pid, slots) {
            final page = pages[pid];
            if (page != null) _tombstoneSlots(page, slots);
          });
        },
        revert: () {
          slotsByPage.forEach((pid, slots) {
            final page = pages[pid];
            if (page != null) _reviveSlots(page, slots);
          });
        },
      ),
    );
  }

  /// Cuts the whole linked text: merges every part back into ONE text
  /// element on the internal clipboard (concatenation restores the original
  /// text exactly), then deletes the parts. Pasting it re-flows across pages
  /// at the destination — this is how a split paste is *moved*.
  void cutLinkedText() {
    final parts = _linkedParts();
    if (parts.isEmpty) return;
    final first = parts.first.$2;
    final merged = TextElement(
      id: newModelId('el'),
      deviceId: SettingsService().deviceId,
      rect: first.rect,
      runs: [
        for (final (_, el) in parts)
          for (final r in el.runs) r.clone(),
      ],
      fontFamily: first.fontFamily,
      fontSize: first.fontSize,
      color: first.color,
      align: first.align,
    );
    _appClipboard = [merged];
    clipboardNotifier.value = clipboardHasContent;
    deleteLinkedText();
    notifyListeners();
  }

  /// Inserts an image *beneath the ink layer*: ink drawn on the page (now or
  /// later) stays on top, while the image still sits above the page
  /// background/pattern. Newly added images stack above older ones but all
  /// stay below strokes. (Contrast [addElement], which — via the
  /// strokes-under-objects z tie-break — would drop the image on top of ink.)
  void addImageBelowInk(String pageId, ImageElement image) {
    final page = pages[pageId]!;
    image.zIndex = _belowInkZ(page);
    _doOp(_addElementsOp('Insert image', pageId, [image]));
  }

  /// The z that puts an image *beneath the ink layer*. Anchors to the lowest
  /// stroke z (default 0) so a freshly drawn stroke at z=0 renders above the
  /// image; images tie among themselves and fall back to insertion order
  /// (newest on top).
  double _belowInkZ(CanvasPage page) {
    var minStrokeZ = 0.0;
    for (final s in page.strokes) {
      if (s.zIndex < minStrokeZ) minStrokeZ = s.zIndex;
    }
    return minStrokeZ - 1;
  }

  /// Pastes [image] into the text box [source] at [caretOffset] as a BLOCK,
  /// Word-style: the image never sits inline in a line of text. It lands on the
  /// line AFTER the caret, left-aligned to the box, and the text that followed
  /// the caret continues in a new box below it.
  ///
  /// Three shapes, all one undoable op:
  /// * caret at the END → nothing moves; the image lands under the box.
  /// * caret at the START → the image takes the box's top-left and the whole
  ///   box slides below it (no second box — the source *is* the after-text).
  /// * caret in the MIDDLE → the box is truncated to the text before the caret
  ///   and the remainder becomes a new box under the image.
  ///
  /// [caretOffset] indexes the runs' concatenated text, so the caller must pass
  /// an offset from a *committed* box (the live editor's controller is the
  /// source of truth until then). Returns the placed image, or null when
  /// [source] isn't live on [pageId].
  ///
  /// The new box is deliberately NOT given [source]'s linkId: the linked-text
  /// chain is page-ordered (`insertTypingContinuation` looks for the next
  /// part on the NEXT page), so a same-page part would make the chain's order
  /// ambiguous. Known limit: splitting a box that is already part of a flowed
  /// text leaves the after-text outside that chain.
  /// Splits [runs] into the part that fits within [budget] height at
  /// [maxWidth], and the remainder that must flow onto the next page.
  ///
  /// Returns `([], runs)` when there isn't room for even one line — the
  /// [splitRunsByHeight] binary search always keeps at least one line in its
  /// first chunk, which here would strand that line below the page edge where
  /// the painter clips it away.
  (List<TextRun>, List<TextRun>) _fitRunsInHeight(
    List<TextRun> runs,
    double maxWidth,
    double budget,
  ) {
    if (runs.isEmpty) return (const [], const []);
    final tallest = runs.fold<double>(0, (m, r) => math.max(m, r.fontSize));
    if (budget < tallest * 1.3 + kTextBoxPad) return (const [], runs);
    final chunks = splitRunsByHeight(runs, maxWidth, budget);
    if (chunks.length < 2) return (runs, const []);
    return (chunks.first, [for (final ch in chunks.skip(1)) ...ch]);
  }

  ImageElement? insertImageAtCaret(
    String pageId,
    TextElement source,
    int caretOffset,
    ImageElement image,
  ) {
    final page = pages[pageId];
    if (page == null) return null;
    if (!page.objects.any((e) => e.id == source.id)) return null;

    final caret = caretOffset.clamp(0, source.text.length);
    final beforeRuns = sliceRuns(source.runs, 0, caret);
    final afterRuns = sliceRuns(source.runs, caret, source.text.length);

    final left = source.rect.left;
    final imgW = image.rect.width, imgH = image.rect.height;
    // Keep the image on the page when the box starts near the right edge (the
    // caller already capped its width).
    final imgLeft = math.max(0.0, math.min(left, page.width - imgW));
    final maxW = page.width - left - 6;

    final sourceBefore = source.deepCopy();
    final sourceAfter = source.deepCopy();
    final added = <CanvasElement>[];
    final double imageTop;
    // Text that has no room left under the image on THIS page — flowed onto the
    // next one below, as one op with the paste.
    var overflow = const <TextRun>[];
    // The box the overflow continues from (the linked chain is page-ordered, so
    // this is always the last part still on this page).
    TextElement linkSource;

    if (beforeRuns.isEmpty) {
      // Caret at the very start: the image takes the box's top-left and the
      // box slides down under it — keeping only what still fits beneath.
      imageTop = source.rect.top;
      final belowTop = imageTop + imgH + kImageBlockGap;
      final (fits, rest) = _fitRunsInHeight(
        sourceAfter.runs,
        maxW,
        page.height - belowTop - kPageTextMargin,
      );
      // Never leave the box empty: it is the anchor the overflow links from,
      // and an emptied box would just be litter. Keeping one (possibly
      // clipped) line matches what typing overflow does with an unsplittable
      // line, and only bites when the image alone fills the page.
      overflow = rest;
      if (fits.isNotEmpty) sourceAfter.runs = fits;
      sourceAfter.rect = Rect.fromLTWH(
        left,
        belowTop,
        sourceAfter.rect.width,
        sourceAfter.rect.height,
      );
      _remeasureText(sourceAfter, pageId);
      linkSource = sourceAfter;
    } else {
      sourceAfter.runs = beforeRuns;
      _remeasureText(sourceAfter, pageId);
      imageTop = sourceAfter.rect.bottom + kImageBlockGap;
      linkSource = sourceAfter;
      if (afterRuns.isNotEmpty) {
        final belowTop = imageTop + imgH + kImageBlockGap;
        final (fits, rest) = _fitRunsInHeight(
          afterRuns,
          maxW,
          page.height - belowTop - kPageTextMargin,
        );
        overflow = rest;
        // No room under the image at all → the whole remainder flows, and the
        // truncated box above the image stays the link anchor.
        if (fits.isNotEmpty) {
          final below = TextElement(
            id: newModelId('el'),
            deviceId: SettingsService().deviceId,
            rect: Rect.fromLTWH(left, belowTop, 10, 10),
            runs: fits,
            fontFamily: source.fontFamily,
            fontSize: source.fontSize,
            color: source.color,
            bold: source.bold,
            italic: source.italic,
            align: source.align,
          );
          _remeasureText(below, pageId);
          added.add(below);
          linkSource = below;
        }
      }
    }

    image.rect = Rect.fromLTWH(imgLeft, imageTop, imgW, imgH);
    image.zIndex = _belowInkZ(page);
    added.add(image);

    // Built BEFORE the op and the stamp, for two reasons: folding its op into
    // ours keeps one paste = one undo, and it assigns linkSource.linkId, which
    // must be stamped and snapshotted along with everything else.
    final cont = overflow.isEmpty
        ? null
        : _buildContinuation(pageId, linkSource, overflow);

    _stamp([sourceAfter, ...added]); // linkSource is one of these
    final slots = [for (final el in added) _ElSlot(el)];

    _doOp(
      _CanvasOp(
        label: 'Paste image',
        structural: cont?.op.structural ?? false,
        dirtyPageIds: {pageId, ...?cont?.op.dirtyPageIds},
        apply: () {
          _replaceElements(pageId, [sourceAfter]);
          _reviveSlots(page, slots);
          cont?.op.apply();
        },
        revert: () {
          cont?.op.revert();
          _replaceElements(pageId, [sourceBefore]);
          _tombstoneSlots(page, slots);
        },
      ),
    );
    return image;
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
    while (page.objects.any(
      (e) => e is AttachmentElement && (e.rect.top - top).abs() < h / 2,
    )) {
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

  void updateTextElement(String pageId, TextElement before, TextElement after) {
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
    final list = element is StrokeElement ? page.strokes : page.objects;
    final index = list.indexWhere((e) => e.id == element.id);
    if (index < 0) return;
    final slots = [_ElSlot(list[index], index)];
    _doOp(
      _CanvasOp(
        label: 'Remove',
        dirtyPageIds: {pageId},
        apply: () => _tombstoneSlots(page, slots),
        revert: () => _reviveSlots(page, slots),
      ),
    );
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
          canvas.rows.insert(math.min(rowIndex, canvas.rows.length), row);
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
          // If the page was already re-linked out of band (restored from the
          // recycle bin while this canvas stayed open), don't re-insert its
          // row — that would leave two rows referencing the same page id.
          final alreadyReferenced = canvas.rows.any(
            (r) => r.pageIds.contains(pageId),
          );
          if (!alreadyReferenced) {
            if (rowBecomesEmpty) {
              canvas.rows.insert(math.min(rowIndex, canvas.rows.length), row);
            }
            if (!row.pageIds.contains(pageId)) {
              row.pageIds.insert(
                math.min(colIndex, row.pageIds.length),
                pageId,
              );
            }
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
      strokes: [for (final el in src.strokes) el.deepCopy(withNewId: true)],
      objects: [for (final el in src.objects) el.deepCopy(withNewId: true)],
      erased: [
        for (final el in src.erased)
          EraseTombstone(
            strokeId: el.strokeId,
            erasedAt: el.erasedAt,
            deviceId: el.deviceId,
            rev: el.rev,
          ),
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
          canvas.rows.insert(math.min(insertAt, canvas.rows.length), row);
        },
        revert: () {
          canvas.rows.remove(row);
          pages.remove(copy.id);
        },
      ),
    );
  }

  /// Copies [pageId] to the app-global page clipboard so it can be pasted into
  /// another canvas / section / notebook (or back into this one).
  void copyPageToClipboard(String pageId) {
    final page = pages[pageId];
    if (page == null) return;
    PageClipboard().copy(canvas, page);
  }

  /// Pastes the clipboard page as a new page appended at the end of this
  /// canvas, copying any referenced assets first. No-op if the clipboard is
  /// empty. One undoable structural op.
  Future<void> pastePageFromClipboard() async {
    final clip = PageClipboard();
    final src = clip.sourceCanvas;
    final srcPage = clip.page;
    if (src == null || srcPage == null) return;
    final copy = srcPage.cloneWithNewIds(deviceId: SettingsService().deviceId);
    await _service.copyPageAssets(src, canvas, copy);
    final row = PageRow(id: _service.newId(), pageIds: [copy.id]);
    _doOp(
      _CanvasOp(
        label: 'Paste page',
        structural: true,
        dirtyPageIds: {copy.id},
        apply: () {
          pages[copy.id] = copy;
          canvas.rows.add(row);
        },
        revert: () {
          canvas.rows.remove(row);
          pages.remove(copy.id);
        },
      ),
    );
  }

  /// Flat list of all page ids in document order (rows top→bottom, pages
  /// left→right within a row). The page-organizer works on this order.
  List<String> get orderedPageIds => [
    for (final row in canvas.rows) ...row.pageIds,
  ];

  /// Reorders pages to match [newOrder] (a permutation of [orderedPageIds]).
  /// Rows are preserved: pages that were in the same multi-page row and remain
  /// adjacent stay grouped in one row; a page dragged away from its row becomes
  /// its own single-page row. One undoable structural op.
  void reorderPages(List<String> newOrder) {
    // Which original row each page belonged to.
    final rowOf = <String, String>{};
    for (final row in canvas.rows) {
      for (final id in row.pageIds) {
        rowOf[id] = row.id;
      }
    }

    List<PageRow> build() {
      final rows = <PageRow>[];
      for (final id in newOrder) {
        final rid = rowOf[id];
        final last = rows.isEmpty ? null : rows.last;
        // Keep a page with its original row only while its siblings stay
        // contiguous — so an undisturbed horizontal row survives intact.
        if (last != null &&
            rid != null &&
            last.pageIds.isNotEmpty &&
            rowOf[last.pageIds.last] == rid) {
          last.pageIds.add(id);
        } else {
          rows.add(PageRow(id: _service.newId(), pageIds: [id]));
        }
      }
      return rows;
    }

    final beforeSnapshot = [
      for (final r in canvas.rows) PageRow(id: r.id, pageIds: [...r.pageIds]),
    ];
    final afterSnapshot = build();
    if (_sameRows(beforeSnapshot, afterSnapshot)) return; // no-op

    void restore(List<PageRow> snapshot) {
      canvas.rows
        ..clear()
        ..addAll([
          for (final r in snapshot) PageRow(id: r.id, pageIds: [...r.pageIds]),
        ]);
    }

    _doOp(
      _CanvasOp(
        label: 'Reorder pages',
        structural: true,
        apply: () => restore(afterSnapshot),
        revert: () => restore(beforeSnapshot),
      ),
    );
  }

  /// Replaces the canvas's row/column structure with [rows] (each inner list is
  /// one row's page ids, left→right). Empty rows are dropped. Lets the page
  /// organizer move pages freely between and within rows (creating/splitting
  /// multi-page horizontal rows). One undoable structural op; no-op if
  /// unchanged.
  void setPageRows(List<List<String>> rows) {
    final cleaned = [
      for (final r in rows)
        if (r.isNotEmpty) List<String>.from(r),
    ];
    if (cleaned.isEmpty) return;

    final beforeSnapshot = [
      for (final r in canvas.rows) PageRow(id: r.id, pageIds: [...r.pageIds]),
    ];
    final afterSnapshot = [
      for (final r in cleaned) PageRow(id: _service.newId(), pageIds: r),
    ];
    if (_sameRows(beforeSnapshot, afterSnapshot)) return;

    void restore(List<PageRow> snapshot) {
      canvas.rows
        ..clear()
        ..addAll([
          for (final r in snapshot) PageRow(id: r.id, pageIds: [...r.pageIds]),
        ]);
    }

    _doOp(
      _CanvasOp(
        label: 'Rearrange pages',
        structural: true,
        apply: () => restore(afterSnapshot),
        revert: () => restore(beforeSnapshot),
      ),
    );
  }

  /// The current structure as a list of rows of page ids (for the organizer).
  List<List<String>> get pageRows => [
    for (final row in canvas.rows) [...row.pageIds],
  ];

  bool _sameRows(List<PageRow> a, List<PageRow> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].pageIds.length != b[i].pageIds.length) return false;
      for (var j = 0; j < a[i].pageIds.length; j++) {
        if (a[i].pageIds[j] != b[i].pageIds[j]) return false;
      }
    }
    return true;
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
    unawaited(_flushThenReindex());
    return bm;
  }

  void removeBookmark(Bookmark bm) {
    canvas.bookmarks.removeWhere((b) => b.id == bm.id);
    _markDirty(const {}, structural: true);
    notifyListeners();
    unawaited(_flushThenReindex());
  }

  /// Persists the canvas *now* (rather than after the 500ms autosave) and then
  /// bumps the data-changed signal so the search index reindexes — a bookmark
  /// add/remove must be searchable without an app restart. Order matters: the
  /// reindex reads canvas.json from disk, so the flush has to land first, or it
  /// would race the debounced reindex and read a stale file.
  Future<void> _flushThenReindex() async {
    await flushSaves();
    SyncService().notifyDataChanged();
  }

  // ── Voice recordings (audio asset + Canvas.recordings → synced) ────────

  AudioRecorderService? _recorder;
  AudioRecorderService get _audio => _recorder ??= AudioRecorderService();

  AudioPlaybackService? _playback;

  /// The wall-clock instant under the playback playhead while a recording is
  /// actively playing, else null. Drives the audio-sync ink glow in the
  /// painter (the painter merges this into its repaint listenable), so it
  /// updates only the canvas, not the whole widget tree.
  final ValueNotifier<DateTime?> audioPlayheadNotifier = ValueNotifier(null);

  /// Lazily-created playback service (one AudioPlayer per open canvas) for the
  /// Recordings sheet and audio-sync. Created on first use so canvases with no
  /// recordings never touch the plugin.
  AudioPlaybackService get audioPlayback {
    if (_playback == null) {
      final p = AudioPlaybackService();
      p.position.addListener(_updateAudioPlayhead);
      p.currentId.addListener(_updateAudioPlayhead);
      p.playing.addListener(_updateAudioPlayhead);
      _playback = p;
    }
    return _playback!;
  }

  void _updateAudioPlayhead() {
    final p = _playback;
    if (p == null || !p.playing.value) {
      audioPlayheadNotifier.value = null;
      return;
    }
    final id = p.currentId.value;
    AudioRecording? rec;
    for (final r in canvas.recordings) {
      if (r.id == id) {
        rec = r;
        break;
      }
    }
    final playhead = rec?.startedAt.add(p.position.value);
    audioPlayheadNotifier.value = playhead;
    if (playhead != null) _followAudioGlow(playhead);
  }

  // ── Connections: navigate-to-element landing flash ─────────────────────

  /// Elements briefly highlighted after arriving via an internal link — the
  /// painter merges this into its repaint listenable and draws an accent halo
  /// around them (outside the picture cache; a pure no-op when null).
  final ValueNotifier<({String pageId, Set<String> ids})?> linkFlashNotifier =
      ValueNotifier(null);
  Timer? _linkFlashTimer;

  /// Scrolls the elements [ids] on [pageId] into view (keeping zoom) and
  /// flashes them for a moment — the landing move of an element link. Falls
  /// back to a plain page jump when none of the ids exist any more.
  void focusElements(String pageId, List<String> ids) {
    final page = pages[pageId];
    final l = layout.layoutOf(pageId);
    if (page == null || l == null) return;
    Rect? bounds;
    for (final el in [...page.strokes, ...page.objects]) {
      if (!ids.contains(el.id)) continue;
      bounds = bounds == null ? el.bounds : bounds.expandToInclude(el.bounds);
    }
    if (bounds == null) {
      jumpToPage(pageId);
      return;
    }
    ensureCanvasRectVisible(bounds.shift(l.rect.topLeft), margin: 64);
    linkFlashNotifier.value = (pageId: pageId, ids: ids.toSet());
    _linkFlashTimer?.cancel();
    _linkFlashTimer = Timer(const Duration(milliseconds: 2000), () {
      linkFlashNotifier.value = null;
    });
  }

  /// Gently keeps the ink glowing under the audio playhead in view — pans
  /// (keeping zoom) only when the glow is off screen, mirroring read-aloud's
  /// [_followReading]. Runs only from the playback position listener while a
  /// recording is actively playing, so it costs nothing during normal use.
  void _followAudioGlow(DateTime playhead) {
    StrokeElement? latest;
    CanvasPage? latestPage;
    for (final page in pages.values) {
      for (final s in page.strokes) {
        if (!strokeActiveAt(s.createdAt, playhead)) continue;
        if (latest == null || s.createdAt.isAfter(latest.createdAt)) {
          latest = s;
          latestPage = page;
        }
      }
    }
    if (latest == null || latestPage == null) return;
    // Union the glowing strokes on the page being drawn "now" so the whole
    // cluster comes into view, not just the newest stroke.
    var target = latest.bounds;
    for (final s in latestPage.strokes) {
      if (identical(s, latest)) continue;
      if (strokeActiveAt(s.createdAt, playhead)) {
        target = target.expandToInclude(s.bounds);
      }
    }
    final l = layout.layoutOf(latestPage.id);
    if (l == null) return;
    ensureCanvasRectVisible(target.shift(l.rect.topLeft));
  }

  // ── Read-aloud (text-to-speech over typed + PDF text) ─────────────────

  PdfTextCache? _pdfTextCache;
  PdfTextCache get _pdfText => _pdfTextCache ??= PdfTextCache(assetFileOf);

  TtsService? _tts;

  /// The queue currently loaded into [tts], kept so a tap on a text box can be
  /// mapped back to its sentence index (tap-to-jump) and the current unit can be
  /// resolved for the read-along highlight.
  List<ReadingUnit> _readingUnits = const [];

  /// Lazily-created text-to-speech service (created on first read so canvases
  /// that never use read-aloud don't touch the engine). Wires the read-along
  /// highlight to the sentence position on first creation.
  TtsService get tts {
    if (_tts == null) {
      final t = TtsService();
      t.index.addListener(_updateReadHighlight);
      t.speaking.addListener(_updateReadHighlight);
      _tts = t;
    }
    return _tts!;
  }

  /// Whether read-aloud is currently active (playing or paused) on this canvas —
  /// gates the floating reader bar.
  final ValueNotifier<bool> readAloudActive = ValueNotifier(false);

  /// The page + page-local rects of the sentence currently being read, or null
  /// when nothing is (or the current unit has no on-canvas position, e.g. a
  /// whole-page PDF span). Drives the painter's read-along highlight, merged
  /// into its repaint listenable so it repaints only the canvas.
  final ValueNotifier<({String pageId, List<Rect> rects})?>
      readAloudHighlightNotifier = ValueNotifier(null);

  /// Read scope: when true only the first page of each row is read (vertical
  /// pages only); otherwise every page is read row-major (horizontals included).
  /// Persisted device-local so the "tiny selector" remembers the choice.
  final ValueNotifier<bool> readMainColumnOnly =
      ValueNotifier(SettingsService().readAloudMainColumnOnly);

  /// The ordered text sources feeding read-aloud. Typed text today, imported-PDF
  /// text today; a future image/handwriting OCR source is added to this one list
  /// and everything downstream (ordering, sentence-splitting, the reader bar)
  /// works unchanged.
  List<PageTextSource> get _textSources =>
      [const TypedTextSource(), PdfPageTextSource(_pdfText)];

  /// Builds the flat, in-order list of sentences to read for the given scope.
  Future<List<ReadingUnit>> buildReadingUnits(
      {required bool mainColumnOnly}) async {
    final units = <ReadingUnit>[];
    for (final pageId
        in readingOrderPageIds(canvas, mainColumnOnly: mainColumnOnly)) {
      final page = pages[pageId];
      if (page == null) continue;
      final spans = <ReadableSpan>[];
      for (final source in _textSources) {
        spans.addAll(await source.spansFor(page));
      }
      units.addAll(readingUnitsForPage(pageId, orderSpansForReading(spans)));
    }
    return units;
  }

  /// Starts reading the canvas aloud with the current [readMainColumnOnly]
  /// scope. Returns the number of sentences queued (0 → nothing readable, and
  /// the caller can hint the user).
  /// Builds the queue and **opens the reader paused at the resume position** —
  /// it does not start speaking (the user presses play). Returns the sentence
  /// count (0 → nothing readable, and the caller can hint the user). The caller
  /// shows a progress ring while this runs (PDF extraction can take a moment).
  Future<int> prepareReadAloud() async {
    final units =
        await buildReadingUnits(mainColumnOnly: readMainColumnOnly.value);
    if (units.isEmpty) return 0;
    _readingUnits = units;
    readAloudActive.value = true;
    await tts.load(units, startIndex: _resumeIndex(units));
    return units.length;
  }

  /// The queue index to resume at from the saved reading position — an exact
  /// match on page + source + sentence start, else the first sentence on that
  /// page, else the top.
  int _resumeIndex(List<ReadingUnit> units) {
    final pos = SettingsService().readingPositionFor(canvas.id);
    if (pos == null) return 0;
    var pageFallback = -1;
    for (var i = 0; i < units.length; i++) {
      final u = units[i];
      if (u.pageId != pos.pageId) continue;
      if (pageFallback < 0) pageFallback = i;
      if (u.sourceId == pos.sourceId && u.charStart == pos.charStart) return i;
    }
    return pageFallback < 0 ? 0 : pageFallback;
  }

  void _saveReadingPosition() {
    final u = _tts?.current;
    if (u != null) {
      SettingsService()
          .saveReadingPosition(canvas.id, u.pageId, u.sourceId, u.charStart);
    }
  }

  /// Tap-to-jump: resolves a tap on typed text (element [elementId], character
  /// [offset] within it) to the sentence that covers it and reads from there.
  /// No-op if the reader isn't loaded or that text isn't in the queue.
  Future<bool> jumpReadingToText(String elementId, int offset) async {
    if (_readingUnits.isEmpty) return false;
    var idx = -1;
    for (var i = 0; i < _readingUnits.length; i++) {
      final u = _readingUnits[i];
      if (u.sourceId != elementId) continue;
      if (idx < 0) idx = i; // first sentence of this box, as a fallback
      if (offset >= u.charStart && offset < u.charEnd) {
        idx = i;
        break;
      }
    }
    if (idx < 0) return false;
    await tts.jumpTo(idx);
    return true;
  }

  /// Tap-to-jump for PDF (and any positioned) text: resolves a page-local point
  /// to the reading unit whose highlight rects (or bounds) contain it and reads
  /// from there. Fires the jump and reports synchronously whether it hit.
  bool jumpReadingAtPoint(String pageId, Offset local) {
    for (var i = 0; i < _readingUnits.length; i++) {
      final u = _readingUnits[i];
      if (u.pageId != pageId) continue;
      final hit = u.rects.isNotEmpty
          ? u.rects.any((r) => r.contains(local))
          : (u.bounds?.contains(local) ?? false);
      if (hit) {
        unawaited(tts.jumpTo(i));
        return true;
      }
    }
    return false;
  }

  /// Recomputes the read-along highlight (and keeps the read location in view)
  /// from the current sentence. Runs on every [tts] index/speaking change.
  void _updateReadHighlight() {
    final t = _tts;
    if (t == null || !t.speaking.value) {
      readAloudHighlightNotifier.value = null;
      return;
    }
    final unit = t.current;
    if (unit == null) {
      readAloudHighlightNotifier.value = null;
      return;
    }
    final page = pages[unit.pageId];
    var rects = const <Rect>[];
    if (page != null && unit.sourceId != null) {
      for (final el in page.objects) {
        if (el.id == unit.sourceId && el is TextElement) {
          rects = selectionRectsForElement(el, unit.charStart, unit.charEnd);
          break;
        }
      }
    }
    // Typed text resolves rects from its element; PDF text carries precomputed
    // per-line rects on the unit.
    if (rects.isEmpty) rects = unit.rects;
    readAloudHighlightNotifier.value = (pageId: unit.pageId, rects: rects);
    _followReading(unit, rects);
  }

  /// Gently brings the sentence being read into view — but only if it's off
  /// screen (so it doesn't fight the user or jitter within a visible page).
  void _followReading(ReadingUnit unit, List<Rect> rects) {
    final l = layout.layoutOf(unit.pageId);
    if (l == null) return;
    final Rect target = rects.isNotEmpty
        ? rects.first.shift(l.rect.topLeft)
        : Rect.fromLTWH(
            l.rect.left, l.rect.top, l.rect.width, math.min(l.rect.height, 220));
    ensureCanvasRectVisible(target);
  }

  /// Re-reads from the top with the (possibly just-changed) scope. Used when the
  /// user flips the scope selector while the reader bar is open; keeps playing if
  /// it was already playing.
  Future<int> restartReadAloud() async {
    SettingsService().setReadAloudMainColumnOnly(readMainColumnOnly.value);
    final wasPlaying = _tts?.speaking.value ?? false;
    final units =
        await buildReadingUnits(mainColumnOnly: readMainColumnOnly.value);
    if (units.isEmpty) {
      await stopReadAloud();
      return 0;
    }
    _readingUnits = units;
    readAloudActive.value = true;
    await tts.load(units);
    if (wasPlaying) await tts.resume();
    return units.length;
  }

  /// Stops reading and hides the reader bar, saving the reading position so a
  /// later reopen resumes here.
  Future<void> stopReadAloud() async {
    _saveReadingPosition();
    readAloudActive.value = false;
    readAloudHighlightNotifier.value = null;
    _readingUnits = const [];
    await _tts?.stop();
  }

  bool get isRecordingAudio => _recorder?.isRecording ?? false;

  /// Wall-clock start of the in-progress recording (for the UI elapsed timer),
  /// or null when not recording.
  DateTime? get audioRecordingStartedAt => _recorder?.startedAt;

  /// Begins a voice recording over the canvas. Returns false if the mic
  /// permission was denied (the caller surfaces a message).
  Future<bool> startAudioRecording() async {
    if (isRecordingAudio) return true;
    final ok = await _audio.start();
    isRecordingAudioNotifier.value = isRecordingAudio;
    notifyListeners();
    return ok;
  }

  /// Stops the recording, stores the audio as a content-addressed asset, and
  /// appends an [AudioRecording] to the canvas (synced via canvas.json). Returns
  /// the new recording, or null if nothing was captured.
  Future<AudioRecording?> stopAudioRecording() async {
    final result = await _audio.stop();
    isRecordingAudioNotifier.value = false;
    if (result == null) {
      notifyListeners();
      return null;
    }
    final file = File(result.path);
    AudioRecording? rec;
    try {
      final bytes = await file.readAsBytes();
      final assetId = await _service.putAsset(canvas, bytes, 'm4a');
      rec = AudioRecording(
        id: newModelId('rec'),
        name: 'Recording ${canvas.recordings.length + 1}',
        assetId: assetId,
        startedAt: result.startedAt,
        durationMs: result.duration.inMilliseconds,
        createdAt: DateTime.now(),
      );
      canvas.recordings.add(rec);
      _markDirty(const {}, structural: true);
      unawaited(_flushThenReindex());
    } finally {
      try {
        await file.delete();
      } catch (_) {}
    }
    notifyListeners();
    return rec;
  }

  /// Aborts an in-progress recording without saving anything.
  Future<void> cancelAudioRecording() async {
    await _audio.cancel();
    isRecordingAudioNotifier.value = false;
    notifyListeners();
  }

  void renameRecording(AudioRecording rec, String name) {
    rec.name = name;
    _markDirty(const {}, structural: true);
    notifyListeners();
    unawaited(_flushThenReindex());
  }

  /// Removes a recording from the canvas. The audio asset is left on disk
  /// (content-addressed, may be shared; harmless — matches how deleted images'
  /// assets are handled).
  void deleteRecording(AudioRecording rec) {
    canvas.recordings.removeWhere((r) => r.id == rec.id);
    _markDirty(const {}, structural: true);
    notifyListeners();
    unawaited(_flushThenReindex());
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

  /// How far (screen px) the user must keep pulling **past** a document edge
  /// before a new page is added on release. Deliberately large so a normal
  /// scroll that happens to reach the edge never adds a page by accident —
  /// only a firm, intentional pull does (Samsung-Notes-style).
  static const double overscrollThreshold = 200; // screen px

  /// The "+" hint stays hidden until the pull passes this floor, so it never
  /// flashes during ordinary edge-scrolling — it only appears once the user is
  /// clearly reaching for a new page. From here it fills up to the threshold.
  static const double overscrollHintFloor = 90; // screen px

  /// Feed the unconsumed pan from [panBy] during a touch pan gesture.
  void accumulateOverscroll(Offset unconsumed) {
    var changed = false;
    if (unconsumed.dx < 0) {
      overscrollRight = math.min(
        overscrollRight - unconsumed.dx,
        overscrollThreshold * 1.2,
      );
      changed = true;
    }
    if (unconsumed.dy < 0) {
      overscrollBottom = math.min(
        overscrollBottom - unconsumed.dy,
        overscrollThreshold * 1.2,
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
      // A remote-only change (e.g. ink erased elsewhere) never reaches
      // _markDirty (nothing to re-upload), so invalidate here.
      pictureCache.invalidate(remote.id);
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
    pictureCache.invalidate(pageId);
    if (selectionPageId == pageId) clearSelection(notify: false);
    _relayout();
    notifyListeners();
  }

  /// Restores a soft-deleted page into this open canvas (invoked from the
  /// recycle bin via [SyncService.restorePageInOpenCanvas]). Loads the
  /// tombstoned page from disk, clears its tombstone, and appends a fresh row
  /// at the bottom — done in memory so the controller's own autosave persists
  /// it (a disk-level restore would be overwritten by that autosave). Not an
  /// undo op: it originates outside the canvas's own editing history.
  Future<void> restorePage(String pageId) async {
    if (pages.containsKey(pageId)) return; // already live
    final page = await _service.loadPageFile(canvas, pageId);
    if (page == null || page.purgedAt != null) return;
    page.deletedAt = null;
    pages[pageId] = page;
    final referenced = <String>{for (final r in canvas.rows) ...r.pageIds};
    if (!referenced.contains(pageId)) {
      canvas.rows.add(PageRow(id: _service.newId(), pageIds: [pageId]));
    }
    // Persist: savePage rewrites the page with its tombstone cleared (bumped
    // rev, so it beats the deletion in LWW everywhere), saveCanvas writes the
    // new row. Flush immediately (not just the 500ms debounce) so the bin sees
    // the cleared tombstone the moment it reloads after the restore.
    _markDirty({pageId}, structural: true);
    _relayout();
    notifyListeners();
    await flushSaves();
  }

  /// canvas.json changed on disk from a pull — refresh structure (rows,
  /// defaults, attachments) and load any newly-referenced pages from disk.
  /// Skipped while local structural edits are still waiting to flush; LWW on
  /// the next round trip reconciles that case.
  Future<void> applyRemoteStructure() async {
    if (_dirtyStructure) return;
    final fresh = await _service.getCanvas(
      canvas.notebookId,
      canvas.sectionId,
      canvas.id,
    );
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
    canvas.recordings
      ..clear()
      ..addAll(fresh.recordings);

    // Keep live in-memory pages (they may be ahead of disk); read only the
    // ones we don't have yet, and drop ones no row references anymore.
    final referenced = <String>{for (final row in canvas.rows) ...row.pageIds};
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
    _holdTimer?.cancel();
    _saveTimer?.cancel();
    unawaited(_recorder?.dispose());
    unawaited(_playback?.dispose());
    _saveReadingPosition();
    unawaited(_tts?.dispose());
    _pdfTextCache?.clear();
    flushSaves();
    renderCache.dispose();
    pictureCache.dispose();
    toolNotifier.dispose();
    toolOptionsOpenNotifier.dispose();
    hasSelectionNotifier.dispose();
    isDraggingSelectionNotifier.dispose();
    isEditingTextNotifier.dispose();
    clipboardNotifier.dispose();
    isRecordingAudioNotifier.dispose();
    audioPlayheadNotifier.dispose();
    _linkFlashTimer?.cancel();
    linkFlashNotifier.dispose();
    readAloudActive.dispose();
    readMainColumnOnly.dispose();
    readAloudHighlightNotifier.dispose();
    chromeContentTick.dispose();
    super.dispose();
  }
}
