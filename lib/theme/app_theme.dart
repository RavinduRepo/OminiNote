import 'package:flutter/material.dart';

/// Corner radius used across the app. Small and crisp (Graphite shape language).
const double kRadius = 6.0;

/// Custom color tokens that don't map cleanly onto Material's [ColorScheme].
/// Read via `Theme.of(context).extension<AppPalette>()!`.
@immutable
class AppPalette extends ThemeExtension<AppPalette> {
  final Color canvas; // drawing surface background
  final Color dot; // grid dots / lines on the canvas
  final Color ink; // default pen color (theme-aware)
  final Color accent; // amber accent
  final Color accentSoft; // translucent accent for chips/tonal fills
  final Color surface2; // subtle raised/inset surface (inputs, viewport)
  final Color border; // hairline dividers and outlines
  final Color textDim; // secondary/metadata text

  const AppPalette({
    required this.canvas,
    required this.dot,
    required this.ink,
    required this.accent,
    required this.accentSoft,
    required this.surface2,
    required this.border,
    required this.textDim,
  });

  /// Stable per-notebook identity colors, fixed across both themes.
  static const List<Color> notebookColors = [
    Color(0xFF3B7DD8), // blue
    Color(0xFF2E9E5B), // green
    Color(0xFFD9553B), // coral
    Color(0xFF7C5CBF), // violet
    Color(0xFF2AA5B5), // teal
    Color(0xFFD98A2B), // ochre
  ];

  /// Curated palette the user picks from when setting a notebook/section/
  /// super-section color. Superset of [notebookColors]; all read cleanly on
  /// both light and dark grounds.
  static const List<Color> swatchColors = [
    Color(0xFF3B7DD8), // blue
    Color(0xFF2AA5B5), // teal
    Color(0xFF2E9E5B), // green
    Color(0xFF7FA31E), // olive
    Color(0xFFD98A2B), // amber
    Color(0xFFD9553B), // coral
    Color(0xFFD6457A), // rose
    Color(0xFF7C5CBF), // violet
    Color(0xFF5E6AD2), // indigo
    Color(0xFF3F7A56), // pine
    Color(0xFF9B6A2F), // brown
    Color(0xFF6B7280), // slate
  ];

  /// Deterministically pick an identity color for a notebook/page id.
  static Color identityColor(String id) {
    final index = id.hashCode.abs() % notebookColors.length;
    return notebookColors[index];
  }

  /// The effective color for an item: its explicit [color] if set, else the
  /// deterministic identity color for [id].
  static Color resolveColor(String id, int? color) =>
      color != null ? Color(color) : identityColor(id);

  @override
  AppPalette copyWith({
    Color? canvas,
    Color? dot,
    Color? ink,
    Color? accent,
    Color? accentSoft,
    Color? surface2,
    Color? border,
    Color? textDim,
  }) {
    return AppPalette(
      canvas: canvas ?? this.canvas,
      dot: dot ?? this.dot,
      ink: ink ?? this.ink,
      accent: accent ?? this.accent,
      accentSoft: accentSoft ?? this.accentSoft,
      surface2: surface2 ?? this.surface2,
      border: border ?? this.border,
      textDim: textDim ?? this.textDim,
    );
  }

  @override
  AppPalette lerp(ThemeExtension<AppPalette>? other, double t) {
    if (other is! AppPalette) return this;
    return AppPalette(
      canvas: Color.lerp(canvas, other.canvas, t)!,
      dot: Color.lerp(dot, other.dot, t)!,
      ink: Color.lerp(ink, other.ink, t)!,
      accent: Color.lerp(accent, other.accent, t)!,
      accentSoft: Color.lerp(accentSoft, other.accentSoft, t)!,
      surface2: Color.lerp(surface2, other.surface2, t)!,
      border: Color.lerp(border, other.border, t)!,
      textDim: Color.lerp(textDim, other.textDim, t)!,
    );
  }
}

/// Light + dark themes: Slate & Amber palette, flat/hairline (Graphite) shapes.
class AppTheme {
  static const _lightPalette = AppPalette(
    canvas: Color(0xFFF5F6F9),
    dot: Color(0xFFC7CCD6),
    ink: Color(0xFF2B303B),
    accent: Color(0xFFB8781E),
    accentSoft: Color(0x1FB8781E),
    surface2: Color(0xFFF7F8FA),
    border: Color(0xFFDDE1E8),
    textDim: Color(0xFF6B7280),
  );

  static const _darkPalette = AppPalette(
    canvas: Color(0xFF1F232C),
    dot: Color(0xFF3A4150),
    ink: Color(0xFFE7E9EE),
    accent: Color(0xFFE8A33D),
    accentSoft: Color(0x29E8A33D),
    surface2: Color(0xFF2A2F3A),
    border: Color(0xFF383E4B),
    textDim: Color(0xFF9AA1AF),
  );

  static ThemeData light() => _build(
    brightness: Brightness.light,
    palette: _lightPalette,
    scaffold: const Color(0xFFEEF0F4),
    surface: const Color(0xFFFFFFFF),
    onSurface: const Color(0xFF232733),
    onAccent: Colors.white,
  );

  static ThemeData dark() => _build(
    brightness: Brightness.dark,
    palette: _darkPalette,
    scaffold: const Color(0xFF1B1E25),
    surface: const Color(0xFF22262F),
    onSurface: const Color(0xFFE7E9EE),
    onAccent: const Color(0xFF23262F),
  );

  static ThemeData _build({
    required Brightness brightness,
    required AppPalette palette,
    required Color scaffold,
    required Color surface,
    required Color onSurface,
    required Color onAccent,
  }) {
    final colorScheme = ColorScheme(
      brightness: brightness,
      primary: palette.accent,
      onPrimary: onAccent,
      secondary: palette.accent,
      onSecondary: onAccent,
      surface: surface,
      onSurface: onSurface,
      error: const Color(0xFFC0413B),
      onError: Colors.white,
      outline: palette.border,
      outlineVariant: palette.border,
    );

    final baseBorder = OutlineInputBorder(
      borderRadius: BorderRadius.circular(kRadius),
      borderSide: BorderSide(color: palette.border),
    );

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: scaffold,
      extensions: [palette],
      splashFactory: InkSparkle.splashFactory,
      appBarTheme: AppBarTheme(
        backgroundColor: surface,
        foregroundColor: onSurface,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          color: onSurface,
          fontSize: 18,
          fontWeight: FontWeight.w600,
          letterSpacing: -0.2,
        ),
        shape: Border(bottom: BorderSide(color: palette.border, width: 1)),
      ),
      dividerTheme: DividerThemeData(
        color: palette.border,
        thickness: 1,
        space: 1,
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: palette.accent,
        foregroundColor: onAccent,
        elevation: 2,
        highlightElevation: 4,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(kRadius + 4),
        ),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: surface,
        surfaceTintColor: Colors.transparent,
        elevation: 4,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(kRadius + 2),
          side: BorderSide(color: palette.border),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(kRadius + 4),
          side: BorderSide(color: palette.border),
        ),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: const BorderRadius.vertical(
            top: Radius.circular(kRadius + 6),
          ),
          side: BorderSide(color: palette.border),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: palette.surface2,
        border: baseBorder,
        enabledBorder: baseBorder,
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(kRadius),
          borderSide: BorderSide(color: palette.accent, width: 1.5),
        ),
        hintStyle: TextStyle(color: palette.textDim),
      ),
      sliderTheme: SliderThemeData(
        activeTrackColor: palette.accent,
        inactiveTrackColor: palette.border,
        thumbColor: palette.accent,
        overlayColor: palette.accentSoft,
        trackHeight: 3,
      ),
    );
  }
}

/// A subtle fade-through page transition: fade in with a small upward slide.
/// Used for every push in the Notebook → Page → Canvas stack.
Route<T> fadeThroughRoute<T>(Widget page) {
  return PageRouteBuilder<T>(
    transitionDuration: const Duration(milliseconds: 320),
    reverseTransitionDuration: const Duration(milliseconds: 240),
    pageBuilder: (_, _, _) => page,
    transitionsBuilder: (_, animation, _, child) {
      final curved = CurvedAnimation(
        parent: animation,
        curve: Curves.easeOutCubic,
        reverseCurve: Curves.easeInCubic,
      );
      return FadeTransition(
        opacity: curved,
        child: SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0, 0.02),
            end: Offset.zero,
          ).animate(curved),
          child: child,
        ),
      );
    },
  );
}
