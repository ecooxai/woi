package dev.woi.woi

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.GestureDescription
import android.content.Context
import android.graphics.Path
import android.graphics.Rect
import android.os.SystemClock
import android.view.WindowManager
import android.view.accessibility.AccessibilityNodeInfo
import android.view.accessibility.AccessibilityWindowInfo
import io.flutter.plugin.common.MethodChannel
import kotlin.math.abs
import kotlin.math.min

/** A scroll direction describes where to read next, not the finger direction. */
internal data class WoiScrollRequest(
    val direction: String,
    val amount: Double = 1.0,
    val x: Float? = null,
    val y: Float? = null,
    val strategy: String = "auto",
) {
    init {
        require(direction in setOf("up", "down", "left", "right")) { "Scroll direction must be up, down, left or right" }
        require(amount.isFinite() && amount in 0.1..5.0) { "Scroll amount must be between 0.1 and 5 viewports" }
        require((x == null) == (y == null) && (x == null || (x.isFinite() && y!!.isFinite()))) {
            "Give both finite screen coordinates, or neither"
        }
        require(strategy in setOf("auto", "gesture")) { "Scroll strategy must be auto or gesture" }
    }
}

internal data class WoiScrollBounds(val left: Float, val top: Float, val right: Float, val bottom: Float) {
    val width get() = right - left
    val height get() = bottom - top
    fun contains(x: Float, y: Float) = x >= left && x < right && y >= top && y < bottom
    fun wire() = listOf(left.toInt(), top.toInt(), right.toInt(), bottom.toInt())
}

internal data class WoiScrollStroke(val fromX: Float, val fromY: Float, val toX: Float, val toY: Float, val durationMs: Long)

/** Pure geometry, shared with unit checks. Leave room for system gestures and
 * keep the entire path in the selected visible pane, including offset windows. */
internal object WoiScrollPlan {
    fun stroke(bounds: WoiScrollBounds, direction: String, amount: Double, x: Float? = null, y: Float? = null): WoiScrollStroke {
        WoiScrollRequest(direction, amount, x, y)
        require(amount <= 1.0) { "Plan one viewport at a time" }
        require(listOf(bounds.left, bounds.top, bounds.right, bounds.bottom).all { it.isFinite() } &&
            bounds.width >= 48 && bounds.height >= 48) { "No usable visible scroll viewport" }
        require(x == null || bounds.contains(x, y!!)) { "Scroll anchor is outside the visible app viewport" }
        val vertical = direction == "up" || direction == "down"
        val low = if (vertical) bounds.top + bounds.height * 0.08f else bounds.left + bounds.width * 0.08f
        val high = if (vertical) bounds.bottom - bounds.height * 0.08f else bounds.right - bounds.width * 0.08f
        val distance = (high - low) * 0.85f * amount.toFloat()
        val requestedCenter = if (vertical) y ?: (low + high) / 2 else x ?: (low + high) / 2
        val center = requestedCenter.coerceIn(low + distance / 2, high - distance / 2)
        val forward = direction == "down" || direction == "right"
        val start = center + (if (forward) 1 else -1) * distance / 2
        val end = center - (if (forward) 1 else -1) * distance / 2
        val cross = if (vertical) (x ?: (bounds.left + bounds.right) / 2).coerceIn(bounds.left + bounds.width * 0.08f, bounds.right - bounds.width * 0.08f)
            else (y ?: (bounds.top + bounds.bottom) / 2).coerceIn(bounds.top + bounds.height * 0.08f, bounds.bottom - bounds.height * 0.08f)
        val duration = (500 * amount).toLong().coerceIn(220, 500)
        return if (vertical) WoiScrollStroke(cross, start, cross, end, duration)
            else WoiScrollStroke(start, cross, end, cross, duration)
    }

    fun fromKey(key: String, modifiers: Set<String>): WoiScrollRequest? {
        if (modifiers.isNotEmpty()) return null
        return when (key) {
            "pageup" -> WoiScrollRequest("up")
            "pagedown" -> WoiScrollRequest("down")
            "up", "down", "left", "right" -> WoiScrollRequest(key, 0.25)
            else -> null
        }
    }
}

internal data class WoiScrollTarget(val packageName: String, val windowId: Int)

/** Public accessibility actions first for whole pages, then a bounded swipe
 * when unsupported/refused. Accepted actions are never replayed as gestures.
 * A completed gesture is reported as dispatched, not proof of page movement. */
internal class WoiScrollController(
    private val service: WoiAccessibilityService,
    private val target: () -> WoiScrollTarget?,
    private val obstruction: () -> Rect?,
    private val gestureStart: (Float, Float) -> Unit,
    private val gestureEnd: () -> Unit,
    private val gestureCancelled: () -> Unit,
) {
    private var busy = false
    private var lastEventAt = 0L
    private var lastEventTarget: WoiScrollTarget? = null

    fun observed(packageName: String?, windowId: Int) {
        if (packageName == null) return
        lastEventTarget = WoiScrollTarget(packageName, windowId)
        lastEventAt = SystemClock.uptimeMillis()
    }

    private data class Pane(val bounds: WoiScrollBounds, val node: AccessibilityNodeInfo?, val action: Int?)

    private fun clipped(rect: Rect): Rect {
        val result = Rect(rect)
        val metrics = android.util.DisplayMetrics()
        @Suppress("DEPRECATION")
        (service.getSystemService(Context.WINDOW_SERVICE) as WindowManager).defaultDisplay.getRealMetrics(metrics)
        check(result.intersect(0, 0, metrics.widthPixels, metrics.heightPixels)) { "App is outside the current screen" }
        val covers = service.windows.filter { it.type == AccessibilityWindowInfo.TYPE_INPUT_METHOD }.map {
            Rect().also(it::getBoundsInScreen)
        } + listOfNotNull(obstruction())
        for (cover in covers) {
            if (!Rect.intersects(result, cover) || cover.width() < result.width() / 2) continue
            if (cover.bottom >= result.bottom - 8 && cover.top > result.top) result.bottom = cover.top
            else if (cover.top <= result.top + 8 && cover.bottom < result.bottom) result.top = cover.bottom
        }
        check(result.width() >= 48 && result.height() >= 48) { "No unobscured app viewport; dismiss or move the keyboard" }
        return result
    }

    private fun action(node: AccessibilityNodeInfo, direction: String): Int? {
        val actions = node.actionList.map { it.id }.toSet()
        val directional = when (direction) {
            "up" -> AccessibilityNodeInfo.AccessibilityAction.ACTION_SCROLL_UP.id
            "down" -> AccessibilityNodeInfo.AccessibilityAction.ACTION_SCROLL_DOWN.id
            "left" -> AccessibilityNodeInfo.AccessibilityAction.ACTION_SCROLL_LEFT.id
            else -> AccessibilityNodeInfo.AccessibilityAction.ACTION_SCROLL_RIGHT.id
        }
        if (directional in actions) return directional
        // A legacy forward/backward action can be horizontal. Directional
        // advertisements and HorizontalScrollView must not reverse our intent.
        val horizontalOnly = (AccessibilityNodeInfo.AccessibilityAction.ACTION_SCROLL_LEFT.id in actions ||
            AccessibilityNodeInfo.AccessibilityAction.ACTION_SCROLL_RIGHT.id in actions) &&
            AccessibilityNodeInfo.AccessibilityAction.ACTION_SCROLL_UP.id !in actions &&
            AccessibilityNodeInfo.AccessibilityAction.ACTION_SCROLL_DOWN.id !in actions
        if (horizontalOnly || node.className?.toString()?.contains("HorizontalScrollView") == true) return null
        val generic = when (direction) {
            "up" -> AccessibilityNodeInfo.ACTION_SCROLL_BACKWARD
            "down" -> AccessibilityNodeInfo.ACTION_SCROLL_FORWARD
            else -> null
        }
        return generic?.takeIf { it in actions }
    }

    private fun pane(app: WoiScrollTarget, request: WoiScrollRequest): Pane {
        val window = service.windows.firstOrNull { it.id == app.windowId && it.type == AccessibilityWindowInfo.TYPE_APPLICATION }
            ?: error("The target application window is no longer visible")
        val viewport = clipped(Rect().also(window::getBoundsInScreen))
        require(request.x == null || viewport.contains(request.x.toInt(), request.y!!.toInt())) {
            "Scroll anchor is outside the unobscured application viewport"
        }
        val root = window.root ?: error("The current app did not expose a viewport")
        var selected: AccessibilityNodeInfo? = null
        var selectedBounds: Rect? = null
        var selectedAction: Int? = null
        var score = if (request.x == null) -1L else Long.MAX_VALUE
        var visited = 0
        try {
            check(root.packageName?.toString() == app.packageName) { "The scroll target changed" }
            fun walk(node: AccessibilityNodeInfo, depth: Int) {
                if (++visited > 800 || depth > 48) return
                if (node.isVisibleToUser && node.isEnabled) {
                    val bounds = Rect().also(node::getBoundsInScreen)
                    val supported = action(node, request.direction)
                    if ((supported != null || node.isScrollable) && bounds.intersect(viewport) && bounds.width() >= 48 && bounds.height() >= 48 &&
                        (request.x == null || bounds.contains(request.x.toInt(), request.y!!.toInt()))) {
                        val area = bounds.width().toLong() * bounds.height()
                        if ((request.x == null && area > score) || (request.x != null && area < score)) {
                            WoiAccessibilityService.recycle(selected)
                            selected = AccessibilityNodeInfo.obtain(node)
                            selectedBounds = bounds
                            selectedAction = supported
                            score = area
                        }
                    }
                }
                for (index in 0 until node.childCount) {
                    if (visited >= 800) break
                    val child = node.getChild(index) ?: continue
                    try { walk(child, depth + 1) } finally { WoiAccessibilityService.recycle(child) }
                }
            }
            walk(root, 0)
            val rect = selectedBounds ?: viewport
            return Pane(WoiScrollBounds(rect.left.toFloat(), rect.top.toFloat(), rect.right.toFloat(), rect.bottom.toFloat()), selected, selectedAction)
        } catch (error: Throwable) {
            WoiAccessibilityService.recycle(selected)
            throw error
        } finally { WoiAccessibilityService.recycle(root) }
    }

    fun scroll(request: WoiScrollRequest, result: MethodChannel.Result, checkInput: () -> Unit) {
        if (busy) return result.error("scroll_busy", "A scroll is still finishing; no input was sent", null)
        val app = target() ?: return result.error("no_scroll_target", "Focus the application to scroll first", null)
        busy = true
        val started = SystemClock.uptimeMillis()
        var completed = 0.0
        val backends = linkedSetOf<String>()
        val gestures = mutableListOf<List<Int>>()
        var lastBounds: WoiScrollBounds? = null
        var done = false
        fun fail(message: String) {
            if (done) return
            done = true
            busy = false
            result.error("scroll_stopped", "$message (completed $completed/${request.amount} viewports; do not retry automatically)",
                mapOf("completed_amount" to completed, "retry_safe" to false))
        }
        fun checkTarget() {
            checkInput()
            check(target() == app) { "The focused app or window changed; scrolling stopped" }
        }
        fun finish() {
            if (done) return
            done = true
            busy = false
            result.success(mapOf(
                "direction" to request.direction, "amount" to request.amount, "completed_amount" to completed,
                "package" to app.packageName, "backend" to backends.joinToString("+"),
                "delivery" to if (gestures.isEmpty()) "accepted" else "dispatched",
                "scroll_event_observed" to (lastEventAt >= started && lastEventTarget == app),
                "viewport" to lastBounds?.wire(), "gestures" to gestures,
            ))
        }
        fun step() {
            if (done) return
            try {
                checkTarget()
                if (request.amount - completed < 0.0001) return finish()
                val amount = min(1.0, request.amount - completed)
                val pane = pane(app, request)
                lastBounds = pane.bounds
                val accepted = try {
                    request.strategy == "auto" && abs(amount - 1.0) < 0.0001 && pane.action != null &&
                        pane.node?.performAction(pane.action) == true
                } finally { WoiAccessibilityService.recycle(pane.node) }
                if (accepted) {
                    completed += amount
                    backends.add("android_accessibility_scroll")
                    WoiBridge.main.postDelayed(::step, 300)
                    return
                }
                checkTarget()
                val stroke = WoiScrollPlan.stroke(pane.bounds, request.direction, amount, request.x, request.y)
                gestureStart(stroke.fromX, stroke.fromY)
                val path = Path().apply { moveTo(stroke.fromX, stroke.fromY); lineTo(stroke.toX, stroke.toY) }
                val gesture = GestureDescription.Builder().addStroke(GestureDescription.StrokeDescription(path, 0, stroke.durationMs)).build()
                val acceptedGesture = service.dispatchGesture(gesture, object : AccessibilityService.GestureResultCallback() {
                    override fun onCompleted(gestureDescription: GestureDescription?) {
                        gestureEnd()
                        if (done) return
                        completed += amount
                        backends.add("android_accessibility_gesture")
                        gestures.add(listOf(stroke.fromX.toInt(), stroke.fromY.toInt(), stroke.toX.toInt(), stroke.toY.toInt()))
                        WoiBridge.main.postDelayed(::step, 180)
                    }
                    override fun onCancelled(gestureDescription: GestureDescription?) {
                        gestureEnd()
                        gestureCancelled()
                        fail("The scroll gesture was cancelled; do not retry automatically")
                    }
                }, WoiBridge.main)
                if (!acceptedGesture) { gestureEnd(); fail("Android refused the scroll gesture; no automatic retry") }
            } catch (error: Throwable) { fail(error.message ?: "Scroll failed") }
        }
        WoiBridge.main.postDelayed({
            if (!done) { gestureEnd(); fail("Android did not finish the scroll in time") }
        }, 8000)
        step()
    }
}
