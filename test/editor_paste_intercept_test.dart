import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// The canvas text editor intercepts paste so an image on the clipboard can go
/// into the DOCUMENT instead of being silently dropped (Flutter's default paste
/// reads text/plain only, and the canvas's own shortcut handler bails out
/// entirely while a text edit is open — the field owns its keys).
///
/// The interception is an `Actions` override of [PasteTextIntent] wrapped
/// around the editor's `TextField`. That only works because EditableText
/// registers its paste action as `Action.overridable` (editable_text.dart:
/// `PasteTextIntent: _makeOverridable(_PasteSelectionAction(this))`), which
/// consults ancestor `Actions` first. These tests pin that the override is
/// actually reached — from BOTH the keyboard and a programmatic invoke — since
/// nothing else in the suite would notice if the intent silently stopped
/// routing to us.
void main() {
  Future<int> pumpAndPaste(
    WidgetTester tester, {
    required Future<void> Function() sendPaste,
  }) async {
    var intercepted = 0;
    final controller = TextEditingController(text: 'hello');
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Actions(
            actions: {
              PasteTextIntent: CallbackAction<PasteTextIntent>(
                onInvoke: (intent) {
                  intercepted++;
                  return null;
                },
              ),
            },
            child: TextField(controller: controller, autofocus: true),
          ),
        ),
      ),
    );
    await tester.pump();
    await sendPaste();
    await tester.pump();
    return intercepted;
  }

  testWidgets('Ctrl+V routes to our override, not the default paste', (
    tester,
  ) async {
    final hits = await pumpAndPaste(
      tester,
      sendPaste: () async {
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyDownEvent(LogicalKeyboardKey.keyV);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.keyV);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      },
    );
    expect(hits, 1, reason: 'the Actions override must intercept Ctrl+V');
  },
      variant: const TargetPlatformVariant({
        TargetPlatform.windows,
        TargetPlatform.linux,
      }));

  testWidgets('Cmd+V routes to our override on macOS', (tester) async {
    final hits = await pumpAndPaste(
      tester,
      sendPaste: () async {
        await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
        await tester.sendKeyDownEvent(LogicalKeyboardKey.keyV);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.keyV);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      },
    );
    expect(hits, 1, reason: 'the Actions override must intercept Cmd+V');
  }, variant: const TargetPlatformVariant({TargetPlatform.macOS}));

  testWidgets(
    'a programmatic PasteTextIntent (the context menu path) also routes to us',
    (tester) async {
      // The context menu's "Paste" invokes the same intent, so covering the
      // invoke path covers the menu without driving platform menu UI.
      final hits = await pumpAndPaste(
        tester,
        sendPaste: () async {
          final ctx = tester.element(find.byType(TextField));
          Actions.invoke(ctx, const PasteTextIntent(SelectionChangedCause.tap));
        },
      );
      expect(hits, 1);
    },
  );
}
