import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'package:archive/archive_io.dart';
import 'package:path_provider/path_provider.dart';
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

  /// Zips [notebookId] into a `.omninote` bundle **streamed to a temp file**,
  /// and returns its path. Memory-safe (the OOM fix): the source files are read
  /// from disk and the zip is written to disk **one entry at a time** via
  /// [ZipFileEncoder], so a gigabyte notebook never sits fully in RAM (and
  /// nothing large is copied across the isolate boundary — only file *paths*
  /// cross it). **The caller owns the returned file — delete it when done.**
  Future<String> exportBundle(
    String notebookId, {
    void Function(double fraction, String label)? onProgress,
  }) async {
    final nb = await _service.getNotebook(notebookId);
    if (nb == null) throw const BundleException('Notebook not found.');
    onProgress?.call(0.02, 'Preparing…');

    // Flat [sourcePath, archiveName, sourcePath, archiveName, …] — paths only,
    // no bytes held/copied (a flat String list crosses the isolate cleanly).
    final entries = <String>[];
    final dir = Directory('${_service.appDir.path}/notebooks/$notebookId');
    if (await dir.exists()) {
      final basePrefix = '${dir.path}${Platform.pathSeparator}';
      await for (final e in dir.list(recursive: true, followLinks: false)) {
        if (e is File) {
          final rel = e.path.substring(basePrefix.length).replaceAll('\\', '/');
          entries..add(e.path)..add('data/$rel');
        }
      }
    }
    final manifest = _jsonBytes({
      'format': _kFormat,
      'formatVersion': _kFormatVersion,
      'exportedAt': DateTime.now().toIso8601String(),
      'notebookName': nb.name,
    });
    final index = _jsonBytes(nb.toJson());

    final tmp = await getTemporaryDirectory();
    final outPath =
        '${tmp.path}/omninote_export_${DateTime.now().microsecondsSinceEpoch}.$kExtension';

    await _streamZipToFile(
      entries,
      manifest,
      index,
      outPath,
      (done, total) => onProgress?.call(
        0.05 + 0.9 * (total == 0 ? 1.0 : done / total),
        'Compressing…',
      ),
    );
    onProgress?.call(1.0, 'Done');
    return outPath;
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

// ── Isolate compute (top-level so the isolate closures can't capture the
//    service `this`; pure CPU + disk I/O, no app state) ──────────────────────

/// Stream-zips [entries] (`[sourcePath, archiveName]`) + the in-memory
/// [manifest]/[index] into [outPath], reporting `onFile(done,total)` per entry.
/// Runs the encode in a spawned isolate (only paths + the two small JSON blobs
/// cross the boundary), falling back to inline on any isolate failure — a
/// hiccup must never fail the export.
Future<void> _streamZipToFile(
  List<String> entries,
  Uint8List manifest,
  Uint8List index,
  String outPath,
  void Function(int done, int total) onFile,
) async {
  final rp = ReceivePort();
  Isolate iso;
  try {
    iso = await Isolate.spawn(
      _zipStreamEntry, [rp.sendPort, entries, manifest, index, outPath]);
  } catch (_) {
    rp.close();
    return _zipStreamSync(entries, manifest, index, outPath, onFile);
  }
  final completer = Completer<void>();
  rp.listen((msg) {
    final m = msg as Map;
    if (m.containsKey('done')) {
      onFile(m['done'] as int, m['total'] as int);
    } else if (m['result'] == true) {
      if (!completer.isCompleted) completer.complete();
      rp.close();
    } else if (m.containsKey('error')) {
      if (!completer.isCompleted) {
        completer.completeError(Exception(m['error'] as String));
      }
      rp.close();
    }
  });
  try {
    await completer.future;
  } catch (_) {
    await _zipStreamSync(entries, manifest, index, outPath, onFile);
  } finally {
    iso.kill(priority: Isolate.immediate);
  }
}

/// Isolate entry for [_streamZipToFile]: `[SendPort, entries, manifest, index,
/// outPath]`. Streams the zip, forwarding per-entry progress, then signals done.
Future<void> _zipStreamEntry(List<Object> args) async {
  final reply = args[0] as SendPort;
  final entries = (args[1] as List).cast<String>();
  final manifest = args[2] as Uint8List;
  final index = args[3] as Uint8List;
  final outPath = args[4] as String;
  try {
    await _zipStreamSync(entries, manifest, index, outPath,
        (done, total) => reply.send({'done': done, 'total': total}));
    reply.send({'result': true});
  } catch (e) {
    reply.send({'error': '$e'});
  }
}

/// Writes the zip at [outPath] one entry at a time via [ZipFileEncoder]
/// (`addFile` streams each source from disk through an `InputFileStream`), so
/// nothing large is buffered. The two small JSON blobs go in as archive files.
Future<void> _zipStreamSync(
  List<String> entries,
  Uint8List manifest,
  Uint8List index,
  String outPath,
  void Function(int done, int total) onFile,
) async {
  final enc = ZipFileEncoder();
  enc.create(outPath);
  enc.addArchiveFile(ArchiveFile('manifest.json', manifest.length, manifest));
  enc.addArchiveFile(ArchiveFile('index.json', index.length, index));
  final total = entries.length ~/ 2 + 2;
  var done = 2;
  onFile(done, total);
  for (var i = 0; i + 1 < entries.length; i += 2) {
    await enc.addFile(File(entries[i]), entries[i + 1]);
    onFile(++done, total);
  }
  enc.closeSync();
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
