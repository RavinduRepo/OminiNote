// OneNote → omininote converter.
//
// Takes the extractor's output (extract.json + assets/) and emits an
// omininote on-disk store:
//
//   <out>/notebooks.json                          (single-notebook index)
//   <out>/notebooks/<nb>/sections/<sec>/section.json
//   <out>/notebooks/<nb>/sections/<sec>/canvases/<cv>/canvas.json
//   <out>/notebooks/<nb>/sections/<sec>/canvases/<cv>/pages/<pg>.json
//   <out>/notebooks/<nb>/sections/<sec>/canvases/<cv>/assets/<sha256>.<ext>
//
// Mapping:
//   OneNote notebook        → Notebook
//   section group (folder)  → FolderNode in Notebook.nodes
//   section (.one)          → Section
//   page                    → Canvas (level ≥ 2 sub-pages nest into a
//                             FolderNode named after their parent page)
//   page content            → the OneNote page is infinite, so content is
//                             tiled into omininote pages: contiguous vertical
//                             bands (→ PageRows) with horizontal cuts inside
//                             wide bands (→ pages in a row). Cut lines are
//                             only placed where no element crosses, so no
//                             stroke/image is ever split.
//   ink stroke              → StrokeElement (COLORREF → ARGB, HIMETRIC → pt,
//                             pen_tip/transparency → pen vs highlighter)
//   image                   → ImageElement (below ink), lossless asset
//   embedded file (PDF …)   → AttachmentElement chip + asset
//   rich text               → TextElement with styled runs
//
// Usage:
//   dart run tools/onenote_importer/convert.dart <extract_dir> \
//       [--name "My Notebook"] [--out <dir>] [--install]
//
// --install merges the result into the local omininote data store
// (%APPDATA%\io.github.ravinduRepo\omininote) with a notebooks.json backup.
// Close the app first.

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';

// ── Units ────────────────────────────────────────────────────────────────
const double kHalfInToPt = 36.0; // 1 half-inch = 36 PDF points
const double kHimetricToPt = 72.0 / 2540.0; // HIMETRIC = 1/2540 inch

// Page tiling targets (PDF points).
const double kContentMargin = 24.0;
const double kMinPageW = 595.0; // A4 portrait width
const double kMinPageH = 842.0; // A4 portrait height
const double kMaxPageW = 1200.0; // wider content gets horizontal cuts
const double kTargetBandAspect = 1.414; // page height ≈ width × √2

const String kDeviceId = 'onenote-import';

int _idSeq = 0;
String newId(String prefix) =>
    '${prefix}_${DateTime.now().microsecondsSinceEpoch}_${_idSeq++}';

// ── Geometry ─────────────────────────────────────────────────────────────
class Box {
  final double left, top, right, bottom;
  const Box(this.left, this.top, this.right, this.bottom);
  double get width => right - left;
  double get height => bottom - top;

  Box union(Box o) => Box(
        math.min(left, o.left),
        math.min(top, o.top),
        math.max(right, o.right),
        math.max(bottom, o.bottom),
      );
}

/// One converted element: its omininote JSON (positioned in absolute content
/// space — translated into page-local space at assignment time) + its bbox.
class ConvertedElement {
  final Map<String, dynamic> json;
  final Box bbox;
  final bool isStroke;
  ConvertedElement(this.json, this.bbox, {required this.isStroke});
}

// ── Color helpers ────────────────────────────────────────────────────────

/// Windows COLORREF (0x00BBGGRR) → ARGB int. Null → opaque black.
int colorRefToArgb(int? ref) {
  if (ref == null) return 0xFF000000;
  final r = ref & 0xFF, g = (ref >> 8) & 0xFF, b = (ref >> 16) & 0xFF;
  return 0xFF000000 | (r << 16) | (g << 8) | b;
}

int rgbToArgb(List<dynamic>? rgb, {int fallback = 0xFF000000}) {
  if (rgb == null || rgb.length < 3) return fallback;
  return 0xFF000000 |
      ((rgb[0] as num).toInt() << 16) |
      ((rgb[1] as num).toInt() << 8) |
      (rgb[2] as num).toInt();
}

String mapFontFamily(String? font) {
  final f = (font ?? '').toLowerCase();
  if (f.contains('courier') || f.contains('consolas') || f.contains('mono')) {
    return 'mono';
  }
  if (f.contains('times') ||
      f.contains('georgia') ||
      f.contains('garamond') ||
      f.contains('serif')) {
    return 'serif';
  }
  return 'sans';
}

// ── Element conversion (absolute content space, PDF points) ─────────────

Map<String, dynamic> _envelope(String prefix, int updatedMs) => {
      'schemaVersion': 1,
      'id': newId(prefix),
      'rev': 1,
      'updatedAt': updatedMs,
      'deviceId': kDeviceId,
      'deletedAt': null,
    };

List<ConvertedElement> convertInk(Map<String, dynamic> item, int updatedMs) {
  final out = <ConvertedElement>[];
  final ox = ((item['offsetXHalfIn'] as num?) ?? 0) * kHalfInToPt;
  final oy = ((item['offsetYHalfIn'] as num?) ?? 0) * kHalfInToPt;

  for (final s in (item['strokes'] as List)) {
    final stroke = s as Map<String, dynamic>;
    final rawPts = stroke['points'] as List;
    if (rawPts.isEmpty) continue;

    final penTip = stroke['penTip'] as num?;
    final transparency = stroke['transparency'] as num?;
    final isHighlighter =
        (penTip != null && penTip != 0) || (transparency ?? 0) >= 64;

    final widthPt =
        math.max(0.5, ((stroke['widthHm'] as num?) ?? 70) * kHimetricToPt);
    // The app paints highlighter strokes at size × 2.6 — compensate so the
    // on-screen width matches OneNote's.
    final size = isHighlighter ? widthPt / 2.6 : widthPt;

    final points = <Map<String, dynamic>>[];
    var minX = double.infinity, minY = double.infinity;
    var maxX = double.negativeInfinity, maxY = double.negativeInfinity;
    for (final p in rawPts) {
      final x = ox + (p[0] as num) * kHimetricToPt;
      final y = oy + (p[1] as num) * kHimetricToPt;
      points.add({'x': x, 'y': y, 'p': 0.5});
      minX = math.min(minX, x);
      minY = math.min(minY, y);
      maxX = math.max(maxX, x);
      maxY = math.max(maxY, y);
    }

    final json = {
      ..._envelope('el', updatedMs),
      'type': 'stroke',
      'zi': 0.0,
      'createdAt': updatedMs,
      'z': '0|a0:',
      'tool': isHighlighter ? 'highlighter' : 'pen',
      'color': colorRefToArgb(stroke['colorRef'] as int?),
      'size': size,
      'points': points,
    };
    final pad = size;
    out.add(ConvertedElement(
      json,
      Box(minX - pad, minY - pad, maxX + pad, maxY + pad),
      isStroke: true,
    ));
  }
  return out;
}

ConvertedElement? convertImage(
    Map<String, dynamic> item, int updatedMs, AssetResolver assets) {
  final asset = item['asset'] as String?;
  if (asset == null) return null;
  final assetId = assets.resolve(asset);
  if (assetId == null) return null;

  final x = ((item['xHalfIn'] as num?) ?? 0) * kHalfInToPt;
  final y = ((item['yHalfIn'] as num?) ?? 0) * kHalfInToPt;
  final w = ((item['wHalfIn'] as num?) ?? 8) * kHalfInToPt;
  final h = ((item['hHalfIn'] as num?) ?? 8) * kHalfInToPt;

  final json = {
    ..._envelope('el', updatedMs),
    'type': 'image',
    'zi': -1.0, // below ink, like the app's own image insert
    'rect': {'x': x, 'y': y, 'w': w, 'h': h},
    'rotation': 0.0,
    'assetId': assetId,
  };
  return ConvertedElement(json, Box(x, y, x + w, y + h), isStroke: false);
}

ConvertedElement? convertFile(
    Map<String, dynamic> item, int updatedMs, AssetResolver assets) {
  final asset = item['asset'] as String?;
  if (asset == null) return null;
  final assetId = assets.resolve(asset);
  if (assetId == null) return null;

  final name = (item['filename'] as String?) ?? 'attachment';
  final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
  final mime = switch (ext) {
    'pdf' => 'application/pdf',
    'png' => 'image/png',
    'jpg' || 'jpeg' => 'image/jpeg',
    'txt' => 'text/plain',
    _ => 'application/octet-stream',
  };

  final x = ((item['xHalfIn'] as num?) ?? 1) * kHalfInToPt;
  final y = ((item['yHalfIn'] as num?) ?? 1) * kHalfInToPt;
  const w = 200.0, h = 48.0;

  final json = {
    ..._envelope('el', updatedMs),
    'type': 'attachment',
    'zi': 0.0,
    'rect': {'x': x, 'y': y, 'w': w, 'h': h},
    'rotation': 0.0,
    'assetId': assetId,
    'name': name,
    'mime': mime,
  };
  return ConvertedElement(json, Box(x, y, x + w, y + h), isStroke: false);
}

ConvertedElement? convertText(Map<String, dynamic> item, int updatedMs) {
  final paragraphs = (item['paragraphs'] as List?) ?? [];
  if (paragraphs.isEmpty) return null;

  final runs = <Map<String, dynamic>>[];
  var estHeight = 0.0;
  var maxLineLen = 0;
  final widthPt = ((item['maxWidthHalfIn'] as num?) ?? 12) * kHalfInToPt;

  for (var i = 0; i < paragraphs.length; i++) {
    final para = paragraphs[i] as Map<String, dynamic>;
    final indent = (para['indent'] as num?)?.toInt() ?? 0;
    final paraRuns = (para['runs'] as List?) ?? [];
    var paraLen = indent * 2;
    var paraFontSize = 11.0;

    for (var j = 0; j < paraRuns.length; j++) {
      final r = paraRuns[j] as Map<String, dynamic>;
      var text = (r['text'] as String?) ?? '';
      if (j == 0 && indent > 0) text = '${'  ' * indent}$text';
      if (j == paraRuns.length - 1 && i < paragraphs.length - 1) {
        text = '$text\n';
      }
      if (text.isEmpty) continue;
      final fontSize = ((r['fontSizeHalfPt'] as num?) ?? 22) / 2.0;
      paraFontSize = math.max(paraFontSize, fontSize);
      paraLen += (r['text'] as String? ?? '').length;
      runs.add({
        't': text,
        's': fontSize,
        'b': (r['bold'] as bool?) ?? false,
        'i': (r['italic'] as bool?) ?? false,
        'c': rgbToArgb(r['colorRgb'] as List?),
        'f': mapFontFamily(r['font'] as String?),
        if (r['hyperlink'] != null) 'l': r['hyperlink'],
      });
    }

    // Crude wrap estimate for the bbox (the app re-measures text on edit).
    final charsPerLine =
        math.max(8, (widthPt / (paraFontSize * 0.55)).floor());
    final lines = math.max(1, (paraLen / charsPerLine).ceil());
    estHeight += lines * paraFontSize * 1.3 + 2;
    maxLineLen = math.max(maxLineLen, paraLen);
  }
  if (runs.isEmpty) return null;

  final x = ((item['xHalfIn'] as num?) ?? 0) * kHalfInToPt;
  final y = ((item['yHalfIn'] as num?) ?? 0) * kHalfInToPt;
  final h = math.max(20.0, estHeight);
  final first = runs.first;

  final json = {
    ..._envelope('el', updatedMs),
    'type': 'text',
    'zi': 0.0,
    'rect': {'x': x, 'y': y, 'w': widthPt, 'h': h},
    'rotation': 0.0,
    'runs': runs,
    'fontFamily': first['f'],
    'fontSize': first['s'],
    'color': first['c'],
    'bold': first['b'],
    'italic': first['i'],
    'align': 'left',
  };
  return ConvertedElement(json, Box(x, y, x + widthPt, y + h),
      isStroke: false);
}

// ── Tiling: cut the infinite OneNote page into omininote pages ──────────

/// Merge 1-D occupied intervals (with a small tolerance so near-touching
/// intervals count as one blob).
List<List<double>> mergeIntervals(List<List<double>> intervals,
    {double tolerance = 2.0}) {
  if (intervals.isEmpty) return [];
  final sorted = [...intervals]..sort((a, b) => a[0].compareTo(b[0]));
  final merged = <List<double>>[
    [sorted.first[0], sorted.first[1]]
  ];
  for (final iv in sorted.skip(1)) {
    if (iv[0] <= merged.last[1] + tolerance) {
      merged.last[1] = math.max(merged.last[1], iv[1]);
    } else {
      merged.add([iv[0], iv[1]]);
    }
  }
  return merged;
}

/// Greedy 1-D banding: returns cut positions (excluding [start] and [end])
/// placed only inside gaps between merged occupied intervals, aiming for
/// bands of roughly [target] length. A blob longer than the target simply
/// yields a longer band — elements are never cut.
List<double> computeCuts({
  required List<List<double>> occupied,
  required double start,
  required double end,
  required double target,
}) {
  final merged = mergeIntervals(occupied);
  final cuts = <double>[];
  var cursor = start;
  // Never leave a sliver band/page: a cut must keep at least this much on
  // the far side, else we simply don't cut.
  final minRemainder = math.max(200.0, target * 0.35);

  while (end - cursor > target * 1.6) {
    final windowMin = cursor + target * 0.6;
    final windowMax = cursor + target * 1.6;

    double? cut;
    // Prefer a gap center inside the window.
    for (var i = 0; i < merged.length - 1; i++) {
      final gapStart = merged[i][1], gapEnd = merged[i + 1][0];
      if (gapEnd <= windowMin) continue;
      if (gapStart >= windowMax) break;
      final lo = math.max(gapStart, windowMin);
      final hi = math.min(gapEnd, windowMax);
      if (hi > lo) {
        cut = (lo + hi) / 2;
        break;
      }
      if (gapStart >= windowMin && gapStart < gapEnd) {
        cut = (gapStart + gapEnd) / 2;
        break;
      }
    }
    // Otherwise take the first gap after the window start (band runs long).
    if (cut == null) {
      for (var i = 0; i < merged.length - 1; i++) {
        final gapStart = merged[i][1], gapEnd = merged[i + 1][0];
        if (gapStart >= windowMin && gapEnd > gapStart) {
          cut = (gapStart + gapEnd) / 2;
          break;
        }
      }
    }
    if (cut == null || cut <= cursor + 1 || cut >= end - minRemainder) break;
    cuts.add(cut);
    cursor = cut;
  }
  return cuts;
}

class PageCell {
  final Box rect;
  final List<ConvertedElement> elements = [];
  PageCell(this.rect);
}

class BandOfCells {
  final List<PageCell> cells;
  BandOfCells(this.cells);
}

/// Tile the content region into bands (rows) × cells (pages) whose boundaries
/// avoid every element bbox, and assign elements to their containing cell.
List<BandOfCells> tileContent(List<ConvertedElement> elements) {
  if (elements.isEmpty) {
    return [
      BandOfCells([PageCell(const Box(0, 0, kMinPageW, kMinPageH))])
    ];
  }

  var bounds = elements.first.bbox;
  for (final e in elements.skip(1)) {
    bounds = bounds.union(e.bbox);
  }
  final left = bounds.left - kContentMargin;
  final top = bounds.top - kContentMargin;
  final right = math.max(bounds.right + kContentMargin, left + kMinPageW);
  final bottom = math.max(bounds.bottom + kContentMargin, top + kMinPageH);

  final contentW = right - left;
  final pageW = math.min(contentW, kMaxPageW);
  final targetBandH = math.max(kMinPageH, pageW * kTargetBandAspect);

  final vCuts = computeCuts(
    occupied: [
      for (final e in elements) [e.bbox.top, e.bbox.bottom]
    ],
    start: top,
    end: bottom,
    target: targetBandH,
  );

  final bandTops = [top, ...vCuts];
  final bandBottoms = [...vCuts, bottom];
  final bands = <BandOfCells>[];

  for (var b = 0; b < bandTops.length; b++) {
    final bTop = bandTops[b], bBottom = bandBottoms[b];
    final bandElements = elements
        .where((e) => e.bbox.top >= bTop - 0.01 && e.bbox.bottom <= bBottom + 0.01)
        .toList();

    // Horizontal cuts only when the band is wider than one target page.
    var hCuts = <double>[];
    if (contentW > kMaxPageW) {
      hCuts = computeCuts(
        occupied: [
          for (final e in bandElements) [e.bbox.left, e.bbox.right]
        ],
        start: left,
        end: right,
        target: math.max(kMinPageW, kMaxPageW * 0.8),
      );
    }

    final cellLefts = [left, ...hCuts];
    final cellRights = [...hCuts, right];
    final cells = <PageCell>[
      for (var c = 0; c < cellLefts.length; c++)
        PageCell(Box(cellLefts[c], bTop, cellRights[c], bBottom))
    ];

    for (final e in bandElements) {
      var placed = false;
      for (final cell in cells) {
        if (e.bbox.left >= cell.rect.left - 0.01 &&
            e.bbox.right <= cell.rect.right + 0.01) {
          cell.elements.add(e);
          placed = true;
          break;
        }
      }
      if (!placed) cells.first.elements.add(e); // shouldn't happen
    }
    bands.add(BandOfCells(cells));
  }

  // Any element that fell between bands (crosses a band boundary — shouldn't
  // happen given gap-based cuts, but guard anyway): put it in the band that
  // contains its top edge.
  final assigned = bands
      .expand((b) => b.cells)
      .expand((c) => c.elements)
      .toSet();
  for (final e in elements) {
    if (assigned.contains(e)) continue;
    for (var b = 0; b < bands.length; b++) {
      if (e.bbox.top >= bandTops[b] - 0.01 &&
          (b == bands.length - 1 || e.bbox.top < bandBottoms[b])) {
        bands[b].cells.first.elements.add(e);
        break;
      }
    }
  }

  return bands;
}

// ── Asset store ──────────────────────────────────────────────────────────

/// Copies extractor assets into a canvas's content-addressed assets dir and
/// hands out `<sha256>.<ext>` ids. One instance per canvas.
class AssetResolver {
  final Directory extractDir;
  final Directory canvasAssetsDir;
  final Map<String, String> _cache = {}; // extract-relative path → assetId

  AssetResolver(this.extractDir, this.canvasAssetsDir);

  String? resolve(String relPath) {
    final cached = _cache[relPath];
    if (cached != null) return cached;
    final src = File('${extractDir.path}/$relPath');
    if (!src.existsSync()) {
      stderr.writeln('  warning: missing asset $relPath');
      return null;
    }
    final bytes = src.readAsBytesSync();
    final ext = relPath.contains('.') ? relPath.split('.').last : 'bin';
    final assetId = '${sha256.convert(bytes).toString()}.$ext';
    final dst = File('${canvasAssetsDir.path}/$assetId');
    if (!dst.existsSync()) {
      dst.parent.createSync(recursive: true);
      dst.writeAsBytesSync(bytes);
    }
    _cache[relPath] = assetId;
    return assetId;
  }
}

// ── Page-level tree (sub-pages → folders) ────────────────────────────────

class PageNode {
  final Map<String, dynamic> page;
  final List<PageNode> children = [];
  PageNode(this.page);
}

/// Group a flat page list by OneNote page level (1..3): a page owns the
/// following pages of deeper level.
List<PageNode> buildPageTree(List<dynamic> pages) {
  final roots = <PageNode>[];
  final stack = <(int, PageNode)>[];
  for (final p in pages) {
    final page = p as Map<String, dynamic>;
    final level = math.max(1, (page['level'] as num?)?.toInt() ?? 1);
    final node = PageNode(page);
    while (stack.isNotEmpty && stack.last.$1 >= level) {
      stack.removeLast();
    }
    if (stack.isEmpty) {
      roots.add(node);
    } else {
      stack.last.$2.children.add(node);
    }
    stack.add((level, node));
  }
  return roots;
}

// ── Main conversion ──────────────────────────────────────────────────────

class Converter {
  final Directory extractDir;
  final Directory outDir;
  final String notebookName;
  final int nowMs = DateTime.now().millisecondsSinceEpoch;

  int canvasCount = 0, pageCount = 0, strokeCount = 0;
  int imageCount = 0, fileCount = 0, textCount = 0;

  Converter(this.extractDir, this.outDir, this.notebookName);

  void writeJson(String path, Object json) {
    final f = File('${outDir.path}/$path');
    f.parent.createSync(recursive: true);
    f.writeAsStringSync(const JsonEncoder.withIndent(' ').convert(json));
  }

  Map<String, dynamic> convert() {
    final extract = jsonDecode(
            File('${extractDir.path}/extract.json').readAsStringSync())
        as Map<String, dynamic>;
    final sections = extract['sections'] as List;

    final nbId = newId('nb');
    final nbNodes = <Map<String, dynamic>>[];
    // groupPath ("A/B") → children list of that folder node
    final folderChildren = <String, List<Map<String, dynamic>>>{
      '': nbNodes,
    };

    List<Map<String, dynamic>> folderFor(List<dynamic> groupPath) {
      var key = '';
      var children = nbNodes;
      for (final part in groupPath) {
        final parentChildren = children;
        key = key.isEmpty ? '$part' : '$key/$part';
        final existing = folderChildren[key];
        if (existing != null) {
          children = existing;
        } else {
          final node = {
            'type': 'folder',
            'id': newId('fold'),
            'name': '$part',
            'color': null,
            'collapsed': false,
            'children': <Map<String, dynamic>>[],
          };
          parentChildren.add(node);
          children = node['children'] as List<Map<String, dynamic>>;
          folderChildren[key] = children;
        }
      }
      return children;
    }

    for (final s in sections) {
      final section = s as Map<String, dynamic>;
      if (section['error'] != null) {
        stderr.writeln(
            'Skipping section ${section['name']} (extract error: ${section['error']})');
        continue;
      }
      final secId = newId('sec');
      final secName = (section['name'] as String?) ?? 'Section';
      stderr.writeln('Section: $secName');

      final pageTree = buildPageTree(section['pages'] as List);
      final secNodes = <Map<String, dynamic>>[];

      List<Map<String, dynamic>> nodesFor(List<PageNode> nodes) {
        final out = <Map<String, dynamic>>[];
        for (final node in nodes) {
          final cvId = convertPageToCanvas(node.page, nbId, secId);
          if (node.children.isEmpty) {
            out.add({'type': 'leaf', 'refId': cvId});
          } else {
            out.add({
              'type': 'folder',
              'id': newId('fold'),
              'name': _pageTitle(node.page),
              'color': null,
              'collapsed': false,
              'children': [
                {'type': 'leaf', 'refId': cvId},
                ...nodesFor(node.children),
              ],
            });
          }
        }
        return out;
      }

      secNodes.addAll(nodesFor(pageTree));

      final sectionJson = {
        'schemaVersion': 1,
        'id': secId,
        'rev': 1,
        'updatedAt': nowMs,
        'deviceId': kDeviceId,
        'deletedAt': null,
        'notebookId': nbId,
        'name': secName,
        'createdAt': DateTime.now().toIso8601String(),
        'color': null,
        'nodes': secNodes,
      };
      writeJson('notebooks/$nbId/sections/$secId/section.json', sectionJson);
      folderFor((section['groupPath'] as List?) ?? [])
          .add({'type': 'leaf', 'refId': secId});
    }

    final notebookJson = {
      'schemaVersion': 1,
      'id': nbId,
      'rev': 1,
      'updatedAt': nowMs,
      'deviceId': kDeviceId,
      'deletedAt': null,
      'name': notebookName,
      'createdAt': DateTime.now().toIso8601String(),
      'color': null,
      'syncTarget': null,
      'nodes': nbNodes,
      'sectionIds': _leafIds(nbNodes),
    };
    writeJson('notebooks.json', {nbId: notebookJson});

    stderr.writeln(
        'Converted: $canvasCount canvases, $pageCount pages, $strokeCount strokes, '
        '$imageCount images, $fileCount files, $textCount text boxes');
    return notebookJson;
  }

  List<String> _leafIds(List<Map<String, dynamic>> nodes) {
    final out = <String>[];
    for (final n in nodes) {
      if (n['type'] == 'leaf') {
        out.add(n['refId'] as String);
      } else {
        out.addAll(_leafIds(
            (n['children'] as List).cast<Map<String, dynamic>>()));
      }
    }
    return out;
  }

  String _pageTitle(Map<String, dynamic> page) {
    final t = (page['title'] as String?)?.trim();
    return (t == null || t.isEmpty) ? 'Untitled page' : t;
  }

  /// One OneNote page → one Canvas with tiled pages. Returns the canvas id.
  String convertPageToCanvas(
      Map<String, dynamic> page, String nbId, String secId) {
    final cvId = newId('cv');
    canvasCount++;
    final updatedMs = (page['updatedMs'] as num?)?.toInt() ?? nowMs;
    final createdMs = (page['createdMs'] as num?)?.toInt() ?? nowMs;
    final canvasDir = 'notebooks/$nbId/sections/$secId/canvases/$cvId';
    final assets = AssetResolver(
        extractDir, Directory('${outDir.path}/$canvasDir/assets'));

    // Convert every item into absolute-content-space elements.
    final elements = <ConvertedElement>[];
    for (final it in (page['items'] as List)) {
      final item = it as Map<String, dynamic>;
      switch (item['kind']) {
        case 'ink':
          final strokes = convertInk(item, updatedMs);
          strokeCount += strokes.length;
          elements.addAll(strokes);
        case 'image':
          final el = convertImage(item, updatedMs, assets);
          if (el != null) {
            imageCount++;
            elements.add(el);
          }
        case 'file':
          final el = convertFile(item, updatedMs, assets);
          if (el != null) {
            fileCount++;
            elements.add(el);
          }
        case 'text':
          final el = convertText(item, updatedMs);
          if (el != null) {
            textCount++;
            elements.add(el);
          }
      }
    }

    final bands = tileContent(elements);

    final rows = <Map<String, dynamic>>[];
    for (final band in bands) {
      final pageIds = <String>[];
      for (final cell in band.cells) {
        final pgId = newId('pg');
        pageCount++;
        pageIds.add(pgId);

        final strokes = <Map<String, dynamic>>[];
        final objects = <Map<String, dynamic>>[];
        for (final e in cell.elements) {
          final json = _translated(e, cell.rect);
          (e.isStroke ? strokes : objects).add(json);
        }

        final pageJson = {
          'schemaVersion': 1,
          'id': pgId,
          'rev': 1,
          'updatedAt': updatedMs,
          'deviceId': kDeviceId,
          'deletedAt': null,
          'w': _round(cell.rect.width),
          'h': _round(cell.rect.height),
          'background': {'color': 0xFFFFFFFF, 'pattern': 'blank'},
          'source': null,
          'strokes': strokes,
          'erased': [],
          'objects': objects,
          'deletedObjects': [],
        };
        writeJson('$canvasDir/pages/$pgId.json', pageJson);
      }
      rows.add({'id': newId('row'), 'pageIds': pageIds});
    }

    final canvasJson = {
      'schemaVersion': 1,
      'id': cvId,
      'rev': 1,
      'updatedAt': updatedMs,
      'deviceId': kDeviceId,
      'deletedAt': null,
      'notebookId': nbId,
      'sectionId': secId,
      'name': _pageTitle(page),
      'createdAt':
          DateTime.fromMillisecondsSinceEpoch(createdMs).toIso8601String(),
      'color': null,
      'defaultPageWidth': 595.0,
      'defaultPageHeight': 842.0,
      'defaultBackground': {'color': 0xFFFFFFFF, 'pattern': 'blank'},
      'rows': rows,
      'attachments': [],
      'bookmarks': [],
    };
    writeJson('$canvasDir/canvas.json', canvasJson);
    return cvId;
  }

  /// Deep-copy an element's JSON translated into page-local coordinates.
  Map<String, dynamic> _translated(ConvertedElement e, Box cell) {
    final json = jsonDecode(jsonEncode(e.json)) as Map<String, dynamic>;
    final dx = cell.left, dy = cell.top;
    if (json['type'] == 'stroke') {
      for (final p in (json['points'] as List)) {
        p['x'] = _round((p['x'] as num) - dx);
        p['y'] = _round((p['y'] as num) - dy);
      }
    } else {
      final r = json['rect'] as Map<String, dynamic>;
      r['x'] = _round((r['x'] as num) - dx);
      r['y'] = _round((r['y'] as num) - dy);
      r['w'] = _round(r['w'] as num);
      r['h'] = _round(r['h'] as num);
    }
    return json;
  }
}

double _round(num v) => (v * 100).round() / 100;

// ── Install ──────────────────────────────────────────────────────────────

Directory appDataStore() {
  final appData = Platform.environment['APPDATA'];
  if (appData == null) {
    throw StateError('APPDATA is not set — --install only works on Windows.');
  }
  return Directory('$appData/io.github.ravinduRepo/omininote');
}

void install(Directory outDir, Map<String, dynamic> notebookJson) {
  final store = appDataStore();
  if (!store.existsSync()) {
    throw StateError(
        'omininote data store not found at ${store.path} — run the app once first.');
  }
  final nbId = notebookJson['id'] as String;

  final indexFile = File('${store.path}/notebooks.json');
  Map<String, dynamic> index = {};
  if (indexFile.existsSync()) {
    final backup = File(
        '${store.path}/notebooks.json.bak-${DateTime.now().millisecondsSinceEpoch}');
    backup.writeAsBytesSync(indexFile.readAsBytesSync());
    index = jsonDecode(indexFile.readAsStringSync()) as Map<String, dynamic>;
    stderr.writeln('Backed up notebooks.json → ${backup.path}');
  }
  index[nbId] = notebookJson;

  // Copy the notebook tree.
  final srcRoot = Directory('${outDir.path}/notebooks/$nbId');
  final dstRoot = Directory('${store.path}/notebooks/$nbId');
  _copyTree(srcRoot, dstRoot);

  indexFile.writeAsStringSync(
      const JsonEncoder.withIndent(' ').convert(index));
  stderr.writeln('Installed notebook "$nbId" into ${store.path}');
  stderr.writeln('Start omininote to see it. (If the app was running, restart it.)');
}

void _copyTree(Directory src, Directory dst) {
  dst.createSync(recursive: true);
  for (final entity in src.listSync(recursive: false)) {
    final name = entity.uri.pathSegments.lastWhere((s) => s.isNotEmpty);
    if (entity is Directory) {
      _copyTree(entity, Directory('${dst.path}/$name'));
    } else if (entity is File) {
      entity.copySync('${dst.path}/$name');
    }
  }
}

// ── Entry point ──────────────────────────────────────────────────────────

void main(List<String> args) {
  if (args.isEmpty) {
    stderr.writeln(
        'Usage: dart run tools/onenote_importer/convert.dart <extract_dir> '
        '[--name "My Notebook"] [--out <dir>] [--install]');
    exit(1);
  }

  final extractDir = Directory(args[0]);
  if (!File('${extractDir.path}/extract.json').existsSync()) {
    stderr.writeln('No extract.json in ${extractDir.path} — run the extractor first.');
    exit(1);
  }

  var name = 'OneNote import';
  Directory? outDir;
  var doInstall = false;
  for (var i = 1; i < args.length; i++) {
    switch (args[i]) {
      case '--name':
        name = args[++i];
      case '--out':
        outDir = Directory(args[++i]);
      case '--install':
        doInstall = true;
      default:
        stderr.writeln('Unknown argument: ${args[i]}');
        exit(1);
    }
  }
  outDir ??= Directory('${extractDir.path}/omininote_store');
  if (outDir.existsSync()) {
    outDir.deleteSync(recursive: true);
  }
  outDir.createSync(recursive: true);

  final converter = Converter(extractDir, outDir, name);
  final notebookJson = converter.convert();
  stderr.writeln('Store written to ${outDir.path}');

  if (doInstall) {
    install(outDir, notebookJson);
  }
}
