package dev.woi.woi

import android.accessibilityservice.AccessibilityServiceInfo
import android.app.Activity
import android.app.Instrumentation
import android.app.UiAutomation
import android.content.ComponentName
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.Rect
import android.os.Bundle
import android.os.Build
import android.os.SystemClock
import android.provider.Settings
import android.view.InputDevice
import android.view.MotionEvent
import android.view.accessibility.AccessibilityNodeInfo
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/** Native device proof without network/AI calls or production test hooks.
 * Run the standard test runner with -e group control. The short pre-action indicator
 * and three-second native trailing holds complement Dart ControlGuard timing tests. */
class ControlOverlayDeviceCheck(private val host: Instrumentation) {
    private lateinit var ui: UiAutomation
    private lateinit var shotsDir: File
    private val shots = mutableListOf<String>()
    private val log = StringBuilder()
    private var passed = 0
    private var width = 0
    private var height = 0
    private lateinit var backdrop: Bitmap
    private val density get() = host.targetContext.resources.displayMetrics.density
    private val testPackage get() = host.context.packageName

    private data class Reply(val value: Any?, val error: String?)

    private fun native(method: String, args: Map<String, Any?> = emptyMap()): Reply {
        val done = CountDownLatch(1)
        var reply = Reply(null, "No callback")
        host.runOnMainSync {
            try {
                WoiAccessibilityService.handle(MethodCall(method, args), object : MethodChannel.Result {
                    override fun success(result: Any?) { reply = Reply(result, null); done.countDown() }
                    override fun error(code: String, message: String?, details: Any?) {
                        reply = Reply(null, "$code: $message"); done.countDown()
                    }
                    override fun notImplemented() { reply = Reply(null, "Not implemented: $method"); done.countDown() }
                })
            } catch (error: Throwable) { reply = Reply(null, error.toString()); done.countDown() }
        }
        check(done.await(6, TimeUnit.SECONDS)) { "$method did not complete" }
        return reply
    }

    private fun ok(method: String, args: Map<String, Any?> = emptyMap()): Any? {
        val reply = native(method, args)
        check(reply.error == null) { "$method: ${reply.error}" }
        return reply.value
    }

    private fun waitFor(label: String, timeout: Long = 5000, condition: () -> Boolean) {
        val until = SystemClock.elapsedRealtime() + timeout
        while (!condition()) {
            check(SystemClock.elapsedRealtime() < until) { "Timed out: $label" }
            SystemClock.sleep(40)
        }
    }

    private fun node(description: String): AccessibilityNodeInfo? {
        fun find(root: AccessibilityNodeInfo): AccessibilityNodeInfo? {
            if (root.contentDescription?.toString() == description) return root
            for (i in 0 until root.childCount) {
                val child = root.getChild(i) ?: continue
                val found = find(child)
                if (found != null) return found
            }
            return null
        }
        val root = ui.rootInActiveWindow ?: return null
        if (root.packageName?.toString() != testPackage) return null
        return find(root)
    }

    private fun requireNode(description: String): AccessibilityNodeInfo =
        checkNotNull(node(description)) { "Neutral test screen is not active: $description" }

    private fun text(description: String): String {
        val found = requireNode(description)
        return if (Build.VERSION.SDK_INT >= 26 && found.isShowingHintText) "" else found.text?.toString() ?: ""
    }
    private fun touches() = text("woi-test-count").substringAfter(": ").toInt()
    private fun longPresses() = text("woi-test-long-count").substringAfter(": ").toInt()
    private fun buttonRect() = Rect().also { requireNode("woi-test-button").getBoundsInScreen(it) }

    private fun setEditor(value: String) {
        val editor = requireNode("woi-test-input")
        if (!editor.isFocused) check(editor.performAction(AccessibilityNodeInfo.ACTION_FOCUS))
        check(requireNode("woi-test-input").performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, Bundle().apply {
            putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, value)
        }))
        waitFor("editor preparation") { text("woi-test-input") == value }
    }

    private fun userTap(x: Int, y: Int) {
        requireNode("woi-test-button")
        val start = SystemClock.uptimeMillis()
        for ((action, whenMs) in listOf(MotionEvent.ACTION_DOWN to start, MotionEvent.ACTION_UP to start + 60)) {
            val event = MotionEvent.obtain(start, whenMs, action, x.toFloat(), y.toFloat(), 0)
            event.source = InputDevice.SOURCE_TOUCHSCREEN
            try { check(ui.injectInputEvent(event, true)) { "Touch injection refused" } } finally { event.recycle() }
            if (action == MotionEvent.ACTION_DOWN) SystemClock.sleep(60)
        }
    }

    private fun rebindAlreadyEnabledService() {
        if (WoiAccessibilityService.instance != null) return
        val resolver = host.targetContext.contentResolver
        val key = Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES
        val original = Settings.Secure.getString(resolver, key) ?: ""
        val component = ComponentName(host.targetContext, WoiAccessibilityService::class.java)
        val entries = original.split(':')
        check(entries.any { ComponentName.unflattenFromString(it) == component }) {
            "Woi accessibility must already be enabled before this device test"
        }
        // Starting instrumentation kills the target process, which Android can
        // mark as a crashed accessibility service. Rebind only this existing
        // entry; do not grant permissions or change any other service setting.
        try {
            check(Settings.Secure.putString(resolver, key,
                entries.filter { ComponentName.unflattenFromString(it) != component }.joinToString(":")))
            SystemClock.sleep(250)
        } finally {
            check(Settings.Secure.putString(resolver, key, original))
        }
    }

    private fun <T> screenshot(name: String, inspect: (Bitmap) -> T): T {
        requireNode("woi-test-button")
        SystemClock.sleep(120)
        val raw = checkNotNull(ui.takeScreenshot()) { "Device screenshot unavailable" }
        val bitmap = try { checkNotNull(raw.copy(Bitmap.Config.ARGB_8888, false)) } finally { raw.recycle() }
        try {
            width = bitmap.width; height = bitmap.height
            val file = File(shotsDir, "$name.png")
            file.outputStream().use { check(bitmap.compress(Bitmap.CompressFormat.PNG, 100, it)) }
            shots.add(file.absolutePath)
            return inspect(bitmap)
        } finally { bitmap.recycle() }
    }

    private fun region(x: Int, y: Int, dx: Int = 45, dy: Int = 75) = Rect(
        (x - dx * density).toInt().coerceAtLeast(0), (y - dy * density).toInt().coerceAtLeast(0),
        (x + dx * density).toInt().coerceAtMost(width), (y + dy * density).toInt().coerceAtMost(height))

    private fun blueCount(bitmap: Bitmap, area: Rect, light: Boolean = false): Int {
        if (area.isEmpty) return 0
        val pixels = IntArray(area.width() * area.height())
        bitmap.getPixels(pixels, 0, area.width(), area.left, area.top, area.width(), area.height())
        return pixels.count {
            val r = Color.red(it); val g = Color.green(it); val b = Color.blue(it)
            if (light) b >= 245 && g in 228..250 && r in 210..240 && b - r >= 14
            else b >= 230 && g in 190..240 && r in 130..200 && b - r >= 30
        }
    }

    private fun cursorAt(bitmap: Bitmap, x: Int, y: Int, expected: Int) {
        fun matches(px: Int, py: Int): Boolean {
            val actual = bitmap.getPixel(px, py)
            val background = backdrop.getPixel(px, py)
            // The complete overlay is composited at 0.5, including pointer
            // fill/stroke and keyboard text. An opaque cursor must fail.
            val blended = Color.rgb((Color.red(expected) + Color.red(background)) / 2,
                (Color.green(expected) + Color.green(background)) / 2,
                (Color.blue(expected) + Color.blue(background)) / 2)
            return kotlin.math.abs(Color.red(actual) - Color.red(blended)) <= 3 &&
                kotlin.math.abs(Color.green(actual) - Color.green(blended)) <= 3 &&
                kotlin.math.abs(Color.blue(actual) - Color.blue(blended)) <= 3
        }
        // Match the arrow's triangular head and diagonal stem at the real
        // hotspot; the old centered ring cannot satisfy these samples.
        for ((dx, dy) in listOf(4 to 12, 16 to 32)) {
            check(matches(x + (dx * density).toInt(), y + (dy * density).toInt())) {
                "Cursor shape/color missing at hotspot $x,$y ($dx,$dy)"
            }
        }
        check(!matches(x - (6 * density).toInt(), y + (12 * density).toInt())) {
            "Cursor is not anchored at the requested hotspot"
        }
    }

    private fun verify(name: String, body: () -> Unit) {
        body(); passed++; log.append("PASS ").append(name).append('\n')
    }

    fun run() {
        var failure: Throwable? = null
        try {
            ui = host.getUiAutomation(UiAutomation.FLAG_DONT_SUPPRESS_ACCESSIBILITY_SERVICES)
            ui.serviceInfo = ui.serviceInfo.apply {
                flags = flags or AccessibilityServiceInfo.FLAG_RETRIEVE_INTERACTIVE_WINDOWS
            }
            shotsDir = File(checkNotNull(host.targetContext.getExternalFilesDir(null)),
                "qa-control-${SystemClock.elapsedRealtime()}").apply { check(mkdirs()) }
            host.runOnMainSync { if (WoiOverlay.showing) WoiOverlay.hide() }
            host.targetContext.startActivity(Intent().apply {
                component = ComponentName(testPackage, ControlOverlayTestActivity::class.java.name)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK)
            })
            waitFor("test activity") { node("woi-test-button") != null }
            rebindAlreadyEnabledService()
            waitFor("Woi accessibility service", 15000) { WoiAccessibilityService.instance != null }
            val service = checkNotNull(WoiAccessibilityService.instance)
            check((service.serviceInfo.flags and AccessibilityServiceInfo.FLAG_REQUEST_TOUCH_EXPLORATION_MODE) == 0) {
                "The Woi service must not request touch exploration"
            }
            ok("controlReset")
            screenshot("baseline") { backdrop = checkNotNull(it.copy(Bitmap.Config.ARGB_8888, false)) }

            verify("pointer begin, move-only update and end") {
                val x1 = width / 5; val y1 = height * 2 / 3
                val x2 = width * 3 / 4; val y2 = height * 4 / 5
                val before = touches()
                check(ok("controlBegin", mapOf("kind" to "pointer", "x" to x1, "y" to y1)) == true)
                screenshot("pointer-before") { cursorAt(it, x1, y1, Color.rgb(92, 190, 255)) }
                check(ok("controlInterrupted") == false)
                ok("controlUpdate", mapOf("x" to x2, "y" to y2))
                screenshot("pointer-moved") {
                    cursorAt(it, x2, y2, Color.rgb(92, 190, 255))
                    check(blueCount(it, region(x1, y1)) < 50) { "Old pointer marker remained" }
                }
                check(touches() == before) { "Moving the virtual pointer unexpectedly tapped" }
                SystemClock.sleep(3000)
                check(ok("controlInterrupted") == false)
                ok("controlEnd")
                screenshot("pointer-ended") { check(blueCount(it, region(x2, y2)) < 50) { "Pointer did not hide" } }
            }

            verify("left tap uses a darker blue cursor without cancelling itself") {
                ok("controlReset")
                val box = buttonRect(); val before = touches()
                check(ok("controlBegin", mapOf("kind" to "pointer", "x" to box.centerX(), "y" to box.centerY())) == true)
                screenshot("left-warning") { cursorAt(it, box.centerX(), box.centerY(), Color.rgb(92, 190, 255)) }
                SystemClock.sleep(120)
                check(ok("click", mapOf("x" to box.centerX(), "y" to box.centerY(), "button" to "left")) == true)
                waitFor("AI tap delivery") { touches() == before + 1 }
                check(ok("controlInterrupted") == false) { "Injected AI tap cancelled itself" }
                screenshot("left-click") { cursorAt(it, box.centerX(), box.centerY(), Color.rgb(52, 155, 231)) }
                SystemClock.sleep(3000)
                ok("controlEnd")
            }

            verify("right click is a red long press; unsupported buttons emit no tap") {
                ok("controlReset")
                val box = buttonRect(); val before = touches(); val longBefore = longPresses()
                check(ok("controlBegin", mapOf("kind" to "pointer", "x" to box.centerX(), "y" to box.centerY())) == true)
                screenshot("right-warning") { cursorAt(it, box.centerX(), box.centerY(), Color.rgb(92, 190, 255)) }
                SystemClock.sleep(120)
                check(ok("click", mapOf("x" to box.centerX(), "y" to box.centerY(), "button" to "right")) == true)
                waitFor("context long press") { longPresses() == longBefore + 1 }
                check(touches() == before) { "Right long press also emitted a left tap" }
                check(ok("controlInterrupted") == false) { "Long press cancelled itself" }
                screenshot("right-click") { cursorAt(it, box.centerX(), box.centerY(), Color.rgb(255, 166, 166)) }
                check(native("click", mapOf("x" to box.centerX(), "y" to box.centerY(), "button" to "middle")).error?.startsWith("unsupported_button:") == true)
                check(touches() == before && longPresses() == longBefore + 1)
                SystemClock.sleep(3000)
                ok("controlEnd")
            }

            verify("user touch passes through and blocks further mouse/keyboard input") {
                ok("controlReset"); setEditor("")
                val box = buttonRect(); val before = touches()
                check(ok("controlBegin", mapOf("kind" to "pointer", "x" to box.centerX(), "y" to box.centerY())) == true)
                SystemClock.sleep(150)
                userTap(box.centerX(), box.centerY())
                waitFor("user touch pass-through") { touches() == before + 1 }
                waitFor("takeover latch") { ok("controlInterrupted") == true }
                screenshot("user-takeover") { }
                check(native("click", mapOf("x" to box.centerX(), "y" to box.centerY())).error != null)
                check(native("typeText", mapOf("text" to "must-not-type")).error != null)
                check(ok("controlBegin", mapOf("kind" to "keyboard", "keys" to "blocked")) == false)
                SystemClock.sleep(250)
                check(touches() == before + 1 && text("woi-test-input").isEmpty()) { "Input continued after takeover" }
                SystemClock.sleep(3000)
                ok("controlEnd")
            }

            verify("user takeover is still armed in the third trailing second") {
                ok("controlReset")
                val box = buttonRect(); val before = touches()
                check(ok("controlBegin", mapOf("kind" to "pointer", "x" to box.centerX(), "y" to box.centerY())) == true)
                SystemClock.sleep(120)
                check(ok("click", mapOf("x" to box.centerX(), "y" to box.centerY(), "button" to "left")) == true)
                waitFor("trailing AI tap") { touches() == before + 1 }
                SystemClock.sleep(2300)
                screenshot("pointer-third-second") { cursorAt(it, box.centerX(), box.centerY(), Color.rgb(52, 155, 231)) }
                userTap(box.centerX(), box.centerY())
                waitFor("trailing user touch") { touches() == before + 2 }
                waitFor("trailing takeover latch") { ok("controlInterrupted") == true }
                check(native("click", mapOf("x" to box.centerX(), "y" to box.centerY())).error != null)
                SystemClock.sleep(700)
                ok("controlEnd")
            }

            verify("keyboard warning preserves focus and typing, then hides") {
                ok("controlReset"); setEditor("")
                val typed = "overlay-keyboard-check"
                check(ok("controlBegin", mapOf("kind" to "keyboard", "keys" to typed)) == true)
                check(requireNode("woi-test-input").isFocused) { "Keyboard indicator stole focus" }
                screenshot("keyboard-warning") {
                    check(blueCount(it, region(width / 2, height / 2, 110, 120), true) > 500) { "Keyboard icon missing" }
                    check(blueCount(it, Rect(width / 4, 0, width, (150 * density).toInt()), true) > 500) { "Key badge missing" }
                }
                SystemClock.sleep(120)
                ok("typeText", mapOf("text" to typed))
                waitFor("native typing") { text("woi-test-input") == typed }
                check(ok("controlInterrupted") == false)
                ok("controlUpdate", mapOf("keys" to "typed: $typed"))
                screenshot("keyboard-typed") { }
                SystemClock.sleep(3000)
                ok("controlEnd")
                screenshot("keyboard-ended") {
                    check(blueCount(it, region(width / 2, height / 2, 110, 120), true) < 50) { "Keyboard icon did not hide" }
                }
            }
        } catch (error: Throwable) {
            failure = error
        } finally {
            if (::backdrop.isInitialized) backdrop.recycle()
            if (WoiAccessibilityService.instance != null) {
                try { ok("controlReset") } catch (_: Throwable) {}
            }
        }
        val problem = failure
        val result = Bundle().apply {
            putString("stream", "\n$log\n$passed native control checks passed.\n" +
                if (problem == null) "Screenshots:\n${shots.joinToString("\n")}\n" else "FAILED: ${problem.stackTraceToString()}\n")
            putInt("passed", passed)
            putString("screenshots", shots.joinToString("\n"))
            if (problem != null) putString("failure", problem.toString())
        }
        host.finish(if (problem == null) Activity.RESULT_OK else Activity.RESULT_CANCELED, result)
    }
}
