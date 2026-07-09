import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import '../services/pdf_exporter.dart';

/// Runs a multi-level PDF export ([items]) with a progress dialog and a save
/// dialog, mirroring the per-canvas export flow in `canvas_screen`. Shared by
/// the notebook and section "Export to PDF" actions.
Future<void> runTreeExport(
  BuildContext context, {
  required List<PdfExportItem> items,
  required String fileName,
}) async {
  final messenger = ScaffoldMessenger.of(context);
  if (items.isEmpty) {
    messenger.showSnackBar(
      const SnackBar(
        content: Text('Nothing to export'),
        behavior: SnackBarBehavior.floating,
      ),
    );
    return;
  }

  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (context) => AlertDialog(
      content: Row(
        children: [
          const CircularProgressIndicator(),
          const SizedBox(width: 20),
          Text('Exporting ${items.length} '
              'canvas${items.length == 1 ? '' : 'es'}…'),
        ],
      ),
    ),
  );

  try {
    final bytes = await SyncfusionPdfExporter().exportTree(items);
    if (!context.mounted) return;
    Navigator.pop(context); // progress dialog

    final safe = fileName.replaceAll(RegExp(r'[<>:"/\\|?*]'), '_');
    final savedPath = await FilePicker.platform.saveFile(
      dialogTitle: 'Save PDF',
      fileName: '$safe.pdf',
      type: FileType.custom,
      allowedExtensions: ['pdf'],
      bytes: bytes,
    );
    if (savedPath == null) return; // cancelled

    // Desktop pickers return a path without writing the bytes.
    final f = File(savedPath);
    if (!await f.exists() || await f.length() == 0) {
      await f.writeAsBytes(bytes);
    }
    messenger.showSnackBar(
      SnackBar(
        content: Text('Exported to $savedPath'),
        behavior: SnackBarBehavior.floating,
      ),
    );
  } catch (err) {
    if (context.mounted && Navigator.canPop(context)) Navigator.pop(context);
    messenger.showSnackBar(
      SnackBar(
        content: Text('Export failed: $err'),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }
}
