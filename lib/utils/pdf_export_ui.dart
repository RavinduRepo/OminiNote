import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import '../services/pdf_export_isolate.dart';
import '../services/pdf_exporter.dart';
import 'progress_overlay.dart';

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

  // Non-modal live progress: the PDF is built on a background isolate, so the
  // app stays usable while a big notebook/section exports.
  final banner = ProgressOverlay.show(
    context,
    'Exporting ${items.length} canvas${items.length == 1 ? '' : 'es'}…',
  );

  try {
    final bytes = await exportPdfInIsolate(
      items,
      onProgress: (fraction, label) => banner.report(fraction, label),
    );
    banner.close();
    if (!context.mounted) return;

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
    banner.close();
    messenger.showSnackBar(
      SnackBar(
        content: Text('Export failed: $err'),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }
}
