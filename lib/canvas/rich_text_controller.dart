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
  })  : _attrs = attrs,
        _baseDefaults = defaults.clone();

  List<CharAttr> _attrs; // length is kept == text.length
  CharAttr defaults; // typing style for newly inserted characters

  /// The element's base style at edit start — what a heading line's typing
  /// style resets to on Enter.
  final CharAttr _baseDefaults;
  double displayScale = 1.0;

  /// Fired when a style (not text) change should trigger a re-measure.
  VoidCallback? onStyleChanged;

  List<CharAttr> get attrs => _attrs;

  /// Line-list prefixes (plain Unicode glyphs, so the painter, PDF export and
  /// sync need zero special handling): bullet, star, unchecked/checked box.
  static const String bulletPrefix = '• ';
  static const String starPrefix = '★ ';
  static const String uncheckedPrefix = '☐ ';
  static const String checkedPrefix = '☑ ';
  static const List<String> _linePrefixes = [
    bulletPrefix,
    starPrefix,
    uncheckedPrefix,
    checkedPrefix,
  ];

  @override
  set value(TextEditingValue newValue) {
    var next = newValue;
    if (next.text != text) {
      final reverted = _maybeRevertRule(value, next);
      if (reverted != null) {
        next = reverted;
      } else {
        // OneNote-style list continuation: pressing Enter on a list line
        // carries the prefix onto the new line; Enter on an *empty* list item
        // removes the prefix (exits the list).
        next = _maybeContinueList(value, next);
        // Notion-style Markdown input rules: `# `, `- `, `[ ] `, `**bold**`…
        next = _maybeApplyInputRules(value, next);
      }
      _attrs = _reconcile(text, _attrs, next.text);
      for (final (a, b, mutate) in _pendingRuleStyles) {
        for (var i = a; i < b && i < _attrs.length; i++) {
          mutate(_attrs[i]);
        }
      }
      _pendingRuleStyles.clear();
    }
    super.value = next;
  }

  // ── Markdown input rules (Notion model: one-way, as-you-type) ────────────

  /// Style ranges (new-text coordinates) staged by a rule, applied right
  /// after [_reconcile] aligns the attr array to the transformed text.
  final List<(int, int, void Function(CharAttr))> _pendingRuleStyles = [];

  /// The escape hatch: pressing backspace immediately after a rule fired
  /// restores the raw characters (and the rule won't re-fire — it only
  /// triggers on the completing keystroke). `(pre-rule value, post-rule
  /// text)`; any other edit clears it.
  (TextEditingValue, String)? _lastRule;

  /// Set when a rule changed the typing style (heading/quote): the editor's
  /// caret-move style-adoption must skip one notification or it would clobber
  /// the style the rule just set (same mechanism as the style-while-typing
  /// fix). Consumed by the edit session via [consumeSuppressStyleAdopt].
  bool _suppressStyleAdopt = false;
  bool consumeSuppressStyleAdopt() {
    final v = _suppressStyleAdopt;
    _suppressStyleAdopt = false;
    return v;
  }

  TextEditingValue? _maybeRevertRule(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final last = _lastRule;
    _lastRule = null;
    if (last == null) return null;
    // A single-character deletion as the very next edit after a rule.
    if (oldValue.text != last.$2 ||
        newValue.text.length != oldValue.text.length - 1) {
      return null;
    }
    // A heading/quote rule changed the typing style — undo that too.
    defaults = _baseDefaults.clone();
    _suppressStyleAdopt = true;
    return last.$1;
  }

  TextEditingValue _maybeApplyInputRules(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final oldText = oldValue.text, newText = newValue.text;
    // Insertions only, at the caret, not mid-IME-composition (transforming
    // composing text breaks autocorrect/swipe input).
    if (newText.length <= oldText.length) return newValue;
    if (newValue.composing.isValid) return newValue;
    final caret = newValue.selection.baseOffset;
    final inserted = newText.length - oldText.length;
    if (!newValue.selection.isCollapsed || caret < inserted) return newValue;
    if (newText.substring(0, caret - inserted) !=
            oldText.substring(0, caret - inserted) ||
        newText.substring(caret) != oldText.substring(caret - inserted)) {
      return newValue;
    }
    final lastChar = newText[caret - 1];

    // Enter leaves a heading: the next line types at the base size again.
    if (lastChar == '\n') {
      if (defaults.fontSize != _baseDefaults.fontSize) {
        defaults = _baseDefaults.clone();
        _suppressStyleAdopt = true;
      }
      return newValue;
    }

    TextEditingValue fire(TextEditingValue out) {
      // Revert restores the raw pre-transform text ("- ", "# ", "**bold**")
      // with the caret where it was — as if the rule never fired.
      _lastRule = (
        TextEditingValue(
          text: newText,
          selection: TextSelection.collapsed(offset: caret),
        ),
        out.text,
      );
      return out;
    }

    if (lastChar == ' ') {
      final lineStart = newText.lastIndexOf('\n', caret - 2) + 1;
      final head = newText.substring(lineStart, caret);

      final heading = RegExp(r'^(#{1,3}) $').firstMatch(head);
      if (heading != null) {
        final scale = const [2.0, 1.5, 1.17][heading.group(1)!.length - 1];
        final size = _baseDefaults.fontSize * scale;
        defaults = _baseDefaults.clone()
          ..fontSize = size
          ..bold = true;
        _suppressStyleAdopt = true;
        final lineEndRaw = newText.indexOf('\n', caret);
        final lineEnd = lineEndRaw < 0 ? newText.length : lineEndRaw;
        if (lineEnd > caret) {
          // "# " typed before existing text: the whole line becomes heading.
          _pendingRuleStyles.add((
            lineStart,
            lineEnd - head.length,
            (a) => a
              ..fontSize = size
              ..bold = true,
          ));
        }
        return fire(TextEditingValue(
          text: newText.substring(0, lineStart) + newText.substring(caret),
          selection: TextSelection.collapsed(offset: lineStart),
        ));
      }

      String? replacement;
      // An existing list glyph before the marker is swallowed too — "[x] "
      // typed on an auto-continued "☐ " line flips it rather than nesting.
      final task = RegExp(r'^(?:[•★☐☑] )?\[( |x|X)?\] $').firstMatch(head);
      if (task != null) {
        replacement = (task.group(1) == 'x' || task.group(1) == 'X')
            ? checkedPrefix
            : uncheckedPrefix;
      } else if (RegExp(r'^[-*] $').hasMatch(head)) {
        replacement = bulletPrefix;
      } else if (head == '> ') {
        replacement = '│ ';
        defaults = defaults.clone()..italic = true;
        _suppressStyleAdopt = true;
      }
      if (replacement != null) {
        return fire(TextEditingValue(
          text: newText.substring(0, lineStart) +
              replacement +
              newText.substring(caret),
          selection:
              TextSelection.collapsed(offset: lineStart + replacement.length),
        ));
      }
      return newValue;
    }

    // Inline pair completions: the closing marker was just typed.
    (int, int, String, void Function(CharAttr))? hit;
    final before = newText.substring(0, caret);
    if (lastChar == '*' || lastChar == '_') {
      final marker = lastChar == '*' ? r'\*' : '_';
      final boldRe = RegExp(
          '$marker$marker([^\\s*_](?:[^*_\\n]*[^\\s*_])?)$marker$marker\$');
      final m = boldRe.firstMatch(before);
      if (m != null) {
        hit = (m.start, caret, m.group(1)!, (a) => a.bold = true);
      } else if (lastChar == '*') {
        // Single-underscore italics are skipped on purpose: snake_case.
        final itRe =
            RegExp(r'(?<!\*)\*([^\s*](?:[^*\n]*[^\s*])?)\*$');
        final it = itRe.firstMatch(before);
        if (it != null) {
          hit = (it.start, caret, it.group(1)!, (a) => a.italic = true);
        }
      }
    } else if (lastChar == '`') {
      final m = RegExp(r'`([^`\n]+)`$').firstMatch(before);
      if (m != null) {
        hit = (m.start, caret, m.group(1)!, (a) => a.family = 'mono');
      }
    }
    if (hit != null) {
      final (start, end, content, mutate) = hit;
      _pendingRuleStyles.add((start, start + content.length, mutate));
      // The caret now sits right after the styled content — suppress one
      // style adoption or typing would continue bold/italic/mono (Notion
      // exits the style after the closing marker).
      _suppressStyleAdopt = true;
      return fire(TextEditingValue(
        text: newText.substring(0, start) + content + newText.substring(end),
        selection: TextSelection.collapsed(offset: start + content.length),
      ));
    }
    return newValue;
  }

  TextEditingValue _maybeContinueList(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final oldText = oldValue.text, newText = newValue.text;
    // Only react to a plain single-'\n' insertion at the caret.
    if (newText.length != oldText.length + 1) return newValue;
    final caret = newValue.selection.baseOffset;
    if (caret < 1 || newText[caret - 1] != '\n') return newValue;
    if (newText.substring(0, caret - 1) != oldText.substring(0, caret - 1) ||
        newText.substring(caret) != oldText.substring(caret - 1)) {
      return newValue;
    }

    final lineStart = newText.lastIndexOf('\n', caret - 2) + 1;
    final prevLine = newText.substring(lineStart, caret - 1);
    for (final prefix in _linePrefixes) {
      if (!prevLine.startsWith(prefix)) continue;
      if (prevLine.length == prefix.length) {
        // Empty item + Enter → exit the list: drop both the prefix and the
        // just-typed newline, leaving a plain empty line.
        return TextEditingValue(
          text: newText.substring(0, lineStart) + newText.substring(caret),
          selection: TextSelection.collapsed(offset: lineStart),
        );
      }
      // Continue the list on the new line (a fresh unchecked box for ☑).
      final cont = prefix == checkedPrefix ? uncheckedPrefix : prefix;
      return TextEditingValue(
        text: newText.substring(0, caret) + cont + newText.substring(caret),
        selection: TextSelection.collapsed(offset: caret + cont.length),
      );
    }
    return newValue;
  }

  /// Toggles a list prefix on every line the selection touches. Behavior per
  /// line: has [prefix] → remove it; has another list prefix → replace; plain
  /// → add. For the checkbox button pass [cycle]=true: none → ☐ → ☑ → none.
  void toggleLinePrefix(String prefix, {bool cycle = false}) {
    final sel = selection;
    final start = sel.isValid ? sel.start : text.length;
    final end = sel.isValid ? sel.end : text.length;

    final lineStarts = <int>[];
    var ls = text.lastIndexOf('\n', (start - 1).clamp(0, text.length)) + 1;
    if (start == 0) ls = 0;
    lineStarts.add(ls);
    for (var i = ls; i < end && i < text.length; i++) {
      if (text[i] == '\n' && i + 1 <= text.length) lineStarts.add(i + 1);
    }

    var newText = text;
    var delta = 0; // total length change before the selection end
    var firstDelta = 0; // change on the first line (affects sel.start)
    for (final lineStartRaw in lineStarts) {
      final lineStart = lineStartRaw + delta;
      final current = _prefixAt(newText, lineStart);
      String? replacement;
      if (cycle) {
        replacement = switch (current) {
          null => uncheckedPrefix, // plain → ☐
          uncheckedPrefix => checkedPrefix, // ☐ → ☑
          checkedPrefix => null, // ☑ → plain
          _ => uncheckedPrefix, // bullet/star → ☐
        };
      } else {
        replacement = current == prefix ? null : prefix;
      }
      final removed = current?.length ?? 0;
      final added = replacement?.length ?? 0;
      newText = newText.substring(0, lineStart) +
          (replacement ?? '') +
          newText.substring(lineStart + removed);
      if (lineStartRaw == lineStarts.first) firstDelta = added - removed;
      delta += added - removed;
    }

    final newStart = (start + firstDelta).clamp(0, newText.length);
    final newEnd = (end + delta).clamp(newStart, newText.length);
    value = TextEditingValue(
      text: newText,
      selection: sel.isValid
          ? TextSelection(baseOffset: newStart, extentOffset: newEnd)
          : TextSelection.collapsed(offset: newText.length),
    );
    onStyleChanged?.call();
  }

  static String? _prefixAt(String s, int lineStart) {
    for (final p in _linePrefixes) {
      if (s.startsWith(p, lineStart)) return p;
    }
    return null;
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
    // Newly typed characters take the current typing style (`defaults`). The
    // editor keeps `defaults` in sync with the caret's surroundings on every
    // caret move (so mid-text typing matches context) and with an explicit
    // style the user just picked (so "set color, then type" actually applies —
    // inheriting from the previous char here would silently ignore that).
    return [
      ...s.sublist(0, p.clamp(0, s.length)),
      for (var i = 0; i < insertedCount; i++) defaults.clone(),
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
