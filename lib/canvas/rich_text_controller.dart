import 'package:flutter/material.dart';
import '../models/element.dart';
import 'text_measure.dart';

/// Per-character style while a text box is being edited. Font sizes are in
/// page points; the controller multiplies by [RichTextController.displayScale]
/// (the viewport zoom) when building the on-screen span.
class CharAttr {
  double fontSize;
  bool bold;
  bool italic;
  Color color;
  String family;

  CharAttr({
    required this.fontSize,
    required this.bold,
    required this.italic,
    required this.color,
    required this.family,
  });

  CharAttr clone() => CharAttr(
    fontSize: fontSize,
    bold: bold,
    italic: italic,
    color: color,
    family: family,
  );

  bool sameStyle(CharAttr o) =>
      fontSize == o.fontSize &&
      bold == o.bold &&
      italic == o.italic &&
      color.toARGB32() == o.color.toARGB32() &&
      family == o.family;
}

/// A [TextEditingController] that carries a per-character style array and
/// renders it as a multi-style [TextSpan]. Applying a style to the current
/// selection mutates only that range and leaves the selection intact (so
/// repeated size nudges keep working), which a plain controller can't do.
class RichTextController extends TextEditingController {
  RichTextController({
    required super.text,
    required List<CharAttr> attrs,
    required this.defaults,
  }) : _attrs = attrs;

  List<CharAttr> _attrs; // length is kept == text.length
  CharAttr defaults; // typing style for newly inserted characters
  double displayScale = 1.0;

  /// Fired when a style (not text) change should trigger a re-measure.
  VoidCallback? onStyleChanged;

  List<CharAttr> get attrs => _attrs;

  @override
  set value(TextEditingValue newValue) {
    if (newValue.text != text) {
      _attrs = _reconcile(text, _attrs, newValue.text);
    }
    super.value = newValue;
  }

  /// Keeps the per-char style array aligned with an arbitrary text edit by
  /// diffing common prefix/suffix; inserted characters inherit the neighbouring
  /// (or typing) style.
  List<CharAttr> _reconcile(String oldText, List<CharAttr> s, String neo) {
    final minLen = oldText.length < neo.length ? oldText.length : neo.length;
    var p = 0;
    while (p < minLen && oldText[p] == neo[p]) {
      p++;
    }
    var suffix = 0;
    while (suffix < (minLen - p) &&
        oldText[oldText.length - 1 - suffix] == neo[neo.length - 1 - suffix]) {
      suffix++;
    }
    final insertedCount = neo.length - p - suffix;
    final inheritIndex = p > 0 ? p - 1 : p;
    final base = (inheritIndex >= 0 && inheritIndex < s.length)
        ? s[inheritIndex]
        : defaults;
    return [
      ...s.sublist(0, p.clamp(0, s.length)),
      for (var i = 0; i < insertedCount; i++) base.clone(),
      ...s.sublist((oldText.length - suffix).clamp(0, s.length)),
    ];
  }

  /// Applies [mutate] to the selected characters (or to the typing style when
  /// the selection is collapsed), preserving the selection.
  void applyToSelection(void Function(CharAttr) mutate) {
    final sel = selection;
    if (!sel.isValid) {
      mutate(defaults);
      onStyleChanged?.call();
      notifyListeners();
      return;
    }
    if (sel.isCollapsed) {
      mutate(defaults); // next typed characters take the new style
    } else {
      for (var i = sel.start; i < sel.end && i < _attrs.length; i++) {
        mutate(_attrs[i]);
      }
    }
    onStyleChanged?.call();
    notifyListeners(); // rebuilds the span; selection is untouched
  }

  /// Representative style for the toolbar: the selection's first char, else the
  /// char before the caret, else the typing style.
  CharAttr styleForToolbar() {
    final sel = selection;
    if (sel.isValid && !sel.isCollapsed && sel.start < _attrs.length) {
      return _attrs[sel.start].clone();
    }
    if (sel.isValid && sel.isCollapsed && sel.start > 0 && sel.start - 1 < _attrs.length) {
      return _attrs[sel.start - 1].clone();
    }
    return defaults.clone();
  }

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    if (text.isEmpty) return TextSpan(text: '', style: style);
    final children = <TextSpan>[];
    var i = 0;
    while (i < text.length) {
      final attr = i < _attrs.length ? _attrs[i] : defaults;
      var j = i + 1;
      while (j < text.length &&
          j < _attrs.length &&
          _attrs[j].sameStyle(attr)) {
        j++;
      }
      children.add(
        TextSpan(text: text.substring(i, j), style: _styleFor(attr)),
      );
      i = j;
    }
    return TextSpan(style: style, children: children);
  }

  TextStyle _styleFor(CharAttr a) {
    final (family, fallback) = fontFamilyResolve(a.family);
    return TextStyle(
      color: a.color,
      fontSize: a.fontSize * displayScale,
      fontFamily: family,
      fontFamilyFallback: fallback,
      fontWeight: a.bold ? FontWeight.w700 : FontWeight.w400,
      fontStyle: a.italic ? FontStyle.italic : FontStyle.normal,
      height: 1.3,
    );
  }
}

/// Expands an element's runs into one [CharAttr] per character (edit start).
List<CharAttr> attrsFromElement(TextElement el) {
  final list = <CharAttr>[];
  for (final run in el.runs) {
    for (var i = 0; i < run.text.length; i++) {
      list.add(
        CharAttr(
          fontSize: run.fontSize,
          bold: run.bold,
          italic: run.italic,
          color: run.color,
          family: run.fontFamily,
        ),
      );
    }
  }
  return list;
}

/// The element's default/typing style as a [CharAttr].
CharAttr defaultAttrOf(TextElement el) => CharAttr(
  fontSize: el.fontSize,
  bold: el.bold,
  italic: el.italic,
  color: el.color,
  family: el.fontFamily,
);

/// Collapses the controller's per-char styles back into merged runs (commit).
List<TextRun> runsFromController(RichTextController rc) {
  final text = rc.text;
  final attrs = rc.attrs;
  final runs = <TextRun>[];
  var i = 0;
  while (i < text.length) {
    final a = i < attrs.length ? attrs[i] : rc.defaults;
    var j = i + 1;
    while (j < text.length && j < attrs.length && attrs[j].sameStyle(a)) {
      j++;
    }
    runs.add(
      TextRun(
        text: text.substring(i, j),
        fontSize: a.fontSize,
        bold: a.bold,
        italic: a.italic,
        color: a.color,
        fontFamily: a.family,
      ),
    );
    i = j;
  }
  return runs;
}
