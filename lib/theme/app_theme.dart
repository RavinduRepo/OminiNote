import 'package:flutter/material.dart';

/// Corner radius used across the app. Softer than the original crisp Graphite
/// 6px — the v2 redesign uses rounder cards/controls (mockup ~11-13px on cards,
/// ~8-10 on small controls); this base + the `kRadius+N` offsets land there.
const double kRadius = 10.0;

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

/// One selectable theme "taste": a full palette + the handful of extra colors
/// [AppTheme._build] needs. The user picks a light one and a dark one; System
/// mode then shows the chosen light variant in light and the chosen dark in
/// dark. All are tuned to stay easy on the eye for long reading/writing.
@immutable
class ThemeVariant {
  final String id;
  final String name;

  /// One-word flavour shown under the name in the picker.
  final String blurb;
  final Brightness brightness;
  final AppPalette palette;
  final Color scaffold;
  final Color surface;
  final Color onSurface;
  final Color onAccent;

  const ThemeVariant({
    required this.id,
    required this.name,
    required this.blurb,
    required this.brightness,
    required this.palette,
    required this.scaffold,
    required this.surface,
    required this.onSurface,
    required this.onAccent,
  });

  ThemeData build() => AppTheme._build(
        brightness: brightness,
        palette: palette,
        scaffold: scaffold,
        surface: surface,
        onSurface: onSurface,
        onAccent: onAccent,
      );
}

/// Light + dark themes: flat/hairline (Graphite) shapes, in several palettes.
class AppTheme {
  // ── Light variants ──────────────────────────────────────────────────────

  static const _slate = ThemeVariant(
    id: 'slate',
    name: 'Slate',
    blurb: 'Cool grey · amber',
    brightness: Brightness.light,
    palette: AppPalette(
      canvas: Color(0xFFF5F6F9),
      dot: Color(0xFFC7CCD6),
      ink: Color(0xFF2B303B),
      accent: Color(0xFFB8781E),
      accentSoft: Color(0x1FB8781E),
      surface2: Color(0xFFF7F8FA),
      border: Color(0xFFDDE1E8),
      textDim: Color(0xFF6B7280),
    ),
    scaffold: Color(0xFFEEF0F4),
    surface: Color(0xFFFFFFFF),
    onSurface: Color(0xFF232733),
    onAccent: Colors.white,
  );

  static const _paper = ThemeVariant(
    id: 'paper',
    name: 'Paper',
    blurb: 'Warm ivory',
    brightness: Brightness.light,
    palette: AppPalette(
      canvas: Color(0xFFEFE9DD),
      dot: Color(0xFFD8CFBE),
      ink: Color(0xFF3A3327),
      accent: Color(0xFFB67A2E),
      accentSoft: Color(0x1FB67A2E),
      surface2: Color(0xFFF6F1E8),
      border: Color(0xFFE3DBCC),
      textDim: Color(0xFF8A8070),
    ),
    scaffold: Color(0xFFF3EFE7),
    surface: Color(0xFFFBF8F2),
    onSurface: Color(0xFF2E2A22),
    onAccent: Colors.white,
  );

  static const _mist = ThemeVariant(
    id: 'mist',
    name: 'Mist',
    blurb: 'Cool blue',
    brightness: Brightness.light,
    palette: AppPalette(
      canvas: Color(0xFFF1F4F9),
      dot: Color(0xFFC4D0DE),
      ink: Color(0xFF263141),
      accent: Color(0xFF3E76C4),
      accentSoft: Color(0x1F3E76C4),
      surface2: Color(0xFFF4F7FB),
      border: Color(0xFFD6DFEA),
      textDim: Color(0xFF64748B),
    ),
    scaffold: Color(0xFFEDF1F6),
    surface: Color(0xFFFFFFFF),
    onSurface: Color(0xFF1F2A38),
    onAccent: Colors.white,
  );

  static const _sage = ThemeVariant(
    id: 'sage',
    name: 'Sage',
    blurb: 'Soft green',
    brightness: Brightness.light,
    palette: AppPalette(
      canvas: Color(0xFFEAEEE6),
      dot: Color(0xFFCBD5C4),
      ink: Color(0xFF2C332B),
      accent: Color(0xFF4B8A5A),
      accentSoft: Color(0x1F4B8A5A),
      surface2: Color(0xFFF4F7F2),
      border: Color(0xFFDBE2D6),
      textDim: Color(0xFF6E7A69),
    ),
    scaffold: Color(0xFFEEF1EC),
    surface: Color(0xFFFBFCFA),
    onSurface: Color(0xFF232A22),
    onAccent: Colors.white,
  );

  static const _sand = ThemeVariant(
    id: 'sand',
    name: 'Sand',
    blurb: 'Warm desert',
    brightness: Brightness.light,
    palette: AppPalette(
      canvas: Color(0xFFEDE5D6),
      dot: Color(0xFFD9CDB8),
      ink: Color(0xFF38322A),
      accent: Color(0xFFC2703C),
      accentSoft: Color(0x1FC2703C),
      surface2: Color(0xFFF7F1E6),
      border: Color(0xFFE2D8C6),
      textDim: Color(0xFF8C8272),
    ),
    scaffold: Color(0xFFF2ECE1),
    surface: Color(0xFFFBF7EF),
    onSurface: Color(0xFF2D2820),
    onAccent: Colors.white,
  );

  static const _sky = ThemeVariant(
    id: 'sky',
    name: 'Sky',
    blurb: 'Airy blue',
    brightness: Brightness.light,
    palette: AppPalette(
      canvas: Color(0xFFEEF5FC),
      dot: Color(0xFFC3D8ED),
      ink: Color(0xFF22303F),
      accent: Color(0xFF2E8BD0),
      accentSoft: Color(0x1F2E8BD0),
      surface2: Color(0xFFF2F8FD),
      border: Color(0xFFD2E1F0),
      textDim: Color(0xFF5E7080),
    ),
    scaffold: Color(0xFFEAF2FA),
    surface: Color(0xFFFFFFFF),
    onSurface: Color(0xFF1B2836),
    onAccent: Colors.white,
  );

  static const _lavender = ThemeVariant(
    id: 'lavender',
    name: 'Lavender',
    blurb: 'Soft violet',
    brightness: Brightness.light,
    palette: AppPalette(
      canvas: Color(0xFFECE8F4),
      dot: Color(0xFFD2CADF),
      ink: Color(0xFF2F2A38),
      accent: Color(0xFF7E5FC0),
      accentSoft: Color(0x1F7E5FC0),
      surface2: Color(0xFFF6F3FC),
      border: Color(0xFFE0DAEC),
      textDim: Color(0xFF746D82),
    ),
    scaffold: Color(0xFFF0EDF6),
    surface: Color(0xFFFCFAFF),
    onSurface: Color(0xFF27222F),
    onAccent: Colors.white,
  );

  static const _rose = ThemeVariant(
    id: 'rose',
    name: 'Rose',
    blurb: 'Warm blush',
    brightness: Brightness.light,
    palette: AppPalette(
      canvas: Color(0xFFF1E6E7),
      dot: Color(0xFFE0C9CC),
      ink: Color(0xFF3A2E30),
      accent: Color(0xFFC15570),
      accentSoft: Color(0x1FC15570),
      surface2: Color(0xFFF9F1F2),
      border: Color(0xFFEAD8DA),
      textDim: Color(0xFF8C7A7C),
    ),
    scaffold: Color(0xFFF6EDEE),
    surface: Color(0xFFFDF8F8),
    onSurface: Color(0xFF302628),
    onAccent: Colors.white,
  );

  static const _mint = ThemeVariant(
    id: 'mint',
    name: 'Mint',
    blurb: 'Fresh teal',
    brightness: Brightness.light,
    palette: AppPalette(
      canvas: Color(0xFFE4EFEA),
      dot: Color(0xFFC3DAD0),
      ink: Color(0xFF23322C),
      accent: Color(0xFF1F9E82),
      accentSoft: Color(0x1F1F9E82),
      surface2: Color(0xFFF1F8F5),
      border: Color(0xFFD3E4DC),
      textDim: Color(0xFF64786F),
    ),
    scaffold: Color(0xFFE9F3EF),
    surface: Color(0xFFFBFDFC),
    onSurface: Color(0xFF1D2A25),
    onAccent: Colors.white,
  );

  static const _cloud = ThemeVariant(
    id: 'cloud',
    name: 'Cloud',
    blurb: 'Crisp neutral',
    brightness: Brightness.light,
    palette: AppPalette(
      canvas: Color(0xFFF7F8FA),
      dot: Color(0xFFD0D4DB),
      ink: Color(0xFF1E2127),
      accent: Color(0xFF4F5BD5),
      accentSoft: Color(0x1F4F5BD5),
      surface2: Color(0xFFF6F7F9),
      border: Color(0xFFE1E4E9),
      textDim: Color(0xFF616772),
    ),
    scaffold: Color(0xFFF4F5F7),
    surface: Color(0xFFFFFFFF),
    onSurface: Color(0xFF16181D),
    onAccent: Colors.white,
  );

  // ── Dark variants ───────────────────────────────────────────────────────

  static const _charcoal = ThemeVariant(
    id: 'charcoal',
    name: 'Charcoal',
    blurb: 'Deep grey · amber',
    brightness: Brightness.dark,
    palette: AppPalette(
      canvas: Color(0xFF14171D),
      dot: Color(0xFF2E3542),
      ink: Color(0xFFE9ECF1),
      accent: Color(0xFFE9A23B),
      accentSoft: Color(0x24E9A23B),
      surface2: Color(0xFF1E232C),
      border: Color(0xFF2A313D),
      textDim: Color(0xFF98A1AF),
    ),
    scaffold: Color(0xFF12151B),
    surface: Color(0xFF171B22),
    onSurface: Color(0xFFE9ECF1),
    onAccent: Color(0xFF12151B),
  );

  static const _midnight = ThemeVariant(
    id: 'midnight',
    name: 'Midnight',
    blurb: 'Deep navy · blue',
    brightness: Brightness.dark,
    palette: AppPalette(
      canvas: Color(0xFF10151F),
      dot: Color(0xFF29334A),
      ink: Color(0xFFE4E9F2),
      accent: Color(0xFF5E86D6),
      accentSoft: Color(0x245E86D6),
      surface2: Color(0xFF1B2233),
      border: Color(0xFF262F44),
      textDim: Color(0xFF8892A8),
    ),
    scaffold: Color(0xFF0F1420),
    surface: Color(0xFF151B2A),
    onSurface: Color(0xFFE4E9F2),
    onAccent: Color(0xFF0F1420),
  );

  static const _espresso = ThemeVariant(
    id: 'espresso',
    name: 'Espresso',
    blurb: 'Warm dark · amber',
    brightness: Brightness.dark,
    palette: AppPalette(
      canvas: Color(0xFF17130F),
      dot: Color(0xFF3A3228),
      ink: Color(0xFFEDE6DA),
      accent: Color(0xFFE0A24B),
      accentSoft: Color(0x24E0A24B),
      surface2: Color(0xFF262019),
      border: Color(0xFF332C24),
      textDim: Color(0xFFA79C8C),
    ),
    scaffold: Color(0xFF1A1613),
    surface: Color(0xFF221D18),
    onSurface: Color(0xFFEDE6DA),
    onAccent: Color(0xFF1A1613),
  );

  static const _carbon = ThemeVariant(
    id: 'carbon',
    name: 'Carbon',
    blurb: 'Near-black · teal',
    brightness: Brightness.dark,
    palette: AppPalette(
      canvas: Color(0xFF0D0F13),
      dot: Color(0xFF262B33),
      ink: Color(0xFFE6E9EE),
      accent: Color(0xFF3FB0A5),
      accentSoft: Color(0x243FB0A5),
      surface2: Color(0xFF16191E),
      border: Color(0xFF23272E),
      textDim: Color(0xFF8B929C),
    ),
    scaffold: Color(0xFF0B0D10),
    surface: Color(0xFF121519),
    onSurface: Color(0xFFE6E9EE),
    onAccent: Color(0xFF0B0D10),
  );

  static const _nord = ThemeVariant(
    id: 'nord',
    name: 'Nord',
    blurb: 'Blue-grey · frost',
    brightness: Brightness.dark,
    palette: AppPalette(
      canvas: Color(0xFF2B303B),
      dot: Color(0xFF434C5E),
      ink: Color(0xFFECEFF4),
      accent: Color(0xFF88C0D0),
      accentSoft: Color(0x2488C0D0),
      surface2: Color(0xFF3B4252),
      border: Color(0xFF3F4859),
      textDim: Color(0xFF9AA4B8),
    ),
    scaffold: Color(0xFF2E3440),
    surface: Color(0xFF343B48),
    onSurface: Color(0xFFECEFF4),
    onAccent: Color(0xFF2E3440),
  );

  static const _forest = ThemeVariant(
    id: 'forest',
    name: 'Forest',
    blurb: 'Deep green',
    brightness: Brightness.dark,
    palette: AppPalette(
      canvas: Color(0xFF0E140D),
      dot: Color(0xFF2A3A28),
      ink: Color(0xFFE4EBE0),
      accent: Color(0xFF6FB05A),
      accentSoft: Color(0x246FB05A),
      surface2: Color(0xFF1D271B),
      border: Color(0xFF283A24),
      textDim: Color(0xFF93A08D),
    ),
    scaffold: Color(0xFF10160F),
    surface: Color(0xFF172016),
    onSurface: Color(0xFFE4EBE0),
    onAccent: Color(0xFF10160F),
  );

  static const _plum = ThemeVariant(
    id: 'plum',
    name: 'Plum',
    blurb: 'Deep violet',
    brightness: Brightness.dark,
    palette: AppPalette(
      canvas: Color(0xFF140F1A),
      dot: Color(0xFF362B45),
      ink: Color(0xFFECE6F2),
      accent: Color(0xFFB57BE0),
      accentSoft: Color(0x24B57BE0),
      surface2: Color(0xFF241C30),
      border: Color(0xFF2E2540),
      textDim: Color(0xFFA398B0),
    ),
    scaffold: Color(0xFF17121E),
    surface: Color(0xFF1F1829),
    onSurface: Color(0xFFECE6F2),
    onAccent: Color(0xFF17121E),
  );

  static const _ocean = ThemeVariant(
    id: 'ocean',
    name: 'Ocean',
    blurb: 'Deep teal',
    brightness: Brightness.dark,
    palette: AppPalette(
      canvas: Color(0xFF0A1416),
      dot: Color(0xFF24393C),
      ink: Color(0xFFDEEBEC),
      accent: Color(0xFF35B0C0),
      accentSoft: Color(0x2435B0C0),
      surface2: Color(0xFF16292C),
      border: Color(0xFF21363A),
      textDim: Color(0xFF8AA2A4),
    ),
    scaffold: Color(0xFF0C1719),
    surface: Color(0xFF122123),
    onSurface: Color(0xFFDEEBEC),
    onAccent: Color(0xFF0C1719),
  );

  static const _mocha = ThemeVariant(
    id: 'mocha',
    name: 'Mocha',
    blurb: 'Warm mauve',
    brightness: Brightness.dark,
    palette: AppPalette(
      canvas: Color(0xFF11111B),
      dot: Color(0xFF313244),
      ink: Color(0xFFCDD6F4),
      accent: Color(0xFFCBA6F7),
      accentSoft: Color(0x24CBA6F7),
      surface2: Color(0xFF262637),
      border: Color(0xFF313244),
      textDim: Color(0xFF9399B2),
    ),
    scaffold: Color(0xFF181825),
    surface: Color(0xFF1E1E2E),
    onSurface: Color(0xFFCDD6F4),
    onAccent: Color(0xFF181825),
  );

  static const _steel = ThemeVariant(
    id: 'steel',
    name: 'Steel',
    blurb: 'Neutral slate',
    brightness: Brightness.dark,
    palette: AppPalette(
      canvas: Color(0xFF16181B),
      dot: Color(0xFF33383D),
      ink: Color(0xFFE7E9EC),
      accent: Color(0xFF6E8CB0),
      accentSoft: Color(0x246E8CB0),
      surface2: Color(0xFF23272B),
      border: Color(0xFF2D3136),
      textDim: Color(0xFF969CA3),
    ),
    scaffold: Color(0xFF1A1C1F),
    surface: Color(0xFF232629),
    onSurface: Color(0xFFE7E9EC),
    onAccent: Color(0xFF1A1C1F),
  );

  /// Pickable light palettes (first is the default).
  static const List<ThemeVariant> lightVariants = [
    _slate,
    _paper,
    _mist,
    _sage,
    _sand,
    _sky,
    _lavender,
    _rose,
    _mint,
    _cloud,
  ];

  /// Pickable dark palettes (first is the default).
  static const List<ThemeVariant> darkVariants = [
    _charcoal,
    _midnight,
    _espresso,
    _carbon,
    _nord,
    _forest,
    _plum,
    _ocean,
    _mocha,
    _steel,
  ];

  /// The light variant for [id], or the default when unknown/null.
  static ThemeVariant lightVariant(String? id) => lightVariants.firstWhere(
        (v) => v.id == id,
        orElse: () => lightVariants.first,
      );

  /// The dark variant for [id], or the default when unknown/null.
  static ThemeVariant darkVariant(String? id) => darkVariants.firstWhere(
        (v) => v.id == id,
        orElse: () => darkVariants.first,
      );

  static ThemeData light() => lightVariants.first.build();

  static ThemeData dark() => darkVariants.first.build();

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

/// Horizontal-slide push used for the mobile drill-down (Notebooks → Sections →
/// Canvases → Canvas): the new page slides in from the right while the page
/// below parallax-shifts left and dims — the "sliding" feel of the redesign
/// (mirrors the mockup's `out-r` → `out-l` screen transition). The parallax is
/// driven by `secondaryAnimation`, so a page shifts out as the next covers it.
Route<T> slideRoute<T>(Widget page) {
  const curve = Curves.easeOutCubic;
  return PageRouteBuilder<T>(
    transitionDuration: const Duration(milliseconds: 300),
    reverseTransitionDuration: const Duration(milliseconds: 260),
    pageBuilder: (_, _, _) => page,
    transitionsBuilder: (_, animation, secondaryAnimation, child) {
      final incoming = Tween<Offset>(
        begin: const Offset(1, 0),
        end: Offset.zero,
      ).chain(CurveTween(curve: curve)).animate(animation);
      final outgoing = Tween<Offset>(
        begin: Offset.zero,
        end: const Offset(-0.28, 0),
      ).chain(CurveTween(curve: curve)).animate(secondaryAnimation);
      final outFade = Tween<double>(
        begin: 1,
        end: 0.35,
      ).chain(CurveTween(curve: curve)).animate(secondaryAnimation);
      return SlideTransition(
        position: outgoing,
        child: FadeTransition(
          opacity: outFade,
          child: SlideTransition(position: incoming, child: child),
        ),
      );
    },
  );
}
