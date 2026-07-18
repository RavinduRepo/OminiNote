package io.github.ravinduRepo.omininote

import android.app.ActivityOptions
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.graphics.Rect
import android.os.Build
import android.util.Log
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
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            MULTIWINDOW_CHANNEL,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "isSupported" -> result.success(isMultiWindowSupported())
                "openNewWindow" -> {
                    openNewWindow()
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
    }

    /**
     * Multi-window / multi-instance needs Android N (24)+; minSdk here is 23, so
     * the app gracefully hides the feature on API 23.
     */
    private fun isMultiWindowSupported(): Boolean =
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.N

    /**
     * Launches another instance of the app in a **separate task/window** (its
     * own Recents entry; side-by-side on large screens / DeX / freeform). Each
     * such Activity gets its own FlutterEngine → its own Dart isolate, so the
     * Dart side must coordinate sync (single-owner lease + per-instance journals)
     * to avoid two writers over the same store.
     */
    private fun openNewWindow() {
        // NEW_TASK + MULTIPLE_TASK is the reliable "multiple instances of the
        // same activity" recipe. We deliberately DON'T set NEW_DOCUMENT: it
        // keys the task by the intent's data, and with no data every launch
        // looks like the same document, so Android reuses the first task
        // instead of making a new one ("opens once, then never again"). A fresh
        // unique action string further guarantees the system can't fold this
        // launch into an existing task.
        val intent = Intent(this, MainActivity::class.java).apply {
            action = "io.github.ravinduRepo.omininote.NEW_WINDOW." +
                System.nanoTime().toString()
            addFlags(
                Intent.FLAG_ACTIVITY_NEW_TASK or
                    Intent.FLAG_ACTIVITY_MULTIPLE_TASK,
            )
        }
        // Request a floating window ~60% of the screen, cascaded so each new
        // window is visibly offset instead of stacked exactly on top of the
        // parent. Honored on freeform / DeX / One UI pop-up mode; ignored on a
        // plain full-screen phone (the new task just launches full-screen —
        // Android won't force a floating window there).
        val options = ActivityOptions.makeBasic()
        try {
            val m = resources.displayMetrics
            val bw = (m.widthPixels * 0.6).toInt()
            val bh = (m.heightPixels * 0.6).toInt()
            val step = (36 * m.density).toInt()
            val n = (windowCascade++ % 6) + 1
            val left = (m.widthPixels - bw) / 2 + n * step
            val top = (m.heightPixels - bh) / 2 + n * step
            options.setLaunchBounds(Rect(left, top, left + bw, top + bh))
        } catch (e: Exception) {
            // Fall back to default (full-screen) launch bounds.
        }
        // Defer the launch to the NEXT main-loop frame. A startActivity fired
        // synchronously inside the button-tap dispatch was being dropped in a
        // floating (freeform) window — the reason a plain tap did nothing while
        // an awkward multi-touch release (which shifted the timing) worked.
        window.decorView.post {
            try {
                startActivity(intent, options.toBundle())
            } catch (e: Exception) {
                Log.e("OmniNote", "openNewWindow failed", e)
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
        private const val MULTIWINDOW_CHANNEL = "omninote/multiwindow"

        // Cascades successive new-window positions so they don't overlap.
        private var windowCascade = 0
    }
}
