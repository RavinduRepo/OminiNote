import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

/// Wraps a single media_kit [Player] to play one canvas video at a time,
/// exposing plain [ValueNotifier]s the floating video bar listens to. One
/// instance is created lazily per open canvas and disposed with it. Mirrors
/// [AudioPlaybackService]'s surface so the UI feels the same.
class VideoPlaybackService {
  final Player _player = Player();
  late final VideoController controller = VideoController(_player);

  /// The asset id currently loaded, or null when stopped.
  final ValueNotifier<String?> currentId = ValueNotifier(null);
  final ValueNotifier<bool> playing = ValueNotifier(false);
  final ValueNotifier<Duration> position = ValueNotifier(Duration.zero);
  final ValueNotifier<Duration> duration = ValueNotifier(Duration.zero);

  /// Playback speed multiplier (1.0 = normal), re-applied on each open.
  final ValueNotifier<double> speed = ValueNotifier(1.0);

  final List<StreamSubscription<dynamic>> _subs = [];

  VideoPlaybackService() {
    _subs.add(_player.stream.position.listen((p) => position.value = p));
    _subs.add(_player.stream.duration.listen((d) => duration.value = d));
    _subs.add(_player.stream.playing.listen((p) => playing.value = p));
    _subs.add(_player.stream.completed.listen((done) {
      if (done) playing.value = false;
    }));
  }

  bool isCurrent(String id) => currentId.value == id;

  /// Loads and plays [filePath] as video [id]. Reloads if it's a different
  /// video; resumes if it's the current one.
  Future<void> play(String id, String filePath) async {
    if (currentId.value == id) {
      await _player.play();
      playing.value = true;
      return;
    }
    currentId.value = id;
    position.value = Duration.zero;
    await _player.open(Media(filePath));
    if (speed.value != 1.0) await _player.setRate(speed.value);
    playing.value = true;
  }

  Future<void> pause() async {
    await _player.pause();
    playing.value = false;
  }

  Future<void> togglePlay() async {
    if (playing.value) {
      await pause();
    } else {
      await _player.play();
      playing.value = true;
    }
  }

  Future<void> seek(Duration to) async {
    final clamped = to < Duration.zero ? Duration.zero : to;
    await _player.seek(clamped);
    position.value = clamped;
  }

  /// Jumps [delta] from the current position (negative = back), clamped.
  Future<void> skip(Duration delta) async {
    var target = position.value + delta;
    final total = duration.value;
    if (total > Duration.zero && target > total) target = total;
    await seek(target);
  }

  Future<void> setSpeed(double rate) async {
    speed.value = rate;
    if (currentId.value != null) await _player.setRate(rate);
  }

  Future<void> stop() async {
    await _player.pause();
    await _player.seek(Duration.zero);
    playing.value = false;
    position.value = Duration.zero;
    currentId.value = null;
  }

  Future<void> dispose() async {
    for (final s in _subs) {
      await s.cancel();
    }
    await _player.dispose();
    currentId.dispose();
    playing.dispose();
    position.dispose();
    duration.dispose();
    speed.dispose();
  }
}
