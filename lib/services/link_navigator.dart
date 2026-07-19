import 'search_service.dart';

/// Bridges "navigate to this link target" to whichever shell is on screen.
///
/// Both shells already know how to reveal a [SearchResult] in place (drill-in
/// stack / pane selection + glow) — they register that same handler here on
/// init, so a tapped connection anywhere (a Connections sheet, later a text
/// hyperlink) navigates exactly like picking a search result.
class LinkNavigator {
  static final LinkNavigator _instance = LinkNavigator._internal();
  factory LinkNavigator() => _instance;
  LinkNavigator._internal();

  void Function(SearchResult r)? _reveal;

  /// Called by the active shell on init. The shell must [unregister] with the
  /// same handler on dispose (guarded, so a stale dispose can't clear a newer
  /// shell's registration when layout mode flips).
  void register(void Function(SearchResult r) reveal) => _reveal = reveal;

  void unregister(void Function(SearchResult r) reveal) {
    if (identical(_reveal, reveal)) _reveal = null;
  }

  /// Reveals [r] via the active shell; false when no shell is registered.
  bool reveal(SearchResult r) {
    final h = _reveal;
    if (h == null) return false;
    h(r);
    return true;
  }

  /// One-shot handoff for element-endpoint navigation: set just before a
  /// reveal (or a same-canvas jump), consumed by the target CanvasScreen once
  /// its pages have loaded — which then scrolls to the elements and flashes
  /// them. A plain field (not part of [SearchResult]) so the search model
  /// stays untouched.
  ({String canvasId, String pageId, List<String> elementIds})?
      pendingElementFocus;

  /// Consumes and returns the pending focus if it targets [canvasId].
  ({String pageId, List<String> elementIds})? takeFocusFor(String canvasId) {
    final f = pendingElementFocus;
    if (f == null || f.canvasId != canvasId) return null;
    pendingElementFocus = null;
    return (pageId: f.pageId, elementIds: f.elementIds);
  }
}
