import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/link.dart';
import '../services/link_resolver.dart';
import '../services/search_service.dart';
import '../theme/app_theme.dart';
import '../utils/url_text.dart';
import 'action_sheet.dart';

/// A picked link target: the destination [target] plus the [title] to show for
/// it (an internal item's live name, or a pasted URL). Returned by both the
/// search list and the Paste button.
class LinkPick {
  final LinkEndpoint target;
  final String title;
  const LinkPick(this.target, this.title);
}

/// A search-backed "link to…" picker (the `[[` trigger, the text toolbar's link
/// button, and the Connections sheet's Choose-target flow): type to filter every
/// notebook / section / super-section / canvas / bookmark by name, or hit
/// **Paste** to turn a copied link (internal or external) straight into the
/// target. Pasting plain (non-link) text instead seeds the search with it.
/// Returns the picked [LinkPick] or null when dismissed.
Future<LinkPick?> showLinkTargetPicker(BuildContext context) {
  return showModalBottomSheet<LinkPick>(
    context: context,
    isScrollControlled: true,
    builder: (sheetContext) => cappedSheetBody(
      sheetContext,
      child: Padding(
        // Keyboard-aware — the search field must stay above the IME.
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(sheetContext).viewInsets.bottom,
        ),
        child: const _TargetPicker(),
      ),
    ),
  );
}

class _TargetPicker extends StatefulWidget {
  const _TargetPicker();

  @override
  State<_TargetPicker> createState() => _TargetPickerState();
}

class _TargetPickerState extends State<_TargetPicker> {
  final TextEditingController _search = TextEditingController();
  List<SearchResult>? _index;
  List<SearchResult> _results = const [];
  String _query = '';

  @override
  void initState() {
    super.initState();
    SearchService().buildIndex().then((index) {
      if (!mounted) return;
      setState(() {
        _index = index;
        _results = SearchService().filter(index, _query);
      });
    });
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _onQuery(String q) {
    _query = q;
    final index = _index;
    if (index == null) return;
    setState(() => _results = SearchService().filter(index, q));
  }

  /// Paste: a copied link (internal item or any URL) → return it directly;
  /// non-link text → seed the search with it (so a copied *name* still finds
  /// its item). Mirrors the Connections sheet's paste detection.
  Future<void> _paste() async {
    final data = await Clipboard.getData('text/plain');
    final text = data?.text?.trim() ?? '';
    if (text.isEmpty) return;
    var target = LinkEndpoint.tryParse(text);
    if (target == null) {
      final url = firstUrlIn(text);
      if (url != null) target = LinkEndpoint.external(url);
    }
    if (target == null) {
      // Not a link → treat the pasted text as a search query.
      _search.text = text;
      _search.selection =
          TextSelection.collapsed(offset: text.length);
      _onQuery(text);
      return;
    }
    // A link → its display title is the item's live name (external = the URL).
    final ep = target;
    var title = ep.externalUrl ?? '';
    if (ep.externalUrl == null) {
      final resolved = await resolveEndpoint(ep);
      title =
          resolved.alive && resolved.title.isNotEmpty ? resolved.title : 'Link';
    }
    if (!mounted) return;
    Navigator.of(context).pop(LinkPick(ep, title));
  }

  void _pickResult(SearchResult r) {
    final ep = endpointOfSearchResult(r);
    if (ep == null) return; // malformed entry — can't be linked
    Navigator.of(context).pop(LinkPick(ep, r.title));
  }

  static IconData _icon(SearchKind k) => switch (k) {
        SearchKind.notebook => Icons.menu_book_outlined,
        SearchKind.superSection => Icons.folder_outlined,
        SearchKind.section => Icons.topic_outlined,
        SearchKind.canvas => Icons.description_outlined,
        SearchKind.bookmark => Icons.bookmark_outline,
      };

  @override
  Widget build(BuildContext context) {
    final palette = Theme.of(context).extension<AppPalette>()!;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: Container(
              width: 36,
              height: 4,
              margin: const EdgeInsets.only(bottom: 8),
              decoration: BoxDecoration(
                color: palette.border,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _search,
                  autofocus: true,
                  onChanged: _onQuery,
                  decoration: const InputDecoration(
                    hintText: 'Link to…',
                    prefixIcon: Icon(Icons.search, size: 20),
                    isDense: true,
                  ),
                ),
              ),
              const SizedBox(width: 6),
              // Paste a copied link (or a copied name to search).
              OutlinedButton.icon(
                onPressed: _paste,
                icon: const Icon(Icons.content_paste, size: 18),
                label: const Text('Paste'),
                style: OutlinedButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          if (_index == null)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
            )
          else if (_results.isEmpty)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                'No matches.',
                style: TextStyle(fontSize: 13, color: palette.textDim),
              ),
            )
          else
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: _results.length,
                itemBuilder: (_, i) {
                  final r = _results[i];
                  return ListTile(
                    dense: true,
                    leading: Icon(_icon(r.kind), size: 20,
                        color: palette.textDim),
                    title: Text(r.title,
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: r.path.isEmpty
                        ? null
                        : Text(r.path,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontSize: 11.5, color: palette.textDim)),
                    onTap: () => _pickResult(r),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }
}
