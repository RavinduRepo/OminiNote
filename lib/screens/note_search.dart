import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/search_service.dart';
import '../theme/app_theme.dart';
import 'canvas_screen.dart';
import 'notebook_screen.dart';
import 'section_screen.dart';

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
    builder: (_) => _SearchScreen(index: index, onReveal: onReveal),
  ));
}

// Intents for keyboard navigation of the results list while the search field
// keeps focus. Mapped in a Shortcuts wrapper around the field, so they win over
// the text field's default arrow/enter behaviour (nearest Shortcuts wins).
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
  const _SearchScreen({required this.index, this.onReveal});

  final List<SearchResult> index;
  final void Function(SearchResult)? onReveal;

  @override
  State<_SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<_SearchScreen> {
  final _controller = TextEditingController();
  final _scroll = ScrollController();
  final _svc = SearchService();
  static const double _rowExtent = 62;

  List<SearchResult> _results = [];
  int _highlighted = 0;
  bool _navigated = false; // guards against Enter firing open twice

  @override
  void initState() {
    super.initState();
    _results = _svc.filter(widget.index, '');
  }

  @override
  void dispose() {
    _controller.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onQueryChanged(String q) {
    setState(() {
      _results = _svc.filter(widget.index, q);
      _highlighted = 0;
    });
    if (_scroll.hasClients) _scroll.jumpTo(0);
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
    final navigator = Navigator.of(context);
    navigator.pop(); // close the search screen
    // Desktop: let the shell reveal + select the result in its panes.
    if (widget.onReveal != null) {
      widget.onReveal!(r);
      return;
    }
    // Mobile: rebuild the natural back stack from the root so Back walks up the
    // hierarchy, exactly as if the user had navigated there by hand.
    navigator.popUntil((route) => route.isFirst);
    navigator.push(fadeThroughRoute(NotebookScreen(notebook: r.notebook)));
    if (r.section != null) {
      navigator.push(fadeThroughRoute(SectionScreen(section: r.section!)));
    }
    if (r.canvas != null) {
      navigator.push(fadeThroughRoute(
        CanvasScreen(canvas: r.canvas!, initialPageId: r.pageId),
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = Theme.of(context).extension<AppPalette>()!;
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
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
              autofocus: true,
              onChanged: _onQueryChanged,
              onSubmitted: (_) => _openHighlighted(),
              textInputAction: TextInputAction.search,
              decoration: const InputDecoration(
                hintText: 'Search notes & bookmarks',
                border: InputBorder.none,
              ),
            ),
          ),
        ),
      ),
      body: _results.isEmpty
          ? Center(
              child: Text(
                _controller.text.isEmpty
                    ? 'No notes yet'
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
                    leading: Icon(_iconFor(r.kind),
                        color: palette.accent, size: 20),
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
    );
  }

  IconData _iconFor(SearchKind kind) => switch (kind) {
        SearchKind.notebook => Icons.book_outlined,
        SearchKind.section => Icons.description_outlined,
        SearchKind.superSection => Icons.folder_outlined,
        SearchKind.canvas => Icons.article_outlined,
        SearchKind.bookmark => Icons.bookmark_outline,
      };

  String _kindLabel(SearchKind kind) => switch (kind) {
        SearchKind.notebook => 'Notebook',
        SearchKind.section => 'Section',
        SearchKind.superSection => 'Super-section',
        SearchKind.canvas => 'Canvas',
        SearchKind.bookmark => 'Bookmark',
      };
}
