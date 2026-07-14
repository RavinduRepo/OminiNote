import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'dart:ui' show Offset;

import '../canvas/text_measure.dart' show placedRunFragments, PlacedRunFragment;
import '../models/canvas.dart';
import '../models/canvas_page.dart';
import '../models/element.dart';
import 'pdf_exporter.dart';

/// Runs a multi-level PDF export on a **background isolate** so the UI stays
/// responsive (the Syncfusion assembly + stroke-outline math is heavy pure
/// CPU). `onProgress(fraction, label)` reports a 0..1 fraction with a label:
/// the first ~0.35 covers on-main **serialization** (so the indicator moves
/// immediately instead of sitting still during text layout), the rest is the
/// isolate appending canvases. (Perf 07/14/26.)
///
/// The isolate boundary carries only plain data (JSON maps + asset bytes +
/// precomputed text fragments) — no live model objects, `dart:ui` handles, or
/// closures cross it. Text layout (`placedRunFragments` → `TextPainter`) is
/// computed **here on the main isolate** because it needs the Flutter engine,
/// which a background isolate doesn't have; the isolate reuses those fragments.
/// The serialize loop yields per item so that on-main work can't freeze a
/// frame. Any isolate failure falls back to an on-main export — a hiccup must
/// never fail the export (same guard the page-JSON offload uses).
Future<Uint8List> exportPdfInIsolate(
  List<PdfExportItem> items, {
  void Function(double fraction, String label)? onProgress,
}) async {
  // Maps the exporter's per-canvas (done,total) into the 0.35..1.0 export span.
  void exportPhase(int done, int total) => onProgress?.call(
        0.35 + 0.65 * (total == 0 ? 1.0 : done / total),
        'Exporting canvas $done of $total…',
      );

  // 1. Serialize on the main isolate (asset reads + engine-bound text layout).
  //    Report progress + yield each item so this phase doesn't freeze a frame.
  final data = <Map<String, dynamic>>[];
  for (var i = 0; i < items.length; i++) {
    data.add(await _serializeItem(items[i]));
    onProgress?.call(0.35 * (i + 1) / items.length, 'Preparing…');
    await Future<void>.delayed(Duration.zero);
  }

  // 2. Spawn the worker; fall back to on-main if spawn itself fails.
  final rp = ReceivePort();
  Isolate iso;
  try {
    iso = await Isolate.spawn(_entry, [rp.sendPort, data]);
  } catch (_) {
    rp.close();
    return SyncfusionPdfExporter().exportTree(items, onProgress: exportPhase);
  }

  final completer = Completer<Uint8List>();
  rp.listen((msg) {
    final m = msg as Map;
    if (m.containsKey('progress')) {
      exportPhase(m['progress'] as int, m['total'] as int);
    } else if (m.containsKey('result')) {
      if (!completer.isCompleted) completer.complete(m['result'] as Uint8List);
      rp.close();
    } else if (m.containsKey('error')) {
      if (!completer.isCompleted) {
        completer.completeError(Exception(m['error'] as String));
      }
      rp.close();
    }
  });

  try {
    return await completer.future;
  } catch (_) {
    // Isolate died / errored mid-run — never fail the export.
    return SyncfusionPdfExporter().exportTree(items, onProgress: exportPhase);
  } finally {
    iso.kill(priority: Isolate.immediate);
  }
}

/// Flattens one [PdfExportItem] into a sendable map: outline, canvas + page
/// JSON, referenced asset bytes, and precomputed per-text-element fragments.
Future<Map<String, dynamic>> _serializeItem(PdfExportItem item) async {
  final assetIds = <String>{};
  for (final p in item.pages.values) {
    assetIds.addAll(p.referencedAssetIds());
  }

  // Prefer shipping asset PATHS (the worker reads them lazily, one at a time)
  // over pre-reading every asset into memory here — the OOM fix for image-heavy
  // exports. Falls back to bytes only when a caller didn't supply paths.
  final assetPath = item.assetPath;
  Map<String, String>? paths;
  Map<String, Uint8List>? assets;
  if (assetPath != null) {
    paths = {for (final id in assetIds) id: assetPath(id)};
  } else {
    assets = <String, Uint8List>{};
    for (final id in assetIds) {
      try {
        assets[id] = await item.assetBytes(id);
      } catch (_) {
        // missing/unreadable asset — the exporter already skips these
      }
    }
  }

  final placed = <String, List<Map<String, dynamic>>>{};
  for (final p in item.pages.values) {
    for (final el in zOrderedElements(p).whereType<TextElement>()) {
      final frags = placedRunFragments(el);
      if (frags.isEmpty) continue;
      placed[el.id] = [
        for (final f in frags)
          {
            't': f.text,
            'dx': f.offset.dx,
            'dy': f.offset.dy,
            'run': f.run.toJson(),
          },
      ];
    }
  }

  return {
    'outline': item.outline,
    'canvas': item.canvas.toJson(),
    'pages': [for (final p in item.pages.values) p.toJson()],
    'assetPaths': ?paths,
    'assets': ?assets,
    'placed': placed,
  };
}

/// Rebuilds a [PdfExportItem] from its serialized map inside the isolate.
PdfExportItem _deserializeItem(Map<String, dynamic> d) {
  final pages = <String, CanvasPage>{};
  for (final pj in (d['pages'] as List)) {
    final page = CanvasPage.fromJson((pj as Map).cast<String, dynamic>());
    pages[page.id] = page;
  }
  final canvas = Canvas.fromJson((d['canvas'] as Map).cast<String, dynamic>());

  // Path-based (lazy, memory-safe) resolver when the caller shipped paths,
  // else the pre-read bytes map (fallback).
  Future<Uint8List> Function(String) assetBytes;
  if (d['assetPaths'] != null) {
    final paths = <String, String>{
      for (final e in (d['assetPaths'] as Map).entries)
        e.key as String: e.value as String,
    };
    assetBytes = (id) async {
      final p = paths[id];
      if (p == null) return Uint8List(0);
      try {
        return await File(p).readAsBytes();
      } catch (_) {
        return Uint8List(0);
      }
    };
  } else {
    final assets = <String, Uint8List>{
      for (final e in (d['assets'] as Map).entries)
        e.key as String: e.value as Uint8List,
    };
    assetBytes = (id) async => assets[id] ?? Uint8List(0);
  }

  final placed = <String, List<PlacedRunFragment>>{};
  (d['placed'] as Map).forEach((elId, list) {
    placed[elId as String] = [
      for (final f in (list as List))
        PlacedRunFragment(
          (f as Map)['t'] as String,
          TextRun.fromJson((f['run'] as Map).cast<String, dynamic>()),
          Offset((f['dx'] as num).toDouble(), (f['dy'] as num).toDouble()),
        ),
    ];
  });

  return PdfExportItem(
    outline: (d['outline'] as List).cast<String>(),
    canvas: canvas,
    pages: pages,
    assetBytes: assetBytes,
    placedText: placed,
  );
}

/// Isolate entry point: [args] is `[SendPort, List<Map>]`. Rebuilds the items,
/// runs the exporter forwarding progress, and sends back the bytes (or error).
Future<void> _entry(List<Object> args) async {
  final reply = args[0] as SendPort;
  final data = (args[1] as List).cast<Map<String, dynamic>>();
  try {
    final items = [for (final d in data) _deserializeItem(d)];
    final bytes = await SyncfusionPdfExporter().exportTree(
      items,
      onProgress: (done, total) => reply.send({'progress': done, 'total': total}),
    );
    reply.send({'result': bytes});
  } catch (e) {
    reply.send({'error': '$e'});
  }
}
