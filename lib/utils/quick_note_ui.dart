import 'package:flutter/material.dart';

import '../models/canvas.dart';
import '../screens/canvas_workspace_screen.dart';
import '../services/notebook_service.dart';
import '../theme/app_theme.dart';
import 'formatting.dart';
import 'new_canvas_ui.dart';

/// Creates a canvas at this device's default target — the notebook marked
/// default (its landing section), else a local-only "Quick Notes" — and opens
/// it. This is the one-tap "quick note" flow; all the plumbing already exists
/// (`resolveDefaultTarget`), so it's just wiring. [kind] chooses empty vs a
/// PDF-backed canvas.
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
  Navigator.of(context, rootNavigator: true).push(
    slideRoute(CanvasWorkspaceScreen(initialCanvas: canvas)),
  );
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
