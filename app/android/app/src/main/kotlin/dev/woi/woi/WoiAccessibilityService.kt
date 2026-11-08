package dev.woi.woi

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.GestureDescription
import android.graphics.Bitmap
import android.graphics.Path
import android.os.Build
import android.os.Bundle
import android.view.Display
import android.view.ViewConfiguration
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Input for click_screen / type_text / send_keys in the app the user is
 * using: taps through dispatchGesture; literal text and exact key chords
 * through the public accessibility InputConnection on Android 13+; semantic
 * edits and older-Android text use supported node actions. System navigation
 * uses global accessibility actions. No IME selection or permission changes.
 *
 * When Woi itself is in front, it is sent to the back first so the action
 * reaches the app below; the floating assistant panel steps aside instead.
 */
class WoiAccessibilityService : AccessibilityService() {
    private val control by lazy { WoiControlOverlay(this) }
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
        keyboardEpoch.cancel()
        control.end()
        if (instance === this) instance = null
        super.onDestroy()
    }

    override fun onUnbind(intent: android.content.Intent?): Boolean {
        keyboardEpoch.cancel()
        control.end()
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

    override fun onInterrupt() { control.cancel() }

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

    private fun tap(x: Float, y: Float, count: Int, button: String, result: MethodChannel.Result) {
        control.check()
        // Android touch has no right mouse button; a long press opens its
        // context action. Set the click color only when this gesture starts.
        control.update(null, x, y, button)
        control.injecting()
        val path = Path().apply { moveTo(x, y) }
        val duration = if (button == "right") ViewConfiguration.getLongPressTimeout().toLong() + 100L else 40L
        val builder = GestureDescription.Builder()
        builder.addStroke(GestureDescription.StrokeDescription(path, 0, duration))
        val ok = dispatchGesture(builder.build(), object : GestureResultCallback() {
            override fun onCompleted(g: GestureDescription?) = safe("gesture") {
                control.gestureFinished()
                if (count > 1) {
                    WoiBridge.main.postDelayed({ guarded("double tap", result) { r -> tap(x, y, count - 1, button, r) } }, 110)
                } else result.success(true)
            }
            override fun onCancelled(g: GestureDescription?) = safe("gesture") { control.gestureFinished(); control.cancel(); result.error("cancelled", "User took control; gesture cancelled", null) }
        }, null)
        if (!ok) { control.gestureFinished(); result.error("failed", "dispatchGesture refused", null) }
    }

    private fun focused(): AccessibilityNodeInfo? =
        findFocus(AccessibilityNodeInfo.FOCUS_INPUT) ?: rootInActiveWindow?.findFocus(AccessibilityNodeInfo.FOCUS_INPUT)

    private var keyboardBusy = false
    private val keyboardEpoch = WoiKeyboardEpoch()
    private var editorGeneration = 0L

    @android.annotation.TargetApi(33)
    override fun onCreateInputMethod(): android.accessibilityservice.InputMethod =
        object : android.accessibilityservice.InputMethod(this) {
            override fun onStartInput(attribute: android.view.inputmethod.EditorInfo, restarting: Boolean) {
                editorGeneration++
                super.onStartInput(attribute, restarting)
            }
            override fun onFinishInput() {
                editorGeneration++
                super.onFinishInput()
            }
        }

    private data class AppFocus(val packageName: String, val title: String?)
    private interface EditorConnection : WoiKeySink {
        fun current(): Boolean
        fun commitText(text: String)
        fun contextAction(id: Int)
    }
    private data class KeyboardFocus(val app: AppFocus, val editor: EditorConnection?, val requestEpoch: Long)
    private data class KeyboardReceipt(val delivery: String, val backend: String)

    /** A focused application window wins over the last accessibility event:
     * those events can lag behind the assistant panel's focus handoff. */
    private fun foregroundApp(): AppFocus? {
        for (window in windows.sortedByDescending { it.layer }) {
            if (!window.isFocused || window.type != android.view.accessibility.AccessibilityWindowInfo.TYPE_APPLICATION) continue
            val root = window.root ?: continue
            try {
                val pkg = root.packageName?.toString() ?: continue
                if (pkg == packageName || pkg == "com.android.systemui") return null
                return AppFocus(pkg, window.title?.toString())
            } finally { recycle(root) }
        }
        val root = rootInActiveWindow ?: return null
        return try {
            val pkg = root.packageName?.toString()
            if (pkg.isNullOrBlank() || pkg == packageName || pkg == "com.android.systemui") null else AppFocus(pkg, null)
        } finally { recycle(root) }
    }

    private fun focusedIn(pkg: String): AccessibilityNodeInfo? {
        val node = focused() ?: return null
        if (node.packageName?.toString() == pkg && node.isFocused) return node
        recycle(node)
        return null
    }

    /** Captures the real editor connection. It remains pinned for a whole
     * request so a new app/editor cannot receive the remainder of a shortcut. */
    private fun editorFor(app: AppFocus): EditorConnection? {
        if (Build.VERSION.SDK_INT < 33) return null
        val method = inputMethod ?: return null
        val info = method.currentInputEditorInfo ?: return null
        if (!WoiKeyboard.acceptsConnection(packageName, app.packageName, info.packageName, method.currentInputStarted)) return null
        val connection = method.currentInputConnection ?: return null
        val generation = editorGeneration
        val downTimes = mutableMapOf<Int, Long>()
        return object : EditorConnection {
            override fun current(): Boolean = editorGeneration == generation &&
                WoiKeyboard.acceptsConnection(packageName, foregroundApp()?.packageName,
                    method.currentInputEditorInfo?.packageName, method.currentInputStarted)
            override fun commitText(text: String) { connection.commitText(text, 1, null) }
            override fun contextAction(id: Int) { connection.performContextMenuAction(id) }
            override fun clearMetaKeyStates(states: Int) { connection.clearMetaKeyStates(states) }
            override fun send(stroke: WoiKeyStroke) {
                val now = android.os.SystemClock.uptimeMillis()
                val downTime = if (stroke.action == android.view.KeyEvent.ACTION_DOWN) {
                    downTimes[stroke.keyCode] = now
                    now
                } else downTimes.remove(stroke.keyCode) ?: now
                connection.sendKeyEvent(android.view.KeyEvent(
                    downTime, now, stroke.action, stroke.keyCode,
                    0, stroke.metaState, android.view.KeyCharacterMap.VIRTUAL_KEYBOARD, 0,
                    android.view.KeyEvent.FLAG_SOFT_KEYBOARD or android.view.KeyEvent.FLAG_KEEP_TOUCH_MODE,
                    android.view.InputDevice.SOURCE_KEYBOARD,
                ))
            }
        }
    }

    /** Exactly one request owns the focus handoff. Every completion restores
     * the assistant panel; input is never replayed after a failed dispatch. */
    private fun keyboardAside(result: MethodChannel.Result, settleMs: Long = 150, block: (Long, MethodChannel.Result) -> Unit) {
        if (keyboardBusy) return result.error("keyboard_busy", "Another keyboard request is still completing", null)
        val requestEpoch = keyboardEpoch.capture()
        keyboardBusy = true
        val once = object : MethodChannel.Result {
            private var done = false
            private fun finish(answer: () -> Unit) {
                if (done) return
                done = true
                keyboardBusy = false
                answer()
            }
            override fun success(value: Any?) = finish { result.success(value) }
            override fun error(code: String, message: String?, details: Any?) = finish { result.error(code, message, details) }
            override fun notImplemented() = finish { result.notImplemented() }
        }
        try {
            aside(settleMs, once) { r ->
                try {
                    keyboardEpoch.check(requestEpoch)
                    block(requestEpoch, r)
                } catch (error: Throwable) {
                    r.error("keyboard_cancelled", error.message ?: "Keyboard request stopped", mapOf("completed" to 0, "retry_safe" to false))
                }
            }
        } catch (error: Throwable) {
            once.error("failed", error.message ?: "Keyboard focus handoff failed", null)
        }
    }

    /** Retry readiness only. Nothing has been sent during this wait. On 13+
     * prefer the editor connection; a legacy node fallback is considered only
     * after giving the editor time to reconnect when the panel steps aside. */
    private fun awaitKeyboardFocus(
        requiresConnection: Boolean, requested: String?, requestEpoch: Long, result: MethodChannel.Result,
        start: Long = android.os.SystemClock.uptimeMillis(), block: (KeyboardFocus) -> Unit,
    ) {
        try {
            keyboardEpoch.check(requestEpoch)
            check(instance === this) { "Accessibility service disconnected before keyboard input" }
            control.check()
            val app = foregroundApp()
            val elapsed = android.os.SystemClock.uptimeMillis() - start
            if (app != null && WoiKeyboard.matchesTarget(requested, app.packageName, app.title)) {
                val editor = editorFor(app)
                if (editor != null) return block(KeyboardFocus(app, editor, requestEpoch))
                if (!requiresConnection && (Build.VERSION.SDK_INT < 33 || elapsed >= 1000)) {
                    val node = focusedIn(app.packageName)
                    if (node != null) {
                        recycle(node)
                        return block(KeyboardFocus(app, null, requestEpoch))
                    }
                }
            }
            if (elapsed >= 1200) {
                val reason = if (!requested.isNullOrBlank() && (app == null || !WoiKeyboard.matchesTarget(requested, app.packageName, app.title))) {
                    "The requested Android target '$requested' is not focused; focus that app first"
                } else if (requiresConnection) {
                    "No active input connection in the focused app. Focus its editor first; Android cannot inject arbitrary global shortcuts"
                } else {
                    "No focused editor in the app beneath Woi. Focus a text field and try again"
                }
                return result.error("no_input_target", reason, null)
            }
            WoiBridge.main.postDelayed({ awaitKeyboardFocus(requiresConnection, requested, requestEpoch, result, start, block) }, 50)
        } catch (error: Throwable) {
            result.error("keyboard_cancelled", error.message ?: "Keyboard request stopped", null)
        }
    }

    private fun checkKeyboardFocus(focus: KeyboardFocus) {
        keyboardEpoch.check(focus.requestEpoch)
        check(instance === this) { "Accessibility service disconnected" }
        control.check()
        check(foregroundApp()?.packageName == focus.app.packageName) { "The focused app changed; keyboard input stopped" }
        check(focus.editor == null || focus.editor.current()) { "The focused editor changed; keyboard input stopped" }
    }

    private fun typeText(text: String, focus: KeyboardFocus): String {
        checkKeyboardFocus(focus)
        focus.editor?.let {
            it.commitText(text)
            // The public accessibility IME API is asynchronous and returns
            // void. This means dispatched, not proof the application edited.
            return "ime_dispatched"
        }
        val node = focusedIn(focus.app.packageName) ?: throw IllegalStateException("No focused text field")
        try {
            check(node.isEditable) { "The focused view is not editable" }
            check(!node.isPassword) { "Password fields require a live input connection; text cannot be safely reconstructed" }
            val hint = Build.VERSION.SDK_INT >= 26 && node.isShowingHintText
            val current = if (hint) "" else node.text?.toString().orEmpty()
            val start = if (current.isEmpty() && node.textSelectionStart < 0) 0 else node.textSelectionStart
            val end = if (current.isEmpty() && node.textSelectionEnd < 0) 0 else node.textSelectionEnd
            val (next, caret) = WoiKeyboard.insertText(current, start, end, text)
            check(node.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, Bundle().apply {
                putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, next)
            })) { "The focused field refused text insertion; a live Android 13+ input connection is required for this editor" }
            node.performAction(AccessibilityNodeInfo.ACTION_SET_SELECTION, Bundle().apply {
                putInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_START_INT, caret)
                putInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_END_INT, caret)
            })
            return "set_text"
        } finally { recycle(node) }
    }

    private fun edit(name: String, focus: KeyboardFocus): KeyboardReceipt {
        checkKeyboardFocus(focus)
        val editor = focus.editor
        val contextAction = when (name) {
            "copy" -> android.R.id.copy
            "paste" -> android.R.id.paste
            "cut" -> android.R.id.cut
            "select_all" -> android.R.id.selectAll
            else -> null
        }
        if (editor != null && contextAction != null) {
            editor.contextAction(contextAction)
            return KeyboardReceipt("dispatched", "android_accessibility_input_connection")
        }
        val node = focusedIn(focus.app.packageName)
        try {
            val handled = when (name) {
                "copy" -> node?.performAction(AccessibilityNodeInfo.ACTION_COPY) == true
                "paste" -> node?.performAction(AccessibilityNodeInfo.ACTION_PASTE) == true
                "cut" -> node?.performAction(AccessibilityNodeInfo.ACTION_CUT) == true
                "select_all" -> node?.let {
                    val length = if (Build.VERSION.SDK_INT >= 26 && it.isShowingHintText) 0 else it.text?.length ?: 0
                    it.performAction(AccessibilityNodeInfo.ACTION_SET_SELECTION, Bundle().apply {
                        putInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_START_INT, 0)
                        putInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_END_INT, length)
                    })
                } == true
                "enter" -> Build.VERSION.SDK_INT >= 30 && node?.performAction(AccessibilityNodeInfo.AccessibilityAction.ACTION_IME_ENTER.id) == true
                "clear_selection" -> node?.performAction(AccessibilityNodeInfo.ACTION_CLEAR_SELECTION) == true
                else -> throw IllegalArgumentException("unknown edit action $name")
            }
            if (handled) return KeyboardReceipt("applied", "android_accessibility_action")
        } finally { recycle(node) }
        if (name == "enter" && editor != null) {
            WoiKeyboard.dispatch(WoiKeyOperation.Chord("enter", emptySet()), editor) { checkKeyboardFocus(focus) }
            return KeyboardReceipt("dispatched", "android_accessibility_input_connection")
        }
        throw IllegalStateException("$name is not available in the focused field")
    }

    private fun sendKeys(operations: List<WoiKeyOperation>, requested: String?, result: MethodChannel.Result) {
        if (operations.all { it is WoiKeyOperation.Global }) {
            require(requested.isNullOrBlank()) { "Android system navigation cannot target a named application" }
            return keyboardAside(result, 450) { requestEpoch, r ->
                var completed = 0
                fun next() {
                    try {
                        keyboardEpoch.check(requestEpoch)
                        val operation = operations[completed] as WoiKeyOperation.Global
                        check(global(operation.name)) { "${operation.name} was refused" }
                        completed++
                        if (completed < operations.size) WoiBridge.main.postDelayed(::next, 350)
                        else r.success(mapOf("completed" to completed, "delivery" to "applied", "backend" to "android_accessibility_global"))
                    } catch (error: Throwable) {
                        r.error("input_stopped", "Keyboard request stopped after $completed/${operations.size} operations: ${error.message}",
                            mapOf("completed" to completed, "retry_safe" to false))
                    }
                }
                next()
            }
        }
        val requiresConnection = operations.any { it is WoiKeyOperation.Chord }
        keyboardAside(result) { requestEpoch, r ->
            awaitKeyboardFocus(requiresConnection, requested, requestEpoch, r) { focus ->
                var completed = 0
                val receipts = mutableListOf<KeyboardReceipt>()
                fun next() {
                    try {
                        checkKeyboardFocus(focus)
                        val receipt = when (val operation = operations[completed]) {
                            is WoiKeyOperation.Chord -> {
                                val editor = checkNotNull(focus.editor) { "No live editor input connection" }
                                WoiKeyboard.dispatch(operation, editor) { checkKeyboardFocus(focus) }
                                KeyboardReceipt("dispatched", "android_accessibility_input_connection")
                            }
                            is WoiKeyOperation.Edit -> edit(operation.name, focus)
                            is WoiKeyOperation.Global -> error("System navigation cannot be mixed with editor keys")
                        }
                        receipts.add(receipt)
                        completed++
                        if (completed < operations.size) WoiBridge.main.postDelayed(::next, 40)
                        else r.success(mapOf(
                            "completed" to completed, "package" to focus.app.packageName,
                            "delivery" to if (receipts.any { it.delivery == "dispatched" }) "dispatched" else "applied",
                            "backend" to receipts.map { it.backend }.distinct().joinToString("+"),
                        ))
                    } catch (error: Throwable) {
                        r.error("input_stopped", "Keyboard request stopped after $completed/${operations.size} operations; input may already have been sent: ${error.message}",
                            mapOf("completed" to completed, "retry_safe" to false))
                    }
                }
                next()
            }
        }
    }

    private fun global(name: String): Boolean {
        control.check()
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

        /** Stop must not queue behind a batch or re-enable an unbound service. */
        fun cancelKeyboard(): Boolean {
            val service = instance ?: return false
            service.keyboardEpoch.cancel()
            return true
        }

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
                "controlBegin" -> s.leaveWoi(100) { guarded("control begin", result) { r ->
                    r.success(s.control.begin(call.argument<String>("kind") ?: "pointer",
                        call.argument<String>("keys") ?: "",
                        call.argument<Number>("x")?.toFloat(), call.argument<Number>("y")?.toFloat()))
                } }
                "controlInterrupted" -> result.success(s.control.cancelled)
                "controlUpdate" -> { s.control.update(call.argument<String>("keys"), call.argument<Number>("x")?.toFloat(), call.argument<Number>("y")?.toFloat(), call.argument<String>("button")); result.success(null) }
                "controlEnd" -> { s.control.end(); result.success(null) }
                "controlReset" -> { s.control.reset(); result.success(null) }
                "click", "doubleClick" -> {
                    val button = call.argument<String>("button") ?: "left"
                    if (button !in listOf("left", "right") || (call.method == "doubleClick" && button != "left")) {
                        result.error("unsupported_button", "Android supports a left tap/double tap or a right long press", null)
                        return
                    }
                    val x = (call.argument<Number>("x") ?: 0).toFloat()
                    val y = (call.argument<Number>("y") ?: 0).toFloat()
                    s.aside(350, result) { r -> s.tap(x, y, if (call.method == "doubleClick") 2 else 1, button, r) }
                }
                "typeText" -> {
                    val text = call.argument<String>("text") ?: ""
                    if (text.length > 100000) return result.error("invalid_text", "Text insertion is limited to 100000 UTF-16 units per request", null)
                    if (text.isEmpty()) return result.success("empty")
                    s.keyboardAside(result) { requestEpoch, r ->
                        s.awaitKeyboardFocus(false, null, requestEpoch, r) { focus ->
                            try { r.success(s.typeText(text, focus)) } catch (error: Throwable) {
                                r.error("input_stopped", "Text insertion stopped; do not retry automatically: ${error.message}", mapOf("retry_safe" to false))
                            }
                        }
                    }
                }
                "sendKeys" -> {
                    val operations = try {
                        WoiKeyboard.parse(call.argument<Any>("operations")).also { WoiKeyboard.validateSdk(it, Build.VERSION.SDK_INT) }
                    } catch (error: IllegalArgumentException) {
                        return result.error("unsupported_keys", error.message, null)
                    }
                    s.sendKeys(operations, call.argument<String>("target"), result)
                }
                "global" -> {
                    val name = call.argument<String>("name") ?: ""
                    // Global keys sent while the task-switch animation still
                    // runs can be dropped: let it finish first.
                    s.aside(450, result) { r -> r.success(s.global(name)) }
                }
                "node" -> {
                    val operations = try { WoiKeyboard.parse(listOf(mapOf("type" to "edit", "name" to call.argument<String>("name")))) }
                    catch (error: IllegalArgumentException) { return result.error("unsupported_keys", error.message, null) }
                    s.sendKeys(operations, null, result)
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
