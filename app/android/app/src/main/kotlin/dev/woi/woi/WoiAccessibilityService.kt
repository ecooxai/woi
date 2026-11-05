package dev.woi.woi

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.GestureDescription
import android.content.ClipData
import android.content.ClipboardManager
import android.graphics.Bitmap
import android.graphics.Path
import android.os.Build
import android.os.Bundle
import android.view.Display
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Input for click_screen / type_text / send_keys in the app the user is
 * using: taps through dispatchGesture, text through ACTION_SET_TEXT (paste as
 * fallback), keys through global actions (back, home, recents) and node
 * actions on the focused field (copy, paste, cut, select all, IME enter).
 *
 * When Woi itself is in front, it is sent to the back first so the action
 * reaches the app below; the floating assistant panel steps aside instead.
 */
class WoiAccessibilityService : AccessibilityService() {
    /** Last foreground package that is not Woi (the send_keys target). */
    @Volatile var targetPackage: String? = null
    @Volatile var activePackage: String? = null

    override fun onServiceConnected() {
        instance = this
        safe("onServiceConnected") {
            super.onServiceConnected()
            android.util.Log.i(WoiBridge.TAG, "a11y service connected")
        }
    }

    override fun onDestroy() {
        if (instance === this) instance = null
        super.onDestroy()
    }

    override fun onUnbind(intent: android.content.Intent?): Boolean {
        if (instance === this) instance = null
        return super.onUnbind(intent)
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) = safe("onAccessibilityEvent") {
        if (event?.eventType != AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED) return@safe
        val pkg = event.packageName?.toString() ?: return@safe
        if (pkg == "com.android.systemui") return@safe
        activePackage = pkg
        if (pkg != packageName) targetPackage = pkg
    }

    override fun onInterrupt() {}

    private fun woiInFront(): Boolean = try {
        val root = rootInActiveWindow?.packageName?.toString()
        (root ?: activePackage) == packageName
    } catch (e: Throwable) {
        activePackage == packageName
    }

    /** Sends Woi to the back (if in front) and waits for the app below. */
    private fun leaveWoi(settleMs: Long = 150, then: () -> Unit) {
        if (!woiInFront()) return safe("leaveWoi", then)
        WoiBridge.activity?.moveTaskToBack(true)
        val start = System.currentTimeMillis()
        fun poll() {
            if (!woiInFront() || System.currentTimeMillis() - start > 1200) {
                android.util.Log.i(WoiBridge.TAG, "left Woi in ${System.currentTimeMillis() - start} ms; front=${rootInActiveWindow?.packageName}")
                WoiBridge.main.postDelayed({ safe("leaveWoi", then) }, settleMs)
            } else {
                WoiBridge.main.postDelayed(::poll, 50)
            }
        }
        WoiBridge.main.postDelayed(::poll, 50)
    }

    /**
     * Runs [block] where the action reaches the app the user is in: with the
     * assistant panel up it steps aside (touches and focus pass through,
     * [visual] also hides it) until the action's result is sent; otherwise
     * Woi's task goes to the back as before.
     */
    private fun aside(settleMs: Long, result: MethodChannel.Result, visual: Boolean = false, block: (MethodChannel.Result) -> Unit) {
        if (!WoiOverlay.showing) return leaveWoi(settleMs) { guarded("aside", result) { block(it) } }
        WoiOverlay.stepAside(visual)
        val r = WoiOverlay.releasing(result)
        val start = System.currentTimeMillis()
        fun poll() {
            // Focus (the active window) moves back to the app once the panel
            // is not focusable; typing and node actions need that.
            if (!woiInFront() || System.currentTimeMillis() - start > 800) {
                android.util.Log.i(WoiBridge.TAG, "panel aside in ${System.currentTimeMillis() - start} ms; front=${rootInActiveWindow?.packageName}")
                WoiBridge.main.postDelayed({ guarded("aside", r) { block(it) } }, if (visual) 120L else 60L)
            } else {
                WoiBridge.main.postDelayed(::poll, 40)
            }
        }
        WoiBridge.main.postDelayed(::poll, 40)
    }

    private fun tap(x: Float, y: Float, count: Int, result: MethodChannel.Result) {
        val path = Path().apply { moveTo(x, y) }
        val builder = GestureDescription.Builder()
        for (i in 0 until count) {
            builder.addStroke(GestureDescription.StrokeDescription(path, i * 150L, 40L))
        }
        val ok = dispatchGesture(builder.build(), object : GestureResultCallback() {
            override fun onCompleted(g: GestureDescription?) = safe("gesture") { result.success(true) }
            override fun onCancelled(g: GestureDescription?) = safe("gesture") { result.error("cancelled", "gesture cancelled", null) }
        }, null)
        if (!ok) result.error("failed", "dispatchGesture refused", null)
    }

    private fun focused(): AccessibilityNodeInfo? =
        findFocus(AccessibilityNodeInfo.FOCUS_INPUT) ?: rootInActiveWindow?.findFocus(AccessibilityNodeInfo.FOCUS_INPUT)

    private fun typeText(text: String): String {
        val node = focused() ?: throw IllegalStateException("no focused text field in ${activePackage ?: "the app"}")
        if (node.isEditable) {
            val cur = if (node.isShowingHintText) "" else (node.text?.toString() ?: "")
            var s = node.textSelectionStart
            var e = node.textSelectionEnd
            if (s < 0 || s > cur.length) s = cur.length
            if (e < s || e > cur.length) e = s
            val next = cur.substring(0, s) + text + cur.substring(e)
            val args = Bundle().apply {
                putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, next)
            }
            if (node.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, args)) {
                val caret = s + text.length
                node.performAction(AccessibilityNodeInfo.ACTION_SET_SELECTION, Bundle().apply {
                    putInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_START_INT, caret)
                    putInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_END_INT, caret)
                })
                return "set_text"
            }
        }
        // Web content (WebView / Chrome inputs) often refuses set-text but has
        // the IME connection: commit through the service's own input method
        // (Android 13+, flagInputMethodEditor), which leaves the clipboard be.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            val ic = inputMethod?.currentInputConnection
            if (ic != null) {
                ic.commitText(text, 1, null)
                return "ime"
            }
        }
        // Fallback: clipboard + paste.
        val cm = getSystemService(ClipboardManager::class.java)
        cm.setPrimaryClip(ClipData.newPlainText("woi", text))
        if (!node.performAction(AccessibilityNodeInfo.ACTION_PASTE)) {
            throw IllegalStateException("the focused field accepts neither set-text nor paste")
        }
        return "paste"
    }

    private fun nodeAction(name: String): String {
        val node = focused() ?: throw IllegalStateException("no focused field for $name")
        val ok = when (name) {
            "copy" -> node.performAction(AccessibilityNodeInfo.ACTION_COPY)
            "paste" -> node.performAction(AccessibilityNodeInfo.ACTION_PASTE)
            "cut" -> node.performAction(AccessibilityNodeInfo.ACTION_CUT)
            "select_all" -> {
                val len = if (node.isShowingHintText) 0 else (node.text?.length ?: 0)
                node.performAction(AccessibilityNodeInfo.ACTION_SET_SELECTION, Bundle().apply {
                    putInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_START_INT, 0)
                    putInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_END_INT, len)
                })
            }
            "enter" -> (Build.VERSION.SDK_INT >= 30 &&
                node.performAction(AccessibilityNodeInfo.AccessibilityAction.ACTION_IME_ENTER.id)) || imeEnter()
            "clear_selection" -> node.performAction(AccessibilityNodeInfo.ACTION_CLEAR_SELECTION)
            else -> throw IllegalArgumentException("unknown node action $name")
        }
        if (!ok) throw IllegalStateException("$name is not available in the focused field")
        return name
    }

    /** Enter through the service's input method (web inputs that lack
     *  ACTION_IME_ENTER still take the key from the IME connection). */
    private fun imeEnter(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return false
        val ic = inputMethod?.currentInputConnection ?: return false
        val now = android.os.SystemClock.uptimeMillis()
        ic.sendKeyEvent(android.view.KeyEvent(now, now, android.view.KeyEvent.ACTION_DOWN, android.view.KeyEvent.KEYCODE_ENTER, 0))
        ic.sendKeyEvent(android.view.KeyEvent(now, now, android.view.KeyEvent.ACTION_UP, android.view.KeyEvent.KEYCODE_ENTER, 0))
        return true
    }

    /** The app's IME connection comes back a moment after the panel steps
     *  aside: retry Enter through it for up to 600 ms. */
    private fun imeEnterSoon(cause: Exception, r: MethodChannel.Result, start: Long = android.os.SystemClock.uptimeMillis()) {
        if (imeEnter()) return r.success("enter")
        if (android.os.SystemClock.uptimeMillis() - start > 600) return r.error("failed", cause.message, null)
        WoiBridge.main.postDelayed({ imeEnterSoon(cause, r, start) }, 50)
    }

    private fun global(name: String): Boolean {
        val action = when (name) {
            "back" -> GLOBAL_ACTION_BACK
            "home" -> GLOBAL_ACTION_HOME
            "recents" -> GLOBAL_ACTION_RECENTS
            "notifications" -> GLOBAL_ACTION_NOTIFICATIONS
            "quick_settings" -> GLOBAL_ACTION_QUICK_SETTINGS
            else -> throw IllegalArgumentException("unknown global action $name")
        }
        val ok = performGlobalAction(action)
        android.util.Log.i(WoiBridge.TAG, "global $name -> $ok (front=${rootInActiveWindow?.packageName})")
        return ok
    }

    /**
     * Visible elements of the app windows (not Woi's, not the system bars) for
     * click_screen target matching: role, name (text, content description or
     * hint) and bounds in screen pixels, the same space dispatchGesture uses.
     */
    private fun elements(max: Int): List<Map<String, Any>> {
        val out = ArrayList<Map<String, Any>>()
        val roots = windows.filter { w ->
            val pkg = w.root?.packageName?.toString()
            pkg != null && pkg != packageName && pkg != "com.android.systemui" &&
                w.type != android.view.accessibility.AccessibilityWindowInfo.TYPE_ACCESSIBILITY_OVERLAY
        }.sortedByDescending { it.layer }.mapNotNull { it.root }
        val r = android.graphics.Rect()
        fun walk(n: AccessibilityNodeInfo, depth: Int) {
            if (out.size >= max || depth > 60 || !n.isVisibleToUser) return
            val name = (n.text ?: n.contentDescription ?: (if (Build.VERSION.SDK_INT >= 26) n.hintText else null))
                ?.toString()?.trim().orEmpty()
            val actionable = n.isClickable || n.isEditable || n.isCheckable || n.isLongClickable
            if (name.isNotEmpty() || actionable) {
                n.getBoundsInScreen(r)
                if (r.width() > 1 && r.height() > 1) {
                    out.add(mapOf("role" to androidRole(n), "name" to name.take(120),
                        "x" to r.left, "y" to r.top, "w" to r.width(), "h" to r.height()))
                }
            }
            for (i in 0 until n.childCount) {
                val c = try { n.getChild(i) } catch (e: Throwable) { null } ?: continue
                try { walk(c, depth + 1) } finally { recycle(c) }
            }
        }
        for (root in roots) try { walk(root, 0) } finally { recycle(root) }
        return out
    }

    private fun androidRole(n: AccessibilityNodeInfo): String {
        val c = n.className?.toString().orEmpty()
        return when {
            n.isEditable || c.endsWith("EditText") -> "entry"
            c.endsWith("CheckBox") -> "check box"
            c.endsWith("Switch") || c.endsWith("SwitchCompat") -> "switch"
            c.endsWith("RadioButton") -> "radio button"
            c.endsWith("ToggleButton") -> "toggle button"
            c.endsWith("Spinner") -> "combo box"
            c.endsWith("Button") || c.endsWith("ImageButton") -> "button"
            c.endsWith("TabWidget") || c.contains("Tab") -> "page tab"
            n.isCheckable -> "check box"
            n.isClickable && c.endsWith("ImageView") -> "button"
            n.isClickable -> "button"
            else -> "label"
        }
    }

    private fun screenshot(call: MethodCall, result: MethodChannel.Result) {
        val scale = call.argument<Double>("scale") ?: ScreenshotEncoder.DEFAULT_SCALE
        val quality = call.argument<Int>("quality") ?: ScreenshotEncoder.DEFAULT_QUALITY
        val maxWidth = call.argument<Int>("maxWidth") ?: 0
        if (Build.VERSION.SDK_INT < 30) return result.error("unsupported", "needs Android 11", null)
        takeScreenshot(Display.DEFAULT_DISPLAY, mainExecutor, object : TakeScreenshotCallback {
            override fun onSuccess(shot: ScreenshotResult) = guarded("screenshot", result) { result ->
                val hw = Bitmap.wrapHardwareBuffer(shot.hardwareBuffer, shot.colorSpace)
                shot.hardwareBuffer.close()
                if (hw == null) return@guarded result.error("failed", "no bitmap", null)
                WoiBridge.io.execute {
                    try {
                        val sw = hw.copy(Bitmap.Config.ARGB_8888, true)
                        hw.recycle()
                        val map = ScreenshotEncoder.encodeToMap(sw, scale, quality, maxWidth, sw.width, sw.height)
                        sw.recycle()
                        WoiBridge.main.post { safe("screenshot") { result.success(map) } }
                    } catch (e: Throwable) {
                        android.util.Log.w(WoiBridge.TAG, "a11y screenshot encode failed", e)
                        WoiBridge.main.post { safe("screenshot") { result.error("failed", e.message ?: "$e", null) } }
                    }
                }
            }

            override fun onFailure(errorCode: Int) = safe("screenshot") { result.error("failed", "takeScreenshot error $errorCode", null) }
        })
    }

    companion object {
        @Volatile var instance: WoiAccessibilityService? = null

        /** Runs [block]; an exception is logged, never thrown into the
         *  framework (an uncaught one would kill the process and unbind the
         *  service). */
        inline fun safe(where: String, block: () -> Unit) {
            try {
                block()
            } catch (e: Throwable) {
                android.util.Log.w(WoiBridge.TAG, "a11y $where failed", e)
            }
        }

        /** Like [safe], but also answers [result] with the error (once). */
        inline fun guarded(where: String, result: MethodChannel.Result, block: (MethodChannel.Result) -> Unit) {
            try {
                block(result)
            } catch (e: Throwable) {
                android.util.Log.w(WoiBridge.TAG, "a11y $where failed", e)
                safe(where) { result.error("failed", e.message ?: "$e", null) }
            }
        }

        @Suppress("DEPRECATION")
        fun recycle(n: AccessibilityNodeInfo?) {
            if (n == null || Build.VERSION.SDK_INT >= 33) return
            try { n.recycle() } catch (_: Throwable) {}
        }

        fun handle(call: MethodCall, result: MethodChannel.Result) {
            val s = instance ?: return result.error(
                "no_accessibility",
                if (WoiA11yKeeper.ensure(WoiBridge.appContext, call.method))
                    "Woi's accessibility service was off and is being switched back on; try again in a moment"
                else "Woi's accessibility service is off (Settings > Accessibility > Woi)", null
            )
            when (call.method) {
                "click", "doubleClick" -> {
                    val x = (call.argument<Number>("x") ?: 0).toFloat()
                    val y = (call.argument<Number>("y") ?: 0).toFloat()
                    s.aside(350, result) { r -> s.tap(x, y, if (call.method == "doubleClick") 2 else 1, r) }
                }
                "typeText" -> s.aside(150, result) { r ->
                    try { r.success(s.typeText(call.argument<String>("text") ?: "")) } catch (e: Exception) {
                        r.error("failed", e.message, null)
                    }
                }
                "global" -> {
                    val name = call.argument<String>("name") ?: ""
                    // Global keys sent while the task-switch animation still
                    // runs can be dropped: let it finish first.
                    s.aside(450, result) { r -> r.success(s.global(name)) }
                }
                "node" -> s.aside(150, result) { r ->
                    val name = call.argument<String>("name") ?: ""
                    try { r.success(s.nodeAction(name)) } catch (e: Exception) {
                        if (name == "enter") s.imeEnterSoon(e, r) else r.error("failed", e.message, null)
                    }
                }
                // Read only: no stepping aside (Woi's own windows are skipped).
                "elements" -> WoiBridge.io.execute {
                    try {
                        val els = s.elements(call.argument<Int>("max") ?: 600)
                        WoiBridge.main.post { result.success(els) }
                    } catch (e: Exception) {
                        WoiBridge.main.post { result.error("failed", e.message, null) }
                    }
                }
                "focusTarget" -> s.aside(150, result) { r ->
                    r.success(mapOf("package" to (s.rootInActiveWindow?.packageName?.toString() ?: s.targetPackage)))
                }
                // The screen of the app the user is working in, not Woi's.
                "a11yScreenshot" -> if (call.argument<Boolean>("stepAside") != false) {
                    s.aside(350, result, visual = true) { r -> s.screenshot(call, r) }
                } else {
                    s.screenshot(call, result)
                }
                else -> result.notImplemented()
            }
        }
    }
}
