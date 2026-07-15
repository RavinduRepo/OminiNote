import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:archive/archive_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omininote/services/notebook_bundle_service.dart';

/// Round-trips the **streaming** `.omninote` import (the OOM fix): a zip built
/// exactly like [NotebookBundleService.exportBundle] writes it (manifest.json +
/// index.json + a `data/…` subtree) is extracted straight to a staging dir via
/// [NotebookBundleService.debugStreamUnzip], and we assert every entry lands
/// byte-for-byte and the returned index bytes match. Also checks the up-front
/// validation (bad manifest / missing index writes nothing) and the zip-slip
/// guard. Uses [Directory.systemTemp] so no `path_provider` stub is needed.
void main() {
  const format = 'omininote-notebook';

  late Directory tmp;
  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('omninote_import_test');
  });
  tearDown(() async {
    try {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    } catch (_) {} // best-effort on Windows (transient handle locks)
  });

  Uint8List jsonBytes(Object o) => Uint8List.fromList(utf8.encode(jsonEncode(o)));

  /// Builds a `.omninote`-shaped zip at [zipPath] holding [data] (relative path
  /// under `data/` → bytes) plus the manifest/index blobs, streamed to disk the
  /// same way the exporter does.
  String buildZip(
    String zipPath, {
    required Uint8List manifest,
    required Uint8List index,
    required Map<String, List<int>> data,
  }) {
    final enc = ZipFileEncoder();
    enc.create(zipPath);
    enc.addArchiveFile(ArchiveFile('manifest.json', manifest.length, manifest));
    enc.addArchiveFile(ArchiveFile('index.json', index.length, index));
    data.forEach((rel, bytes) {
      enc.addArchiveFile(ArchiveFile('data/$rel', bytes.length, bytes));
    });
    enc.closeSync();
    return zipPath;
  }

  test('extracts every entry losslessly and returns the index', () {
    final index = jsonBytes({'name': 'My Notebook', 'nodes': []});
    final big = Uint8List.fromList(List.generate(200000, (i) => i % 256));
    final data = <String, List<int>>{
      'sections/s1/section.json': utf8.encode('{"id":"s1"}'),
      'sections/s1/canvases/c1/canvas.json': utf8.encode('{"id":"c1"}'),
      'sections/s1/canvases/c1/pages/p1.json': utf8.encode('{"id":"p1"}'),
      'sections/s1/canvases/c1/assets/abc.png': big,
    };
    final zip = buildZip('${tmp.path}/bundle.omninote',
        manifest: jsonBytes({'format': format, 'formatVersion': 1}),
        index: index,
        data: data);

    final staging = '${tmp.path}/staging';
    final returnedIndex =
        NotebookBundleService.debugStreamUnzip(zip, staging);

    expect(returnedIndex, equals(index));
    data.forEach((rel, bytes) {
      final f = File('$staging/$rel');
      expect(f.existsSync(), isTrue, reason: 'missing $rel');
      expect(f.readAsBytesSync(), equals(bytes), reason: 'corrupt $rel');
    });
    // Manifest/index are metadata — they are NOT written into the data subtree.
    expect(File('$staging/manifest.json').existsSync(), isFalse);
  });

  test('rejects a non-Omininote zip and writes nothing', () {
    final zip = buildZip('${tmp.path}/bad.omninote',
        manifest: jsonBytes({'format': 'something-else'}),
        index: jsonBytes({'name': 'x'}),
        data: {'sections/s1/section.json': utf8.encode('{}')});

    final staging = '${tmp.path}/staging';
    expect(
      () => NotebookBundleService.debugStreamUnzip(zip, staging),
      throwsA(isA<BundleException>()),
    );
    expect(Directory(staging).existsSync(), isFalse);
  });

  test('rejects a corrupt/non-zip file', () {
    final zip = File('${tmp.path}/garbage.omninote')
      ..writeAsBytesSync(utf8.encode('not a zip at all'));
    expect(
      () => NotebookBundleService.debugStreamUnzip(zip.path, '${tmp.path}/st'),
      throwsA(isA<BundleException>()),
    );
  });

  test('skips zip-slip (..) entries', () {
    // Hand-craft an archive whose data entry tries to escape the staging dir.
    final enc = ZipFileEncoder();
    final zipPath = '${tmp.path}/slip.omninote';
    enc.create(zipPath);
    final manifest = jsonBytes({'format': format});
    final index = jsonBytes({'name': 'x', 'nodes': []});
    enc.addArchiveFile(ArchiveFile('manifest.json', manifest.length, manifest));
    enc.addArchiveFile(ArchiveFile('index.json', index.length, index));
    final evil = utf8.encode('pwned');
    enc.addArchiveFile(
        ArchiveFile('data/../escaped.json', evil.length, evil));
    final ok = utf8.encode('{"id":"s1"}');
    enc.addArchiveFile(
        ArchiveFile('data/sections/s1/section.json', ok.length, ok));
    enc.closeSync();

    final staging = '${tmp.path}/staging';
    NotebookBundleService.debugStreamUnzip(zipPath, staging);

    expect(File('${tmp.path}/escaped.json').existsSync(), isFalse);
    expect(File('$staging/sections/s1/section.json').existsSync(), isTrue);
  });
}
