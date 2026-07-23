import 'package:flutter/material.dart';

/// Describes one customizable app-bar action for the "Customize toolbar"
/// sheet's pickable-item list — icon/label only (display metadata). The
/// actual live button (which may show a different icon/label depending on
/// state, e.g. the shape-snap checkbox glyph) is built by the host screen's
/// own per-id dispatch, not from this spec.
class ToolbarActionSpec {
  final String id;
  final IconData icon;
  final String label;
  const ToolbarActionSpec(this.id, this.icon, this.label);
}

/// The three always-present chrome buttons that used to be hardcoded into the
/// toolbar (undo, redo, and the "+" Add control). They're now ordinary
/// promotable/reorderable actions like everything else — the only button that
/// can never be removed or reordered out is the "⋯" overflow menu itself.
/// 'add' promotes the whole "+" control (a dropdown/sheet of the add actions);
/// when it isn't on the bar the add actions are reached through the "⋯" menu's
/// "Add…" entry instead.
const List<ToolbarActionSpec> kCoreActionSpecs = [
  ToolbarActionSpec('undo', Icons.undo, 'Undo'),
  ToolbarActionSpec('redo', Icons.redo, 'Redo'),
  ToolbarActionSpec('add', Icons.add, 'Add menu (＋)'),
];

/// Customizable actions that originate from the "+" (Add) menu. Conditional-
/// existence items ('camera' — mobile-only; 'pastePage' — only when a page
/// is on the clipboard) are deliberately excluded: promoting something that
/// might not exist on this platform/moment to a fixed bar slot isn't a good
/// fit, so they always stay inside the "+" menu.
const List<ToolbarActionSpec> kAddActionSpecs = [
  ToolbarActionSpec('blank', Icons.note_add_outlined, 'Add page'),
  ToolbarActionSpec('horizontal', Icons.swap_horiz, 'Horizontal page'),
  ToolbarActionSpec('pdf', Icons.picture_as_pdf_outlined, 'Insert PDF'),
  ToolbarActionSpec('image', Icons.image_outlined, 'Insert image'),
  ToolbarActionSpec('paste', Icons.content_paste, 'Paste'),
  // Audio capture/playback are content additions, so they live in the "+"
  // menu alongside the other insert actions.
  ToolbarActionSpec('record_audio', Icons.mic_none, 'Record audio'),
  ToolbarActionSpec('import_audio', Icons.audio_file_outlined, 'Import audio'),
  ToolbarActionSpec('recordings', Icons.graphic_eq, 'Recordings'),
];

/// Customizable actions that originate from the "⋯" (overflow) menu.
const List<ToolbarActionSpec> kOverflowActionSpecs = [
  ToolbarActionSpec('fullscreen', Icons.fullscreen, 'Full screen'),
  ToolbarActionSpec('toggle_toolbar', Icons.brush_outlined, 'Show/hide tools'),
  ToolbarActionSpec('export', Icons.picture_as_pdf_outlined, 'Export PDF'),
  ToolbarActionSpec('navigator', Icons.grid_view_outlined, 'Pages'),
  ToolbarActionSpec('bookmarks', Icons.bookmark_border, 'Bookmarks'),
  ToolbarActionSpec('attachments', Icons.attach_file, 'Attachments'),
  ToolbarActionSpec(
      'page_settings', Icons.description_outlined, 'Page settings'),
  ToolbarActionSpec('shape_snap', Icons.check_box_outlined, 'Snap drawn shapes'),
  ToolbarActionSpec('finger_draw', Icons.check_box_outlined, 'Draw with finger'),
  ToolbarActionSpec(
      'split', Icons.vertical_split_outlined, 'Open canvas alongside'),
  ToolbarActionSpec('read_aloud', Icons.volume_up_outlined, 'Read aloud'),
  ToolbarActionSpec('connections', Icons.hub_outlined, 'All connections'),
];

ToolbarActionSpec? findActionSpec(String id) {
  for (final s in kCoreActionSpecs) {
    if (s.id == id) return s;
  }
  for (final s in kAddActionSpecs) {
    if (s.id == id) return s;
  }
  for (final s in kOverflowActionSpecs) {
    if (s.id == id) return s;
  }
  return null;
}
