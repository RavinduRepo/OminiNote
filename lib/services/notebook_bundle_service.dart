import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
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
///
/// **Off the main isolate (perf 07/14/26):** the ZIP compress/decompress is
/// pure CPU that froze the UI on a large notebook. The bytes are gathered on
/// the main isolate (file reads are I/O), then `ZipEncoder`/`ZipDecoder` runs
/// via [Isolate.run] so the app stays responsive; `onProgress(fraction, label)`
/// reports the read/write phases (0..1). The zip step itself is opaque, so it's
/// reported as one "Compressing…"/"Reading…" span. Falls back to inline on any
/// isolate failure — a hiccup must never break export/import (same guard the
/// page-JSON offload uses in `NotebookService`).
class NotebookBundleService {
  final _service = NotebookService();

  static const kExtension = 'omninote';
  static const _kFormat = 'omininote-notebook';
  static const _kFormatVersion = 1;

  /// Zips [notebookId] into a `.omninote` bundle. Returns the bytes.
  Future<List<int>> exportBundle(
    String notebookId, {
    void Function(double fraction, String label)? onProgress,
  }) async {
    final nb = await _service.getNotebook(notebookId);
    if (nb == null) throw const BundleException('Notebook not found.');

    // Everything the archive will hold, gathered as plain bytes so the zip
    // step can run in a background isolate (nothing app-specific crosses).
    final files = <String, Uint8List>{
      'manifest.json': _jsonBytes({
        'format': _kFormat,
        'formatVersion': _kFormatVersion,
        'exportedAt': DateTime.now().toIso8601String(),
        'notebookName': nb.name,
      }),
      'index.json': _jsonBytes(nb.toJson()),
    };

    final dir = Directory('${_service.appDir.path}/notebooks/$notebookId');
    if (await dir.exists()) {
      final entries = <File>[];
      await for (final e in dir.list(recursive: true, followLinks: false)) {
        if (e is File) entries.add(e);
      }
      final basePrefix = '${dir.path}${Platform.pathSeparator}';
      for (var i = 0; i < entries.length; i++) {
        final e = entries[i];
        final rel = e.path.substring(basePrefix.length).replaceAll('\\', '/');
        files['data/$rel'] = Uint8List.fromList(await e.readAsBytes());
        onProgress?.call(
          0.05 + 0.75 * (i + 1) / entries.length,
          'Reading files…',
        );
      }
    }

    onProgress?.call(0.85, 'Compressing…');
    List<int> bytes;
    try {
      bytes = await Isolate.run(() => _zipEncode(files));
    } catch (_) {
      bytes = _zipEncode(files); // isolate hiccup — never fail the export
    }
    onProgress?.call(1.0, 'Done');
    return bytes;
  }

  /// Imports a `.omninote` bundle as a new notebook bound to [syncTarget]
  /// (null = local). Returns the new notebook.
  Future<Notebook?> importBundle(
    List<int> zipBytes, {
    String? syncTarget,
    void Function(double fraction, String label)? onProgress,
  }) async {
    onProgress?.call(0.1, 'Reading…');
    final bytes =
        zipBytes is Uint8List ? zipBytes : Uint8List.fromList(zipBytes);
    Map<String, Uint8List> files;
    try {
      try {
        files = await Isolate.run(() => _zipDecode(bytes));
      } catch (_) {
        files = _zipDecode(bytes); // isolate hiccup — decode inline
      }
    } catch (_) {
      throw const BundleException(
          'This file isn\'t a valid Omininote notebook.');
    }

    final manifest = _decodeJson(files['manifest.json']);
    if (manifest == null || manifest['format'] != _kFormat) {
      throw const BundleException('This file isn\'t an Omininote notebook.');
    }
    final index = _decodeJson(files['index.json']);
    if (index == null) {
      throw const BundleException('The notebook file is missing its index.');
    }

    // Write the data subtree under a fresh staging notebook id.
    final stagingId = _service.newId();
    final base = '${_service.appDir.path}/notebooks/$stagingId';
    final dataEntries =
        files.entries.where((e) => e.key.startsWith('data/')).toList();
    for (var i = 0; i < dataEntries.length; i++) {
      final rel = dataEntries[i].key.substring('data/'.length);
      if (rel.isEmpty || rel.contains('..')) continue; // zip-slip guard
      final out = File('$base/$rel');
      await out.parent.create(recursive: true);
      await out.writeAsBytes(dataEntries[i].value, flush: true);
      onProgress?.call(
        0.3 + 0.6 * (i + 1) / dataEntries.length,
        'Installing…',
      );
    }

    onProgress?.call(1.0, 'Done');
    return _service.installImportedNotebook(stagingId, index,
        syncTarget: syncTarget);
  }

  static Uint8List _jsonBytes(Object json) =>
      Uint8List.fromList(utf8.encode(jsonEncode(json)));

  static Map<String, dynamic>? _decodeJson(Uint8List? bytes) {
    if (bytes == null) return null;
    try {
      return jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }
}

// ── Isolate compute (top-level so the Isolate.run closure can't capture the
//    service `this`; pure CPU, no app state) ──────────────────────────────────

/// Builds and deflates a ZIP from [files] (`name -> bytes`). Runs in a
/// background isolate via [Isolate.run].
Uint8List _zipEncode(Map<String, Uint8List> files) {
  final archive = Archive();
  files.forEach(
    (name, data) => archive.addFile(ArchiveFile(name, data.length, data)),
  );
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

/// Inflates a ZIP into `name -> bytes` for every file entry. Runs in a
/// background isolate via [Isolate.run].
Map<String, Uint8List> _zipDecode(Uint8List bytes) {
  final archive = ZipDecoder().decodeBytes(bytes);
  final out = <String, Uint8List>{};
  for (final f in archive.files) {
    if (f.isFile) out[f.name] = Uint8List.fromList(f.content as List<int>);
  }
  return out;
}

class BundleException implements Exception {
  final String message;
  const BundleException(this.message);
  @override
  String toString() => message;
}
