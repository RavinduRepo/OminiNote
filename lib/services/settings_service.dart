import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';
import '../canvas/shape_recognizer.dart' show ShapeToolKind;
import '../models/canvas_page.dart';
import '../models/shape_template.dart';
import '../theme/app_theme.dart';

/// Which navigation shell to show. [auto] picks based on window width (see
/// `main.dart`'s root router); [mobile]/[desktop] force one regardless of
/// size, for when the auto-detected default doesn't match what the user wants.
enum LayoutMode { auto, mobile, desktop }

/// Persists app-wide preferences to `settings.json` in the app documents
/// directory (same file-based approach as [NotebookService]). Exposes the
/// theme mode as a [ValueNotifier] so the root [MaterialApp] can rebuild when
/// it changes, without a state-management library.
class SettingsService {
  static final SettingsService _instance = SettingsService._internal();

  factory SettingsService() => _instance;

  SettingsService._internal();

  late File _settingsFile;

  final ValueNotifier<ThemeMode> themeMode = ValueNotifier(ThemeMode.system);

  /// Chosen light/dark palette variants (`AppTheme.lightVariants`/`darkVariants`
  /// ids). Whichever brightness is showing — via System or a manual pick — uses
  /// its selected variant, so the two are remembered independently.
  final ValueNotifier<String> lightThemeId = ValueNotifier('slate');
  final ValueNotifier<String> darkThemeId = ValueNotifier('charcoal');

  /// Guided custom themes (`AppTheme.buildCustomVariant`): an accent + a base
  /// background tone (ARGB ints), per brightness. Null until the user makes one.
  final ValueNotifier<int?> customLightAccent = ValueNotifier(null);
  final ValueNotifier<int?> customLightBase = ValueNotifier(null);
  final ValueNotifier<int?> customDarkAccent = ValueNotifier(null);
  final ValueNotifier<int?> customDarkBase = ValueNotifier(null);

  bool get hasCustomLight =>
      customLightAccent.value != null && customLightBase.value != null;
  bool get hasCustomDark =>
      customDarkAccent.value != null && customDarkBase.value != null;

  /// The built custom light variant, or null if none has been made.
  ThemeVariant? customLightVariant() => hasCustomLight
      ? AppTheme.buildCustomVariant(
          brightness: Brightness.light,
          accent: Color(customLightAccent.value!),
          base: Color(customLightBase.value!),
        )
      : null;

  ThemeVariant? customDarkVariant() => hasCustomDark
      ? AppTheme.buildCustomVariant(
          brightness: Brightness.dark,
          accent: Color(customDarkAccent.value!),
          base: Color(customDarkBase.value!),
        )
      : null;

  /// The light [ThemeVariant] to actually apply: the custom one when 'custom' is
  /// selected and exists, else the built-in for [lightThemeId] (default).
  ThemeVariant effectiveLightVariant() {
    if (lightThemeId.value == 'custom') {
      final v = customLightVariant();
      if (v != null) return v;
    }
    return AppTheme.lightVariant(lightThemeId.value);
  }

  ThemeVariant effectiveDarkVariant() {
    if (darkThemeId.value == 'custom') {
      final v = customDarkVariant();
      if (v != null) return v;
    }
    return AppTheme.darkVariant(darkThemeId.value);
  }

  /// App-wide default page background seeded into new sections/pages. Editable
  /// from Settings (outside a notebook) so the default applies everywhere.
  final ValueNotifier<PageBackground> defaultPageBackground = ValueNotifier(
    const PageBackground(pattern: BgPattern.ruled),
  );

  /// When true, [effectiveDefaultBackground] derives the page color from the
  /// current theme (white for light, charcoal for dark) instead of using the
  /// stored color. Set to false the first time the user picks a color manually.
  final ValueNotifier<bool> autoPageColor = ValueNotifier(true);

  /// Mobile (single-pane, pushed navigation) vs desktop (split-view sidebar)
  /// shell, or auto-detect from window width.
  final ValueNotifier<LayoutMode> layoutMode = ValueNotifier(LayoutMode.auto);

  /// Draw with a finger (touch) in addition to stylus/mouse — for when no pen
  /// is at hand. While on, one finger draws and two-finger gestures still
  /// pan/zoom. Device-local (never synced); toggled from the canvas overflow
  /// menu.
  bool fingerDraw = false;

  Future<void> setFingerDraw(bool value) async {
    if (fingerDraw == value) return;
    fingerDraw = value;
    await _persist();
  }

  /// Snap drawn shapes: while drawing with the pen or highlighter, pausing
  /// without lifting recognizes the stroke as a clean shape (line/rect/circle/…).
  /// Device-local (never synced); default ON; toggled from the canvas overflow
  /// menu.
  bool shapeSnap = true;

  Future<void> setShapeSnap(bool value) async {
    if (shapeSnap == value) return;
    shapeSnap = value;
    await _persist();
  }

  /// Auto-expand the notebook/canvas list panes when navigating in-place via a
  /// tapped link (Connections), a graph edge/node, or a search reveal. When on
  /// (default), landing on a target re-expands a collapsed desktop sidebar so
  /// you see where you landed; when off, the panes stay however you left them
  /// (open the list manually to see the graph/tree). Device-local (never
  /// synced). Managed under Settings for now.
  bool autoExpandOnReveal = true;

  Future<void> setAutoExpandOnReveal(bool value) async {
    if (autoExpandOnReveal == value) return;
    autoExpandOnReveal = value;
    await _persist();
  }

  /// Read-aloud scope: when true the reader speaks only the first page of each
  /// row (vertical pages only), skipping horizontal continuation pages.
  /// Device-local; default OFF (read every page). Toggled by the reader bar's
  /// scope selector.
  bool readAloudMainColumnOnly = false;

  Future<void> setReadAloudMainColumnOnly(bool value) async {
    if (readAloudMainColumnOnly == value) return;
    readAloudMainColumnOnly = value;
    await _persist();
  }

  /// Connections-graph appearance + view toggles. Device-local (never synced —
  /// how you *view* the graph is per-device, like zoom/pan and layout mode).
  double graphNodeSize = 1.0;
  double graphTextSize = 1.0;
  double graphLinkThickness = 1.0;
  double graphLinkOpacity = 0.6;
  double graphLabelOpacity = 0.95;
  bool graphAlwaysLabels = false;
  bool graphAbstractItems = true;
  bool graphShowExternal = true;
  bool graphShowUnlinked = false;
  bool graphSameCanvasLinks = true; // dashed links among same-canvas items
  bool graphPinOnDrag = false; // dragging a node pins it in place (off = springs back)
  bool graphAutoScale = true; // auto-fit/reframe the graph after it settles (off = keep your zoom/pan)

  /// Free-form persisted graph-view state (device-local): selected/hidden
  /// containers, tag filter, active project, and panel expand states. A blob so
  /// the controller and panel can each patch their own keys.
  Map<String, dynamic> graphView = {};

  Future<void> patchGraphView(Map<String, dynamic> partial) async {
    graphView = {...graphView, ...partial};
    await _persist();
  }

  Future<void> saveGraphSettings({
    double? nodeSize,
    double? textSize,
    double? linkThickness,
    double? linkOpacity,
    double? labelOpacity,
    bool? alwaysLabels,
    bool? abstractItems,
    bool? showExternal,
    bool? showUnlinked,
    bool? sameCanvasLinks,
    bool? pinOnDrag,
    bool? autoScale,
  }) async {
    graphNodeSize = nodeSize ?? graphNodeSize;
    graphTextSize = textSize ?? graphTextSize;
    graphLinkThickness = linkThickness ?? graphLinkThickness;
    graphLinkOpacity = linkOpacity ?? graphLinkOpacity;
    graphLabelOpacity = labelOpacity ?? graphLabelOpacity;
    graphAlwaysLabels = alwaysLabels ?? graphAlwaysLabels;
    graphAbstractItems = abstractItems ?? graphAbstractItems;
    graphShowExternal = showExternal ?? graphShowExternal;
    graphShowUnlinked = showUnlinked ?? graphShowUnlinked;
    graphSameCanvasLinks = sameCanvasLinks ?? graphSameCanvasLinks;
    graphPinOnDrag = pinOnDrag ?? graphPinOnDrag;
    graphAutoScale = autoScale ?? graphAutoScale;
    await _persist();
  }

  /// Chosen read-aloud voice (device-local; the engine's default when null).
  String? ttsVoiceName;
  String? ttsVoiceLocale;

  Future<void> setTtsVoice(String name, String locale) async {
    ttsVoiceName = name;
    ttsVoiceLocale = locale;
    await _persist();
  }

  /// Where read-aloud was last positioned in each canvas, so reopening the
  /// reader resumes instead of restarting. Device-local (never synced — reading
  /// position is per-device), capped like [_canvasViewports].
  Map<String, dynamic> _readingPositions = {};
  static const int _kMaxReadingPositions = 300;

  ({String pageId, String? sourceId, int charStart})? readingPositionFor(
      String canvasId) {
    final v = _readingPositions[canvasId];
    if (v is! Map) return null;
    final page = v['pageId'];
    if (page is! String) return null;
    return (
      pageId: page,
      sourceId: v['sourceId'] as String?,
      charStart: (v['charStart'] as num?)?.toInt() ?? 0,
    );
  }

  Future<void> saveReadingPosition(
      String canvasId, String pageId, String? sourceId, int charStart) async {
    _readingPositions.remove(canvasId);
    _readingPositions[canvasId] = {
      'pageId': pageId,
      'sourceId': sourceId,
      'charStart': charStart,
    };
    while (_readingPositions.length > _kMaxReadingPositions) {
      _readingPositions.remove(_readingPositions.keys.first);
    }
    await _persist();
  }

  /// Last-used kind for the Shapes tool (device-local).
  ShapeToolKind shapeToolKind = ShapeToolKind.rectangle;

  Future<void> setShapeToolKind(ShapeToolKind kind) async {
    if (shapeToolKind == kind) return;
    shapeToolKind = kind;
    await _persist();
  }

  /// Saved custom shape templates (device-local, capped). Newest first.
  List<ShapeTemplate> shapeTemplates = [];
  static const int _kMaxShapeTemplates = 50;

  Future<void> addShapeTemplate(ShapeTemplate t) async {
    shapeTemplates.insert(0, t);
    if (shapeTemplates.length > _kMaxShapeTemplates) {
      shapeTemplates = shapeTemplates.sublist(0, _kMaxShapeTemplates);
    }
    await _persist();
  }

  Future<void> removeShapeTemplate(String id) async {
    shapeTemplates.removeWhere((t) => t.id == id);
    await _persist();
  }

  /// Eraser preferences (device-local, like [fingerDraw]): partial mode
  /// splits strokes at the erased gap instead of removing them whole.
  bool eraserPartial = false;
  double eraserSize = 10.0;

  Future<void> setEraserPrefs({bool? partial, double? size}) async {
    if ((partial == null || partial == eraserPartial) &&
        (size == null || size == eraserSize)) {
      return;
    }
    eraserPartial = partial ?? eraserPartial;
    eraserSize = size ?? eraserSize;
    await _persist();
  }

  /// Which ink types get their colour lightness-flipped for visibility when a
  /// page background crosses light↔dark (device-local, remembered per type).
  /// Highlighter defaults off — a translucent highlight tuned for light paper
  /// often reads fine on dark, so it's opt-in.
  bool inkAdjustPen = true;
  bool inkAdjustHighlighter = false;
  bool inkAdjustText = true;

  Future<void> setInkAdjustPrefs({bool? pen, bool? highlighter, bool? text}) async {
    if ((pen == null || pen == inkAdjustPen) &&
        (highlighter == null || highlighter == inkAdjustHighlighter) &&
        (text == null || text == inkAdjustText)) {
      return;
    }
    inkAdjustPen = pen ?? inkAdjustPen;
    inkAdjustHighlighter = highlighter ?? inkAdjustHighlighter;
    inkAdjustText = text ?? inkAdjustText;
    await _persist();
  }

  // ── Toolbar customization (device-local) ────────────────────────────────

  /// A single ordered list of the toolbar buttons promoted onto the canvas
  /// app bar, in left-to-right bar order — separate per layout (mobile's bar
  /// has far less room than desktop's). Unlike the old two-list model (add
  /// actions + overflow actions kept apart), this is ONE sequence so undo,
  /// redo, the "+" Add control ('add') and every add/overflow action can be
  /// freely interleaved and reordered relative to each other, giving the two
  /// layouts a consistent structure. The only button that is never in this
  /// list (always pinned last, never removable) is the "⋯" overflow menu.
  /// Anything not listed here is reached through that menu instead. Action ids
  /// reuse the exact strings used as `_runAddAction`/menu `onSelected` values
  /// plus the three core ids 'undo'/'redo'/'add'.
  List<String> promotedToolbarMobile = List.of(_defaultToolbarMobile);
  List<String> promotedToolbarDesktop = List.of(_defaultToolbarDesktop);

  /// Mobile default mirrors today's fixed mobile bar (undo, redo, then the
  /// "+" button); desktop default mirrors today's fixed desktop toolbar
  /// (undo, redo, the two seeded add actions, the "+", then the two seeded
  /// overflow actions).
  static const List<String> _defaultToolbarMobile = ['undo', 'redo', 'add'];
  static const List<String> _defaultToolbarDesktop = [
    'undo',
    'redo',
    'blank',
    'image',
    'add',
    'fullscreen',
    'toggle_toolbar',
  ];

  Future<void> setPromotedToolbar({
    required bool mobile,
    required List<String> ids,
  }) async {
    if (mobile) {
      promotedToolbarMobile = ids;
    } else {
      promotedToolbarDesktop = ids;
    }
    await _persist();
  }

  /// Builds a unified toolbar list from the legacy split (add + overflow)
  /// lists, preserving the old visual order: undo, redo, promoted add
  /// actions, the "+" control, then promoted overflow actions.
  static List<String> _migrateLegacyToolbar(
    List<String> add,
    List<String> overflow,
  ) =>
      ['undo', 'redo', ...add, 'add', ...overflow];

  /// Per-tool-kind pin state for the pen/highlighter/shape/eraser options
  /// popover ('pen', 'highlighter', 'shape', 'eraser'): pinned stays open
  /// across tool switches; unpinned (default) auto-closes on tool switch,
  /// same as `CanvasController.setTool`'s usual behavior.
  Set<String> pinnedToolOptionPopovers = {};

  bool isToolOptionPopoverPinned(String toolKind) =>
      pinnedToolOptionPopovers.contains(toolKind);

  Future<void> setToolOptionPopoverPinned(String toolKind, bool pinned) async {
    if (pinned) {
      if (!pinnedToolOptionPopovers.add(toolKind)) return;
    } else {
      if (!pinnedToolOptionPopovers.remove(toolKind)) return;
    }
    await _persist();
  }

  // ── Sync-related fields ─────────────────────────────────────────────────

  /// Stable identifier for this installation, generated once and persisted.
  /// Used in lock files so other devices know who holds a lock.
  late String deviceId;

  /// Drive Changes API page token **per account** (accountId → token) —
  /// persisted so each account pulls only its own deltas. Phase 2 made sync
  /// account-scoped (was a single [driveChangesToken] before).
  Map<String, String> _driveChangesTokens = {};

  /// Pre-multi-account single changes token, kept only to migrate into
  /// [_driveChangesTokens] for the default account on first Phase-2 launch.
  String legacyDriveChangesToken = '';

  String driveChangesTokenFor(String accountId) =>
      _driveChangesTokens[accountId] ?? '';

  /// Timestamp of the last successful sync, or null if never synced.
  DateTime? lastSyncAt;

  /// Notebook ids this device keeps **local-only**: never uploaded and never
  /// updated from Drive (sync is blocked in *both* directions for them). This
  /// is a **per-device** decision, deliberately not synced — another device may
  /// still sync the same notebook. Persisted in settings.json.
  Set<String> localOnlyNotebooks = {};

  bool isNotebookLocalOnly(String id) => localOnlyNotebooks.contains(id);

  Future<void> setNotebookLocalOnly(String id, bool local) async {
    if (local) {
      if (!localOnlyNotebooks.add(id)) return;
    } else {
      if (!localOnlyNotebooks.remove(id)) return;
    }
    await _persist();
  }

  /// The notebook this device drops quick imports / opened PDFs into. A
  /// **per-device** pointer (settings.json, never synced) — two devices on the
  /// same account may each mark a different notebook. Null ⇒ fall back to a
  /// local-only "Quick Notes" notebook (see [NotebookService.resolveDefaultTarget]).
  String? defaultNotebookId;

  Future<void> setDefaultNotebook(String? id) async {
    if (defaultNotebookId == id) return;
    defaultNotebookId = id;
    await _persist();
  }

  /// Per-canvas last viewport (canvasId → {z, x, y}) so a canvas reopens
  /// where the user left it. Device-local by design — zoom/pan depend on this
  /// screen, so it lives in settings.json (never synced). Capped so it can't
  /// grow unboundedly.
  Map<String, dynamic> _canvasViewports = {};
  static const int _kMaxViewports = 300;

  /// Action-recording anchors: for a media (a recording id, or `video:<assetId>`)
  /// on a canvas, the wall-clock ms that maps to media position 0. Replay glows
  /// the ink drawn during the recording pass (its `createdAt` maps back through
  /// this anchor to a media position). Device-local like the viewport — an
  /// action pass is re-recordable per device — so it never syncs. Capped.
  Map<String, dynamic> _actionAnchors = {};
  static const int _kMaxActionAnchors = 500;

  int? actionAnchorFor(String canvasId, String mediaId) {
    final v = _actionAnchors['$canvasId:$mediaId'];
    return (v as num?)?.toInt();
  }

  Future<void> setActionAnchor(
      String canvasId, String mediaId, int wallclockMs) async {
    final key = '$canvasId:$mediaId';
    _actionAnchors.remove(key);
    _actionAnchors[key] = wallclockMs;
    while (_actionAnchors.length > _kMaxActionAnchors) {
      _actionAnchors.remove(_actionAnchors.keys.first);
    }
    await _persist();
  }

  Future<void> clearActionAnchor(String canvasId, String mediaId) async {
    if (_actionAnchors.remove('$canvasId:$mediaId') != null) await _persist();
  }

  ({double zoom, double panX, double panY})? viewportFor(String canvasId) {
    final v = _canvasViewports[canvasId];
    if (v is! Map) return null;
    final z = (v['z'] as num?)?.toDouble();
    final x = (v['x'] as num?)?.toDouble();
    final y = (v['y'] as num?)?.toDouble();
    if (z == null || x == null || y == null) return null;
    return (zoom: z, panX: x, panY: y);
  }

  Future<void> saveCanvasViewport(
    String canvasId,
    double zoom,
    double panX,
    double panY,
  ) async {
    // Re-insert to keep LRU-ish ordering; evict oldest past the cap.
    _canvasViewports.remove(canvasId);
    _canvasViewports[canvasId] = {'z': zoom, 'x': panX, 'y': panY};
    while (_canvasViewports.length > _kMaxViewports) {
      _canvasViewports.remove(_canvasViewports.keys.first);
    }
    await _persist();
  }

  Future<void> init() async {
    // Device-local settings live alongside the data store in the app-support dir
    // (see NotebookService.init for the per-OS locations), never in Documents.
    final appDir = await getApplicationSupportDirectory();
    _settingsFile = File('${appDir.path}/settings.json');

    Map<String, dynamic> data = {};
    if (await _settingsFile.exists()) {
      try {
        data =
            jsonDecode(await _settingsFile.readAsString())
                as Map<String, dynamic>;
      } catch (_) {
        // Corrupt/partial settings file — fall back to defaults.
      }
    }

    themeMode.value = _parseThemeMode(data['themeMode']);
    if (data['lightThemeId'] is String) lightThemeId.value = data['lightThemeId'];
    if (data['darkThemeId'] is String) darkThemeId.value = data['darkThemeId'];
    customLightAccent.value = (data['customLightAccent'] as num?)?.toInt();
    customLightBase.value = (data['customLightBase'] as num?)?.toInt();
    customDarkAccent.value = (data['customDarkAccent'] as num?)?.toInt();
    customDarkBase.value = (data['customDarkBase'] as num?)?.toInt();
    layoutMode.value = _parseLayoutMode(data['layoutMode']);
    fingerDraw = data['fingerDraw'] == true;
    shapeSnap = data['shapeSnap'] != false; // default ON
    autoExpandOnReveal = data['autoExpandOnReveal'] != false; // default ON
    readAloudMainColumnOnly = data['readAloudMainColumnOnly'] == true;
    graphNodeSize = (data['graphNodeSize'] as num?)?.toDouble() ?? 1.0;
    graphTextSize = (data['graphTextSize'] as num?)?.toDouble() ?? 1.0;
    graphLinkThickness = (data['graphLinkThickness'] as num?)?.toDouble() ?? 1.0;
    graphLinkOpacity = (data['graphLinkOpacity'] as num?)?.toDouble() ?? 0.6;
    graphLabelOpacity = (data['graphLabelOpacity'] as num?)?.toDouble() ?? 0.95;
    graphAlwaysLabels = data['graphAlwaysLabels'] == true; // default false
    graphAbstractItems = data['graphAbstractItems'] != false; // default true
    graphShowExternal = data['graphShowExternal'] != false; // default true
    graphShowUnlinked = data['graphShowUnlinked'] == true; // default false
    graphSameCanvasLinks = data['graphSameCanvasLinks'] != false; // default true
    graphPinOnDrag = data['graphPinOnDrag'] == true; // default false
    graphAutoScale = data['graphAutoScale'] != false; // default true
    graphView = (data['graphView'] as Map?)?.cast<String, dynamic>() ?? {};
    ttsVoiceName = data['ttsVoiceName'] as String?;
    ttsVoiceLocale = data['ttsVoiceLocale'] as String?;
    shapeToolKind = ShapeToolKind.values.firstWhere(
      (k) => k.name == data['shapeToolKind'],
      orElse: () => ShapeToolKind.rectangle,
    );
    shapeTemplates = [
      for (final t in (data['shapeTemplates'] as List? ?? const []))
        ShapeTemplate.fromJson(t as Map<String, dynamic>),
    ];
    eraserPartial = data['eraserPartial'] == true;
    eraserSize = (data['eraserSize'] as num?)?.toDouble() ?? 10.0;
    inkAdjustPen = data['inkAdjustPen'] != false; // default true
    inkAdjustHighlighter = data['inkAdjustHighlighter'] == true; // default false
    inkAdjustText = data['inkAdjustText'] != false; // default true
    autoPageColor.value = data['autoPageColor'] != false; // default true
    if (data['defaultPageBackground'] is Map<String, dynamic>) {
      defaultPageBackground.value = PageBackground.fromJson(
        data['defaultPageBackground'] as Map<String, dynamic>,
      );
    }

    // Device ID: generate once if missing.
    deviceId = (data['deviceId'] as String?)?.isNotEmpty == true
        ? data['deviceId'] as String
        : const Uuid().v4();

    legacyDriveChangesToken = (data['driveChangesToken'] as String?) ?? '';
    if (data['driveChangesTokens'] is Map) {
      _driveChangesTokens = Map<String, String>.from(
        (data['driveChangesTokens'] as Map).map(
          (k, v) => MapEntry(k.toString(), v?.toString() ?? ''),
        ),
      );
    }
    final lastSyncStr = data['lastSyncAt'] as String?;
    lastSyncAt = lastSyncStr != null ? DateTime.tryParse(lastSyncStr) : null;
    defaultNotebookId = data['defaultNotebookId'] as String?;
    if (data['localOnlyNotebooks'] is List) {
      localOnlyNotebooks =
          Set<String>.from((data['localOnlyNotebooks'] as List).cast<String>());
    }
    if (data['canvasViewports'] is Map<String, dynamic>) {
      _canvasViewports = Map<String, dynamic>.from(
        data['canvasViewports'] as Map,
      );
    }
    if (data['actionAnchors'] is Map<String, dynamic>) {
      _actionAnchors = Map<String, dynamic>.from(data['actionAnchors'] as Map);
    }
    if (data['readingPositions'] is Map<String, dynamic>) {
      _readingPositions = Map<String, dynamic>.from(
        data['readingPositions'] as Map,
      );
    }
    // Unified toolbar lists (current model). If absent, fall back to the
    // legacy split (add + overflow) lists and migrate them into one sequence.
    if (data['promotedToolbarMobile'] is List) {
      promotedToolbarMobile =
          (data['promotedToolbarMobile'] as List).cast<String>();
    } else if (data['promotedAddActionsMobile'] is List ||
        data['promotedOverflowActionsMobile'] is List) {
      promotedToolbarMobile = _migrateLegacyToolbar(
        (data['promotedAddActionsMobile'] as List?)?.cast<String>() ?? const [],
        (data['promotedOverflowActionsMobile'] as List?)?.cast<String>() ??
            const [],
      );
    }
    if (data['promotedToolbarDesktop'] is List) {
      promotedToolbarDesktop =
          (data['promotedToolbarDesktop'] as List).cast<String>();
    } else if (data['promotedAddActionsDesktop'] is List ||
        data['promotedOverflowActionsDesktop'] is List) {
      promotedToolbarDesktop = _migrateLegacyToolbar(
        (data['promotedAddActionsDesktop'] as List?)?.cast<String>() ??
            const ['blank', 'image'],
        (data['promotedOverflowActionsDesktop'] as List?)?.cast<String>() ??
            const ['fullscreen', 'toggle_toolbar'],
      );
    }
    if (data['pinnedToolOptionPopovers'] is List) {
      pinnedToolOptionPopovers = Set<String>.from(
        (data['pinnedToolOptionPopovers'] as List).cast<String>(),
      );
    }

    // Persist device ID if it was just generated.
    if (data['deviceId'] == null) await _persist();
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    if (themeMode.value == mode) return;
    themeMode.value = mode;
    await _persist();
  }

  Future<void> setLightThemeId(String id) async {
    if (lightThemeId.value == id) return;
    lightThemeId.value = id;
    await _persist();
  }

  Future<void> setDarkThemeId(String id) async {
    if (darkThemeId.value == id) return;
    darkThemeId.value = id;
    await _persist();
  }

  /// Saves a guided custom light theme and selects it.
  Future<void> setCustomLight(int accent, int base) async {
    customLightAccent.value = accent;
    customLightBase.value = base;
    lightThemeId.value = 'custom';
    await _persist();
  }

  /// Saves a guided custom dark theme and selects it.
  Future<void> setCustomDark(int accent, int base) async {
    customDarkAccent.value = accent;
    customDarkBase.value = base;
    darkThemeId.value = 'custom';
    await _persist();
  }

  Future<void> setLayoutMode(LayoutMode mode) async {
    if (layoutMode.value == mode) return;
    layoutMode.value = mode;
    await _persist();
  }

  /// The actual brightness in use right now, resolving System to the platform.
  /// Falls back to light if the binding isn't available (e.g. unit tests that
  /// construct a controller without a `WidgetsFlutterBinding`).
  Brightness get effectiveBrightness {
    if (themeMode.value == ThemeMode.light) return Brightness.light;
    if (themeMode.value == ThemeMode.dark) return Brightness.dark;
    try {
      return WidgetsBinding.instance.platformDispatcher.platformBrightness;
    } catch (_) {
      return Brightness.light;
    }
  }

  /// The background to seed into new pages/canvases. When [autoPageColor] is
  /// true the color tracks the theme; the user's pattern choice always applies.
  PageBackground effectiveDefaultBackground() {
    final color = autoPageColor.value
        ? (effectiveBrightness == Brightness.dark
            ? const Color(0xFF2A2A2E)
            : const Color(0xFFFFFFFF))
        : defaultPageBackground.value.color;
    return defaultPageBackground.value.copyWith(color: color);
  }

  Future<void> setDefaultPageBackground(PageBackground background) async {
    autoPageColor.value = false;
    defaultPageBackground.value = background;
    await _persist();
  }

  Future<void> setAutoPageColor(bool value) async {
    if (autoPageColor.value == value) return;
    autoPageColor.value = value;
    await _persist();
  }

  Future<void> setDriveChangesTokenFor(String accountId, String token) async {
    if (_driveChangesTokens[accountId] == token) return;
    _driveChangesTokens[accountId] = token;
    await _persist();
  }

  Future<void> removeDriveChangesToken(String accountId) async {
    if (_driveChangesTokens.remove(accountId) == null) return;
    await _persist();
  }

  /// Clears the legacy single changes token once migrated to an account.
  Future<void> clearLegacyDriveChangesToken() async {
    if (legacyDriveChangesToken.isEmpty) return;
    legacyDriveChangesToken = '';
    await _persist();
  }

  Future<void> setLastSyncAt(DateTime dt) async {
    lastSyncAt = dt;
    await _persist();
  }

  Future<void> _persist() async {
    await _settingsFile.writeAsString(
      jsonEncode({
        'themeMode': themeMode.value.name,
        'lightThemeId': lightThemeId.value,
        'darkThemeId': darkThemeId.value,
        'customLightAccent': customLightAccent.value,
        'customLightBase': customLightBase.value,
        'customDarkAccent': customDarkAccent.value,
        'customDarkBase': customDarkBase.value,
        'layoutMode': layoutMode.value.name,
        'fingerDraw': fingerDraw,
        'shapeSnap': shapeSnap,
        'autoExpandOnReveal': autoExpandOnReveal,
        'readAloudMainColumnOnly': readAloudMainColumnOnly,
        'graphNodeSize': graphNodeSize,
        'graphTextSize': graphTextSize,
        'graphLinkThickness': graphLinkThickness,
        'graphLinkOpacity': graphLinkOpacity,
        'graphLabelOpacity': graphLabelOpacity,
        'graphAlwaysLabels': graphAlwaysLabels,
        'graphAbstractItems': graphAbstractItems,
        'graphShowExternal': graphShowExternal,
        'graphShowUnlinked': graphShowUnlinked,
        'graphSameCanvasLinks': graphSameCanvasLinks,
        'graphPinOnDrag': graphPinOnDrag,
        'graphAutoScale': graphAutoScale,
        'graphView': graphView,
        'shapeToolKind': shapeToolKind.name,
        'shapeTemplates': [for (final t in shapeTemplates) t.toJson()],
        'eraserPartial': eraserPartial,
        'eraserSize': eraserSize,
        'inkAdjustPen': inkAdjustPen,
        'inkAdjustHighlighter': inkAdjustHighlighter,
        'inkAdjustText': inkAdjustText,
        'autoPageColor': autoPageColor.value,
        'defaultPageBackground': defaultPageBackground.value.toJson(),
        'deviceId': deviceId,
        'driveChangesToken': legacyDriveChangesToken,
        'driveChangesTokens': _driveChangesTokens,
        'lastSyncAt': lastSyncAt?.toIso8601String(),
        'localOnlyNotebooks': localOnlyNotebooks.toList(),
        'defaultNotebookId': defaultNotebookId,
        'canvasViewports': _canvasViewports,
        'actionAnchors': _actionAnchors,
        'readingPositions': _readingPositions,
        'ttsVoiceName': ttsVoiceName,
        'ttsVoiceLocale': ttsVoiceLocale,
        'promotedToolbarMobile': promotedToolbarMobile,
        'promotedToolbarDesktop': promotedToolbarDesktop,
        'pinnedToolOptionPopovers': pinnedToolOptionPopovers.toList(),
      }),
    );
  }

  ThemeMode _parseThemeMode(dynamic value) {
    return ThemeMode.values.firstWhere(
      (m) => m.name == value,
      orElse: () => ThemeMode.system,
    );
  }

  LayoutMode _parseLayoutMode(dynamic value) {
    return LayoutMode.values.firstWhere(
      (m) => m.name == value,
      orElse: () => LayoutMode.auto,
    );
  }
}
