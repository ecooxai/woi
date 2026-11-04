package dev.woi.woi

import android.content.Context
import android.content.Intent
import android.util.Log
import android.view.ViewGroup
import android.view.WindowManager
import android.widget.FrameLayout
import io.flutter.embedding.android.FlutterTextureView
import io.flutter.embedding.android.FlutterView
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel

/**
 * The one Flutter engine of the process, shared by MainActivity and the
 * assistant overlay so both show the same voice session, notes and history.
 * Created by whichever comes first (the launcher or the assist gesture).
 */
object WoiEngine {
    const val ID = "woi_main"

    fun obtain(ctx: Context): FlutterEngine {
        FlutterEngineCache.getInstance().get(ID)?.let { return it }
        val app = ctx.applicationContext
        val engine = FlutterEngine(app)
        // Channels before Dart runs: main() calls "init" right away.
        WoiBridge.attachEngine(app, engine)
        engine.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint.createDefault())
        FlutterEngineCache.getInstance().put(ID, engine)
        Log.i(WoiBridge.TAG, "flutter engine created")
        return engine
    }

    fun peek(): FlutterEngine? = FlutterEngineCache.getInstance().get(ID)
}

/**
 * The assistant as a floating panel: a transparent FlutterView inside the
 * VoiceInteractionSession's own window (TYPE_VOICE_INTERACTION, above the
 * current app) attached to the shared engine. Flutter draws a light scrim and
 * the bottom panel (lib/ui/assist); the app below stays visible above it.
 *
 * An engine renders into one view at a time, so MainActivity's FlutterView is
 * detached while the panel shows and re-attached when the activity starts.
 *
 * Accessibility actions step the panel aside (not touchable / not focusable,
 * invisible for screenshots) so taps, text and keys reach the app below.
 */
object WoiOverlay {
    private const val PREFS = "woi_overlay"
    private const val KEY_FRACTION = "fraction"
    const val DEFAULT_FRACTION = 0.6
    const val MIN_FRACTION = 0.35
    const val MAX_FRACTION = 0.95

    private var session: WoiSession? = null
    private var view: FlutterView? = null
    private var asideCount = 0
    private var asideVisual = false
    private var shownAt = 0L

    private val reveal = Runnable { view?.alpha = 1f }
    private val restore = Runnable { applyAside(false, false) }

    val showing: Boolean get() = view != null

    fun fraction(ctx: Context): Double =
        ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getFloat(KEY_FRACTION, DEFAULT_FRACTION.toFloat()).toDouble()
            .coerceIn(MIN_FRACTION, MAX_FRACTION)

    fun saveFraction(ctx: Context, f: Double) {
        ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
            .putFloat(KEY_FRACTION, f.coerceIn(MIN_FRACTION, MAX_FRACTION).toFloat()).apply()
    }

    /** Puts the panel into [container] (the session's content view). */
    fun show(s: WoiSession, container: FrameLayout) {
        if (view != null) {
            if (session === s) return
            hide()
        }
        val ctx = s.context
        // Android 14+ only lets a non-foreground app record with a
        // microphone-type foreground service, and that service may only be
        // started while the app is visible: now (the session window is up).
        // Dart keeps it in sync with the mic mode afterwards (voiceActive).
        if (WoiBridge.hasPermission(ctx, android.Manifest.permission.RECORD_AUDIO)) {
            WoiForegroundService.startVoice(ctx)
        }
        val engine = WoiEngine.obtain(ctx)
        WoiBridge.activity?.releaseFlutterView()
        val texture = FlutterTextureView(ctx).apply { isOpaque = false }
        val v = FlutterView(ctx, texture)
        // Invisible until Dart has pushed the panel route (overlayReady), so
        // the first frame never flashes the full app.
        v.alpha = 0f
        container.addView(v, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
        v.attachToFlutterEngine(engine)
        session = s
        view = v
        asideCount = 0
        asideVisual = false
        shownAt = System.currentTimeMillis()
        engine.lifecycleChannel.appIsResumed()
        engine.lifecycleChannel.aWindowIsFocused()
        WoiBridge.emit(mapOf("type" to "overlay", "on" to true, "fraction" to fraction(ctx)))
        WoiBridge.main.postDelayed(reveal, 1500)
        Log.i(WoiBridge.TAG, "overlay shown")
    }

    /** Dart drew the panel. */
    fun ready() {
        WoiBridge.main.removeCallbacks(reveal)
        view?.alpha = 1f
        Log.i(WoiBridge.TAG, "overlay ready in ${System.currentTimeMillis() - shownAt} ms")
    }

    /** Takes the panel down (session hidden, dismissed, or the full app opens). */
    fun hide() {
        val v = view ?: return
        WoiBridge.main.removeCallbacks(reveal)
        WoiBridge.main.removeCallbacks(restore)
        if (asideCount > 0 || asideVisual) applyAside(false, false)
        asideCount = 0
        view = null
        session = null
        v.detachFromFlutterEngine()
        (v.parent as? ViewGroup)?.removeView(v)
        WoiBridge.emit(mapOf("type" to "overlay", "on" to false))
        val engine = WoiEngine.peek()
        val act = WoiBridge.activity
        if (act != null && act.started) {
            act.reattachFlutterView()
        } else if (engine != null) {
            engine.lifecycleChannel.noWindowsAreFocused()
            engine.lifecycleChannel.appIsPaused()
        }
        Log.i(WoiBridge.TAG, "overlay hidden")
    }

    /** Back / tap outside / swipe down in the panel. */
    fun dismiss() {
        val s = session
        hide()
        s?.hide()
    }

    /** "Open full app": the panel goes, MainActivity comes to the front (in
     *  the bottom freeform window when it isn't running yet, WoiLaunch). */
    fun openApp(ctx: Context) {
        val s = session
        hide()
        val i = Intent(ctx, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        try {
            val c = s?.context ?: ctx
            WoiLaunch.start(c, i)
        } catch (e: Exception) {
            Log.w(WoiBridge.TAG, "open app from overlay failed; startAssistantActivity", e)
            try { s?.startAssistantActivity(i) } catch (e2: Exception) { Log.w(WoiBridge.TAG, "startAssistantActivity failed", e2) }
        }
        s?.hide()
    }

    /**
     * Lets an accessibility action reach the app below: the panel window stops
     * taking touches and focus ([visual]: also invisible, for screenshots).
     * Pair every call with the Result returned by [releasing].
     */
    fun stepAside(visual: Boolean) {
        WoiBridge.main.removeCallbacks(restore)
        asideCount++
        if (visual) asideVisual = true
        applyAside(true, asideVisual)
    }

    /** Wraps [r] so the panel comes back ~0.6 s after the last action ends. */
    fun releasing(r: MethodChannel.Result): MethodChannel.Result = object : MethodChannel.Result {
        private var done = false
        private fun release() {
            if (done) return
            done = true
            asideCount = (asideCount - 1).coerceAtLeast(0)
            if (asideCount == 0) {
                WoiBridge.main.removeCallbacks(restore)
                WoiBridge.main.postDelayed(restore, 600)
            }
        }

        override fun success(result: Any?) { release(); r.success(result) }
        override fun error(code: String, msg: String?, details: Any?) { release(); r.error(code, msg, details) }
        override fun notImplemented() { release(); r.notImplemented() }
    }

    private fun applyAside(aside: Boolean, visual: Boolean) {
        if (!aside) asideVisual = false
        val w = session?.window?.window ?: return
        val lp = w.attributes
        val flags = WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE or WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE
        lp.flags = if (aside) lp.flags or flags else lp.flags and flags.inv()
        lp.alpha = if (aside && visual) 0f else 1f
        w.attributes = lp
        Log.i(WoiBridge.TAG, "overlay aside=$aside visual=$visual")
    }
}
