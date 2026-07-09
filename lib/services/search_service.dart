import '../models/notebook.dart';
import '../models/section.dart';
import '../models/canvas.dart';
import '../models/tree.dart';
import 'notebook_service.dart';

/// What a [SearchResult] points at.
enum SearchKind { notebook, section, superSection, canvas, bookmark }

/// One entry in the search index: a named thing (notebook / section /
/// super-section / canvas / bookmark) plus enough context to open it.
class SearchResult {
  final SearchKind kind;

  /// The matched name (notebook/section/canvas/bookmark label).
  final String title;

  /// Breadcrumb of the containing items, e.g. "My Notebook › Physics".
  final String path;

  final Notebook notebook;
  final Section? section;
  final Canvas? canvas;

  /// The bookmarked page to jump to (bookmarks only).
  final String? pageId;

  /// The super-section (folder) id (super-section results only), so the host
  /// can expand + glow the exact folder.
  final String? folderId;

  SearchResult({
    required this.kind,
    required this.title,
    required this.path,
    required this.notebook,
    this.section,
    this.canvas,
    this.pageId,
    this.folderId,
  });
}

/// Builds a flat, in-memory index of every notebook/section/canvas name plus
/// bookmark labels, and fuzzy-filters it. Content (ink/text inside pages) is
/// intentionally not indexed — names + bookmarks are enough to be useful and
/// keep the build cheap.
class SearchService {
  static final SearchService _instance = SearchService._();
  factory SearchService() => _instance;
  SearchService._();

  final _service = NotebookService();

  /// Walks the whole tree (notebooks → sections → canvases → bookmarks) and
  /// returns a flat index. Reads section.json / canvas.json per item, so this
  /// is O(sections + canvases) file reads — build it when search opens.
  Future<List<SearchResult>> buildIndex() async {
    final out = <SearchResult>[];
    final notebooks = await _service.getNotebooks();
    for (final nb in notebooks) {
      out.add(SearchResult(
        kind: SearchKind.notebook,
        title: nb.name,
        path: '',
        notebook: nb,
      ));
      // Super-sections that group sections inside this notebook. They have no
      // screen of their own, so a hit opens the containing notebook.
      _collectFolders(nb.nodes, (id, name) {
        out.add(SearchResult(
          kind: SearchKind.superSection,
          title: name,
          path: nb.name,
          notebook: nb,
          folderId: id,
        ));
      });
      for (final sectionId in nb.allSectionIds) {
        final section = await _service.getSection(nb.id, sectionId);
        if (section == null) continue;
        out.add(SearchResult(
          kind: SearchKind.section,
          title: section.name,
          path: nb.name,
          notebook: nb,
          section: section,
        ));
        // Super-sections that group canvases inside this section — a hit opens
        // the containing section.
        _collectFolders(section.nodes, (id, name) {
          out.add(SearchResult(
            kind: SearchKind.superSection,
            title: name,
            path: '${nb.name} › ${section.name}',
            notebook: nb,
            section: section,
            folderId: id,
          ));
        });
        for (final canvasId in section.allCanvasIds) {
          final canvas = await _service.getCanvas(nb.id, section.id, canvasId);
          if (canvas == null) continue;
          final path = '${nb.name} › ${section.name}';
          out.add(SearchResult(
            kind: SearchKind.canvas,
            title: canvas.name,
            path: path,
            notebook: nb,
            section: section,
            canvas: canvas,
          ));
          for (final bm in canvas.bookmarks) {
            out.add(SearchResult(
              kind: SearchKind.bookmark,
              title: bm.name,
              path: '$path › ${canvas.name}',
              notebook: nb,
              section: section,
              canvas: canvas,
              pageId: bm.pageId,
            ));
          }
        }
      }
    }
    return out;
  }

  /// Depth-first walk collecting every super-section (folder) id + name.
  void _collectFolders(
    List<TreeNode> nodes,
    void Function(String id, String name) add,
  ) {
    for (final n in nodes) {
      if (n is FolderNode) {
        add(n.id, n.name);
        _collectFolders(n.children, add);
      }
    }
  }

  /// Fuzzy-filters [index] by [query], best matches first. An empty query
  /// returns everything (so the search page can show the whole tree to browse).
  List<SearchResult> filter(List<SearchResult> index, String query) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return index;
    final scored = <(int, SearchResult)>[];
    for (final r in index) {
      final score = _score(r.title.toLowerCase(), q);
      if (score != null) scored.add((score, r));
    }
    scored.sort((a, b) => a.$1.compareTo(b.$1));
    return [for (final s in scored) s.$2];
  }

  /// Subsequence fuzzy match. Returns a cost (lower = better) or null if [q]
  /// isn't a subsequence of [text]. Rewards contiguous runs and an early first
  /// match, so "phy" ranks "Physics" above "Photography".
  int? _score(String text, String q) {
    if (q.isEmpty) return 0;
    // Exact / prefix / contains shortcuts rank highest.
    if (text == q) return -1000;
    final idx = text.indexOf(q);
    if (idx == 0) return -500 + text.length;
    if (idx > 0) return -200 + idx + text.length;

    var ti = 0, qi = 0, cost = 0, gap = 0;
    var lastMatch = -1;
    while (ti < text.length && qi < q.length) {
      if (text[ti] == q[qi]) {
        if (lastMatch >= 0) gap = ti - lastMatch - 1;
        cost += gap; // penalize gaps between matched chars
        lastMatch = ti;
        qi++;
      }
      ti++;
    }
    if (qi < q.length) return null; // not a subsequence
    return cost + lastMatch; // later last match = slightly worse
  }
}
