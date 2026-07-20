import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import '../models/canvas.dart';
import '../models/section.dart';
import '../services/notebook_service.dart';
import '../widgets/action_sheet.dart';
import 'progress_overlay.dart';

/// What kind of canvas the "New canvas" sheet should create.
enum NewCanvasKind { empty, pdf }

/// Asks whether the new canvas should be an empty one or a PDF opened as a
/// canvas. Returns null if dismissed.
Future<NewCanvasKind?> pickNewCanvasKind(BuildContext context, {bool? desktop}) {
  return showAdaptiveMenu<NewCanvasKind>(
    context,
    desktop: desktop,
    builder: (context) => scrollableSheetBody(
      context,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 8),
          ListTile(
            leading: const Icon(Icons.note_add_outlined),
            title: const Text('Empty canvas'),
            subtitle: const Text('A blank page to draw and type on'),
            onTap: () => Navigator.pop(context, NewCanvasKind.empty),
          ),
          ListTile(
            leading: const Icon(Icons.picture_as_pdf_outlined),
            title: const Text('Open PDF'),
            subtitle: const Text('Import a PDF as an annotatable canvas'),
            onTap: () => Navigator.pop(context, NewCanvasKind.pdf),
          ),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );
}

/// Picks a PDF and creates a PDF-backed canvas (no blank starter page) in
/// [section]. Returns the new canvas, or null if the user cancelled the picker
/// (or no file came back). The canvas name is the PDF's file name (sans `.pdf`).
Future<Canvas?> pickAndCreatePdfCanvas(
  BuildContext context,
  Section section, {
  String? parentFolderId,
  String? afterCanvasId,
}) async {
  final result = await FilePicker.platform.pickFiles(
    type: FileType.custom,
    allowedExtensions: ['pdf'],
  );
  final picked = result?.files.single;
  final path = picked?.path;
  if (path == null) return null;
  final bytes = await File(path).readAsBytes();
  var name = picked!.name;
  if (name.toLowerCase().endsWith('.pdf')) {
    name = name.substring(0, name.length - 4);
  }
  if (!context.mounted) return null;
  final progress = ProgressOverlay.show(context, 'Opening PDF…');
  try {
    return await NotebookService().createCanvasFromPdf(
      section,
      name.isEmpty ? 'PDF' : name,
      bytes,
      parentFolderId: parentFolderId,
      afterCanvasId: afterCanvasId,
      onProgress: progress.report,
    );
  } finally {
    progress.close();
  }
}
