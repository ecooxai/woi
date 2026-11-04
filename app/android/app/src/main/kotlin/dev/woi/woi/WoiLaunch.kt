package dev.woi.woi

import android.app.Activity
import android.app.ActivityOptions
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Point
import android.graphics.Rect
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.util.Log
import android.view.WindowManager

/**
 * Starts the full app (MainActivity) in a freeform window docked at the
 * bottom of the screen: full width, [HEIGHT] of the screen height. The user
 * can still maximize it from the window caption.
 *
 * A fullscreen display ignores launch bounds unless the launch also asks for
 * the freeform windowing mode, which has no public setter: the mode goes
 * into the options bundle under the key ActivityOptions(Bundle) reads.
 * Without freeform support (the `enable_freeform_support` developer option
 * or the freeform feature) Woi starts full screen as before.
 */
object WoiLaunch {
    const val HEIGHT = 0.7

    private const val WINDOWING_MODE_FREEFORM = 5
    private const val KEY_WINDOWING_MODE = "android.activity.windowingMode"
    private const val SETTING_FREEFORM = "enable_freeform_support"

    /** Freeform windows can be created on this device right now. */
    fun freeformSupported(ctx: Context): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.N) return false
        if (ctx.packageManager.hasSystemFeature(PackageManager.FEATURE_FREEFORM_WINDOW_MANAGEMENT)) return true
        return try {
            Settings.Global.getInt(ctx.contentResolver, SETTING_FREEFORM, 0) != 0
        } catch (e: Exception) {
            Log.w(WoiBridge.TAG, "can't read $SETTING_FREEFORM", e)
            false
        }
    }

    /** Full width, the bottom [HEIGHT] of the display. */
    fun bounds(ctx: Context): Rect {
        val wm = ctx.getSystemService(WindowManager::class.java)
        val full = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            wm.maximumWindowMetrics.bounds
        } else {
            val p = Point()
            @Suppress("DEPRECATION")
            wm.defaultDisplay.getRealSize(p)
            Rect(0, 0, p.x, p.y)
        }
        val top = full.bottom - (full.height() * HEIGHT).toInt()
        return Rect(full.left, top, full.right, full.bottom)
    }

    /** Options for a freeform start, or null where freeform isn't available. */
    fun options(ctx: Context): Bundle? {
        if (!freeformSupported(ctx)) return null
        return try {
            val b = ActivityOptions.makeBasic().setLaunchBounds(bounds(ctx)).toBundle()
            b.putInt(KEY_WINDOWING_MODE, WINDOWING_MODE_FREEFORM)
            b
        } catch (e: Exception) {
            Log.w(WoiBridge.TAG, "freeform options failed", e)
            null
        }
    }

    /** MainActivity is alive (maybe in the background): just bring it to the
     *  front in whatever window it has (the user may have maximized it). */
    private fun appAlive(): Boolean {
        val a = WoiBridge.activity ?: return false
        return !a.isFinishing && !a.isDestroyed
    }

    /**
     * Starts [intent] (for MainActivity, FLAG_ACTIVITY_NEW_TASK set) in the
     * freeform window when possible, else normally. [starter] does the start
     * so callers can route it (e.g. through a voice session). Throws what a
     * plain start throws.
     */
    fun start(ctx: Context, intent: Intent, starter: (Intent, Bundle?) -> Unit = { i, o -> ctx.startActivity(i, o) }) {
        val opts = if (appAlive()) null else options(ctx)
        if (opts != null) {
            try {
                starter(intent, opts)
                Log.i(WoiBridge.TAG, "full app started in a freeform window ${bounds(ctx).toShortString()}")
                return
            } catch (e: Exception) {
                Log.w(WoiBridge.TAG, "freeform start failed; starting full screen", e)
            }
        }
        starter(intent, null)
    }
}

/**
 * The launcher entry: relaunches MainActivity in the bottom freeform window
 * (WoiLaunch) and goes away. Draws nothing.
 */
class WoiLaunchActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val i = Intent(this, MainActivity::class.java)
            .setAction(Intent.ACTION_MAIN)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        try {
            WoiLaunch.start(this, i)
        } catch (e: Exception) {
            Log.e(WoiBridge.TAG, "launch failed", e)
        }
        finish()
        // No exit animation of our own: the MainActivity window animates in.
        @Suppress("DEPRECATION")
        overridePendingTransition(0, 0)
    }
}
