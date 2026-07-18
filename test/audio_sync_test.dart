import 'package:flutter_test/flutter_test.dart';
import 'package:omininote/utils/audio_sync.dart';

void main() {
  final started = DateTime(2026, 7, 18, 10, 0, 0);

  group('playheadWallclock', () {
    test('is start + position', () {
      expect(
        playheadWallclock(started, const Duration(seconds: 12)),
        DateTime(2026, 7, 18, 10, 0, 12),
      );
    });
  });

  group('strokeActiveAt', () {
    test('a stroke drawn just before the playhead glows', () {
      final playhead = started.add(const Duration(seconds: 10));
      final stroke = started.add(const Duration(seconds: 9)); // 1s before
      expect(strokeActiveAt(stroke, playhead), isTrue);
    });

    test('a stroke drawn long before the playhead has faded out', () {
      final playhead = started.add(const Duration(seconds: 30));
      final stroke = started.add(const Duration(seconds: 5)); // 25s before
      expect(strokeActiveAt(stroke, playhead), isFalse);
    });

    test('a stroke drawn after the playhead does not glow yet', () {
      final playhead = started.add(const Duration(seconds: 10));
      final stroke = started.add(const Duration(seconds: 20)); // future
      expect(strokeActiveAt(stroke, playhead), isFalse);
    });

    test('exactly at the window edge still counts (inclusive)', () {
      final playhead = started.add(const Duration(seconds: 10));
      final stroke = playhead.subtract(kAudioGlowWindow);
      expect(strokeActiveAt(stroke, playhead), isTrue);
      final justOutside =
          playhead.subtract(kAudioGlowWindow + const Duration(milliseconds: 1));
      expect(strokeActiveAt(justOutside, playhead), isFalse);
    });

    test('a custom window is honored', () {
      final playhead = started.add(const Duration(seconds: 10));
      final stroke = started.add(const Duration(seconds: 7)); // 3s before
      expect(strokeActiveAt(stroke, playhead,
              window: const Duration(seconds: 2)),
          isFalse);
      expect(strokeActiveAt(stroke, playhead,
              window: const Duration(seconds: 5)),
          isTrue);
    });
  });
}
