import 'dart:async';
import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';
import 'screens/desktop_shell_screen.dart';
import 'screens/home_screen.dart';
import 'screens/note_search.dart';
import 'services/auth_service.dart';
import 'services/drive_service.dart';
import 'services/notebook_service.dart';
import 'services/settings_service.dart';
import 'services/sync_service.dart';
import 'theme/app_theme.dart';

void main() async {
  // Ensures hardware bindings are initialized for rendering
  WidgetsFlutterBinding.ensureInitialized();

  // pdfrx is used engine-only (page rendering, no PdfViewer) — needs an
  // explicit init when documents are opened directly.
  await pdfrxFlutterInitialize();

  // Initialize services in dependency order.
  await SettingsService().init();
  await NotebookService().init();
  // Local-only tombstone cleanup (v3 §4) — fine to run for local-only users
  // too, not gated on sign-in. Fire-and-forget so launch isn't slowed down.
  unawaited(NotebookService().runGarbageCollection());

  // Auth + sync: restore silent sign-in, prime the Drive client, then start
  // the sync loop (journal replay is fast; network work runs unawaited).
  await AuthService().init();
  await DriveService().init();
  SyncService().init(); // Don't await — performs network operations.

  runApp(const NoteApp());
}

class NoteApp extends StatefulWidget {
  const NoteApp({super.key});

  @override
  State<NoteApp> createState() => _NoteAppState();
}

class _NoteAppState extends State<NoteApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Backgrounding: flush pending edits during the grace window so nothing is
    // stranded. Returning to foreground: pull anything that changed elsewhere.
    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.inactive:
        SyncService().flushPending();
      case AppLifecycleState.resumed:
        SyncService().syncNow();
      default:
        break;
    }
  }

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
          navigatorObservers: [searchRouteObserver],
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
