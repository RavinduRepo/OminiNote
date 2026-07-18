import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:flutter/services.dart';
import 'package:open_filex/open_filex.dart';
import 'package:url_launcher/url_launcher.dart';
import '../utils/clipboard_images.dart';
import '../utils/ink_contrast.dart';
import '../utils/progress_overlay.dart';
import '../utils/html_text.dart';
import '../utils/markdown_text.dart';
import '../utils/url_text.dart';
import '../canvas/canvas_controller.dart';
import '../canvas/canvas_layout.dart';
import '../canvas/canvas_painter.dart';
import '../canvas/rich_text_controller.dart';
import '../canvas/text_measure.dart';
import '../models/canvas_page.dart';
import '../models/element.dart';
import '../models/canvas.dart';
import '../services/notebook_service.dart';
import '../services/page_clipboard.dart';
import '../services/pdf_export_isolate.dart';
import '../services/pdf_exporter.dart';
import '../services/settings_service.dart';
import '../services/sync_service.dart';
import '../theme/app_theme.dart';
import '../widgets/action_sheet.dart';
import '../widgets/sync_status_icon.dart';
import 'canvas_toolbar/adaptive_toolbar_row.dart';
import 'canvas_toolbar/canvas_chrome_shared.dart';
import 'canvas_toolbar/customize_toolbar_sheet.dart';
import 'canvas_toolbar/lasso_floating_menu.dart';
import 'canvas_toolbar/text_bottom_bar.dart';
import 'canvas_toolbar/tool_option_rows.dart';
import 'canvas_toolbar/tool_options_popover.dart';
import 'page_organizer.dart';

/// Stroke width of the box drawn around the text element being edited, in
/// SCREEN px (call sites divide by zoom — the overlay lays out in page
/// points). Matches the lasso selection box's 1.5px stroke so a box looks the
/// same whether it's selected or being edited.
const double kEditBorderStroke = 1.5;

/// The Canvas: a freely pannable/zoomable surface of pages (blank or
/// PDF-backed) with ink, text, and images. The app owns the viewport;
/// input routing: stylus + mouse draw, touch pans/zooms, wheel scrolls
/// (Ctrl = zoom, Shift = horizontal), double-tap (touch) fits page width,
/// over-scroll past the right/bottom edge adds a page.
class CanvasScreen extends StatefulWidget {
  final Canvas canvas;

  /// Fired after the canvas is renamed here, so a host embedding this screen
  /// directly (e.g. the desktop split-view sidebar) can refresh its own copy
  /// of the name instead of relying on this screen's own AppBar title.
  final VoidCallback? onCanvasRenamed;

  /// Optional page to jump to once loaded (e.g. opening a bookmark from search).
  final String? initialPageId;

  /// True when embedded directly in a host (the desktop split-view) rather than
  /// pushed as its own route. When embedded, this screen does NOT pop itself if
  /// its notebook disappears (moved/deleted elsewhere) — the host clears its own
  /// selection instead; popping would dismiss the wrong route.
  final bool embedded;

  /// When embedded (desktop), full-screen still hides this screen's own app
  /// bar/toolbar (the internal full-screen), and additionally notifies the host
  /// via this callback so it can collapse its side panes — the canvas then
  /// fills the whole window. Called with the new full-screen state.
  final ValueChanged<bool>? onFullScreenChanged;

  /// Split-view (in-app multi-canvas, `CanvasWorkspaceScreen`). When non-null,
  /// an "Open canvas alongside" item appears in the overflow to add a pane.
  final VoidCallback? onSplitRequested;

  /// When non-null (a secondary split pane), the app bar's leading becomes a
  /// close-pane "×" that calls this, instead of a back arrow.
  final VoidCallback? onClosePane;

  /// When non-null, the app bar shows a back arrow that calls this (used by the
  /// workspace's primary embedded pane, which has no route of its own to pop).
  final VoidCallback? onBack;

  const CanvasScreen({
    super.key,
    required this.canvas,
    this.onCanvasRenamed,
    this.initialPageId,
    this.embedded = false,
    this.onFullScreenChanged,
    this.onSplitRequested,
    this.onClosePane,
    this.onBack,
  });

  @override
  State<CanvasScreen> createState() => _CanvasScreenState();
}

class _CanvasScreenState extends State<CanvasScreen>
    with WidgetsBindingObserver {
  final _service = NotebookService();
  CanvasController? _controller;
  bool _showToolbar = true;

  // Full screen: hides the app bar + normal toolbar, replaced by a floating
  // exit button and a collapsed tool control (see _buildFloatingToolControl).
  bool _isFullScreen = false;
  bool _fullScreenPickerOpen = false;

  // Whether the small floating audio player is showing (opened via the
  // "Recordings" action, or kept up while a take plays). Replaces the old
  // Recordings bottom sheet.
  bool _audioPlayerOpen = false;

  // Tap tracking for the text tool (placement happens on tap-up).
  Offset? _downPosition;
  bool _toolGestureActive = false;
  bool _scrollbarDragging = false;

  /// Pointer id of the finger currently drawing (finger-draw mode only), so
  /// other fingers' events don't feed the stroke and a second touch can
  /// cancel it into a pan/pinch.
  int? _fingerDrawPointer;

  /// The current pointer went down inside the text-edit overlay: the
  /// TextField owns the whole gesture (caret, drag-select), so our pointer-up
  /// tap handling must not run — it would re-enter _startTextEdit on the same
  /// element with a fresh controller and wipe the selection the user just
  /// made ("selection dies as soon as the finger/mouse lifts").
  bool _pointerInTextEditor = false;

  bool _elementGrabbing = false; // guards the pan recognizer for touch grabs

  // Last tap (for double-tap detection in the lasso tool: double-tap an
  // attachment chip to open it, since a single tap now selects it).
  Offset? _lastTapPos;
  DateTime? _lastTapTime;

  // Touch pan/zoom bookkeeping.
  Offset _lastFocal = Offset.zero;
  double _lastScale = 1.0;

  _TextEditSession? _textEdit;

  /// Where the caret sat when the last edit session committed.
  ///
  /// Needed because a paste triggered from a control OUTSIDE the editor — the
  /// Add sheet's Paste — fires the field's `onTapOutside` first, committing the
  /// session and clearing `_textEdit` before the handler ever runs. Without
  /// this the caret is simply gone by paste time. Holds an ID, not a ref:
  /// committing routes through `updateTextElement` → `_replaceElements`, which
  /// swaps in a `deepCopy`, so the session's instance is stale afterwards.
  ///
  /// Only consulted when NO session is live (an open one is the better answer)
  /// and only while the text tool is still active — switching tools means the
  /// user moved on, and a stale caret shouldn't drag an image across the page.
  /// Rewritten by each commit, cleared when the committed box doesn't survive
  /// (an emptied box is dropped) and once a paste consumes it.
  ({String pageId, String elementId, int caret})? _lastCaret;

  /// Captures the rendered canvas so "copy selection" can put pixels on the
  /// OS clipboard.
  final GlobalKey _canvasBoundaryKey = GlobalKey();

  /// Keys the text style bar floating at the canvas bottom so the caret
  /// auto-scroll can keep the caret above it, not just above the keyboard.
  final GlobalKey _textBarKey = GlobalKey();

  /// Keyboard focus for canvas shortcuts (Ctrl+C/V/X/Z/Y/D, Delete, Esc).
  final FocusNode _canvasFocus = FocusNode(debugLabel: 'canvas-shortcuts');

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
    // Close this view if its notebook is moved to another account or deleted on
    // another device (its notebooks.json entry is tombstoned here). Only when
    // pushed as its own route — the desktop host clears its selection instead.
    if (!widget.embedded) {
      SyncService().dataVersion.addListener(_onSyncData);
    }
  }

  @override
  void didChangeMetrics() {
    // Keyboard opening/closing (or a window resize) moves the visible area —
    // keep the editing caret in view. The Scaffold consumes the keyboard inset
    // when it resizes, so watching MediaQuery from inside the body misses
    // this; window metrics don't lie.
    if (_textEdit != null) _scheduleEnsureEditVisible();
  }

  bool _closing = false;

  Future<void> _onSyncData() async {
    if (_closing || !mounted) return;
    final nb = await _service.getNotebook(widget.canvas.notebookId);
    if (nb != null || _closing || !mounted) {
      return; // still here — nothing to do
    }
    _closing = true;
    // The whole notebook is gone (moved/deleted), so the section + notebook
    // screens beneath this canvas are stale too — pop all the way back to the
    // notebooks list, not just one level.
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    if (navigator.canPop()) {
      navigator.popUntil((route) => route.isFirst);
      messenger.showSnackBar(
        const SnackBar(
          content: Text(
            'This notebook was moved or deleted on another device.',
          ),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  Future<void> _load() async {
    final pages = await _service.loadPages(widget.canvas);
    if (!mounted) return;
    setState(() {
      _controller = CanvasController(canvas: widget.canvas, pages: pages)
        ..systemCopyHook = _copySelectionToSystemClipboard
        ..systemPasteFallback = _pasteFromSystemClipboard
        ..eraserPartial = SettingsService().eraserPartial
        ..eraserSize = SettingsService().eraserSize;
    });
    // Jump to a requested page (e.g. a bookmark opened from search) once the
    // first layout has set the screen size, so the fit math has real bounds.
    final target = widget.initialPageId;
    if (target != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _controller?.jumpToPage(target);
      });
    }
  }

  // ── OS clipboard bridging ─────────────────────────────────────────────

  /// Mirrors the just-copied selection to the OS clipboard: text-only
  /// selections as plain text, anything else as a PNG of the selection's
  /// on-screen pixels.
  Future<void> _copySelectionToSystemClipboard() async {
    final c = _controller;
    if (c == null || c.selection.isEmpty) return;

    if (c.selection.every((e) => e is TextElement)) {
      final texts = c.selection.whereType<TextElement>().toList();
      final text = texts.map((t) => t.text).join('\n');
      if (text.trim().isEmpty) return;
      // Rich flavor first (styled runs → HTML with a plain-text fallback in
      // the same clipboard item), so pasting into a rich target keeps the
      // formatting; plain Clipboard only if the platform lacks support.
      final allRuns = <TextRun>[];
      for (final t in texts) {
        if (allRuns.isNotEmpty) {
          allRuns.add(
            TextRun(
              text: '\n',
              fontSize: t.fontSize,
              bold: false,
              italic: false,
              color: t.color,
              fontFamily: t.fontFamily,
            ),
          );
        }
        allRuns.addAll(t.runs);
      }
      try {
        if (await ClipboardHtml.write(htmlFromRuns(allRuns), text)) return;
      } catch (_) {
        // fall through to plain text
      }
      await Clipboard.setData(ClipboardData(text: text));
      return;
    }

    // A single image: put the ORIGINAL file bytes on the clipboard
    // (lossless), not a screen-resolution re-render. Assets are stored as
    // PNG/JPEG; both paste fine elsewhere.
    if (c.selection.length == 1 && c.selection.single is ImageElement) {
      try {
        final el = c.selection.single as ImageElement;
        final file = _service.assetFile(widget.canvas, el.assetId);
        if (await file.exists()) {
          await ClipboardImages.write(await file.readAsBytes());
          return;
        }
      } catch (_) {
        // fall through to the rendered-pixels path
      }
    }

    try {
      final pageId = c.selectionPageId;
      final bounds = c.selectionBounds;
      if (pageId == null || bounds == null) return;
      final boundary =
          _canvasBoundaryKey.currentContext?.findRenderObject()
              as RenderRepaintBoundary?;
      if (boundary == null) return;

      const ratio = 2.0; // crisp enough for re-paste anywhere
      final full = await boundary.toImage(pixelRatio: ratio);
      final screenRect = c
          .pageScreenRect(pageId, bounds.inflate(8))
          .intersect(Offset.zero & boundary.size);
      if (screenRect.isEmpty) return;

      // Crop the selection out of the captured frame.
      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder);
      final src = Rect.fromLTWH(
        screenRect.left * ratio,
        screenRect.top * ratio,
        screenRect.width * ratio,
        screenRect.height * ratio,
      );
      final dst = Rect.fromLTWH(0, 0, src.width, src.height);
      canvas.drawImageRect(full, src, dst, ui.Paint());
      final cropped = await recorder.endRecording().toImage(
        src.width.round(),
        src.height.round(),
      );
      final png = await cropped.toByteData(format: ui.ImageByteFormat.png);
      full.dispose();
      cropped.dispose();
      if (png == null) return;
      await ClipboardImages.write(png.buffer.asUint8List());
    } catch (_) {
      // OS image clipboard unsupported here — the internal clipboard still
      // has the full-fidelity copy.
    }
  }

  /// Paste fallback when the internal clipboard is empty: OS image first,
  /// then rich HTML text (formatting preserved), then plain OS text.
  Future<void> _pasteFromSystemClipboard() async {
    final c = _controller;
    if (c == null) return;

    Uint8List? imageBytes;
    try {
      imageBytes = await ClipboardImages.read();
    } catch (_) {
      imageBytes = null; // platform without image clipboard support
    }
    if (imageBytes != null && imageBytes.isNotEmpty) {
      await _insertImageBytes(imageBytes);
      return;
    }

    // Rich text: browsers/Word/OneNote put an HTML flavor on the clipboard
    // alongside the plain one — read it so bold/color/size etc. survive.
    String? html;
    try {
      html = await ClipboardHtml.read();
    } catch (_) {
      html = null;
    }
    if (html != null && mounted && _pasteRichHtml(html)) return;

    await _pasteSystemText();
  }

  /// Drops styled multi-run text built from clipboard HTML on the current
  /// page — split across linked continuation pages when it's taller than the
  /// page. Returns false when the HTML held no visible text (the caller then
  /// falls back to the plain-text paste).
  bool _pasteRichHtml(String html) {
    final c = _controller!;
    final target = c.currentPageLayout;
    if (target == null) return false;

    final base = TextRun(
      text: '',
      fontSize: c.textFontSize,
      bold: false,
      italic: false,
      color: c.textColor,
      fontFamily: c.textFontFamily,
    );
    var runs = runsFromHtml(html, base);
    if (runs.isEmpty) return false;

    // A source/code view (editor, chat code fence) wraps raw Markdown in an
    // HTML flavor — the converted text then *still reads as Markdown*. Only
    // reconvert when the HTML produced a style-UNIFORM result (the fingerprint
    // of a source copy): a rendered page always has style variety, and
    // reconverting one would flatten its real headings/bold/code styling and
    // mis-convert literal syntax its content merely mentions (found live on a
    // Markdown spec page whose escaped examples became headings).
    final first = runs.first;
    final uniform = runs.every(
      (r) =>
          r.fontSize == first.fontSize &&
          r.bold == first.bold &&
          r.italic == first.italic &&
          r.fontFamily == first.fontFamily &&
          r.link == null,
    );
    final joined = runs.map((r) => r.text).join();
    var wasMarkdown = false;
    if (uniform && looksLikeMarkdown(joined)) {
      final md = runsFromMarkdown(joined, base);
      if (md.isNotEmpty) {
        runs = md;
        wasMarkdown = true;
      }
    }

    final boxes = c.insertRunsAsText(target.pageId, runs);
    final what = wasMarkdown ? 'Markdown as formatted text' : 'formatted text';
    _toast(boxes > 1 ? 'Pasted $what across $boxes pages' : 'Pasted $what');
    return boxes > 0;
  }

  /// Decodes [bytes], stores them as an asset, and drops an ImageElement
  /// Paste while a text box is being edited (Ctrl/Cmd+V or the context menu's
  /// Paste — both route through [PasteTextIntent]).
  ///
  /// An image on the clipboard goes into the DOCUMENT at the caret;
  /// [_insertImageBytes] → [_placeImage] commits the session and does the
  /// block-insert. Text keeps its normal in-field behaviour.
  ///
  /// The check can't be synchronous (reading the clipboard is async, the
  /// intent's handler is not), so this replaces the default paste rather than
  /// deferring to it: `TextField` exposes no handle on its inner
  /// `EditableText`, so there's no `pasteText` to delegate back to. Inserting
  /// through the controller is equivalent for our purposes —
  /// `TextEditingValue.replaced` drops the selection and moves the caret just
  /// like the default action, `RichTextController`'s setter reconciles the
  /// per-character styles, and the field's undo history tracks the controller.
  Future<void> _handleEditorPaste(SelectionChangedCause? cause) async {
    Uint8List? image;
    try {
      image = await ClipboardImages.read();
    } catch (_) {
      image = null; // platform without image-clipboard support
    }
    if (!mounted) return;
    if (image != null && image.isNotEmpty) {
      await _insertImageBytes(image);
      return;
    }

    final rc = _textEdit?.controller;
    if (rc == null) return;
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text == null || text.isEmpty || !mounted) return;
    if (_textEdit?.controller != rc) return; // session changed under the await
    final sel = rc.selection;
    rc.value = rc.value.replaced(
      sel.isValid ? sel : TextSelection.collapsed(offset: rc.text.length),
      text,
    );
  }

  /// Places a freshly-built [image] on [pageId]: at the caret when the user is
  /// (or just was) typing in a text box — as a block, pushing the text after
  /// the caret below it (see [CanvasController.insertImageAtCaret]) — else at
  /// the top-left of what's currently on screen.
  ///
  /// Commits any live edit session FIRST: the caret indexes the box's committed
  /// runs, and until commit the editor's controller — not the element — holds
  /// the real text.
  void _placeImage(PageLayout target, ImageElement image) {
    final c = _controller!;
    final pageId = target.pageId;

    // Resolve the caret to (page, element id, offset) BEFORE committing:
    // committing swaps the element instance for a deepCopy, so a ref taken
    // here would go stale.
    ({String pageId, String elementId, int caret})? at;
    final session = _textEdit;
    if (session != null) {
      final sel = session.controller.selection;
      at = (
        pageId: session.pageId,
        elementId: session.element.id,
        caret: sel.isValid ? sel.baseOffset : session.element.text.length,
      );
      _commitTextEdit(); // writes the controller's runs onto the element
    } else if (c.tool == CanvasTool.text) {
      at = _lastCaret;
    }

    if (at != null) {
      final host = c.pages[at.pageId];
      final el = host?.objects
          .whereType<TextElement>()
          .cast<TextElement?>()
          .firstWhere((e) => e!.id == at!.elementId, orElse: () => null);
      // The box can be gone (an emptied box is dropped on commit) — fall
      // through to the viewport placement rather than losing the paste.
      if (el != null && c.insertImageAtCaret(at.pageId, el, at.caret, image) != null) {
        _lastCaret = null; // consumed; the text around it just moved
        return;
      }
    }

    // No caret: land at the top-left of the visible viewport, nudged in so the
    // image doesn't sit flush against the edge, and clamped onto the page (the
    // viewport can be scrolled past the page's own bounds).
    final page = c.pages[pageId]!;
    final view = c.screenToCanvas(const Offset(24, 24)) - target.rect.topLeft;
    final local = Offset(
      view.dx.clamp(0.0, math.max(0.0, page.width - image.rect.width)),
      view.dy.clamp(0.0, math.max(0.0, page.height - image.rect.height)),
    );
    c.addImageBelowInk(
      pageId,
      image
        ..rect = Rect.fromLTWH(
          local.dx,
          local.dy,
          image.rect.width,
          image.rect.height,
        ),
    );
  }

  /// centered on the current page (scaled to fit).
  Future<void> _insertImageBytes(Uint8List bytes) async {
    final c = _controller!;
    final target = c.currentPageLayout;
    if (target == null) return;
    final page = c.pages[target.pageId]!;

    ui.Image decoded;
    try {
      final codec = await ui.instantiateImageCodec(bytes);
      decoded = (await codec.getNextFrame()).image;
    } catch (_) {
      _toast('Clipboard image could not be read');
      return;
    }
    // Always store a real PNG: clipboards can hand over formats (e.g. a
    // Windows DIB) that Flutter decodes fine but the PDF exporter's
    // PdfBitmap (PNG/JPEG only) would silently drop from exports.
    var storeBytes = bytes;
    try {
      final png = await decoded.toByteData(format: ui.ImageByteFormat.png);
      if (png != null) storeBytes = png.buffer.asUint8List();
    } catch (_) {}
    final assetId = await _service.putAsset(widget.canvas, storeBytes, 'png');
    final maxW = page.width * 0.6;
    final scale = math.min(1.0, maxW / decoded.width);
    final w = decoded.width * scale, h = decoded.height * scale;
    decoded.dispose();
    if (!mounted) return;
    _placeImage(
      target,
      ImageElement(
        id: newModelId('el'),
        deviceId: SettingsService().deviceId,
        rect: Rect.fromLTWH(0, 0, w, h), // _placeImage positions it
        assetId: assetId,
      ),
    );
    _toast('Image pasted');
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (!widget.embedded) {
      SyncService().dataVersion.removeListener(_onSyncData);
    }
    _canvasFocus.dispose();
    _controller?.dispose(); // flushes pending saves
    super.dispose();
  }

  // ── Pointer routing ──────────────────────────────────────────────────

  bool _isDrawingDevice(PointerEvent e) =>
      e.kind == PointerDeviceKind.stylus ||
      e.kind == PointerDeviceKind.invertedStylus ||
      (e.kind == PointerDeviceKind.touch && SettingsService().fingerDraw) ||
      (e.kind == PointerDeviceKind.mouse && e.buttons == kPrimaryMouseButton);

  bool _forceEraser(PointerEvent e) =>
      e.kind == PointerDeviceKind.invertedStylus ||
      (e.kind == PointerDeviceKind.stylus &&
          (e.buttons & kPrimaryStylusButton) != 0);

  void _onPointerDown(PointerDownEvent e) {
    final c = _controller!;
    // Clicking the canvas claims keyboard focus for the shortcut handler
    // (unless a text edit is active — the TextField keeps it then).
    if (_textEdit == null && !_canvasFocus.hasFocus) {
      _canvasFocus.requestFocus();
    }

    // Finger-draw mode: a second finger landing while one is drawing means
    // the user wants to pan/pinch — cancel the in-progress finger stroke and
    // hand the gesture to the scale recognizer (which tracks both fingers).
    if (e.kind == PointerDeviceKind.touch &&
        _fingerDrawPointer != null &&
        e.pointer != _fingerDrawPointer &&
        _toolGestureActive) {
      _toolGestureActive = false;
      _fingerDrawPointer = null;
      c.cancelToolGesture();
      return;
    }

    // A tool's options panel (colors/size, selection actions, text style) or
    // the full-screen tool picker is open: the first tap outside it just
    // dismisses it, matching "shrinks as soon as you tap outside" — it
    // doesn't also start a draw/pan gesture on that same tap.
    if (c.toolOptionsOpen) {
      c.closeToolOptions();
      return;
    }
    if (_fullScreenPickerOpen) {
      setState(() => _fullScreenPickerOpen = false);
      return;
    }

    // An open text editor: taps inside it belong to the TextField (caret
    // placement); taps outside commit it — then fall through as a normal
    // canvas interaction. In the Text tool specifically, the commit is
    // deferred to pointer-up instead: a tap that lands on a *different*
    // existing text box commits the old one and starts the new one together
    // in one synchronous call (_handleTextTap), so a bottom bar reflecting
    // the edit session never disappears for a frame in between. Any other
    // tool switching away still commits immediately here (matches the
    // TextField's own onTapOutside behavior for toolbar taps).
    final session = _textEdit;
    if (session != null) {
      final editorRect = c
          .pageScreenRect(session.pageId, session.element.rect)
          .inflate(12);
      if (editorRect.contains(e.localPosition)) {
        _pointerInTextEditor = true; // swallow the matching pointer-up too
        return;
      }
      // A stylus touching down is about to auto-switch the tool away from
      // Text (below) — commit immediately rather than defer, or the session
      // would be orphaned open once the tool is no longer Text by the time
      // pointer-up's fallback check runs.
      final stylusAutoSwitch =
          e.kind == PointerDeviceKind.stylus ||
          e.kind == PointerDeviceKind.invertedStylus;
      if (c.tool != CanvasTool.text || stylusAutoSwitch) {
        _commitTextEdit();
      }
    }
    _downPosition = e.localPosition;

    // S-Pen / stylus touching the canvas while in Text mode auto-switches to
    // the Pen (draw) tool — the only automatic tool switch.
    if (e.kind == PointerDeviceKind.stylus ||
        e.kind == PointerDeviceKind.invertedStylus) {
      c.handleStylusInput();
    }

    // Mouse or finger can grab the scrollbar thumb. Touch also goes through
    // the pan recognizer, so the scale handlers below no-op while a scrollbar
    // drag is active.
    if ((e.kind == PointerDeviceKind.mouse ||
            e.kind == PointerDeviceKind.touch) &&
        c.beginScrollbarDrag(e.localPosition)) {
      _scrollbarDragging = true;
      return;
    }

    // Text tool: it only creates/edits text — it never moves a box (that's the
    // Lasso tool's job). Taps are handled on pointer-up (edit existing / create
    // new); a drag just pans. So nothing to grab here.
    if (c.tool == CanvasTool.text) {
      return;
    }

    if (_isDrawingDevice(e)) {
      _toolGestureActive = c.startToolGesture(
        e.localPosition,
        e.pressure == 0 ? 0.5 : e.pressure,
        forceEraser: _forceEraser(e),
      );
      if (_toolGestureActive && e.kind == PointerDeviceKind.touch) {
        _fingerDrawPointer = e.pointer;
      }
    } else if (e.kind == PointerDeviceKind.touch &&
        c.tool == CanvasTool.lasso &&
        c.selection.isNotEmpty &&
        c.hitTestSelection(e.localPosition) != SelectionHit.none) {
      // Let a finger drag the selection too — it's a precise, deliberate
      // target, unlike freehand drawing.
      _toolGestureActive = c.startToolGesture(e.localPosition, 0.5);
    }
  }

  void _onPointerMove(PointerMoveEvent e) {
    if (_scrollbarDragging) {
      _controller!.updateScrollbarDrag(e.localPosition);
      return;
    }
    if (!_toolGestureActive) return;
    // A finger is drawing: only that finger's moves feed the stroke.
    if (_fingerDrawPointer != null && e.pointer != _fingerDrawPointer) return;
    _controller!.updateToolGesture(
      e.localPosition,
      e.pressure == 0 ? 0.5 : e.pressure,
    );
  }

  void _onPointerUp(PointerUpEvent e) {
    final c = _controller!;
    // This gesture lived inside the text editor (caret tap / drag-select):
    // the TextField already handled it fully.
    if (_pointerInTextEditor) {
      _pointerInTextEditor = false;
      return;
    }
    // A non-drawing finger lifting must not end the drawing finger's stroke.
    if (_toolGestureActive &&
        _fingerDrawPointer != null &&
        e.pointer != _fingerDrawPointer) {
      return;
    }
    _fingerDrawPointer = null;
    final down = _downPosition;
    _downPosition = null;

    if (_scrollbarDragging) {
      _scrollbarDragging = false;
      c.endScrollbarDrag();
      return;
    }

    final moved = down != null && (e.localPosition - down).distance >= 10;

    // A deferred text-edit commit (see _onPointerDown): this turned into a
    // drag/pan rather than a tap, so resolve it now — only a genuine tap
    // that lands on a different existing text box gets the flicker-free
    // commit-then-start treatment inside _handleTextTap.
    if (moved && c.tool == CanvasTool.text && _textEdit != null) {
      _commitTextEdit();
    }

    if (_toolGestureActive) {
      _toolGestureActive = false;

      // Lasso tool, TAP (not drag): select the single topmost element under
      // the point so it can be moved/resized. A drag draws the lasso circle or
      // moves the current selection (handled by endToolGesture).
      if (c.tool == CanvasTool.lasso && !moved) {
        c.cancelToolGesture();
        final cb = _checkboxAt(e.localPosition);
        if (cb != null) {
          c.toggleCheckboxAt(cb.$1, cb.$2.id, cb.$3);
          return;
        }
        final url = _urlAt(e.localPosition);
        if (url != null) {
          _openUrl(url);
        } else {
          _lassoTap(e.localPosition, e.kind);
        }
        return;
      }

      c.endToolGesture();
      return;
    }

    // Taps that didn't start a gesture.
    if (!moved && e.kind != PointerDeviceKind.trackpad) {
      // A tap directly on a checkbox glyph toggles it, regardless of tool —
      // the drawn ☐/☑ is the affordance, like a link's blue underline.
      final cb = _checkboxAt(e.localPosition);
      if (cb != null) {
        // A deferred text-edit commit (see _onPointerDown) isn't resolved by
        // this branch — do it now rather than leave the old session open.
        if (c.tool == CanvasTool.text && _textEdit != null) _commitTextEdit();
        c.toggleCheckboxAt(cb.$1, cb.$2.id, cb.$3);
        return;
      }
      // A tap directly on a link opens it, regardless of tool (the blue
      // underlined text is the affordance). Tapping elsewhere falls through.
      final url = _urlAt(e.localPosition);
      if (url != null) {
        if (c.tool == CanvasTool.text && _textEdit != null) _commitTextEdit();
        _openUrl(url);
        return;
      }
      if (c.tool == CanvasTool.text) {
        // In the text tool a tap on an attachment opens it (single tap);
        // otherwise edit an existing box / create a new one.
        final att = _attachmentAt(e.localPosition);
        if (att != null) {
          if (_textEdit != null) _commitTextEdit();
          _openAttachment(att);
          return;
        }
        _handleTextTap(e.localPosition);
      } else if (c.tool == CanvasTool.lasso) {
        _lassoTap(e.localPosition, e.kind);
      }
    }
  }

  void _onPointerCancel(PointerCancelEvent e) {
    if (_scrollbarDragging) {
      _scrollbarDragging = false;
      _controller!.endScrollbarDrag();
    } else if (_toolGestureActive) {
      _toolGestureActive = false;
      _controller!.cancelToolGesture();
    }
    _fingerDrawPointer = null;
    _pointerInTextEditor = false;
    _elementGrabbing = false;
    _downPosition = null;
  }

  /// Lasso-tool tap: select the single topmost element under [screenPos] (so it
  /// can be moved/resized via the handles). Attachments open on a single tap
  /// with a finger (mobile); with a mouse/pen a single tap selects the
  /// attachment and a double tap opens it.
  void _lassoTap(Offset screenPos, PointerDeviceKind kind) {
    final c = _controller!;
    final att = _attachmentAt(screenPos);
    if (att != null) {
      if (kind == PointerDeviceKind.touch) {
        _openAttachment(att); // finger: single tap opens
        return;
      }
      final now = DateTime.now();
      final isDouble =
          _lastTapTime != null &&
          _lastTapPos != null &&
          now.difference(_lastTapTime!) < const Duration(milliseconds: 350) &&
          (screenPos - _lastTapPos!).distance < 24;
      _lastTapTime = now;
      _lastTapPos = screenPos;
      if (isDouble) {
        _openAttachment(att);
        return;
      }
    }
    c.selectAt(screenPos);
  }

  /// Topmost text element under a screen position, with its page id.
  // ignore: unused_element
  (String, TextElement)? _textAt(Offset screenPos) {
    final c = _controller!;
    final canvasPos = c.screenToCanvas(screenPos);
    final pageLayout = c.layout.pageAt(canvasPos);
    if (pageLayout == null) return null;
    final page = c.pages[pageLayout.pageId]!;
    final local = canvasPos - pageLayout.rect.topLeft;
    for (final el in [...page.strokes, ...page.objects].reversed) {
      if (el is TextElement && el.rect.inflate(6).contains(local)) {
        return (pageLayout.pageId, el);
      }
    }
    return null;
  }

  /// The checkbox glyph under a screen position — `(pageId, element,
  /// charOffset)` if the tap landed on a line-leading ☐/☑ in the topmost text
  /// box there (else null). Mirrors [_urlAt].
  (String, TextElement, int)? _checkboxAt(Offset screenPos) {
    final c = _controller!;
    final canvasPos = c.screenToCanvas(screenPos);
    final pageLayout = c.layout.pageAt(canvasPos);
    if (pageLayout == null) return null;
    final page = c.pages[pageLayout.pageId]!;
    final local = canvasPos - pageLayout.rect.topLeft;
    for (final el in page.objects.reversed) {
      if (el is TextElement && el.rect.inflate(4).contains(local)) {
        final offset = checkboxOffsetAt(el, local - el.rect.topLeft);
        if (offset != null) return (pageLayout.pageId, el, offset);
        return null; // topmost text box wins even when the tap missed a glyph
      }
    }
    return null;
  }

  /// The link URL under a screen position, if the tap landed on a link run in
  /// the topmost text box there (else null).
  String? _urlAt(Offset screenPos) {
    final c = _controller!;
    final canvasPos = c.screenToCanvas(screenPos);
    final pageLayout = c.layout.pageAt(canvasPos);
    if (pageLayout == null) return null;
    final page = c.pages[pageLayout.pageId]!;
    final local = canvasPos - pageLayout.rect.topLeft;
    for (final el in [...page.strokes, ...page.objects].reversed) {
      if (el is TextElement && el.rect.inflate(4).contains(local)) {
        return urlAtOffset(el, local - el.rect.topLeft);
      }
    }
    return null;
  }

  /// Opens [url] in the system browser. Returns true if a tap was consumed.
  Future<void> _openUrl(String url) async {
    final ok = await launchUrl(
      Uri.parse(url),
      mode: LaunchMode.externalApplication,
    );
    if (!ok && mounted) _toast("Couldn't open $url");
  }

  /// Topmost attachment chip under a screen position.
  AttachmentElement? _attachmentAt(Offset screenPos) {
    final c = _controller!;
    final canvasPos = c.screenToCanvas(screenPos);
    final pageLayout = c.layout.pageAt(canvasPos);
    if (pageLayout == null) return null;
    final page = c.pages[pageLayout.pageId]!;
    final local = canvasPos - pageLayout.rect.topLeft;
    for (final el in page.objects.reversed) {
      if (el is AttachmentElement && el.rect.inflate(4).contains(local)) {
        return el;
      }
    }
    return null;
  }

  /// Opens an attachment chip's file with the platform's default handler.
  Future<void> _openAttachment(AttachmentElement el) async {
    final file = _service.assetFile(widget.canvas, el.assetId);
    if (!await file.exists()) {
      _toast(
        '"${el.name}" is missing on this device — sync may still be '
        'downloading it',
      );
      return;
    }
    final result = await OpenFilex.open(file.path, type: el.mime);
    if (result.type != ResultType.done && mounted) {
      _toast('Could not open "${el.name}": ${result.message}');
    }
  }

  void _onPointerSignal(PointerSignalEvent e) {
    if (e is! PointerScrollEvent) return;
    final c = _controller!;
    final keys = HardwareKeyboard.instance;
    if (keys.isControlPressed || keys.isMetaPressed) {
      // Wheel zoom, centered on the cursor.
      c.zoomAt(e.localPosition, math.exp(-e.scrollDelta.dy * 0.002));
    } else if (keys.isShiftPressed) {
      c.scrollByWheel(Offset(-(e.scrollDelta.dy + e.scrollDelta.dx), 0));
    } else {
      c.scrollByWheel(-e.scrollDelta);
    }
  }

  // ── Touch pan / pinch ────────────────────────────────────────────────

  void _onScaleStart(ScaleStartDetails d) {
    if (_scrollbarDragging || _elementGrabbing) return;
    _controller!.stopScrollAnimation(); // grabbing halts momentum
    _lastFocal = d.localFocalPoint;
    _lastScale = 1.0;
  }

  void _onScaleUpdate(ScaleUpdateDetails d) {
    if (_scrollbarDragging || _elementGrabbing) return;
    final c = _controller!;
    if (c.hasActiveGesture) return; // palm rejection while the pen is down
    final unconsumed = c.panImmediate(d.localFocalPoint - _lastFocal);
    if (d.pointerCount == 1 && d.scale == 1.0) {
      c.accumulateOverscroll(unconsumed);
    }
    if (d.scale != _lastScale && _lastScale > 0) {
      c.zoomAt(d.localFocalPoint, d.scale / _lastScale);
    }
    _lastFocal = d.localFocalPoint;
    _lastScale = d.scale;
  }

  void _onScaleEnd(ScaleEndDetails d) {
    if (_scrollbarDragging || _elementGrabbing) return;
    final c = _controller!;
    final addedPage = c.settleOverscroll();
    if (!addedPage) {
      c.flingBy(d.velocity.pixelsPerSecond);
    }
  }

  void _onDoubleTapDown(TapDownDetails d) {
    final c = _controller!;
    final canvasPos = c.screenToCanvas(d.localPosition);
    final page = c.layout.pageAt(canvasPos) ?? c.layout.nearestPage(canvasPos);
    if (page != null) c.fitPageWidth(page.pageId);
  }

  // ── Text tool ────────────────────────────────────────────────────────

  /// Hit-tests for an existing [TextElement] under [screenPos] — shared by
  /// [_handleTextTap] (edit vs. create) and nothing else; kept as its own
  /// function so the hit-test logic has one home.
  TextElement? _textElementAt(Offset screenPos) {
    final c = _controller!;
    final canvasPos = c.screenToCanvas(screenPos);
    final pageLayout = c.layout.pageAt(canvasPos);
    if (pageLayout == null) return null;
    final page = c.pages[pageLayout.pageId]!;
    final local = canvasPos - pageLayout.rect.topLeft;
    for (final el in [...page.strokes, ...page.objects].reversed) {
      if (el is TextElement && el.rect.inflate(4).contains(local)) return el;
    }
    return null;
  }

  void _handleTextTap(Offset screenPos) {
    // Retargeting from one existing text box straight to another: commit the
    // old one and start the new one together in this single synchronous
    // call, so a bottom bar reflecting the edit session never disappears for
    // a frame in between (a tap that instead lands on empty canvas/a
    // checkbox/a link/an attachment already committed the old session
    // earlier — in _onPointerDown/_onPointerUp — where a single immediate
    // hide is correct).
    if (_textEdit != null) {
      _commitTextEdit();
    }
    final c = _controller!;
    final canvasPos = c.screenToCanvas(screenPos);
    final pageLayout = c.layout.pageAt(canvasPos);
    if (pageLayout == null) return;
    final page = c.pages[pageLayout.pageId]!;
    final local = canvasPos - pageLayout.rect.topLeft;

    // Tap an existing text element → edit it, caret under the finger. (Local
    // space is the box's top-left, matching the link/checkbox hit-tests above.)
    final existing = _textElementAt(screenPos);
    if (existing != null) {
      _startTextEdit(
        page.id,
        existing,
        isNew: false,
        caretAt: local - existing.rect.topLeft,
      );
      return;
    }

    // Otherwise drop a new (auto-sizing) text box at the tap point.
    final el = TextElement(
      id: newModelId('el'),
      deviceId: SettingsService().deviceId,
      rect: Rect.fromLTWH(
        local.dx.clamp(0.0, page.width - 40),
        local.dy.clamp(0.0, page.height - 24),
        80,
        c.textFontSize * 1.6,
      ),
      text: '',
      fontFamily: c.textFontFamily,
      fontSize: c.textFontSize,
      color: c.color,
      bold: c.textBold,
      italic: c.textItalic,
      align: c.textAlign,
    );
    // A fresh box is empty, so the caret can only go at 0 — but passing it
    // explicitly keeps the selection VALID, which stops EditableText's
    // focus-time `selection = collapsed(text.length)` fixup from firing a
    // redundant _onEditingChanged (and viewport glide) on open.
    _startTextEdit(page.id, el, isNew: true, caretAt: Offset.zero);
  }

  /// Opens an edit session on [el]. [caretAt] is the tap point in the box's
  /// local (page-point) space, when the session was opened BY a tap: the caret
  /// goes exactly there, which is both what every text editor does and what
  /// keeps the viewport still.
  ///
  /// Leaving the selection invalid instead makes the viewport jump TWICE before
  /// the user can aim: `_ensureEditCaretVisible` falls back to end-of-text for
  /// an invalid selection, and `EditableText` separately assigns
  /// `controller.selection = collapsed(text.length)` on focus — which notifies,
  /// firing `_onEditingChanged` and a second glide. Zoomed in on a box taller
  /// than the screen, both scroll to the box's END, dragging the spot the user
  /// was aiming at out from under them. With the caret placed at the tap, it is
  /// visible by construction, so the ensure-visible below is a no-op and only
  /// does its real job — lifting the caret above the keyboard.
  void _startTextEdit(
    String pageId,
    TextElement el, {
    required bool isNew,
    Offset? caretAt,
  }) {
    final c = _controller!;
    c.clearSelection(notify: false);
    final rc = RichTextController(
      text: el.text,
      attrs: attrsFromElement(el),
      defaults: defaultAttrOf(el),
    );
    if (caretAt != null) {
      rc.selection = TextSelection.collapsed(
        offset: caretOffsetAt(el, caretAt),
      );
    }
    rc.addListener(_onEditingChanged);
    setState(() {
      _textEdit = _TextEditSession(
        pageId: pageId,
        element: el,
        isNew: isNew,
        before: el.deepCopy(),
        controller: rc,
      );
    });
    // Routes toolbar style changes to the in-box selection, and hides the
    // element from the painter (the TextField draws it while editing).
    c.setEditing(el, rc);
    _scheduleEnsureEditVisible();
  }

  /// Fires on any text or selection change while editing: re-measures the box
  /// and syncs the toolbar/typing style to the caret or selection.
  void _onEditingChanged() {
    final session = _textEdit;
    if (session == null) return;
    final c = _controller!;
    final rc = session.controller;
    final sel = rc.selection;
    final selectionMoved = sel != session.lastSelection;
    session.lastSelection = sel;

    // Only adopt the surrounding text's style as the typing style when the
    // caret/selection actually moved. Applying a style to a collapsed caret
    // preserves the selection, so this branch is skipped and the just-set
    // typing style (`defaults`) survives to the next keystroke — the fix for
    // "can't change style while typing". A Markdown input rule that changed
    // the typing style (heading/quote) suppresses one adoption the same way,
    // or the rule's own caret move would clobber it.
    if (selectionMoved && !rc.consumeSuppressStyleAdopt()) {
      rc.defaults = rc.styleForToolbar().clone();
    }

    // Reflect the authoritative current style in the toolbar: for a collapsed
    // caret that's the typing style (`defaults`) so a just-applied bold/size
    // shows as active; for a range it's the range's leading style.
    final display = (sel.isValid && sel.isCollapsed)
        ? rc.defaults
        : rc.styleForToolbar();
    c.textFontFamily = display.family;
    c.textFontSize = display.fontSize;
    c.textBold = display.bold;
    c.textItalic = display.italic;
    c.textColor =
        display.color; // text's own color slot, whatever tool is active
    _remeasureEditing();
    // Typing or moving the caret can carry it off screen (below the keyboard,
    // past the viewport edge while zoomed) — glide it back into view.
    _scheduleEnsureEditVisible();
    c.notifyRepaint(); // refresh toolbar highlight
  }

  /// Grows/wraps the editing box to fit the current (rich) content — and when
  /// it outgrows the page bottom, flows the overflow onto the next page.
  void _remeasureEditing() {
    final session = _textEdit;
    if (session == null) return;
    final page = _controller!.pages[session.pageId];
    if (page == null) return;
    final el = session.element;
    el.runs = runsFromController(session.controller);
    final maxWidth = page.width - el.rect.left - 6;
    setState(() {
      el.rect = autoTextRect(el, maxWidth);
    });
    if (el.rect.bottom > page.height - 8 && !_handlingOverflow) {
      // Never mutate the controller from inside its own notification.
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _handleTypingOverflow(),
      );
    }
  }

  bool _handlingOverflow = false;
  bool _ensureVisibleScheduled = false;

  /// Schedules a post-frame viewport glide that brings the editing caret into
  /// view — the post-frame delay lets a pending remeasure/keyboard resize land
  /// first so the geometry we correct against is current.
  void _scheduleEnsureEditVisible() {
    if (_ensureVisibleScheduled) return;
    _ensureVisibleScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _ensureVisibleScheduled = false;
      _ensureEditCaretVisible();
    });
  }

  /// Glides the viewport so the editing caret is on screen. Matters most on
  /// mobile: the keyboard shrinks the canvas (resizeToAvoidBottomInset) and
  /// the box being edited can end up hidden under where it appeared.
  void _ensureEditCaretVisible() {
    final session = _textEdit;
    final c = _controller;
    if (session == null || c == null || !mounted || c.screenSize.isEmpty) {
      return;
    }
    final el = session.element;
    final sel = session.controller.selection;
    final caretIdx = (sel.isValid ? sel.extentOffset : el.text.length).clamp(
      0,
      el.text.length,
    );
    // Caret position in page points, from the same layout the painter uses.
    final tp = TextPainter(
      text: textSpanForElement(el),
      textDirection: TextDirection.ltr,
      textAlign: switch (el.align) {
        TextAlignOption.center => TextAlign.center,
        TextAlignOption.right => TextAlign.right,
        _ => TextAlign.left,
      },
    )..layout(minWidth: el.rect.width, maxWidth: math.max(el.rect.width, 8));
    final caret = tp.getOffsetForCaret(
      TextPosition(offset: caretIdx),
      Rect.zero,
    );
    final lineH = tp.preferredLineHeight;
    tp.dispose();
    final screen = c.pageScreenRect(
      session.pageId,
      Rect.fromLTWH(el.rect.left + caret.dx, el.rect.top + caret.dy, 1, lineH),
    );
    // Visible area: the canvas height, minus however much of it the keyboard
    // covers — computed from window metrics + the canvas's global position,
    // which is correct whether or not the Scaffold resized for the keyboard
    // (when it did, the overlap is simply ≤ 0).
    const margin = 28.0;
    var visibleBottom = c.screenSize.height;
    final rb = _canvasBoundaryKey.currentContext?.findRenderObject();
    if (rb is RenderBox && rb.hasSize) {
      final view = View.of(context);
      final keyboardTop =
          (view.physicalSize.height - view.viewInsets.bottom) /
          view.devicePixelRatio;
      final canvasTop = rb.localToGlobal(Offset.zero).dy;
      visibleBottom = math.min(visibleBottom, keyboardTop - canvasTop);
      // The text style bar floats over the canvas bottom (above the
      // keyboard) — keep the caret above IT, not just above the keyboard.
      final bar = _textBarKey.currentContext?.findRenderObject();
      if (bar is RenderBox && bar.hasSize && bar.size.height > 0) {
        final barTop = bar.localToGlobal(Offset.zero).dy - canvasTop;
        visibleBottom = math.min(visibleBottom, barTop);
      }
    }
    var dy = 0.0;
    if (screen.bottom > visibleBottom - margin) {
      dy = (visibleBottom - margin) - screen.bottom;
    } else if (screen.top < margin) {
      dy = margin - screen.top;
    }
    var dx = 0.0;
    if (screen.right > c.screenSize.width - margin) {
      dx = (c.screenSize.width - margin) - screen.right;
    } else if (screen.left < margin) {
      dx = margin - screen.left;
    }
    if (dx != 0 || dy != 0) c.scrollByWheel(Offset(dx, dy));
  }

  /// Live-typing page flow (the paste-splitter's typing counterpart): when the
  /// editing box crosses the page bottom, the lines that no longer fit move to
  /// a linked continuation box on the next page (reused if empty, freshly
  /// inserted otherwise — `insertTypingContinuation`). If the caret rode the
  /// overflow (typing at the end — the common case), the editing session
  /// commits and hops to the continuation, word-processor style; editing the
  /// middle keeps the caret put and only the tail flows. Overflow only flows
  /// forward — no Word-style back-rebalancing (deliberate v1 scope).
  void _handleTypingOverflow() {
    final session = _textEdit;
    final c = _controller;
    if (session == null || c == null || _handlingOverflow) return;
    final page = c.pages[session.pageId];
    if (page == null) return;
    final el = session.element;
    if (el.rect.bottom <= page.height - 8) return; // resolved meanwhile

    _handlingOverflow = true;
    try {
      final rc = session.controller;
      final runs = runsFromController(rc);
      final maxW = page.width - el.rect.left - 6;
      final budget = page.height - el.rect.top - 8;
      final chunks = splitRunsByHeight(runs, maxW, budget);
      if (chunks.length < 2) return; // one unsplittable line — leave as-is

      final fit = chunks.first;
      final overflow = [for (final ch in chunks.skip(1)) ...ch];
      final fitLen = fit.fold(0, (n, r) => n + r.text.length);
      final caret = rc.selection.baseOffset;

      final target = c.insertTypingContinuation(session.pageId, el, overflow);
      if (target == null) return;
      final (targetPageId, targetEl) = target;

      // Truncate the editing box to the fitting part. The value setter
      // reconciles per-char styles by suffix diff, so attributes follow.
      final fitText = fit.map((r) => r.text).join();
      rc.value = TextEditingValue(
        text: fitText,
        selection: TextSelection.collapsed(
          offset: math.min(math.max(caret, 0), fitText.length),
        ),
      );

      if (caret > fitLen) {
        // The caret rode the overflow: hop the session to the continuation.
        final rel = math.min(math.max(caret - fitLen, 0), targetEl.text.length);
        _commitTextEdit();
        c.jumpToPage(targetPageId);
        _startTextEdit(targetPageId, targetEl, isNew: false);
        _textEdit?.controller.selection = TextSelection.collapsed(offset: rel);
      }
    } finally {
      _handlingOverflow = false;
    }
  }

  void _commitTextEdit() {
    final session = _textEdit;
    if (session == null) return;
    final c = _controller!;
    final rc = session.controller;
    // Remember the caret before the controller goes away, so a paste routed
    // through a control outside the editor can still land on it.
    final caretSel = rc.selection;
    rc.removeListener(_onEditingChanged);
    _textEdit = null;
    c.setEditing(null, null);

    final el = session.element;
    // Auto-link URLs in the committed text (splits runs at URL boundaries).
    el.runs = linkifyRuns(runsFromController(rc));
    final page = c.pages[session.pageId];
    if (page != null) {
      el.rect = autoTextRect(el, page.width - el.rect.left - 6);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => rc.dispose());

    if (el.text.trim().isEmpty) {
      // Nothing typed: drop a new box, or delete an emptied existing one.
      _lastCaret = null; // no box survives — nothing to anchor a paste to
      if (!session.isNew) c.removeElement(session.pageId, session.before);
      setState(() {});
      return;
    }

    if (session.isNew) {
      c.addElement(session.pageId, el);
    } else {
      c.updateTextElement(session.pageId, session.before, el);
    }
    _lastCaret = (
      pageId: session.pageId,
      elementId: el.id,
      caret: (caretSel.isValid ? caretSel.baseOffset : el.text.length).clamp(
        0,
        el.text.length,
      ),
    );
    setState(() {});
  }

  // ── App-bar overflow (sheet on mobile, popup on desktop) ─────────────

  /// Sheet menus when pushed as its own screen (the mobile shell); popup menus
  /// when embedded in the desktop split-view. `embedded` is the exact signal.
  bool _useMobileMenus(BuildContext context) => !widget.embedded;

  /// Leading button for a split-view pane: close "×" for a secondary pane, a
  /// back arrow for the primary embedded pane, else null (normal behavior).
  Widget? _paneLeading() {
    if (widget.onClosePane != null) {
      return IconButton(
        icon: const Icon(Icons.close),
        tooltip: 'Close pane',
        onPressed: widget.onClosePane,
      );
    }
    if (widget.onBack != null) {
      return IconButton(
        icon: const BackButtonIcon(),
        tooltip: 'Back',
        onPressed: widget.onBack,
      );
    }
    return null;
  }

  /// Every overflow action **not** already promoted to the app bar (see
  /// `_buildDesktopToolbar`/mobile actions) shows up here instead — an item
  /// lives in exactly one place at a time.
  Widget _buildOverflowMenu(BuildContext context) {
    final palette = Theme.of(context).extension<AppPalette>()!;
    final mobile = _useMobileMenus(context);
    final c = _controller;
    final promoted = mobile
        ? SettingsService().promotedToolbarMobile
        : SettingsService().promotedToolbarDesktop;
    bool shown(String id) => !promoted.contains(id);
    // Undo/redo/+ are now promotable buttons; when one isn't on the bar it
    // falls back into this menu. Undo/redo only appear when there's actually
    // something to undo/redo. The Add sub-actions belong to the "+" menu, not
    // here — so when "+" itself isn't on the bar, "⋯" shows a single "Add…"
    // entry that opens that add menu (rather than scattering its items here).
    final showUndo = shown('undo') && (c?.canUndo ?? false);
    final showRedo = shown('redo') && (c?.canRedo ?? false);
    final showAdd = shown('add');

    if (mobile) {
      return IconButton(
        icon: Icon(Icons.more_vert, color: palette.textDim),
        tooltip: 'More',
        onPressed: () => showActionSheet(
          context,
          items: [
            if (showUndo)
              ActionSheetItem(
                icon: Icons.undo,
                label: 'Undo',
                onTap: () => c?.undo(),
              ),
            if (showRedo)
              ActionSheetItem(
                icon: Icons.redo,
                label: 'Redo',
                onTap: () => c?.redo(),
              ),
            if (showAdd)
              ActionSheetItem(
                icon: Icons.add,
                label: 'Add…',
                onTap: _showAddSheet,
              ),
            if (widget.onSplitRequested != null && shown('split'))
              ActionSheetItem(
                icon: Icons.vertical_split_outlined,
                label: 'Open canvas alongside',
                onTap: widget.onSplitRequested!,
              ),
            if (shown('fullscreen'))
              ActionSheetItem(
                icon: Icons.fullscreen,
                label: 'Full screen',
                onTap: _toggleFullScreen,
              ),
            if (shown('toggle_toolbar'))
              ActionSheetItem(
                icon: _showToolbar ? Icons.expand_less : Icons.brush_outlined,
                label: _showToolbar ? 'Hide tools' : 'Show tools',
                onTap: () => setState(() => _showToolbar = !_showToolbar),
              ),
            if (shown('rename'))
              ActionSheetItem(
                icon: Icons.edit_outlined,
                label: 'Rename',
                onTap: _renameCanvas,
              ),
            if (shown('export'))
              ActionSheetItem(
                icon: Icons.picture_as_pdf_outlined,
                label: 'Export PDF',
                onTap: _exportPdf,
              ),
            if (shown('navigator'))
              ActionSheetItem(
                icon: Icons.grid_view_outlined,
                label: 'Pages',
                onTap: _showNavigator,
              ),
            if (shown('bookmarks'))
              ActionSheetItem(
                icon: Icons.bookmark_border,
                label: 'Bookmarks',
                onTap: _showBookmarks,
              ),
            if (shown('attachments'))
              ActionSheetItem(
                icon: Icons.attach_file,
                label: 'Attachments',
                onTap: _showAttachments,
              ),
            if (shown('page_settings'))
              ActionSheetItem(
                icon: Icons.description_outlined,
                label: 'Page settings',
                onTap: _showPageSettings,
              ),
            if (shown('shape_snap'))
              ActionSheetItem(
                icon: SettingsService().shapeSnap
                    ? Icons.check_box_outlined
                    : Icons.check_box_outline_blank,
                label: 'Snap drawn shapes',
                onTap: _toggleShapeSnap,
              ),
            if (shown('finger_draw'))
              ActionSheetItem(
                icon: SettingsService().fingerDraw
                    ? Icons.check_box_outlined
                    : Icons.check_box_outline_blank,
                label: 'Draw with finger',
                onTap: _toggleFingerDraw,
              ),
            ActionSheetItem(
              icon: Icons.tune,
              label: 'Customize toolbar…',
              onTap: () async {
                await showCustomizeToolbarSheet(context, mobile: true);
                // The sheet writes straight to SettingsService; nothing
                // notifies this screen, so force a rebuild to pick up the
                // new promoted-action lists.
                if (mounted) setState(() {});
              },
            ),
          ],
        ),
      );
    }
    return PopupMenuButton<String>(
      onSelected: (action) {
        switch (action) {
          case 'undo':
            c?.undo();
          case 'redo':
            c?.redo();
          case 'add':
            _showAddSheet();
          case 'split':
            widget.onSplitRequested?.call();
          case 'fullscreen':
            _toggleFullScreen();
          case 'toggle_toolbar':
            setState(() => _showToolbar = !_showToolbar);
          case 'rename':
            _renameCanvas();
          case 'export':
            _exportPdf();
          case 'navigator':
            _showNavigator();
          case 'bookmarks':
            _showBookmarks();
          case 'attachments':
            _showAttachments();
          case 'page_settings':
            _showPageSettings();
          case 'finger_draw':
            _toggleFingerDraw();
          case 'shape_snap':
            _toggleShapeSnap();
          case 'customize':
            showCustomizeToolbarSheet(context, mobile: false).then((_) {
              // Same reason as the mobile sheet: force a rebuild so the
              // desktop toolbar/app-bar reflect the new promoted-action
              // lists immediately.
              if (mounted) setState(() {});
            });
        }
      },
      itemBuilder: (context) => [
        if (showUndo) iconMenuItem('undo', Icons.undo, 'Undo'),
        if (showRedo) iconMenuItem('redo', Icons.redo, 'Redo'),
        if (showAdd) iconMenuItem('add', Icons.add, 'Add…'),
        if (widget.onSplitRequested != null && shown('split'))
          iconMenuItem('split', Icons.vertical_split_outlined,
              'Open canvas alongside'),
        if (shown('fullscreen'))
          iconMenuItem('fullscreen', Icons.fullscreen, 'Full screen'),
        if (shown('toggle_toolbar'))
          iconMenuItem(
            'toggle_toolbar',
            _showToolbar ? Icons.expand_less : Icons.brush_outlined,
            _showToolbar ? 'Hide tools' : 'Show tools',
          ),
        if (shown('rename'))
          iconMenuItem('rename', Icons.edit_outlined, 'Rename'),
        if (shown('export'))
          iconMenuItem('export', Icons.picture_as_pdf_outlined, 'Export PDF'),
        if (shown('navigator'))
          iconMenuItem('navigator', Icons.grid_view_outlined, 'Pages'),
        if (shown('bookmarks'))
          iconMenuItem('bookmarks', Icons.bookmark_border, 'Bookmarks'),
        if (shown('attachments'))
          iconMenuItem('attachments', Icons.attach_file, 'Attachments'),
        if (shown('page_settings'))
          iconMenuItem(
            'page_settings',
            Icons.description_outlined,
            'Page settings',
          ),
        // Checkbox glyphs reflect toggle state, matching the mobile sheet.
        if (shown('shape_snap'))
          iconMenuItem(
            'shape_snap',
            SettingsService().shapeSnap
                ? Icons.check_box_outlined
                : Icons.check_box_outline_blank,
            'Snap drawn shapes',
          ),
        if (shown('finger_draw'))
          iconMenuItem(
            'finger_draw',
            SettingsService().fingerDraw
                ? Icons.check_box_outlined
                : Icons.check_box_outline_blank,
            'Draw with finger',
          ),
        iconMenuItem('customize', Icons.tune, 'Customize toolbar…'),
      ],
    );
  }

  // ── Add / insert flows ───────────────────────────────────────────────

  Future<void> _showAddSheet() async {
    // An add sub-action that's individually promoted to the bar is left out of
    // this sheet — it lives in exactly one place. Uses the active layout's
    // unified promoted list (this sheet is also the fallback the "⋯" menu's
    // "Add…" opens on desktop when "+" itself isn't on the bar).
    final promoted = _useMobileMenus(context)
        ? SettingsService().promotedToolbarMobile
        : SettingsService().promotedToolbarDesktop;
    bool shown(String id) => !promoted.contains(id);
    final action = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (context) => scrollableSheetBody(
        context,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            const _SheetLabel('Pages'),
            if (shown('blank'))
              ListTile(
                leading: const Icon(Icons.note_add_outlined),
                title: const Text('Blank page'),
                subtitle: const Text('Above · below · or at the end'),
                onTap: () => Navigator.pop(context, 'blank'),
              ),
            if (shown('horizontal'))
              ListTile(
                leading: const Icon(Icons.swap_horiz),
                title: const Text('Horizontal page'),
                subtitle: const Text('Extend this row to the right'),
                onTap: () => Navigator.pop(context, 'horizontal'),
              ),
            if (shown('pdf'))
              ListTile(
                leading: const Icon(Icons.picture_as_pdf_outlined),
                title: const Text('Insert PDF'),
                subtitle: const Text(
                  'As annotatable pages, or as an attachment',
                ),
                onTap: () => Navigator.pop(context, 'pdf'),
              ),
            if (PageClipboard().hasPage.value)
              ListTile(
                leading: const Icon(Icons.content_paste_go_outlined),
                title: const Text('Paste page'),
                subtitle: const Text('A page copied from any canvas'),
                onTap: () => Navigator.pop(context, 'pastePage'),
              ),
            const Divider(),
            const _SheetLabel('Content'),
            if (shown('image'))
              ListTile(
                leading: const Icon(Icons.image_outlined),
                title: const Text('Image'),
                subtitle: const Text('From files'),
                onTap: () => Navigator.pop(context, 'image'),
              ),
            if (Platform.isAndroid || Platform.isIOS)
              ListTile(
                leading: const Icon(Icons.photo_camera_outlined),
                title: const Text('Take photo'),
                subtitle: const Text('Capture with the camera'),
                onTap: () => Navigator.pop(context, 'camera'),
              ),
            if (shown('paste'))
              ListTile(
                leading: const Icon(Icons.content_paste),
                title: const Text('Paste'),
                onTap: () => Navigator.pop(context, 'paste'),
              ),
            const Divider(),
            const _SheetLabel('Audio'),
            if (shown('record_audio') &&
                !(_controller?.isRecordingAudio ?? false))
              ListTile(
                leading: const Icon(Icons.mic_none),
                title: const Text('Record audio'),
                subtitle: const Text('Capture voice over this canvas'),
                onTap: () => Navigator.pop(context, 'record_audio'),
              ),
            if (shown('recordings'))
              ListTile(
                leading: const Icon(Icons.graphic_eq),
                title: const Text('Recordings'),
                subtitle: const Text('Play back voice recordings'),
                onTap: () => Navigator.pop(context, 'recordings'),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (!mounted || action == null) return;
    await _runAddAction(action);
  }

  /// Runs one Add action. Shared by the mobile Add sheet and the desktop
  /// top-bar Add dropdown.
  Future<void> _runAddAction(String action) async {
    final c = _controller;
    if (c == null) return;
    switch (action) {
      case 'blank':
        final pos = await _pickInsertPosition(includeTop: false);
        if (pos != null) c.addBlankPage(pos);
      case 'horizontal':
        final current = c.currentPageLayout;
        if (current != null) c.addHorizontalPage(current.rowIndex);
      case 'pdf':
        await _insertPdfFlow();
      case 'image':
        await _insertImageFlow();
      case 'camera':
        await _capturePhotoFlow();
      case 'paste':
        await _pasteFlow();
      case 'pastePage':
        await c.pastePageFromClipboard();
        _toast('Page pasted at the end');
      case 'record_audio':
        await _startAudioRecording();
      case 'recordings':
        _openAudioPlayer();
    }
  }

  /// The Add control: a bottom sheet on mobile, a top-bar dropdown on
  /// desktop. Whichever Add actions are promoted to the desktop toolbar
  /// (see `_buildDesktopToolbar`) are left out here — an item lives in
  /// exactly one place at a time.
  Widget _buildAddButton(BuildContext context) {
    if (_useMobileMenus(context)) {
      return IconButton(
        icon: const Icon(Icons.add),
        tooltip: 'Add',
        onPressed: _showAddSheet,
      );
    }
    final promoted = SettingsService().promotedToolbarDesktop;
    bool shown(String id) => !promoted.contains(id);
    return PopupMenuButton<String>(
      icon: const Icon(Icons.add),
      tooltip: 'More to add',
      onSelected: _runAddAction,
      itemBuilder: (context) => [
        if (shown('blank'))
          iconMenuItem('blank', Icons.note_add_outlined, 'Add page'),
        if (shown('horizontal'))
          iconMenuItem('horizontal', Icons.swap_horiz, 'Horizontal page'),
        if (shown('pdf'))
          iconMenuItem('pdf', Icons.picture_as_pdf_outlined, 'Insert PDF'),
        if (shown('image'))
          iconMenuItem('image', Icons.image_outlined, 'Insert image'),
        // Same gate as the mobile Add sheet — an Android/iOS device in the
        // desktop *layout* has a camera; true desktop OSes (no image_picker
        // camera support) don't show it.
        if (Platform.isAndroid || Platform.isIOS)
          iconMenuItem('camera', Icons.photo_camera_outlined, 'Take photo'),
        if (PageClipboard().hasPage.value)
          iconMenuItem(
            'pastePage',
            Icons.content_paste_go_outlined,
            'Paste page',
          ),
        if (shown('paste')) iconMenuItem('paste', Icons.content_paste, 'Paste'),
        if (shown('record_audio') &&
            !(_controller?.isRecordingAudio ?? false))
          iconMenuItem('record_audio', Icons.mic_none, 'Record audio'),
        if (shown('recordings'))
          iconMenuItem('recordings', Icons.graphic_eq, 'Recordings'),
      ],
    );
  }

  Future<InsertPosition?> _pickInsertPosition({bool includeTop = true}) {
    return showModalBottomSheet<InsertPosition>(
      context: context,
      isScrollControlled: true,
      builder: (context) => scrollableSheetBody(
        context,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            const _SheetLabel('Where?'),
            if (includeTop)
              ListTile(
                leading: const Icon(Icons.vertical_align_top),
                title: const Text('At the top'),
                onTap: () => Navigator.pop(context, InsertPosition.top),
              ),
            ListTile(
              leading: const Icon(Icons.arrow_upward),
              title: const Text('Above current page'),
              onTap: () => Navigator.pop(context, InsertPosition.aboveCurrent),
            ),
            ListTile(
              leading: const Icon(Icons.arrow_downward),
              title: const Text('Below current page'),
              onTap: () => Navigator.pop(context, InsertPosition.belowCurrent),
            ),
            ListTile(
              leading: const Icon(Icons.vertical_align_bottom),
              title: const Text('At the end'),
              onTap: () => Navigator.pop(context, InsertPosition.end),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Future<void> _insertPdfFlow() async {
    final c = _controller!;
    final mode = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (context) => scrollableSheetBody(
        context,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            ListTile(
              leading: const Icon(Icons.grid_view_outlined),
              title: const Text('Insert with view'),
              subtitle: const Text(
                'Each PDF page becomes a page you can write on',
              ),
              onTap: () => Navigator.pop(context, 'view'),
            ),
            ListTile(
              leading: const Icon(Icons.attach_file),
              title: const Text('Add as attachment'),
              subtitle: const Text('Kept with this canvas, not drawn on it'),
              onTap: () => Navigator.pop(context, 'attach'),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (!mounted || mode == null) return;

    InsertPosition? position;
    if (mode == 'view') {
      position = await _pickInsertPosition();
      if (position == null || !mounted) return;
    }

    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['pdf'],
    );
    final path = result?.files.single.path;
    if (path == null || !mounted) return;

    final bytes = await File(path).readAsBytes();
    final assetId = await _service.putAsset(widget.canvas, bytes, 'pdf');
    final name = result!.files.single.name;

    if (mode == 'attach') {
      c.addAttachment(
        Attachment(
          id: _service.newId(),
          name: name,
          assetId: assetId,
          mime: 'application/pdf',
          addedAt: DateTime.now(),
        ),
      );
      // Visible, tappable chip on the page linking to the file.
      c.addAttachmentChip(assetId, name, 'application/pdf');
      _toast('Added "$name" — tap the chip to open it');
      return;
    }

    final sizes = await c.renderCache.pdfPageSizes(
      _service.assetFile(widget.canvas, assetId).path,
    );
    if (!mounted) return;
    c.insertPdfPages(assetId, sizes, position!);
    _toast('Inserted ${sizes.length} PDF page(s)');
  }

  Future<void> _insertImageFlow() async {
    final result = await FilePicker.platform.pickFiles(type: FileType.image);
    final path = result?.files.single.path;
    if (path == null || !mounted) return;
    final bytes = await File(path).readAsBytes();
    await _placeImageFromFileBytes(bytes, path.split('.').last.toLowerCase());
  }

  /// Captures a photo with the device camera and drops it on the page.
  Future<void> _capturePhotoFlow() async {
    final XFile? shot;
    try {
      shot = await ImagePicker().pickImage(
        source: ImageSource.camera,
        imageQuality: 90,
      );
    } catch (e) {
      _toast('Camera unavailable');
      return;
    }
    if (shot == null || !mounted) return;
    final bytes = await shot.readAsBytes();
    final ext = shot.name.contains('.') ? shot.name.split('.').last : 'jpg';
    await _placeImageFromFileBytes(bytes, ext.toLowerCase());
  }

  /// Stores [bytes] as a content-addressed asset and drops an ImageElement
  /// centered on the current page (scaled to fit). Shared by the file-pick
  /// and camera flows.
  Future<void> _placeImageFromFileBytes(Uint8List bytes, String ext) async {
    final c = _controller!;
    final assetId = await _service.putAsset(widget.canvas, bytes, ext);

    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    final imgW = frame.image.width.toDouble();
    final imgH = frame.image.height.toDouble();
    frame.image.dispose();

    final target = c.currentPageLayout;
    if (target == null || !mounted) return;
    final page = c.pages[target.pageId]!;
    final scale = math.min(
      1.0,
      math.min(page.width * 0.6 / imgW, page.height * 0.6 / imgH),
    );
    final w = imgW * scale, h = imgH * scale;

    _placeImage(
      target,
      ImageElement(
        id: newModelId('el'),
        deviceId: SettingsService().deviceId,
        rect: Rect.fromLTWH(0, 0, w, h), // _placeImage positions it
        assetId: assetId,
      ),
    );
  }

  /// Toggles drawing with a finger (for pen-less use). Rebuild swaps the
  /// gesture map (double-tap zoom off while drawing with fingers).
  Future<void> _toggleFingerDraw() async {
    final s = SettingsService();
    await s.setFingerDraw(!s.fingerDraw);
    if (!mounted) return;
    setState(() {});
    _toast(
      s.fingerDraw
          ? 'Finger drawing on — two fingers to pan/zoom'
          : 'Finger drawing off',
    );
  }

  /// Toggles hold-to-snap shape recognition (pen). Rebuild refreshes the menu
  /// checkbox glyph.
  Future<void> _toggleShapeSnap() async {
    final s = SettingsService();
    await s.setShapeSnap(!s.shapeSnap);
    if (!mounted) return;
    setState(() {});
    _toast(
      s.shapeSnap
          ? 'Shape snapping on — pause mid-stroke to snap'
          : 'Shape snapping off',
    );
  }

  Future<void> _pasteFlow() async {
    final c = _controller!;
    if (CanvasController.clipboardHasContent) {
      c.pasteClipboard();
      return;
    }
    await _pasteFromSystemClipboard();
  }

  Future<void> _pasteSystemText() async {
    final c = _controller!;
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text == null || text.trim().isEmpty || !mounted) {
      _toast('Nothing to paste');
      return;
    }
    final target = c.currentPageLayout;
    if (target == null) return;
    final base = TextRun(
      text: '',
      fontSize: c.textFontSize,
      bold: false,
      italic: false,
      color: c.textColor,
      fontFamily: c.textFontFamily,
    );
    // Markdown arrives as plain text (it has no clipboard flavor of its own):
    // when the strict detector recognizes it, convert to styled runs — the
    // same one-way input conversion Notion does. Ordinary prose never matches.
    if (looksLikeMarkdown(text)) {
      final runs = runsFromMarkdown(text, base);
      if (runs.isNotEmpty) {
        final boxes = c.insertRunsAsText(target.pageId, runs);
        _toast(
          boxes > 1
              ? 'Pasted Markdown as formatted text across $boxes pages'
              : 'Pasted Markdown as formatted text',
        );
        return;
      }
    }
    // Same auto-size + split-across-pages pipeline as the rich paste, with
    // one base-styled run.
    final boxes = c.insertRunsAsText(target.pageId, [base..text = text]);
    if (boxes > 1) _toast('Pasted text across $boxes pages');
  }

  // ── Sheets: page settings, navigator, attachments ────────────────────

  Future<void> _showPageSettings() async {
    final c = _controller!;
    final current = c.currentPageLayout;
    if (current == null) return;
    final page = c.pages[current.pageId]!;
    final settings = SettingsService();
    final originalColor = page.background.color;
    var color = page.background.color;
    var pattern = page.background.pattern;
    var asDefault = false;
    var adjPen = settings.inkAdjustPen;
    var adjHl = settings.inkAdjustHighlighter;
    var adjText = settings.inkAdjustText;

    const presets = [
      Color(0xFFFFFFFF), // white
      Color(0xFFF8F1E3), // cream
      Color(0xFFEDEDED), // light grey
      Color(0xFF2A2A2E), // charcoal
      Color(0xFF17171A), // near black
    ];

    final apply = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (context) => StatefulBuilder(
        builder: (context, setSheetState) {
          // Offer the ink-visibility adjustment only when the picked colour
          // crosses light↔dark relative to the page's current background.
          final crossing =
              isDarkBackground(originalColor) != isDarkBackground(color);
          return scrollableSheetBody(
            context,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const _SheetLabel('Background color'),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      for (final preset in presets)
                        Padding(
                          padding: const EdgeInsets.only(right: 10),
                          child: GestureDetector(
                            onTap: () => setSheetState(() => color = preset),
                            child: Container(
                              width: 36,
                              height: 36,
                              decoration: BoxDecoration(
                                color: preset,
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: color == preset
                                      ? Theme.of(context).colorScheme.primary
                                      : Theme.of(context).dividerColor,
                                  width: color == preset ? 3 : 1,
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  const _SheetLabel('Pattern'),
                  const SizedBox(height: 8),
                  SegmentedButton<BgPattern>(
                    segments: const [
                      ButtonSegment(
                        value: BgPattern.blank,
                        label: Text('Blank'),
                      ),
                      ButtonSegment(
                        value: BgPattern.ruled,
                        label: Text('Ruled'),
                      ),
                      ButtonSegment(value: BgPattern.grid, label: Text('Grid')),
                      ButtonSegment(
                        value: BgPattern.dotted,
                        label: Text('Dotted'),
                      ),
                    ],
                    selected: {pattern},
                    showSelectedIcon: false,
                    onSelectionChanged: (s) =>
                        setSheetState(() => pattern = s.first),
                  ),
                  const SizedBox(height: 16),
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Apply to all pages'),
                    subtitle: const Text(
                      'Changes every page in this canvas now, and becomes the default for new pages',
                    ),
                    value: asDefault,
                    onChanged: (v) =>
                        setSheetState(() => asDefault = v ?? false),
                  ),
                  if (crossing) ...[
                    const SizedBox(height: 8),
                    const Divider(height: 1),
                    const SizedBox(height: 10),
                    const _SheetLabel('Adjust ink so it stays visible'),
                    const SizedBox(height: 4),
                    Text(
                      'Flips the lightness of ink (keeps the colour) so it stays '
                      'readable on the new background.',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).hintColor,
                      ),
                    ),
                    const SizedBox(height: 4),
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      title: const Text('Pen strokes'),
                      value: adjPen,
                      onChanged: (v) =>
                          setSheetState(() => adjPen = v ?? false),
                    ),
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      title: const Text('Highlighter'),
                      value: adjHl,
                      onChanged: (v) => setSheetState(() => adjHl = v ?? false),
                    ),
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      title: const Text('Text'),
                      value: adjText,
                      onChanged: (v) =>
                          setSheetState(() => adjText = v ?? false),
                    ),
                  ],
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: () => Navigator.pop(context, true),
                      child: const Text('Apply'),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );

    if (apply == true) {
      final wasDark = isDarkBackground(originalColor);
      final willBeDark = isDarkBackground(color);
      c.setPageBackground(
        current.pageId,
        PageBackground(color: color, pattern: pattern),
        asSectionDefault: asDefault,
      );
      // Only when the background actually crossed light↔dark and at least one
      // ink type is enabled. Scope matches the "apply to all" choice.
      if (wasDark != willBeDark && (adjPen || adjHl || adjText)) {
        final ids = asDefault ? c.pages.keys.toSet() : {current.pageId};
        c.adjustInkForContrast(
          ids,
          pen: adjPen,
          highlighter: adjHl,
          text: adjText,
        );
      }
      await settings.setInkAdjustPrefs(
        pen: adjPen,
        highlighter: adjHl,
        text: adjText,
      );
    }
  }

  Future<void> _showNavigator() async {
    final c = _controller!;
    await Navigator.of(context).push(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => PageOrganizer(
          controller: c,
          onJump: (pageId) => c.jumpToPage(pageId),
        ),
      ),
    );
  }

  Future<void> _showBookmarks() async {
    final c = _controller!;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) => cappedSheetBody(
        context,
        child: ListenableBuilder(
          listenable: c,
          builder: (context, _) {
            final items = c.canvas.bookmarks;
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(height: 8),
                const _SheetLabel('Bookmarks'),
                ListTile(
                  leading: const Icon(Icons.bookmark_add_outlined),
                  title: const Text('Bookmark this page'),
                  onTap: () async {
                    final ordinal = c.pageOrdinalOf(
                      c.currentPageLayout?.pageId ?? '',
                    );
                    final name = await _promptText(
                      title: 'New bookmark',
                      initial: ordinal != null ? 'Page $ordinal' : 'Bookmark',
                      cta: 'Add',
                    );
                    if (name == null || name.isEmpty) return;
                    c.addBookmarkHere(name);
                  },
                ),
                const Divider(height: 1),
                if (items.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(24),
                    child: Text('No bookmarks yet'),
                  )
                else
                  Flexible(
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: items.length,
                      itemBuilder: (context, i) {
                        final bm = items[i];
                        final ordinal = c.pageOrdinalOf(bm.pageId);
                        return ListTile(
                          leading: const Icon(Icons.bookmark_outline),
                          title: Text(bm.name),
                          subtitle: ordinal != null
                              ? Text('Page $ordinal')
                              : null,
                          onTap: () {
                            Navigator.pop(context);
                            c.jumpToBookmark(bm);
                          },
                          trailing: IconButton(
                            icon: const Icon(Icons.delete_outline, size: 20),
                            tooltip: 'Remove bookmark',
                            onPressed: () => c.removeBookmark(bm),
                          ),
                        );
                      },
                    ),
                  ),
                const SizedBox(height: 8),
              ],
            );
          },
        ),
      ),
    );
  }

  /// Small shared one-line text prompt.
  Future<String?> _promptText({
    required String title,
    String initial = '',
    String cta = 'OK',
  }) {
    final controller = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          textCapitalization: TextCapitalization.sentences,
          onSubmitted: (v) => Navigator.pop(context, v.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: Text(cta),
          ),
        ],
      ),
    );
  }

  Future<void> _showAttachments() async {
    final c = _controller!;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) => cappedSheetBody(
        context,
        child: ListenableBuilder(
          listenable: c,
          builder: (context, _) {
            final items = c.canvas.attachments;
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(height: 8),
                const _SheetLabel('Attachments'),
                if (items.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(24),
                    child: Text('No attachments yet'),
                  )
                else
                  Flexible(
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: items.length,
                      itemBuilder: (context, i) {
                        final att = items[i];
                        final isPdf = att.mime == 'application/pdf';
                        return ListTile(
                          leading: Icon(
                            isPdf
                                ? Icons.picture_as_pdf_outlined
                                : Icons.attach_file,
                          ),
                          title: Text(att.name),
                          trailing: PopupMenuButton<String>(
                            onSelected: (action) async {
                              if (action == 'open') {
                                final f = _service.assetFile(
                                  widget.canvas,
                                  att.assetId,
                                );
                                if (await f.exists()) {
                                  OpenFilex.open(f.path, type: att.mime);
                                }
                              } else if (action == 'insert' && isPdf) {
                                Navigator.pop(context);
                                final sizes = await c.renderCache.pdfPageSizes(
                                  _service
                                      .assetFile(widget.canvas, att.assetId)
                                      .path,
                                );
                                c.insertPdfPages(
                                  att.assetId,
                                  sizes,
                                  InsertPosition.end,
                                );
                              } else if (action == 'remove') {
                                c.removeAttachment(att);
                              }
                            },
                            itemBuilder: (context) => [
                              const PopupMenuItem(
                                value: 'open',
                                child: Text('Open'),
                              ),
                              if (isPdf)
                                const PopupMenuItem(
                                  value: 'insert',
                                  child: Text('Insert with view'),
                                ),
                              const PopupMenuItem(
                                value: 'remove',
                                child: Text('Remove'),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
                const SizedBox(height: 8),
              ],
            );
          },
        ),
      ),
    );
  }

  /// Opens the small floating audio player (the replacement for the old
  /// Recordings bottom sheet). If there are no recordings yet, just hints —
  /// there'd be nothing to show.
  void _openAudioPlayer() {
    final c = _controller;
    if (c == null) return;
    if (c.canvas.recordings.isEmpty) {
      _toast('No recordings yet');
      return;
    }
    setState(() => _audioPlayerOpen = true);
  }

  /// Closes the floating player and stops any playback.
  void _closeAudioPlayer() {
    _controller?.audioPlayback.stop();
    if (mounted) setState(() => _audioPlayerOpen = false);
  }

  /// Starts (or resumes) playback of [rec], guarding against a not-yet-synced
  /// audio asset.
  Future<void> _playRecording(CanvasController c, AudioRecording rec) async {
    final file = c.assetFileOf(rec.assetId);
    if (!await file.exists()) {
      _toast('Audio not available yet (still syncing?)');
      return;
    }
    await c.audioPlayback.play(
      rec.id,
      file.path,
      total: Duration(milliseconds: rec.durationMs),
    );
  }

  Future<void> _renameRecording(CanvasController c, AudioRecording rec) async {
    final name = await _promptText(
      title: 'Rename recording',
      initial: rec.name,
      cta: 'Rename',
    );
    if (name != null && name.isNotEmpty) c.renameRecording(rec, name);
  }

  void _deleteRecording(CanvasController c, AudioRecording rec) {
    if (c.audioPlayback.isCurrent(rec.id)) c.audioPlayback.stop();
    c.deleteRecording(rec);
    // Nothing left to show — close the player.
    if (c.canvas.recordings.isEmpty) _closeAudioPlayer();
  }

  // ── Export ───────────────────────────────────────────────────────────

  Future<void> _exportPdf() async {
    final c = _controller!;
    await c.flushSaves();
    if (!mounted) return;

    // Non-modal progress; the PDF builds on a background isolate so the canvas
    // stays interactive. Empty outline → no bookmarks (same as a plain
    // single-canvas export).
    final banner = ProgressOverlay.show(context, 'Exporting PDF…');

    try {
      final bytes = await exportPdfInIsolate([
        PdfExportItem(
          outline: const [],
          canvas: widget.canvas,
          pages: c.pages,
          assetBytes: (assetId) =>
              _service.assetFile(widget.canvas, assetId).readAsBytes(),
          assetPath: (assetId) =>
              _service.assetFile(widget.canvas, assetId).path,
        ),
      ], onProgress: (fraction, label) => banner.report(fraction, label));
      banner.close();
      if (!mounted) return;

      final fileName =
          '${widget.canvas.name.replaceAll(RegExp(r'[<>:"/\\|?*]'), '_')}.pdf';
      final savedPath = await FilePicker.platform.saveFile(
        dialogTitle: 'Save PDF',
        fileName: fileName,
        type: FileType.custom,
        allowedExtensions: ['pdf'],
        bytes: bytes,
      );
      if (savedPath == null) return; // user cancelled

      // Desktop pickers return a path without writing the bytes.
      final f = File(savedPath);
      if (!await f.exists() || await f.length() == 0) {
        await f.writeAsBytes(bytes);
      }
      _toast('Exported to $savedPath');
    } catch (err) {
      banner.close();
      _toast('Export failed: $err');
    }
  }

  Future<void> _renameCanvas() async {
    final controller = TextEditingController(text: widget.canvas.name);
    controller.selection = TextSelection(
      baseOffset: 0,
      extentOffset: widget.canvas.name.length,
    );
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Rename'),
        content: TextField(
          controller: controller,
          autofocus: true,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(hintText: 'Name'),
          onSubmitted: (v) => Navigator.pop(context, v.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Rename'),
          ),
        ],
      ),
    );
    if (name == null || name.isEmpty || !mounted) return;
    await _service.renameCanvas(widget.canvas, name);
    setState(() {}); // refresh the app-bar title
    widget.onCanvasRenamed?.call();
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
    );
  }

  // ── Voice recording ────────────────────────────────────────────────────

  Future<void> _startAudioRecording() async {
    final c = _controller;
    if (c == null || c.isRecordingAudio) return;
    final ok = await c.startAudioRecording();
    if (!ok) _toast('Microphone permission is needed to record');
  }

  Future<void> _stopAudioRecording(CanvasController c) async {
    final rec = await c.stopAudioRecording();
    if (rec != null) _toast('Recording saved');
  }

  // ── Build ────────────────────────────────────────────────────────────

  void _toggleFullScreen() {
    setState(() {
      _isFullScreen = !_isFullScreen;
      _fullScreenPickerOpen = false;
    });
    _controller?.closeToolOptions();
    // Desktop host: collapse/expand its side panes to match, so full screen
    // truly fills the window.
    widget.onFullScreenChanged?.call(_isFullScreen);
  }

  // ── Desktop top toolbar (all tools inline, grouped; right-aligns when it
  //    fits, scrolls when it doesn't — see AdaptiveToolbarRow) ────────────
  // tbBtn/tbDivider now live in canvas_toolbar/canvas_chrome_shared.dart.

  /// Renders one promoted action id as a `tbBtn`. Dispatch, not data: a few
  /// ids (toggle_toolbar/shape_snap/finger_draw) show state-dependent icons,
  /// which is why this can't just read [findActionSpec]'s static icon.
  /// Rebuilt whenever `_CanvasScreenState.build()` reruns — `_showToolbar`'s
  /// own setState and `_toggleShapeSnap`/`_toggleFingerDraw`'s setState
  /// already cover that, so no extra listening is needed here.
  Widget _buildPromotedButton(String id) {
    switch (id) {
      case 'undo':
        final c = _controller;
        if (c == null) return const SizedBox.shrink();
        // Own narrow listener — canUndo flips on every op without a screen
        // setState. Keeping it per-button (not one wrapper around the whole
        // row) is the load-bearing perf rule for the desktop toolbar.
        return ListenableBuilder(
          listenable: c,
          builder: (context, _) =>
              tbBtn(Icons.undo, 'Undo', c.canUndo ? c.undo : null),
        );
      case 'redo':
        final c = _controller;
        if (c == null) return const SizedBox.shrink();
        return ListenableBuilder(
          listenable: c,
          builder: (context, _) =>
              tbBtn(Icons.redo, 'Redo', c.canRedo ? c.redo : null),
        );
      case 'add':
        return _buildAddButton(context);
      case 'blank':
        return tbBtn(
          Icons.note_add_outlined,
          'Add page',
          () => _runAddAction('blank'),
        );
      case 'horizontal':
        return tbBtn(
          Icons.swap_horiz,
          'Horizontal page',
          () => _runAddAction('horizontal'),
        );
      case 'pdf':
        return tbBtn(
          Icons.picture_as_pdf_outlined,
          'Insert PDF',
          () => _runAddAction('pdf'),
        );
      case 'image':
        return tbBtn(
          Icons.image_outlined,
          'Insert image',
          () => _runAddAction('image'),
        );
      case 'paste':
        return tbBtn(
          Icons.content_paste,
          'Paste',
          () => _runAddAction('paste'),
        );
      case 'fullscreen':
        return tbBtn(Icons.fullscreen, 'Full screen', _toggleFullScreen);
      case 'toggle_toolbar':
        return tbBtn(
          _showToolbar ? Icons.expand_less : Icons.brush_outlined,
          _showToolbar ? 'Hide tools' : 'Show tools',
          () => setState(() => _showToolbar = !_showToolbar),
        );
      case 'rename':
        return tbBtn(Icons.edit_outlined, 'Rename', _renameCanvas);
      case 'export':
        return tbBtn(Icons.picture_as_pdf_outlined, 'Export PDF', _exportPdf);
      case 'navigator':
        return tbBtn(Icons.grid_view_outlined, 'Pages', _showNavigator);
      case 'bookmarks':
        return tbBtn(Icons.bookmark_border, 'Bookmarks', _showBookmarks);
      case 'attachments':
        return tbBtn(Icons.attach_file, 'Attachments', _showAttachments);
      case 'page_settings':
        return tbBtn(
          Icons.description_outlined,
          'Page settings',
          _showPageSettings,
        );
      case 'shape_snap':
        return tbBtn(
          SettingsService().shapeSnap
              ? Icons.check_box_outlined
              : Icons.check_box_outline_blank,
          'Snap drawn shapes',
          _toggleShapeSnap,
        );
      case 'finger_draw':
        return tbBtn(
          SettingsService().fingerDraw
              ? Icons.check_box_outlined
              : Icons.check_box_outline_blank,
          'Draw with finger',
          _toggleFingerDraw,
        );
      case 'record_audio':
        final c = _controller;
        if (c == null) return const SizedBox.shrink();
        // Own narrow listener (not the static cluster): turns red while
        // recording; the floating bar owns Stop, so tapping it again mid-record
        // is a harmless no-op.
        return ValueListenableBuilder<bool>(
          valueListenable: c.isRecordingAudioNotifier,
          builder: (context, recording, _) => tbBtn(
            recording ? Icons.mic : Icons.mic_none,
            recording ? 'Recording…' : 'Record audio',
            _startAudioRecording,
            color: recording ? const Color(0xFFE5484D) : null,
          ),
        );
      case 'recordings':
        return tbBtn(Icons.graphic_eq, 'Recordings', _openAudioPlayer);
      case 'split':
        // Only meaningful inside a workspace (split host); empty elsewhere.
        if (widget.onSplitRequested == null) return const SizedBox.shrink();
        return tbBtn(Icons.vertical_split_outlined, 'Open canvas alongside',
            widget.onSplitRequested);
      default:
        return const SizedBox.shrink();
    }
  }

  /// Mobile top bar: like the desktop toolbar, the name is a fixed box on the
  /// left (always visible) and the controls live in a right-aligned,
  /// horizontally-scrollable row — so a long name never hides and promoted
  /// tools scroll instead of overflowing.
  Widget _buildMobileToolbar(
    BuildContext context,
    CanvasController c,
    AppPalette palette,
  ) {
    final s = SettingsService();
    return Row(
      children: [
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 130),
          child: Text(
            widget.canvas.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w500),
          ),
        ),
        const SizedBox(width: 4),
        Expanded(
          child: AdaptiveToolbarRow(
            children: [
              // One unified promoted list (undo/redo/+/add/overflow actions in
              // the user's chosen order), then the fixed sync icon + "⋯" — the
              // same structure as desktop, so the two layouts read the same.
              for (final id in s.promotedToolbarMobile)
                _buildPromotedButton(id),
              const SyncStatusIcon(),
              _buildOverflowMenu(context),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildDesktopToolbar(
    BuildContext context,
    CanvasController c,
    AppPalette palette,
  ) {
    final s = SettingsService();
    // Rendered in the AppBar's flexibleSpace (not `title`) so it spans the
    // full pane width — the `title` slot is narrower, which left-clustered
    // the tools with dead space on the right. The name is a fixed-max-width
    // box (NOT Flexible): a Flexible here defaults to flex:1 and would split
    // the row 50/50 with the Expanded tools, halving the tools' width.
    return Row(
      children: [
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 220),
          child: Text(
            widget.canvas.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
          ),
        ),
        const SizedBox(width: 12),
        // The tool cluster is STATIC except for each button's own scoped
        // listener (undo/redo wrap themselves in a ListenableBuilder inside
        // _buildPromotedButton) — wrapping the whole row in one
        // ListenableBuilder on the controller rebuilt ~25 widgets on every pen
        // move, the desktop-view fast-writing jank this was fixed for. Keep new
        // controller-dependent controls inside their own smallest-possible
        // listener, never around the row.
        Expanded(
          child: AdaptiveToolbarRow(
            children: [
              // One unified promoted list (undo/redo/+/add/overflow actions in
              // the user's chosen order), then the fixed sync icon + "⋯" — the
              // same structure as mobile.
              for (final id in s.promotedToolbarDesktop)
                _buildPromotedButton(id),
              tbDivider(palette),
              const SyncStatusIcon(),
              _buildOverflowMenu(context),
            ],
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = _controller;
    final theme = Theme.of(context);
    final palette = theme.extension<AppPalette>()!;

    if (c == null) {
      return Scaffold(
        appBar: AppBar(title: Text(widget.canvas.name)),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    if (_isFullScreen) {
      return Scaffold(
        backgroundColor: palette.canvas,
        body: Stack(
          children: [
            Positioned.fill(child: _buildCanvasArea(c, palette)),
            Positioned(
              top: 12,
              right: 12,
              child: FloatingIconButton(
                icon: Icons.fullscreen_exit,
                tooltip: 'Exit full screen',
                onTap: _toggleFullScreen,
              ),
            ),
            Positioned(
              left: 16,
              bottom: 16,
              // Same narrow-notifier set as _ToolOptionsPanel — was
              // ListenableBuilder(listenable: c), which is "accidentally
              // cheap" only while collapsed to one icon; drawing with the
              // context row open (or the full-screen tool picker open) would
              // otherwise rebuild on every stroke point too.
              child: ListenableBuilder(
                listenable: Listenable.merge([
                  c.toolNotifier,
                  c.toolOptionsOpenNotifier,
                  c.hasSelectionNotifier,
                  c.isEditingTextNotifier,
                  c.clipboardNotifier,
                  c.chromeContentTick,
                ]),
                builder: (context, _) =>
                    _buildFloatingToolControl(context, c, palette),
              ),
            ),
          ],
        ),
      );
    }

    final mobile = _useMobileMenus(context);
    // Split-view panes inject their own leading: a close-pane "×" for a
    // secondary pane, or a back arrow for the primary embedded pane (which has
    // no route of its own to pop).
    final paneLeading = _paneLeading();
    return Scaffold(
      backgroundColor: palette.canvas,
      appBar: AppBar(
        titleSpacing: 0,
        // Mobile keeps the automatic back button (pushed as its own route);
        // desktop is embedded, no leading — unless a split pane supplies one.
        leading: paneLeading,
        automaticallyImplyLeading: mobile && paneLeading == null,
        title: null,
        // Both layouts render the whole toolbar in flexibleSpace (full width)
        // so the name stays fixed on the left and the controls scroll /
        // right-align on the right. Left-pad to clear the leading button.
        flexibleSpace: SafeArea(
          child: Padding(
            padding: EdgeInsets.only(
                left: (mobile || paneLeading != null) ? 52 : 10, right: 10),
            child: Align(
              alignment: Alignment.centerLeft,
              child: SizedBox(
                width: double.infinity,
                child: mobile
                    ? _buildMobileToolbar(context, c, palette)
                    : _buildDesktopToolbar(context, c, palette),
              ),
            ),
          ),
        ),
      ),
      body: Column(
        children: [
          // Only the fixed tool row lives in the column. Toggling the whole
          // toolbar (app-bar button) is a deliberate action, so its reflow is
          // fine — but the per-tool OPTIONS panel opens/closes constantly, so
          // it floats over the canvas (below) instead of resizing it.
          AnimatedSize(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOut,
            alignment: Alignment.topCenter,
            child: _showToolbar
                ? _CanvasToolbar(controller: c)
                : const SizedBox(width: double.infinity),
          ),
          Expanded(
            child: Stack(
              children: [
                Positioned.fill(child: _buildCanvasArea(c, palette)),
                // Tool-options panel: overlaid at the top of the canvas so
                // showing/hiding it never moves the canvas viewport. Hidden
                // entirely while the toolbar is toggled off. Pen/highlighter/
                // shape/eraser/lasso/text all opt out here (all include* flags
                // false) — they show as a drop-down popover / floating-near-
                // selection menu / bottom bar instead (ToolOptionsPopover /
                // LassoFloatingMenu / TextBottomBar), so this panel currently
                // renders nothing and is kept only as the shared overlay slot.
                if (_showToolbar)
                  Positioned(
                    top: 0,
                    left: 0,
                    right: 0,
                    child: _ToolOptionsPanel(controller: c),
                  ),
                if (_showToolbar) LassoFloatingMenu(controller: c),
                if (_showToolbar)
                  TextBottomBar(key: _textBarKey, controller: c),
                // Pen/highlighter/shape/eraser options, dropping down under
                // the active tool's icon (re-tap to open, or pinned).
                if (_showToolbar) ToolOptionsPopover(controller: c),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// The pannable/zoomable canvas: pointer routing, gesture recognizers, the
  /// painted content, and the text-edit overlay. Shared by the normal layout
  /// (below the app bar + toolbar) and full screen (filling the whole
  /// Scaffold behind the floating controls).
  /// Desktop keyboard shortcuts. Only while NOT editing text — the editing
  /// TextField owns its own keys (incl. Ctrl+C/V inside the box).
  KeyEventResult _onCanvasKey(FocusNode node, KeyEvent event) {
    final c = _controller;
    if (c == null || _textEdit != null) return KeyEventResult.ignored;
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final ctrl =
        HardwareKeyboard.instance.isControlPressed ||
        HardwareKeyboard.instance.isMetaPressed; // Cmd on macOS
    final key = event.logicalKey;

    if (ctrl) {
      switch (key) {
        case LogicalKeyboardKey.keyV:
          c.pasteClipboard(); // internal → OS image → OS text
          return KeyEventResult.handled;
        case LogicalKeyboardKey.keyC:
          if (c.selection.isNotEmpty) c.copySelection();
          return KeyEventResult.handled;
        case LogicalKeyboardKey.keyX:
          if (c.selection.isNotEmpty) c.cutSelection();
          return KeyEventResult.handled;
        case LogicalKeyboardKey.keyD:
          if (c.selection.isNotEmpty) c.duplicateSelection();
          return KeyEventResult.handled;
        case LogicalKeyboardKey.keyZ:
          HardwareKeyboard.instance.isShiftPressed ? c.redo() : c.undo();
          return KeyEventResult.handled;
        case LogicalKeyboardKey.keyY:
          c.redo();
          return KeyEventResult.handled;
      }
    } else if (key == LogicalKeyboardKey.delete ||
        key == LogicalKeyboardKey.backspace) {
      if (c.selection.isNotEmpty) {
        c.deleteSelection();
        return KeyEventResult.handled;
      }
    } else if (key == LogicalKeyboardKey.escape) {
      if (c.selection.isNotEmpty) {
        c.clearSelection();
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }

  Widget _buildCanvasArea(CanvasController c, AppPalette palette) {
    return ClipRect(
      child: LayoutBuilder(
        builder: (context, constraints) {
          c.setScreenSize(constraints.biggest);
          return Focus(
            focusNode: _canvasFocus,
            onKeyEvent: _onCanvasKey,
            child: Listener(
              onPointerDown: _onPointerDown,
              onPointerMove: _onPointerMove,
              onPointerUp: _onPointerUp,
              onPointerCancel: _onPointerCancel,
              onPointerSignal: _onPointerSignal,
              behavior: HitTestBehavior.opaque,
              child: RawGestureDetector(
                gestures: {
                  ScaleGestureRecognizer:
                      GestureRecognizerFactoryWithHandlers<
                        ScaleGestureRecognizer
                      >(
                        () => ScaleGestureRecognizer(
                          supportedDevices: {
                            PointerDeviceKind.touch,
                            PointerDeviceKind.trackpad,
                          },
                        ),
                        (r) => r
                          ..onStart = _onScaleStart
                          ..onUpdate = _onScaleUpdate
                          ..onEnd = _onScaleEnd,
                      ),
                  // Touch double-tap = fit page width — but not in finger-draw
                  // mode, where two quick taps are two ink dots, not a zoom.
                  if (!SettingsService().fingerDraw)
                    DoubleTapGestureRecognizer:
                        GestureRecognizerFactoryWithHandlers<
                          DoubleTapGestureRecognizer
                        >(
                          () => DoubleTapGestureRecognizer(
                            supportedDevices: {PointerDeviceKind.touch},
                          ),
                          (r) => r..onDoubleTapDown = _onDoubleTapDown,
                        ),
                },
                child: Stack(
                  children: [
                    SizedBox.expand(
                      // Boundary lets "copy selection" capture the rendered
                      // pixels for the OS clipboard.
                      child: RepaintBoundary(
                        key: _canvasBoundaryKey,
                        child: CustomPaint(
                          painter: CanvasPainter(
                            controller: c,
                            pageBorderColor: palette.border,
                            accentColor: palette.accent,
                            canvasTextColor: palette.textDim,
                          ),
                        ),
                      ),
                    ),
                    if (_textEdit != null) _buildTextEditOverlay(c),
                    // Floating voice-recording bar (both normal + full screen,
                    // since this area is shared). Overlaid, so recording never
                    // shifts the canvas; the user keeps drawing while it runs.
                    Positioned(
                      top: 8,
                      left: 0,
                      right: 0,
                      child: ValueListenableBuilder<bool>(
                        valueListenable: c.isRecordingAudioNotifier,
                        builder: (context, recording, _) => recording
                            ? Align(
                                alignment: Alignment.topCenter,
                                child: _RecordingBar(
                                  startedAt: c.audioRecordingStartedAt,
                                  onStop: () => _stopAudioRecording(c),
                                  onCancel: () => c.cancelAudioRecording(),
                                ),
                              )
                            : const SizedBox.shrink(),
                      ),
                    ),
                    // Floating audio player (replaces the Recordings sheet).
                    // Bottom-center so it clears the top recording bar and the
                    // full-screen tool control at bottom-left.
                    if (_audioPlayerOpen)
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: 12,
                        child: Align(
                          alignment: Alignment.bottomCenter,
                          child: _AudioPlayerBar(
                            controller: c,
                            onPlay: (rec) => _playRecording(c, rec),
                            onRename: (rec) => _renameRecording(c, rec),
                            onDelete: (rec) => _deleteRecording(c, rec),
                            onClose: _closeAudioPlayer,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  /// Full-screen's minimal floating tool control: collapsed to the active
  /// tool's icon; tapping it reveals the 5-tool picker row; tapping the
  /// already-active tool within that row opens its options panel (same
  /// content as the normal toolbar's context row) — mirroring "tap the
  /// selected tool again to see its options" everywhere, not just here.
  Widget _buildFloatingToolControl(
    BuildContext context,
    CanvasController c,
    AppPalette palette,
  ) {
    // Same visibility rule as the normal toolbar (an exception like an active
    // selection stays visible even if toolOptionsOpen is false), computed
    // once here so both modes can never disagree.
    final contextRow = buildToolContextRow(context, c, palette);
    if (contextRow != null) {
      return FloatingPanel(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ToolIconButton(
              tool: c.tool,
              active: true,
              onTap: () => c.setTool(c.tool), // re-tap: close options
            ),
            const SizedBox(height: 8),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 300),
              child: contextRow,
            ),
          ],
        ),
      );
    }

    if (_fullScreenPickerOpen) {
      return FloatingPanel(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final tool in kCanvasToolOrder)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                child: ToolIconButton(
                  tool: tool,
                  active: c.tool == tool,
                  onTap: () {
                    c.setTool(tool);
                    setState(() => _fullScreenPickerOpen = false);
                  },
                ),
              ),
          ],
        ),
      );
    }

    return FloatingPanel(
      child: ToolIconButton(
        tool: c.tool,
        active: true,
        onTap: () => setState(() => _fullScreenPickerOpen = true),
      ),
    );
  }

  Widget _buildTextEditOverlay(CanvasController c) {
    final session = _textEdit!;
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        final el = session.element;
        final rect = c.pageScreenRect(session.pageId, el.rect);
        // Lay the editor out in PAGE POINTS at scale 1 — identical metrics to
        // the painter's TextPainter — and scale the whole overlay visually by
        // zoom (Transform.scale below). Laying out at fontSize×zoom instead
        // made glyph advances round differently from the painter's, so the
        // editor wrapped lines at different words than the committed text.
        session.controller.displayScale = 1.0;
        // RenderEditable wraps its text `cursorWidth + 1` (its caret margin)
        // narrower than the field width — widen the field by exactly that so
        // the EFFECTIVE wrap width equals el.rect.width, the same width the
        // painter lays out at. Without this the editor broke lines a few
        // points earlier than the committed text. Left-aligned text only:
        // widening a center/right-aligned field would shift the text sideways
        // by (part of) the margin, which is worse than the slightly-early
        // wrap it avoids.
        final cursorWidth = 2 / c.zoom;
        final caretExtra = el.align == TextAlignOption.left
            ? cursorWidth + 1
            : 0.0;
        // Width in page points (the Transform scales it to rect.width on
        // screen). This must track el.rect.width EXACTLY: a `max(..., 60/zoom)`
        // floor used to widen the field past the element for small/empty boxes,
        // so the editor wrapped at a different width than the painter and the
        // border no longer hugged the box.
        final boxWidth = el.rect.width;
        return Positioned(
          left: rect.left,
          top: rect.top,
          width: boxWidth + caretExtra,
          child: Transform.scale(
            scale: c.zoom,
            alignment: Alignment.topLeft,
            child: Material(
              color: Colors.transparent,
              child: Stack(
                // Clip.none is load-bearing: the border below is deliberately
                // OUTSET past this Stack's bounds (negative left/top/bottom) so
                // it brackets the text instead of covering it. Stack clips to
                // its own size by default (Clip.hardEdge), which erased the
                // outset left/top/bottom edges and left only the right one
                // visible — the "text box is barely there" bug.
                clipBehavior: Clip.none,
                children: [
                  // SizedBox is load-bearing: the Stack hands its
                  // non-positioned children LOOSE constraints, under which
                  // the field can size to its own intrinsics and lose the
                  // caret-margin width compensation (observed on-device as a
                  // ~3px-narrower wrap). Tight width restores the invariant:
                  // field width == boxWidth + caretExtra, text wraps at
                  // exactly boxWidth like the painter.
                  SizedBox(
                    width: boxWidth + caretExtra,
                    // The canvas is a document: the painter draws text at its
                    // absolute point size (TextPainter never system-scales),
                    // so the editor must too — otherwise a non-default OS
                    // font-size setting makes text visibly grow/shrink
                    // (and re-wrap) on commit.
                    child: MediaQuery.withNoTextScaling(
                      // Intercept paste so an image on the clipboard lands in
                      // the document instead of being silently dropped. The
                      // field owns Ctrl/Cmd+V while it has focus (the canvas's
                      // own shortcut handler bails out entirely while editing),
                      // and Flutter's default paste reads text/plain only — so
                      // pasting an image while typing did nothing at all.
                      // Overriding the intent catches BOTH the keyboard and the
                      // built-in context-menu Paste. Text still takes the
                      // default path untouched.
                      child: Actions(
                        actions: {
                          PasteTextIntent: CallbackAction<PasteTextIntent>(
                            onInvoke: (intent) {
                              unawaited(_handleEditorPaste(intent.cause));
                              return null;
                            },
                          ),
                        },
                        child: TextField(
                          controller: session.controller,
                          autofocus: true,
                          maxLines: null,
                        // Counter the Transform: ~2px caret at any zoom (also
                        // feeds the caret-margin width compensation above).
                        cursorWidth: cursorWidth,
                        cursorColor: Theme.of(context).colorScheme.primary,
                        // Base style in page points (per-run styles come from
                        // buildTextSpan; the Transform provides the zoom).
                        // `inherit: false` is load-bearing: TextField merges
                        // the theme's bodyLarge UNDER its style, and any field
                        // we leave null inherits from it — its letterSpacing
                        // 0.5 made editor glyphs wider than the painter's, and
                        // its explicit fontFamily 'Roboto' can resolve to a
                        // DIFFERENT face than the painter's null→engine-default
                        // family (e.g. Samsung system-font substitution), which
                        // re-wraps lines during editing. With inherit false the
                        // merge returns this style verbatim, so every unset
                        // field falls back to the same engine defaults the
                        // painter's TextPainter uses — parity by construction.
                        style: editorBaseStyle(el),
                        // No strut — the painter's TextPainter has none, so the
                        // editor must not either. With strutStyle null,
                        // EditableText applies
                        // `StrutStyle.fromTextStyle(style, forceStrutHeight:
                        // true)`, which forces EVERY line to the BASE style's
                        // height (el.fontSize × 1.3) no matter what sizes the
                        // runs on that line actually use. A box mixing sizes
                        // (or one whose size changed after creation, leaving
                        // el.fontSize stale) then laid out with crushed line
                        // spacing while editing and sprang back on commit.
                        // StrutStyle.disabled survives EditableText's
                        // inheritFromTextStyle (its explicit height 0.0 wins
                        // over the base style's), so lines size to their own
                        // content exactly like the painter's.
                        strutStyle: StrutStyle.disabled,
                        textAlign: switch (el.align) {
                          TextAlignOption.center => TextAlign.center,
                          TextAlignOption.right => TextAlign.right,
                          _ => TextAlign.left,
                        },
                        decoration: const InputDecoration(
                          isDense: true,
                          // Zero padding so the text area matches the box width
                          // exactly (the painter draws text flush at the rect's
                          // top-left too).
                          contentPadding: EdgeInsets.zero,
                          // EVERY border slot must be cleared, not just
                          // `border`. InputDecoration.applyDefaults falls back
                          // to the theme PER SLOT (`focusedBorder ??
                          // theme.focusedBorder`), and this field is always
                          // autofocused — so with only `border` set, the app
                          // theme's focusedBorder (an OutlineInputBorder) still
                          // applied. Material then adds that border's
                          // `gapPadding` (4.0) to contentPadding on BOTH sides
                          // (InputDecorator's `inputGap`, Material 3 only),
                          // which shifted the editor's text 4pt right and cut
                          // 8pt off its wrap width — so the editor broke lines
                          // at different words than the painter, and the
                          // theme's accent outline was drawn on top of our own
                          // border. Zero-width borders here keep inputGap 0.
                          border: InputBorder.none,
                          enabledBorder: InputBorder.none,
                          focusedBorder: InputBorder.none,
                          disabledBorder: InputBorder.none,
                          errorBorder: InputBorder.none,
                          focusedErrorBorder: InputBorder.none,
                          filled: false,
                        ),
                          onTapOutside: (_) => _commitTextEdit(),
                        ),
                      ),
                    ),
                  ),
                  // The border sits on ITS OWN box at exactly the element's
                  // width — not on the (caret-margin-widened) field — so it
                  // hugs the text like the lasso selection box. IgnorePointer
                  // keeps taps flowing to the field.
                  //
                  // It's OUTSET by its own stroke width on every side so it
                  // brackets the text rather than painting over it (Border.all
                  // strokes INSIDE its box, and the text starts flush at x=0),
                  // and extends kTextBoxPad further down because the field is
                  // only as tall as its text while el.rect adds that pad. The
                  // outset only renders because the Stack above sets
                  // Clip.none — without it these edges are clipped away.
                  Positioned(
                    left: -kEditBorderStroke / c.zoom,
                    top: -kEditBorderStroke / c.zoom,
                    bottom: -kTextBoxPad - (kEditBorderStroke / c.zoom),
                    width: boxWidth + (2 * kEditBorderStroke / c.zoom),
                    child: IgnorePointer(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          border: Border.all(
                            color: Theme.of(context).colorScheme.primary,
                            // Counter the Transform: a constant ~1.5px at any
                            // zoom, matching the lasso selection box's stroke.
                            width: kEditBorderStroke / c.zoom,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _TextEditSession {
  final String pageId;
  final TextElement element;
  final TextElement before;
  final bool isNew;
  final RichTextController controller;

  /// The selection at the previous editing notification. Used to tell a
  /// caret/selection *move* (which should adopt the surrounding text's style
  /// as the typing style) apart from a style-only change at the same caret
  /// (which must NOT clobber the just-applied typing style).
  TextSelection? lastSelection;

  _TextEditSession({
    required this.pageId,
    required this.element,
    required this.before,
    required this.isNew,
    required this.controller,
  });
}

// ── Toolbar ────────────────────────────────────────────────────────────
// kCanvasToolOrder, iconForTool/labelForTool, ToolIconButton, FloatingPanel,
// FloatingIconButton now live in canvas_toolbar/canvas_chrome_shared.dart.
// buildToolContextRow and every per-tool options row (pen/shape/eraser/
// lasso/text) now live in canvas_toolbar/tool_option_rows.dart.

// ToolIconButton, FloatingIconButton, FloatingPanel now live in
// canvas_toolbar/canvas_chrome_shared.dart.

class _CanvasToolbar extends StatelessWidget {
  final CanvasController controller;

  const _CanvasToolbar({required this.controller});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = theme.extension<AppPalette>()!;

    // Only the active tool matters here — listen to the narrow toolNotifier,
    // not the whole controller, so a fast pen stroke's per-point
    // notifyListeners() (see updateToolGesture) never rebuilds this row.
    return ValueListenableBuilder<CanvasTool>(
      valueListenable: controller.toolNotifier,
      builder: (context, activeTool, _) {
        return Container(
          width: double.infinity,
          decoration: BoxDecoration(
            color: theme.colorScheme.surface,
            border: Border(bottom: BorderSide(color: palette.border)),
          ),
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
          // Fixed height: just the tool icon row. Pen/highlighter/shape/
          // eraser options drop down under the active tool (ToolOptionsPopover
          // in the canvas Stack); lasso/text use their own floating menu / bar.
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (final tool in kCanvasToolOrder)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 2),
                    child: ToolIconButton(
                      tool: tool,
                      active: activeTool == tool,
                      onTap: () => controller.setTool(tool),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// The per-tool contextual options (colors/size/eraser mode/selection actions/
/// text style). Rendered as a **floating overlay** pinned to the top of the
/// canvas — showing/hiding it animates the panel itself (slide + fade) without
/// ever changing the canvas viewport's size, so the canvas never jumps when
/// options open or close.
class _ToolOptionsPanel extends StatelessWidget {
  final CanvasController controller;

  const _ToolOptionsPanel({required this.controller});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = theme.extension<AppPalette>()!;

    // buildToolContextRow reads tool/toolOptionsOpen/selection/isEditingText/
    // clipboard state — none of which change on a stroke's per-point
    // notifyListeners() (see updateToolGesture) — plus chromeContentTick for
    // in-place content refreshes (a color/size pick) while already open. This
    // merge deliberately excludes the whole controller so drawing doesn't
    // rebuild this panel every sampled point.
    return ListenableBuilder(
      listenable: Listenable.merge([
        controller.toolNotifier,
        controller.toolOptionsOpenNotifier,
        controller.hasSelectionNotifier,
        controller.isEditingTextNotifier,
        controller.clipboardNotifier,
        controller.chromeContentTick,
      ]),
      builder: (context, _) {
        final contextRow = buildToolContextRow(
          context,
          controller,
          palette,
          includePopoverTools: false,
          includeLassoRow: false,
          includeTextRow: false,
        );
        return AnimatedSwitcher(
          duration: const Duration(milliseconds: 180),
          switchInCurve: Curves.easeOutCubic,
          switchOutCurve: Curves.easeInCubic,
          transitionBuilder: (child, animation) => FadeTransition(
            opacity: animation,
            child: SizeTransition(
              sizeFactor: animation,
              axisAlignment: -1,
              child: child,
            ),
          ),
          child: contextRow == null
              ? const SizedBox(
                  key: ValueKey('opts-none'),
                  width: double.infinity,
                )
              // Opaque Listener: the panel floats over the canvas, so it must
              // swallow pointer-downs itself — otherwise a tap on the panel
              // (a swatch, or an empty gap) would fall through to the canvas
              // Listener behind it and close the panel mid-interaction.
              : Listener(
                  key: const ValueKey('opts-panel'),
                  behavior: HitTestBehavior.opaque,
                  onPointerDown: (_) {},
                  child: Container(
                    width: double.infinity,
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surface,
                      border: Border(bottom: BorderSide(color: palette.border)),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withAlpha(28),
                          blurRadius: 12,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                    child: contextRow,
                  ),
                ),
        );
      },
    );
  }
}

// _HintRow, _SelAction, _ToggleChip, _ColorDot, _WheelDot now live in
// canvas_toolbar/tool_option_rows.dart (private to that file).

/// Floating pill shown while a voice recording runs: a pulsing red dot, a live
/// elapsed timer, and Stop / discard controls. Overlaid on the canvas so the
/// user keeps drawing (audio-sync uses each stroke's createdAt).
class _RecordingBar extends StatefulWidget {
  final DateTime? startedAt;
  final VoidCallback onStop;
  final VoidCallback onCancel;

  const _RecordingBar({
    required this.startedAt,
    required this.onStop,
    required this.onCancel,
  });

  @override
  State<_RecordingBar> createState() => _RecordingBarState();
}

class _RecordingBarState extends State<_RecordingBar>
    with SingleTickerProviderStateMixin {
  Timer? _tick;
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat(reverse: true);

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    _pulse.dispose();
    super.dispose();
  }

  String _elapsed() {
    final started = widget.startedAt;
    if (started == null) return '0:00';
    final s = DateTime.now().difference(started).inSeconds;
    final m = s ~/ 60;
    return '$m:${(s % 60).toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final palette = Theme.of(context).extension<AppPalette>()!;
    return Material(
      color: Colors.transparent,
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 6, 6, 6),
        decoration: BoxDecoration(
          color: palette.surface2,
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: palette.border),
          boxShadow: const [
            BoxShadow(
              color: Color(0x33000000),
              blurRadius: 12,
              offset: Offset(0, 4),
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            FadeTransition(
              opacity: _pulse,
              child: Container(
                width: 10,
                height: 10,
                decoration: const BoxDecoration(
                  color: Color(0xFFE5484D),
                  shape: BoxShape.circle,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              _elapsed(),
              style: TextStyle(
                fontFeatures: const [ui.FontFeature.tabularFigures()],
                fontWeight: FontWeight.w600,
                color: Theme.of(context).colorScheme.onSurface,
              ),
            ),
            const SizedBox(width: 4),
            IconButton(
              tooltip: 'Discard',
              visualDensity: VisualDensity.compact,
              icon: Icon(Icons.close, size: 20, color: palette.textDim),
              onPressed: widget.onCancel,
            ),
            FilledButton.icon(
              onPressed: widget.onStop,
              style: FilledButton.styleFrom(
                backgroundColor: palette.accent,
                foregroundColor: Colors.black,
                padding: const EdgeInsets.symmetric(horizontal: 14),
                visualDensity: VisualDensity.compact,
              ),
              icon: const Icon(Icons.stop, size: 18),
              label: const Text('Stop'),
            ),
          ],
        ),
      ),
    );
  }
}

String _fmtDuration(Duration d) {
  final m = d.inMinutes;
  final s = d.inSeconds % 60;
  return '$m:${s.toString().padLeft(2, '0')}';
}

/// The small, non-distracting floating audio player (replaces the old
/// Recordings bottom sheet). A compact panel over the canvas: a recording
/// picker (also holding rename/delete), a scrubber with quick ±10s skips,
/// play/pause, a cycling speed chip, and a close button. All controls read the
/// controller's [AudioPlaybackService] notifiers, so it stays in sync whether
/// playback was started here or elsewhere.
class _AudioPlayerBar extends StatelessWidget {
  final CanvasController controller;

  /// Starts (or resumes) playback of a recording — guards the not-yet-synced
  /// asset case, so it lives on the screen (owns the toast).
  final void Function(AudioRecording rec) onPlay;
  final void Function(AudioRecording rec) onRename;
  final void Function(AudioRecording rec) onDelete;
  final VoidCallback onClose;

  const _AudioPlayerBar({
    required this.controller,
    required this.onPlay,
    required this.onRename,
    required this.onDelete,
    required this.onClose,
  });

  static const List<double> _speeds = [0.75, 1.0, 1.25, 1.5, 2.0];

  @override
  Widget build(BuildContext context) {
    final palette = Theme.of(context).extension<AppPalette>()!;
    final playback = controller.audioPlayback;
    return Material(
      color: Colors.transparent,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 340),
        child: Container(
          padding: const EdgeInsets.fromLTRB(8, 6, 6, 8),
          decoration: BoxDecoration(
            color: palette.surface2,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: palette.border),
            boxShadow: const [
              BoxShadow(
                color: Color(0x33000000),
                blurRadius: 12,
                offset: Offset(0, 4),
              ),
            ],
          ),
          // Rebuild the whole panel on any recording change (rename/delete) and
          // on the current-take change (name + which one is active).
          child: ListenableBuilder(
            listenable: controller,
            builder: (context, _) {
              final recs = controller.canvas.recordings;
              return ValueListenableBuilder<String?>(
                valueListenable: playback.currentId,
                builder: (context, currentId, _) {
                  AudioRecording? current;
                  for (final r in recs) {
                    if (r.id == currentId) {
                      current = r;
                      break;
                    }
                  }
                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _topRow(context, palette, recs, current),
                      _scrubberRow(context, palette, current, recs),
                    ],
                  );
                },
              );
            },
          ),
        ),
      ),
    );
  }

  // Recording picker (name + dropdown of takes with rename/delete) + close.
  Widget _topRow(
    BuildContext context,
    AppPalette palette,
    List<AudioRecording> recs,
    AudioRecording? current,
  ) {
    return Row(
      children: [
        Expanded(
          child: PopupMenuButton<({String op, AudioRecording rec})>(
            tooltip: 'Choose recording',
            onSelected: (sel) {
              switch (sel.op) {
                case 'play':
                  onPlay(sel.rec);
                case 'rename':
                  onRename(sel.rec);
                case 'delete':
                  onDelete(sel.rec);
              }
            },
            itemBuilder: (context) => [
              for (final r in recs)
                PopupMenuItem<({String op, AudioRecording rec})>(
                  value: (op: 'play', rec: r),
                  child: Row(
                    children: [
                      Icon(
                        r.id == current?.id
                            ? Icons.graphic_eq
                            : Icons.play_arrow,
                        size: 18,
                        color: palette.textDim,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(r.name, overflow: TextOverflow.ellipsis),
                      ),
                      IconButton(
                        icon: const Icon(Icons.edit_outlined, size: 18),
                        tooltip: 'Rename',
                        visualDensity: VisualDensity.compact,
                        onPressed: () =>
                            Navigator.pop(context, (op: 'rename', rec: r)),
                      ),
                      IconButton(
                        icon: const Icon(Icons.delete_outline, size: 18),
                        tooltip: 'Delete',
                        visualDensity: VisualDensity.compact,
                        onPressed: () =>
                            Navigator.pop(context, (op: 'delete', rec: r)),
                      ),
                    ],
                  ),
                ),
            ],
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
              child: Row(
                children: [
                  Icon(Icons.graphic_eq, size: 18, color: palette.accent),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      current?.name ?? 'Choose recording',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                  Icon(Icons.arrow_drop_down, color: palette.textDim),
                ],
              ),
            ),
          ),
        ),
        IconButton(
          icon: Icon(Icons.close, size: 20, color: palette.textDim),
          tooltip: 'Close player',
          visualDensity: VisualDensity.compact,
          onPressed: onClose,
        ),
      ],
    );
  }

  // Time + slider + skip / play / speed controls.
  Widget _scrubberRow(
    BuildContext context,
    AppPalette palette,
    AudioRecording? current,
    List<AudioRecording> recs,
  ) {
    final playback = controller.audioPlayback;
    // Play/pause acts on the current take, or starts the first one.
    void togglePlay(bool playing) {
      if (current == null) {
        if (recs.isNotEmpty) onPlay(recs.first);
        return;
      }
      if (playing) {
        playback.pause();
      } else {
        onPlay(current);
      }
    }

    return ValueListenableBuilder<Duration>(
      valueListenable: playback.duration,
      builder: (context, total, _) => ValueListenableBuilder<Duration>(
        valueListenable: playback.position,
        builder: (context, pos, _) {
          final maxMs = total.inMilliseconds > 0
              ? total.inMilliseconds
              : (current?.durationMs ?? 1);
          final value = pos.inMilliseconds.clamp(0, maxMs).toDouble();
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Text(_fmtDuration(pos),
                      style: TextStyle(fontSize: 11, color: palette.textDim)),
                  Expanded(
                    child: SliderTheme(
                      data: SliderTheme.of(context).copyWith(
                        trackHeight: 2,
                        thumbShape: const RoundSliderThumbShape(
                            enabledThumbRadius: 6),
                        overlayShape: const RoundSliderOverlayShape(
                            overlayRadius: 12),
                      ),
                      child: Slider(
                        value: value,
                        max: maxMs.toDouble().clamp(1, double.infinity),
                        onChanged: (v) =>
                            playback.seek(Duration(milliseconds: v.round())),
                      ),
                    ),
                  ),
                  Text(_fmtDuration(Duration(milliseconds: maxMs)),
                      style: TextStyle(fontSize: 11, color: palette.textDim)),
                ],
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  IconButton(
                    icon: const Icon(Icons.replay_10),
                    tooltip: 'Back 10s',
                    visualDensity: VisualDensity.compact,
                    onPressed: () =>
                        playback.skip(const Duration(seconds: -10)),
                  ),
                  ValueListenableBuilder<bool>(
                    valueListenable: playback.playing,
                    builder: (context, playing, _) => IconButton(
                      icon: Icon(
                        playing
                            ? Icons.pause_circle_filled
                            : Icons.play_circle_fill,
                        size: 40,
                        color: palette.accent,
                      ),
                      onPressed: () => togglePlay(playing),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.forward_10),
                    tooltip: 'Forward 10s',
                    visualDensity: VisualDensity.compact,
                    onPressed: () =>
                        playback.skip(const Duration(seconds: 10)),
                  ),
                  const SizedBox(width: 4),
                  ValueListenableBuilder<double>(
                    valueListenable: playback.speed,
                    builder: (context, speed, _) => TextButton(
                      style: TextButton.styleFrom(
                        minimumSize: const Size(44, 32),
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        foregroundColor: palette.textDim,
                      ),
                      onPressed: () {
                        final i = _speeds.indexOf(speed);
                        final next = _speeds[(i + 1) % _speeds.length];
                        playback.setSpeed(next);
                      },
                      child: Text(
                        '${_trimSpeed(speed)}×',
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          );
        },
      ),
    );
  }

  static String _trimSpeed(double s) {
    final str = s.toStringAsFixed(2);
    return str.replaceAll(RegExp(r'\.?0+$'), '');
  }
}

class _SheetLabel extends StatelessWidget {
  final String text;
  const _SheetLabel(this.text);

  @override
  Widget build(BuildContext context) {
    final palette = Theme.of(context).extension<AppPalette>()!;
    return Align(
      alignment: Alignment.centerLeft,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
        child: Text(
          text.toUpperCase(),
          style: TextStyle(
            fontFamily: 'monospace',
            fontSize: 11,
            letterSpacing: 0.8,
            fontWeight: FontWeight.w600,
            color: palette.textDim,
          ),
        ),
      ),
    );
  }
}
