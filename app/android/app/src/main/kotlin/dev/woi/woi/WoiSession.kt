package dev.woi.woi

import android.app.assist.AssistStructure
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.os.Bundle
import android.os.SystemClock
import android.service.voice.VoiceInteractionService
import android.service.voice.VoiceInteractionSession
import android.service.voice.VoiceInteractionSessionService
import android.speech.RecognitionService
import android.speech.SpeechRecognizer
import android.util.Log
import java.io.File
import java.io.FileOutputStream

/** Lets the user pick Woi as the "Digital assistant app". */
class WoiVoiceInteractionService : VoiceInteractionService() {
    override fun onReady() {
        super.onReady()
        Log.i(WoiBridge.TAG, "voice interaction service ready")
    }
}

class WoiSessionService : VoiceInteractionSessionService() {
    override fun onNewSession(args: Bundle?): VoiceInteractionSession = WoiSession(this)
}

/**
 * Long-press home / assist gesture: waits for the assist screenshot (and the
 * screen's text from the AssistStructure), saves the screenshot and opens
 * Woi on top of the current app, which attaches it to the next turn.
 */
class WoiSession(ctx: Context) : VoiceInteractionSession(ctx) {
    private var launched = false
    private var shownAt = 0L
    private var screenText: String? = null
    private var appName: String? = null
    private val fallback = Runnable { launch(null) }

    override fun onShow(args: Bundle?, showFlags: Int) {
        super.onShow(args, showFlags)
        launched = false
        screenText = null
        appName = null
        shownAt = System.currentTimeMillis()
        Log.i(WoiBridge.TAG, "assist session shown flags=$showFlags")
        // The screenshot normally arrives within ~300 ms; without it (assist
        // screenshots disabled) open Woi anyway.
        val wantsShot = showFlags and SHOW_WITH_SCREENSHOT != 0
        WoiBridge.main.postDelayed(fallback, if (wantsShot) 2000L else 600L)
    }

    override fun onHide() {
        WoiBridge.main.removeCallbacks(fallback)
        super.onHide()
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
        if (screenshot == null) return launch(null)
        val t0 = SystemClock.elapsedRealtime()
        val w = screenshot.width
        val h = screenshot.height
        WoiBridge.io.execute {
            var path: String? = null
            var sw = w
            var sh = h
            try {
                val maxW = 720
                val scaled = if (w > maxW) Bitmap.createScaledBitmap(screenshot, maxW, (h.toLong() * maxW / w).toInt(), true) else screenshot
                sw = scaled.width
                sh = scaled.height
                val dir = File(context.cacheDir, "assist").apply { mkdirs() }
                dir.listFiles()?.forEach { it.delete() }
                val f = File(dir, "assist-${System.currentTimeMillis()}.png")
                FileOutputStream(f).use { scaled.compress(Bitmap.CompressFormat.PNG, 100, it) }
                if (scaled !== screenshot) scaled.recycle()
                path = f.absolutePath
                Log.i(WoiBridge.TAG, "assist screenshot ${w}x$h -> ${sw}x$sh in ${SystemClock.elapsedRealtime() - t0} ms")
            } catch (e: Exception) {
                Log.w(WoiBridge.TAG, "assist screenshot failed", e)
            }
            val p = path
            WoiBridge.main.post { launch(p, sw, sh, w, h) }
        }
    }

    private fun launch(png: String?, w: Int = 0, h: Int = 0, ow: Int = 0, oh: Int = 0) {
        if (launched) return
        launched = true
        WoiBridge.main.removeCallbacks(fallback)
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
        // A plain start reaches the existing singleTask MainActivity (one
        // Flutter engine). startAssistantActivity() would create a second
        // MainActivity in an "assistant" task, i.e. a second engine and app
        // state in the same process; only use it if the plain start fails.
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
