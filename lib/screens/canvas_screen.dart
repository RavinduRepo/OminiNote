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
import '../widgets/color_wheel_picker.dart';
import '../widgets/sync_status_icon.dart';
import 'page_organizer.dart';

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

  const CanvasScreen({
    super.key,
    required this.canvas,
    this.onCanvasRenamed,
    this.initialPageId,
    this.embedded = false,
    this.onFullScreenChanged,
  });

  @override
  State<CanvasScreen> createState() => _CanvasScreenState();
}

class _CanvasScreenState extends State<CanvasScreen> {
  final _service = NotebookService();
  CanvasController? _controller;
  bool _showToolbar = true;

  // Full screen: hides the app bar + normal toolbar, replaced by a floating
  // exit button and a collapsed tool control (see _buildFloatingToolControl).
  bool _isFullScreen = false;
  bool _fullScreenPickerOpen = false;

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

  /// Captures the rendered canvas so "copy selection" can put pixels on the
  /// OS clipboard.
  final GlobalKey _canvasBoundaryKey = GlobalKey();

  /// Keyboard focus for canvas shortcuts (Ctrl+C/V/X/Z/Y/D, Delete, Esc).
  final FocusNode _canvasFocus = FocusNode(debugLabel: 'canvas-shortcuts');

  @override
  void initState() {
    super.initState();
    _load();
    // Close this view if its notebook is moved to another account or deleted on
    // another device (its notebooks.json entry is tombstoned here). Only when
    // pushed as its own route — the desktop host clears its selection instead.
    if (!widget.embedded) {
      SyncService().dataVersion.addListener(_onSyncData);
    }
  }

  bool _closing = false;

  Future<void> _onSyncData() async {
    if (_closing || !mounted) return;
    final nb = await _service.getNotebook(widget.canvas.notebookId);
    if (nb != null || _closing || !mounted) return; // still here — nothing to do
    _closing = true;
    // The whole notebook is gone (moved/deleted), so the section + notebook
    // screens beneath this canvas are stale too — pop all the way back to the
    // notebooks list, not just one level.
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    if (navigator.canPop()) {
      navigator.popUntil((route) => route.isFirst);
      messenger.showSnackBar(const SnackBar(
        content: Text('This notebook was moved or deleted on another device.'),
        behavior: SnackBarBehavior.floating,
      ));
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
    final uniform = runs.every((r) =>
        r.fontSize == first.fontSize &&
        r.bold == first.bold &&
        r.italic == first.italic &&
        r.fontFamily == first.fontFamily &&
        r.link == null);
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
    _toast(
      boxes > 1 ? 'Pasted $what across $boxes pages' : 'Pasted $what',
    );
    return boxes > 0;
  }

  /// Decodes [bytes], stores them as an asset, and drops an ImageElement
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
    c.addImageBelowInk(
      target.pageId,
      ImageElement(
        id: newModelId('el'),
        deviceId: SettingsService().deviceId,
        rect: Rect.fromCenter(
          center: Offset(page.width / 2, page.height / 2),
          width: w,
          height: h,
        ),
        assetId: assetId,
      ),
    );
    _toast('Image pasted');
  }

  @override
  void dispose() {
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
    // canvas interaction.
    final session = _textEdit;
    if (session != null) {
      final editorRect = c
          .pageScreenRect(session.pageId, session.element.rect)
          .inflate(12);
      if (editorRect.contains(e.localPosition)) {
        _pointerInTextEditor = true; // swallow the matching pointer-up too
        return;
      }
      _commitTextEdit();
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
        c.toggleCheckboxAt(cb.$1, cb.$2.id, cb.$3);
        return;
      }
      // A tap directly on a link opens it, regardless of tool (the blue
      // underlined text is the affordance). Tapping elsewhere falls through.
      final url = _urlAt(e.localPosition);
      if (url != null) {
        _openUrl(url);
        return;
      }
      if (c.tool == CanvasTool.text) {
        // In the text tool a tap on an attachment opens it (single tap);
        // otherwise edit an existing box / create a new one.
        final att = _attachmentAt(e.localPosition);
        if (att != null) {
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
      final isDouble = _lastTapTime != null &&
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

  void _handleTextTap(Offset screenPos) {
    final c = _controller!;
    final canvasPos = c.screenToCanvas(screenPos);
    final pageLayout = c.layout.pageAt(canvasPos);
    if (pageLayout == null) return;
    final page = c.pages[pageLayout.pageId]!;
    final local = canvasPos - pageLayout.rect.topLeft;

    // Tap an existing text element → edit it.
    for (final el in [...page.strokes, ...page.objects].reversed) {
      if (el is TextElement && el.rect.inflate(4).contains(local)) {
        _startTextEdit(page.id, el, isNew: false);
        return;
      }
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
    _startTextEdit(page.id, el, isNew: true);
  }

  void _startTextEdit(String pageId, TextElement el, {required bool isNew}) {
    final c = _controller!;
    c.clearSelection(notify: false);
    final rc = RichTextController(
      text: el.text,
      attrs: attrsFromElement(el),
      defaults: defaultAttrOf(el),
    );
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
    c.textColor = display.color; // text's own color slot, whatever tool is active
    _remeasureEditing();
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
        final rel =
            math.min(math.max(caret - fitLen, 0), targetEl.text.length);
        _commitTextEdit();
        c.jumpToPage(targetPageId);
        _startTextEdit(targetPageId, targetEl, isNew: false);
        _textEdit?.controller.selection =
            TextSelection.collapsed(offset: rel);
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
      if (!session.isNew) c.removeElement(session.pageId, session.before);
      setState(() {});
      return;
    }

    if (session.isNew) {
      c.addElement(session.pageId, el);
    } else {
      c.updateTextElement(session.pageId, session.before, el);
    }
    setState(() {});
  }

  // ── App-bar overflow (sheet on mobile, popup on desktop) ─────────────

  /// Sheet menus when pushed as its own screen (the mobile shell); popup menus
  /// when embedded in the desktop split-view. `embedded` is the exact signal.
  bool _useMobileMenus(BuildContext context) => !widget.embedded;

  Widget _buildOverflowMenu(BuildContext context) {
    final palette = Theme.of(context).extension<AppPalette>()!;
    if (_useMobileMenus(context)) {
      return IconButton(
        icon: Icon(Icons.more_vert, color: palette.textDim),
        tooltip: 'More',
        onPressed: () => showActionSheet(context, items: [
          ActionSheetItem(
              icon: Icons.fullscreen,
              label: 'Full screen',
              onTap: _toggleFullScreen),
          ActionSheetItem(
              icon: _showToolbar ? Icons.expand_less : Icons.brush_outlined,
              label: _showToolbar ? 'Hide tools' : 'Show tools',
              onTap: () => setState(() => _showToolbar = !_showToolbar)),
          ActionSheetItem(
              icon: Icons.edit_outlined,
              label: 'Rename',
              onTap: _renameCanvas),
          ActionSheetItem(
              icon: Icons.picture_as_pdf_outlined,
              label: 'Export PDF',
              onTap: _exportPdf),
          ActionSheetItem(
              icon: Icons.grid_view_outlined,
              label: 'Pages',
              onTap: _showNavigator),
          ActionSheetItem(
              icon: Icons.bookmark_border,
              label: 'Bookmarks',
              onTap: _showBookmarks),
          ActionSheetItem(
              icon: Icons.attach_file,
              label: 'Attachments',
              onTap: _showAttachments),
          ActionSheetItem(
              icon: Icons.description_outlined,
              label: 'Page settings',
              onTap: _showPageSettings),
          ActionSheetItem(
              icon: SettingsService().shapeSnap
                  ? Icons.check_box_outlined
                  : Icons.check_box_outline_blank,
              label: 'Snap drawn shapes',
              onTap: _toggleShapeSnap),
          ActionSheetItem(
              icon: SettingsService().fingerDraw
                  ? Icons.check_box_outlined
                  : Icons.check_box_outline_blank,
              label: 'Draw with finger',
              onTap: _toggleFingerDraw),
        ]),
      );
    }
    return PopupMenuButton<String>(
      onSelected: (action) {
        switch (action) {
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
        }
      },
      itemBuilder: (context) => [
        iconMenuItem('rename', Icons.edit_outlined, 'Rename'),
        iconMenuItem('export', Icons.picture_as_pdf_outlined, 'Export PDF'),
        iconMenuItem('navigator', Icons.grid_view_outlined, 'Pages'),
        iconMenuItem('bookmarks', Icons.bookmark_border, 'Bookmarks'),
        iconMenuItem('attachments', Icons.attach_file, 'Attachments'),
        iconMenuItem('page_settings', Icons.description_outlined,
            'Page settings'),
        // Checkbox glyphs reflect toggle state, matching the mobile sheet.
        iconMenuItem(
            'shape_snap',
            SettingsService().shapeSnap
                ? Icons.check_box_outlined
                : Icons.check_box_outline_blank,
            'Snap drawn shapes'),
        iconMenuItem(
            'finger_draw',
            SettingsService().fingerDraw
                ? Icons.check_box_outlined
                : Icons.check_box_outline_blank,
            'Draw with finger'),
      ],
    );
  }

  // ── Add / insert flows ───────────────────────────────────────────────

  Future<void> _showAddSheet() async {
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
              ListTile(
                leading: const Icon(Icons.note_add_outlined),
                title: const Text('Blank page'),
                subtitle: const Text('Above · below · or at the end'),
                onTap: () => Navigator.pop(context, 'blank'),
              ),
              ListTile(
                leading: const Icon(Icons.swap_horiz),
                title: const Text('Horizontal page'),
                subtitle: const Text('Extend this row to the right'),
                onTap: () => Navigator.pop(context, 'horizontal'),
              ),
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
              ListTile(
                leading: const Icon(Icons.content_paste),
                title: const Text('Paste'),
                onTap: () => Navigator.pop(context, 'paste'),
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
    }
  }

  /// The Add control: a bottom sheet on mobile, a top-bar dropdown on desktop.
  Widget _buildAddButton(BuildContext context) {
    if (_useMobileMenus(context)) {
      return IconButton(
        icon: const Icon(Icons.add),
        tooltip: 'Add',
        onPressed: _showAddSheet,
      );
    }
    // Desktop: the frequently-used adds (Add page, Image) are direct top-bar
    // buttons (see the app bar); this "+" holds the rest.
    return PopupMenuButton<String>(
      icon: const Icon(Icons.add),
      tooltip: 'More to add',
      onSelected: _runAddAction,
      itemBuilder: (context) => [
        iconMenuItem('horizontal', Icons.swap_horiz, 'Horizontal page'),
        iconMenuItem('pdf', Icons.picture_as_pdf_outlined, 'Insert PDF'),
        if (PageClipboard().hasPage.value)
          iconMenuItem('pastePage', Icons.content_paste_go_outlined,
              'Paste page'),
        iconMenuItem('paste', Icons.content_paste, 'Paste'),
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

    c.addImageBelowInk(
      target.pageId,
      ImageElement(
        id: newModelId('el'),
        deviceId: SettingsService().deviceId,
        rect: Rect.fromCenter(
          center: Offset(page.width / 2, page.height / 2),
          width: w,
          height: h,
        ),
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
                    ButtonSegment(value: BgPattern.blank, label: Text('Blank')),
                    ButtonSegment(value: BgPattern.ruled, label: Text('Ruled')),
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
                  onChanged: (v) => setSheetState(() => asDefault = v ?? false),
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
                    onChanged: (v) => setSheetState(() => adjPen = v ?? false),
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
                    onChanged: (v) => setSheetState(() => adjText = v ?? false),
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
        final ids = asDefault
            ? c.pages.keys.toSet()
            : {current.pageId};
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
      final bytes = await exportPdfInIsolate(
        [
          PdfExportItem(
            outline: const [],
            canvas: widget.canvas,
            pages: c.pages,
            assetBytes: (assetId) =>
                _service.assetFile(widget.canvas, assetId).readAsBytes(),
            assetPath: (assetId) =>
                _service.assetFile(widget.canvas, assetId).path,
          ),
        ],
        onProgress: (fraction, label) => banner.report(fraction, label),
      );
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

  // ── Desktop top toolbar (all tools inline, grouped, horizontally scrollable
  //    so a narrow window never overflows) ────────────────────────────────

  Widget _tbBtn(IconData icon, String tooltip, VoidCallback? onPressed) =>
      IconButton(
        icon: Icon(icon, size: 20),
        tooltip: tooltip,
        visualDensity: VisualDensity.compact,
        constraints: const BoxConstraints(minWidth: 38, minHeight: 44),
        padding: EdgeInsets.zero,
        onPressed: onPressed,
      );

  Widget _tbDivider(AppPalette palette) => Container(
        width: 1,
        height: 20,
        margin: const EdgeInsets.symmetric(horizontal: 6),
        color: palette.border,
      );

  Widget _buildDesktopToolbar(
      BuildContext context, CanvasController c, AppPalette palette) {
    return Row(
      children: [
        Flexible(
          child: Text(
            widget.canvas.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
          ),
        ),
        const SizedBox(width: 12),
        // The whole tool cluster scrolls horizontally — a shrunk window scrolls
        // instead of overflowing. The cluster is STATIC: only the undo/redo
        // pair listens to the drawing controller, and the paste-page button
        // listens to the clipboard notifier. Wrapping the whole row in one
        // ListenableBuilder on the controller rebuilt ~25 widgets (buttons +
        // tooltips + scroll view) on every pen move — the desktop-view
        // fast-writing jank; mobile's app bar only ever rebuilt its undo/redo
        // pair, which is why it stayed smooth. Keep new controller-dependent
        // controls inside their own smallest-possible listener, never around
        // the row.
        Expanded(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            reverse: true, // right-align the tools; scroll on a narrow window
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListenableBuilder(
                  listenable: c,
                  builder: (context, _) => Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _tbBtn(Icons.undo, 'Undo', c.canUndo ? c.undo : null),
                      _tbBtn(Icons.redo, 'Redo', c.canRedo ? c.redo : null),
                    ],
                  ),
                ),
                _tbDivider(palette),
                _tbBtn(Icons.note_add_outlined, 'Add page',
                    () => _runAddAction('blank')),
                _tbBtn(Icons.swap_horiz, 'Horizontal page',
                    () => _runAddAction('horizontal')),
                _tbBtn(Icons.image_outlined, 'Insert image',
                    () => _runAddAction('image')),
                _tbBtn(Icons.picture_as_pdf_outlined, 'Insert PDF',
                    () => _runAddAction('pdf')),
                _tbBtn(Icons.content_paste, 'Paste',
                    () => _runAddAction('paste')),
                ValueListenableBuilder<bool>(
                  valueListenable: PageClipboard().hasPage,
                  builder: (context, hasPage, _) => hasPage
                      ? _tbBtn(Icons.content_paste_go_outlined, 'Paste page',
                          () => _runAddAction('pastePage'))
                      : const SizedBox.shrink(),
                ),
                _tbDivider(palette),
                _tbBtn(Icons.fullscreen, 'Full screen', _toggleFullScreen),
                _tbBtn(
                    _showToolbar ? Icons.expand_less : Icons.brush_outlined,
                    _showToolbar ? 'Hide tools' : 'Show tools',
                    () => setState(() => _showToolbar = !_showToolbar)),
                _tbDivider(palette),
                const SyncStatusIcon(),
                _buildOverflowMenu(context),
              ],
            ),
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
              child: _FloatingIconButton(
                icon: Icons.fullscreen_exit,
                tooltip: 'Exit full screen',
                onTap: _toggleFullScreen,
              ),
            ),
            Positioned(
              left: 16,
              bottom: 16,
              child: ListenableBuilder(
                listenable: c,
                builder: (context, _) =>
                    _buildFloatingToolControl(context, c, palette),
              ),
            ),
          ],
        ),
      );
    }

    final mobile = _useMobileMenus(context);
    return Scaffold(
      backgroundColor: palette.canvas,
      appBar: AppBar(
        titleSpacing: mobile ? null : 10,
        title: mobile
            ? Text(widget.canvas.name)
            : _buildDesktopToolbar(context, c, palette),
        actions: mobile
            ? [
                const SyncStatusIcon(),
                ListenableBuilder(
                  listenable: c,
                  builder: (context, _) => Row(
                    children: [
                      IconButton(
                        icon: const Icon(Icons.undo),
                        tooltip: 'Undo',
                        onPressed: c.canUndo ? c.undo : null,
                      ),
                      IconButton(
                        icon: const Icon(Icons.redo),
                        tooltip: 'Redo',
                        onPressed: c.canRedo ? c.redo : null,
                      ),
                    ],
                  ),
                ),
                _buildAddButton(context),
                _buildOverflowMenu(context),
                const SizedBox(width: 4),
              ]
            : null,
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
                // entirely while the toolbar is toggled off.
                if (_showToolbar)
                  Positioned(
                    top: 0,
                    left: 0,
                    right: 0,
                    child: _ToolOptionsPanel(controller: c),
                  ),
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
    final contextRow = _buildToolContextRow(context, c, palette);
    if (contextRow != null) {
      return _FloatingPanel(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _ToolIconButton(
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
      return _FloatingPanel(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final tool in kCanvasToolOrder)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                child: _ToolIconButton(
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

    return _FloatingPanel(
      child: _ToolIconButton(
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
        session.controller.displayScale = c.zoom; // scale per-run sizes
        return Positioned(
          left: rect.left,
          top: rect.top,
          width: math.max(rect.width, 60),
          child: Material(
            color: Colors.transparent,
            child: Container(
              // foregroundDecoration paints the border *over* the child without
              // insetting it — so the TextField keeps the full box width and
              // wraps at the same width the painter/autoTextRect measured. A
              // bordered `decoration` (which insets by the border width) plus
              // content padding made the live editor narrower than the box,
              // wrapping the first line early then snapping back on commit.
              foregroundDecoration: BoxDecoration(
                border: Border.all(
                  color: Theme.of(context).colorScheme.primary,
                ),
              ),
              child: TextField(
                controller: session.controller,
                autofocus: true,
                maxLines: null,
                cursorColor: Theme.of(context).colorScheme.primary,
                // Fallback style (per-run styles come from buildTextSpan).
                style: textStyleForElement(
                  el,
                ).copyWith(fontSize: el.fontSize * c.zoom),
                textAlign: switch (el.align) {
                  TextAlignOption.center => TextAlign.center,
                  TextAlignOption.right => TextAlign.right,
                  _ => TextAlign.left,
                },
                decoration: const InputDecoration(
                  isDense: true,
                  // Zero padding so the text area matches the box width exactly
                  // (the painter draws text flush at the rect's top-left too).
                  contentPadding: EdgeInsets.zero,
                  border: InputBorder.none,
                  filled: false,
                ),
                onTapOutside: (_) => _commitTextEdit(),
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

/// The 5 tools, in the order they're always presented.
const List<CanvasTool> kCanvasToolOrder = [
  CanvasTool.pen,
  CanvasTool.highlighter,
  CanvasTool.eraser,
  CanvasTool.lasso,
  CanvasTool.text,
];

const List<Color> _presetColors = [
  Color(0xFFD9553B),
  Color(0xFF17171A),
  Color(0xFFD98A2B),
  Color(0xFF2E9E5B),
  Color(0xFF3B7DD8),
  Color(0xFF7C5CBF),
  Color(0xFF2AA5B5),
  Color(0xFFFFFFFF),
];

IconData _iconForTool(CanvasTool tool) => switch (tool) {
  CanvasTool.pen => Icons.draw_outlined,
  CanvasTool.highlighter => Icons.highlight_outlined,
  CanvasTool.eraser => Icons.auto_fix_normal_outlined,
  CanvasTool.lasso => Icons.gesture,
  CanvasTool.text => Icons.text_fields,
};

String _labelForTool(CanvasTool tool) => switch (tool) {
  CanvasTool.pen => 'Pen',
  CanvasTool.highlighter => 'Highlighter',
  CanvasTool.eraser => 'Eraser',
  CanvasTool.lasso => 'Lasso select',
  CanvasTool.text => 'Text',
};

/// Builds the active tool's contextual panel (colors/size, selection
/// actions, text style), or `null` when nothing should show. Shared by the
/// normal toolbar and the full-screen floating tool control so both reveal
/// options identically: only on a deliberate re-tap of the already-active
/// tool (`CanvasController.setTool` toggles `toolOptionsOpen`), except for
/// panels that reflect something already in progress — actively editing
/// text, a text box selected via lasso, or an active lasso
/// selection/clipboard — which stay visible regardless, the same way the
/// normal toolbar always showed them before this panel became collapsible.
Widget? _buildToolContextRow(
  BuildContext context,
  CanvasController c,
  AppPalette palette,
) {
  if (c.isEditingText || c.selectionIsTextOnly) {
    return _buildTextStyleRow(context, c, palette);
  }
  if (c.tool == CanvasTool.lasso &&
      (c.selection.isNotEmpty || CanvasController.clipboardHasContent)) {
    return _buildLassoActionRow(context, c, palette);
  }

  if (!c.toolOptionsOpen) return null;

  switch (c.tool) {
    case CanvasTool.pen:
    case CanvasTool.highlighter:
      return _buildPenOptionsRow(context, c, palette);
    case CanvasTool.eraser:
      return _buildEraserOptionsRow(context, c, palette);
    case CanvasTool.lasso:
      // Hint + Paste (the row handles the empty-selection state itself).
      return _buildLassoActionRow(context, c, palette);
    case CanvasTool.text:
      return _buildTextStyleRow(context, c, palette);
  }
}

Widget _buildEraserOptionsRow(
  BuildContext context,
  CanvasController c,
  AppPalette palette,
) {
  return Row(
    children: [
      SegmentedButton<bool>(
        showSelectedIcon: false,
        style: const ButtonStyle(
          visualDensity: VisualDensity.compact,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
        segments: const [
          ButtonSegment(
            value: false,
            label: Text('Stroke'),
            tooltip: 'Erase whole strokes',
          ),
          ButtonSegment(
            value: true,
            label: Text('Partial'),
            tooltip: 'Erase only where you rub',
          ),
        ],
        selected: {c.eraserPartial},
        onSelectionChanged: (sel) {
          c.eraserPartial = sel.first;
          SettingsService().setEraserPrefs(partial: sel.first);
          c.notifyRepaint();
        },
      ),
      Container(
        width: 1,
        height: 24,
        margin: const EdgeInsets.symmetric(horizontal: 8),
        color: palette.border,
      ),
      _ThicknessPreview(
        color: palette.textDim,
        size: c.eraserSize.clamp(4, 40),
        min: 4,
        max: 40,
      ),
      SizedBox(
        width: 110,
        child: Slider(
          value: c.eraserSize.clamp(4, 40),
          min: 4,
          max: 40,
          divisions: 18,
          label: c.eraserSize.toStringAsFixed(0),
          onChanged: (v) {
            c.eraserSize = v;
            SettingsService().setEraserPrefs(size: v);
            c.notifyRepaint();
          },
        ),
      ),
    ],
  );
}

Widget _buildPenOptionsRow(
  BuildContext context,
  CanvasController c,
  AppPalette palette,
) {
  return Row(
    children: [
      Flexible(
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              for (final preset in _presetColors)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 3),
                  child: _ColorDot(
                    color: preset,
                    selected: preset.toARGB32() == c.color.toARGB32(),
                    ringColor: palette.accent,
                    borderColor: palette.border,
                    onTap: () {
                      c.color = preset;
                      c.notifyRepaint();
                    },
                  ),
                ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 3),
                child: _WheelDot(
                  current: c.color,
                  selected: _presetColors
                      .every((p) => p.toARGB32() != c.color.toARGB32()),
                  ringColor: palette.accent,
                  onPicked: (color) {
                    c.color = color;
                    c.notifyRepaint();
                  },
                ),
              ),
            ],
          ),
        ),
      ),
      Container(
        width: 1,
        height: 24,
        margin: const EdgeInsets.symmetric(horizontal: 8),
        color: palette.border,
      ),
      _ThicknessPreview(color: c.color, size: c.strokeSize, min: 1, max: 20),
      SizedBox(
        width: 110,
        child: Slider(
          value: c.strokeSize,
          min: 1,
          max: 20,
          divisions: 19,
          label: c.strokeSize.toStringAsFixed(0),
          onChanged: (v) {
            c.strokeSize = v;
            c.notifyRepaint();
          },
        ),
      ),
    ],
  );
}

/// The mockup's thickness "preview": a chip holding a dot whose diameter tracks
/// the current stroke size, tinted with the tool's color (grey for the eraser).
class _ThicknessPreview extends StatelessWidget {
  final Color color;
  final double size;
  final double min;
  final double max;

  const _ThicknessPreview({
    required this.color,
    required this.size,
    required this.min,
    required this.max,
  });

  @override
  Widget build(BuildContext context) {
    final palette = Theme.of(context).extension<AppPalette>()!;
    final t = ((size - min) / (max - min)).clamp(0.0, 1.0);
    final d = 4 + t * 18; // 4..22px
    return Container(
      width: 34,
      height: 34,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: palette.surface2,
        border: Border.all(color: palette.border),
        borderRadius: BorderRadius.circular(kRadius),
      ),
      child: Container(
        width: d,
        height: d,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      ),
    );
  }
}

Widget _buildLassoActionRow(
  BuildContext context,
  CanvasController c,
  AppPalette palette,
) {
  if (c.selection.isEmpty) {
    return Row(
      children: [
        Expanded(
          child: _HintRow(
            icon: Icons.gesture,
            text: 'Draw around items to select them',
            palette: palette,
          ),
        ),
        // Always available: internal clipboard first, else the OS clipboard
        // (image, then text).
        TextButton.icon(
          onPressed: c.pasteClipboard,
          icon: const Icon(Icons.content_paste, size: 16),
          label: const Text('Paste'),
        ),
      ],
    );
  }
  return SingleChildScrollView(
    scrollDirection: Axis.horizontal,
    child: Row(
      children: [
        Text(
          '${c.selection.length} selected',
          style: TextStyle(fontSize: 12, color: palette.textDim),
        ),
        const SizedBox(width: 8),
        _SelAction(
          icon: Icons.delete_outline,
          label: 'Delete',
          onTap: c.deleteSelection,
        ),
        _SelAction(icon: Icons.copy, label: 'Copy', onTap: c.copySelection),
        _SelAction(icon: Icons.cut, label: 'Cut', onTap: c.cutSelection),
        _SelAction(
          icon: Icons.control_point_duplicate,
          label: 'Duplicate',
          onTap: c.duplicateSelection,
        ),
        _SelAction(
          icon: Icons.palette_outlined,
          label: 'Color',
          onTap: c.applyColorToSelection,
        ),
        _SelAction(
          icon: Icons.flip_to_front,
          label: 'Front',
          onTap: c.bringSelectionToFront,
        ),
        _SelAction(
          icon: Icons.flip_to_back,
          label: 'Back',
          onTap: c.sendSelectionToBack,
        ),
        // Split pasted text (linked boxes across pages): act on ALL parts.
        // "Cut all" + paste elsewhere re-flows it there = the move story.
        if (c.selectionHasLinkedText) ...[
          _SelAction(
            icon: Icons.cut,
            label: 'Cut all parts',
            onTap: c.cutLinkedText,
          ),
          _SelAction(
            icon: Icons.delete_sweep_outlined,
            label: 'Delete all parts',
            onTap: c.deleteLinkedText,
          ),
        ],
      ],
    ),
  );
}

Widget _buildTextStyleRow(
  BuildContext context,
  CanvasController c,
  AppPalette palette,
) {
  final showActions = c.selection.isNotEmpty && !c.isEditingText;
  Widget divider() => Container(
    width: 1,
    height: 24,
    margin: const EdgeInsets.symmetric(horizontal: 8),
    color: palette.border,
  );

  // TextFieldTapRegion: taps on these controls count as "inside" the text
  // editor, so they no longer unfocus the TextField / fire onTapOutside —
  // which used to commit the edit and collapse the selection the instant any
  // style button was tapped ("selecting a style deselects and does nothing").
  return TextFieldTapRegion(
    child: SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          PopupMenuButton<String>(
            tooltip: 'Font',
            initialValue: c.textFontFamily,
            onSelected: c.setTextFontFamily,
            itemBuilder: (context) => const [
              PopupMenuItem(value: 'sans', child: Text('Sans')),
              PopupMenuItem(
                value: 'serif',
                child: Text('Serif', style: TextStyle(fontFamily: 'Georgia')),
              ),
              PopupMenuItem(
                value: 'mono',
                child: Text(
                  'Mono',
                  style: TextStyle(fontFamily: 'Courier New'),
                ),
              ),
            ],
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Aa',
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      fontFamily: switch (c.textFontFamily) {
                        'serif' => 'Georgia',
                        'mono' => 'Courier New',
                        _ => null,
                      },
                    ),
                  ),
                  Icon(Icons.arrow_drop_down, size: 18, color: palette.textDim),
                ],
              ),
            ),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            tooltip: 'Smaller',
            icon: const Icon(Icons.text_decrease, size: 18),
            onPressed: () => c.setTextFontSize(c.textFontSize - 2),
          ),
          Text(
            c.textFontSize.toStringAsFixed(0),
            style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            tooltip: 'Larger',
            icon: const Icon(Icons.text_increase, size: 18),
            onPressed: () => c.setTextFontSize(c.textFontSize + 2),
          ),
          const SizedBox(width: 4),
          _ToggleChip(
            label: 'B',
            bold: true,
            active: c.textBold,
            onTap: c.toggleTextBold,
          ),
          _ToggleChip(
            label: 'I',
            italic: true,
            active: c.textItalic,
            onTap: c.toggleTextItalic,
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            tooltip: 'Alignment',
            icon: Icon(switch (c.textAlign) {
              TextAlignOption.center => Icons.format_align_center,
              TextAlignOption.right => Icons.format_align_right,
              _ => Icons.format_align_left,
            }, size: 18),
            onPressed: c.cycleTextAlign,
          ),
          if (c.isEditingText) ...[
            divider(),
            IconButton(
              visualDensity: VisualDensity.compact,
              tooltip: 'Bullet list',
              icon: const Icon(Icons.format_list_bulleted, size: 18),
              onPressed: () =>
                  c.toggleTextListPrefix(RichTextController.bulletPrefix),
            ),
            IconButton(
              visualDensity: VisualDensity.compact,
              tooltip: 'Star list',
              icon: const Icon(Icons.star_outline, size: 18),
              onPressed: () =>
                  c.toggleTextListPrefix(RichTextController.starPrefix),
            ),
            IconButton(
              visualDensity: VisualDensity.compact,
              tooltip: 'Checkbox (tap again to check)',
              icon: const Icon(Icons.check_box_outlined, size: 18),
              onPressed: () => c.toggleTextListPrefix(
                RichTextController.uncheckedPrefix,
                cycle: true,
              ),
            ),
          ],
          divider(),
          for (final preset in _presetColors)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 3),
              child: _ColorDot(
                color: preset,
                selected: preset.toARGB32() == c.textColor.toARGB32(),
                ringColor: palette.accent,
                borderColor: palette.border,
                onTap: () => c.setTextColor(preset),
              ),
            ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 3),
            child: _WheelDot(
              current: c.textColor,
              selected: _presetColors
                  .every((p) => p.toARGB32() != c.textColor.toARGB32()),
              ringColor: palette.accent,
              onPicked: c.setTextColor,
            ),
          ),
          if (showActions) ...[
            divider(),
            _SelAction(
              icon: Icons.control_point_duplicate,
              label: 'Duplicate',
              onTap: c.duplicateSelection,
            ),
            _SelAction(
              icon: Icons.delete_outline,
              label: 'Delete',
              onTap: c.deleteSelection,
            ),
            // A text-only selection shows THIS row, not the lasso action row
            // — so the linked (split-paste) whole-text actions must live here
            // too, or they'd be unreachable for text boxes.
            if (c.selectionHasLinkedText) ...[
              _SelAction(
                icon: Icons.cut,
                label: 'Cut all parts',
                onTap: c.cutLinkedText,
              ),
              _SelAction(
                icon: Icons.delete_sweep_outlined,
                label: 'Delete all parts',
                onTap: c.deleteLinkedText,
              ),
            ],
          ],
        ],
      ),
    ),
  );
}

/// A single tool's tappable icon — used both in the normal toolbar's tool
/// row and the full-screen floating control (collapsed icon + picker row).
class _ToolIconButton extends StatelessWidget {
  final CanvasTool tool;
  final bool active;
  final VoidCallback onTap;

  const _ToolIconButton({
    required this.tool,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final palette = Theme.of(context).extension<AppPalette>()!;
    return Tooltip(
      message: _labelForTool(tool),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(kRadius),
        child: Container(
          width: 40,
          height: 40,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: active ? palette.accentSoft : null,
            borderRadius: BorderRadius.circular(kRadius),
          ),
          child: Icon(
            _iconForTool(tool),
            size: 20,
            color: active ? palette.accent : null,
          ),
        ),
      ),
    );
  }
}

/// A small floating action button used for full-screen's exit control.
class _FloatingIconButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  const _FloatingIconButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = theme.extension<AppPalette>()!;
    return _FloatingPanel(
      padding: EdgeInsets.zero,
      child: Tooltip(
        message: tooltip,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(kRadius + 6),
          child: SizedBox(
            width: 40,
            height: 40,
            child: Icon(icon, size: 20, color: palette.textDim),
          ),
        ),
      ),
    );
  }
}

/// Elevated, bordered container full-screen's floating controls sit in —
/// legible over any page content underneath.
class _FloatingPanel extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;

  const _FloatingPanel({
    required this.child,
    this.padding = const EdgeInsets.all(8),
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = theme.extension<AppPalette>()!;
    return Material(
      color: theme.colorScheme.surface,
      elevation: 6,
      borderRadius: BorderRadius.circular(kRadius + 6),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(kRadius + 6),
          border: Border.all(color: palette.border),
        ),
        padding: padding,
        child: child,
      ),
    );
  }
}

class _CanvasToolbar extends StatelessWidget {
  final CanvasController controller;

  const _CanvasToolbar({required this.controller});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = theme.extension<AppPalette>()!;

    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final c = controller;
        return Container(
          width: double.infinity,
          decoration: BoxDecoration(
            color: theme.colorScheme.surface,
            border: Border(bottom: BorderSide(color: palette.border)),
          ),
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
          // Fixed height: just the tool icon row. The per-tool options panel
          // is drawn separately as a floating overlay (see _ToolOptionsPanel)
          // so opening it never resizes/moves the canvas below.
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (final tool in kCanvasToolOrder)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 2),
                    child: _ToolIconButton(
                      tool: tool,
                      active: c.tool == tool,
                      onTap: () => c.setTool(tool),
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

    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final contextRow =
            _buildToolContextRow(context, controller, palette);
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
              ? const SizedBox(key: ValueKey('opts-none'), width: double.infinity)
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

class _HintRow extends StatelessWidget {
  final IconData icon;
  final String text;
  final AppPalette palette;

  const _HintRow({
    required this.icon,
    required this.text,
    required this.palette,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Icon(icon, size: 16, color: palette.textDim),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              text,
              style: TextStyle(fontSize: 11.5, color: palette.textDim),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

class _SelAction extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _SelAction({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 2),
      child: TextButton.icon(
        onPressed: onTap,
        icon: Icon(icon, size: 16),
        label: Text(label, style: const TextStyle(fontSize: 12)),
        style: TextButton.styleFrom(
          visualDensity: VisualDensity.compact,
          padding: const EdgeInsets.symmetric(horizontal: 8),
        ),
      ),
    );
  }
}

class _ToggleChip extends StatelessWidget {
  final String label;
  final bool bold;
  final bool italic;
  final bool active;
  final VoidCallback onTap;

  const _ToggleChip({
    required this.label,
    this.bold = false,
    this.italic = false,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(kRadius),
        child: Container(
          width: 30,
          height: 30,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: active
                ? theme.colorScheme.primary.withValues(alpha: 0.15)
                : null,
            borderRadius: BorderRadius.circular(kRadius),
            border: Border.all(
              color: active ? theme.colorScheme.primary : theme.dividerColor,
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 14,
              fontWeight: bold ? FontWeight.w700 : FontWeight.w500,
              fontStyle: italic ? FontStyle.italic : FontStyle.normal,
              color: active ? theme.colorScheme.primary : null,
            ),
          ),
        ),
      ),
    );
  }
}

class _ColorDot extends StatelessWidget {
  final Color color;
  final bool selected;
  final Color ringColor;
  final Color borderColor;
  final VoidCallback onTap;

  const _ColorDot({
    required this.color,
    required this.selected,
    required this.ringColor,
    required this.borderColor,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOut,
        width: 26,
        height: 26,
        padding: EdgeInsets.all(selected ? 3 : 0),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(
            color: selected ? ringColor : Colors.transparent,
            width: 2,
          ),
        ),
        child: Container(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: color,
            border: Border.all(color: borderColor, width: 1),
          ),
        ),
      ),
    );
  }
}

/// The rainbow "more colors" dot at the end of a color row: opens the full
/// color wheel. [selected] (the active color isn't one of the presets) shows
/// the ring and the current custom color in the dot's center.
class _WheelDot extends StatelessWidget {
  final Color current;
  final bool selected;
  final Color ringColor;
  final ValueChanged<Color> onPicked;

  const _WheelDot({
    required this.current,
    required this.selected,
    required this.ringColor,
    required this.onPicked,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () async {
        final picked = await showColorWheelPicker(context, initial: current);
        if (picked != null) onPicked(picked);
      },
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOut,
        width: 26,
        height: 26,
        padding: EdgeInsets.all(selected ? 3 : 0),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(
            color: selected ? ringColor : Colors.transparent,
            width: 2,
          ),
        ),
        child: Container(
          decoration: const BoxDecoration(
            shape: BoxShape.circle,
            gradient: kColorWheelGradient,
          ),
          alignment: Alignment.center,
          child: selected
              ? Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(
                    color: current,
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white, width: 1.5),
                  ),
                )
              : const Icon(Icons.colorize, color: Colors.white, size: 12),
        ),
      ),
    );
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
