import 'package:flutter/material.dart';

import '../models/canvas.dart';
import '../models/notebook.dart';
import '../models/section.dart';
import '../screens/canvas_workspace_screen.dart';
import '../services/link_navigator.dart';
import '../services/notebook_service.dart';
import '../services/search_service.dart';
import '../theme/app_theme.dart';
import 'formatting.dart';
import 'new_canvas_ui.dart';

/// Creates a canvas at this device's default target — the notebook marked
/// default (its landing section), else a local-only "Quick Notes" — then
/// **navigates there and opens it the way the active shell opens a canvas**
/// (desktop: selected + embedded in the panes; mobile: full-bleed with the
/// section list behind it). This mirrors the OS "open PDF with" flow, minus
/// the location prompt. [kind] chooses empty vs a PDF-backed canvas.
Future<void> createQuickNote(
  BuildContext context, {
  NewCanvasKind kind = NewCanvasKind.empty,
}) async {
  final svc = NotebookService();
  final target = await svc.resolveDefaultTarget();
  if (!context.mounted) return;
  final Canvas canvas;
  if (kind == NewCanvasKind.pdf) {
    final c = await pickAndCreatePdfCanvas(context, target.section);
    if (c == null) return;
    canvas = c;
  } else {
    canvas = await svc.createCanvas(
      target.section,
      'Quick note ${formatShortDate(DateTime.now())}',
    );
  }
  if (!context.mounted) return;
  _openNewCanvas(context, target.notebook, target.section, canvas);
}

void _openNewCanvas(
  BuildContext context,
  Notebook notebook,
  Section section,
  Canvas canvas,
) {
  final result = SearchResult(
    kind: SearchKind.canvas,
    title: canvas.name,
    path: '${notebook.name} › ${section.name}',
    notebook: notebook,
    section: section,
    canvas: canvas,
  );
  // Route through the active shell so it lands at the default location and
  // opens the canvas in that shell's native way. Fall back to a direct push
  // if no shell is registered (shouldn't happen in normal use).
  if (!LinkNavigator().openCanvas(result)) {
    Navigator.of(context, rootNavigator: true).push(
      slideRoute(CanvasWorkspaceScreen(initialCanvas: canvas)),
    );
  }
}

/// Press-and-hold the quick-note control to choose empty vs PDF, then create.
Future<void> chooseAndCreateQuickNote(BuildContext context) async {
  final kind = await pickNewCanvasKind(context);
  if (kind == null || !context.mounted) return;
  await createQuickNote(context, kind: kind);
}

/// A one-tap quick-note control (mobile home app bar): tap creates an empty
/// quick note at the default target; press-and-hold offers empty vs PDF.
class QuickNoteButton extends StatelessWidget {
  const QuickNoteButton({super.key});

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: 'Quick note (hold for options)',
      child: InkResponse(
        onTap: () => createQuickNote(context),
        onLongPress: () => chooseAndCreateQuickNote(context),
        radius: 24,
        child: const Padding(
          padding: EdgeInsets.all(8),
          child: Icon(Icons.bolt_outlined),
        ),
      ),
    );
  }
}
