package dev.woi.woi

import android.app.Activity
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.view.Gravity
import android.view.WindowManager
import android.widget.TextView
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.lang.ref.WeakReference
import java.util.UUID

/** Explicit clipboard operations only. No listener, history, logging, or
 * background polling. Android 10+ reads use a visibly focused Activity when
 * Woi is behind another app; the OS clipboard privacy boundary stays intact. */
internal object WoiClipboard {
    private data class Pending(val id: String, val result: MethodChannel.Result)
    private var pending: Pending? = null
    private var reader: WeakReference<WoiClipboardActivity>? = null
    private var closing = false
    private var closingCancelled = false
    private const val maxTextLength = 100000

    fun handle(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "writeClipboard" -> {
                    val text = call.argument<String>("text") ?: return result.error("invalid_clipboard", "text is required", null)
                    require(text.length <= maxTextLength) { "Clipboard text is limited to $maxTextLength UTF-16 units" }
                    manager(WoiBridge.appContext).setPrimaryClip(ClipData.newPlainText("Woi", text))
                    result.success(true)
                }
                "readClipboard" -> {
                    if (pending != null || closing) return result.error("clipboard_busy", "A clipboard read is already in progress", null)
                    val activity = WoiBridge.activity
                    if (Build.VERSION.SDK_INT < 29 || activity?.hasWindowFocus() == true) {
                        result.success(read(activity ?: WoiBridge.appContext))
                        return
                    }
                    val panelShowing = WoiOverlay.showing
                    val reply = if (panelShowing) WoiOverlay.releasing(result) else result
                    if (panelShowing) try { WoiOverlay.stepAside(false) }
                    catch (error: Throwable) {
                        reply.error("clipboard_unavailable", error.message ?: "Could not release assistant focus", null)
                        return
                    }
                    val request = Pending(UUID.randomUUID().toString(), reply)
                    pending = request
                    val context = WoiAccessibilityService.instance ?: WoiBridge.appContext
                    try {
                        context.startActivity(Intent(context, WoiClipboardActivity::class.java).apply {
                            putExtra("request", request.id)
                            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_NO_HISTORY or Intent.FLAG_ACTIVITY_EXCLUDE_FROM_RECENTS)
                        })
                    } catch (error: Throwable) {
                        finish(request.id, error = error.message ?: "Android refused clipboard focus")
                        return
                    }
                    WoiBridge.main.postDelayed({
                        if (pending?.id == request.id) finish(request.id, error = "Android did not give Woi clipboard focus. Open Woi and retry the clipboard read")
                    }, 2500)
                }
                else -> result.notImplemented()
            }
        } catch (error: Throwable) {
            result.error("clipboard_unavailable", error.message ?: "Clipboard operation failed", null)
        }
    }

    /** Stop/new-turn cancellation is idempotent and uses the same focus
     * cleanup as completion. A delayed Activity cannot attach to a cancelled
     * request, and a result already waiting for focus release is suppressed. */
    fun cancelPending(): Boolean {
        val request = pending
        if (request != null) {
            finish(request.id, error = "Clipboard read cancelled", errorCode = "clipboard_cancelled")
            return true
        }
        if (closing) {
            closingCancelled = true
            return true
        }
        return false
    }

    private fun manager(context: Context) = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager

    private fun read(context: Context): Map<String, Any?> {
        val clip = manager(context).primaryClip
        // Do not coerce URI/intent clips: a clipboard read should not open
        // providers, fetch remote data, or execute content from another app.
        val text = if (clip != null && clip.itemCount > 0) clip.getItemAt(0).text?.toString() else null
        require(text == null || text.length <= maxTextLength) { "Clipboard text exceeds the $maxTextLength UTF-16 unit limit" }
        return mapOf("available" to (text != null), "text" to text)
    }

    fun attach(activity: WoiClipboardActivity, id: String?): Boolean {
        if (id == null || pending?.id != id) return false
        reader = WeakReference(activity)
        return true
    }

    fun readFocused(activity: WoiClipboardActivity, id: String) {
        if (pending?.id != id || !activity.hasWindowFocus()) return
        try { finish(id, value = read(activity)) }
        catch (error: Throwable) { finish(id, error = error.message ?: "Android refused clipboard access") }
    }

    fun abandoned(id: String) {
        if (pending?.id == id) finish(id, error = "Clipboard read was cancelled before the window gained focus")
    }

    private fun finish(id: String, value: Any? = null, error: String? = null, errorCode: String = "clipboard_unavailable") {
        val request = pending?.takeIf { it.id == id } ?: return
        pending = null
        closing = true
        closingCancelled = false
        val activity = reader?.get()
        reader = null
        // Wait for this window to release focus, not merely for finish() to
        // return. The assistant's focus lease is released by the reply wrapper
        // after this handoff, and following input can take over that lease.
        activity?.finish()
        val deadline = android.os.SystemClock.uptimeMillis() + 700
        fun completeAfterRelease() {
            if (activity != null && !activity.isDestroyed && activity.hasWindowFocus() &&
                android.os.SystemClock.uptimeMillis() < deadline) {
                WoiBridge.main.postDelayed(::completeAfterRelease, 32)
                return
            }
            val cancelled = closingCancelled
            closing = false
            closingCancelled = false
            if (cancelled) request.result.error("clipboard_cancelled", "Clipboard read cancelled", null)
            else if (error == null) request.result.success(value)
            else request.result.error(errorCode, error, null)
        }
        WoiBridge.main.postDelayed(::completeAfterRelease, if (activity == null) 0 else 32)
    }
}

/** A small visible, non-exported read window. It never focuses a text editor,
 * changes the selected keyboard, or exposes clipboard content on screen. */
class WoiClipboardActivity : Activity() {
    private var requestId: String? = null
    private var reading = false

    override fun onCreate(state: Bundle?) {
        super.onCreate(state)
        requestId = intent.getStringExtra("request")
        if (!WoiClipboard.attach(this, requestId)) { finish(); return }
        window.setSoftInputMode(WindowManager.LayoutParams.SOFT_INPUT_STATE_ALWAYS_HIDDEN)
        setFinishOnTouchOutside(false)
        setContentView(TextView(this).apply {
            text = "Woi is reading the clipboard…"
            textSize = 16f
            gravity = Gravity.CENTER
            val pad = (24 * resources.displayMetrics.density).toInt()
            setPadding(pad, pad, pad, pad)
            contentDescription = "Woi clipboard access"
        })
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        val id = requestId ?: return
        if (hasFocus && !reading) {
            reading = true
            // Wait for the visible window to be drawn and focus registration
            // to reach the clipboard service, rather than reading in onCreate.
            window.decorView.postDelayed({
                reading = false
                WoiClipboard.readFocused(this, id)
            }, 100)
        }
    }

    override fun onDestroy() {
        requestId?.let { WoiClipboard.abandoned(it) }
        super.onDestroy()
    }
}
