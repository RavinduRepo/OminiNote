import 'dart:ui' show Color;
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' show parseFragment;
import '../models/element.dart';

/// HTML ⇄ styled [TextRun]s, so pasted rich text (browser/Word/OneNote HTML on
/// the clipboard) keeps its formatting instead of flattening to plain text.
///
/// Scope is inline text styling — bold/italic/color/size/family, headings,
/// line breaks, and lists (as the app's plain-glyph "• " prefixes). Tables
/// degrade to space-separated cells; images/nested block layout are ignored
/// (see CANVAS_SPEC §7.5).

/// Converts an HTML fragment into styled runs. [base] supplies the style for
/// unstyled text (the canvas' current text-tool defaults). Returns an empty
/// list when the HTML holds no visible text.
List<TextRun> runsFromHtml(String html, TextRun base) {
  final fragment = parseFragment(html);
  final walker = _HtmlWalker(
    _RunStyle(
      fontSize: base.fontSize,
      bold: base.bold,
      italic: base.italic,
      color: base.color,
      fontFamily: base.fontFamily,
    ),
  );
  walker.walkChildren(fragment.nodes, walker.baseStyle, preformatted: false);
  return walker.finish();
}

/// Serializes runs back to a minimal HTML fragment (one styled `<span>` per
/// run, `<br>` for newlines) so copied canvas text pastes rich elsewhere.
String htmlFromRuns(List<TextRun> runs) {
  final buf = StringBuffer();
  for (final r in runs) {
    final family = switch (r.fontFamily) {
      'serif' => 'Georgia, serif',
      'mono' => "'Courier New', monospace",
      _ => 'sans-serif',
    };
    final styles = [
      'font-size:${_trimNum(r.fontSize)}px',
      'color:#${(r.color.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}',
      'font-family:$family',
      if (r.bold) 'font-weight:bold',
      if (r.italic) 'font-style:italic',
    ];
    final text = _escapeHtml(r.text).replaceAll('\n', '<br>');
    buf.write('<span style="${styles.join(';')}">$text</span>');
  }
  return buf.toString();
}

String _trimNum(double v) =>
    v == v.roundToDouble() ? v.round().toString() : v.toString();

String _escapeHtml(String s) =>
    s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');

/// Immutable style snapshot carried down the DOM walk.
class _RunStyle {
  final double fontSize;
  final bool bold;
  final bool italic;
  final Color color;
  final String fontFamily; // 'sans' | 'serif' | 'mono'

  const _RunStyle({
    required this.fontSize,
    required this.bold,
    required this.italic,
    required this.color,
    required this.fontFamily,
  });

  _RunStyle copyWith({
    double? fontSize,
    bool? bold,
    bool? italic,
    Color? color,
    String? fontFamily,
  }) => _RunStyle(
    fontSize: fontSize ?? this.fontSize,
    bold: bold ?? this.bold,
    italic: italic ?? this.italic,
    color: color ?? this.color,
    fontFamily: fontFamily ?? this.fontFamily,
  );

  TextRun toRun(String text) => TextRun(
    text: text,
    fontSize: fontSize,
    bold: bold,
    italic: italic,
    color: color,
    fontFamily: fontFamily,
  );
}

const _skipTags = {
  'script',
  'style',
  'head',
  'meta',
  'link',
  'title',
  'template',
  'noscript',
  'img',
  'svg',
  'button',
  'input',
  'select',
};

const _blockTags = {
  'p',
  'div',
  'section',
  'article',
  'header',
  'footer',
  'main',
  'aside',
  'h1',
  'h2',
  'h3',
  'h4',
  'h5',
  'h6',
  'ul',
  'ol',
  'li',
  'blockquote',
  'pre',
  'table',
  'tr',
  'hr',
  'figure',
  'figcaption',
  'dl',
  'dt',
  'dd',
};

/// CSS-default heading scales, relative to the base font size.
const _headingScale = {
  'h1': 2.0,
  'h2': 1.5,
  'h3': 1.17,
  'h4': 1.0,
  'h5': 0.83,
  'h6': 0.67,
};

class _HtmlWalker {
  final _RunStyle baseStyle;
  final _out = <TextRun>[];

  /// Open list nesting: `ordered` + the next item number for `<ol>`.
  final _lists = <({bool ordered, int counter})>[];

  /// Set right after a `<li>` glyph prefix so the item's own block child
  /// doesn't push the content onto the next line.
  bool _suppressNextBreak = false;

  _HtmlWalker(this.baseStyle);

  bool _empty = true;
  bool _endsNewline = false;
  bool _endsSpace = false;

  bool get _atLineStart => _empty || _endsNewline;

  void _emit(String text, _RunStyle style) {
    if (text.isEmpty) return;
    _out.add(style.toRun(text));
    _empty = false;
    _endsNewline = text.endsWith('\n');
    _endsSpace = text.endsWith(' ');
  }

  void _recomputeEnds() {
    if (_out.isEmpty) {
      _empty = true;
      _endsNewline = false;
      _endsSpace = false;
      return;
    }
    final t = _out.last.text;
    _empty = false;
    _endsNewline = t.endsWith('\n');
    _endsSpace = t.endsWith(' ');
  }

  /// A line break is coming: collapsed inline spaces before it are not
  /// rendered by browsers, so drop them.
  void _trimTrailingSpaces() {
    while (_out.isNotEmpty) {
      _out.last.text = _out.last.text.replaceFirst(RegExp(r' +$'), '');
      if (_out.last.text.isEmpty) {
        _out.removeLast();
      } else {
        break;
      }
    }
    _recomputeEnds();
  }

  void _emitBreak(_RunStyle style) {
    _trimTrailingSpaces();
    _emit('\n', style);
  }

  void _ensureBreak(_RunStyle style) {
    if (_suppressNextBreak) {
      _suppressNextBreak = false;
      return;
    }
    _trimTrailingSpaces();
    if (!_atLineStart) _emit('\n', style);
  }

  void walkChildren(
    List<dom.Node> nodes,
    _RunStyle style, {
    required bool preformatted,
  }) {
    for (final node in nodes) {
      if (node is dom.Text) {
        _emitText(node.data, style, preformatted: preformatted);
      } else if (node is dom.Element) {
        _walkElement(node, style, preformatted: preformatted);
      }
      // Comments/doctype/etc. are skipped.
    }
  }

  void _emitText(String raw, _RunStyle style, {required bool preformatted}) {
    if (preformatted) {
      _emit(raw.replaceAll('\r\n', '\n').replaceAll('\t', '    '), style);
      return;
    }
    // CSS whitespace collapsing: runs of whitespace become one space; a space
    // at the start of a line — or right after an already-emitted space — is
    // dropped so spaces never double up across node boundaries.
    var text = raw.replaceAll(RegExp(r'[ \t\r\n\f]+'), ' ');
    if (text.startsWith(' ') && (_atLineStart || _endsSpace)) {
      text = text.substring(1);
    }
    if (text.isEmpty) return;
    _emit(text, style);
  }

  void _walkElement(
    dom.Element el,
    _RunStyle style, {
    required bool preformatted,
  }) {
    final tag = el.localName ?? '';
    if (_skipTags.contains(tag)) return;

    var s = style;

    // Tag-implied styling (a style="" attribute below can still override).
    switch (tag) {
      case 'b' || 'strong':
        s = s.copyWith(bold: true);
      case 'i' || 'em':
        s = s.copyWith(italic: true);
      case 'code' || 'tt' || 'kbd' || 'samp' || 'pre':
        s = s.copyWith(fontFamily: 'mono');
      case 'sub' || 'sup':
        s = s.copyWith(fontSize: (s.fontSize * 0.75).clamp(6, 96));
      case 'a':
        s = s.copyWith(color: const Color(0xFF3B7DD8));
      case 'font':
        final c = _parseCssColor(el.attributes['color'] ?? '');
        if (c != null) s = s.copyWith(color: c);
    }
    final heading = _headingScale[tag];
    if (heading != null) {
      s = s.copyWith(
        bold: true,
        fontSize: (baseStyle.fontSize * heading).clamp(6, 96),
      );
    }

    s = _applyCssStyle(s, el.attributes['style']);

    final isBlock = _blockTags.contains(tag);
    if (tag == 'br') {
      _emitBreak(s);
      return;
    }
    if (tag == 'hr') {
      _ensureBreak(s);
      return;
    }
    if (isBlock) _ensureBreak(s);

    // Cells inside a row: separate from the previous cell with two spaces
    // (tables degrade to space-separated text).
    if ((tag == 'td' || tag == 'th') && !_atLineStart) _emit('  ', s);

    if (tag == 'ul' || tag == 'ol') {
      _lists.add((ordered: tag == 'ol', counter: 1));
    }
    if (tag == 'li') {
      final depth = _lists.isEmpty ? 1 : _lists.length;
      final indent = '  ' * (depth - 1);
      String glyph;
      if (_lists.isNotEmpty && _lists.last.ordered) {
        final n = _lists.last.counter;
        _lists.last = (ordered: true, counter: n + 1);
        glyph = '$n. ';
      } else {
        glyph = '• ';
      }
      _emit('$indent$glyph', s);
      _suppressNextBreak = true; // a block child of the li stays on this line
    }

    walkChildren(el.nodes, s, preformatted: preformatted || tag == 'pre');

    if (tag == 'ul' || tag == 'ol') _lists.removeLast();
    if (isBlock) {
      _suppressNextBreak = false;
      _ensureBreak(s);
    }
  }

  /// Merges adjacent same-style runs, trims leading/trailing blank space, and
  /// returns the final list (empty when there's no visible text).
  List<TextRun> finish() {
    // Trim leading newlines/spaces off the front…
    while (_out.isNotEmpty) {
      _out.first.text = _out.first.text.replaceFirst(RegExp(r'^[\n ]+'), '');
      if (_out.first.text.isEmpty) {
        _out.removeAt(0);
      } else {
        break;
      }
    }
    // …and trailing whitespace off the back.
    while (_out.isNotEmpty) {
      _out.last.text = _out.last.text.replaceFirst(RegExp(r'[\n ]+$'), '');
      if (_out.last.text.isEmpty) {
        _out.removeLast();
      } else {
        break;
      }
    }

    final merged = <TextRun>[];
    for (final run in _out) {
      final prev = merged.isEmpty ? null : merged.last;
      if (prev != null &&
          prev.fontSize == run.fontSize &&
          prev.bold == run.bold &&
          prev.italic == run.italic &&
          prev.color == run.color &&
          prev.fontFamily == run.fontFamily) {
        prev.text += run.text;
      } else {
        merged.add(run);
      }
    }
    if (merged.every((r) => r.text.trim().isEmpty)) return [];
    return merged;
  }

  _RunStyle _applyCssStyle(_RunStyle s, String? css) {
    if (css == null || css.isEmpty) return s;
    for (final decl in css.split(';')) {
      final i = decl.indexOf(':');
      if (i <= 0) continue;
      final prop = decl.substring(0, i).trim().toLowerCase();
      final value = decl.substring(i + 1).trim().toLowerCase();
      switch (prop) {
        case 'color':
          final c = _parseCssColor(value);
          if (c != null) s = s.copyWith(color: c);
        case 'font-weight':
          final n = int.tryParse(value);
          if (n != null) {
            s = s.copyWith(bold: n >= 600);
          } else if (value == 'bold' || value == 'bolder') {
            s = s.copyWith(bold: true);
          } else if (value == 'normal' || value == 'lighter') {
            s = s.copyWith(bold: false);
          }
        case 'font-style':
          if (value == 'italic' || value == 'oblique') {
            s = s.copyWith(italic: true);
          } else if (value == 'normal') {
            s = s.copyWith(italic: false);
          }
        case 'font-size':
          final size = _parseCssFontSize(value, s.fontSize);
          if (size != null) s = s.copyWith(fontSize: size.clamp(6, 96));
        case 'font-family':
          if (RegExp(r'mono|courier|consolas|menlo').hasMatch(value)) {
            s = s.copyWith(fontFamily: 'mono');
          } else if (value.contains('serif') && !value.contains('sans')) {
            s = s.copyWith(fontFamily: 'serif');
          } else if (value.contains('sans')) {
            s = s.copyWith(fontFamily: 'sans');
          }
      }
    }
    return s;
  }

  /// Parses a CSS font-size into the app's units (browser default 16px maps
  /// to the app default 16). Returns null when unparseable.
  double? _parseCssFontSize(String value, double current) {
    const keywords = {
      'xx-small': 9.0,
      'x-small': 10.0,
      'small': 13.0,
      'medium': 16.0,
      'large': 18.0,
      'x-large': 24.0,
      'xx-large': 32.0,
    };
    final kw = keywords[value];
    if (kw != null) return kw;
    final m = RegExp(r'^([\d.]+)(px|pt|em|rem|%)?$').firstMatch(value);
    if (m == null) return null;
    final n = double.tryParse(m.group(1)!);
    if (n == null || n <= 0) return null;
    return switch (m.group(2)) {
      'pt' => n * 4 / 3,
      'em' || 'rem' => current * n,
      '%' => current * n / 100,
      _ => n, // px or unitless
    };
  }
}

const _namedColors = {
  'black': 0xFF000000,
  'white': 0xFFFFFFFF,
  'red': 0xFFFF0000,
  'green': 0xFF008000,
  'blue': 0xFF0000FF,
  'yellow': 0xFFFFFF00,
  'orange': 0xFFFFA500,
  'purple': 0xFF800080,
  'pink': 0xFFFFC0CB,
  'gray': 0xFF808080,
  'grey': 0xFF808080,
  'brown': 0xFFA52A2A,
  'cyan': 0xFF00FFFF,
  'magenta': 0xFFFF00FF,
  'silver': 0xFFC0C0C0,
  'maroon': 0xFF800000,
  'olive': 0xFF808000,
  'lime': 0xFF00FF00,
  'aqua': 0xFF00FFFF,
  'teal': 0xFF008080,
  'navy': 0xFF000080,
  'fuchsia': 0xFFFF00FF,
  'gold': 0xFFFFD700,
  'indigo': 0xFF4B0082,
  'violet': 0xFFEE82EE,
  'darkred': 0xFF8B0000,
  'darkblue': 0xFF00008B,
  'darkgreen': 0xFF006400,
};

Color? _parseCssColor(String raw) {
  final value = raw.trim().toLowerCase();
  if (value.isEmpty || value == 'transparent' || value == 'inherit') {
    return null;
  }
  final named = _namedColors[value];
  if (named != null) return Color(named);

  if (value.startsWith('#')) {
    final hex = value.substring(1);
    if (hex.length == 3 || hex.length == 4) {
      final r = hex[0], g = hex[1], b = hex[2];
      final v = int.tryParse('$r$r$g$g$b$b', radix: 16);
      return v == null ? null : Color(0xFF000000 | v);
    }
    if (hex.length == 6) {
      final v = int.tryParse(hex, radix: 16);
      return v == null ? null : Color(0xFF000000 | v);
    }
    if (hex.length == 8) {
      // #rrggbbaa → keep rgb, ignore alpha (canvas text is opaque).
      final v = int.tryParse(hex.substring(0, 6), radix: 16);
      return v == null ? null : Color(0xFF000000 | v);
    }
    return null;
  }

  final rgb = RegExp(
    r'^rgba?\(\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)',
  ).firstMatch(value);
  if (rgb != null) {
    final r = int.parse(rgb.group(1)!).clamp(0, 255);
    final g = int.parse(rgb.group(2)!).clamp(0, 255);
    final b = int.parse(rgb.group(3)!).clamp(0, 255);
    return Color(0xFF000000 | (r << 16) | (g << 8) | b);
  }
  return null;
}
