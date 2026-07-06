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

/// Style for a single styled run.
TextStyle textStyleForRun(TextRun r) {
  final (family, fallback) = fontFamilyResolve(r.fontFamily);
  return TextStyle(
    color: r.color,
    fontSize: r.fontSize,
    fontFamily: family,
    fontFamilyFallback: fallback,
    fontWeight: r.bold ? FontWeight.w700 : FontWeight.w400,
    fontStyle: r.italic ? FontStyle.italic : FontStyle.normal,
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

/// The element's content as a multi-style span (one child per run).
InlineSpan textSpanForElement(TextElement el) {
  if (el.runs.isEmpty) return TextSpan(text: '', style: textStyleForElement(el));
  return TextSpan(
    children: [
      for (final r in el.runs) TextSpan(text: r.text, style: textStyleForRun(r)),
    ],
  );
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
  final contentWidth = math.min(natural.width, cap);

  final wrapped = TextPainter(
    text: span,
    textDirection: TextDirection.ltr,
    maxLines: null,
  )..layout(maxWidth: contentWidth);

  return Rect.fromLTWH(
    el.rect.left,
    el.rect.top,
    wrapped.width + kTextBoxPad,
    wrapped.height + kTextBoxPad,
  );
}
