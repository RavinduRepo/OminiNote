import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:share_plus/share_plus.dart';
import 'package:path_provider/path_provider.dart';
import '../models/notebook.dart';
import '../services/auth_service.dart';
import '../services/drive_service.dart';
import '../services/notebook_bundle_service.dart';
import '../services/notebook_service.dart';
import '../services/sync_service.dart';
import 'progress_overlay.dart';
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
  // Non-modal progress: the compress runs on a background isolate, so the app
  // stays usable while a big notebook exports.
  final banner = ProgressOverlay.show(context, 'Exporting “${notebook.name}”…');
  try {
    // Streamed to a temp file (memory-safe) — we move/copy the file itself
    // rather than ever holding the whole bundle in memory.
    final zipPath =
        await _bundle.exportBundle(notebook.id, onProgress: banner.report);
    banner.close();
    final fileName = _bundleFileName(notebook.name);
    final zipFile = File(zipPath);

    if (_isMobile) {
      // Rename to a friendly name in-place, then hand the file to the share
      // sheet (left in temp for the sheet to read; the OS cleans temp).
      final named = '${(await getTemporaryDirectory()).path}/$fileName';
      final shareFile = named == zipPath ? zipFile : await zipFile.rename(named);
      await SharePlus.instance.share(
        ShareParams(files: [XFile(shareFile.path)], subject: notebook.name),
      );
    } else {
      final saved = await FilePicker.platform.saveFile(
        dialogTitle: 'Save notebook copy',
        fileName: fileName,
      );
      if (saved != null) {
        final ext = '.${NotebookBundleService.kExtension}';
        final out = saved.endsWith(ext) ? saved : '$saved$ext';
        await zipFile.copy(out); // copy the file, no bytes in memory
        messenger.showSnackBar(SnackBar(
          content: Text('Saved ${out.split(Platform.pathSeparator).last}'),
          behavior: SnackBarBehavior.floating,
        ));
      }
      if (await zipFile.exists()) {
        try {
          await zipFile.delete();
        } catch (_) {}
      }
    }
  } catch (e) {
    banner.close();
    messenger.showSnackBar(SnackBar(
      content: Text('Couldn\'t export: $e'),
      behavior: SnackBarBehavior.floating,
    ));
  }
}

/// Shares a notebook as an `omninote://` **link**: hosts the bundle on a
/// connected account's Drive ("anyone with the link"), then shares
/// `omninote://import?id=<fileId>`. Needs a signed-in account (falls back to a
/// hint to use "Send a copy" otherwise). It's a copy at share time — later edits
/// don't change what the link delivers.
Future<void> shareNotebookLink(BuildContext context, Notebook notebook) async {
  final messenger = ScaffoldMessenger.of(context);
  final accounts = AuthService().accounts.value;
  if (accounts.isEmpty) {
    messenger.showSnackBar(const SnackBar(
      content: Text('Sign in to share a link — or use “Send a copy”.'),
      behavior: SnackBarBehavior.floating,
    ));
    return;
  }
  // Host it on the notebook's own account if connected, else the first account.
  final target = notebook.syncTarget ?? AuthService().defaultAccountId;
  final accountId = (target != null && accounts.any((a) => a.id == target))
      ? target
      : accounts.first.id;

  _showProgress(context, 'Creating link…');
  try {
    // Streamed to a temp file; read it back only for the upload, then clean up.
    final zipPath = await _bundle.exportBundle(notebook.id);
    final zipFile = File(zipPath);
    final bytes = await zipFile.readAsBytes();
    final fileId = await DriveManager.forAccount(accountId)
        .uploadSharedBundle(_bundleFileName(notebook.name), bytes);
    if (await zipFile.exists()) {
      try {
        await zipFile.delete();
      } catch (_) {}
    }
    if (context.mounted) Navigator.of(context, rootNavigator: true).pop();
    if (fileId == null) {
      messenger.showSnackBar(const SnackBar(
        content: Text('Couldn\'t create the link.'),
        behavior: SnackBarBehavior.floating,
      ));
      return;
    }
    await SharePlus.instance.share(ShareParams(
      text: 'omninote://import?id=$fileId',
      subject: notebook.name,
    ));
  } catch (e) {
    if (context.mounted) Navigator.of(context, rootNavigator: true).pop();
    messenger.showSnackBar(SnackBar(
      content: Text('Couldn\'t create the link: $e'),
      behavior: SnackBarBehavior.floating,
    ));
  }
}

/// Handles a tapped `omninote://import?id=…` link: downloads the public bundle
/// over HTTPS and imports it (account picker). Returns the imported notebook.
Future<Notebook?> importNotebookFromLink(BuildContext context, Uri uri) async {
  final id = uri.queryParameters['id'];
  if (id == null || id.isEmpty) return null;
  final messenger = ScaffoldMessenger.of(context);

  _showProgress(context, 'Downloading notebook…');
  List<int>? bytes;
  try {
    final resp = await http.get(Uri.parse(
        'https://drive.usercontent.google.com/download?id=$id&export=download&confirm=t'));
    if (resp.statusCode == 200) bytes = resp.bodyBytes;
  } catch (_) {}
  if (context.mounted) Navigator.of(context, rootNavigator: true).pop();

  if (bytes == null) {
    messenger.showSnackBar(const SnackBar(
      content: Text('Couldn\'t download the shared notebook.'),
      behavior: SnackBarBehavior.floating,
    ));
    return null;
  }
  if (!context.mounted) return null;
  return importBundleBytes(context, bytes);
}

void _showProgress(BuildContext context, String label) {
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (context) => AlertDialog(
      content: Row(children: [
        const SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(strokeWidth: 2.5)),
        const SizedBox(width: 18),
        Expanded(child: Text(label, style: const TextStyle(fontSize: 13))),
      ]),
    ),
  );
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
  final banner = ProgressOverlay.show(context, 'Importing notebook…');
  try {
    final nb = await _bundle.importBundle(
      bytes,
      syncTarget: target.accountId,
      onProgress: banner.report,
    );
    banner.close();
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
    banner.close();
    messenger.showSnackBar(SnackBar(
      content: Text('Couldn\'t import: $e'),
      behavior: SnackBarBehavior.floating,
    ));
    return null;
  }
}
