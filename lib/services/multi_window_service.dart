import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Opens additional OS windows (separate Android tasks/instances) on Android
/// N+. A no-op on other platforms. Each new window runs its own FlutterEngine
/// and Dart isolate, so sync safety across windows is handled separately by the
/// single-owner lease + per-instance journals (see `SyncCoordinator`).
class MultiWindowService {
  static const _channel = MethodChannel('omninote/multiwindow');

  /// Only Android can spawn separate app windows here.
  static bool get platformCanSupport =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  static bool? _supported;

  /// Whether the device supports multi-window (Android N+). Cached.
  static Future<bool> isSupported() async {
    if (!platformCanSupport) return false;
    if (_supported != null) return _supported!;
    try {
      _supported = await _channel.invokeMethod<bool>('isSupported') ?? false;
    } catch (_) {
      _supported = false;
    }
    return _supported!;
  }

  /// Launches another app window (a separate Android task). No-op if the
  /// platform can't support it.
  static Future<void> openNewWindow() async {
    if (!platformCanSupport) return;
    try {
      await _channel.invokeMethod('openNewWindow');
    } catch (_) {}
  }
}
