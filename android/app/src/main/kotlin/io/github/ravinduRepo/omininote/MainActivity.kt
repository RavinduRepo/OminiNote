package io.github.ravinduRepo.omininote

import android.content.ClipboardManager
import android.content.Context
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            CLIPBOARD_CHANNEL,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "canEnumerate" -> result.success(canEnumerateClipboard())
                else -> result.notImplemented()
            }
        }
    }

    /**
     * Whether it is safe to let super_clipboard read the clipboard.
     *
     * super_native_extensions' ClipDataHelper.getFormats calls
     * ContentResolver.getStreamTypes() on any clipboard item carrying a URI,
     * WITHOUT catching SecurityException (still true on their `main`, and 0.9.1
     * is the newest release). A clipboard item can easily point at a
     * FileProvider that is not exported and never granted us a URI permission —
     * e.g. content synced from a desktop. getStreamTypes then throws on the main
     * Looper inside the plugin's Java, so it never becomes a Dart exception and
     * no Dart try/catch can stop it: the process simply dies.
     *
     * So we make the exact same call FIRST, here, where the catch is ours. If it
     * throws, Dart skips super_clipboard and falls back to plain text — which
     * loses nothing, because a throw means we had no permission to read that
     * item's data anyway. Android's own ClipData.Item.coerceToText (what
     * Flutter's Clipboard.getData uses) already swallows SecurityException, so
     * the fallback is safe.
     *
     * Returns true when there's nothing to worry about (no clip, no URI items,
     * or every URI answered), false when any item would blow up.
     */
    private fun canEnumerateClipboard(): Boolean {
        return try {
            val manager =
                getSystemService(Context.CLIPBOARD_SERVICE) as? ClipboardManager
                    ?: return false
            val clip = manager.primaryClip ?: return true
            for (i in 0 until clip.itemCount) {
                val uri = clip.getItemAt(i).uri ?: continue
                // The call that kills us — made here so the catch is ours.
                contentResolver.getStreamTypes(uri, "*/*")
            }
            true
        } catch (e: SecurityException) {
            false
        } catch (e: Exception) {
            // Any other provider misbehaviour: treat as unreadable rather than
            // let it reach the plugin, which wouldn't catch it either.
            false
        }
    }

    companion object {
        private const val CLIPBOARD_CHANNEL = "omninote/clipboard_guard"
    }
}
