import 'package:flutter/material.dart';
import '../../services/settings_service.dart';
import '../../theme/app_theme.dart';
import '../../widgets/action_sheet.dart';
import 'toolbar_actions.dart';

/// Opens the "Customize toolbar" sheet for the currently-active layout
/// (mobile app bar vs desktop toolbar have separate promoted-action lists,
/// mirroring `_useMobileMenus`'s existing mobile/desktop split).
Future<void> showCustomizeToolbarSheet(
  BuildContext context, {
  required bool mobile,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (context) => scrollableSheetBody(
      context,
      child: _CustomizeToolbarSheetBody(mobile: mobile),
    ),
  );
}

class _CustomizeToolbarSheetBody extends StatefulWidget {
  final bool mobile;
  const _CustomizeToolbarSheetBody({required this.mobile});

  @override
  State<_CustomizeToolbarSheetBody> createState() =>
      _CustomizeToolbarSheetBodyState();
}

class _CustomizeToolbarSheetBodyState
    extends State<_CustomizeToolbarSheetBody> {
  late List<String> _promoted;

  @override
  void initState() {
    super.initState();
    final s = SettingsService();
    _promoted = List.of(
      widget.mobile ? s.promotedToolbarMobile : s.promotedToolbarDesktop,
    );
  }

  void _set(List<String> ids) {
    setState(() => _promoted = ids);
    SettingsService().setPromotedToolbar(mobile: widget.mobile, ids: ids);
  }

  void _remove(String id) => _set(List.of(_promoted)..remove(id));
  void _add(String id) => _set(List.of(_promoted)..add(id));

  void _reorder(int oldIndex, int newIndex) {
    final ids = List.of(_promoted);
    if (newIndex > oldIndex) newIndex -= 1;
    ids.insert(newIndex, ids.removeAt(oldIndex));
    _set(ids);
  }

  @override
  Widget build(BuildContext context) {
    final palette = Theme.of(context).extension<AppPalette>()!;
    // The single ordered "on the bar" list, resolved to specs (unknown ids
    // from a future build are silently skipped).
    final onBar = [
      for (final id in _promoted)
        if (findActionSpec(id) != null) findActionSpec(id)!,
    ];
    bool promoted(String id) => _promoted.contains(id);

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 8),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text(
            'Customize toolbar',
            style: Theme.of(context).textTheme.titleMedium,
          ),
        ),
        const SizedBox(height: 4),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text(
            'Long-press to reorder what\'s on the bar. Tap + or − to move '
            'items between the bar and the "⋯" menu. The "⋯" menu itself '
            'always stays.',
            style: TextStyle(fontSize: 12, color: palette.textDim),
          ),
        ),
        const SizedBox(height: 12),
        // ── On toolbar (one unified, reorderable sequence) ──
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text(
            'On toolbar',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: palette.textDim,
            ),
          ),
        ),
        const SizedBox(height: 4),
        if (onBar.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            child: Text(
              'Nothing on the bar — only the "⋯" menu shows',
              style: TextStyle(fontSize: 12, color: palette.textDim),
            ),
          )
        else
          ReorderableListView(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            buildDefaultDragHandles: false,
            onReorder: _reorder,
            children: [
              for (final entry in onBar.asMap().entries)
                ReorderableDelayedDragStartListener(
                  key: ValueKey('bar-${entry.value.id}'),
                  index: entry.key,
                  child: ListTile(
                    dense: true,
                    leading: Icon(entry.value.icon, size: 20),
                    title: Text(entry.value.label),
                    trailing: IconButton(
                      icon: const Icon(Icons.remove_circle_outline, size: 20),
                      tooltip: 'Remove from toolbar',
                      onPressed: () => _remove(entry.value.id),
                    ),
                  ),
                ),
            ],
          ),
        const Divider(height: 24),
        // ── In menu, grouped by origin so items stay easy to find ──
        _AddGroup(
          title: 'Buttons',
          specs: kCoreActionSpecs,
          promoted: promoted,
          onAdd: _add,
        ),
        _AddGroup(
          title: 'Add actions',
          specs: kAddActionSpecs,
          promoted: promoted,
          onAdd: _add,
        ),
        _AddGroup(
          title: 'Tools & settings',
          specs: kOverflowActionSpecs,
          promoted: promoted,
          onAdd: _add,
        ),
        const SizedBox(height: 12),
      ],
    );
  }
}

/// One "In menu" category: its not-yet-promoted specs, each with a "+ add to
/// bar" button. Renders nothing when every spec in it is already on the bar.
class _AddGroup extends StatelessWidget {
  final String title;
  final List<ToolbarActionSpec> specs;
  final bool Function(String id) promoted;
  final ValueChanged<String> onAdd;

  const _AddGroup({
    required this.title,
    required this.specs,
    required this.promoted,
    required this.onAdd,
  });

  @override
  Widget build(BuildContext context) {
    final palette = Theme.of(context).extension<AppPalette>()!;
    final inMenu = specs.where((s) => !promoted(s.id)).toList();
    if (inMenu.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
          child: Text(
            title,
            style: TextStyle(fontSize: 11, color: palette.textDim),
          ),
        ),
        for (final spec in inMenu)
          ListTile(
            dense: true,
            leading: Icon(spec.icon, size: 20),
            title: Text(spec.label),
            trailing: IconButton(
              icon: const Icon(Icons.add_circle_outline, size: 20),
              tooltip: 'Add to toolbar',
              onPressed: () => onAdd(spec.id),
            ),
          ),
      ],
    );
  }
}
