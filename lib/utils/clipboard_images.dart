import 'dart:async';
import 'dart:typed_data';
import 'package:super_clipboard/super_clipboard.dart';

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
    final item = DataWriterItem(suggestedName: isJpeg ? 'image.jpg' : 'image.png')
      ..add(isJpeg ? Formats.jpeg(bytes) : Formats.png(bytes));
    await clipboard.write([item]);
    return true;
  }

  /// Reads an image off the OS clipboard, trying the common raster formats.
  /// Null when there is no image (or no clipboard access on this platform).
  static Future<Uint8List?> read() async {
    final clipboard = SystemClipboard.instance;
    if (clipboard == null) return null;
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
      reader.getFile(
        format,
        (file) async {
          try {
            completer.complete(await file.readAll());
          } catch (_) {
            completer.complete(null);
          }
        },
        onError: (_) => completer.complete(null),
      );
      final bytes = await completer.future;
      if (bytes != null && bytes.isNotEmpty) return bytes;
    }
    return null;
  }
}
