import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omininote/utils/ink_contrast.dart';

int _r(Color c) => (c.toARGB32() >> 16) & 0xFF;
int _g(Color c) => (c.toARGB32() >> 8) & 0xFF;
int _b(Color c) => c.toARGB32() & 0xFF;
int _a(Color c) => (c.toARGB32() >> 24) & 0xFF;

void main() {
  group('reflectLightnessForContrast', () {
    test('black and white flip fully', () {
      expect(reflectLightnessForContrast(const Color(0xFF000000)).toARGB32(),
          0xFFFFFFFF);
      expect(reflectLightnessForContrast(const Color(0xFFFFFFFF)).toARGB32(),
          0xFF000000);
    });

    test('keeps hue — a dark colour becomes a light one of the same hue', () {
      const navy = Color(0xFF1A2B6B);
      final flipped = reflectLightnessForContrast(navy);
      final navyHsl = HSLColor.fromColor(navy);
      final flipHsl = HSLColor.fromColor(flipped);
      expect((flipHsl.hue - navyHsl.hue).abs(), lessThan(1.0));
      expect(flipHsl.lightness, greaterThan(navyHsl.lightness));
    });

    test('is an involution up to HSL rounding', () {
      for (final argb in [0xFF3366CC, 0xFF2E7D32, 0xFFE23B3B, 0xFFEAD24B]) {
        final c = Color(argb);
        final back =
            reflectLightnessForContrast(reflectLightnessForContrast(c));
        expect((_r(back) - _r(c)).abs(), lessThan(3));
        expect((_g(back) - _g(c)).abs(), lessThan(3));
        expect((_b(back) - _b(c)).abs(), lessThan(3));
      }
    });

    test('preserves alpha', () {
      final f = reflectLightnessForContrast(const Color(0x80FF0000));
      expect((_a(f) - 0x80).abs(), lessThan(2));
    });
  });

  group('isDarkBackground', () {
    test('classifies the page presets', () {
      expect(isDarkBackground(const Color(0xFFFFFFFF)), isFalse); // white
      expect(isDarkBackground(const Color(0xFFF8F1E3)), isFalse); // cream
      expect(isDarkBackground(const Color(0xFFEDEDED)), isFalse); // light grey
      expect(isDarkBackground(const Color(0xFF2A2A2E)), isTrue); // charcoal
      expect(isDarkBackground(const Color(0xFF17171A)), isTrue); // near black
    });
  });
}
