package dev.woi.woi

import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Path
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
    private var button = ""
    private var heldPanel = false

    fun begin(kind: String, keys: String, targetX: Float?, targetY: Float?): Boolean {
        if (cancelled) return false
        end()
        active = true
        button = ""  // Each warning begins with the neutral light-blue cursor.
        // Gestures and screenshots include system bars; app displayMetrics can
        // exclude those areas and would clamp a valid bottom-screen target.
        val metrics = android.util.DisplayMetrics()
        @Suppress("DEPRECATION")
        wm.defaultDisplay.getRealMetrics(metrics)
        if (x == 0f && y == 0f) { x = metrics.widthPixels / 2f; y = metrics.heightPixels / 2f }
        // Phones have no system mouse cursor: the marker is the touch target.
        if (targetX != null) x = targetX.coerceIn(0f, (metrics.widthPixels - 1).coerceAtLeast(0).toFloat())
        if (targetY != null) y = targetY.coerceIn(0f, (metrics.heightPixels - 1).coerceAtLeast(0).toFloat())
        if (WoiOverlay.showing) {
            WoiOverlay.stepAside(false)
            heldPanel = true
        }
        val v = Indicator(service, kind, keys.take(180)).also {
            it.alpha = 0.5f
            visual = it
        }
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

    fun update(keys: String?, px: Float?, py: Float?, pointerButton: String? = null) {
        if (keys != null) visual?.keys = keys.take(180)
        if (px != null) x = px
        if (py != null) y = py
        if (pointerButton != null) button = pointerButton
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
        button = ""
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
        private val screenOrigin = IntArray(2)
        private val cursor = Path().apply {
            moveTo(0f, 0f); lineTo(0f, 30f); lineTo(8f, 23f)
            lineTo(15f, 38f); lineTo(22f, 35f); lineTo(14f, 20f); lineTo(27f, 20f)
            close()
        }
        override fun onDraw(canvas: Canvas) {
            super.onDraw(canvas)
            canvas.save()
            // Gesture coordinates are physical screen pixels. Accessibility overlay
            // windows can start below status bars/cutouts even with LAYOUT_IN_SCREEN.
            // Use the actual view origin on every frame, including after rotation,
            // instead of assuming the overlay canvas starts at screen (0, 0).
            getLocationOnScreen(screenOrigin)
            canvas.translate(this@WoiControlOverlay.x - screenOrigin[0],
                this@WoiControlOverlay.y - screenOrigin[1])
            canvas.scale(density, density)
            paint.style = Paint.Style.STROKE
            paint.strokeJoin = Paint.Join.ROUND
            paint.strokeWidth = 4f
            paint.color = Color.argb(245, 255, 255, 255)
            canvas.drawPath(cursor, paint)
            paint.style = Paint.Style.FILL
            paint.color = when (button) {
                "left" -> Color.rgb(52, 155, 231)
                "right" -> Color.rgb(255, 166, 166)
                else -> Color.rgb(92, 190, 255)
            }
            canvas.drawPath(cursor, paint)
            paint.style = Paint.Style.STROKE
            paint.strokeWidth = 1.25f
            paint.color = if (button == "right") Color.rgb(204, 93, 102) else Color.rgb(31, 109, 170)
            canvas.drawPath(cursor, paint)
            canvas.restore()
            paint.style = Paint.Style.FILL
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
