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
  late List<String> _addPromoted;
  late List<String> _overflowPromoted;

  @override
  void initState() {
    super.initState();
    final s = SettingsService();
    _addPromoted = List.of(
      widget.mobile ? s.promotedAddActionsMobile : s.promotedAddActionsDesktop,
    );
    _overflowPromoted = List.of(
      widget.mobile
          ? s.promotedOverflowActionsMobile
          : s.promotedOverflowActionsDesktop,
    );
  }

  void _setAdd(List<String> ids) {
    setState(() => _addPromoted = ids);
    SettingsService().setPromotedActions(
      mobile: widget.mobile,
      origin: 'add',
      ids: ids,
    );
  }

  void _setOverflow(List<String> ids) {
    setState(() => _overflowPromoted = ids);
    SettingsService().setPromotedActions(
      mobile: widget.mobile,
      origin: 'overflow',
      ids: ids,
    );
  }

  @override
  Widget build(BuildContext context) {
    final palette = Theme.of(context).extension<AppPalette>()!;
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
            'items between the bar and the menu.',
            style: TextStyle(fontSize: 12, color: palette.textDim),
          ),
        ),
        const SizedBox(height: 12),
        _CustomizeSection(
          title: 'Add actions',
          specs: kAddActionSpecs,
          promoted: _addPromoted,
          onChanged: _setAdd,
        ),
        const Divider(height: 24),
        _CustomizeSection(
          title: 'Tools & settings',
          specs: kOverflowActionSpecs,
          promoted: _overflowPromoted,
          onChanged: _setOverflow,
        ),
        const SizedBox(height: 12),
      ],
    );
  }
}

class _CustomizeSection extends StatelessWidget {
  final String title;
  final List<ToolbarActionSpec> specs;
  final List<String> promoted;
  final ValueChanged<List<String>> onChanged;

  const _CustomizeSection({
    required this.title,
    required this.specs,
    required this.promoted,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final palette = Theme.of(context).extension<AppPalette>()!;
    final onBarSpecs = [
      for (final id in promoted)
        if (findActionSpec(id) != null) findActionSpec(id)!,
    ];
    final inMenuSpecs = specs.where((s) => !promoted.contains(s.id)).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text(
            title,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: palette.textDim,
            ),
          ),
        ),
        const SizedBox(height: 4),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text(
            'On toolbar',
            style: TextStyle(fontSize: 11, color: palette.textDim),
          ),
        ),
        if (onBarSpecs.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            child: Text(
              'Nothing promoted — everything below stays in the menu',
              style: TextStyle(fontSize: 12, color: palette.textDim),
            ),
          )
        else
          ReorderableListView(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            buildDefaultDragHandles: false,
            onReorder: (oldIndex, newIndex) {
              final ids = List.of(promoted);
              if (newIndex > oldIndex) newIndex -= 1;
              final id = ids.removeAt(oldIndex);
              ids.insert(newIndex, id);
              onChanged(ids);
            },
            children: [
              for (final entry in onBarSpecs.asMap().entries)
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
                      onPressed: () {
                        final ids = List.of(promoted)..remove(entry.value.id);
                        onChanged(ids);
                      },
                    ),
                  ),
                ),
            ],
          ),
        const SizedBox(height: 4),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text(
            'In menu',
            style: TextStyle(fontSize: 11, color: palette.textDim),
          ),
        ),
        for (final spec in inMenuSpecs)
          ListTile(
            dense: true,
            leading: Icon(spec.icon, size: 20),
            title: Text(spec.label),
            trailing: IconButton(
              icon: const Icon(Icons.add_circle_outline, size: 20),
              tooltip: 'Add to toolbar',
              onPressed: () {
                final ids = List.of(promoted)..add(spec.id);
                onChanged(ids);
              },
            ),
          ),
      ],
    );
  }
}
