import 'package:flutter/material.dart';
import '../models/canvas.dart';
import '../models/section.dart';
import '../services/notebook_service.dart';
import '../screens/canvas_screen.dart';
import '../widgets/location_picker.dart';
import 'progress_overlay.dart';

enum _PdfDest { here, choose, cancel }

/// Handles a PDF opened *with* the app (OS "open with" / share): asks whether
/// to drop it in this device's default target (one tap) or choose a location,
/// then creates a PDF-backed canvas (no blank page) and opens it.
Future<void> openPdfIntoApp(
  BuildContext context,
  List<int> pdfBytes,
  String pdfName,
) async {
  final service = NotebookService();
  final label = await service.defaultTargetLabel();
  if (!context.mounted) return;

  final choice = await showDialog<_PdfDest>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text('Open "$pdfName"'),
      content: Text('Add it to "$label"?'),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, _PdfDest.cancel),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, _PdfDest.choose),
          child: const Text('Choose location…'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _PdfDest.here),
          child: const Text('Add here'),
        ),
      ],
    ),
  );
  if (choice == null || choice == _PdfDest.cancel || !context.mounted) return;

  Section? section;
  if (choice == _PdfDest.here) {
    section = (await service.resolveDefaultTarget()).section;
  } else {
    final dest = await pickSectionDestination(context, title: 'Add PDF to…');
    if (dest == null) return;
    section = await service.getSection(dest.notebookId, dest.sectionId);
  }
  if (section == null || !context.mounted) return;

  final progress = ProgressOverlay.show(context, 'Importing PDF…');
  final Canvas canvas;
  try {
    canvas = await service.createCanvasFromPdf(
      section,
      pdfName,
      pdfBytes,
      onProgress: progress.report,
    );
  } finally {
    progress.close();
  }
  if (!context.mounted) return;
  await Navigator.of(context).push(
    MaterialPageRoute(builder: (_) => CanvasScreen(canvas: canvas)),
  );
}
