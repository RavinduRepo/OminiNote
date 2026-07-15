import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'package:archive/archive_io.dart';
import 'package:flutter/foundation.dart';
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
/// **Off the main isolate + streamed to/from disk (perf + OOM fix):** the ZIP
/// compress/decompress is pure CPU that froze the UI on a large notebook, and
/// buffering the whole (de)compressed tree in RAM OOM'd big bundles on Android.
/// Both directions now stream **one entry at a time between disk and a spawned
/// isolate** — export via [ZipFileEncoder] ([exportBundle], returns a temp-file
/// path), import via `InputFileStream`→`OutputFileStream` straight into the
/// staging dir ([importBundleFile]) — so only file *paths* and the tiny
/// manifest/index blobs cross the isolate boundary, never the bulk data.
/// `onProgress(fraction, label)` reports the read/write phases (0..1). Export
/// falls back to inline on any isolate failure; import falls back inline only if
/// the isolate can't be *spawned* (nothing written yet) — a running isolate's
/// error is a real failure, reported and not retried.
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

  /// Imports the `.omninote` bundle **at [zipPath]** as a new notebook bound to
  /// [syncTarget] (null = local). Returns the new notebook.
  ///
  /// Memory-safe (the OOM fix, symmetric to [exportBundle]): the zip is inflated
  /// **one entry at a time straight to disk** inside an isolate — each data entry
  /// is streamed (`InputFileStream`→`OutputFileStream`) into the staging notebook
  /// dir, so a gigabyte bundle never sits fully in RAM, and only the tiny
  /// `index.json` bytes cross the isolate boundary. Manifest/index are validated
  /// from the central directory **before** any data entry is written, so a bad
  /// file leaves nothing on disk. On any mid-extraction failure the partial
  /// staging dir is removed. Falls back to inline extraction only if the isolate
  /// can't be spawned (nothing written yet) — a running isolate's error is a
  /// genuine failure and is not retried (it may have written partial data).
  Future<Notebook?> importBundleFile(
    String zipPath, {
    String? syncTarget,
    void Function(double fraction, String label)? onProgress,
  }) async {
    onProgress?.call(0.05, 'Reading…');
    final stagingId = _service.newId();
    final base = '${_service.appDir.path}/notebooks/$stagingId';

    Uint8List indexBytes;
    try {
      indexBytes = await _streamUnzipToStaging(
        zipPath,
        base,
        _kFormat,
        (done, total) => onProgress?.call(
          0.1 + 0.85 * (total == 0 ? 1.0 : done / total),
          'Installing…',
        ),
      );
    } on BundleException {
      await _bestEffortDeleteDir(base);
      rethrow;
    } catch (_) {
      await _bestEffortDeleteDir(base);
      throw const BundleException(
          'This file isn\'t a valid Omininote notebook.');
    }

    final index = _decodeJson(indexBytes);
    if (index == null) {
      await _bestEffortDeleteDir(base);
      throw const BundleException('The notebook file is missing its index.');
    }

    onProgress?.call(1.0, 'Done');
    return _service.installImportedNotebook(stagingId, index,
        syncTarget: syncTarget);
  }

  /// Imports an in-memory bundle. Kept for byte sources that can't hand us a
  /// path (a downloaded share-link body): writes the bytes to a temp file so the
  /// extraction still streams from disk, imports it, then cleans up. Prefer
  /// [importBundleFile] whenever a file path is available (file-picker / open-with)
  /// — it never holds the whole bundle in RAM.
  Future<Notebook?> importBundle(
    List<int> zipBytes, {
    String? syncTarget,
    void Function(double fraction, String label)? onProgress,
  }) async {
    final tmp = await getTemporaryDirectory();
    final path =
        '${tmp.path}/omninote_import_${DateTime.now().microsecondsSinceEpoch}.$kExtension';
    final f = File(path);
    await f.writeAsBytes(zipBytes, flush: true);
    try {
      return await importBundleFile(path,
          syncTarget: syncTarget, onProgress: onProgress);
    } finally {
      try {
        await f.delete();
      } catch (_) {}
    }
  }

  static Future<void> _bestEffortDeleteDir(String path) async {
    try {
      final dir = Directory(path);
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (_) {}
  }

  /// Test seam: run the streaming extraction inline (no isolate) so a unit test
  /// can round-trip a zip built with [ZipFileEncoder] against
  /// [Directory.systemTemp] without a `path_provider` stub. Returns the
  /// extracted `index.json` bytes.
  @visibleForTesting
  static Uint8List debugStreamUnzip(String zipPath, String stagingBase) =>
      _unzipStreamSync(zipPath, stagingBase, _kFormat, (_, _) {});

  static Uint8List _jsonBytes(Object json) =>
      Uint8List.fromList(utf8.encode(jsonEncode(json)));
}

// ── Isolate compute (top-level so the isolate closures can't capture the
//    service `this`; pure CPU + disk I/O, no app state) ──────────────────────

/// Decodes UTF-8 JSON bytes into a map, or null if absent/malformed. Top-level
/// so the isolate extraction worker can reach it too.
Map<String, dynamic>? _decodeJson(Uint8List? bytes) {
  if (bytes == null) return null;
  try {
    return jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
  } catch (_) {
    return null;
  }
}

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

/// Streams the zip at [zipPath] into the staging dir [stagingBase], validating
/// the manifest/index first, then extracting each `data/…` entry to disk one at
/// a time. Returns the `index.json` bytes over the [SendPort]; reports
/// `{done,total}` per data entry and `{error}` on failure. Runs the extraction
/// in a spawned isolate (only paths + the tiny index cross the boundary), so a
/// large import never buffers the whole tree in RAM. On spawn failure it runs
/// inline (nothing written yet); a running isolate's failure is reported as an
/// error and **not** retried inline (it may have written partial data — the
/// caller cleans up the staging dir).
Future<Uint8List> _streamUnzipToStaging(
  String zipPath,
  String stagingBase,
  String expectedFormat,
  void Function(int done, int total) onFile,
) async {
  final rp = ReceivePort();
  Isolate iso;
  try {
    iso = await Isolate.spawn(
        _unzipStreamEntry, [rp.sendPort, zipPath, stagingBase, expectedFormat]);
  } catch (_) {
    rp.close();
    return _unzipStreamSync(zipPath, stagingBase, expectedFormat, onFile);
  }
  final completer = Completer<Uint8List>();
  rp.listen((msg) {
    final m = msg as Map;
    if (m.containsKey('done')) {
      onFile(m['done'] as int, m['total'] as int);
    } else if (m.containsKey('index')) {
      if (!completer.isCompleted) completer.complete(m['index'] as Uint8List);
      rp.close();
    } else if (m.containsKey('error')) {
      if (!completer.isCompleted) {
        completer.completeError(BundleException(m['error'] as String));
      }
      rp.close();
    }
  });
  try {
    return await completer.future;
  } finally {
    iso.kill(priority: Isolate.immediate);
  }
}

/// Isolate entry for [_streamUnzipToStaging]: `[SendPort, zipPath, stagingBase,
/// expectedFormat]`. Streams the extraction, forwarding per-entry progress, then
/// sends the index bytes (or an error). Cleans up its own partial writes on
/// failure so a retry/caller never sees a half-written staging dir it didn't
/// expect.
void _unzipStreamEntry(List<Object> args) {
  final reply = args[0] as SendPort;
  final zipPath = args[1] as String;
  final stagingBase = args[2] as String;
  final expectedFormat = args[3] as String;
  try {
    final index = _unzipStreamSync(zipPath, stagingBase, expectedFormat,
        (done, total) => reply.send({'done': done, 'total': total}));
    reply.send({'index': index});
  } catch (e) {
    try {
      final dir = Directory(stagingBase);
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    } catch (_) {}
    reply.send({'error': e is BundleException ? e.message : '$e'});
  }
}

/// Inflates the zip at [zipPath] into [stagingBase], streaming each `data/…`
/// entry through `OutputFileStream` so nothing large is buffered. Manifest +
/// index are read from the central directory and validated **before** any data
/// entry is written. Throws [BundleException] on an invalid/corrupt bundle.
/// Returns the extracted `index.json` bytes.
Uint8List _unzipStreamSync(
  String zipPath,
  String stagingBase,
  String expectedFormat,
  void Function(int done, int total) onFile,
) {
  final input = InputFileStream(zipPath);
  try {
    final Archive archive;
    try {
      archive = ZipDecoder().decodeStream(input);
    } catch (_) {
      throw const BundleException(
          'This file isn\'t a valid Omininote notebook.');
    }

    // Validate manifest + read index up front — nothing is written to disk
    // unless the bundle is genuinely one of ours.
    final manifestFile = archive.findFile('manifest.json');
    final indexFile = archive.findFile('index.json');
    if (manifestFile == null || indexFile == null) {
      throw const BundleException('This file isn\'t an Omininote notebook.');
    }
    final manifest = _decodeJson(manifestFile.readBytes());
    if (manifest == null || manifest['format'] != expectedFormat) {
      throw const BundleException('This file isn\'t an Omininote notebook.');
    }
    final indexBytes = indexFile.readBytes();
    if (indexBytes == null || _decodeJson(indexBytes) == null) {
      throw const BundleException('The notebook file is missing its index.');
    }

    final sep = Platform.pathSeparator;
    final dataEntries = archive.files
        .where((f) => f.isFile && f.name.startsWith('data/'))
        .toList();
    final total = dataEntries.length;
    var done = 0;
    onFile(done, total);
    for (final entry in dataEntries) {
      final rel = entry.name.substring('data/'.length);
      if (rel.isEmpty || rel.contains('..')) {
        onFile(++done, total); // zip-slip guard — skip
        continue;
      }
      final outPath = '$stagingBase$sep${rel.replaceAll('/', sep)}';
      final outFile = File(outPath);
      outFile.parent.createSync(recursive: true);
      final out = OutputFileStream(outPath);
      try {
        entry.writeContent(out);
      } finally {
        out.closeSync();
      }
      onFile(++done, total);
    }
    return indexBytes;
  } finally {
    input.closeSync();
  }
}

class BundleException implements Exception {
  final String message;
  const BundleException(this.message);
  @override
  String toString() => message;
}
