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
    }

    override fun onDestroy() {
        if (instance === this) instance = null
        super.onDestroy()
    }

    override fun onUnbind(intent: android.content.Intent?): Boolean {
        if (instance === this) instance = null
        return super.onUnbind(intent)
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        if (event?.eventType != AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED) return
        val pkg = event.packageName?.toString() ?: return
        if (pkg == "com.android.systemui") return
        activePackage = pkg
        if (pkg != packageName) targetPackage = pkg
    }

    override fun onInterrupt() {}

    private fun woiInFront(): Boolean {
        val root = rootInActiveWindow?.packageName?.toString()
        return (root ?: activePackage) == packageName
    }

    /** Sends Woi to the back (if in front) and waits for the app below. */
    private fun leaveWoi(settleMs: Long = 150, then: () -> Unit) {
        if (!woiInFront()) return then()
        WoiBridge.activity?.moveTaskToBack(true)
        val start = System.currentTimeMillis()
        fun poll() {
            if (!woiInFront() || System.currentTimeMillis() - start > 1200) {
                android.util.Log.i(WoiBridge.TAG, "left Woi in ${System.currentTimeMillis() - start} ms; front=${rootInActiveWindow?.packageName}")
                WoiBridge.main.postDelayed(then, settleMs)
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
        if (!WoiOverlay.showing) return leaveWoi(settleMs) { block(result) }
        WoiOverlay.stepAside(visual)
        val r = WoiOverlay.releasing(result)
        val start = System.currentTimeMillis()
        fun poll() {
            // Focus (the active window) moves back to the app once the panel
            // is not focusable; typing and node actions need that.
            if (!woiInFront() || System.currentTimeMillis() - start > 800) {
                android.util.Log.i(WoiBridge.TAG, "panel aside in ${System.currentTimeMillis() - start} ms; front=${rootInActiveWindow?.packageName}")
                WoiBridge.main.postDelayed({ block(r) }, if (visual) 120L else 60L)
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
            override fun onCompleted(g: GestureDescription?) = result.success(true)
            override fun onCancelled(g: GestureDescription?) = result.error("cancelled", "gesture cancelled", null)
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
            "enter" -> if (Build.VERSION.SDK_INT >= 30) {
                node.performAction(AccessibilityNodeInfo.AccessibilityAction.ACTION_IME_ENTER.id)
            } else false
            "clear_selection" -> node.performAction(AccessibilityNodeInfo.ACTION_CLEAR_SELECTION)
            else -> throw IllegalArgumentException("unknown node action $name")
        }
        if (!ok) throw IllegalStateException("$name is not available in the focused field")
        return name
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

    private fun screenshot(maxWidth: Int, result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < 30) return result.error("unsupported", "needs Android 11", null)
        takeScreenshot(Display.DEFAULT_DISPLAY, mainExecutor, object : TakeScreenshotCallback {
            override fun onSuccess(shot: ScreenshotResult) {
                val hw = Bitmap.wrapHardwareBuffer(shot.hardwareBuffer, shot.colorSpace)
                shot.hardwareBuffer.close()
                if (hw == null) return result.error("failed", "no bitmap", null)
                WoiBridge.io.execute {
                    val sw = hw.copy(Bitmap.Config.ARGB_8888, false)
                    hw.recycle()
                    val map = WoiScreen.encode(sw, maxWidth)
                    sw.recycle()
                    WoiBridge.main.post { result.success(map) }
                }
            }

            override fun onFailure(errorCode: Int) = result.error("failed", "takeScreenshot error $errorCode", null)
        })
    }

    companion object {
        @Volatile var instance: WoiAccessibilityService? = null

        fun handle(call: MethodCall, result: MethodChannel.Result) {
            val s = instance ?: return result.error(
                "no_accessibility",
                "Woi's accessibility service is off (Settings > Accessibility > Woi)", null
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
                    try { r.success(s.nodeAction(call.argument<String>("name") ?: "")) } catch (e: Exception) {
                        r.error("failed", e.message, null)
                    }
                }
                "focusTarget" -> s.aside(150, result) { r ->
                    r.success(mapOf("package" to (s.rootInActiveWindow?.packageName?.toString() ?: s.targetPackage)))
                }
                // The screen of the app the user is working in, not Woi's.
                "a11yScreenshot" -> if (call.argument<Boolean>("stepAside") != false) {
                    s.aside(350, result, visual = true) { r -> s.screenshot(call.argument<Int>("maxWidth") ?: 1280, r) }
                } else {
                    s.screenshot(call.argument<Int>("maxWidth") ?: 1280, result)
                }
                else -> result.notImplemented()
            }
        }
    }
}
