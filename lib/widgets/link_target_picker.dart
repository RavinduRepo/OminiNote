import 'package:flutter/material.dart';

import '../services/search_service.dart';
import '../theme/app_theme.dart';
import 'action_sheet.dart';

/// A search-backed "link to…" picker (the `[[` trigger and the Connections
/// sheet's Choose-target flow): type to filter every notebook / section /
/// super-section / canvas / bookmark by name, pick one. Returns the picked
/// [SearchResult] or null when dismissed.
Future<SearchResult?> showLinkTargetPicker(BuildContext context) {
  return showModalBottomSheet<SearchResult>(
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

  void _onQuery(String q) {
    _query = q;
    final index = _index;
    if (index == null) return;
    setState(() => _results = SearchService().filter(index, q));
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
          TextField(
            autofocus: true,
            onChanged: _onQuery,
            decoration: const InputDecoration(
              hintText: 'Link to…',
              prefixIcon: Icon(Icons.search, size: 20),
              isDense: true,
            ),
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
                    onTap: () => Navigator.of(context).pop(r),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }
}
