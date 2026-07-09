import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../models/element.dart';

/// Internal horizontal/vertical padding baked into a text box so the caret and
/// descenders aren't clipped.
const double kTextBoxPad = 4.0;

/// Maps a family key ('sans' | 'serif' | 'mono') to a platform font family and
/// fallbacks. Shared by the painter, the editing controller, and measurement.
(String?, List<String>) fontFamilyResolve(String key) => switch (key) {
  'serif' => ('Georgia', const ['Times New Roman', 'serif']),
  'mono' => ('Courier New', const ['Consolas', 'monospace']),
  _ => (null, const <String>[]),
};

/// Link runs render in a fixed blue + underline (conventional, theme-neutral —
/// stroke/text colors are absolute in this app), overriding the run's own color.
const Color kLinkColor = Color(0xFF2563EB);

/// Style for a single styled run.
TextStyle textStyleForRun(TextRun r) {
  final (family, fallback) = fontFamilyResolve(r.fontFamily);
  final isLink = r.link != null;
  return TextStyle(
    color: isLink ? kLinkColor : r.color,
    fontSize: r.fontSize,
    fontFamily: family,
    fontFamilyFallback: fallback,
    fontWeight: r.bold ? FontWeight.w700 : FontWeight.w400,
    fontStyle: r.italic ? FontStyle.italic : FontStyle.normal,
    decoration: isLink ? TextDecoration.underline : null,
    decorationColor: isLink ? kLinkColor : null,
    height: 1.3,
  );
}

/// The element's baseline (default) style — used for an empty box and as the
/// editing overlay's fallback style.
TextStyle textStyleForElement(TextElement el) {
  final (family, fallback) = fontFamilyResolve(el.fontFamily);
  return TextStyle(
    color: el.color,
    fontSize: el.fontSize,
    fontFamily: family,
    fontFamilyFallback: fallback,
    fontWeight: el.bold ? FontWeight.w700 : FontWeight.w400,
    fontStyle: el.italic ? FontStyle.italic : FontStyle.normal,
    height: 1.3,
  );
}

/// The link URL at [localOffset] (relative to the box's top-left) within [el],
/// or null if that point isn't on a link run. Uses the same layout the painter
/// does, so it lines up with what's drawn.
String? urlAtOffset(TextElement el, Offset localOffset) {
  if (el.runs.every((r) => r.link == null)) return null;
  final tp = TextPainter(
    text: textSpanForElement(el),
    textDirection: TextDirection.ltr,
    textAlign: switch (el.align) {
      TextAlignOption.center => TextAlign.center,
      TextAlignOption.right => TextAlign.right,
      _ => TextAlign.left,
    },
  )..layout(minWidth: el.rect.width, maxWidth: math.max(el.rect.width, 8));
  final idx = tp.getPositionForOffset(localOffset).offset;
  var acc = 0;
  for (final r in el.runs) {
    final end = acc + r.text.length;
    if (idx < end) return r.link;
    acc = end;
  }
  return el.runs.isNotEmpty ? el.runs.last.link : null;
}

/// The element's content as a multi-style span (one child per run).
InlineSpan textSpanForElement(TextElement el) {
  if (el.runs.isEmpty) {
    return TextSpan(text: '', style: textStyleForElement(el));
  }
  return TextSpan(
    children: [
      for (final r in el.runs)
        TextSpan(text: r.text, style: textStyleForRun(r)),
    ],
  );
}

/// One styled fragment placed by line layout: [text] drawn with [run]'s style
/// at [offset], relative to the element's rect top-left. A run that wraps
/// across lines yields one fragment per line.
class PlacedRunFragment {
  final String text;
  final TextRun run;
  final Offset offset;
  const PlacedRunFragment(this.text, this.run, this.offset);
}

/// Splits [el]'s styled runs into per-line fragments with their laid-out
/// positions, using the same `TextPainter` layout the on-screen painter uses —
/// so a consumer that can't take a multi-style span (the PDF exporter) still
/// line-breaks, aligns, and positions each styled range identically to the
/// screen.
List<PlacedRunFragment> placedRunFragments(TextElement el) {
  if (el.runs.isEmpty) return const [];
  final tp = TextPainter(
    text: textSpanForElement(el),
    textDirection: TextDirection.ltr,
    textAlign: switch (el.align) {
      TextAlignOption.center => TextAlign.center,
      TextAlignOption.right => TextAlign.right,
      _ => TextAlign.left,
    },
  )..layout(minWidth: el.rect.width, maxWidth: math.max(el.rect.width, 8));

  final full = el.text;
  final total = full.length;
  // Each run's start offset in the concatenated text.
  final starts = <int>[];
  var acc = 0;
  for (final r in el.runs) {
    starts.add(acc);
    acc += r.text.length;
  }

  final out = <PlacedRunFragment>[];
  var lineStart = 0;
  while (lineStart < total) {
    final line = tp.getLineBoundary(TextPosition(offset: lineStart));
    final lineEnd = line.end;
    if (lineEnd <= lineStart) {
      lineStart++; // empty line (bare newline)
      continue;
    }
    for (var i = 0; i < el.runs.length; i++) {
      final rStart = starts[i];
      final rEnd = rStart + el.runs[i].text.length;
      final s = math.max(rStart, lineStart);
      final e = math.min(rEnd, lineEnd);
      if (e <= s) continue;
      final frag = el.runs[i].text
          .substring(s - rStart, e - rStart)
          .replaceAll('\n', '');
      if (frag.isEmpty) continue;
      final boxes = tp.getBoxesForSelection(
        TextSelection(baseOffset: s, extentOffset: e),
      );
      if (boxes.isEmpty) continue;
      out.add(
        PlacedRunFragment(
          frag,
          el.runs[i],
          Offset(boxes.first.left, boxes.first.top),
        ),
      );
    }
    // Next line: skip the hard newline character if that's what broke it.
    lineStart = (lineEnd < total && full[lineEnd] == '\n')
        ? lineEnd + 1
        : lineEnd;
  }
  return out;
}

/// Splits [runs] into consecutive chunks whose laid-out heights (wrapping at
/// [maxWidth], drawn with the same 1.3 line height as the painter) each fit
/// [maxHeight]. Split points fall on line boundaries; concatenating the
/// chunks' text restores the input exactly (a hard '\n' at a split stays at
/// the end of the earlier chunk). Returns a single chunk when everything
/// fits — and always makes progress, so one line taller than [maxHeight]
/// still lands somewhere rather than looping.
///
/// Used by the split-on-paste flow: each chunk becomes one linked text box
/// on its own page.
List<List<TextRun>> splitRunsByHeight(
  List<TextRun> runs,
  double maxWidth,
  double maxHeight,
) {
  if (runs.isEmpty) return [runs];
  final cap = math.max(maxWidth - kTextBoxPad, 8.0);
  final budget = maxHeight - kTextBoxPad;

  /// Slices the run list to the [a, b) character range, styles preserved.
  List<TextRun> slice(int a, int b) {
    final out = <TextRun>[];
    var pos = 0;
    for (final r in runs) {
      final start = math.max(a - pos, 0);
      final end = math.min(b - pos, r.text.length);
      if (start < end) {
        out.add(r.clone()..text = r.text.substring(start, end));
      }
      pos += r.text.length;
    }
    return out;
  }

  double heightOf(List<TextRun> chunk) {
    final span = TextSpan(
      children: [
        for (final r in chunk)
          TextSpan(text: r.text, style: textStyleForRun(r)),
      ],
    );
    final tp = TextPainter(text: span, textDirection: TextDirection.ltr)
      ..layout(maxWidth: cap);
    return tp.height;
  }

  if (heightOf(runs) <= budget) return [runs];

  // Line-start character offsets from the full layout (same enumeration as
  // [placedRunFragments]); cuts may only fall on these.
  final probe = TextElement(
    id: 'probe',
    deviceId: 'probe',
    rect: Rect.zero,
    runs: runs,
    color: runs.first.color,
  );
  final full = probe.text;
  final total = full.length;
  final tp = TextPainter(
    text: textSpanForElement(probe),
    textDirection: TextDirection.ltr,
  )..layout(maxWidth: cap);
  final lineStarts = <int>[0];
  var lineStart = 0;
  while (lineStart < total) {
    final b = tp.getLineBoundary(TextPosition(offset: lineStart));
    lineStart = b.end <= lineStart
        ? lineStart +
              1 // empty line (bare newline)
        : ((b.end < total && full[b.end] == '\n') ? b.end + 1 : b.end);
    if (lineStart < total) lineStarts.add(lineStart);
  }

  // Greedy: each chunk takes the most whole lines that still fit when the
  // chunk is laid out standalone (measured, not estimated — line heights can
  // round differently between a combined and a standalone layout). Always
  // takes at least one line so a single over-tall line can't loop.
  final out = <List<TextRun>>[];
  var startLine = 0;
  while (startLine < lineStarts.length) {
    final a = lineStarts[startLine];
    var lo = startLine + 1; // first candidate end line (≥ 1 line taken)
    var hi = lineStarts.length; // sentinel: end == total
    int endOffsetAt(int lineIdx) =>
        lineIdx >= lineStarts.length ? total : lineStarts[lineIdx];
    // Largest end line whose chunk still fits.
    var best = lo;
    while (lo <= hi) {
      final mid = (lo + hi) ~/ 2;
      if (heightOf(slice(a, endOffsetAt(mid))) <= budget ||
          mid == startLine + 1) {
        best = mid;
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    out.add(slice(a, endOffsetAt(best)));
    startLine = best;
  }
  return out;
}

/// Auto-sizes a text box to its content: grows to the text's natural
/// (single-line) width, wrapping only when it would exceed [maxWidth] (the
/// distance to the page's right edge). Keeps the element's top-left anchor.
Rect autoTextRect(TextElement el, double maxWidth) {
  final span = el.runs.isEmpty
      ? TextSpan(text: ' ', style: textStyleForElement(el))
      : textSpanForElement(el);

  final natural = TextPainter(
    text: span,
    textDirection: TextDirection.ltr,
    maxLines: null,
  )..layout();

  final cap = math.max(maxWidth - kTextBoxPad, el.fontSize);
  // A user-resized box wraps at its chosen width; otherwise auto-size to the
  // text's natural single-line width (capped at the page edge).
  final contentWidth = el.manualWidth != null
      ? (el.manualWidth! - kTextBoxPad).clamp(el.fontSize, cap)
      : math.min(natural.width, cap);

  final wrapped = TextPainter(
    text: span,
    textDirection: TextDirection.ltr,
    maxLines: null,
  )..layout(maxWidth: contentWidth);

  return Rect.fromLTWH(
    el.rect.left,
    el.rect.top,
    el.manualWidth ?? wrapped.width + kTextBoxPad,
    wrapped.height + kTextBoxPad,
  );
}
