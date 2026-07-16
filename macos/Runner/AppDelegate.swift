import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  // Files/links opened before Flutter's Dart side is ready are buffered, then
  // flushed once Dart signals "ready" over the omninote/open channel.
  private var pendingOpens: [String] = []
  private var openChannel: FlutterMethodChannel?
  private var dartReady = false

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

  override func applicationDidFinishLaunching(_ notification: Notification) {
    if let controller = NSApp.windows
      .compactMap({ $0.contentViewController as? FlutterViewController })
      .first {
      let channel = FlutterMethodChannel(
        name: "omninote/open",
        binaryMessenger: controller.engine.binaryMessenger)
      channel.setMethodCallHandler { [weak self] call, result in
        if call.method == "ready" {
          self?.dartReady = true
          self?.flushPendingOpens()
        }
        result(nil)
      }
      openChannel = channel
    }
    super.applicationDidFinishLaunching(notification)
  }

  // omninote:// share links — and, on modern macOS, file opens too (AppKit
  // prefers this over openFiles when both are implemented). A file URL must be
  // forwarded as a plain path: the Dart side does File(path).readAsBytes(),
  // which can't open a file:// URI string.
  override func application(_ application: NSApplication, open urls: [URL]) {
    for url in urls { enqueueOpen(url.isFileURL ? url.path : url.absoluteString) }
  }

  // Double-clicked / "Open with" .omninote files.
  override func application(_ sender: NSApplication, openFiles filenames: [String]) {
    for name in filenames { enqueueOpen(name) }
    sender.reply(toOpenOrPrint: .success)
  }

  private func enqueueOpen(_ item: String) {
    if dartReady, let channel = openChannel {
      channel.invokeMethod("open", arguments: item)
    } else {
      pendingOpens.append(item)
    }
  }

  private func flushPendingOpens() {
    guard let channel = openChannel else { return }
    for item in pendingOpens { channel.invokeMethod("open", arguments: item) }
    pendingOpens.removeAll()
  }
}
