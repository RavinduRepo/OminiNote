import '../models/element.dart';

/// Matches http(s):// URLs and bare `www.` / domain-like tokens. Kept
/// deliberately simple (no full RFC 3986) — good enough to auto-link typed and
/// pasted addresses. Trailing sentence punctuation is trimmed in [_normalize].
final RegExp _urlPattern = RegExp(
  r'((https?:\/\/|www\.)[^\s]+|[a-zA-Z0-9-]+\.(com|org|net|io|dev|app|co|edu|gov)(\/[^\s]*)?)',
  caseSensitive: false,
);

/// Re-scans [runs], splitting each run's text at URL boundaries so URL
/// substrings become their own runs with [TextRun.link] set (and non-URL parts
/// get `link` cleared). Style (size/weight/family/color) is preserved on every
/// piece; the link *visuals* (underline + color) are applied at render time
/// based on `link != null`, so this never mutates a run's stored color.
///
/// Idempotent: running it again on already-split runs yields the same result.
List<TextRun> linkifyRuns(List<TextRun> runs) {
  final out = <TextRun>[];
  for (final run in runs) {
    // Internal (Connections) links are set deliberately — their display text
    // is arbitrary (never URL-shaped), so the re-scan below would CLEAR them.
    // Pass them through untouched.
    if (run.link?.startsWith('omninote://') ?? false) {
      out.add(run);
      continue;
    }
    final text = run.text;
    if (text.isEmpty) {
      out.add(run..link = null);
      continue;
    }
    var last = 0;
    for (final m in _urlPattern.allMatches(text)) {
      // Text before the URL keeps the run's style, no link.
      if (m.start > last) {
        out.add(run.clone()
          ..text = text.substring(last, m.start)
          ..link = null);
      }
      final raw = text.substring(m.start, m.end);
      final (visible, trimmed) = _splitTrailing(raw);
      out.add(run.clone()
        ..text = visible
        ..link = _normalize(visible));
      // Any trailing punctuation trimmed off the URL rejoins as plain text.
      if (trimmed.isNotEmpty) {
        out.add(run.clone()
          ..text = trimmed
          ..link = null);
      }
      last = m.end;
    }
    if (last < text.length) {
      out.add(run.clone()
        ..text = text.substring(last)
        ..link = null);
    }
  }
  final merged = _mergeAdjacent(out);
  // If the whole box is a link, tapping anywhere would open it and leave no
  // way to place the caret (edit) or grab the box (move). Append a trailing
  // space run (non-link) so there's always a grabbable, editable spot. This is
  // idempotent — once the space exists, the box is no longer all-link.
  if (merged.isNotEmpty && merged.every((r) => r.link != null)) {
    merged.add(merged.last.clone()
      ..text = ' '
      ..link = null);
  }
  return merged;
}

/// The first URL in [text], normalized (with scheme), or null if none.
String? firstUrlIn(String text) {
  final m = _urlPattern.firstMatch(text);
  if (m == null) return null;
  final (visible, _) = _splitTrailing(text.substring(m.start, m.end));
  return _normalize(visible);
}

/// Splits trailing sentence punctuation (`.`, `,`, `)`, etc.) off a matched URL
/// so "see (https://x.com)." links just the address.
(String, String) _splitTrailing(String raw) {
  const trailing = '.,;:!?)]}\'"';
  var end = raw.length;
  while (end > 0 && trailing.contains(raw[end - 1])) {
    end--;
  }
  return (raw.substring(0, end), raw.substring(end));
}

/// Ensures a scheme so `url_launcher` can open it.
String _normalize(String url) {
  if (url.startsWith(RegExp(r'https?:\/\/', caseSensitive: false))) return url;
  return 'https://$url';
}

/// Coalesces neighbouring runs that share identical style + link, keeping the
/// run list minimal (so this stays idempotent across repeated calls).
List<TextRun> _mergeAdjacent(List<TextRun> runs) {
  final out = <TextRun>[];
  for (final r in runs) {
    if (r.text.isEmpty) continue;
    final prev = out.isEmpty ? null : out.last;
    if (prev != null &&
        prev.link == r.link &&
        prev.fontSize == r.fontSize &&
        prev.bold == r.bold &&
        prev.italic == r.italic &&
        prev.fontFamily == r.fontFamily &&
        prev.color.toARGB32() == r.color.toARGB32()) {
      prev.text += r.text;
    } else {
      out.add(r);
    }
  }
  return out;
}
