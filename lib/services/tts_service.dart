import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';

import '../utils/readable_text.dart';
import 'settings_service.dart';

/// Speaks a queue of [ReadingUnit]s (read-aloud). One instance is created lazily
/// per open canvas and disposed with it, mirroring [AudioPlaybackService].
///
/// It drives one *sentence* utterance at a time and advances on the backend's
/// completion signal, so pause/skip/scope-change stay responsive. Two things
/// make it robust cross-platform:
///  * **Pause = stop + restart-the-current-sentence** (real mid-utterance pause
///    is inconsistent across engines, and sentences are short).
///  * **The next sentence is spoken on a fresh event-loop turn, never
///    synchronously inside the engine's completion callback** — re-entering the
///    synthesizer from its own callback crashes the Windows plugin (Android
///    tolerates it). A `_gen` counter ignores completions from a
///    superseded/paused/stopped utterance.
///
/// Backends: [_FlutterTtsBackend] on Android/iOS/macOS/Windows; [_LinuxTtsBackend]
/// (espeak / spd-say) on Linux, where `flutter_tts` has no plugin.
class TtsService {
  TtsService() : _backend = _makeBackend() {
    _backend.onComplete(_onUtteranceDone);
  }

  final _TtsBackend _backend;
  bool _initialized = false;

  // The user's manually-pinned voice (device-local; null = none chosen, so
  // whatever the engine defaults to). This is the voice used for Latin-script
  // text; non-Latin scripts (e.g. Sinhala) auto-switch to a matching
  // installed voice per sentence — see [_applyVoiceFor] — so a pinned English
  // voice doesn't silently force every language to English.
  String? _manualVoiceName;
  String? _manualVoiceLocale;

  // The installed-voices list, cached once (mirrors availableVoices(), kept
  // internal so per-sentence language switching doesn't re-query the plugin).
  List<({String name, String locale})> _voicesCache = const [];

  // The language currently applied to the backend (2-letter code, lowercase),
  // so unchanged-language runs of sentences don't re-issue setVoice calls.
  String? _appliedLangCode;

  /// Speed multiplier (1.0 = the engine's normal rate). Re-applied on each
  /// utterance so a mid-read change takes effect on the next sentence.
  final ValueNotifier<double> speed = ValueNotifier(1.0);

  final ValueNotifier<bool> speaking = ValueNotifier(false);
  final ValueNotifier<bool> paused = ValueNotifier(false);

  /// Index of the sentence currently being (or about to be) spoken, and the
  /// total in the queue — drives the reader bar's progress + which page to show.
  final ValueNotifier<int> index = ValueNotifier(0);
  final ValueNotifier<int> total = ValueNotifier(0);

  List<ReadingUnit> _units = const [];
  // Bumped on every stop/skip/jump/pause so a late completion callback from a
  // superseded utterance can't advance the (already-moved) queue.
  int _gen = 0;
  // The [_gen] value at the moment the current utterance was handed to the
  // backend; a completion is "natural" only when it still matches.
  int _speakingGen = -1;

  /// The unit currently pointed at, or null when the queue is empty/finished.
  ReadingUnit? get current =>
      (index.value >= 0 && index.value < _units.length)
          ? _units[index.value]
          : null;

  bool get isSupported => _backend.isSupported;

  Future<void> _ensureInit() async {
    if (_initialized) return;
    _initialized = true;
    await _backend.init();
    _voicesCache = await _backend.voices();
    // Apply a previously chosen voice (device-local), if any — this is the
    // voice Latin-script text reads in; see _applyVoiceFor for the per-
    // sentence non-Latin auto-switch.
    _manualVoiceName = SettingsService().ttsVoiceName;
    _manualVoiceLocale = SettingsService().ttsVoiceLocale;
    if (_manualVoiceName != null && _manualVoiceLocale != null) {
      await _backend.setVoice(_manualVoiceName!, _manualVoiceLocale!);
      _appliedLangCode = _langCodeOf(_manualVoiceLocale!);
    }
  }

  static String _langCodeOf(String locale) =>
      locale.replaceAll('_', '-').split('-').first.toLowerCase();

  /// Auto-switches voice for non-Latin-script text (detected via
  /// [detectScriptLanguage]) even when the user has pinned a different voice
  /// for their primary (Latin-script) language — this is what makes e.g.
  /// Sinhala sentences read correctly again instead of being forced through
  /// a manually-pinned English voice. Latin/ambiguous text falls back to the
  /// pinned voice (or whatever the engine already has, if none is pinned).
  /// A no-op when the device has no installed voice for the detected
  /// language (best-effort only — voice sets differ a lot across OSes).
  Future<void> _applyVoiceFor(String text) async {
    final detected = detectScriptLanguage(text);
    final targetLang = detected ??
        (_manualVoiceLocale != null ? _langCodeOf(_manualVoiceLocale!) : null);
    if (targetLang == null || targetLang == _appliedLangCode) return;
    if (detected != null) {
      // Look up an installed voice for the detected language — prefer one
      // matching the user's pinned region if it happens to also match.
      final matches = [
        for (final v in _voicesCache)
          if (_langCodeOf(v.locale) == detected) v
      ];
      if (matches.isEmpty) return; // nothing installed for this language
      final pick = matches.firstWhere(
        (v) => _manualVoiceLocale != null && v.locale == _manualVoiceLocale,
        orElse: () => matches.first,
      );
      await _backend.setVoice(pick.name, pick.locale);
      _appliedLangCode = detected;
    } else if (_manualVoiceName != null && _manualVoiceLocale != null) {
      await _backend.setVoice(_manualVoiceName!, _manualVoiceLocale!);
      _appliedLangCode = targetLang;
    }
  }

  /// Loads [units] starting at [startIndex] **without speaking** — the reader
  /// opens paused-at-position, and playback begins only when the user presses
  /// play (→ [resume]). Replaces any current queue.
  Future<void> load(List<ReadingUnit> units, {int startIndex = 0}) async {
    await _ensureInit();
    _gen++;
    await _backend.stop();
    _units = units;
    total.value = units.length;
    index.value = units.isEmpty ? 0 : startIndex.clamp(0, units.length - 1);
    speaking.value = false;
    paused.value = false;
  }

  /// Loads [units] and immediately starts reading (kept for completeness; the
  /// UI uses [load] + [resume] so opening the reader doesn't auto-play).
  Future<void> speakAll(List<ReadingUnit> units, {int startIndex = 0}) async {
    await load(units, startIndex: startIndex);
    if (units.isNotEmpty) await resume();
  }

  Future<void> _speakCurrent() async {
    final unit = current;
    if (unit == null) {
      await _finish();
      return;
    }
    final myGen = _gen;
    await _backend.setRate(speed.value);
    if (myGen != _gen) return; // superseded while awaiting
    await _applyVoiceFor(unit.text);
    if (myGen != _gen) return; // superseded while awaiting
    _speakingGen = _gen;
    await _backend.speak(unit.text);
  }

  void _onUtteranceDone() {
    // Ignore completions from a superseded/paused/stopped utterance.
    if (!speaking.value || paused.value || _gen != _speakingGen) return;
    if (index.value >= _units.length - 1) {
      unawaited(_finish());
      return;
    }
    index.value = index.value + 1;
    // Advance on a fresh event-loop turn, NOT synchronously inside the engine's
    // completion callback (Windows crashes if the synthesizer is re-entered
    // from its own callback). Re-check state when it runs.
    final scheduledGen = _gen;
    Future(() {
      if (scheduledGen == _gen && speaking.value && !paused.value) {
        unawaited(_speakCurrent());
      }
    });
  }

  Future<void> _finish() async {
    speaking.value = false;
    paused.value = false;
    // Leave index at the end so the bar reads "done"; a fresh play restarts.
  }

  Future<void> pause() async {
    if (!speaking.value || paused.value) return;
    _gen++;
    paused.value = true;
    speaking.value = false;
    await _backend.stop();
  }

  Future<void> resume() async {
    if (paused.value) {
      paused.value = false;
      speaking.value = true;
      await _speakCurrent();
    } else if (!speaking.value && _units.isNotEmpty) {
      // Loaded-but-not-started, or finished → play from the current index.
      if (index.value >= _units.length) index.value = 0;
      speaking.value = true;
      await _speakCurrent();
    }
  }

  /// Jumps by [delta] sentences (±1 for next/prev).
  Future<void> skip(int delta) => jumpTo(index.value + delta);

  /// Jumps to sentence [target] (clamped) and starts speaking it — the tap-to-
  /// jump target. Reads from here even if it was paused/finished.
  Future<void> jumpTo(int target) async {
    if (_units.isEmpty) return;
    _gen++;
    await _backend.stop();
    index.value = target.clamp(0, _units.length - 1);
    paused.value = false;
    speaking.value = true;
    await _speakCurrent();
  }

  Future<void> setSpeed(double value) async {
    speed.value = value;
    await _backend.setRate(value);
  }

  /// The installed voices (name + locale). Empty on Linux/espeak.
  Future<List<({String name, String locale})>> availableVoices() async {
    await _ensureInit();
    _voicesCache = await _backend.voices();
    return _voicesCache;
  }

  /// Picks [name]/[locale] as the reading voice (device-local, applied live).
  /// This becomes the voice used for Latin-script text; non-Latin scripts
  /// keep auto-switching per sentence regardless (see [_applyVoiceFor]).
  Future<void> setVoice(String name, String locale) async {
    await SettingsService().setTtsVoice(name, locale);
    await _ensureInit();
    _manualVoiceName = name;
    _manualVoiceLocale = locale;
    await _backend.setVoice(name, locale);
    _appliedLangCode = _langCodeOf(locale);
  }

  Future<void> stop() async {
    _gen++;
    speaking.value = false;
    paused.value = false;
    index.value = 0;
    _units = const [];
    total.value = 0;
    await _backend.stop();
  }

  Future<void> dispose() async {
    _gen++;
    await _backend.dispose();
    speed.dispose();
    speaking.dispose();
    paused.dispose();
    index.dispose();
    total.dispose();
  }
}

_TtsBackend _makeBackend() =>
    Platform.isLinux ? _LinuxTtsBackend() : _FlutterTtsBackend();

/// A speech engine the [TtsService] driver sits on top of. [speak] starts one
/// utterance; [onComplete]'s callback must fire when it finishes naturally
/// (never when [stop] cancelled it).
abstract class _TtsBackend {
  bool get isSupported;
  Future<void> init();
  Future<void> speak(String text);
  Future<void> stop();
  Future<void> setRate(double multiplier);
  Future<List<({String name, String locale})>> voices();
  Future<void> setVoice(String name, String locale);
  void onComplete(VoidCallback cb);
  Future<void> dispose();
}

class _FlutterTtsBackend implements _TtsBackend {
  final FlutterTts _tts = FlutterTts();
  VoidCallback? _onComplete;

  @override
  bool get isSupported => true;

  @override
  Future<void> init() async {
    _tts.setCompletionHandler(() => _onComplete?.call());
    // A synth error shouldn't stall the queue — treat it as "move on".
    _tts.setErrorHandler((_) => _onComplete?.call());
    // Deliberately NOT calling awaitSpeakCompletion(true): the driver advances
    // via the completion handler, and holding a pending speak future was extra
    // dual-signalling that made Windows flakier.
  }

  @override
  Future<void> speak(String text) async {
    try {
      await _tts.speak(text);
    } catch (_) {
      _onComplete?.call();
    }
  }

  @override
  Future<void> stop() async {
    try {
      await _tts.stop();
    } catch (_) {}
  }

  @override
  Future<void> setRate(double multiplier) async {
    // flutter_tts speech rate is roughly 0..1 with ~0.5 as normal on the major
    // engines; map the multiplier onto that and clamp.
    final rate = (0.5 * multiplier).clamp(0.0, 1.0);
    try {
      await _tts.setSpeechRate(rate);
    } catch (_) {}
  }

  @override
  Future<List<({String name, String locale})>> voices() async {
    try {
      final raw = await _tts.getVoices;
      final out = <({String name, String locale})>[];
      if (raw is List) {
        for (final v in raw) {
          if (v is Map) {
            final n = v['name']?.toString();
            final l = (v['locale'] ?? v['language'])?.toString() ?? '';
            if (n != null && n.isNotEmpty) out.add((name: n, locale: l));
          }
        }
      }
      // Stable order: by locale then name.
      out.sort((a, b) {
        final l = a.locale.compareTo(b.locale);
        return l != 0 ? l : a.name.compareTo(b.name);
      });
      return out;
    } catch (_) {
      return const [];
    }
  }

  @override
  Future<void> setVoice(String name, String locale) async {
    try {
      await _tts.setVoice({'name': name, 'locale': locale});
    } catch (_) {}
  }

  @override
  void onComplete(VoidCallback cb) => _onComplete = cb;

  @override
  Future<void> dispose() async {
    await stop();
  }
}

/// Linux backend: `flutter_tts` has no Linux plugin, so shell out to
/// `spd-say` (speech-dispatcher, `-w` waits until done) or `espeak`. If neither
/// is installed, [isSupported] is false and the reader surfaces a hint.
class _LinuxTtsBackend implements _TtsBackend {
  String? _cmd; // 'spd-say' | 'espeak'
  double _multiplier = 1.0;
  Process? _proc;
  VoidCallback? _onComplete;
  bool _cancelled = false;

  @override
  bool get isSupported => _cmd != null;

  @override
  Future<void> init() async {
    for (final candidate in ['spd-say', 'espeak']) {
      if (await _exists(candidate)) {
        _cmd = candidate;
        break;
      }
    }
  }

  Future<bool> _exists(String cmd) async {
    try {
      final r = await Process.run('which', [cmd]);
      return r.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> speak(String text) async {
    final cmd = _cmd;
    if (cmd == null) {
      _onComplete?.call();
      return;
    }
    _cancelled = false;
    try {
      final args = cmd == 'spd-say'
          // -w: wait until finished; -r: rate -100..100.
          ? ['-w', '-r', _spdRate().toString(), text]
          // espeak -s: words/minute (~175 normal).
          : ['-s', _espeakWpm().toString(), text];
      final proc = await Process.start(cmd, args);
      _proc = proc;
      await proc.exitCode;
      _proc = null;
      if (!_cancelled) _onComplete?.call();
    } catch (_) {
      _proc = null;
      if (!_cancelled) _onComplete?.call();
    }
  }

  int _spdRate() => (100 * (_multiplier - 1.0)).clamp(-100, 100).round();
  int _espeakWpm() => (175 * _multiplier).clamp(80, 450).round();

  @override
  Future<void> stop() async {
    _cancelled = true;
    final proc = _proc;
    _proc = null;
    if (proc != null) {
      proc.kill();
    } else if (_cmd == 'spd-say') {
      // Cancel anything already queued in speech-dispatcher.
      try {
        await Process.run('spd-say', ['-C']);
      } catch (_) {}
    }
  }

  @override
  Future<void> setRate(double multiplier) async => _multiplier = multiplier;

  @override
  Future<List<({String name, String locale})>> voices() async => const [];

  @override
  Future<void> setVoice(String name, String locale) async {}

  @override
  void onComplete(VoidCallback cb) => _onComplete = cb;

  @override
  Future<void> dispose() async => stop();
}
