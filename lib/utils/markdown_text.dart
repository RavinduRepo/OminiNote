import '../models/element.dart';

/// Markdown → styled [TextRun]s, so pasted Markdown (ChatGPT output, `.md`
/// notes) lands formatted instead of as raw symbols.
///
/// One-way input conversion (the Notion model): the result is ordinary rich
/// text — the Markdown source is not retained. Deliberate subset (CANVAS_SPEC
/// §17.1): headings, bold/italic, inline + fenced code (mono), bullet /
/// numbered / task lists with nesting (the app's plain-glyph prefixes —
/// `- [ ]` becomes the same tappable ☐ the toolbar makes), links, blockquotes,
/// horizontal rules. Tables/images/footnotes/HTML are out of scope; unknown
/// syntax passes through as literal text.

// ── Detection ──────────────────────────────────────────────────────────────

final _reHeading = RegExp(r'^#{1,6}\s+\S', multiLine: true);
final _reFence = RegExp(r'^\s*```', multiLine: true);
final _reTask = RegExp(r'^\s*[-*+]\s+\[[ xX]?\]\s+\S', multiLine: true);
final _reTableRow = RegExp(r'^\s*\|(.+)\|\s*$');
final _reLink = RegExp(r'\[[^\]\n]+\]\([^)\s]+\)');
final _reBold = RegExp(r'\*\*\S(?:[^*\n]*\S)?\*\*|__\S(?:[^_\n]*\S)?__');
final _reBullet = RegExp(r'^\s*[-*+]\s+\S', multiLine: true);
final _reOrdered = RegExp(r'^\s*\d+\.\s+\S', multiLine: true);
final _reCode = RegExp(r'`[^`\n]+`');
final _reQuote = RegExp(r'^>\s+\S', multiLine: true);

/// Strict "is this Markdown?" check for the plain-text paste branch — biased
/// against false positives so ordinary prose is never reformatted. Strong
/// signals convert alone (a heading, fence, task item, link, bold pair, or a
/// *list* of 2+ items); weak ones (a single list line, inline code, a quote)
/// need two distinct kinds.
bool looksLikeMarkdown(String text) {
  if (_reHeading.hasMatch(text) ||
      _reFence.hasMatch(text) ||
      _reTask.hasMatch(text) ||
      _reLink.hasMatch(text) ||
      _reBold.hasMatch(text) ||
      _reBullet.allMatches(text).length >= 2 ||
      _reOrdered.allMatches(text).length >= 2 ||
      RegExp(r'^\s*\|.+\|\s*$', multiLine: true).allMatches(text).length >=
          2) {
    return true;
  }
  var weak = 0;
  if (_reBullet.hasMatch(text)) weak++;
  if (_reOrdered.hasMatch(text)) weak++;
  if (_reCode.hasMatch(text)) weak++;
  if (_reQuote.hasMatch(text)) weak++;
  return weak >= 2;
}

// ── Conversion ─────────────────────────────────────────────────────────────

/// Converts [markdown] into styled runs. [base] supplies the style for
/// unstyled text (the canvas' current text-tool defaults), mirroring
/// `runsFromHtml`. Returns an empty list when there's no visible text.
List<TextRun> runsFromMarkdown(String markdown, TextRun base) {
  final b = _MdBuilder(base);
  final lines =
      markdown.replaceAll('\r\n', '\n').replaceAll('\r', '\n').split('\n');

  var inFence = false;
  var prevBlank = true; // suppress leading blank lines

  // Consecutive |-delimited rows buffer up, then flush as column-padded mono
  // lines (mono makes the padding actually align — the readable degrade).
  final tableRows = <List<String>>[];
  void flushTable() {
    if (tableRows.isEmpty) return;
    final cols = tableRows.map((r) => r.length).reduce((a, c) => a > c ? a : c);
    final widths = List<int>.filled(cols, 0);
    for (final row in tableRows) {
      for (var i = 0; i < row.length; i++) {
        if (row[i].length > widths[i]) widths[i] = row[i].length;
      }
    }
    for (final row in tableRows) {
      final cells = [
        for (var i = 0; i < row.length; i++)
          i == row.length - 1 ? row[i] : row[i].padRight(widths[i]),
      ];
      b.emit(cells.join('  '), b.style(mono: true));
      b.newline();
    }
    tableRows.clear();
  }

  for (final rawLine in lines) {
    final line = rawLine.replaceAll('\t', '  ');

    if (!inFence) {
      final tr = _reTableRow.firstMatch(line);
      if (tr != null) {
        final cells =
            tr.group(1)!.split('|').map((c) => c.trim()).toList();
        // Alignment separator rows (|---|:--:|) carry no content — drop.
        if (!cells.every((c) => RegExp(r'^:?-{2,}:?$').hasMatch(c))) {
          tableRows.add(cells);
        }
        prevBlank = false;
        continue;
      }
      flushTable();
    }

    if (inFence) {
      if (RegExp(r'^\s*```').hasMatch(line)) {
        inFence = false;
      } else {
        b.emit(line, b.style(mono: true));
        b.newline();
      }
      continue;
    }
    if (RegExp(r'^\s*```').hasMatch(line)) {
      inFence = true;
      prevBlank = false;
      continue;
    }

    if (line.trim().isEmpty) {
      if (!prevBlank) b.newline(); // collapse blank runs, keep one separator
      prevBlank = true;
      continue;
    }
    prevBlank = false;

    final heading = RegExp(r'^(#{1,6})\s+(.*)$').firstMatch(line);
    if (heading != null) {
      final scale = switch (heading.group(1)!.length) {
        1 => 2.0,
        2 => 1.5,
        3 => 1.17,
        _ => 1.0, // h4–h6: bold at base size
      };
      b.inline(
        heading.group(2)!,
        b.style(fontSize: base.fontSize * scale, bold: true),
      );
      b.newline();
      continue;
    }

    if (RegExp(r'^\s*(-{3,}|\*{3,}|_{3,})\s*$').hasMatch(line)) {
      b.emit('──────────', b.style());
      b.newline();
      continue;
    }

    final item = RegExp(r'^(\s*)(?:([-*+])|(\d+)\.)\s+(.*)$').firstMatch(line);
    if (item != null) {
      final indent = '  ' * (item.group(1)!.length ~/ 2);
      var content = item.group(4)!;
      String glyph;
      // Tolerates "[]" with no inner space — common in hand-typed markdown.
      final task = RegExp(r'^\[([ xX]?)\]\s+(.*)$').firstMatch(content);
      if (task != null) {
        glyph = (task.group(1) == 'x' || task.group(1) == 'X') ? '☑ ' : '☐ ';
        content = task.group(2)!;
      } else if (item.group(3) != null) {
        glyph = '${item.group(3)}. ';
      } else {
        glyph = '• ';
      }
      b.emit('$indent$glyph', b.style());
      b.inline(content, b.style());
      b.newline();
      continue;
    }

    final quote = RegExp(r'^\s*>\s?(.*)$').firstMatch(line);
    if (quote != null) {
      b.emit('│ ', b.style());
      b.inline(quote.group(1)!, b.style(italic: true));
      b.newline();
      continue;
    }

    b.inline(line, b.style());
    b.newline();
  }
  flushTable();

  return b.finish();
}

/// Immutable style snapshot for the inline walk.
class _MdStyle {
  final double fontSize;
  final bool bold;
  final bool italic;
  final bool mono;
  final String? link;

  const _MdStyle({
    required this.fontSize,
    required this.bold,
    required this.italic,
    required this.mono,
    this.link,
  });

  _MdStyle copyWith({
    double? fontSize,
    bool? bold,
    bool? italic,
    bool? mono,
    String? link,
  }) => _MdStyle(
    fontSize: fontSize ?? this.fontSize,
    bold: bold ?? this.bold,
    italic: italic ?? this.italic,
    mono: mono ?? this.mono,
    link: link ?? this.link,
  );

  bool sameAs(_MdStyle o) =>
      fontSize == o.fontSize &&
      bold == o.bold &&
      italic == o.italic &&
      mono == o.mono &&
      link == o.link;
}

class _MdBuilder {
  final TextRun base;
  final _out = <TextRun>[];
  _MdStyle? _lastStyle;

  _MdBuilder(this.base);

  _MdStyle style({
    double? fontSize,
    bool bold = false,
    bool italic = false,
    bool mono = false,
    String? link,
  }) => _MdStyle(
    fontSize: fontSize ?? base.fontSize,
    bold: bold,
    italic: italic,
    mono: mono,
    link: link,
  );

  void emit(String text, _MdStyle s) {
    if (text.isEmpty) return;
    if (_out.isNotEmpty && _lastStyle != null && _lastStyle!.sameAs(s)) {
      _out.last.text += text;
    } else {
      _out.add(TextRun(
        text: text,
        fontSize: s.fontSize,
        bold: s.bold,
        italic: s.italic,
        color: base.color,
        fontFamily: s.mono ? 'mono' : base.fontFamily,
        link: s.link,
      ));
      _lastStyle = s;
    }
  }

  void newline() => emit('\n', style());

  static const _escapable = r'\*_`[]()#+-.!>';
  static final _linkRe = RegExp(r'\[([^\]\n]+)\]\(([^)\s]+)\)');

  /// Inline syntax within one line: `**bold**`/`__bold__`, `*italic*` /
  /// `_italic_` (nesting via recursion), `` `code` ``, `[label](url)`, and
  /// backslash escapes. Unmatched markers pass through literally.
  void inline(String text, _MdStyle s) {
    var i = 0;
    final buf = StringBuffer();
    void flush() {
      if (buf.isNotEmpty) {
        emit(buf.toString(), s);
        buf.clear();
      }
    }

    while (i < text.length) {
      final ch = text[i];
      if (ch == r'\' &&
          i + 1 < text.length &&
          _escapable.contains(text[i + 1])) {
        buf.write(text[i + 1]);
        i += 2;
        continue;
      }
      if (ch == '`') {
        final close = text.indexOf('`', i + 1);
        if (close > i + 1) {
          flush();
          emit(text.substring(i + 1, close), s.copyWith(mono: true));
          i = close + 1;
          continue;
        }
      }
      if (ch == '[') {
        final m = _linkRe.matchAsPrefix(text, i);
        if (m != null) {
          flush();
          emit(m.group(1)!, s.copyWith(link: m.group(2)));
          i = m.end;
          continue;
        }
      }
      // Emphasis follows CommonMark's flanking rule pragmatically: an opener
      // must be followed by a non-space, a closer preceded by one — so
      // "2 ** 3" and "5 * 6" stay literal.
      if (text.startsWith('**', i) || text.startsWith('__', i)) {
        final marker = text.substring(i, i + 2);
        if (i + 2 < text.length && text[i + 2] != ' ') {
          var close = text.indexOf(marker, i + 2);
          while (close > i + 2 && text[close - 1] == ' ') {
            close = text.indexOf(marker, close + 1);
          }
          // "**bold *both***": prefer the later pair so the inner single
          // marker stays with the nested italic.
          if (close > i + 2 &&
              close + 2 < text.length &&
              text[close + 2] == marker[0]) {
            close += 1;
          }
          if (close > i + 2) {
            flush();
            inline(text.substring(i + 2, close), s.copyWith(bold: true));
            i = close + 2;
            continue;
          }
        }
      }
      if (ch == '*' || ch == '_') {
        if (i + 1 < text.length && text[i + 1] != ' ' && text[i + 1] != ch) {
          var close = text.indexOf(ch, i + 1);
          while (close > i + 1 && text[close - 1] == ' ') {
            close = text.indexOf(ch, close + 1);
          }
          if (close > i + 1 &&
              text.substring(i + 1, close).trim().isNotEmpty) {
            flush();
            inline(text.substring(i + 1, close), s.copyWith(italic: true));
            i = close + 1;
            continue;
          }
        }
      }
      buf.write(ch);
      i++;
    }
    flush();
  }

  /// Trims trailing newline-only tail and returns the runs (empty when no
  /// visible text was produced).
  List<TextRun> finish() {
    while (_out.isNotEmpty) {
      _out.last.text = _out.last.text.replaceFirst(RegExp(r'\n+$'), '');
      if (_out.last.text.isEmpty) {
        _out.removeLast();
      } else {
        break;
      }
    }
    if (_out.every((r) => r.text.trim().isEmpty)) return [];
    return _out;
  }
}
