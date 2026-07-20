import 'package:flutter/material.dart';
import '../services/notebook_service.dart';
import '../services/sync_service.dart';
import '../theme/app_theme.dart';
import '../utils/app_toast.dart';

/// The recycle bin: soft-deleted notebooks/sections/canvases, restorable for
/// 30 days (then the GC sweep removes them permanently). Restore clears the
/// tombstone with a bumped rev, so it propagates through sync like any edit.
class BinScreen extends StatefulWidget {
  /// Bumped by the host (mobile shell) each time the Bin tab is opened, so the
  /// kept-alive tab reloads its list — otherwise something deleted elsewhere
  /// wouldn't appear until the tab was rebuilt.
  final Listenable? refreshSignal;

  const BinScreen({super.key, this.refreshSignal});

  @override
  State<BinScreen> createState() => _BinScreenState();
}

class _BinScreenState extends State<BinScreen> {
  final _service = NotebookService();
  List<BinItem>? _items;

  // `dataVersion` at the last completed load; -1 = never loaded. Entering the
  // Bin tab reloads only when the store actually changed since (local
  // delete/restore/purge now bump dataVersion too, not just remote pulls), so
  // swiping into the Bin no longer rescans the whole store every single time.
  int _loadedVersion = -1;

  // Keys of rows currently animating out (restore / delete-forever) so the
  // row collapses + fades before the list actually drops it.
  final Set<String> _removing = {};
  static const _kRemoveAnim = Duration(milliseconds: 280);

  String _keyOf(BinItem item) => '${item.type}_${_identityId(item)}';

  @override
  void initState() {
    super.initState();
    // Defer the first (whole-store) scan off the entry/push animation frame.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _load();
    });
    widget.refreshSignal?.addListener(_maybeReload);
  }

  @override
  void dispose() {
    widget.refreshSignal?.removeListener(_maybeReload);
    super.dispose();
  }

  /// Reload on tab entry only if the store changed since the last load (or we
  /// never loaded) — the cache that kills the swipe-into-Bin rescan.
  void _maybeReload() {
    if (_items == null || SyncService().dataVersion.value != _loadedVersion) {
      _load();
    }
  }

  Future<void> _load() async {
    // Capture BEFORE the async scan: a change landing mid-scan leaves the
    // version stale, so the next entry reloads (no missed updates).
    final version = SyncService().dataVersion.value;
    final items = await _service.listDeletedItems();
    if (!mounted) return;
    setState(() {
      _items = items;
      _loadedVersion = version;
      _removing.clear();
    });
  }

  /// Animate a row out (collapse + fade) before running [action].
  Future<void> _removeThen(BinItem item, Future<void> Function() action) async {
    setState(() => _removing.add(_keyOf(item)));
    await Future.delayed(_kRemoveAnim);
    await action();
    if (mounted) await _load();
  }

  Future<void> _restore(BinItem item) async {
    await _removeThen(item, () async {
      await _service.restoreBinItem(item); // bumps dataVersion internally now
    });
    if (mounted) {
      showAppToast(context, 'Restored "${item.name}"');
    }
  }

  Future<bool> _confirmPurge(String what) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete forever?'),
        content: Text(
          '$what will be permanently deleted from all devices and '
          'Google Drive. This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete forever'),
          ),
        ],
      ),
    );
    return confirmed == true;
  }

  Future<void> _purge(BinItem item) async {
    if (!await _confirmPurge('"${item.name}"')) return;
    await _removeThen(item, () => _service.purgeBinItem(item));
  }

  Future<void> _emptyBin() async {
    final items = _items;
    if (items == null || items.isEmpty) return;
    if (!await _confirmPurge('All ${items.length} item(s)')) return;
    for (final item in items) {
      await _service.purgeBinItem(item);
    }
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final palette = Theme.of(context).extension<AppPalette>()!;
    final items = _items;
    final canPop = Navigator.of(context).canPop();
    return Scaffold(
      appBar: AppBar(
        title: const Text('Recycle bin'),
        // See settings_screen.dart's identical comment: only tighten when a
        // back chevron is actually showing (desktop, pushed); as a mobile tab
        // root there's no leading, so keep the default spacing.
        titleSpacing: canPop ? 4 : null,
        leadingWidth: canPop ? 40 : null,
        leading: canPop
            ? IconButton(
                padding: EdgeInsets.zero,
                icon: const Icon(kBackIcon),
                tooltip: 'Back',
                onPressed: () => Navigator.of(context).pop(),
              )
            : null,
        actions: [
          if (items != null && items.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.delete_sweep_outlined),
              tooltip: 'Empty bin',
              onPressed: _emptyBin,
            ),
        ],
      ),
      body: items == null
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _refresh,
              child: items.isEmpty
                  ? ListView(
                      // A scrollable so pull-to-refresh works on the empty state.
                      physics: const AlwaysScrollableScrollPhysics(),
                      children: [
                        SizedBox(
                          height:
                              MediaQuery.of(context).size.height * 0.6,
                          child: Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.delete_outline,
                                    size: 48, color: palette.textDim),
                                const SizedBox(height: 12),
                                const Text('Bin is empty'),
                                const SizedBox(height: 4),
                                Text(
                                  'Deleted items stay here for 30 days',
                                  style: TextStyle(
                                      fontSize: 12.5, color: palette.textDim),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    )
                  : ListView.builder(
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: const EdgeInsets.fromLTRB(10, 10, 10, 16),
                      itemCount: items.length,
                      itemBuilder: (context, i) =>
                          _binRow(context, palette, items[i]),
                    ),
            ),
    );
  }

  /// Pull-to-refresh: run a sync round trip, then reload the bin.
  Future<void> _refresh() async {
    await SyncService().syncNow();
    await _load();
  }

  Widget _binRow(BuildContext context, AppPalette palette, BinItem item) {
    final theme = Theme.of(context);
    final daysLeft = 30 - DateTime.now().difference(item.deletedAt).inDays;
    final railColor = AppPalette.resolveColor(_identityId(item), null);
    final removing = _removing.contains(_keyOf(item));
    final meta = [
      _typeLabel(item.type),
      if (item.parentName.isNotEmpty) 'in ${item.parentName}',
      if (daysLeft > 0) '$daysLeft day left',
    ].join(' · ');

    // Restore / delete-forever collapse the row (height → 0) and fade it out
    // before _load() drops it from the list.
    return AnimatedSize(
      duration: _kRemoveAnim,
      curve: Curves.easeInOut,
      alignment: Alignment.topCenter,
      child: AnimatedOpacity(
        opacity: removing ? 0 : 1,
        duration: const Duration(milliseconds: 200),
        child: removing
            ? const SizedBox(width: double.infinity)
            : _binCard(context, theme, palette, item, railColor, meta),
      ),
    );
  }

  Widget _binCard(
    BuildContext context,
    ThemeData theme,
    AppPalette palette,
    BinItem item,
    Color railColor,
    String meta,
  ) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(kRadius + 2),
        border: Border.all(color: palette.border),
      ),
      padding: const EdgeInsets.fromLTRB(10, 10, 6, 10),
      child: Row(
        children: [
          Container(
            width: 3,
            height: 34,
            decoration: BoxDecoration(
              color: railColor,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 10),
          Icon(
            switch (item.type) {
              BinItemType.notebook => Icons.menu_book_outlined,
              BinItemType.section => Icons.description_outlined,
              BinItemType.canvas => Icons.crop_portrait,
              BinItemType.page => Icons.insert_drive_file_outlined,
              BinItemType.folder => Icons.folder_outlined,
            },
            size: 20,
            color: palette.textDim,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 14, fontWeight: FontWeight.w500),
                ),
                const SizedBox(height: 3),
                Text(
                  meta,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 10.5,
                    color: palette.textDim,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 6),
          TextButton(
            onPressed: item.parentAlive ? () => _restore(item) : null,
            style: TextButton.styleFrom(
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: 10),
            ),
            child: Text(item.parentAlive
                ? 'Restore'
                : 'Restore ${switch (item.type) {
                    BinItemType.canvas || BinItemType.page => 'section',
                    BinItemType.folder =>
                      item.sectionId != null ? 'section' : 'notebook',
                    _ => 'notebook',
                  }} first'),
          ),
          IconButton(
            icon: const Icon(Icons.delete_forever_outlined, size: 20),
            tooltip: 'Delete forever',
            color: theme.colorScheme.error,
            visualDensity: VisualDensity.compact,
            onPressed: () => _purge(item),
          ),
        ],
      ),
    );
  }

  String _identityId(BinItem item) => switch (item.type) {
        BinItemType.notebook => item.notebookId,
        BinItemType.section => item.sectionId ?? item.notebookId,
        BinItemType.canvas => item.canvasId ?? item.notebookId,
        BinItemType.page =>
          item.pageId ?? item.canvasId ?? item.notebookId,
        BinItemType.folder => item.folderId ?? item.notebookId,
      };

  String _typeLabel(BinItemType t) => switch (t) {
        BinItemType.notebook => 'Notebook',
        BinItemType.section => 'Section',
        BinItemType.canvas => 'Canvas',
        BinItemType.page => 'Page',
        BinItemType.folder => 'Super-section',
      };
}
