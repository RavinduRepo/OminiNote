import 'package:flutter/material.dart';

import '../models/link.dart';
import '../models/tag.dart';
import '../services/tag_service.dart';
import '../theme/app_theme.dart';
import 'action_sheet.dart';

/// Attach/detach, create, rename and delete tags for one item ([endpoint]).
/// Names only. Tags are synced (`tags.json`), so changes propagate like links.
Future<void> showTagManagerSheet(
  BuildContext context, {
  required LinkEndpoint endpoint,
  bool? desktop,
}) {
  return showAdaptiveMenu<void>(
    context,
    desktop: desktop,
    builder: (sheetContext) => cappedSheetBody(
      sheetContext,
      child: _TagManager(endpoint: endpoint),
    ),
  );
}

class _TagManager extends StatefulWidget {
  final LinkEndpoint endpoint;
  const _TagManager({required this.endpoint});

  @override
  State<_TagManager> createState() => _TagManagerState();
}

class _TagManagerState extends State<_TagManager> {
  final _searchCtrl = TextEditingController();
  String _query = '';
  List<TagDef>? _all;
  Set<String> _assigned = {};

  @override
  void initState() {
    super.initState();
    _reload();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    final all = await TagService().allTags();
    final mine = await TagService().tagsOf(widget.endpoint.leafId);
    if (!mounted) return;
    setState(() {
      _all = all;
      _assigned = mine.map((t) => t.id).toSet();
    });
  }

  /// Attaches the tag named [name] — reusing an existing same-named tag
  /// (case-insensitive) instead of creating a duplicate, else creating it. The
  /// seamless search-or-create: type a name, tap it if it exists, or create it.
  Future<void> _createAndAttach(String name) async {
    final n = name.trim();
    if (n.isEmpty) return;
    final existing = (_all ?? const <TagDef>[])
        .where((t) => t.name.toLowerCase() == n.toLowerCase());
    final def =
        existing.isNotEmpty ? existing.first : await TagService().createTag(n);
    await TagService().assign(def.id, widget.endpoint);
    _searchCtrl.clear();
    _query = '';
    await _reload();
  }

  Future<void> _toggle(TagDef t, bool on) async {
    if (on) {
      await TagService().assign(t.id, widget.endpoint);
    } else {
      await TagService().unassign(t.id, widget.endpoint);
    }
    await _reload();
  }

  Future<void> _rename(TagDef t) async {
    final ctrl = TextEditingController(text: t.name);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Rename tag'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'Tag name'),
          onSubmitted: (v) => Navigator.of(ctx).pop(v.trim()),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(), child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(ctrl.text.trim()),
              child: const Text('Save')),
        ],
      ),
    );
    ctrl.dispose();
    if (name == null || name.isEmpty) return;
    await TagService().renameTag(t.id, name);
    await _reload();
  }

  Future<void> _delete(TagDef t) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete tag “${t.name}”?'),
        content: const Text('It will be removed from every item it\'s on.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true) return;
    await TagService().deleteTag(t.id);
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    final palette = Theme.of(context).extension<AppPalette>()!;
    final onSurface = Theme.of(context).colorScheme.onSurface;
    final all = _all;
    final q = _query.trim();
    final ql = q.toLowerCase();
    final filtered = (all == null || q.isEmpty)
        ? (all ?? const <TagDef>[])
        : all.where((t) => t.name.toLowerCase().contains(ql)).toList();
    final exact = all != null && all.any((t) => t.name.toLowerCase() == ql);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 12, 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: Container(
              width: 36,
              height: 4,
              margin: const EdgeInsets.only(bottom: 10),
              decoration: BoxDecoration(
                  color: palette.border,
                  borderRadius: BorderRadius.circular(2)),
            ),
          ),
          Text('Tags',
              style: TextStyle(
                  fontSize: 13, fontWeight: FontWeight.w600, color: palette.textDim)),
          const SizedBox(height: 8),
          TextField(
            controller: _searchCtrl,
            autofocus: true,
            textInputAction: TextInputAction.done,
            decoration: const InputDecoration(
              isDense: true,
              hintText: 'Search or create a tag',
              prefixIcon: Icon(Icons.search, size: 20),
            ),
            onChanged: (v) => setState(() => _query = v),
            onSubmitted: _createAndAttach,
          ),
          const SizedBox(height: 4),
          // When the typed name isn't an existing tag, offer to create it —
          // the seamless "not found → make it" path.
          if (all != null && q.isNotEmpty && !exact)
            ListTile(
              dense: true,
              leading: Icon(Icons.add, size: 20, color: palette.accent),
              title: Text('Create “$q”',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 14, color: palette.accent)),
              onTap: () => _createAndAttach(q),
            ),
          if (all == null)
            const Padding(
              padding: EdgeInsets.all(20),
              child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
            )
          else if (filtered.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Text(
                  q.isEmpty
                      ? 'No tags yet — type a name to create one.'
                      : (exact ? 'No other matching tags.' : 'No matching tags.'),
                  style: TextStyle(fontSize: 13, color: palette.textDim)),
            )
          else
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: filtered.length,
                itemBuilder: (_, i) {
                  final t = filtered[i];
                  final on = _assigned.contains(t.id);
                  return Row(
                    children: [
                      Checkbox(
                        value: on,
                        onChanged: (v) => _toggle(t, v ?? false),
                        visualDensity: VisualDensity.compact,
                        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      Expanded(
                        child: Text(t.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 14, color: onSurface)),
                      ),
                      IconButton(
                        icon: const Icon(Icons.edit_outlined, size: 17),
                        color: palette.textDim,
                        tooltip: 'Rename',
                        onPressed: () => _rename(t),
                      ),
                      IconButton(
                        icon: const Icon(Icons.delete_outline, size: 17),
                        color: palette.textDim,
                        tooltip: 'Delete tag everywhere',
                        onPressed: () => _delete(t),
                      ),
                    ],
                  );
                },
              ),
            ),
        ],
      ),
    );
  }
}
