import 'dart:convert';
import 'dart:io';
import 'package:archive/archive.dart';
import '../models/notebook.dart';
import 'notebook_service.dart';

/// Reads/writes `.omninote` notebook bundles for "send a copy" sharing (Phase 3
/// v1). A bundle is a ZIP with:
///   * `manifest.json` — format id + version + metadata,
///   * `index.json`    — the notebook's index (`notebooks.json`) entry,
///   * `data/…`        — the notebook's whole on-disk file subtree
///     (`sections/…/section.json`, `canvases/…/canvas.json`, `pages/*.json`,
///     `assets/*`).
///
/// Import unzips to a staging id, then deep-re-ids into a fresh notebook (new
/// notebook/section/canvas ids) so imports never collide and re-importing makes
/// an independent copy — see [NotebookService.installImportedNotebook].
class NotebookBundleService {
  final _service = NotebookService();

  static const kExtension = 'omninote';
  static const _kFormat = 'omininote-notebook';
  static const _kFormatVersion = 1;

  /// Zips [notebookId] into a `.omninote` bundle. Returns the bytes.
  Future<List<int>> exportBundle(String notebookId) async {
    final nb = await _service.getNotebook(notebookId);
    if (nb == null) throw const BundleException('Notebook not found.');

    final archive = Archive();
    archive.addFile(_jsonEntry('manifest.json', {
      'format': _kFormat,
      'formatVersion': _kFormatVersion,
      'exportedAt': DateTime.now().toIso8601String(),
      'notebookName': nb.name,
    }));
    archive.addFile(_jsonEntry('index.json', nb.toJson()));

    final dir = Directory('${_service.appDir.path}/notebooks/$notebookId');
    if (await dir.exists()) {
      final basePrefix = '${dir.path}${Platform.pathSeparator}';
      await for (final e in dir.list(recursive: true, followLinks: false)) {
        if (e is! File) continue;
        final rel =
            e.path.substring(basePrefix.length).replaceAll('\\', '/');
        final bytes = await e.readAsBytes();
        archive.addFile(ArchiveFile('data/$rel', bytes.length, bytes));
      }
    }
    return ZipEncoder().encode(archive);
  }

  /// Imports a `.omninote` bundle as a new notebook bound to [syncTarget]
  /// (null = local). Returns the new notebook.
  Future<Notebook?> importBundle(List<int> zipBytes, {String? syncTarget}) async {
    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(zipBytes);
    } catch (_) {
      throw const BundleException(
          'This file isn\'t a valid Omininote notebook.');
    }
    final manifest = _readJson(archive, 'manifest.json');
    if (manifest == null || manifest['format'] != _kFormat) {
      throw const BundleException('This file isn\'t an Omininote notebook.');
    }
    final index = _readJson(archive, 'index.json');
    if (index == null) {
      throw const BundleException('The notebook file is missing its index.');
    }

    // Unzip the data subtree under a fresh staging notebook id.
    final stagingId = _service.newId();
    final base = '${_service.appDir.path}/notebooks/$stagingId';
    for (final f in archive.files) {
      if (!f.isFile || !f.name.startsWith('data/')) continue;
      final rel = f.name.substring('data/'.length);
      if (rel.isEmpty || rel.contains('..')) continue; // zip-slip guard
      final out = File('$base/$rel');
      await out.parent.create(recursive: true);
      await out.writeAsBytes(f.content as List<int>, flush: true);
    }

    return _service.installImportedNotebook(stagingId, index,
        syncTarget: syncTarget);
  }

  ArchiveFile _jsonEntry(String name, Object json) {
    final bytes = utf8.encode(jsonEncode(json));
    return ArchiveFile(name, bytes.length, bytes);
  }

  Map<String, dynamic>? _readJson(Archive archive, String name) {
    try {
      final f = archive.files.firstWhere((e) => e.name == name);
      return jsonDecode(utf8.decode(f.content as List<int>))
          as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }
}

class BundleException implements Exception {
  final String message;
  const BundleException(this.message);
  @override
  String toString() => message;
}
