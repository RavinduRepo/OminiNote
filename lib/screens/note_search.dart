import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/search_service.dart';
import '../services/sync_service.dart';
import '../theme/app_theme.dart';
import 'canvas_workspace_screen.dart';
import 'notebook_screen.dart';
import 'section_screen.dart';

/// Observes route pushes/pops so a mobile list screen can (re)glow a search
/// target when it becomes visible again (e.g. popping back from an opened
/// canvas to the section list). Registered in [MaterialApp.navigatorObservers].
final RouteObserver<PageRoute<dynamic>> searchRouteObserver =
    RouteObserver<PageRoute<dynamic>>();

/// Builds the search index and opens the search screen. Call from a search icon
/// on any list screen (or a Ctrl/Cmd+K shortcut on desktop).
///
/// [onReveal] lets a host (the desktop shell) open the result *in place* —
/// expanding + selecting it in its panes — instead of the mobile behaviour of
/// pushing the full hierarchy. When null (mobile), selecting a result rebuilds
/// the natural back stack (Notebooks → Sections → Canvases → Canvas) so Back
/// walks up the tree.
Future<void> openNoteSearch(
  BuildContext context, {
  void Function(SearchResult)? onReveal,
}) async {
  final index = await SearchService().buildIndex();
  if (!context.mounted) return;
  await Navigator.of(context).push(MaterialPageRoute(
    fullscreenDialog: true,
    builder: (_) =>
        _SearchScreen(index: index, onReveal: onReveal, autofocus: true),
  ));
}

// Intents for keyboard navigation of the results list while the search field
// keeps focus. Mapped in a Shortcuts wrapper around the field, so they win over
// the text field's default arrow/enter behaviour (nearest Shortcuts wins).
/// The user-facing result categories the search screen can filter to. Each maps
/// to one or more [SearchKind]s (super-sections travel with sections).
enum _ResultFilter { notebooks, sections, canvases, bookmarks, things }

/// The four name-level filters (everything except content). "Things" is handled
/// on a separate path (content index), so it's excluded here.
const List<_ResultFilter> _nameFilters = [
  _ResultFilter.notebooks,
  _ResultFilter.sections,
  _ResultFilter.canvases,
  _ResultFilter.bookmarks,
];

Set<SearchKind> _kindsFor(_ResultFilter f) => switch (f) {
      _ResultFilter.notebooks => {SearchKind.notebook},
      _ResultFilter.sections => {SearchKind.section, SearchKind.superSection},
      _ResultFilter.canvases => {SearchKind.canvas},
      _ResultFilter.bookmarks => {SearchKind.bookmark},
      _ResultFilter.things => {SearchKind.thing},
    };

String _filterLabel(_ResultFilter f) => switch (f) {
      _ResultFilter.notebooks => 'Notebooks',
      _ResultFilter.sections => 'Sections',
      _ResultFilter.canvases => 'Canvases',
      _ResultFilter.bookmarks => 'Bookmarks',
      _ResultFilter.things => 'Things',
    };

class _NextIntent extends Intent {
  const _NextIntent();
}

class _PrevIntent extends Intent {
  const _PrevIntent();
}

class _OpenIntent extends Intent {
  const _OpenIntent();
}

class _SearchScreen extends StatefulWidget {
  const _SearchScreen({
    super.key,
    required this.index,
    this.onReveal,
    this.autofocus = false,
    this.focusSignal,
  });

  final List<SearchResult> index;
  final void Function(SearchResult)? onReveal;

  /// Focus the field on first build (desktop: start typing on open).
  final bool autofocus;

  /// Fired by the host to focus the field on demand (mobile: only when the
  /// Search tab is actually opened, so the keyboard never intrudes otherwise).
  final Listenable? focusSignal;

  @override
  State<_SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<_SearchScreen> {
  final _controller = TextEditingController();
  final _scroll = ScrollController();
  final _fieldFocus = FocusNode();
  final _svc = SearchService();
  static const double _rowExtent = 62;

  /// Indexes at/above this size debounce the per-keystroke filter; smaller ones
  /// filter instantly (no perceptible lag, and no debounce delay to feel).
  static const int _kInstantFilterMax = 400;

  List<SearchResult> _results = [];
  int _highlighted = 0;
  bool _navigated = false; // guards against Enter firing open twice
  Timer? _filterDebounce;

  /// Lazily-built content index (typed + PDF text), and a flag while it builds.
  /// Only populated once the "Things" filter is turned on — it's much heavier
  /// than the name index, so it stays off the default path.
  List<ContentEntry>? _contentIndex;
  bool _contentBuilding = false;

  /// Selected type filters. The four name filters default on; "Things" (content)
  /// is deliberately OFF by default — scanning every page's text on each query
  /// is expensive, so the user opts in.
  final Set<_ResultFilter> _filters = {..._nameFilters};

  @override
  void initState() {
    super.initState();
    // Empty query → a hint, not the whole index: rendering a row per item
    // before anything is typed is wasteful and not useful.
    _results = const [];
    if (widget.autofocus) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _focusField());
    }
    widget.focusSignal?.addListener(_focusField);
  }

  void _focusField() {
    if (mounted) _fieldFocus.requestFocus();
  }

  @override
  void dispose() {
    _filterDebounce?.cancel();
    widget.focusSignal?.removeListener(_focusField);
    _fieldFocus.dispose();
    _controller.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onQueryChanged(String q) {
    _filterDebounce?.cancel();
    // Small index: filter instantly. Large index: debounce so the O(n) filter
    // doesn't run on every keystroke.
    if (widget.index.length < _kInstantFilterMax) {
      _applyFilter(q);
    } else {
      _filterDebounce =
          Timer(const Duration(milliseconds: 140), () => _applyFilter(q));
    }
  }

  /// The name-level [SearchKind] restriction from the current chip selection, or
  /// null when all four name filters are on (no restriction — the cheap
  /// default). "Things" is not a name kind and is handled separately.
  Set<SearchKind>? _selectedNameKinds() {
    final selected = [for (final f in _nameFilters) if (_filters.contains(f)) f];
    if (selected.length == _nameFilters.length) return null; // all → no restrict
    return {for (final f in selected) ..._kindsFor(f)};
  }

  void _applyFilter(String q) {
    if (!mounted) return;
    final query = q.trim();
    final nameResults = query.isEmpty
        ? const <SearchResult>[]
        : _svc.filter(widget.index, query, kinds: _selectedNameKinds());
    final wantContent =
        _filters.contains(_ResultFilter.things) && query.length >= 2;
    final contentResults = (wantContent && _contentIndex != null)
        ? _svc.filterContent(_contentIndex!, query)
        : const <SearchResult>[];
    setState(() {
      _results = [...nameResults, ...contentResults];
      _highlighted = 0;
    });
    if (_scroll.hasClients) _scroll.jumpTo(0);
    // Build the content index the first time it's actually needed, then re-run.
    if (wantContent && _contentIndex == null && !_contentBuilding) {
      _buildContentIndex();
    }
  }

  Future<void> _buildContentIndex() async {
    setState(() => _contentBuilding = true);
    final content = await _svc.buildContentIndex();
    if (!mounted) return;
    setState(() {
      _contentIndex = content;
      _contentBuilding = false;
    });
    _applyFilter(_controller.text); // fold in content results now they exist
  }

  void _toggleFilter(_ResultFilter f) {
    setState(() {
      // Never allow an empty selection — re-selecting the last one is a no-op
      // that would show nothing; instead toggling it off with others off just
      // leaves it on.
      if (_filters.contains(f)) {
        if (_filters.length > 1) _filters.remove(f);
      } else {
        _filters.add(f);
      }
    });
    _filterDebounce?.cancel();
    _applyFilter(_controller.text);
  }

  void _move(int delta) {
    if (_results.isEmpty) return;
    setState(() {
      _highlighted = (_highlighted + delta).clamp(0, _results.length - 1);
    });
    _ensureVisible();
  }

  /// Keeps the highlighted row within the viewport as it moves.
  void _ensureVisible() {
    if (!_scroll.hasClients) return;
    final top = _highlighted * _rowExtent;
    final bottom = top + _rowExtent;
    final viewTop = _scroll.offset;
    final viewBottom = viewTop + _scroll.position.viewportDimension;
    if (top < viewTop) {
      _scroll.jumpTo(top);
    } else if (bottom > viewBottom) {
      _scroll.jumpTo(bottom - _scroll.position.viewportDimension);
    }
  }

  void _openHighlighted() {
    if (_highlighted >= 0 && _highlighted < _results.length) {
      _open(_results[_highlighted]);
    }
  }

  void _open(SearchResult r) {
    if (_navigated) return;
    _navigated = true;
    // Drop the keyboard as we leave search — otherwise the field keeps focus in
    // the (kept-alive) Search tab and the keyboard re-pops when the shell is
    // revealed again (e.g. popping back from a canvas opened from a result).
    _fieldFocus.unfocus();
    final navigator = Navigator.of(context);
    // Was this search screen *pushed* as a route (desktop overlay / old mobile
    // flow) or *embedded* as a tab (mobile shell)? A pushed one can pop — and
    // MUST, or its overlay lingers on top of the revealed result (the desktop
    // bug). An embedded tab is at its navigator's root (canPop == false), so it
    // stays put and the host's onReveal switches away from the search tab.
    final wasPushed = navigator.canPop();
    if (wasPushed) navigator.pop();
    // A host reveals the result (desktop shell panes, or the mobile shell
    // switching to the Notebooks tab and driving its nested navigator).
    if (widget.onReveal != null) {
      widget.onReveal!(r);
      // Embedded tab only: reset so it's reusable next time (a pushed screen is
      // being disposed by the pop above, so leave it alone).
      if (!wasPushed && mounted) {
        setState(() {
          _navigated = false;
          _controller.clear();
          _results = const []; // back to the empty-query hint state
          _highlighted = 0;
        });
      }
      return;
    }
    // Mobile: rebuild the natural back stack from the root so Back walks up the
    // hierarchy, exactly as if the user had navigated there by hand. Each list
    // screen glows the child that leads to the target (or the target itself, for
    // a super-section), so popping back highlights the trail — desktop parity.
    navigator.popUntil((route) => route.isFirst);
    // The notebook screen glows the section it leads into, or a notebook-level
    // super-section that is itself the target.
    final notebookGlow = r.kind == SearchKind.superSection && r.section == null
        ? r.folderId
        : r.section?.id;
    navigator.push(fadeThroughRoute(
      NotebookScreen(notebook: r.notebook, glowId: notebookGlow),
    ));
    if (r.section != null) {
      // The section screen glows the canvas it opens, or a section-level
      // super-section that is itself the target.
      final sectionGlow = r.kind == SearchKind.superSection
          ? r.folderId
          : r.canvas?.id;
      navigator.push(fadeThroughRoute(
        SectionScreen(section: r.section!, glowId: sectionGlow),
      ));
    }
    if (r.canvas != null) {
      navigator.push(fadeThroughRoute(
        CanvasWorkspaceScreen(
            initialCanvas: r.canvas!, initialPageId: r.pageId),
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = Theme.of(context).extension<AppPalette>()!;
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        leadingWidth: 40,
        leading: Navigator.of(context).canPop()
            ? IconButton(
                padding: EdgeInsets.zero,
                icon: const Icon(kBackIcon),
                tooltip: 'Back',
                onPressed: () => Navigator.of(context).pop(),
              )
            : null,
        title: Shortcuts(
          shortcuts: const {
            SingleActivator(LogicalKeyboardKey.arrowDown): _NextIntent(),
            SingleActivator(LogicalKeyboardKey.arrowUp): _PrevIntent(),
            SingleActivator(LogicalKeyboardKey.enter): _OpenIntent(),
            SingleActivator(LogicalKeyboardKey.numpadEnter): _OpenIntent(),
          },
          child: Actions(
            actions: {
              _NextIntent: CallbackAction<_NextIntent>(
                onInvoke: (_) {
                  _move(1);
                  return null;
                },
              ),
              _PrevIntent: CallbackAction<_PrevIntent>(
                onInvoke: (_) {
                  _move(-1);
                  return null;
                },
              ),
              _OpenIntent: CallbackAction<_OpenIntent>(
                onInvoke: (_) {
                  _openHighlighted();
                  return null;
                },
              ),
            },
            child: TextField(
              controller: _controller,
              focusNode: _fieldFocus,
              onChanged: _onQueryChanged,
              onSubmitted: (_) {
                // Flush any pending debounced filter so Enter opens a result
                // matching what's currently typed (setState updates _results
                // synchronously before _openHighlighted reads it).
                _filterDebounce?.cancel();
                _applyFilter(_controller.text);
                _openHighlighted();
              },
              textInputAction: TextInputAction.search,
              decoration: const InputDecoration(
                hintText: 'Search notes & bookmarks',
                border: InputBorder.none,
              ),
            ),
          ),
        ),
      ),
      body: Column(
        children: [
          _buildFilterBar(palette),
          Expanded(
            child: _results.isEmpty
          ? Center(
              child: _contentBuilding
                  ? Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                        const SizedBox(height: 12),
                        Text('Indexing canvas contents…',
                            style: TextStyle(color: palette.textDim)),
                      ],
                    )
                  : Text(
                      _controller.text.trim().isEmpty
                          ? 'Search your notes & bookmarks'
                          : 'No matches for "${_controller.text}"',
                      style: TextStyle(color: palette.textDim),
                    ),
            )
          : ListView.builder(
              controller: _scroll,
              itemExtent: _rowExtent,
              itemCount: _results.length,
              itemBuilder: (context, i) {
                final r = _results[i];
                final active = i == _highlighted;
                return Material(
                  color: active ? palette.accentSoft : Colors.transparent,
                  child: ListTile(
                    dense: true,
                    leading: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 3,
                          height: 28,
                          decoration: BoxDecoration(
                            color: _railColor(r),
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Icon(_iconFor(r.kind),
                            color: palette.accent, size: 19),
                      ],
                    ),
                    title: Text(r.title,
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: Text(
                      r.path.isEmpty
                          ? _kindLabel(r.kind)
                          : '${_kindLabel(r.kind)} · ${r.path}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12, color: palette.textDim),
                    ),
                    onTap: () => _open(r),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  /// A horizontally-scrollable row of type-filter chips (Notebooks / Sections /
  /// Canvases / Bookmarks). All selected = no restriction.
  Widget _buildFilterBar(AppPalette palette) {
    return SizedBox(
      height: 48,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        children: [
          for (final f in _ResultFilter.values)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: FilterChip(
                label: Text(_filterLabel(f)),
                selected: _filters.contains(f),
                onSelected: (_) => _toggleFilter(f),
                visualDensity: VisualDensity.compact,
                showCheckmark: false,
                selectedColor: palette.accentSoft,
              ),
            ),
        ],
      ),
    );
  }

  /// The identity color of the most specific item the result points at, for
  /// the row's colored rail (matches the tree/bin rails).
  Color _railColor(SearchResult r) {
    if (r.canvas != null) {
      return AppPalette.resolveColor(r.canvas!.id, r.canvas!.color);
    }
    if (r.section != null) {
      return AppPalette.resolveColor(r.section!.id, r.section!.color);
    }
    return AppPalette.resolveColor(r.notebook.id, r.notebook.color);
  }

  IconData _iconFor(SearchKind kind) => switch (kind) {
        SearchKind.notebook => Icons.book_outlined,
        SearchKind.section => Icons.description_outlined,
        SearchKind.superSection => Icons.folder_outlined,
        SearchKind.canvas => Icons.article_outlined,
        SearchKind.bookmark => Icons.bookmark_outline,
        SearchKind.thing => Icons.text_snippet_outlined,
      };

  String _kindLabel(SearchKind kind) => switch (kind) {
        SearchKind.notebook => 'Notebook',
        SearchKind.section => 'Section',
        SearchKind.superSection => 'Super-section',
        SearchKind.canvas => 'Canvas',
        SearchKind.bookmark => 'Bookmark',
        SearchKind.thing => 'In canvas',
      };
}

/// The search screen embedded inline (e.g. as the mobile shell's Search tab)
/// rather than pushed as a route. Builds the index and rebuilds it whenever the
/// underlying data changes ([SyncService.dataVersion]) so newly-synced items
/// become searchable. [onReveal] is required — the host reveals the picked
/// result (the mobile shell switches to the Notebooks tab and drives its
/// nested navigator; a canvas opens above the shell so the bar hides).
class NoteSearchView extends StatefulWidget {
  const NoteSearchView({
    super.key,
    required this.onReveal,
    this.autofocus = false,
    this.focusSignal,
  });

  final void Function(SearchResult) onReveal;

  /// Focus the field on build (desktop opens the search pane ready to type).
  final bool autofocus;

  /// Focus the field on demand (mobile: only when the Search tab is opened).
  final Listenable? focusSignal;

  @override
  State<NoteSearchView> createState() => _NoteSearchViewState();
}

class _NoteSearchViewState extends State<NoteSearchView> {
  List<SearchResult>? _index;
  Timer? _rebuildDebounce;

  @override
  void initState() {
    super.initState();
    _rebuild(); // first index build immediately
    SyncService().dataVersion.addListener(_scheduleRebuild);
  }

  @override
  void dispose() {
    _rebuildDebounce?.cancel();
    SyncService().dataVersion.removeListener(_scheduleRebuild);
    super.dispose();
  }

  // A local add/rename/delete (and remote sync pulls) bump dataVersion so the
  // index refreshes — newly-created items become searchable without an app
  // restart. Debounced so a burst (creating several items, a flurry of pulls)
  // coalesces into one full-store reindex instead of one per change.
  void _scheduleRebuild() {
    _rebuildDebounce?.cancel();
    _rebuildDebounce = Timer(const Duration(milliseconds: 400), _rebuild);
  }

  Future<void> _rebuild() async {
    final index = await SearchService().buildIndex();
    if (mounted) setState(() => _index = index);
  }

  @override
  Widget build(BuildContext context) {
    final index = _index;
    if (index == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    // A key tied to the index length forces a fresh _SearchScreen when the data
    // set changes, without leaking stale results. Autofocus is NOT keyed to
    // build (that would grab the keyboard on every reindex); it's gated on the
    // host's focusSignal / the explicit autofocus flag instead.
    return _SearchScreen(
      key: ValueKey(index.length),
      index: index,
      onReveal: widget.onReveal,
      autofocus: widget.autofocus,
      focusSignal: widget.focusSignal,
    );
  }
}
