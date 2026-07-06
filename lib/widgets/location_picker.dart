import 'package:flutter/material.dart';
import '../models/section.dart';
import '../services/notebook_service.dart';
import '../theme/app_theme.dart';

/// A chosen canvas destination: a section within a notebook.
class CanvasDestination {
  final String notebookId;
  final String sectionId;
  final String label;
  const CanvasDestination(this.notebookId, this.sectionId, this.label);
}

/// Picks a destination **notebook** (for moving/copying a section). Returns the
/// notebook id, or null if cancelled.
Future<String?> pickNotebookDestination(
  BuildContext context, {
  required String title,
}) async {
  final service = NotebookService();
  final notebooks = await service.getNotebooks();
  if (!context.mounted) return null;
  return showDialog<String>(
    context: context,
    builder: (context) => SimpleDialog(
      title: Text(title),
      children: [
        if (notebooks.isEmpty)
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text('No notebooks.'),
          ),
        for (final nb in notebooks)
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, nb.id),
            child: Row(
              children: [
                _dot(AppPalette.resolveColor(nb.id, nb.color)),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(nb.name, overflow: TextOverflow.ellipsis),
                ),
              ],
            ),
          ),
      ],
    ),
  );
}

/// Picks a destination **section** (for moving/copying a canvas): notebooks
/// expand to their sections. Returns the chosen section, or null.
Future<CanvasDestination?> pickSectionDestination(
  BuildContext context, {
  required String title,
}) async {
  final service = NotebookService();
  final notebooks = await service.getNotebooks();
  final sectionMaps = <String, Map<String, Section>>{};
  for (final nb in notebooks) {
    sectionMaps[nb.id] = await service.getSectionMap(nb.id);
  }
  if (!context.mounted) return null;

  return showDialog<CanvasDestination>(
    context: context,
    builder: (context) {
      final palette = Theme.of(context).extension<AppPalette>()!;
      return Dialog(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420, maxHeight: 520),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 18, 20, 8),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    title,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    children: [
                      for (final nb in notebooks)
                        Theme(
                          data: Theme.of(
                            context,
                          ).copyWith(dividerColor: Colors.transparent),
                          child: ExpansionTile(
                            initiallyExpanded: notebooks.length == 1,
                            leading: _dot(
                              AppPalette.resolveColor(nb.id, nb.color),
                            ),
                            title: Text(
                              nb.name,
                              style: const TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            childrenPadding: EdgeInsets.zero,
                            children: [
                              for (final sectionId in nb.allSectionIds)
                                if (sectionMaps[nb.id]?[sectionId] != null)
                                  ListTile(
                                    contentPadding: const EdgeInsets.only(
                                      left: 48,
                                      right: 16,
                                    ),
                                    dense: true,
                                    leading: Icon(
                                      Icons.description_outlined,
                                      size: 18,
                                      color: AppPalette.resolveColor(
                                        sectionId,
                                        sectionMaps[nb.id]![sectionId]!.color,
                                      ),
                                    ),
                                    title: Text(
                                      sectionMaps[nb.id]![sectionId]!.name,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    onTap: () => Navigator.pop(
                                      context,
                                      CanvasDestination(
                                        nb.id,
                                        sectionId,
                                        sectionMaps[nb.id]![sectionId]!.name,
                                      ),
                                    ),
                                  ),
                              if (nb.allSectionIds.isEmpty)
                                Padding(
                                  padding: const EdgeInsets.only(
                                    left: 48,
                                    bottom: 8,
                                  ),
                                  child: Align(
                                    alignment: Alignment.centerLeft,
                                    child: Text(
                                      'No sections',
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: palette.textDim,
                                      ),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              Align(
                alignment: Alignment.centerRight,
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Cancel'),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}

Widget _dot(Color color) => Container(
  width: 12,
  height: 12,
  decoration: BoxDecoration(color: color, shape: BoxShape.circle),
);
