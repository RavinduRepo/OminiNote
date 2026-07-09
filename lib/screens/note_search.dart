import 'package:flutter/material.dart';
import '../services/search_service.dart';
import '../theme/app_theme.dart';
import 'canvas_screen.dart';
import 'notebook_screen.dart';
import 'section_screen.dart';

/// Builds the search index and opens the search UI. Call from a search icon on
/// any list screen (or a Ctrl/Cmd+K shortcut on desktop).
Future<void> openNoteSearch(BuildContext context) async {
  final index = await SearchService().buildIndex();
  if (!context.mounted) return;
  await showSearch(context: context, delegate: _NoteSearchDelegate(index));
}

/// Fuzzy search over notebook / section / super-section / canvas names and
/// bookmark labels. Selecting a result opens the target (canvases and
/// bookmarks open the canvas; bookmarks also jump to their page).
class _NoteSearchDelegate extends SearchDelegate<void> {
  _NoteSearchDelegate(this.index)
      : super(searchFieldLabel: 'Search notes & bookmarks');

  final List<SearchResult> index;

  @override
  List<Widget> buildActions(BuildContext context) => [
        if (query.isNotEmpty)
          IconButton(
            icon: const Icon(Icons.clear),
            tooltip: 'Clear',
            onPressed: () => query = '',
          ),
      ];

  @override
  Widget buildLeading(BuildContext context) => IconButton(
        icon: const Icon(Icons.arrow_back),
        onPressed: () => close(context, null),
      );

  @override
  Widget buildResults(BuildContext context) => _resultsList(context);

  @override
  Widget buildSuggestions(BuildContext context) => _resultsList(context);

  Widget _resultsList(BuildContext context) {
    final palette = Theme.of(context).extension<AppPalette>()!;
    final results = SearchService().filter(index, query);
    if (results.isEmpty) {
      return Center(
        child: Text(
          query.isEmpty ? 'No notes yet' : 'No matches for "$query"',
          style: TextStyle(color: palette.textDim),
        ),
      );
    }
    return ListView.builder(
      itemCount: results.length,
      itemBuilder: (context, i) {
        final r = results[i];
        return ListTile(
          leading: Icon(_iconFor(r.kind), color: palette.accent, size: 20),
          title: Text(r.title, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: r.path.isEmpty
              ? Text(_kindLabel(r.kind),
                  style: TextStyle(fontSize: 12, color: palette.textDim))
              : Text('${_kindLabel(r.kind)} · ${r.path}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, color: palette.textDim)),
          onTap: () => _open(context, r),
        );
      },
    );
  }

  void _open(BuildContext context, SearchResult r) {
    // Close the search UI, then push the target over the current screen. Works
    // in both the mobile push-nav flow and the desktop shell.
    final navigator = Navigator.of(context);
    close(context, null);
    switch (r.kind) {
      case SearchKind.notebook:
        navigator.push(fadeThroughRoute(NotebookScreen(notebook: r.notebook)));
      case SearchKind.superSection:
        // Folders have no screen; open their container (section, else notebook).
        if (r.section != null) {
          navigator.push(fadeThroughRoute(SectionScreen(section: r.section!)));
        } else {
          navigator
              .push(fadeThroughRoute(NotebookScreen(notebook: r.notebook)));
        }
      case SearchKind.section:
        navigator.push(fadeThroughRoute(SectionScreen(section: r.section!)));
      case SearchKind.canvas:
        navigator.push(fadeThroughRoute(CanvasScreen(canvas: r.canvas!)));
      case SearchKind.bookmark:
        navigator.push(fadeThroughRoute(
          CanvasScreen(canvas: r.canvas!, initialPageId: r.pageId),
        ));
    }
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
