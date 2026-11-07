package dev.woi.woi

import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.PixelFormat
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.WindowManager

/** Native, non-focusable indicators remain above the controlled app. The
 * visual window is input-transparent. A 1 px outside-touch watcher cancels on
 * a user's touch without taking touches away from the app below. No global
 * motion-source interception (which would consume Android input) is used. */
class WoiControlOverlay(private val service: WoiAccessibilityService) {
    private val wm = service.getSystemService(Context.WINDOW_SERVICE) as WindowManager
    private val main = WoiBridge.main
    private var visual: Indicator? = null
    private var watcher: View? = null
    private var active = false
    private var injecting = false
    private var injectionSerial = 0
    var cancelled = false
        private set
    private var x = 0f
    private var y = 0f
    private var heldPanel = false

    fun begin(kind: String, keys: String, targetX: Float?, targetY: Float?): Boolean {
        if (cancelled) return false
        end()
        active = true
        val metrics = service.resources.displayMetrics
        if (x == 0f && y == 0f) { x = metrics.widthPixels / 2f; y = metrics.heightPixels / 2f }
        // Phones have no system mouse cursor: the marker is the touch target.
        if (targetX != null) x = targetX.coerceIn(0f, metrics.widthPixels.toFloat())
        if (targetY != null) y = targetY.coerceIn(0f, metrics.heightPixels.toFloat())
        if (WoiOverlay.showing) {
            WoiOverlay.stepAside(false)
            heldPanel = true
        }
        val v = Indicator(service, kind, keys.take(180)).also { visual = it }
        val lp = WindowManager.LayoutParams(
            WindowManager.LayoutParams.MATCH_PARENT, WindowManager.LayoutParams.MATCH_PARENT,
            WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE or
                WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN,
            PixelFormat.TRANSLUCENT
        ).apply { gravity = Gravity.TOP or Gravity.START; title = "Woi control indicator" }
        wm.addView(v, lp)
        // Keep this tiny window at the far corner. WATCH_OUTSIDE_TOUCH delivers
        // the initial outside down while the user's app still receives it.
        val watch = object : View(service) {
            override fun onTouchEvent(event: MotionEvent): Boolean {
                if (active && !injecting && (event.actionMasked == MotionEvent.ACTION_OUTSIDE ||
                            event.actionMasked == MotionEvent.ACTION_DOWN || event.actionMasked == MotionEvent.ACTION_MOVE)) {
                    cancel()
                }
                return false
            }
        }.also { watcher = it }
        val wp = WindowManager.LayoutParams(1, 1, WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL or
                WindowManager.LayoutParams.FLAG_WATCH_OUTSIDE_TOUCH or WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN,
            PixelFormat.TRANSLUCENT).apply { gravity = Gravity.TOP or Gravity.START; title = "Woi input watcher" }
        wm.addView(watch, wp)
        return true
    }

    fun update(keys: String?, px: Float?, py: Float?) {
        if (keys != null) visual?.keys = keys.take(180)
        if (px != null) x = px
        if (py != null) y = py
        visual?.invalidate()
    }

    /** Android cancels dispatchGesture itself if the user touches during a
     * synthetic gesture. Ignore only that gesture's own outside-touch event. */
    fun injecting() {
        injecting = true
        val serial = ++injectionSerial
        main.postDelayed({ if (serial == injectionSerial) injecting = false }, 90)
    }
    fun gestureFinished() { injecting = false; injectionSerial++ }
    fun check() { if (cancelled) throw IllegalStateException("User took control; stop input until a new user request") }
    fun cancel() { if (active) { cancelled = true; visual?.invalidate() } }
    fun reset() { end(); cancelled = false }
    fun end() {
        active = false
        injecting = false
        injectionSerial++
        watcher?.let { try { wm.removeView(it) } catch (_: Throwable) {} }
        visual?.let { try { wm.removeView(it) } catch (_: Throwable) {} }
        watcher = null
        visual = null
        if (heldPanel) {
            heldPanel = false
            WoiOverlay.releasing(object : io.flutter.plugin.common.MethodChannel.Result {
                override fun success(result: Any?) {}
                override fun error(code: String, message: String?, details: Any?) {}
                override fun notImplemented() {}
            }).success(null)
        }
    }

    private inner class Indicator(ctx: Context, val kind: String, var keys: String) : View(ctx) {
        private val paint = Paint(Paint.ANTI_ALIAS_FLAG)
        private val density = resources.displayMetrics.density
        override fun onDraw(canvas: Canvas) {
            super.onDraw(canvas)
            paint.style = Paint.Style.FILL
            paint.color = Color.argb(70, 92, 190, 255)
            // View.x/y are the view's own offsets, not the requested screen point.
            canvas.drawCircle(this@WoiControlOverlay.x, this@WoiControlOverlay.y, 20 * density, paint)
            paint.style = Paint.Style.STROKE
            paint.strokeWidth = 2 * density
            paint.color = Color.rgb(92, 190, 255)
            canvas.drawCircle(this@WoiControlOverlay.x, this@WoiControlOverlay.y, 20 * density, paint)
            paint.style = Paint.Style.FILL
            canvas.drawCircle(this@WoiControlOverlay.x, this@WoiControlOverlay.y, 4 * density, paint)
            if (kind != "keyboard") return
            val cx = width / 2f
            val cy = height / 2f
            paint.color = Color.rgb(191, 228, 255)
            canvas.drawRoundRect(cx - 44 * density, cy - 30 * density, cx + 44 * density, cy + 30 * density, 5 * density, 5 * density, paint)
            paint.color = Color.rgb(63, 135, 187)
            for (row in 0..2) for (col in 0..5) {
                val kx = cx - 32 * density + col * 11 * density
                val ky = cy - 19 * density + row * 11 * density
                canvas.drawRect(kx, ky, kx + 6 * density, ky + 6 * density, paint)
            }
            canvas.drawRect(cx - 21 * density, cy + 17 * density, cx + 21 * density, cy + 22 * density, paint)
            val boxWidth = minOf(width - 24 * density, 420 * density)
            val left = width - boxWidth - 12 * density
            paint.color = Color.argb(245, 204, 235, 255)
            canvas.drawRoundRect(left, 28 * density, width - 12 * density, 68 * density, 6 * density, 6 * density, paint)
            paint.color = Color.rgb(31, 79, 117)
            paint.textSize = 13 * density
            val label = if (cancelled) "Control stopped" else keys.replace('\n', ' ').replace('\r', ' ')
            val fit = paint.breakText(label, true, boxWidth - 24 * density, null)
            canvas.drawText(label.take(fit), left + 12 * density, 54 * density, paint)
        }
    }
}
