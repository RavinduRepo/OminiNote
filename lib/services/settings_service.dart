import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
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

  Future<void> init() async {
    final appDir = await getApplicationDocumentsDirectory();
    _settingsFile = File('${appDir.path}/settings.json');

    if (await _settingsFile.exists()) {
      try {
        final data =
            jsonDecode(await _settingsFile.readAsString())
                as Map<String, dynamic>;
        themeMode.value = _parseThemeMode(data['themeMode']);
        layoutMode.value = _parseLayoutMode(data['layoutMode']);
        if (data['defaultPageBackground'] is Map<String, dynamic>) {
          defaultPageBackground.value = PageBackground.fromJson(
            data['defaultPageBackground'] as Map<String, dynamic>,
          );
        }
      } catch (_) {
        // Corrupt/partial settings file — fall back to defaults.
      }
    }
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

  Future<void> _persist() async {
    await _settingsFile.writeAsString(
      jsonEncode({
        'themeMode': themeMode.value.name,
        'layoutMode': layoutMode.value.name,
        'defaultPageBackground': defaultPageBackground.value.toJson(),
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
