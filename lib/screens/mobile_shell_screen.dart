import 'dart:async';

import 'package:flutter/material.dart';
import '../services/search_service.dart';
import '../theme/app_theme.dart';
import 'bin_screen.dart';
import 'canvas_workspace_screen.dart';
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
  static const _kBin = 1;
  static const _kSettings = 2;
  static const _kSearch = 3;

  int _index = _kNotebooks;

  // A PageView so tabs slide horizontally — tapping a tab animates in that
  // tab's direction, and (at a tab root) a horizontal swipe moves between tabs.
  final PageController _pageController = PageController();

  // Bumped each time the Bin tab is opened, so the kept-alive BinScreen
  // reloads (something deleted elsewhere must appear when you switch back to it).
  final ValueNotifier<int> _binRefresh = ValueNotifier(0);

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

  // Defers the (potentially whole-store) Bin reload until the tab slide has
  // settled, so the scan never competes with the swipe animation for frames.
  Timer? _binReloadTimer;

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

  @override
  void dispose() {
    _binReloadTimer?.cancel();
    _pageController.dispose();
    _binRefresh.dispose();
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
    if (i == _kBin) {
      _binReloadTimer?.cancel();
      _binReloadTimer = Timer(const Duration(milliseconds: 350), () {
        if (mounted) _binRefresh.value++;
      });
    }
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
    _pageController.jumpToPage(_kNotebooks);
    setState(() => _index = _kNotebooks);
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
        _kBin => BinScreen(refreshSignal: _binRefresh),
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
              // Order: Notebooks · Bin · Settings · Search (Search last so its
              // keyboard is never adjacent to Notebooks).
              _TabItem(
                icon: Icons.book_outlined,
                activeIcon: Icons.book,
                label: 'Notebooks',
                active: index == 0,
                onTap: () => onSelect(0),
              ),
              _TabItem(
                icon: Icons.delete_outline,
                activeIcon: Icons.delete,
                label: 'Bin',
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
