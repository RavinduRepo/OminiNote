import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import 'action_sheet.dart';
import 'color_wheel_picker.dart';

/// Result of the color picker. [color] null means "use the default identity
/// color". A null *return* from [showColorSwatchPicker] means dismissed.
class ColorChoice {
  final int? color;
  const ColorChoice(this.color);
}

/// Bottom sheet showing the curated swatch palette (`AppPalette.swatchColors`)
/// plus a "Default" option, for setting a notebook/section/super-section
/// color. [current] highlights the active swatch.
Future<ColorChoice?> showColorSwatchPicker(
  BuildContext context, {
  int? current,
}) {
  return showModalBottomSheet<ColorChoice>(
    context: context,
    isScrollControlled: true,
    builder: (context) {
      final theme = Theme.of(context);
      final palette = theme.extension<AppPalette>()!;
      return scrollableSheetBody(
        context,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'COLOR',
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 11,
                  letterSpacing: 0.8,
                  fontWeight: FontWeight.w600,
                  color: palette.textDim,
                ),
              ),
              const SizedBox(height: 14),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  for (final color in AppPalette.swatchColors)
                    _Swatch(
                      color: color,
                      selected: current == color.toARGB32(),
                      ring: palette.accent,
                      onTap: () => Navigator.pop(
                        context,
                        ColorChoice(color.toARGB32()),
                      ),
                    ),
                  _WheelSwatch(
                    // A custom color that is none of the curated swatches
                    // lights the wheel dot up as the active choice.
                    selected: current != null &&
                        AppPalette.swatchColors
                            .every((c) => c.toARGB32() != current),
                    currentColor: current,
                    ring: palette.accent,
                    onPicked: (color) => Navigator.pop(
                      context,
                      ColorChoice(color.toARGB32()),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () =>
                      Navigator.pop(context, const ColorChoice(null)),
                  icon: const Icon(Icons.refresh, size: 18),
                  label: const Text('Default color'),
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}

/// The rainbow "more colors" swatch: opens the full color wheel. When a
/// custom (non-curated) color is active it shows the selection ring and the
/// current color in its center.
class _WheelSwatch extends StatelessWidget {
  final bool selected;
  final int? currentColor;
  final Color ring;
  final ValueChanged<Color> onPicked;

  const _WheelSwatch({
    required this.selected,
    required this.currentColor,
    required this.ring,
    required this.onPicked,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () async {
        final picked = await showColorWheelPicker(
          context,
          initial: Color(currentColor ?? 0xFFE9A23B),
        );
        if (picked != null) onPicked(picked);
      },
      child: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(
            color: selected ? ring : Colors.transparent,
            width: 3,
          ),
        ),
        child: Padding(
          padding: EdgeInsets.all(selected ? 3 : 0),
          child: Container(
            decoration: const BoxDecoration(
              gradient: kColorWheelGradient,
              shape: BoxShape.circle,
            ),
            alignment: Alignment.center,
            child: selected
                ? Container(
                    width: 18,
                    height: 18,
                    decoration: BoxDecoration(
                      color: Color(currentColor!),
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white, width: 2),
                    ),
                  )
                : const Icon(Icons.colorize, color: Colors.white, size: 17),
          ),
        ),
      ),
    );
  }
}

class _Swatch extends StatelessWidget {
  final Color color;
  final bool selected;
  final Color ring;
  final VoidCallback onTap;

  const _Swatch({
    required this.color,
    required this.selected,
    required this.ring,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(
            color: selected ? ring : Colors.transparent,
            width: 3,
          ),
        ),
        child: Padding(
          padding: EdgeInsets.all(selected ? 3 : 0),
          child: Container(
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            child: selected
                ? const Icon(Icons.check, color: Colors.white, size: 18)
                : null,
          ),
        ),
      ),
    );
  }
}
