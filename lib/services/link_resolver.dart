import '../models/canvas.dart';
import '../models/link.dart';
import '../models/tree.dart';
import 'notebook_service.dart';
import 'search_service.dart';

/// A [LinkEndpoint] resolved against the local store: whether the target is
/// currently reachable ([alive] — soft-deleted/purged/absent all count as
/// dead), its live [title] + breadcrumb [path], and — when alive — a
/// [SearchResult] the shells' existing reveal machinery can navigate to.
///
/// Resolution is on-demand (a Connections sheet opening, a link tap) and reads
/// only the target's structural files — it never scans the store.
class ResolvedLink {
  final bool alive;
  final String title;
  final String path;
  final LinkTargetKind kind;
  final SearchResult? reveal;

  const ResolvedLink({
    required this.alive,
    required this.title,
    this.path = '',
    required this.kind,
    this.reveal,
  });
}

/// Resolves [e] against the local store. [fallbackName] (the record's name
/// snapshot) becomes the title when the target is dead.
Future<ResolvedLink> resolveEndpoint(
  LinkEndpoint e, {
  String fallbackName = '',
}) async {
  final kind = e.kind;
  ResolvedLink dead() => ResolvedLink(
        alive: false,
        title: fallbackName.isEmpty ? 'Deleted item' : fallbackName,
        kind: kind,
      );

  final service = NotebookService();
  final nb = await service.getNotebook(e.notebookId);
  if (nb == null) return dead();

  if (kind == LinkTargetKind.notebook) {
    return ResolvedLink(
      alive: true,
      title: nb.name,
      kind: kind,
      reveal: SearchResult(
        kind: SearchKind.notebook,
        title: nb.name,
        path: '',
        notebook: nb,
      ),
    );
  }

  // Notebook-level folder (super-section grouping sections).
  if (kind == LinkTargetKind.folder && e.sectionId == null) {
    final folder = _findFolder(nb.nodes, e.folderId!);
    if (folder == null) return dead();
    return ResolvedLink(
      alive: true,
      title: folder.name,
      path: nb.name,
      kind: kind,
      reveal: SearchResult(
        kind: SearchKind.superSection,
        title: folder.name,
        path: nb.name,
        notebook: nb,
        folderId: folder.id,
      ),
    );
  }

  if (e.sectionId == null) return dead(); // malformed URI guard
  final sec = await service.getSection(e.notebookId, e.sectionId!);
  if (sec == null) return dead();

  if (kind == LinkTargetKind.section) {
    return ResolvedLink(
      alive: true,
      title: sec.name,
      path: nb.name,
      kind: kind,
      reveal: SearchResult(
        kind: SearchKind.section,
        title: sec.name,
        path: nb.name,
        notebook: nb,
        section: sec,
      ),
    );
  }

  // Section-level folder (grouping canvases).
  if (kind == LinkTargetKind.folder) {
    final folder = _findFolder(sec.nodes, e.folderId!);
    if (folder == null) return dead();
    return ResolvedLink(
      alive: true,
      title: folder.name,
      path: '${nb.name} › ${sec.name}',
      kind: kind,
      reveal: SearchResult(
        kind: SearchKind.superSection,
        title: folder.name,
        path: '${nb.name} › ${sec.name}',
        notebook: nb,
        section: sec,
        folderId: folder.id,
      ),
    );
  }

  if (e.canvasId == null) return dead(); // malformed URI guard
  final canvas =
      await service.getCanvas(e.notebookId, e.sectionId!, e.canvasId!);
  if (canvas == null) return dead();
  final canvasPath = '${nb.name} › ${sec.name}';

  SearchResult revealCanvas({SearchKind k = SearchKind.canvas, String? pageId,
      String? title}) {
    return SearchResult(
      kind: k,
      title: title ?? canvas.name,
      path: canvasPath,
      notebook: nb,
      section: sec,
      canvas: canvas,
      pageId: pageId,
    );
  }

  switch (kind) {
    case LinkTargetKind.canvas:
      return ResolvedLink(
        alive: true,
        title: canvas.name,
        path: canvasPath,
        kind: kind,
        reveal: revealCanvas(),
      );
    case LinkTargetKind.bookmark:
      Bookmark? bm;
      for (final b in canvas.bookmarks) {
        if (b.id == e.bookmarkId) {
          bm = b;
          break;
        }
      }
      if (bm == null) return dead();
      return ResolvedLink(
        alive: true,
        title: bm.name,
        path: '$canvasPath › ${canvas.name}',
        kind: kind,
        reveal: revealCanvas(
            k: SearchKind.bookmark, pageId: bm.pageId, title: bm.name),
      );
    case LinkTargetKind.page:
    case LinkTargetKind.element:
      // Row membership is the aliveness proxy: a deleted page's row entry is
      // removed by deletePage, and loadPages prunes stale rows — no page-file
      // read needed here. Element endpoints resolve to their page (finer
      // aliveness would need the page JSON; the landing view shows the truth).
      if (e.pageId == null) return dead(); // malformed URI guard
      final n = _pageNumber(canvas, e.pageId!);
      if (n == null) return dead();
      final title = 'Page $n';
      return ResolvedLink(
        alive: true,
        title: kind == LinkTargetKind.element
            ? (fallbackName.isEmpty ? '$title selection' : fallbackName)
            : title,
        path: '$canvasPath › ${canvas.name}',
        kind: kind,
        reveal: revealCanvas(pageId: e.pageId, title: title),
      );
    case LinkTargetKind.notebook:
    case LinkTargetKind.folder:
    case LinkTargetKind.section:
      return dead(); // unreachable — handled above
  }
}

/// The [LinkEndpoint] a picked search result addresses, or null for results
/// that can't be linked (malformed entries). Bookmarks map to their page
/// (SearchResult carries the page, not the bookmark id) — navigation lands
/// on the same spot either way.
LinkEndpoint? endpointOfSearchResult(SearchResult r) {
  switch (r.kind) {
    case SearchKind.notebook:
      return LinkEndpoint(notebookId: r.notebook.id);
    case SearchKind.superSection:
      if (r.folderId == null) return null;
      return LinkEndpoint(
        notebookId: r.notebook.id,
        sectionId: r.section?.id,
        folderId: r.folderId,
      );
    case SearchKind.section:
      if (r.section == null) return null;
      return LinkEndpoint(notebookId: r.notebook.id, sectionId: r.section!.id);
    case SearchKind.canvas:
      if (r.section == null || r.canvas == null) return null;
      return LinkEndpoint(
        notebookId: r.notebook.id,
        sectionId: r.section!.id,
        canvasId: r.canvas!.id,
      );
    case SearchKind.bookmark:
      if (r.section == null || r.canvas == null) return null;
      return LinkEndpoint(
        notebookId: r.notebook.id,
        sectionId: r.section!.id,
        canvasId: r.canvas!.id,
        pageId: r.pageId,
      );
  }
}

FolderNode? _findFolder(List<TreeNode> nodes, String id) {
  for (final n in nodes) {
    if (n is FolderNode) {
      if (n.id == id) return n;
      final inner = _findFolder(n.children, id);
      if (inner != null) return inner;
    }
  }
  return null;
}

/// 1-based reading-order number of [pageId] in [canvas]'s rows, or null when
/// no row references it (deleted).
int? _pageNumber(Canvas canvas, String pageId) {
  var n = 0;
  for (final row in canvas.rows) {
    for (final id in row.pageIds) {
      n++;
      if (id == pageId) return n;
    }
  }
  return null;
}
