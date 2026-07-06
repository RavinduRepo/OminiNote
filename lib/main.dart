import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';
import 'screens/desktop_shell_screen.dart';
import 'screens/home_screen.dart';
import 'services/notebook_service.dart';
import 'services/settings_service.dart';
import 'theme/app_theme.dart';

void main() async {
  // Ensures hardware bindings are initialized for rendering
  WidgetsFlutterBinding.ensureInitialized();

  // pdfrx is used engine-only (page rendering, no PdfViewer) — needs an
  // explicit init when documents are opened directly.
  await pdfrxFlutterInitialize();

  // Initialize services
  await SettingsService().init();
  await NotebookService().init();

  runApp(const NoteApp());
}

class NoteApp extends StatelessWidget {
  const NoteApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: SettingsService().themeMode,
      builder: (context, themeMode, _) {
        return MaterialApp(
          title: 'Omininote',
          debugShowCheckedModeBanner: false,
          theme: AppTheme.light(),
          darkTheme: AppTheme.dark(),
          themeMode: themeMode,
          home: const _RootRouter(),
        );
      },
    );
  }
}

/// Picks the mobile (single-pane, pushed navigation) or desktop (split-view
/// sidebar) shell. In [LayoutMode.auto] this follows the window width live —
/// resizing across the breakpoint swaps shells immediately, same as the
/// Settings toggle overriding it manually.
class _RootRouter extends StatelessWidget {
  const _RootRouter();

  /// Material's "expanded" window-size-class threshold — wide enough for a
  /// permanent two-pane layout without feeling cramped.
  static const double _desktopBreakpoint = 840;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<LayoutMode>(
      valueListenable: SettingsService().layoutMode,
      builder: (context, mode, _) {
        return LayoutBuilder(
          builder: (context, constraints) {
            final isDesktop = switch (mode) {
              LayoutMode.desktop => true,
              LayoutMode.mobile => false,
              LayoutMode.auto => constraints.maxWidth >= _desktopBreakpoint,
            };
            return isDesktop
                ? const DesktopShellScreen()
                : const HomeScreen();
          },
        );
      },
    );
  }
}
