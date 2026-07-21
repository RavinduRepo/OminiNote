import 'dart:async';

import 'package:flutter/material.dart';
import '../services/link_navigator.dart';
import '../services/search_service.dart';
import '../theme/app_theme.dart';
import 'canvas_workspace_screen.dart';
import 'graph_screen.dart';
import 'home_screen.dart';
import 'note_search.dart';
import 'notebook_screen.dart';
import 'section_screen.dart';
import 'settings_screen.dart';

/// The mobile shell: a bottom navigation bar over four destinations —
/// Notebooks, Search, Bin, Settings. Each tab owns a **nested [Navigator]** so
/// the notebook → section → canvas-list drill-down happens *inside* the tab and
/// the bottom bar stays visible the whole way down. Opening a canvas pushes on
/// the **root** navigator (above this shell), which covers the bar — so the
/// editor is full-bleed with no bottom bar, per the design.
class MobileShellScreen extends StatefulWidget {
  const MobileShellScreen({super.key});

  @override
  State<MobileShellScreen> createState() => _MobileShellScreenState();
}

class _MobileShellScreenState extends State<MobileShellScreen> {
  // Order: Search sits at the far end (away from Notebooks) so its keyboard
  // never intrudes when you land on Notebooks — and it only focuses on entry.
  static const _kNotebooks = 0;
  static const _kGraph = 1; // Connections graph (Bin moved to the home app bar)
  static const _kSettings = 2;
  static const _kSearch = 3;

  int _index = _kNotebooks;

  // A PageView so tabs slide horizontally — tapping a tab animates in that
  // tab's direction, and (at a tab root) a horizontal swipe moves between tabs.
  final PageController _pageController = PageController();

  // A reveal pins the PageView to the Notebooks tab for a short window so a
  // stray settle (the off-stage-jump / post-pop layout churn) can't land on an
  // adjacent tab. See _jumpToNotebooksTab + onPageChanged.
  bool _revealing = false;
  Timer? _revealTimer;

  // Bumped when the Search tab is opened, so its field focuses ONLY then — the
  // field never autofocuses on build, which used to pop the keyboard when you
  // navigated back to Notebooks while the (kept-alive) Search tab rebuilt.
  final ValueNotifier<int> _searchFocus = ValueNotifier(0);

  // One navigator per tab, so each tab keeps its own back stack and the bar
  // stays put while drilling in. Keyed so the shell can drive the Notebooks
  // tab when revealing a search result.
  final List<GlobalKey<NavigatorState>> _navKeys =
      List.generate(4, (_) => GlobalKey<NavigatorState>());

  // Per-tab observer: pushes/pops inside a tab flip whether swiping between
  // tabs is allowed (disabled once you've drilled in, so a horizontal drag
  // doesn't switch tabs while you're inside a notebook/section).
  late final List<NavigatorObserver> _navObservers = List.generate(
    4,
    (_) => _TabNavObserver(_scheduleSwipeRecheck),
  );

  // Whether horizontal tab-swiping is currently allowed. Cached (not read live
  // in build) because the observers that change it fire *during* a navigator's
  // build — including the initial-route push at startup — so we recompute it
  // post-frame and only setState when it actually flips.
  bool _swipeEnabled = true;
  bool _recheckScheduled = false;

  void _scheduleSwipeRecheck() {
    if (_recheckScheduled) return;
    _recheckScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _recheckScheduled = false;
      if (!mounted) return;
      final enabled = !(_navKeys[_index].currentState?.canPop() ?? false);
      if (enabled != _swipeEnabled) setState(() => _swipeEnabled = enabled);
    });
  }

  /// Switches the PageView to the Notebooks tab safely.
  ///
  /// A reveal is often triggered from *inside* a full-bleed canvas that covers
  /// this shell on the root navigator. On the frame the canvas is popped, the
  /// shell's `PageView` is off-stage with no viewport metrics, and the pushes
  /// that follow (for a section/canvas target) churn its layout — so the
  /// controller can spuriously settle onto the adjacent page (Bin): the "reveal
  /// also swipes me into the Bin" bug. Jump-timing tricks weren't reliable, so
  /// we *pin* the tab for a short window instead: while `_revealing`, any
  /// `onPageChanged` that reports a non-Notebooks page is snapped straight back.
  void _jumpToNotebooksTab() {
    _revealing = true;
    _revealTimer?.cancel();
    _revealTimer = Timer(const Duration(milliseconds: 550), () {
      if (!mounted) return;
      _revealing = false;
      _scheduleSwipeRecheck();
    });
    setState(() => _index = _kNotebooks);
    void tryJump() {
      if (!mounted || !_revealing) return;
      if (_pageController.hasClients &&
          _pageController.position.hasContentDimensions) {
        _pageController.jumpToPage(_kNotebooks);
      } else {
        WidgetsBinding.instance.addPostFrameCallback((_) => tryJump());
      }
    }

    tryJump();
  }

  @override
  void initState() {
    super.initState();
    // Internal links ("Connections") navigate through the same reveal path as
    // search results, whichever shell is active.
    LinkNavigator().register(_revealFromLink);
    // Quick-note (and any "open this canvas") lands IN the canvas — mobile's
    // link-reveal stops at the list for containers, so it needs the open path.
    LinkNavigator().registerOpenCanvas(_revealSearchResult);
  }

  /// A tapped internal link can come from *inside* a full-bleed canvas, which
  /// covers this shell on the root navigator — pop back to the shell first so
  /// the reveal is actually visible (and canvases don't stack up). Same-canvas
  /// targets never reach here (the Connections sheet jumps in place instead).
  ///
  /// Mobile design rule ("stop one level up"): a link to a *container*
  /// (notebook / folder / section / canvas) lands on its **parent list** with
  /// the target briefly glowing, instead of auto-opening the target — opening
  /// it would lose the "this is what was linked" context. Targets *inside* a
  /// canvas (page/element/bookmark — always carrying a pageId) still open the
  /// canvas: there the landing flash/page jump is the indication. Desktop
  /// keeps full reveal (everything is visible at once there).
  void _revealFromLink(SearchResult r) {
    Navigator.of(context, rootNavigator: true)
        .popUntil((route) => route.isFirst);
    if (r.pageId != null) {
      _revealSearchResult(r); // in-canvas target: open + flash/jump
      return;
    }
    _jumpToNotebooksTab();
    final nav = _navKeys[_kNotebooks].currentState;
    if (nav == null) return;
    nav.popUntil((route) => route.isFirst);

    if (r.kind == SearchKind.notebook) {
      HomeScreen.glowRequest.value = r.notebook.id; // glow the home card
      return;
    }
    // Notebook-level folder or section: notebook screen, target glowing.
    if (r.section == null || r.kind == SearchKind.section) {
      nav.push(slideRoute(NotebookScreen(
        notebook: r.notebook,
        glowId: r.kind == SearchKind.superSection ? r.folderId : r.section?.id,
      )));
      return;
    }
    // Canvas or canvas-tree folder: drill to the section's canvas list,
    // target glowing — the canvas itself is NOT opened.
    nav.push(slideRoute(
      NotebookScreen(notebook: r.notebook, glowId: r.section!.id),
    ));
    nav.push(slideRoute(SectionScreen(
      section: r.section!,
      glowId: r.kind == SearchKind.superSection ? r.folderId : r.canvas?.id,
    )));
  }

  @override
  void dispose() {
    LinkNavigator().unregister(_revealFromLink);
    LinkNavigator().unregisterOpenCanvas(_revealSearchResult);
    _revealTimer?.cancel();
    _pageController.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  // Per-tab side effects on entry. Search focuses promptly (so the keyboard
  // comes up), but the Bin reload is deferred/debounced ~350ms — long enough
  // to clear a tap animation (300ms) or a swipe settle — so any rescan runs
  // after the motion, not during it. The Bin's own cache then skips the scan
  // entirely unless the store changed.
  void _onEnterTab(int i) {
    if (i == _kSearch) _searchFocus.value++;
  }

  void _selectTab(int i) {
    if (i == _index) {
      // Re-tapping the active tab pops it back to its root (common pattern).
      _navKeys[i].currentState?.popUntil((r) => r.isFirst);
      _onEnterTab(i);
      return;
    }
    // Slide toward the tapped tab. onPageChanged updates _index.
    _pageController.animateToPage(
      i,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOutCubic,
    );
  }

  /// Reveals a search result: switch to the Notebooks tab, rebuild its drill-in
  /// stack (so Back walks up the hierarchy), and open a canvas above the shell.
  void _revealSearchResult(SearchResult r) {
    _jumpToNotebooksTab();
    final nav = _navKeys[_kNotebooks].currentState;
    if (nav == null) return;
    nav.popUntil((route) => route.isFirst);

    final notebookGlow = r.kind == SearchKind.superSection && r.section == null
        ? r.folderId
        : r.section?.id;
    nav.push(slideRoute(
      NotebookScreen(notebook: r.notebook, glowId: notebookGlow),
    ));
    if (r.section != null) {
      final sectionGlow =
          r.kind == SearchKind.superSection ? r.folderId : r.canvas?.id;
      nav.push(slideRoute(
        SectionScreen(section: r.section!, glowId: sectionGlow),
      ));
    }
    if (r.canvas != null) {
      // Canvas opens on the root navigator so the bottom bar is hidden.
      Navigator.of(context, rootNavigator: true).push(slideRoute(
        CanvasWorkspaceScreen(
            initialCanvas: r.canvas!, initialPageId: r.pageId),
      ));
    }
  }

  Widget _tabRoot(int i) => switch (i) {
        _kNotebooks => const HomeScreen(),
        _kGraph => const GraphScreen(),
        _kSettings => const SettingsScreen(),
        _kSearch => NoteSearchView(
            onReveal: _revealSearchResult,
            focusSignal: _searchFocus,
          ),
        _ => const HomeScreen(),
      };

  Widget _buildTabNavigator(int i) {
    // Kept alive so a tab's nested-navigator stack (and its GlobalKey) survives
    // being swiped off-screen — PageView would otherwise dispose far pages.
    return _KeepAliveTab(
      child: Navigator(
        key: _navKeys[i],
        observers: [_navObservers[i]],
        onGenerateRoute: (settings) => MaterialPageRoute(
          settings: settings,
          builder: (_) => _tabRoot(i),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      // Intercept the system back: pop the active tab's nested navigator first;
      // if it can't (already at the tab root), let the framework handle it
      // (backgrounds the app), but first slide back to the Notebooks tab.
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        final nav = _navKeys[_index].currentState;
        if (nav != null && nav.canPop()) {
          nav.pop();
        } else if (_index != _kNotebooks) {
          _selectTab(_kNotebooks);
        }
      },
      child: Scaffold(
        body: PageView.builder(
          controller: _pageController,
          itemCount: 4,
          // Swipe between tabs only at a tab's root; once drilled in, lock it
          // so horizontal drags belong to the content, not tab-switching.
          physics: _swipeEnabled
              ? const ClampingScrollPhysics()
              : const NeverScrollableScrollPhysics(),
          onPageChanged: (i) {
            // While revealing, the PageView may spuriously settle onto an
            // adjacent tab — snap it back to Notebooks and ignore the report.
            if (_revealing && i != _kNotebooks) {
              if (_pageController.hasClients) {
                _pageController.jumpToPage(_kNotebooks);
              }
              return;
            }
            setState(() => _index = i);
            _scheduleSwipeRecheck(); // the new tab may be drilled in
            _onEnterTab(i); // reload bin / focus search on entry
            // Landing on any non-Search tab drops the keyboard, so the search
            // field never holds focus off-tab (which made the keyboard re-pop
            // when returning to a list from a canvas).
            if (i != _kSearch) FocusManager.instance.primaryFocus?.unfocus();
          },
          itemBuilder: (context, i) => _buildTabNavigator(i),
        ),
        bottomNavigationBar: _MobileTabBar(
          index: _index,
          onSelect: _selectTab,
        ),
      ),
    );
  }
}

/// Observes a tab's nested navigator so the shell can recompute whether swiping
/// between tabs is allowed whenever that tab pushes/pops.
class _TabNavObserver extends NavigatorObserver {
  final VoidCallback onChanged;
  _TabNavObserver(this.onChanged);

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      onChanged();
  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      onChanged();
  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      onChanged();
  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) =>
      onChanged();
}

/// Keeps a PageView child (a tab's navigator) mounted while off-screen.
class _KeepAliveTab extends StatefulWidget {
  final Widget child;
  const _KeepAliveTab({required this.child});

  @override
  State<_KeepAliveTab> createState() => _KeepAliveTabState();
}

class _KeepAliveTabState extends State<_KeepAliveTab>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return widget.child;
  }
}

/// Custom bottom bar matching the redesign: neutral surface, a hairline top
/// border, icon-over-label items that go amber when active (no Material pill).
class _MobileTabBar extends StatelessWidget {
  final int index;
  final ValueChanged<int> onSelect;

  const _MobileTabBar({required this.index, required this.onSelect});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = theme.extension<AppPalette>()!;
    final bottomInset = MediaQuery.of(context).padding.bottom;

    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border: Border(top: BorderSide(color: palette.border)),
      ),
      padding: EdgeInsets.only(bottom: bottomInset),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 60,
          child: Row(
            children: [
              // Order: Notebooks · Graph · Settings · Search (Search last so its
              // keyboard is never adjacent to Notebooks). Bin moved to the
              // home-screen app bar.
              _TabItem(
                icon: Icons.book_outlined,
                activeIcon: Icons.book,
                label: 'Notebooks',
                active: index == 0,
                onTap: () => onSelect(0),
              ),
              _TabItem(
                icon: Icons.hub_outlined,
                activeIcon: Icons.hub,
                label: 'Graph',
                active: index == 1,
                onTap: () => onSelect(1),
              ),
              _TabItem(
                icon: Icons.settings_outlined,
                activeIcon: Icons.settings,
                label: 'Settings',
                active: index == 2,
                onTap: () => onSelect(2),
              ),
              _TabItem(
                icon: Icons.search,
                activeIcon: Icons.search,
                label: 'Search',
                active: index == 3,
                onTap: () => onSelect(3),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TabItem extends StatelessWidget {
  final IconData icon;
  final IconData activeIcon;
  final String label;
  final bool active;
  final VoidCallback onTap;

  const _TabItem({
    required this.icon,
    required this.activeIcon,
    required this.label,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final palette = Theme.of(context).extension<AppPalette>()!;
    final color = active ? palette.accent : palette.textDim;
    return Expanded(
      child: InkResponse(
        onTap: onTap,
        radius: 44,
        highlightColor: Colors.transparent,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            AnimatedScale(
              scale: active ? 1.0 : 0.96,
              duration: const Duration(milliseconds: 160),
              curve: Curves.easeOut,
              child: Icon(active ? activeIcon : icon, size: 22, color: color),
            ),
            const SizedBox(height: 4),
            AnimatedDefaultTextStyle(
              duration: const Duration(milliseconds: 160),
              style: TextStyle(
                fontSize: 10.5,
                fontWeight: active ? FontWeight.w600 : FontWeight.w500,
                color: color,
              ),
              child: Text(label),
            ),
          ],
        ),
      ),
    );
  }
}
