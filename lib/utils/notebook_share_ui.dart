import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';
import 'package:path_provider/path_provider.dart';
import '../models/notebook.dart';
import '../services/notebook_bundle_service.dart';
import '../services/notebook_service.dart';
import '../services/sync_service.dart';
import 'sync_target_ui.dart';

final _bundle = NotebookBundleService();

bool get _isMobile => Platform.isAndroid || Platform.isIOS;

String _bundleFileName(String notebookName) {
  final safe = notebookName.replaceAll(RegExp(r'[^\w\s-]'), '').trim();
  return '${safe.isEmpty ? 'notebook' : safe}.${NotebookBundleService.kExtension}';
}

/// Exports [notebook] to a `.omninote` file and shares it: the native share
/// sheet on mobile, a save-file dialog on desktop.
Future<void> shareNotebookCopy(BuildContext context, Notebook notebook) async {
  final messenger = ScaffoldMessenger.of(context);
  try {
    final bytes = await _bundle.exportBundle(notebook.id);
    final fileName = _bundleFileName(notebook.name);

    if (_isMobile) {
      final dir = await getTemporaryDirectory();
      final path = '${dir.path}/$fileName';
      await File(path).writeAsBytes(bytes, flush: true);
      await SharePlus.instance.share(
        ShareParams(files: [XFile(path)], subject: notebook.name),
      );
    } else {
      final saved = await FilePicker.platform.saveFile(
        dialogTitle: 'Save notebook copy',
        fileName: fileName,
      );
      if (saved == null) return; // cancelled
      final ext = '.${NotebookBundleService.kExtension}';
      final out = saved.endsWith(ext) ? saved : '$saved$ext';
      await File(out).writeAsBytes(bytes, flush: true);
      messenger.showSnackBar(SnackBar(
        content: Text('Saved ${out.split(Platform.pathSeparator).last}'),
        behavior: SnackBarBehavior.floating,
      ));
    }
  } catch (e) {
    messenger.showSnackBar(SnackBar(
      content: Text('Couldn\'t export: $e'),
      behavior: SnackBarBehavior.floating,
    ));
  }
}

/// Picks a `.omninote` file, asks which account to sync it to, and imports it as
/// a new notebook (fresh ids). Returns the imported notebook, or null if
/// cancelled/failed.
Future<Notebook?> importNotebookCopy(BuildContext context) async {
  // On Android a custom/unknown extension (.omninote) has no MIME mapping, so
  // the system picker greys the file out and it can't be selected. Show all
  // files there and let importBundle validate the manifest; keep the tidy
  // extension filter on desktop, where pickers filter by extension directly.
  final picked = await FilePicker.platform.pickFiles(
    dialogTitle: 'Import notebook',
    type: _isMobile ? FileType.any : FileType.custom,
    allowedExtensions:
        _isMobile ? null : const [NotebookBundleService.kExtension],
    withData: true,
  );
  if (picked == null || picked.files.isEmpty) return null;
  final f = picked.files.first;
  final bytes = f.bytes ??
      (f.path != null ? await File(f.path!).readAsBytes() : null);
  if (bytes == null) return null;

  if (!context.mounted) return null;
  return importBundleBytes(context, bytes);
}

/// Imports already-loaded bundle [bytes] as a new notebook: asks which account,
/// installs it (fresh ids), kicks its upload, and refreshes open lists. Shared
/// by the file-picker import and the "open a .omninote file with the app" path.
Future<Notebook?> importBundleBytes(
    BuildContext context, List<int> bytes) async {
  final target = await chooseNewNotebookAccount(context);
  if (target == null || !context.mounted) return null; // cancelled

  final messenger = ScaffoldMessenger.of(context);
  try {
    final nb = await _bundle.importBundle(bytes, syncTarget: target.accountId);
    if (nb == null) return null;
    if (target.localOnly) {
      await NotebookService().setNotebookLocalOnly(nb.id, true);
    } else {
      await SyncService().uploadNotebook(nb.id);
    }
    SyncService().notifyDataChanged(); // reload any open list screen
    messenger.showSnackBar(SnackBar(
      content: Text('Imported “${nb.name}”'),
      behavior: SnackBarBehavior.floating,
    ));
    return nb;
  } catch (e) {
    messenger.showSnackBar(SnackBar(
      content: Text('Couldn\'t import: $e'),
      behavior: SnackBarBehavior.floating,
    ));
    return null;
  }
}
