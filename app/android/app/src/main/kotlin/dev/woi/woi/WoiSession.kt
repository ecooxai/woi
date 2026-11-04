package dev.woi.woi

import android.app.assist.AssistStructure
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.drawable.ColorDrawable
import android.os.Bundle
import android.os.SystemClock
import android.service.voice.VoiceInteractionService
import android.service.voice.VoiceInteractionSession
import android.service.voice.VoiceInteractionSessionService
import android.speech.RecognitionService
import android.speech.SpeechRecognizer
import android.util.Log
import android.view.View
import android.view.WindowManager
import android.widget.FrameLayout
import java.io.File
import java.io.FileOutputStream

/** Lets the user pick Woi as the "Digital assistant app". */
class WoiVoiceInteractionService : VoiceInteractionService() {
    override fun onReady() {
        super.onReady()
        instance = this
        Log.i(WoiBridge.TAG, "voice interaction service ready")
    }

    override fun onShutdown() {
        if (instance === this) instance = null
        super.onShutdown()
    }

    companion object {
        /** Set while Woi is the active digital assistant. */
        @Volatile var instance: WoiVoiceInteractionService? = null
    }
}

/**
 * ACTION_ASSIST / VOICE_ASSIST sent straight to Woi (`am start -a
 * android.intent.action.ASSIST`, headset buttons, launchers): when Woi is the
 * active assistant, open the real session so the system takes the assist
 * screenshot of the app below; otherwise open Woi without one. Draws nothing.
 */
class WoiAssistActivity : android.app.Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val svc = WoiVoiceInteractionService.instance
        if (svc != null) {
            Log.i(WoiBridge.TAG, "assist intent -> showSession")
            svc.showSession(Bundle(), VoiceInteractionSession.SHOW_WITH_ASSIST or VoiceInteractionSession.SHOW_WITH_SCREENSHOT)
        } else {
            startActivity(
                Intent(this, MainActivity::class.java)
                    .putExtra(WoiSession.EXTRA_ASSIST, true)
                    .putExtra(WoiSession.EXTRA_T0, System.currentTimeMillis())
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            )
        }
        finish()
    }
}

class WoiSessionService : VoiceInteractionSessionService() {
    override fun onNewSession(args: Bundle?): VoiceInteractionSession = WoiSession(this)
}

/**
 * Long-press home / assist gesture / ASSIST intent. Normally Woi floats as a
 * bottom panel over the current app (WoiOverlay, drawn in this session's own
 * window). When Woi itself is in front, the session opens no panel and hands
 * the screenshot to MainActivity as before.
 *
 * Either way it waits for the assist screenshot (and the screen's text from
 * the AssistStructure), saves it and gives it to Dart, which attaches it to
 * the next turn.
 */
class WoiSession(ctx: Context) : VoiceInteractionSession(ctx) {
    private var delivered = false
    private var overlay = false
    private var shownAt = 0L
    private var screenText: String? = null
    private var appName: String? = null
    private var container: FrameLayout? = null
    private val fallback = Runnable { deliver(null) }

    override fun onCreateContentView(): View {
        val c = FrameLayout(context)
        c.setBackgroundColor(Color.TRANSPARENT)
        container = c
        return c
    }

    override fun onShow(args: Bundle?, showFlags: Int) {
        super.onShow(args, showFlags)
        delivered = false
        screenText = null
        appName = null
        shownAt = System.currentTimeMillis()
        overlay = WoiBridge.activity?.resumed != true
        Log.i(WoiBridge.TAG, "assist session shown flags=$showFlags overlay=$overlay")
        if (overlay) {
            window?.window?.let { w ->
                w.setBackgroundDrawable(ColorDrawable(Color.TRANSPARENT))
                w.setSoftInputMode(WindowManager.LayoutParams.SOFT_INPUT_ADJUST_RESIZE)
            }
            val c = container
            if (c != null) WoiOverlay.show(this, c) else overlay = false
        }
        // The screenshot normally arrives within ~300 ms; without it (assist
        // screenshots disabled) go on anyway.
        val wantsShot = showFlags and SHOW_WITH_SCREENSHOT != 0
        WoiBridge.main.postDelayed(fallback, if (wantsShot) 2000L else 600L)
    }

    override fun onHide() {
        WoiBridge.main.removeCallbacks(fallback)
        if (overlay) WoiOverlay.hide()
        super.onHide()
    }

    override fun onDestroy() {
        WoiBridge.main.removeCallbacks(fallback)
        if (overlay) WoiOverlay.hide()
        super.onDestroy()
    }

    override fun onBackPressed() {
        if (overlay) WoiOverlay.dismiss() else super.onBackPressed()
    }

    override fun onHandleAssist(state: AssistState) {
        val structure = state.assistStructure ?: return
        appName = structure.activityComponent?.packageName
        val sb = StringBuilder()
        for (i in 0 until structure.windowNodeCount) collect(structure.getWindowNodeAt(i).rootViewNode, sb)
        screenText = sb.toString().take(4000).ifBlank { null }
    }

    private fun collect(n: AssistStructure.ViewNode?, sb: StringBuilder) {
        if (n == null || sb.length > 4000) return
        val t = n.text?.toString()?.trim()
        if (!t.isNullOrEmpty()) sb.append(t).append('\n')
        else n.contentDescription?.toString()?.trim()?.takeIf { it.isNotEmpty() }?.let { sb.append(it).append('\n') }
        for (i in 0 until n.childCount) collect(n.getChildAt(i), sb)
    }

    override fun onHandleScreenshot(screenshot: Bitmap?) {
        if (screenshot == null) return deliver(null)
        val t0 = SystemClock.elapsedRealtime()
        val w = screenshot.width
        val h = screenshot.height
        WoiBridge.io.execute {
            var path: String? = null
            var sw = w
            var sh = h
            try {
                // Hardware bitmaps can't be scaled/compressed reliably on
                // every GPU (black thumbnails): copy to software first.
                val src = if (screenshot.config == Bitmap.Config.HARDWARE) screenshot.copy(Bitmap.Config.ARGB_8888, false) else screenshot
                val maxW = 720
                val scaled = if (w > maxW) Bitmap.createScaledBitmap(src, maxW, (h.toLong() * maxW / w).toInt(), true) else src
                sw = scaled.width
                sh = scaled.height
                val dir = File(context.cacheDir, "assist").apply { mkdirs() }
                dir.listFiles()?.forEach { it.delete() }
                val f = File(dir, "assist-${System.currentTimeMillis()}.png")
                FileOutputStream(f).use { scaled.compress(Bitmap.CompressFormat.PNG, 100, it) }
                if (scaled !== src) scaled.recycle()
                if (src !== screenshot) src.recycle()
                path = f.absolutePath
                Log.i(WoiBridge.TAG, "assist screenshot ${w}x$h -> ${sw}x$sh in ${SystemClock.elapsedRealtime() - t0} ms")
            } catch (e: Exception) {
                Log.w(WoiBridge.TAG, "assist screenshot failed", e)
            }
            val p = path
            WoiBridge.main.post { deliver(p, sw, sh, w, h) }
        }
    }

    private fun deliver(png: String?, w: Int = 0, h: Int = 0, ow: Int = 0, oh: Int = 0) {
        if (delivered) return
        delivered = true
        WoiBridge.main.removeCallbacks(fallback)
        if (overlay) {
            // The panel is up: Dart attaches the screenshot to the session.
            WoiBridge.emit(
                mapOf(
                    "type" to "assist",
                    "png" to png,
                    "width" to w,
                    "height" to h,
                    "originalWidth" to ow,
                    "originalHeight" to oh,
                    "app" to appName,
                    "screenText" to screenText,
                    "shownAt" to shownAt,
                    "overlay" to true,
                )
            )
            return
        }
        val i = Intent(context, MainActivity::class.java).apply {
            putExtra(EXTRA_ASSIST, true)
            putExtra(EXTRA_PNG, png)
            putExtra(EXTRA_W, w)
            putExtra(EXTRA_H, h)
            putExtra(EXTRA_OW, ow)
            putExtra(EXTRA_OH, oh)
            putExtra(EXTRA_APP, appName)
            putExtra(EXTRA_TEXT, screenText)
            putExtra(EXTRA_T0, shownAt)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        }
        // Woi is in front already: a plain start reaches the existing
        // singleTask MainActivity (the shared engine).
        try {
            context.startActivity(i)
        } catch (e: Exception) {
            Log.w(WoiBridge.TAG, "startActivity from session failed; using startAssistantActivity", e)
            try { startAssistantActivity(i) } catch (e2: Exception) { Log.w(WoiBridge.TAG, "startAssistantActivity failed", e2) }
        }
        hide()
    }

    companion object {
        const val EXTRA_ASSIST = "woi_assist"
        const val EXTRA_PNG = "woi_assist_png"
        const val EXTRA_W = "woi_assist_w"
        const val EXTRA_H = "woi_assist_h"
        const val EXTRA_OW = "woi_assist_ow"
        const val EXTRA_OH = "woi_assist_oh"
        const val EXTRA_APP = "woi_assist_app"
        const val EXTRA_TEXT = "woi_assist_text"
        const val EXTRA_T0 = "woi_assist_t0"
    }
}

/** Required by the voice-interaction metadata; Woi's speech runs in the app. */
class WoiRecognitionService : RecognitionService() {
    override fun onStartListening(recognizerIntent: Intent?, listener: Callback?) {
        listener?.error(SpeechRecognizer.ERROR_CLIENT)
    }

    override fun onCancel(listener: Callback?) {}
    override fun onStopListening(listener: Callback?) {}
}
