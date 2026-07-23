import '../models/element.dart';

/// A *standalone link marker* — the on-canvas element that visualizes a
/// Connection: a [TextElement] whose visible content is exactly one hyperlink
/// (a single link run, plus any whitespace-only runs). Dropped by
/// `CanvasController.insertLinkItem` / `NotebookService.addLinkMarkerToPage`.
///
/// Returns the marker's link URI, or null when [el] isn't a standalone marker —
/// not a text element, carries non-link text, or mixes two different links. An
/// inline `[[`-style link inside a bigger text box is deliberately NOT one, so
/// coupling a connection's lifecycle to its marker never deletes real content
/// (Model A: markers and connections live and die together, but only the
/// dedicated marker element does).
String? standaloneMarkerUri(CanvasElement el) {
  if (el is! TextElement) return null;
  String? link;
  for (final r in el.runs) {
    final hasLink = r.link != null && r.link!.isNotEmpty;
    if (hasLink) {
      if (link != null && link != r.link) return null; // two different links
      link = r.link;
    } else if (r.text.trim().isNotEmpty) {
      return null; // real (non-whitespace, non-link) text → not standalone
    }
  }
  return link;
}
