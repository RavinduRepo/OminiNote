import 'dart:ui';

import '../models/canvas.dart';
import '../models/canvas_page.dart';
import '../models/element.dart';

/// One chunk of readable text discovered on a page, together with where it sits
/// (page-local PDF points) and which element produced it.
///
/// This is the single currency of the read-aloud pipeline. Every kind of
/// content that can yield text — typed text boxes today, imported-PDF text
/// today, and *image OCR / handwriting OCR in the future* — is exposed as a
/// [PageTextSource] that emits [ReadableSpan]s. To teach the reader a new
/// source, implement one class and register it in the reader's source list;
/// nothing else changes.
///
/// [bounds] and [sourceId] are carried so a future "read-along" highlight can
/// glow the span currently being spoken (mirroring the audio-sync ink glow),
/// but they are optional — a source that has no position (`bounds == null`)
/// still reads fine, it just sorts after the positioned spans on its page.
class ReadableSpan {
  /// The text to read. May contain multiple sentences/lines.
  final String text;

  /// Page-local bounds in PDF points, or null when position is unknown.
  final Rect? bounds;

  /// The producing element's id (or a synthetic tag like `'pdf'`), for the
  /// read-along highlight. Not required for speech.
  final String? sourceId;

  /// For a source whose text was assembled from several positioned lines (a PDF
  /// page), the per-line boxes with each line's start offset in [text]. Lets the
  /// sentence-splitter map any character range back to the exact line rects it
  /// covers — so a sentence that flows across wrapped PDF lines highlights all
  /// of them. Null for single-box sources (typed text uses its element instead).
  final List<SpanLineBox>? lineBoxes;

  const ReadableSpan(this.text, {this.bounds, this.sourceId, this.lineBoxes});
}

/// One laid-out line inside a multi-line span: the character offset in the
/// span's text where the line begins, and its page-local rect.
class SpanLineBox {
  final int start;
  final Rect rect;
  const SpanLineBox(this.start, this.rect);
}

/// One atomic thing the reader speaks: a single utterance of [text], tagged with
/// the [pageId] it came from (so the reader can bring that page into view) and
/// the originating [sourceId]/[bounds] (read-along highlight). One [ReadableSpan]
/// is split into several [ReadingUnit]s at sentence boundaries so pause/skip and
/// highlighting stay granular.
///
/// [charStart]/[charEnd] are this sentence's character range *within the source
/// span's text*. For a typed-text span the span text is exactly the element's
/// text, so the range maps straight onto the [TextElement] (used to compute the
/// on-canvas highlight and to resolve a tap on the box back to this unit).
class ReadingUnit {
  final String text;
  final String pageId;
  final String? sourceId;
  final Rect? bounds;
  final int charStart;
  final int charEnd;

  /// Precomputed page-local highlight rects for this sentence, when the source
  /// already knows them (a PDF sentence → the wrapped-line rects it covers).
  /// Empty for typed text, whose rects are computed from its element on demand.
  final List<Rect> rects;

  const ReadingUnit({
    required this.text,
    required this.pageId,
    this.sourceId,
    this.bounds,
    this.charStart = 0,
    this.charEnd = 0,
    this.rects = const [],
  });
}

/// A producer of readable text for a page. Concrete sources hold whatever they
/// need (e.g. a PDF text extractor) in their constructor; the reader just asks
/// each registered source for spans and merges the results.
///
/// Future OCR sources (image text, handwriting recognition) implement exactly
/// this interface — that's the whole extensibility contract.
abstract class PageTextSource {
  Future<List<ReadableSpan>> spansFor(CanvasPage page);
}

/// Reads the typed [TextElement]s on a page. Pure — no plugins — so the common
/// case (typed notes) needs nothing asynchronous and is fully unit-testable.
class TypedTextSource implements PageTextSource {
  const TypedTextSource();

  @override
  Future<List<ReadableSpan>> spansFor(CanvasPage page) async {
    final spans = <ReadableSpan>[];
    for (final el in page.objects) {
      if (el is TextElement) {
        if (el.text.trim().isEmpty) continue;
        spans.add(ReadableSpan(el.text, bounds: el.rect, sourceId: el.id));
      }
    }
    return spans;
  }
}

/// Vertical overlap (in points) below which two spans are treated as being on
/// the same visual line and ordered left-to-right instead of top-to-bottom.
const double _kRowBandTolerance = 6;

/// Orders spans into natural reading order: top-to-bottom, and left-to-right
/// among spans that sit on roughly the same line. Spans without [bounds] keep
/// their original relative order and sort *after* all positioned spans (a
/// source that can't localize its text — e.g. a whole-page PDF extraction —
/// reads as a block).
List<ReadableSpan> orderSpansForReading(List<ReadableSpan> spans) {
  final positioned = <ReadableSpan>[];
  final unpositioned = <ReadableSpan>[];
  for (final s in spans) {
    (s.bounds == null ? unpositioned : positioned).add(s);
  }
  positioned.sort((a, b) {
    final ab = a.bounds!, bb = b.bounds!;
    // Same line (tops within tolerance) → left-to-right; else top-to-bottom.
    if ((ab.top - bb.top).abs() <= _kRowBandTolerance) {
      return ab.left.compareTo(bb.left);
    }
    return ab.top.compareTo(bb.top);
  });
  return [...positioned, ...unpositioned];
}

/// Keep sentence-ending punctuation with its sentence; also grab a trailing
/// closing quote/paren so "…done." ) doesn't strand a fragment.
final _kSentence = RegExp(r'[^.!?\n]+[.!?]*[")\]’”]*');

/// Splits [text] into sentence-sized utterances, each paired with the character
/// offset (`.$2`) at which it starts *within [text]* — so a highlight/tap can
/// map a sentence back to its exact character range. Newlines always break;
/// within a line, runs ending in `.`/`!`/`?` (plus trailing quotes/brackets)
/// become separate utterances. Empty pieces are dropped.
List<(String, int)> splitIntoUtterancesWithOffsets(String text) {
  final out = <(String, int)>[];
  var lineOffset = 0;
  for (final line in text.split('\n')) {
    final matches = _kSentence.allMatches(line).toList();
    if (matches.isEmpty) {
      final trimmed = line.trim();
      if (trimmed.isNotEmpty) {
        out.add((trimmed, lineOffset + (line.length - line.trimLeft().length)));
      }
    } else {
      for (final m in matches) {
        final raw = m.group(0)!;
        final trimmed = raw.trim();
        if (trimmed.isEmpty) continue;
        final leading = raw.length - raw.trimLeft().length;
        out.add((trimmed, lineOffset + m.start + leading));
      }
    }
    lineOffset += line.length + 1; // +1 for the consumed '\n'
  }
  return out;
}

/// The utterance texts only (offsets dropped) — the plain sentence split.
List<String> splitIntoUtterances(String text) =>
    [for (final u in splitIntoUtterancesWithOffsets(text)) u.$1];

/// Best-effort per-utterance language detection by Unicode script, so the
/// reader can auto-switch to a matching installed voice for non-Latin text
/// (e.g. Sinhala, Tamil, Arabic) even when the user has manually pinned a
/// different voice for their primary language. Returns an ISO 639-1 code, or
/// null when the text is Latin-script or too short to have a clear script
/// majority — Latin covers dozens of languages, so no code is a safe guess
/// there and the manually-selected/default voice is left alone.
String? detectScriptLanguage(String text) {
  final counts = <String, int>{};
  var total = 0;
  for (final rune in text.runes) {
    final lang = _scriptLanguageOf(rune);
    if (lang == null) continue;
    total++;
    counts[lang] = (counts[lang] ?? 0) + 1;
  }
  if (total < 3) return null; // too little non-Latin signal to trust
  var bestLang = '';
  var bestCount = 0;
  for (final entry in counts.entries) {
    if (entry.value > bestCount) {
      bestLang = entry.key;
      bestCount = entry.value;
    }
  }
  return bestCount / total >= 0.6 ? bestLang : null;
}

/// The ISO 639-1 language a single code point's Unicode block belongs to, for
/// scripts that map cleanly onto one common language — null for Latin (and
/// anything else not listed) since that's shared across too many languages.
String? _scriptLanguageOf(int r) {
  if (r >= 0x0D80 && r <= 0x0DFF) return 'si'; // Sinhala
  if (r >= 0x0B80 && r <= 0x0BFF) return 'ta'; // Tamil
  if (r >= 0x0C00 && r <= 0x0C7F) return 'te'; // Telugu
  if (r >= 0x0C80 && r <= 0x0CFF) return 'kn'; // Kannada
  if (r >= 0x0D00 && r <= 0x0D7F) return 'ml'; // Malayalam
  if (r >= 0x0980 && r <= 0x09FF) return 'bn'; // Bengali
  if (r >= 0x0A80 && r <= 0x0AFF) return 'gu'; // Gujarati
  if (r >= 0x0A00 && r <= 0x0A7F) return 'pa'; // Punjabi (Gurmukhi)
  if (r >= 0x0900 && r <= 0x097F) return 'hi'; // Devanagari (Hindi etc.)
  if ((r >= 0x0600 && r <= 0x06FF) || (r >= 0x0750 && r <= 0x077F)) return 'ar';
  if (r >= 0x0590 && r <= 0x05FF) return 'he'; // Hebrew
  if (r >= 0x0E00 && r <= 0x0E7F) return 'th'; // Thai
  if (r >= 0x1780 && r <= 0x17FF) return 'km'; // Khmer
  if (r >= 0x1000 && r <= 0x109F) return 'my'; // Myanmar
  if (r >= 0x3040 && r <= 0x30FF) return 'ja'; // Hiragana/Katakana
  if (r >= 0xAC00 && r <= 0xD7A3) return 'ko'; // Hangul
  if (r >= 0x4E00 && r <= 0x9FFF) return 'zh'; // CJK ideographs
  if (r >= 0x0400 && r <= 0x04FF) return 'ru'; // Cyrillic
  if (r >= 0x0370 && r <= 0x03FF) return 'el'; // Greek
  return null;
}

/// The page ids to read, in document order. When [mainColumnOnly] is true only
/// the first page of each row is read (the "vertical pages only" scope), so
/// horizontal continuation pages are skipped; otherwise every page is read
/// row-major (each row left-to-right, then the next row down).
List<String> readingOrderPageIds(Canvas canvas, {required bool mainColumnOnly}) {
  final ids = <String>[];
  for (final row in canvas.rows) {
    if (row.pageIds.isEmpty) continue;
    if (mainColumnOnly) {
      ids.add(row.pageIds.first);
    } else {
      ids.addAll(row.pageIds);
    }
  }
  return ids;
}

/// Turns a page's already-ordered [spans] into the flat list of reading units
/// (one per sentence), tagging each with [pageId]. Pure helper shared by the
/// reader and its tests.
List<ReadingUnit> readingUnitsForPage(String pageId, List<ReadableSpan> spans) {
  final units = <ReadingUnit>[];
  for (final span in spans) {
    for (final (sentence, start) in splitIntoUtterancesWithOffsets(span.text)) {
      final end = start + sentence.length;
      units.add(ReadingUnit(
        text: sentence,
        pageId: pageId,
        sourceId: span.sourceId,
        bounds: span.bounds,
        charStart: start,
        charEnd: end,
        rects: _lineRectsForRange(span.lineBoxes, span.text.length, start, end),
      ));
    }
  }
  return units;
}

/// The line rects whose character span overlaps `[a, b)` — i.e. every wrapped
/// line the sentence touches. Empty when the span has no line boxes (typed text).
List<Rect> _lineRectsForRange(
    List<SpanLineBox>? boxes, int spanLen, int a, int b) {
  if (boxes == null || boxes.isEmpty) return const [];
  final out = <Rect>[];
  for (var i = 0; i < boxes.length; i++) {
    final lineStart = boxes[i].start;
    final lineEnd = i + 1 < boxes.length ? boxes[i + 1].start : spanLen;
    if (lineStart < b && lineEnd > a) out.add(boxes[i].rect);
  }
  return out;
}
