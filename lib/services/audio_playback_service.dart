import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';

/// Wraps a single `audioplayers` AudioPlayer to play one canvas recording at a
/// time, exposing plain [ValueNotifier]s the UI (and the audio-sync painter)
/// can listen to. One instance is created lazily per open canvas and disposed
/// with it.
class AudioPlaybackService {
  final AudioPlayer _player = AudioPlayer();

  /// The recording id currently loaded, or null when stopped.
  final ValueNotifier<String?> currentId = ValueNotifier(null);
  final ValueNotifier<bool> playing = ValueNotifier(false);
  final ValueNotifier<Duration> position = ValueNotifier(Duration.zero);
  final ValueNotifier<Duration> duration = ValueNotifier(Duration.zero);

  /// Playback speed multiplier (1.0 = normal). Persisted for the session on
  /// this player and re-applied to every take that starts.
  final ValueNotifier<double> speed = ValueNotifier(1.0);

  /// True while paused mid-take (so [play] resumes); false after a stop or a
  /// natural finish (so [play] restarts from the top instead of no-op resuming
  /// an ended player — the "can't replay after it finishes" bug).
  bool _paused = false;

  /// Where a fresh [play] of the current recording should begin — set when the
  /// user scrubs while it isn't playing (e.g. after it finished), so dragging
  /// the playhead back and pressing play replays from there.
  Duration? _resumeFrom;

  AudioPlaybackService() {
    _player.onPositionChanged.listen((p) => position.value = p);
    _player.onDurationChanged.listen((d) => duration.value = d);
    _player.onPlayerStateChanged
        .listen((s) => playing.value = s == PlayerState.playing);
    _player.onPlayerComplete.listen((_) {
      // Reset to the start so the scrubber returns home and Play replays it.
      playing.value = false;
      _paused = false;
      _resumeFrom = null;
      position.value = Duration.zero;
    });
  }

  bool isCurrent(String id) => currentId.value == id;

  /// Reads the total duration of an audio file on a throwaway player, without
  /// touching the live playback state. Used when importing an audio file (which,
  /// unlike an in-app recording, doesn't already know its length). Returns null
  /// if the length can't be determined within a short window.
  static Future<Duration?> probeDuration(String filePath) async {
    final p = AudioPlayer();
    final completer = Completer<Duration?>();
    StreamSubscription<Duration>? sub;
    try {
      sub = p.onDurationChanged.listen((d) {
        if (!completer.isCompleted) completer.complete(d);
      });
      await p.setSourceDeviceFile(filePath);
      // Some platforms populate the duration synchronously after setSource.
      final direct = await p.getDuration();
      if (direct != null && !completer.isCompleted) completer.complete(direct);
      return await completer.future
          .timeout(const Duration(seconds: 3), onTimeout: () => null);
    } catch (_) {
      return null;
    } finally {
      await sub?.cancel();
      await p.dispose();
    }
  }

  /// Plays [filePath] as recording [id]. Resumes when it's the paused current
  /// recording; otherwise starts fresh from the top (or from a prior scrub via
  /// [_resumeFrom]) — this covers a different recording, a stopped one, and a
  /// finished one (replay). [total] seeds the duration before the source
  /// reports it (avoids a 0-length scrubber flash).
  Future<void> play(String id, String filePath, {Duration? total}) async {
    if (currentId.value == id && _paused) {
      _paused = false;
      await _player.resume();
    } else {
      final from = currentId.value == id ? _resumeFrom : null;
      currentId.value = id;
      _paused = false;
      _resumeFrom = null;
      if (total != null) duration.value = total;
      await _player.stop();
      await _player.play(DeviceFileSource(filePath));
      // Re-apply the chosen speed — a fresh play() resets the rate to 1.0.
      if (speed.value != 1.0) await _player.setPlaybackRate(speed.value);
      if (from != null && from > Duration.zero) {
        await _player.seek(from);
        position.value = from;
      } else {
        position.value = Duration.zero;
      }
    }
    playing.value = true;
  }

  Future<void> pause() async {
    await _player.pause();
    _paused = true;
    playing.value = false;
  }

  Future<void> seek(Duration to) async {
    final clamped = to < Duration.zero ? Duration.zero : to;
    await _player.seek(clamped);
    position.value = clamped;
    // Scrubbed while stopped/finished → remember it as the replay start point.
    if (!playing.value) _resumeFrom = clamped;
  }

  /// Jumps [delta] from the current position (negative = back), clamped to the
  /// known duration. The quick ±seconds controls in the floating player.
  Future<void> skip(Duration delta) async {
    var target = position.value + delta;
    final total = duration.value;
    if (total > Duration.zero && target > total) target = total;
    await seek(target);
  }

  /// Sets the playback speed and applies it live if a take is loaded.
  Future<void> setSpeed(double rate) async {
    speed.value = rate;
    if (currentId.value != null) await _player.setPlaybackRate(rate);
  }

  Future<void> stop() async {
    await _player.stop();
    playing.value = false;
    _paused = false;
    _resumeFrom = null;
    position.value = Duration.zero;
    currentId.value = null;
  }

  Future<void> dispose() async {
    await _player.dispose();
    currentId.dispose();
    playing.dispose();
    position.dispose();
    duration.dispose();
    speed.dispose();
  }
}
