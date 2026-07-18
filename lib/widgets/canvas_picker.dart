import 'package:flutter/material.dart';

import '../models/canvas.dart';
import '../models/notebook.dart';
import '../models/section.dart';
import '../services/notebook_service.dart';
import '../theme/app_theme.dart';
import 'action_sheet.dart';

/// Modal picker that drills notebooks → sections → canvases and returns the
/// chosen [Canvas] (or null if dismissed). Canvases already open in the split
/// ([excludeIds]) are shown disabled. Used by the in-app split view to fill a
/// new pane.
Future<Canvas?> pickCanvasForPane(
  BuildContext context, {
  Set<String> excludeIds = const {},
}) {
  return showModalBottomSheet<Canvas>(
    context: context,
    isScrollControlled: true,
    builder: (context) => scrollableSheetBody(
      context,
      child: _CanvasPickerBody(excludeIds: excludeIds),
    ),
  );
}

class _CanvasPickerBody extends StatefulWidget {
  final Set<String> excludeIds;
  const _CanvasPickerBody({required this.excludeIds});

  @override
  State<_CanvasPickerBody> createState() => _CanvasPickerBodyState();
}

class _CanvasPickerBodyState extends State<_CanvasPickerBody> {
  final _svc = NotebookService();

  List<Notebook>? _notebooks;
  Notebook? _notebook;
  Map<String, Section>? _sections;
  Section? _section;
  Map<String, Canvas>? _canvases;

  @override
  void initState() {
    super.initState();
    _loadNotebooks();
  }

  Future<void> _loadNotebooks() async {
    final nbs = await _svc.getNotebooks();
    if (mounted) setState(() => _notebooks = nbs);
  }

  Future<void> _openNotebook(Notebook nb) async {
    setState(() {
      _notebook = nb;
      _sections = null;
    });
    final map = await _svc.getSectionMap(nb.id, notebook: nb);
    if (mounted) setState(() => _sections = map);
  }

  Future<void> _openSection(Section s) async {
    setState(() {
      _section = s;
      _canvases = null;
    });
    final map = await _svc.getCanvasMap(s);
    if (mounted) setState(() => _canvases = map);
  }

  void _back() {
    setState(() {
      if (_section != null) {
        _section = null;
        _canvases = null;
      } else if (_notebook != null) {
        _notebook = null;
        _sections = null;
      }
    });
  }

  String get _title {
    if (_section != null) return _section!.name;
    if (_notebook != null) return _notebook!.name;
    return 'Open a canvas';
  }

  @override
  Widget build(BuildContext context) {
    final palette = Theme.of(context).extension<AppPalette>()!;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(height: 8),
        Row(
          children: [
            if (_notebook != null)
              IconButton(
                icon: const Icon(Icons.chevron_left),
                tooltip: 'Back',
                onPressed: _back,
              )
            else
              const SizedBox(width: 12),
            Expanded(
              child: Text(
                _title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.close),
              tooltip: 'Cancel',
              onPressed: () => Navigator.pop(context),
            ),
          ],
        ),
        const Divider(height: 1),
        Flexible(child: _buildLevel(palette)),
        const SizedBox(height: 8),
      ],
    );
  }

  Widget _buildLevel(AppPalette palette) {
    if (_section != null) {
      final canvases = _canvases;
      if (canvases == null) return const _Loading();
      final ids = _section!.allCanvasIds.where(canvases.containsKey).toList();
      if (ids.isEmpty) return const _Empty('No canvases here');
      return ListView(
        shrinkWrap: true,
        children: [
          for (final id in ids)
            _row(
              palette,
              Icons.description_outlined,
              canvases[id]!.name,
              disabled: widget.excludeIds.contains(id),
              disabledHint: 'Already open',
              onTap: () => Navigator.pop(context, canvases[id]),
            ),
        ],
      );
    }
    if (_notebook != null) {
      final sections = _sections;
      if (sections == null) return const _Loading();
      final ids = _notebook!.allSectionIds.where(sections.containsKey).toList();
      if (ids.isEmpty) return const _Empty('No sections here');
      return ListView(
        shrinkWrap: true,
        children: [
          for (final id in ids)
            _row(palette, Icons.folder_outlined, sections[id]!.name,
                onTap: () => _openSection(sections[id]!)),
        ],
      );
    }
    final nbs = _notebooks;
    if (nbs == null) return const _Loading();
    if (nbs.isEmpty) return const _Empty('No notebooks');
    return ListView(
      shrinkWrap: true,
      children: [
        for (final nb in nbs)
          _row(palette, Icons.book_outlined, nb.name,
              color: AppPalette.resolveColor(nb.id, nb.color),
              onTap: () => _openNotebook(nb)),
      ],
    );
  }

  Widget _row(
    AppPalette palette,
    IconData icon,
    String label, {
    Color? color,
    bool disabled = false,
    String? disabledHint,
    required VoidCallback onTap,
  }) {
    return ListTile(
      dense: true,
      enabled: !disabled,
      leading: Icon(icon, size: 20, color: color ?? palette.textDim),
      title: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: disabled && disabledHint != null
          ? Text(disabledHint,
              style: TextStyle(fontSize: 11, color: palette.textDim))
          : null,
      trailing: disabled
          ? null
          : Icon(Icons.chevron_right, size: 18, color: palette.textDim),
      onTap: disabled ? null : onTap,
    );
  }
}

class _Loading extends StatelessWidget {
  const _Loading();
  @override
  Widget build(BuildContext context) => const Padding(
        padding: EdgeInsets.all(28),
        child: Center(child: CircularProgressIndicator()),
      );
}

class _Empty extends StatelessWidget {
  final String text;
  const _Empty(this.text);
  @override
  Widget build(BuildContext context) {
    final palette = Theme.of(context).extension<AppPalette>()!;
    return Padding(
      padding: const EdgeInsets.all(28),
      child: Center(
        child: Text(text, style: TextStyle(color: palette.textDim)),
      ),
    );
  }
}
