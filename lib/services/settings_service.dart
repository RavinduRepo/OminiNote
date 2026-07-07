import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';
import '../models/canvas_page.dart';

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
    const PageBackground(),
  );

  /// Mobile (single-pane, pushed navigation) vs desktop (split-view sidebar)
  /// shell, or auto-detect from window width.
  final ValueNotifier<LayoutMode> layoutMode = ValueNotifier(LayoutMode.auto);

  // ── Sync-related fields ─────────────────────────────────────────────────

  /// Stable identifier for this installation, generated once and persisted.
  /// Used in lock files so other devices know who holds a lock.
  late String deviceId;

  /// Drive Changes API page token — persisted across restarts so we only
  /// pull deltas, not the full Drive.
  String driveChangesToken = '';

  /// Timestamp of the last successful sync, or null if never synced.
  DateTime? lastSyncAt;

  Future<void> init() async {
    final appDir = await getApplicationDocumentsDirectory();
    _settingsFile = File('${appDir.path}/settings.json');

    Map<String, dynamic> data = {};
    if (await _settingsFile.exists()) {
      try {
        data = jsonDecode(await _settingsFile.readAsString())
            as Map<String, dynamic>;
      } catch (_) {
        // Corrupt/partial settings file — fall back to defaults.
      }
    }

    themeMode.value = _parseThemeMode(data['themeMode']);
    layoutMode.value = _parseLayoutMode(data['layoutMode']);
    if (data['defaultPageBackground'] is Map<String, dynamic>) {
      defaultPageBackground.value = PageBackground.fromJson(
        data['defaultPageBackground'] as Map<String, dynamic>,
      );
    }

    // Device ID: generate once if missing.
    deviceId = (data['deviceId'] as String?)?.isNotEmpty == true
        ? data['deviceId'] as String
        : const Uuid().v4();

    driveChangesToken = (data['driveChangesToken'] as String?) ?? '';
    final lastSyncStr = data['lastSyncAt'] as String?;
    lastSyncAt = lastSyncStr != null ? DateTime.tryParse(lastSyncStr) : null;

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

  Future<void> setDefaultPageBackground(PageBackground background) async {
    defaultPageBackground.value = background;
    await _persist();
  }

  Future<void> setDriveChangesToken(String token) async {
    if (driveChangesToken == token) return;
    driveChangesToken = token;
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
        'defaultPageBackground': defaultPageBackground.value.toJson(),
        'deviceId': deviceId,
        'driveChangesToken': driveChangesToken,
        'lastSyncAt': lastSyncAt?.toIso8601String(),
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
