import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';
import 'screens/desktop_shell_screen.dart';
import 'screens/home_screen.dart';
import 'screens/note_search.dart';
import 'services/auth_service.dart';
import 'services/notebook_service.dart';
import 'services/settings_service.dart';
import 'services/sync_service.dart';
import 'theme/app_theme.dart';
import 'utils/notebook_share_ui.dart';

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

  // Auth + sync: restore connected accounts, then start the sync loop
  // (per-account Drive clients are created + inited by SyncService as it brings
  // each account up; journal replay is fast; network work runs unawaited).
  await AuthService().init();
  SyncService().init(); // Don't await — performs network operations.

  runApp(const NoteApp());
}

class NoteApp extends StatefulWidget {
  const NoteApp({super.key});

  @override
  State<NoteApp> createState() => _NoteAppState();
}

class _NoteAppState extends State<NoteApp> with WidgetsBindingObserver {
  final _navigatorKey = GlobalKey<NavigatorState>();
  StreamSubscription<List<SharedMediaFile>>? _intentSub;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _setupIncomingFiles();
  }

  @override
  void dispose() {
    _intentSub?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// Handles a `.omninote` file opened/shared with the app (Android open-with /
  /// share sheet) — routes it into the notebook-import flow. Desktop open-with
  /// needs native-runner wiring and is handled with the installer packaging.
  void _setupIncomingFiles() {
    if (!(Platform.isAndroid || Platform.isIOS)) return;
    // Cold start: the app was launched by tapping the file.
    ReceiveSharingIntent.instance.getInitialMedia().then((files) {
      if (files.isNotEmpty) _handleIncoming(files);
      ReceiveSharingIntent.instance.reset();
    });
    // Warm: the app was already running.
    _intentSub =
        ReceiveSharingIntent.instance.getMediaStream().listen(_handleIncoming);
  }

  void _handleIncoming(List<SharedMediaFile> files) {
    if (files.isEmpty) return;
    // A tapped omninote:// share link arrives as a URL "media" entry.
    if (files.first.path.startsWith('omninote://')) {
      _handleLink(files.first.path);
      return;
    }
    final f = files.firstWhere(
      (m) => m.path.toLowerCase().endsWith('.omninote'),
      orElse: () => files.first,
    );
    _importFromPath(f.path);
  }

  void _handleLink(String uriStr) {
    final uri = Uri.tryParse(uriStr);
    if (uri == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _navigatorKey.currentContext;
      if (ctx != null) importNotebookFromLink(ctx, uri);
    });
  }

  Future<void> _importFromPath(String path) async {
    List<int> bytes;
    try {
      bytes = await File(path).readAsBytes();
    } catch (_) {
      return;
    }
    // Run after a frame so the navigator/context is available (cold start).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _navigatorKey.currentContext;
      if (ctx != null) importBundleBytes(ctx, bytes);
    });
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
          navigatorKey: _navigatorKey,
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
