import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import '../../canvas/canvas_controller.dart';
import '../../canvas/rich_text_controller.dart';
import '../../canvas/shape_recognizer.dart' show ShapeToolKind;
import '../../models/element.dart';
import '../../models/link.dart';
import '../../models/shape_template.dart';
import '../../services/link_navigator.dart';
import '../../services/link_service.dart';
import '../../services/settings_service.dart';
import '../../theme/app_theme.dart';
import '../../widgets/color_wheel_picker.dart';
import '../../widgets/connections_sheet.dart';

const List<Color> _presetColors = [
  Color(0xFFD9553B),
  Color(0xFF17171A),
  Color(0xFFD98A2B),
  Color(0xFF2E9E5B),
  Color(0xFF3B7DD8),
  Color(0xFF7C5CBF),
  Color(0xFF2AA5B5),
  Color(0xFFFFFFFF),
];

/// Builds the active tool's contextual panel (colors/size, selection
/// actions, text style), or `null` when nothing should show. Shared by the
/// full-screen floating tool control (which shows a tool's options inline in
/// its own self-contained floating panel — [includePopoverTools],
/// [includeLassoRow], and [includeTextRow] all default true there) and, with
/// those flags false, the normal toolbar's `_ToolOptionsPanel` — pen/
/// highlighter/shape/eraser now show as an anchored popover
/// (`tool_options_popover.dart`), lasso shows as a floating menu near the
/// selection (`lasso_floating_menu.dart`), and text shows as a bottom bar
/// (`text_bottom_bar.dart`) in normal mode instead, so `_ToolOptionsPanel`
/// opts out of all three to avoid showing the same options twice. Options
/// only ever appear on a deliberate re-tap of the already-active tool
/// (`CanvasController.setTool` toggles `toolOptionsOpen`), except for panels
/// that reflect something already in progress — actively editing text, a
/// text box selected via lasso, or an active lasso selection/clipboard —
/// which stay visible regardless.
Widget? buildToolContextRow(
  BuildContext context,
  CanvasController c,
  AppPalette palette, {
  bool includePopoverTools = true,
  bool includeLassoRow = true,
  bool includeTextRow = true,
}) {
  if (c.isEditingText || c.selectionIsTextOnly) {
    return includeTextRow ? buildTextStyleRow(context, c, palette) : null;
  }
  if (c.tool == CanvasTool.lasso &&
      (c.selection.isNotEmpty || CanvasController.clipboardHasContent)) {
    return includeLassoRow ? buildLassoActionRow(context, c, palette) : null;
  }

  if (!c.toolOptionsOpen) return null;

  switch (c.tool) {
    case CanvasTool.pen:
    case CanvasTool.highlighter:
      return includePopoverTools
          ? buildPenOptionsRow(context, c, palette)
          : null;
    case CanvasTool.shape:
      return includePopoverTools
          ? buildShapeOptionsRow(context, c, palette)
          : null;
    case CanvasTool.eraser:
      return includePopoverTools
          ? buildEraserOptionsRow(context, c, palette)
          : null;
    case CanvasTool.lasso:
      // Hint + Paste (the row handles the empty-selection state itself).
      return includeLassoRow ? buildLassoActionRow(context, c, palette) : null;
    case CanvasTool.text:
      return includeTextRow ? buildTextStyleRow(context, c, palette) : null;
  }
}

const Map<ShapeToolKind, IconData> _shapeKindIcons = {
  ShapeToolKind.line: Icons.horizontal_rule,
  ShapeToolKind.arrow: Icons.north_east,
  ShapeToolKind.rectangle: Icons.crop_square,
  ShapeToolKind.ellipse: Icons.circle_outlined,
  ShapeToolKind.triangle: Icons.change_history,
  ShapeToolKind.diamond: Icons.diamond_outlined,
  ShapeToolKind.pentagon: Icons.pentagon_outlined,
  ShapeToolKind.hexagon: Icons.hexagon_outlined,
  ShapeToolKind.star: Icons.star_outline,
};

/// The Shapes tool options: a kind picker (line/rect/ellipse/…) plus the pen
/// color/size (drawn shapes use the pen's ink), so one place controls the whole
/// tool. Shown on a re-tap of the active Shapes tool.
Widget buildShapeOptionsRow(
  BuildContext context,
  CanvasController c,
  AppPalette palette,
) {
  final templates = SettingsService().shapeTemplates;
  return Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            for (final entry in _shapeKindIcons.entries)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                child: _ShapeKindButton(
                  icon: entry.value,
                  selected:
                      c.shapeToolTemplate == null && c.shapeToolKind == entry.key,
                  onTap: () => c.setShapeToolKind(entry.key),
                  palette: palette,
                ),
              ),
            if (templates.isNotEmpty)
              Container(
                width: 1,
                height: 28,
                margin: const EdgeInsets.symmetric(horizontal: 6),
                color: palette.border,
              ),
            for (final t in templates)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                child: _TemplateThumb(
                  template: t,
                  selected: c.shapeToolTemplate?.id == t.id,
                  onTap: () => c.setShapeToolTemplate(t),
                  onDelete: () => _confirmDeleteTemplate(context, c, t),
                  palette: palette,
                ),
              ),
          ],
        ),
      ),
      const SizedBox(height: 6),
      buildPenOptionsRow(context, c, palette),
    ],
  );
}

/// Prompts for a name and saves the current strokes-only selection as a custom
/// shape template (Phase 3).
Future<void> _promptSaveShape(BuildContext context, CanvasController c) async {
  final field = TextEditingController(text: 'My shape');
  final name = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Save as shape'),
      content: TextField(
        controller: field,
        autofocus: true,
        decoration: const InputDecoration(hintText: 'Shape name'),
        onSubmitted: (v) => Navigator.pop(ctx, v),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        TextButton(
            onPressed: () => Navigator.pop(ctx, field.text),
            child: const Text('Save')),
      ],
    ),
  );
  if (name == null) return;
  await c.saveSelectionAsShape(name);
  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: const Text('Saved to your shapes — pick it in the Shapes tool'),
      behavior: SnackBarBehavior.floating,
    ));
  }
}

Future<void> _confirmDeleteTemplate(
    BuildContext context, CanvasController c, ShapeTemplate t) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text('Delete “${t.name}”?'),
      content: const Text('This removes the saved shape from this device.'),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel')),
        TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete')),
      ],
    ),
  );
  if (ok == true) await c.deleteShapeTemplate(t.id);
}

/// A saved-template chip: a tiny thumbnail of the template's polylines; tap to
/// select it for stamping, long-press to delete.
class _TemplateThumb extends StatelessWidget {
  final ShapeTemplate template;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onDelete;
  final AppPalette palette;
  const _TemplateThumb({
    required this.template,
    required this.selected,
    required this.onTap,
    required this.onDelete,
    required this.palette,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: template.name,
      child: GestureDetector(
        onTap: onTap,
        onLongPress: onDelete,
        child: Container(
          width: 38,
          height: 38,
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(
            color: selected ? palette.accent.withValues(alpha: 0.16) : null,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: selected ? palette.accent : palette.border,
              width: selected ? 1.5 : 1,
            ),
          ),
          child: CustomPaint(
            painter: _TemplateThumbPainter(
                template, selected ? palette.accent : palette.textDim),
          ),
        ),
      ),
    );
  }
}

class _TemplateThumbPainter extends CustomPainter {
  final ShapeTemplate template;
  final Color color;
  _TemplateThumbPainter(this.template, this.color);

  @override
  void paint(ui.Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    for (final poly in template.polylines) {
      if (poly.length < 2) continue;
      final path = Path()
        ..moveTo(poly.first.dx * size.width, poly.first.dy * size.height);
      for (var i = 1; i < poly.length; i++) {
        path.lineTo(poly[i].dx * size.width, poly[i].dy * size.height);
      }
      canvas.drawPath(path, paint);
    }
  }

  @override
  bool shouldRepaint(_TemplateThumbPainter old) =>
      old.template != template || old.color != color;
}

class _ShapeKindButton extends StatelessWidget {
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;
  final AppPalette palette;
  const _ShapeKindButton({
    required this.icon,
    required this.selected,
    required this.onTap,
    required this.palette,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        width: 38,
        height: 38,
        decoration: BoxDecoration(
          color: selected ? palette.accent.withValues(alpha: 0.16) : null,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: selected ? palette.accent : palette.border,
            width: selected ? 1.5 : 1,
          ),
        ),
        child: Icon(icon,
            size: 20, color: selected ? palette.accent : palette.textDim),
      ),
    );
  }
}

Widget buildEraserOptionsRow(
  BuildContext context,
  CanvasController c,
  AppPalette palette,
) {
  return Row(
    children: [
      SegmentedButton<bool>(
        showSelectedIcon: false,
        style: const ButtonStyle(
          visualDensity: VisualDensity.compact,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
        segments: const [
          ButtonSegment(
            value: false,
            label: Text('Stroke'),
            tooltip: 'Erase whole strokes',
          ),
          ButtonSegment(
            value: true,
            label: Text('Partial'),
            tooltip: 'Erase only where you rub',
          ),
        ],
        selected: {c.eraserPartial},
        onSelectionChanged: (sel) {
          c.eraserPartial = sel.first;
          SettingsService().setEraserPrefs(partial: sel.first);
          c.notifyRepaint();
        },
      ),
      Container(
        width: 1,
        height: 24,
        margin: const EdgeInsets.symmetric(horizontal: 8),
        color: palette.border,
      ),
      _ThicknessPreview(
        color: palette.textDim,
        size: c.eraserSize.clamp(4, 40),
        min: 4,
        max: 40,
      ),
      SizedBox(
        width: 110,
        child: Slider(
          value: c.eraserSize.clamp(4, 40),
          min: 4,
          max: 40,
          divisions: 18,
          label: c.eraserSize.toStringAsFixed(0),
          onChanged: (v) {
            c.eraserSize = v;
            SettingsService().setEraserPrefs(size: v);
            c.notifyRepaint();
          },
        ),
      ),
    ],
  );
}

Widget buildPenOptionsRow(
  BuildContext context,
  CanvasController c,
  AppPalette palette,
) {
  return Row(
    children: [
      Flexible(
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              for (final preset in _presetColors)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 3),
                  child: _ColorDot(
                    color: preset,
                    selected: preset.toARGB32() == c.color.toARGB32(),
                    ringColor: palette.accent,
                    borderColor: palette.border,
                    onTap: () {
                      c.color = preset;
                      c.notifyRepaint();
                    },
                  ),
                ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 3),
                child: _WheelDot(
                  current: c.color,
                  selected: _presetColors
                      .every((p) => p.toARGB32() != c.color.toARGB32()),
                  ringColor: palette.accent,
                  onPicked: (color) {
                    c.color = color;
                    c.notifyRepaint();
                  },
                ),
              ),
            ],
          ),
        ),
      ),
      Container(
        width: 1,
        height: 24,
        margin: const EdgeInsets.symmetric(horizontal: 8),
        color: palette.border,
      ),
      _ThicknessPreview(color: c.color, size: c.strokeSize, min: 1, max: 20),
      SizedBox(
        width: 110,
        child: Slider(
          value: c.strokeSize,
          min: 1,
          max: 20,
          divisions: 19,
          label: c.strokeSize.toStringAsFixed(0),
          onChanged: (v) {
            c.strokeSize = v;
            c.notifyRepaint();
          },
        ),
      ),
    ],
  );
}

/// The mockup's thickness "preview": a chip holding a dot whose diameter tracks
/// the current stroke size, tinted with the tool's color (grey for the eraser).
class _ThicknessPreview extends StatelessWidget {
  final Color color;
  final double size;
  final double min;
  final double max;

  const _ThicknessPreview({
    required this.color,
    required this.size,
    required this.min,
    required this.max,
  });

  @override
  Widget build(BuildContext context) {
    final palette = Theme.of(context).extension<AppPalette>()!;
    final t = ((size - min) / (max - min)).clamp(0.0, 1.0);
    final d = 4 + t * 18; // 4..22px
    return Container(
      width: 34,
      height: 34,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: palette.surface2,
        border: Border.all(color: palette.border),
        borderRadius: BorderRadius.circular(kRadius),
      ),
      child: Container(
        width: d,
        height: d,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      ),
    );
  }
}

/// The element endpoint for the current lasso selection (its element ids on
/// their page), or null when nothing is selected.
LinkEndpoint? _selectionEndpoint(CanvasController c) {
  final pageId = c.selectionPageId;
  if (pageId == null || c.selection.isEmpty) return null;
  return LinkEndpoint(
    notebookId: c.canvas.notebookId,
    sectionId: c.canvas.sectionId,
    canvasId: c.canvas.id,
    pageId: pageId,
    elementIds: c.selection.map((e) => e.id).toList(),
  );
}

Widget buildLassoActionRow(
  BuildContext context,
  CanvasController c,
  AppPalette palette,
) {
  if (c.selection.isEmpty) {
    return Row(
      children: [
        Expanded(
          child: _HintRow(
            icon: Icons.gesture,
            text: 'Draw around items to select them',
            palette: palette,
          ),
        ),
        // Always available: internal clipboard first, else the OS clipboard
        // (image, then text).
        TextButton.icon(
          onPressed: c.pasteClipboard,
          icon: const Icon(Icons.content_paste, size: 16),
          label: const Text('Paste'),
        ),
      ],
    );
  }
  return SingleChildScrollView(
    scrollDirection: Axis.horizontal,
    child: Row(
      children: [
        Text(
          '${c.selection.length} selected',
          style: TextStyle(fontSize: 12, color: palette.textDim),
        ),
        const SizedBox(width: 8),
        _SelAction(
          icon: Icons.delete_outline,
          label: 'Delete',
          onTap: c.deleteSelection,
        ),
        _SelAction(icon: Icons.copy, label: 'Copy', onTap: c.copySelection),
        _SelAction(icon: Icons.cut, label: 'Cut', onTap: c.cutSelection),
        _SelAction(
          icon: Icons.control_point_duplicate,
          label: 'Duplicate',
          onTap: c.duplicateSelection,
        ),
        _SelAction(
          icon: Icons.palette_outlined,
          label: 'Color',
          onTap: c.applyColorToSelection,
        ),
        _SelAction(
          icon: Icons.flip_to_front,
          label: 'Front',
          onTap: c.bringSelectionToFront,
        ),
        _SelAction(
          icon: Icons.flip_to_back,
          label: 'Back',
          onTap: c.sendSelectionToBack,
        ),
        // Connections: link this exact selection to anything (element
        // endpoint = the selected ids on their page).
        _SelAction(
          icon: Icons.link,
          label: 'Copy link',
          onTap: () {
            final ep = _selectionEndpoint(c);
            if (ep != null) copyLinkToClipboard(context, ep);
          },
        ),
        _SelAction(
          icon: Icons.hub_outlined,
          label: 'Connections',
          onTap: () {
            final ep = _selectionEndpoint(c);
            if (ep == null) return;
            // Snapshot the selection geometry now — adding a target from the
            // sheet may outlive the live selection.
            final pageId = c.selectionPageId!;
            final bounds = c.selectionBounds;
            showConnectionsSheet(
              context,
              title: 'Selection',
              endpoint: ep,
              endpointName: 'Selection in ${c.canvas.name}',
              insideCanvasId: c.canvas.id,
              onJumpInSameCanvas: (pid) {
                final f = LinkNavigator().takeFocusFor(c.canvas.id);
                if (f != null) {
                  c.focusElements(f.pageId, f.elementIds);
                } else if (pid != null) {
                  c.jumpToPage(pid);
                }
              },
              // Linking a selection drops a visible hyperlink marker right
              // next to it (the on-canvas indication that a link exists) and
              // registers the record with the marker's id included — so the
              // marker's ✎ retargets this very record.
              onAddTarget: (target, resolved) async {
                // Dedup by overlap: the stored record's element side also
                // holds the marker id, so exact-pair matching can't see it.
                final existing =
                    await LinkService().linksOfElements(ep.elementIds);
                for (final r in existing) {
                  if (r.a.sameAs(target) || r.b.sameAs(target)) return;
                }
                final marker = c.insertLinkItem(
                  pageId,
                  target.toUri(),
                  resolved.title,
                  nearBounds: bounds,
                );
                await LinkService().addLink(
                  from: LinkEndpoint(
                    notebookId: ep.notebookId,
                    sectionId: ep.sectionId,
                    canvasId: ep.canvasId,
                    pageId: ep.pageId,
                    elementIds: [
                      ...ep.elementIds,
                      if (marker != null) marker.id,
                    ],
                  ),
                  to: target,
                  fromName: 'Selection in ${c.canvas.name}',
                  toName: resolved.title,
                );
              },
            );
          },
        ),
        // Save a strokes-only selection as a reusable custom shape (Phase 3).
        if (c.selectionIsStrokesOnly)
          _SelAction(
            icon: Icons.add_box_outlined,
            label: 'Save as shape',
            onTap: () => _promptSaveShape(context, c),
          ),
        // Split pasted text (linked boxes across pages): act on ALL parts.
        // "Cut all" + paste elsewhere re-flows it there = the move story.
        if (c.selectionHasLinkedText) ...[
          _SelAction(
            icon: Icons.cut,
            label: 'Cut all parts',
            onTap: c.cutLinkedText,
          ),
          _SelAction(
            icon: Icons.delete_sweep_outlined,
            label: 'Delete all parts',
            onTap: c.deleteLinkedText,
          ),
        ],
      ],
    ),
  );
}

Widget buildTextStyleRow(
  BuildContext context,
  CanvasController c,
  AppPalette palette,
) {
  final showActions = c.selection.isNotEmpty && !c.isEditingText;
  Widget divider() => Container(
    width: 1,
    height: 24,
    margin: const EdgeInsets.symmetric(horizontal: 8),
    color: palette.border,
  );

  // TextFieldTapRegion: taps on these controls count as "inside" the text
  // editor, so they no longer unfocus the TextField / fire onTapOutside —
  // which used to commit the edit and collapse the selection the instant any
  // style button was tapped ("selecting a style deselects and does nothing").
  return TextFieldTapRegion(
    child: SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          PopupMenuButton<String>(
            tooltip: 'Font',
            initialValue: c.textFontFamily,
            onSelected: c.setTextFontFamily,
            itemBuilder: (context) => const [
              PopupMenuItem(value: 'sans', child: Text('Sans')),
              PopupMenuItem(
                value: 'serif',
                child: Text('Serif', style: TextStyle(fontFamily: 'Georgia')),
              ),
              PopupMenuItem(
                value: 'mono',
                child: Text(
                  'Mono',
                  style: TextStyle(fontFamily: 'Courier New'),
                ),
              ),
            ],
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Aa',
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      fontFamily: switch (c.textFontFamily) {
                        'serif' => 'Georgia',
                        'mono' => 'Courier New',
                        _ => null,
                      },
                    ),
                  ),
                  Icon(Icons.arrow_drop_down, size: 18, color: palette.textDim),
                ],
              ),
            ),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            tooltip: 'Smaller',
            icon: const Icon(Icons.text_decrease, size: 18),
            onPressed: () => c.setTextFontSize(c.textFontSize - 2),
          ),
          Text(
            c.textFontSize.toStringAsFixed(0),
            style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            tooltip: 'Larger',
            icon: const Icon(Icons.text_increase, size: 18),
            onPressed: () => c.setTextFontSize(c.textFontSize + 2),
          ),
          const SizedBox(width: 4),
          _ToggleChip(
            label: 'B',
            bold: true,
            active: c.textBold,
            onTap: c.toggleTextBold,
          ),
          _ToggleChip(
            label: 'I',
            italic: true,
            active: c.textItalic,
            onTap: c.toggleTextItalic,
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            tooltip: 'Alignment',
            icon: Icon(switch (c.textAlign) {
              TextAlignOption.center => Icons.format_align_center,
              TextAlignOption.right => Icons.format_align_right,
              _ => Icons.format_align_left,
            }, size: 18),
            onPressed: c.cycleTextAlign,
          ),
          if (c.isEditingText) ...[
            divider(),
            IconButton(
              visualDensity: VisualDensity.compact,
              tooltip: 'Bullet list',
              icon: const Icon(Icons.format_list_bulleted, size: 18),
              onPressed: () =>
                  c.toggleTextListPrefix(RichTextController.bulletPrefix),
            ),
            IconButton(
              visualDensity: VisualDensity.compact,
              tooltip: 'Star list',
              icon: const Icon(Icons.star_outline, size: 18),
              onPressed: () =>
                  c.toggleTextListPrefix(RichTextController.starPrefix),
            ),
            IconButton(
              visualDensity: VisualDensity.compact,
              tooltip: 'Checkbox (tap again to check)',
              icon: const Icon(Icons.check_box_outlined, size: 18),
              onPressed: () => c.toggleTextListPrefix(
                RichTextController.uncheckedPrefix,
                cycle: true,
              ),
            ),
          ],
          divider(),
          for (final preset in _presetColors)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 3),
              child: _ColorDot(
                color: preset,
                selected: preset.toARGB32() == c.textColor.toARGB32(),
                ringColor: palette.accent,
                borderColor: palette.border,
                onTap: () => c.setTextColor(preset),
              ),
            ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 3),
            child: _WheelDot(
              current: c.textColor,
              selected: _presetColors
                  .every((p) => p.toARGB32() != c.textColor.toARGB32()),
              ringColor: palette.accent,
              onPicked: c.setTextColor,
            ),
          ),
          if (showActions) ...[
            divider(),
            _SelAction(
              icon: Icons.control_point_duplicate,
              label: 'Duplicate',
              onTap: c.duplicateSelection,
            ),
            _SelAction(
              icon: Icons.delete_outline,
              label: 'Delete',
              onTap: c.deleteSelection,
            ),
            // A text-only selection shows THIS row, not the lasso action row
            // — so the linked (split-paste) whole-text actions must live here
            // too, or they'd be unreachable for text boxes.
            if (c.selectionHasLinkedText) ...[
              _SelAction(
                icon: Icons.cut,
                label: 'Cut all parts',
                onTap: c.cutLinkedText,
              ),
              _SelAction(
                icon: Icons.delete_sweep_outlined,
                label: 'Delete all parts',
                onTap: c.deleteLinkedText,
              ),
            ],
          ],
        ],
      ),
    ),
  );
}

class _HintRow extends StatelessWidget {
  final IconData icon;
  final String text;
  final AppPalette palette;

  const _HintRow({
    required this.icon,
    required this.text,
    required this.palette,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Icon(icon, size: 16, color: palette.textDim),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              text,
              style: TextStyle(fontSize: 11.5, color: palette.textDim),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

class _SelAction extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _SelAction({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 2),
      child: TextButton.icon(
        onPressed: onTap,
        icon: Icon(icon, size: 16),
        label: Text(label, style: const TextStyle(fontSize: 12)),
        style: TextButton.styleFrom(
          visualDensity: VisualDensity.compact,
          padding: const EdgeInsets.symmetric(horizontal: 8),
        ),
      ),
    );
  }
}

class _ToggleChip extends StatelessWidget {
  final String label;
  final bool bold;
  final bool italic;
  final bool active;
  final VoidCallback onTap;

  const _ToggleChip({
    required this.label,
    this.bold = false,
    this.italic = false,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(kRadius),
        child: Container(
          width: 30,
          height: 30,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: active
                ? theme.colorScheme.primary.withValues(alpha: 0.15)
                : null,
            borderRadius: BorderRadius.circular(kRadius),
            border: Border.all(
              color: active ? theme.colorScheme.primary : theme.dividerColor,
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 14,
              fontWeight: bold ? FontWeight.w700 : FontWeight.w500,
              fontStyle: italic ? FontStyle.italic : FontStyle.normal,
              color: active ? theme.colorScheme.primary : null,
            ),
          ),
        ),
      ),
    );
  }
}

class _ColorDot extends StatelessWidget {
  final Color color;
  final bool selected;
  final Color ringColor;
  final Color borderColor;
  final VoidCallback onTap;

  const _ColorDot({
    required this.color,
    required this.selected,
    required this.ringColor,
    required this.borderColor,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOut,
        width: 26,
        height: 26,
        padding: EdgeInsets.all(selected ? 3 : 0),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(
            color: selected ? ringColor : Colors.transparent,
            width: 2,
          ),
        ),
        child: Container(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: color,
            border: Border.all(color: borderColor, width: 1),
          ),
        ),
      ),
    );
  }
}

/// The rainbow "more colors" dot at the end of a color row: opens the full
/// color wheel. [selected] (the active color isn't one of the presets) shows
/// the ring and the current custom color in the dot's center.
class _WheelDot extends StatelessWidget {
  final Color current;
  final bool selected;
  final Color ringColor;
  final ValueChanged<Color> onPicked;

  const _WheelDot({
    required this.current,
    required this.selected,
    required this.ringColor,
    required this.onPicked,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () async {
        final picked = await showColorWheelPicker(context, initial: current);
        if (picked != null) onPicked(picked);
      },
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOut,
        width: 26,
        height: 26,
        padding: EdgeInsets.all(selected ? 3 : 0),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(
            color: selected ? ringColor : Colors.transparent,
            width: 2,
          ),
        ),
        child: Container(
          decoration: const BoxDecoration(
            shape: BoxShape.circle,
            gradient: kColorWheelGradient,
          ),
          alignment: Alignment.center,
          child: selected
              ? Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(
                    color: current,
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white, width: 1.5),
                  ),
                )
              : const Icon(Icons.colorize, color: Colors.white, size: 12),
        ),
      ),
    );
  }
}
