import 'package:flutter/material.dart';

/// Helpers for keeping ink readable when a page background flips between a
/// light and a dark colour. The transform preserves hue + saturation (and
/// alpha) — it only reflects lightness, so colours are *retained* rather than
/// flattened to white/black (navy → light-navy, red stays red), while pure
/// black ↔ white flip fully.

/// A background counts as "dark" below this relative luminance. Matches the
/// canvas painter's pattern-line threshold so "dark background" means the same
/// thing everywhere.
bool isDarkBackground(Color c) => c.computeLuminance() < 0.4;

/// Reflects [c]'s HSL lightness (`L → 1 - L`), keeping hue, saturation and
/// alpha. Ink tuned for one background brightness stays visible on the
/// opposite one. It's an involution up to HSL rounding, so flipping a page's
/// background back and re-applying restores the original ink.
Color reflectLightnessForContrast(Color c) {
  final hsl = HSLColor.fromColor(c);
  return hsl.withLightness((1.0 - hsl.lightness).clamp(0.0, 1.0)).toColor();
}
