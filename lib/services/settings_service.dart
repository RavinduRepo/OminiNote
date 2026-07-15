import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';
import '../canvas/shape_recognizer.dart' show ShapeToolKind;
import '../models/canvas_page.dart';
import '../models/shape_template.dart';

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
    layoutMode.value = _parseLayoutMode(data['layoutMode']);
    fingerDraw = data['fingerDraw'] == true;
    shapeSnap = data['shapeSnap'] != false; // default ON
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

    // Persist device ID if it was just generated.
    if (data['deviceId'] == null) await _persist();
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    if (themeMode.value == mode) return;
    themeMode.value = mode;
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
        'layoutMode': layoutMode.value.name,
        'fingerDraw': fingerDraw,
        'shapeSnap': shapeSnap,
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
