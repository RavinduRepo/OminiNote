import '../models/notebook.dart';
import '../models/section.dart';
import '../models/canvas.dart';
import '../models/canvas_page.dart';
import '../models/element.dart';
import '../models/tree.dart';
import 'notebook_service.dart';
import 'pdf_text_extractor.dart';

/// What a [SearchResult] points at. [thing] = content *inside* a canvas (typed
/// text or extracted PDF text) — the opt-in "Things" search.
enum SearchKind { notebook, section, superSection, canvas, bookmark, thing }

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

  /// Precomputed lowercased match keys (built once at index time so the
  /// per-keystroke filter never re-lowercases). [pathKeyLower] is the full
  /// breadcrumb + title concatenated, so a query typed as a run-together path
  /// ("noteseccanv") fuzzily matches Notebook › Section › Canvas.
  final String titleLower;
  final String pathKeyLower;

  SearchResult({
    required this.kind,
    required this.title,
    required this.path,
    required this.notebook,
    this.section,
    this.canvas,
    this.pageId,
    this.folderId,
  })  : titleLower = title.toLowerCase(),
        pathKeyLower =
            (path.isEmpty ? title : '$path $title').toLowerCase();
}

/// One page's searchable text (typed text + extracted PDF text), plus the
/// context needed to open it. Built by [SearchService.buildContentIndex] only
/// when the user opts into "Things" search — reading page files + extracting
/// PDF text is far heavier than the name index, so it's never on the hot path.
class ContentEntry {
  final Notebook notebook;
  final Section section;
  final Canvas canvas;
  final String pageId;

  /// The page's text (kept for snippet display) and a lowercased copy for
  /// substring matching.
  final String text;
  final String textLower;

  ContentEntry({
    required this.notebook,
    required this.section,
    required this.canvas,
    required this.pageId,
    required this.text,
  }) : textLower = text.toLowerCase();
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
  ///
  /// The section and canvas reads are the dominant cost (sequential disk I/O on
  /// a large store), so they run **bounded-concurrently** ([_kReadConcurrency]
  /// at a time) instead of one-after-another — the index builds far faster
  /// without flooding the OS with file handles. Result *order* is preserved
  /// (tree order), and per-item semantics are unchanged (`getSection`/
  /// `getCanvas` still filter tombstoned items). The tiny structure-only decode
  /// stays on the main isolate — offloading it wouldn't pay (the models must be
  /// built here anyway to navigate to results).
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
      final sectionIds = nb.allSectionIds.toList();
      final sections = await _mapBounded(
          sectionIds, (id) => _service.getSection(nb.id, id));
      for (final section in sections) {
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
        final canvasIds = section.allCanvasIds.toList();
        final canvases = await _mapBounded(
            canvasIds, (id) => _service.getCanvas(nb.id, section.id, id));
        final path = '${nb.name} › ${section.name}';
        for (final canvas in canvases) {
          if (canvas == null) continue;
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

  /// Builds the **content** index: one [ContentEntry] per page that has any
  /// typed text or extracted PDF text. This is O(all pages) file reads plus PDF
  /// text extraction, so it's built lazily — only when the user turns on the
  /// "Things" filter — and cached by the caller. Sections/canvases read
  /// bounded-concurrently; per-canvas PDF text is cached then dropped so peak
  /// memory doesn't hold every PDF at once.
  Future<List<ContentEntry>> buildContentIndex() async {
    final out = <ContentEntry>[];
    final notebooks = await _service.getNotebooks();
    for (final nb in notebooks) {
      final sectionIds = nb.allSectionIds.toList();
      final sections = await _mapBounded(
          sectionIds, (id) => _service.getSection(nb.id, id));
      for (final section in sections) {
        if (section == null) continue;
        final canvasIds = section.allCanvasIds.toList();
        final canvases = await _mapBounded(
            canvasIds, (id) => _service.getCanvas(nb.id, section.id, id));
        for (final canvas in canvases) {
          if (canvas == null) continue;
          final pages = await _service.loadPages(canvas);
          final pdfCache =
              PdfTextCache((assetId) => _service.assetFile(canvas, assetId));
          for (final page in pages.values) {
            final text = await _pageText(page, pdfCache);
            if (text.trim().isEmpty) continue;
            out.add(ContentEntry(
              notebook: nb,
              section: section,
              canvas: canvas,
              pageId: page.id,
              text: text,
            ));
          }
          pdfCache.clear();
        }
      }
    }
    return out;
  }

  /// A page's combined searchable text: every typed [TextElement] plus the
  /// extracted text of an imported-PDF background, if any.
  Future<String> _pageText(CanvasPage page, PdfTextCache pdfCache) async {
    final buf = StringBuffer();
    for (final el in page.objects) {
      if (el is TextElement) {
        final t = el.text.trim();
        if (t.isNotEmpty) buf.writeln(t);
      }
    }
    final src = page.source;
    if (src != null) {
      final pt = await pdfCache.page(src.assetId, src.pageIndex);
      if (pt != null) {
        for (final line in pt.lines) {
          final t = line.text.trim();
          if (t.isNotEmpty) buf.writeln(t);
        }
      }
    }
    return buf.toString();
  }

  /// Substring-matches [content] against [query], returning up to [limit]
  /// [SearchResult]s of kind [SearchKind.thing] with a snippet around each hit.
  /// Requires 2+ chars (a 1-char content match would hit almost everything).
  List<SearchResult> filterContent(
    List<ContentEntry> content,
    String query, {
    int limit = 80,
  }) {
    final q = query.trim().toLowerCase();
    if (q.length < 2) return const [];
    final out = <SearchResult>[];
    for (final e in content) {
      final idx = e.textLower.indexOf(q);
      if (idx < 0) continue;
      out.add(SearchResult(
        kind: SearchKind.thing,
        title: _contentSnippet(e.text, idx, q.length),
        path: '${e.notebook.name} › ${e.section.name} › ${e.canvas.name}',
        notebook: e.notebook,
        section: e.section,
        canvas: e.canvas,
        pageId: e.pageId,
      ));
      if (out.length >= limit) break;
    }
    return out;
  }

  /// A one-line preview of [text] around a match, with ellipses where trimmed.
  String _contentSnippet(String text, int matchIndex, int matchLen) {
    const pad = 32;
    var start = matchIndex - pad;
    var end = matchIndex + matchLen + pad;
    if (start < 0) start = 0;
    if (end > text.length) end = text.length;
    var s = text.substring(start, end).replaceAll(RegExp(r'\s+'), ' ').trim();
    if (start > 0) s = '…$s';
    if (end < text.length) s = '$s…';
    return s;
  }

  /// Max concurrent section/canvas file reads while building the index.
  static const int _kReadConcurrency = 8;

  /// Runs [task] over [items] with at most [_kReadConcurrency] in flight,
  /// returning results in input order. `i = next++` is safe: the isolate is
  /// single-threaded, so workers only interleave at `await` points.
  Future<List<R>> _mapBounded<T, R>(
      List<T> items, Future<R> Function(T) task) async {
    final results = List<R?>.filled(items.length, null);
    var next = 0;
    Future<void> worker() async {
      while (true) {
        final i = next++;
        if (i >= items.length) break;
        results[i] = await task(items[i]);
      }
    }

    final n = items.length < _kReadConcurrency ? items.length : _kReadConcurrency;
    await Future.wait([for (var k = 0; k < n; k++) worker()]);
    return results.cast<R>();
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

  /// How much worse a path-only match ranks than any title match — large
  /// enough that every title hit sorts above every path-only hit.
  static const int _kPathMatchPenalty = 1000;

  /// Fuzzy-filters [index] by [query], best matches first. Optionally restricts
  /// to a set of [kinds] (the search screen's type filters). An empty query
  /// returns everything of the allowed kinds (so a host can show the whole tree
  /// to browse).
  ///
  /// Matching is against the item's title first; for queries of 3+ chars it
  /// *also* tries the full breadcrumb path ([SearchResult.pathKeyLower]), so
  /// typing a run-together path like "noteseccanv" surfaces the canvas — but
  /// those path-only hits always rank below real title hits.
  List<SearchResult> filter(
    List<SearchResult> index,
    String query, {
    Set<SearchKind>? kinds,
  }) {
    final q = query.trim().toLowerCase();
    bool allowed(SearchResult r) => kinds == null || kinds.contains(r.kind);
    if (q.isEmpty) {
      return kinds == null ? index : [for (final r in index) if (allowed(r)) r];
    }
    final matchPath = q.length >= 3;
    final scored = <(int, SearchResult)>[];
    for (final r in index) {
      if (!allowed(r)) continue;
      var score = _score(r.titleLower, q);
      if (score == null && matchPath) {
        final ps = _score(r.pathKeyLower, q);
        if (ps != null) score = ps + _kPathMatchPenalty;
      }
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
