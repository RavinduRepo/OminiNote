import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';

/// Wraps a single `audioplayers` AudioPlayer to play one canvas recording at a
/// time, exposing plain [ValueNotifier]s the UI (and, later, the audio-sync
/// painter) can listen to. One instance is created lazily per open canvas and
/// disposed with it.
class AudioPlaybackService {
  final AudioPlayer _player = AudioPlayer();

  /// The recording id currently loaded, or null when stopped.
  final ValueNotifier<String?> currentId = ValueNotifier(null);
  final ValueNotifier<bool> playing = ValueNotifier(false);
  final ValueNotifier<Duration> position = ValueNotifier(Duration.zero);
  final ValueNotifier<Duration> duration = ValueNotifier(Duration.zero);

  AudioPlaybackService() {
    _player.onPositionChanged.listen((p) => position.value = p);
    _player.onDurationChanged.listen((d) => duration.value = d);
    _player.onPlayerStateChanged
        .listen((s) => playing.value = s == PlayerState.playing);
    _player.onPlayerComplete.listen((_) {
      playing.value = false;
      position.value = duration.value;
    });
  }

  bool isCurrent(String id) => currentId.value == id;

  /// Plays [filePath] as recording [id] — from the start when switching to a
  /// different recording, else resumes the current one. [total] seeds the
  /// duration before the source reports it (avoids a 0-length scrubber flash).
  Future<void> play(String id, String filePath, {Duration? total}) async {
    if (currentId.value != id) {
      currentId.value = id;
      position.value = Duration.zero;
      if (total != null) duration.value = total;
      await _player.stop();
      await _player.play(DeviceFileSource(filePath));
    } else {
      await _player.resume();
    }
    playing.value = true;
  }

  Future<void> pause() async {
    await _player.pause();
    playing.value = false;
  }

  Future<void> seek(Duration to) => _player.seek(to);

  Future<void> stop() async {
    await _player.stop();
    playing.value = false;
    position.value = Duration.zero;
    currentId.value = null;
  }

  Future<void> dispose() async {
    await _player.dispose();
    currentId.dispose();
    playing.dispose();
    position.dispose();
    duration.dispose();
  }
}
