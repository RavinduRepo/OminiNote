import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';
import 'screens/desktop_shell_screen.dart';
import 'screens/mobile_shell_screen.dart';
import 'screens/note_search.dart';
import 'services/auth_service.dart';
import 'services/notebook_service.dart';
import 'services/settings_service.dart';
import 'services/sync_service.dart';
import 'utils/notebook_share_ui.dart';
import 'utils/open_pdf_ui.dart';
import 'utils/progress_overlay.dart';

/// A `.omninote` file path or `omninote://` URI the desktop OS launched us with
/// (Linux/Windows forward argv to the Dart entrypoint). Consumed once by the app
/// root. macOS delivers opens via an `openFile`/`openURLs` event instead (see
/// the method channel in [_NoteAppState]).
String? _initialDesktopOpen;

void main(List<String> args) async {
  // Ensures hardware bindings are initialized for rendering
  WidgetsFlutterBinding.ensureInitialized();

  // Desktop open-with: the OS may launch us with a file path or omninote:// URI
  // as a command-line argument (double-click a .omninote / tap a link).
  if (Platform.isLinux || Platform.isWindows) {
    for (final a in args) {
      final lower = a.toLowerCase();
      if (a.startsWith('omninote://') ||
          lower.endsWith('.omninote') ||
          lower.endsWith('.pdf')) {
        _initialDesktopOpen = a;
        break;
      }
    }
  }

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
    // Global open-with / share-link callbacks only have the root Navigator's
    // own context (no Overlay ancestor), so give ProgressOverlay a way to reach
    // the navigator's overlay directly. See progressOverlayFallback's doc.
    progressOverlayFallback = () => _navigatorKey.currentState?.overlay;
    _setupIncomingFiles();
  }

  @override
  void dispose() {
    _intentSub?.cancel();
    progressOverlayFallback = null;
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// Handles a `.omninote` file opened/shared with the app (Android open-with /
  /// share sheet) — routes it into the notebook-import flow. Desktop open-with
  /// needs native-runner wiring and is handled with the installer packaging.
  void _setupIncomingFiles() {
    if (Platform.isAndroid || Platform.isIOS) {
      // Cold start: the app was launched by tapping the file.
      ReceiveSharingIntent.instance.getInitialMedia().then((files) {
        if (files.isNotEmpty) _handleIncoming(files);
        ReceiveSharingIntent.instance.reset();
      });
      // Warm: the app was already running.
      _intentSub = ReceiveSharingIntent.instance
          .getMediaStream()
          .listen(_handleIncoming);
      return;
    }
    // Desktop cold-start: Linux/Windows forwarded the file path / omninote://
    // URI as a launch argument (captured in main()).
    final initial = _initialDesktopOpen;
    _initialDesktopOpen = null;
    if (initial != null) _handleDesktopOpen(initial);
    // macOS delivers opens via an openFile/openURLs event; the Swift runner
    // pushes them over this channel (also covers desktop warm-start there).
    if (Platform.isMacOS) {
      const channel = MethodChannel('omninote/open');
      channel.setMethodCallHandler((call) async {
        if (call.method == 'open' && call.arguments is String) {
          _handleDesktopOpen(call.arguments as String);
        }
        return null;
      });
      // Tell the native runner we're ready, so any file/link opened before
      // Flutter started (cold launch) is flushed to us now.
      channel.invokeMethod('ready');
    }
  }

  void _handleDesktopOpen(String item) {
    // Linux (%U) and macOS (open urls) may deliver local files as file:// URIs
    // rather than plain paths — File() can't open those, so convert first.
    if (item.startsWith('file://')) {
      try {
        item = Uri.parse(item).toFilePath();
      } catch (_) {}
    }
    if (item.startsWith('omninote://')) {
      _handleLink(item);
    } else if (item.toLowerCase().endsWith('.pdf')) {
      _handlePdfOpen(item);
    } else {
      _importFromPath(item);
    }
  }

  void _handleIncoming(List<SharedMediaFile> files) {
    if (files.isEmpty) return;
    // A tapped omninote:// share link arrives as a URL "media" entry.
    if (files.first.path.startsWith('omninote://')) {
      _handleLink(files.first.path);
      return;
    }
    // Prefer a recognized type (a bundle or a PDF), else the first file.
    String? path;
    for (final ext in ['.omninote', '.pdf']) {
      for (final m in files) {
        if (m.path.toLowerCase().endsWith(ext)) {
          path = m.path;
          break;
        }
      }
      if (path != null) break;
    }
    path ??= files.first.path;
    if (path.toLowerCase().endsWith('.pdf')) {
      _handlePdfOpen(path);
    } else {
      _importFromPath(path);
    }
  }

  /// A PDF opened *with* the app (Android open-with / share, desktop launch
  /// arg, macOS openFile). Reads it and routes into the open-PDF flow (ask
  /// where, then create a PDF-backed canvas and open it).
  Future<void> _handlePdfOpen(String path) async {
    List<int> bytes;
    try {
      bytes = await File(path).readAsBytes();
    } catch (_) {
      return;
    }
    var name = path.split(Platform.pathSeparator).last.split('/').last;
    if (name.toLowerCase().endsWith('.pdf')) {
      name = name.substring(0, name.length - 4);
    }
    if (name.isEmpty) name = 'PDF';
    // Run after a frame so the navigator/context is available (cold start).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _navigatorKey.currentContext;
      if (ctx != null) openPdfIntoApp(ctx, bytes, name);
    });
  }

  void _handleLink(String uriStr) {
    final uri = Uri.tryParse(uriStr);
    if (uri == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _navigatorKey.currentContext;
      if (ctx != null) importNotebookFromLink(ctx, uri);
    });
  }

  void _importFromPath(String path) {
    // Stream the import straight from the file (memory-safe — the OOM fix);
    // don't read the whole bundle into RAM here.
    // Run after a frame so the navigator/context is available (cold start).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _navigatorKey.currentContext;
      if (ctx != null) importBundleFileUi(ctx, path);
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
    final s = SettingsService();
    return ListenableBuilder(
      // Rebuild on theme mode, either palette-variant pick, or a custom-theme
      // edit, so the chosen light/dark palettes apply live.
      listenable: Listenable.merge([
        s.themeMode,
        s.lightThemeId,
        s.darkThemeId,
        s.customLightAccent,
        s.customLightBase,
        s.customDarkAccent,
        s.customDarkBase,
      ]),
      builder: (context, _) {
        return MaterialApp(
          title: 'Omininote',
          debugShowCheckedModeBanner: false,
          navigatorKey: _navigatorKey,
          theme: s.effectiveLightVariant().build(),
          darkTheme: s.effectiveDarkVariant().build(),
          themeMode: s.themeMode.value,
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
                : const MobileShellScreen();
          },
        );
      },
    );
  }
}
