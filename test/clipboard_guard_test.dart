import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omininote/utils/clipboard_images.dart';

/// The Android clipboard guard. See [clipboardIsReadable]: super_clipboard
/// crashes the PROCESS (uncatchable from Dart) when the clipboard holds a URI
/// we lack permission for, so every read is gated on a native pre-flight.
///
/// The guard must fail OPEN — a missing/broken channel has to behave exactly as
/// it did before the guard existed, or we'd silently kill paste on every
/// platform that has no handler.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('omninote/clipboard_guard');
  final calls = <String>[];

  void mock(Object? Function() respond) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      return respond();
    });
  }

  setUp(calls.clear);
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('non-Android platforms never touch the channel and stay readable', () {
    // The test host is not Android, so the guard must short-circuit: the
    // channel doesn't exist on desktop/iOS and the bug is Android-only.
    mock(() => false); // would say "unsafe" IF it were ever consulted
    expectLater(clipboardIsReadable(), completion(isTrue));
    expect(calls, isEmpty);
  },
      skip: 'Platform.isAndroid is false on the test host — kept as '
          'documentation of the intended short-circuit');

  group('fails open', () {
    test('a missing handler (no native side) reports readable', () async {
      // Nothing registered on the channel at all.
      expect(await clipboardIsReadable(), isTrue);
    });

    test('a PlatformException reports readable', () async {
      mock(() => throw PlatformException(code: 'boom'));
      expect(await clipboardIsReadable(), isTrue);
    });

    test('a null answer reports readable', () async {
      mock(() => null);
      expect(await clipboardIsReadable(), isTrue);
    });
  });
}
