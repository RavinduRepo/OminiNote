import 'package:flutter/material.dart';
import '../services/notebook_service.dart';
import '../services/sync_service.dart';
import '../theme/app_theme.dart';
import '../utils/formatting.dart';

/// The recycle bin: soft-deleted notebooks/sections/canvases, restorable for
/// 30 days (then the GC sweep removes them permanently). Restore clears the
/// tombstone with a bumped rev, so it propagates through sync like any edit.
class BinScreen extends StatefulWidget {
  const BinScreen({super.key});

  @override
  State<BinScreen> createState() => _BinScreenState();
}

class _BinScreenState extends State<BinScreen> {
  final _service = NotebookService();
  List<BinItem>? _items;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final items = await _service.listDeletedItems();
    if (!mounted) return;
    setState(() => _items = items);
  }

  Future<void> _restore(BinItem item) async {
    await _service.restoreBinItem(item);
    SyncService().dataVersion.value++; // nudge open list screens to reload
    await _load();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Restored "${item.name}"'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  Future<void> _purge(BinItem item) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete forever?'),
        content: Text(
          '"${item.name}" will be permanently deleted from this device. '
          'This cannot be undone.',
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
    if (confirmed != true) return;
    await _service.purgeBinItem(item);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final palette = Theme.of(context).extension<AppPalette>()!;
    final items = _items;
    return Scaffold(
      appBar: AppBar(title: const Text('Recycle bin')),
      body: items == null
          ? const Center(child: CircularProgressIndicator())
          : items.isEmpty
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.delete_outline, size: 48, color: palette.textDim),
                  const SizedBox(height: 12),
                  const Text('Bin is empty'),
                  const SizedBox(height: 4),
                  Text(
                    'Deleted items stay here for 30 days',
                    style: TextStyle(fontSize: 12.5, color: palette.textDim),
                  ),
                ],
              ),
            )
          : ListView.separated(
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemCount: items.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, i) {
                final item = items[i];
                final daysLeft = 30 -
                    DateTime.now().difference(item.deletedAt).inDays;
                return ListTile(
                  leading: Icon(switch (item.type) {
                    BinItemType.notebook => Icons.menu_book_outlined,
                    BinItemType.section => Icons.description_outlined,
                    BinItemType.canvas => Icons.crop_portrait,
                  }),
                  title: Text(item.name),
                  subtitle: Text(
                    [
                      'Deleted ${formatShortDate(item.deletedAt)}',
                      if (item.parentName.isNotEmpty) 'in ${item.parentName}',
                      if (daysLeft > 0) '$daysLeft day(s) left',
                    ].join(' · '),
                    style: TextStyle(fontSize: 12, color: palette.textDim),
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.restore),
                        tooltip: item.parentAlive
                            ? 'Restore'
                            : 'Restore its ${item.type == BinItemType.canvas ? 'section' : 'notebook'} first',
                        onPressed:
                            item.parentAlive ? () => _restore(item) : null,
                      ),
                      IconButton(
                        icon: const Icon(Icons.delete_forever_outlined),
                        tooltip: 'Delete forever',
                        onPressed: () => _purge(item),
                      ),
                    ],
                  ),
                );
              },
            ),
    );
  }
}
