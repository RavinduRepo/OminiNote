import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

/// The result of a finished recording: a temp file the caller must store as a
/// content-addressed asset (then delete), plus the timing needed to build an
/// [AudioRecording]. [startedAt] is the wall-clock start, so it lines up with
/// each `StrokeElement.createdAt` for audio-sync.
class RecordingResult {
  final String path;
  final DateTime startedAt;
  final Duration duration;

  RecordingResult({
    required this.path,
    required this.startedAt,
    required this.duration,
  });
}

/// Thin wrapper over the `record` plugin: records aacLc (.m4a, playable
/// everywhere) to a temp file. Stateless about storage — the controller turns a
/// [RecordingResult] into a stored asset + `Canvas.recordings` entry. One
/// instance is created lazily per open canvas and disposed with it.
class AudioRecorderService {
  final AudioRecorder _rec = AudioRecorder();
  DateTime? _startedAt;
  String? _path;

  bool get isRecording => _startedAt != null;
  DateTime? get startedAt => _startedAt;

  /// Whether the mic is available; requests the permission if not yet granted.
  Future<bool> hasPermission() => _rec.hasPermission();

  /// Begins recording to a fresh temp file. Returns false (and records nothing)
  /// if permission is denied or a recording is already in progress.
  Future<bool> start() async {
    if (isRecording) return true;
    if (!await _rec.hasPermission()) return false;
    final dir = await getTemporaryDirectory();
    final path =
        '${dir.path}/omninote_rec_${DateTime.now().millisecondsSinceEpoch}.m4a';
    await _rec.start(const RecordConfig(encoder: AudioEncoder.aacLc),
        path: path);
    _startedAt = DateTime.now();
    _path = path;
    return true;
  }

  /// Stops and returns where/when it recorded, or null if nothing was running.
  Future<RecordingResult?> stop() async {
    if (!isRecording) return null;
    final started = _startedAt!;
    final duration = DateTime.now().difference(started);
    final stoppedPath = await _rec.stop() ?? _path;
    _startedAt = null;
    final tmp = _path;
    _path = null;
    if (stoppedPath == null) return null;
    return RecordingResult(
      path: stoppedPath == '' ? (tmp ?? stoppedPath) : stoppedPath,
      startedAt: started,
      duration: duration,
    );
  }

  /// Aborts an in-progress recording and best-effort deletes the temp file.
  Future<void> cancel() async {
    if (isRecording) {
      try {
        await _rec.stop();
      } catch (_) {}
    }
    final tmp = _path;
    _startedAt = null;
    _path = null;
    if (tmp != null) {
      try {
        await File(tmp).delete();
      } catch (_) {}
    }
  }

  Future<void> dispose() async {
    if (isRecording) {
      try {
        await _rec.stop();
      } catch (_) {}
    }
    await _rec.dispose();
  }
}
