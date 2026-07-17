import 'dart:async';
import 'dart:io' show Platform;
import 'package:flutter/foundation.dart' show debugPrint, kDebugMode;
import 'package:flutter/services.dart';
import 'package:super_clipboard/super_clipboard.dart';

const MethodChannel _clipboardGuard = MethodChannel('omninote/clipboard_guard');

/// Whether `super_clipboard` can safely read the clipboard right now.
///
/// **Android only, and load-bearing — do not call `SystemClipboard.read()`
/// without it.** `super_native_extensions`' `ClipDataHelper.getFormats` calls
/// `ContentResolver.getStreamTypes()` on any clipboard item carrying a URI and
/// does NOT catch `SecurityException` (still true on their `main`; 0.9.1 is the
/// newest release — there is no version to upgrade to). Clipboard items
/// routinely point at a `FileProvider` that isn't exported and never granted us
/// a URI permission — content synced from a desktop is the common one. The
/// throw then happens on Android's main Looper *inside the plugin's Java*, so it
/// never becomes a Dart exception: it is **not catchable from Dart** and takes
/// the whole process down.
///
/// So `MainActivity.canEnumerateClipboard` makes the same call first, where the
/// catch is ours, and this gates every read on the answer. A `false` costs us
/// nothing — it means we had no permission to read that item's data anyway — so
/// callers just fall back to plain text (`Clipboard.getData`, which routes
/// through Android's own `coerceToText` and already swallows the exception).
///
/// Fails **open** on anything unexpected: every other platform, and any channel
/// error, behaves exactly as before this guard existed.
Future<bool> clipboardIsReadable() async {
  if (!Platform.isAndroid) return true;
  try {
    return await _clipboardGuard.invokeMethod<bool>('canEnumerate') ?? true;
  } catch (e) {
    if (kDebugMode) debugPrint('clipboard guard unavailable: $e');
    return true;
  }
}

/// Cross-platform image clipboard (Android, iOS, macOS, Windows, Linux) on
/// top of `super_clipboard`. Replaces the old `pasteboard` usage — that only
/// covered desktop reads; this covers copy *and* paste everywhere, including
/// Android (content-URI based) and future iOS/macOS builds.
class ClipboardImages {
  const ClipboardImages._();

  /// Puts [bytes] on the OS clipboard as an image. Detects JPEG by magic
  /// number (gallery photos stay JPEG); everything else is written as PNG.
  /// Returns false when the platform clipboard isn't available.
  static Future<bool> write(Uint8List bytes) async {
    final clipboard = SystemClipboard.instance;
    if (clipboard == null) return false;
    final isJpeg = bytes.length > 2 && bytes[0] == 0xFF && bytes[1] == 0xD8;
    final item = DataWriterItem(
      suggestedName: isJpeg ? 'image.jpg' : 'image.png',
    )..add(isJpeg ? Formats.jpeg(bytes) : Formats.png(bytes));
    await clipboard.write([item]);
    return true;
  }

  /// Reads an image off the OS clipboard, trying the common raster formats.
  /// Null when there is no image (or no clipboard access on this platform).
  static Future<Uint8List?> read() async {
    final clipboard = SystemClipboard.instance;
    if (clipboard == null) return null;
    // Must come first — see [clipboardIsReadable]. Without it, an unreadable
    // clipboard URI crashes the process instead of returning null.
    if (!await clipboardIsReadable()) return null;
    final reader = await clipboard.read();
    // Try formats in preference order; first one the source app provides wins.
    const formats = [
      Formats.png,
      Formats.jpeg,
      Formats.gif,
      Formats.webp,
      Formats.bmp,
      Formats.tiff,
    ];
    for (final format in formats) {
      if (!reader.canProvide(format)) continue;
      final completer = Completer<Uint8List?>();
      reader.getFile(format, (file) async {
        try {
          completer.complete(await file.readAll());
        } catch (_) {
          completer.complete(null);
        }
      }, onError: (_) => completer.complete(null));
      final bytes = await completer.future;
      if (bytes != null && bytes.isNotEmpty) return bytes;
    }
    return null;
  }
}

/// OS-clipboard HTML interop (same `super_clipboard` plumbing as
/// [ClipboardImages]). Rich text copied from browsers/Word/OneNote rides the
/// clipboard as an HTML flavor alongside the plain-text one — reading it is
/// what lets paste keep formatting.
class ClipboardHtml {
  const ClipboardHtml._();

  /// The clipboard's HTML flavor, or null when the source app only offered
  /// plain text (or no clipboard access on this platform).
  static Future<String?> read() async {
    final clipboard = SystemClipboard.instance;
    if (clipboard == null) return null;
    // Same crash, same guard — this read enumerates formats too.
    if (!await clipboardIsReadable()) return null;
    final reader = await clipboard.read();
    if (!reader.canProvide(Formats.htmlText)) return null;
    final html = await reader.readValue(Formats.htmlText);
    return (html == null || html.trim().isEmpty) ? null : html;
  }

  /// Writes [html] + [plainText] together as one clipboard item, so rich
  /// targets paste formatted text and plain targets get the fallback.
  /// Returns false when the platform clipboard isn't available.
  static Future<bool> write(String html, String plainText) async {
    final clipboard = SystemClipboard.instance;
    if (clipboard == null) return false;
    final item = DataWriterItem()
      ..add(Formats.htmlText(html))
      ..add(Formats.plainText(plainText));
    await clipboard.write([item]);
    return true;
  }
}
