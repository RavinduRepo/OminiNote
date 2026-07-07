import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:flutter/services.dart';
import 'package:open_filex/open_filex.dart';
import '../utils/clipboard_images.dart';
import '../canvas/canvas_controller.dart';
import '../canvas/canvas_painter.dart';
import '../canvas/rich_text_controller.dart';
import '../canvas/text_measure.dart';
import '../models/canvas_page.dart';
import '../models/element.dart';
import '../models/canvas.dart';
import '../services/notebook_service.dart';
import '../services/pdf_exporter.dart';
import '../services/settings_service.dart';
import '../theme/app_theme.dart';
import '../widgets/sync_status_icon.dart';

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

  const CanvasScreen({super.key, required this.canvas, this.onCanvasRenamed});

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

  // A text box grabbed in text mode: a tap edits it, a drag moves it.
  TextElement? _grabbedText;
  String? _grabbedPageId;
  bool _elementGrabbing = false; // guards the pan recognizer for touch grabs

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
  }

  Future<void> _load() async {
    final pages = await _service.loadPages(widget.canvas);
    if (!mounted) return;
    setState(() {
      _controller = CanvasController(canvas: widget.canvas, pages: pages)
        ..systemCopyHook = _copySelectionToSystemClipboard
        ..systemPasteFallback = _pasteFromSystemClipboard;
    });
  }

  // ── OS clipboard bridging ─────────────────────────────────────────────

  /// Mirrors the just-copied selection to the OS clipboard: text-only
  /// selections as plain text, anything else as a PNG of the selection's
  /// on-screen pixels.
  Future<void> _copySelectionToSystemClipboard() async {
    final c = _controller;
    if (c == null || c.selection.isEmpty) return;

    if (c.selection.every((e) => e is TextElement)) {
      final text = c.selection
          .whereType<TextElement>()
          .map((t) => t.text)
          .join('\n');
      if (text.trim().isNotEmpty) {
        await Clipboard.setData(ClipboardData(text: text));
      }
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
      final boundary = _canvasBoundaryKey.currentContext?.findRenderObject()
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
      final cropped = await recorder
          .endRecording()
          .toImage(src.width.round(), src.height.round());
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
  /// then OS text.
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
    await _pasteSystemText();
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
    c.addElement(
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
    _canvasFocus.dispose();
    _controller?.dispose(); // flushes pending saves
    super.dispose();
  }

  // ── Pointer routing ──────────────────────────────────────────────────

  bool _isDrawingDevice(PointerEvent e) =>
      e.kind == PointerDeviceKind.stylus ||
      e.kind == PointerDeviceKind.invertedStylus ||
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
      if (editorRect.contains(e.localPosition)) return;
      _commitTextEdit();
    }
    _downPosition = e.localPosition;

    // Mouse or finger can grab the scrollbar thumb. Touch also goes through
    // the pan recognizer, so the scale handlers below no-op while a scrollbar
    // drag is active.
    if ((e.kind == PointerDeviceKind.mouse ||
            e.kind == PointerDeviceKind.touch) &&
        c.beginScrollbarDrag(e.localPosition)) {
      _scrollbarDragging = true;
      return;
    }

    // Text mode: grab a text box under the point — a tap edits it, a drag
    // moves it (no lasso needed). Empty area is handled on tap-up (new box).
    if (c.tool == CanvasTool.text) {
      final hit = _textAt(e.localPosition);
      if (hit != null) {
        _grabbedText = hit.$2;
        _grabbedPageId = hit.$1;
        _elementGrabbing = e.kind == PointerDeviceKind.touch;
        c.selectSingle(hit.$1, hit.$2);
        _toolGestureActive = c.startToolGesture(
          e.localPosition,
          e.pressure == 0 ? 0.5 : e.pressure,
        );
      }
      return;
    }

    if (_isDrawingDevice(e)) {
      _toolGestureActive = c.startToolGesture(
        e.localPosition,
        e.pressure == 0 ? 0.5 : e.pressure,
        forceEraser: _forceEraser(e),
      );
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
    _controller!.updateToolGesture(
      e.localPosition,
      e.pressure == 0 ? 0.5 : e.pressure,
    );
  }

  void _onPointerUp(PointerUpEvent e) {
    final c = _controller!;
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

      // Text-mode grab: tap edits, drag commits the move.
      if (_grabbedText != null) {
        final el = _grabbedText!;
        final pageId = _grabbedPageId!;
        _grabbedText = null;
        _grabbedPageId = null;
        _elementGrabbing = false;
        if (moved) {
          c.endToolGesture();
        } else {
          c.cancelToolGesture();
          _startTextEdit(pageId, el, isNew: false);
        }
        return;
      }

      // Lasso mode: a tap on an attachment chip opens it; a tap on a text
      // box edits it (a drag draws the lasso).
      if (c.tool == CanvasTool.lasso && !moved) {
        final att = _attachmentAt(e.localPosition);
        if (att != null && c.selection.isEmpty) {
          c.cancelToolGesture();
          _openAttachment(att);
          return;
        }
        final hit = _textAt(e.localPosition);
        if (hit != null) {
          c.cancelToolGesture();
          _startTextEdit(hit.$1, hit.$2, isNew: false);
          return;
        }
      }

      c.endToolGesture();
      return;
    }

    // Taps that didn't start a gesture.
    if (!moved && e.kind != PointerDeviceKind.trackpad) {
      if (c.tool == CanvasTool.text) {
        final att = _attachmentAt(e.localPosition);
        if (att != null) {
          _openAttachment(att);
          return;
        }
        _handleTextTap(e.localPosition); // empty area → new text box
      } else if (c.tool == CanvasTool.lasso) {
        final att = _attachmentAt(e.localPosition);
        if (att != null && c.selection.isEmpty) {
          _openAttachment(att);
          return;
        }
        final hit = _textAt(e.localPosition);
        if (hit != null) _startTextEdit(hit.$1, hit.$2, isNew: false);
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
    _grabbedText = null;
    _grabbedPageId = null;
    _elementGrabbing = false;
    _downPosition = null;
  }

  /// Topmost text element under a screen position, with its page id.
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
      _toast('"${el.name}" is missing on this device — sync may still be '
          'downloading it');
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
    final attr = session.controller.styleForToolbar();
    session.controller.defaults = attr.clone();
    c.textFontFamily = attr.family;
    c.textFontSize = attr.fontSize;
    c.textBold = attr.bold;
    c.textItalic = attr.italic;
    c.textColor = attr.color; // text's own color slot, whatever tool is active
    _remeasureEditing();
    c.notifyRepaint(); // refresh toolbar highlight
  }

  /// Grows/wraps the editing box to fit the current (rich) content.
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
    el.runs = runsFromController(rc);
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

  // ── Add / insert flows ───────────────────────────────────────────────

  Future<void> _showAddSheet() async {
    final c = _controller!;
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: SingleChildScrollView(
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
              subtitle: const Text('As annotatable pages, or as an attachment'),
              onTap: () => Navigator.pop(context, 'pdf'),
            ),
            const Divider(),
            const _SheetLabel('Content'),
            ListTile(
              leading: const Icon(Icons.text_fields),
              title: const Text('Text box'),
              subtitle: const Text('Switch to the text tool, then tap the page'),
              onTap: () => Navigator.pop(context, 'text'),
            ),
            ListTile(
              leading: const Icon(Icons.image_outlined),
              title: const Text('Image'),
              onTap: () => Navigator.pop(context, 'image'),
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
      ),
    );
    if (!mounted || action == null) return;

    switch (action) {
      case 'blank':
        final pos = await _pickInsertPosition(
      includeTop: false,
        );
        if (pos != null) c.addBlankPage(pos);
      case 'horizontal':
        final current = c.currentPageLayout;
        if (current != null) c.addHorizontalPage(current.rowIndex);
      case 'pdf':
        await _insertPdfFlow();
      case 'text':
        c.setTool(CanvasTool.text);
        _toast('Tap anywhere on a page to place text');
      case 'image':
        await _insertImageFlow();
      case 'paste':
        await _pasteFlow();
    }
  }

  Future<InsertPosition?> _pickInsertPosition({bool includeTop = true}) {
    return showModalBottomSheet<InsertPosition>(
      context: context,
      builder: (context) => SafeArea(
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
      builder: (context) => SafeArea(
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
    final c = _controller!;
    final result = await FilePicker.platform.pickFiles(type: FileType.image);
    final path = result?.files.single.path;
    if (path == null || !mounted) return;

    final bytes = await File(path).readAsBytes();
    final ext = path.split('.').last.toLowerCase();
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

    c.addElement(
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
    final page = c.pages[target.pageId]!;
    final width = math.min(page.width * 0.7, 320.0);
    final el = TextElement(
      id: newModelId('el'),
      deviceId: SettingsService().deviceId,
      rect: Rect.fromCenter(
        center: Offset(page.width / 2, page.height / 2),
        width: width,
        height: c.textFontSize * 1.6,
      ),
      text: text,
      fontFamily: c.textFontFamily,
      fontSize: c.textFontSize,
      color: c.color,
    );
    final tp = TextPainter(
      text: TextSpan(text: text, style: textStyleForElement(el)),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: width);
    el.rect = Rect.fromLTWH(
      el.rect.left,
      el.rect.top,
      width,
      tp.height + 8,
    );
    c.addElement(target.pageId, el);
  }

  // ── Sheets: page settings, navigator, attachments ────────────────────

  Future<void> _showPageSettings() async {
    final c = _controller!;
    final current = c.currentPageLayout;
    if (current == null) return;
    final page = c.pages[current.pageId]!;
    var color = page.background.color;
    var pattern = page.background.pattern;
    var asDefault = false;

    const presets = [
      Color(0xFFFFFFFF), // white
      Color(0xFFF8F1E3), // cream
      Color(0xFFEDEDED), // light grey
      Color(0xFF2A2A2E), // charcoal
      Color(0xFF17171A), // near black
    ];

    final apply = await showModalBottomSheet<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setSheetState) => SafeArea(
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
        ),
      ),
    );

    if (apply == true) {
      c.setPageBackground(
        current.pageId,
        PageBackground(color: color, pattern: pattern),
        asSectionDefault: asDefault,
      );
    }
  }

  Future<void> _showNavigator() async {
    final c = _controller!;
    await showModalBottomSheet<void>(
      context: context,
      builder: (context) => SafeArea(
        child: ListenableBuilder(
          listenable: c,
          builder: (context, _) {
            final entries = c.layout.pages;
            return ListView.builder(
              itemCount: entries.length,
              itemBuilder: (context, i) {
                final l = entries[i];
                final page = c.pages[l.pageId];
                final isPdf = page?.source != null;
                return ListTile(
                  leading: Icon(
                    isPdf ? Icons.picture_as_pdf_outlined : Icons.crop_portrait,
                  ),
                  title: Text('Page ${i + 1}'),
                  subtitle: Text(
                    'Row ${l.rowIndex + 1}'
                    '${l.colIndex > 0 ? ' · position ${l.colIndex + 1}' : ''}'
                    '${isPdf ? ' · PDF' : ''}',
                  ),
                  onTap: () {
                    Navigator.pop(context);
                    c.jumpToPage(l.pageId);
                  },
                  trailing: PopupMenuButton<String>(
                    onSelected: (action) {
                      switch (action) {
                        case 'duplicate':
                          c.duplicatePage(l.pageId);
                        case 'delete':
                          if (!c.deletePage(l.pageId)) {
                            _toast("Can't delete the only page");
                          }
                        case 'up':
                          c.moveRow(l.rowIndex, -1);
                        case 'down':
                          c.moveRow(l.rowIndex, 1);
                      }
                    },
                    itemBuilder: (context) => const [
                      PopupMenuItem(
                        value: 'duplicate',
                        child: Text('Duplicate'),
                      ),
                      PopupMenuItem(value: 'up', child: Text('Move row up')),
                      PopupMenuItem(
                        value: 'down',
                        child: Text('Move row down'),
                      ),
                      PopupMenuItem(value: 'delete', child: Text('Delete')),
                    ],
                  ),
                );
              },
            );
          },
        ),
      ),
    );
  }

  Future<void> _showBookmarks() async {
    final c = _controller!;
    await showModalBottomSheet<void>(
      context: context,
      builder: (context) => SafeArea(
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
                    final ordinal =
                        c.pageOrdinalOf(c.currentPageLayout?.pageId ?? '');
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
                          subtitle:
                              ordinal != null ? Text('Page $ordinal') : null,
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
      builder: (context) => SafeArea(
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
                                    widget.canvas, att.assetId);
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

    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => const AlertDialog(
        content: Row(
          children: [
            CircularProgressIndicator(),
            SizedBox(width: 20),
            Text('Exporting PDF…'),
          ],
        ),
      ),
    );

    try {
      final exporter = SyncfusionPdfExporter();
      final bytes = await exporter.export(
        canvas: widget.canvas,
        pages: c.pages,
        assetBytes: (assetId) =>
            _service.assetFile(widget.canvas, assetId).readAsBytes(),
      );
      if (!mounted) return;
      Navigator.pop(context); // progress dialog

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
      if (mounted && Navigator.canPop(context)) Navigator.pop(context);
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

    return Scaffold(
      backgroundColor: palette.canvas,
      appBar: AppBar(
        title: Text(widget.canvas.name),
        actions: [
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
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: 'Add',
            onPressed: _showAddSheet,
          ),
          IconButton(
            icon: const Icon(Icons.fullscreen),
            tooltip: 'Full screen',
            onPressed: _toggleFullScreen,
          ),
          IconButton(
            icon: Icon(_showToolbar ? Icons.expand_less : Icons.brush_outlined),
            tooltip: _showToolbar ? 'Hide tools' : 'Show tools',
            onPressed: () => setState(() => _showToolbar = !_showToolbar),
          ),
          PopupMenuButton<String>(
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
              }
            },
            itemBuilder: (context) => const [
              PopupMenuItem(value: 'rename', child: Text('Rename')),
              PopupMenuItem(value: 'export', child: Text('Export PDF')),
              PopupMenuItem(value: 'navigator', child: Text('Pages')),
              PopupMenuItem(value: 'bookmarks', child: Text('Bookmarks')),
              PopupMenuItem(value: 'attachments', child: Text('Attachments')),
              PopupMenuItem(
                value: 'page_settings',
                child: Text('Page settings'),
              ),
            ],
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: Column(
        children: [
          AnimatedSize(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOut,
            alignment: Alignment.topCenter,
            child: _showToolbar
                ? _CanvasToolbar(controller: c)
                : const SizedBox(width: double.infinity),
          ),
          Expanded(child: _buildCanvasArea(c, palette)),
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
    final ctrl = HardwareKeyboard.instance.isControlPressed ||
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
              decoration: BoxDecoration(
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
                  contentPadding: EdgeInsets.all(4),
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
      return _HintRow(
        icon: Icons.auto_fix_normal_outlined,
        text:
            'Draw over strokes to erase them · hold the pen button to erase anytime',
        palette: palette,
      );
    case CanvasTool.lasso:
      // Hint + Paste (the row handles the empty-selection state itself).
      return _buildLassoActionRow(context, c, palette);
    case CanvasTool.text:
      return _buildTextStyleRow(context, c, palette);
  }
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
      Icon(Icons.line_weight, size: 18, color: palette.textDim),
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
              child:
                  Text('Mono', style: TextStyle(fontFamily: 'Courier New')),
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
          icon: Icon(
            switch (c.textAlign) {
              TextAlignOption.center => Icons.format_align_center,
              TextAlignOption.right => Icons.format_align_right,
              _ => Icons.format_align_left,
            },
            size: 18,
          ),
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
        final contextRow = _buildToolContextRow(context, c, palette);
        return Container(
          width: double.infinity,
          decoration: BoxDecoration(
            color: theme.colorScheme.surface,
            border: Border(bottom: BorderSide(color: palette.border)),
          ),
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SingleChildScrollView(
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
              AnimatedSize(
                duration: const Duration(milliseconds: 160),
                curve: Curves.easeOut,
                alignment: Alignment.topLeft,
                child: contextRow == null
                    ? const SizedBox(width: double.infinity)
                    : Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: contextRow,
                      ),
              ),
            ],
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
              color: active
                  ? theme.colorScheme.primary
                  : theme.dividerColor,
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
