import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/link.dart';
import '../utils/url_text.dart';
import '../services/link_navigator.dart';
import '../services/link_resolver.dart';
import '../services/link_service.dart';
import '../theme/app_theme.dart';
import 'action_sheet.dart';
import 'edit_link_sheet.dart';
import 'link_target_picker.dart';

/// Copies [endpoint]'s `omninote://link/...` URI to the OS clipboard — the
/// "Copy link" action every linkable item's menu offers.
Future<void> copyLinkToClipboard(
  BuildContext context,
  LinkEndpoint endpoint,
) async {
  await Clipboard.setData(ClipboardData(text: endpoint.toUri()));
  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Link copied — paste it in any Connections list')),
    );
  }
}

/// Shows the Connections list for one item ([endpoint] mode: its two-way
/// links, with paste-to-add), or — when [aggregateCanvasId] is set instead —
/// the read-mostly aggregate of every connection touching anything inside
/// that canvas (the canvas ⋯ menu's "All connections").
/// [insideCanvasId] + [onJumpInSameCanvas]: hosts that open this sheet from
/// *inside* an open canvas pass its id and an in-place jump — a tapped row
/// targeting that very canvas must never route through the shell reveal,
/// which would open a second CanvasScreen (two controllers on one canvas id
/// fight over the autosave — the split-view rule).
Future<void> showConnectionsSheet(
  BuildContext context, {
  required String title,
  LinkEndpoint? endpoint,
  String endpointName = '',
  String? aggregateCanvasId,
  String? insideCanvasId,
  void Function(String? pageId)? onJumpInSameCanvas,
  Future<void> Function(LinkEndpoint target, ResolvedLink resolved)?
      onAddTarget,
}) {
  assert((endpoint == null) != (aggregateCanvasId == null),
      'pass exactly one of endpoint / aggregateCanvasId');
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (sheetContext) => cappedSheetBody(
      sheetContext,
      child: _ConnectionsList(
        title: title,
        endpoint: endpoint,
        endpointName: endpointName,
        aggregateCanvasId: aggregateCanvasId,
        insideCanvasId: insideCanvasId,
        onJumpInSameCanvas: onJumpInSameCanvas,
        onAddTarget: onAddTarget,
        // Navigation must outlive the sheet; snackbars anchor to the host.
        hostContext: context,
      ),
    ),
  );
}

class _ConnectionsList extends StatefulWidget {
  final String title;
  final LinkEndpoint? endpoint;
  final String endpointName;
  final String? aggregateCanvasId;
  final String? insideCanvasId;
  final void Function(String? pageId)? onJumpInSameCanvas;

  /// When set (the lasso-selection host), adding a target routes here instead
  /// of the default [LinkService.addLink] — the host drops a visible link
  /// marker next to the selection and registers the record itself.
  final Future<void> Function(LinkEndpoint target, ResolvedLink resolved)?
      onAddTarget;

  final BuildContext hostContext;

  const _ConnectionsList({
    required this.title,
    required this.endpoint,
    required this.endpointName,
    required this.aggregateCanvasId,
    this.insideCanvasId,
    this.onJumpInSameCanvas,
    this.onAddTarget,
    required this.hostContext,
  });

  @override
  State<_ConnectionsList> createState() => _ConnectionsListState();
}

class _Row {
  final LinkRecord record;
  final ResolvedLink resolved;
  _Row(this.record, this.resolved);
}

class _ConnectionsListState extends State<_ConnectionsList> {
  List<_Row>? _rows;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final ep = widget.endpoint;
    final records = ep == null
        ? await LinkService().linksTouchingCanvas(widget.aggregateCanvasId!)
        : ep.kind == LinkTargetKind.element
            // Element endpoints match by id overlap, not leaf equality — a
            // re-lassoed subset/superset of a linked selection still finds it.
            ? await LinkService().linksOfElements(ep.elementIds)
            : await LinkService().linksOf(ep.leafId);
    final rows = <_Row>[];
    for (final r in records) {
      final other = _otherEndOf(r);
      final resolved = await resolveEndpoint(
        other,
        fallbackName: _otherNameOf(r, other),
      );
      rows.add(_Row(r, resolved));
    }
    if (mounted) setState(() => _rows = rows);
  }

  /// The end to display: opposite this sheet's item, or — in the canvas
  /// aggregate, where a record may touch the canvas on either (or both)
  /// sides — the side leading *away* from the canvas, falling back to `b`.
  LinkEndpoint _otherEndOf(LinkRecord r) {
    final ep = widget.endpoint;
    if (ep != null) {
      if (ep.kind == LinkTargetKind.element) {
        final set = ep.elementIds.toSet();
        return r.a.elementIds.any(set.contains) ? r.b : r.a;
      }
      return r.otherEndOf(ep.leafId) ?? r.b;
    }
    final cid = widget.aggregateCanvasId!;
    if (r.a.canvasId == cid && r.b.canvasId != cid) return r.b;
    if (r.b.canvasId == cid && r.a.canvasId != cid) return r.a;
    return r.b;
  }

  String _otherNameOf(LinkRecord r, LinkEndpoint other) =>
      identical(other, r.a) ? r.aName : r.bName;

  Future<void> _pasteLink() async {
    final data = await Clipboard.getData('text/plain');
    final text = data?.text?.trim() ?? '';
    // Type is auto-detected: an internal item link, else any URL (external
    // links live in the same list, shown distinctly).
    var target = LinkEndpoint.tryParse(text);
    if (target == null) {
      final url = firstUrlIn(text);
      if (url != null) target = LinkEndpoint.external(url);
    }
    if (target == null) {
      _toast('The clipboard doesn\'t contain an Omininote link or a URL — '
          'use "Copy link" on any item, or copy a web address.');
      return;
    }
    await _addTarget(target);
  }

  Future<void> _chooseTarget() async {
    final r = await showLinkTargetPicker(context);
    if (r == null || !mounted) return;
    final target = endpointOfSearchResult(r);
    if (target == null) return;
    await _addTarget(target);
  }

  Future<void> _addTarget(LinkEndpoint target) async {
    final ep = widget.endpoint!;
    if (target.sameAs(ep)) {
      _toast('That link points at this very item.');
      return;
    }
    final resolved = await resolveEndpoint(target);
    if (widget.onAddTarget != null) {
      await widget.onAddTarget!(target, resolved);
    } else {
      await LinkService().addLink(
        from: ep,
        to: target,
        fromName: widget.endpointName,
        toName: resolved.title,
      );
    }
    await _load();
  }

  /// The ✎ on a row: rename (label) and/or retarget — internal item link or
  /// external URL, freely swapped; an emptied destination removes the record.
  Future<void> _editRow(_Row row) async {
    final other = _otherEndOf(row.record);
    final result = await showEditLinkSheet(
      context,
      text: row.record.label ?? row.resolved.title,
      link: other.toUri(),
    );
    if (result == null || !mounted) return;
    if (result.link == null) {
      await _remove(row.record);
      return;
    }
    final newOther = LinkEndpoint.sideFrom(result.link!);
    if (newOther == null) {
      _toast('Not a valid destination — paste a copied item link or a URL.');
      return;
    }
    final defaultTitle = row.resolved.title;
    await LinkService().updateLink(
      row.record.id,
      otherIsA: identical(other, row.record.a),
      newOther: newOther.sameAs(other) ? null : newOther,
      label: result.text == defaultTitle ? null : result.text,
      clearLabel: result.text == defaultTitle,
    );
    await _load();
  }

  Future<void> _remove(LinkRecord r) async {
    await LinkService().removeLink(r.id);
    await _load();
    _toast('Connection removed from both items.');
  }

  void _openRow(_Row row) {
    final other = _otherEndOf(row.record);
    // External link: straight to the browser (the sheet stays open).
    if (other.kind == LinkTargetKind.external) {
      launchUrl(Uri.parse(other.externalUrl!),
          mode: LaunchMode.externalApplication);
      return;
    }
    final reveal = row.resolved.reveal;
    if (reveal == null) return;
    Navigator.of(context).pop();
    // Element targets hand their ids to the destination canvas (scroll-to +
    // landing flash) via the one-shot pending-focus channel — consumed by the
    // same-canvas jump below or by the CanvasScreen the reveal opens.
    if (other.elementIds.isNotEmpty &&
        other.canvasId != null &&
        other.pageId != null) {
      LinkNavigator().pendingElementFocus = (
        canvasId: other.canvasId!,
        pageId: other.pageId!,
        elementIds: other.elementIds,
      );
    }
    // Target inside the canvas we were opened from: jump in place — a shell
    // reveal would open a SECOND CanvasScreen on the same canvas id (two
    // controllers, one autosave — forbidden, same rule as split view).
    if (widget.insideCanvasId != null &&
        reveal.canvas?.id == widget.insideCanvasId) {
      widget.onJumpInSameCanvas?.call(reveal.pageId);
      return;
    }
    if (!LinkNavigator().reveal(reveal)) {
      LinkNavigator().pendingElementFocus = null; // don't fire much later
      ScaffoldMessenger.of(widget.hostContext).showSnackBar(
        const SnackBar(content: Text('Couldn\'t navigate to the target.')),
      );
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg)));
  }

  static IconData _kindIcon(LinkTargetKind k) => switch (k) {
        LinkTargetKind.notebook => Icons.menu_book_outlined,
        LinkTargetKind.folder => Icons.folder_outlined,
        LinkTargetKind.section => Icons.topic_outlined,
        LinkTargetKind.canvas => Icons.description_outlined,
        LinkTargetKind.page => Icons.article_outlined,
        LinkTargetKind.element => Icons.gesture,
        LinkTargetKind.bookmark => Icons.bookmark_outline,
        LinkTargetKind.external => Icons.public,
      };

  @override
  Widget build(BuildContext context) {
    final palette = Theme.of(context).extension<AppPalette>()!;
    final rows = _rows;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 10),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: Container(
              width: 36,
              height: 4,
              margin: const EdgeInsets.only(top: 2, bottom: 8),
              decoration: BoxDecoration(
                color: palette.border,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 2, 4, 4),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Connections — ${widget.title}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: palette.textDim,
                    ),
                  ),
                ),
                if (widget.endpoint != null) ...[
                  IconButton(
                    tooltip: 'Copy link to this item',
                    icon: const Icon(Icons.link, size: 20),
                    onPressed: () =>
                        copyLinkToClipboard(context, widget.endpoint!),
                  ),
                  PopupMenuButton<String>(
                    tooltip: 'Add a connection',
                    icon: const Icon(Icons.add, size: 22),
                    onSelected: (a) => a == 'paste' ? _pasteLink() : _chooseTarget(),
                    itemBuilder: (context) => [
                      iconMenuItem(
                          'paste', Icons.content_paste, 'Paste copied link'),
                      iconMenuItem('choose', Icons.search, 'Choose target…'),
                    ],
                  ),
                ],
              ],
            ),
          ),
          if (rows == null)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
            )
          else if (rows.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 20),
              child: Text(
                widget.endpoint != null
                    ? 'No connections yet. Use "Copy link" on any item, then '
                        'the + above to connect it here — the link works from '
                        'both sides.'
                    : 'Nothing inside this canvas is connected yet.',
                style: TextStyle(fontSize: 13.5, color: palette.textDim),
              ),
            )
          else
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: rows.length,
                itemBuilder: (_, i) => _buildRow(palette, rows[i]),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildRow(AppPalette palette, _Row row) {
    final alive = row.resolved.alive;
    final onSurface = Theme.of(context).colorScheme.onSurface;
    final title = row.record.label ?? row.resolved.title;
    return InkWell(
      onTap: alive ? () => _openRow(row) : null,
      borderRadius: BorderRadius.circular(kRadius),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
        child: Row(
          children: [
            Icon(
              alive ? _kindIcon(row.resolved.kind) : Icons.link_off,
              size: 20,
              color: alive ? palette.textDim : palette.border,
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 15,
                      color: alive ? onSurface : palette.textDim,
                      decoration: alive ? null : TextDecoration.lineThrough,
                    ),
                  ),
                  Text(
                    alive
                        ? (row.resolved.path.isEmpty
                            ? _kindLabel(row.resolved.kind)
                            : row.resolved.path)
                        : 'No longer exists — restore it to re-enable',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: palette.textDim),
                  ),
                ],
              ),
            ),
            IconButton(
              tooltip: 'Edit link (name / destination)',
              icon: const Icon(Icons.edit_outlined, size: 18),
              color: palette.textDim,
              onPressed: () => _editRow(row),
            ),
            IconButton(
              tooltip: 'Remove connection (both sides)',
              icon: const Icon(Icons.close, size: 18),
              color: palette.textDim,
              onPressed: () => _remove(row.record),
            ),
          ],
        ),
      ),
    );
  }

  static String _kindLabel(LinkTargetKind k) => switch (k) {
        LinkTargetKind.notebook => 'Notebook',
        LinkTargetKind.folder => 'Folder',
        LinkTargetKind.section => 'Section',
        LinkTargetKind.canvas => 'Canvas',
        LinkTargetKind.page => 'Page',
        LinkTargetKind.element => 'Canvas selection',
        LinkTargetKind.bookmark => 'Bookmark',
        LinkTargetKind.external => 'External link',
      };
}
