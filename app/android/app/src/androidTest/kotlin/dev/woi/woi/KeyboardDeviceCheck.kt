package dev.woi.woi

import android.accessibilityservice.AccessibilityServiceInfo
import android.app.Activity
import android.app.Instrumentation
import android.app.UiAutomation
import android.content.ComponentName
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.os.SystemClock
import android.provider.Settings
import android.view.accessibility.AccessibilityNodeInfo
import android.view.accessibility.AccessibilityWindowInfo
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/** Prepared for an isolated Android 13+ emulator/test device only. Starting the
 * app's instrumentation restarts its target process, so do not run this against
 * the user's active Woi session. It rebinds only the already-enabled service
 * after instrumentation restarts Woi; it never grants permissions, changes the
 * selected IME/assistant, or starts Flutter/audio. The copy tests use fixture
 * clipboard content. The complete pre-test clip is preserved and restored only
 * inside the fixture app on the device; it never leaves that process as data. */
class KeyboardDeviceCheck(private val host: Instrumentation) {
    private lateinit var ui: UiAutomation
    private val testPackage get() = host.context.packageName
    private data class Reply(val value: Any?, val code: String? = null, val message: String? = null)
    private data class CapturedConnection(
        val connection: android.accessibilityservice.InputMethod.AccessibilityInputConnection?,
        val info: android.view.inputmethod.EditorInfo?,
    ) {
        fun metadata() = "field=${info?.fieldId},fixture_connection=${info?.extras?.getInt("woi_fixture_connection", -1)},initial_selection=${info?.initialSelStart}..${info?.initialSelEnd}"
    }
    private var lastKeyConnection: CapturedConnection? = null

    /** Called on the instrumentation thread, never the service/main thread.
     * Captures only a known fixture connection; reports equality/offsets, not text. */
    private fun diagnoseConnection(log: StringBuilder) {
        fun probe(captured: CapturedConnection?): String {
            if (captured == null || captured.info?.packageName != testPackage) return "not_fixture"
            val began = SystemClock.elapsedRealtime()
            val surrounding = captured.connection?.getSurroundingText(64, 64, 0)
            val classification = when (surrounding?.text?.toString()) {
                null -> "unavailable"
                "copy sample" -> "primary_copy"
                "copy samplecopy sample" -> "primary_copied"
                "cut sample" -> "primary_cut"
                "" -> "empty"
                "secondary fixture" -> "secondary"
                else -> "other_redacted"
            }
            return "result=$classification,offset=${surrounding?.offset},selection=${surrounding?.selectionStart}..${surrounding?.selectionEnd},ms=${SystemClock.elapsedRealtime() - began}"
        }
        val captured = lastKeyConnection
        var current: CapturedConnection? = null
        host.runOnMainSync {
            val method = WoiAccessibilityService.instance?.inputMethod
            current = CapturedConnection(method?.currentInputConnection, method?.currentInputEditorInfo)
        }
        log.append("DETAIL dispatch_connection ${captured?.metadata()} ${probe(captured)}\n")
        log.append("DETAIL current_connection ${current?.metadata()} same_editor_info=${captured?.info === current?.info} ${probe(current)}\n")
        log.append("DETAIL primary_lifecycle=${required("woi-keyboard-primary-connection").text} secondary_lifecycle=${required("woi-keyboard-secondary-connection").text} secondary_unchanged=${secondaryText() == "secondary fixture"} secondary_focus=${required("woi-keyboard-secondary-input").isFocused}\n")
    }

    /** The fixture owns its View and can prepare a fresh public input connection
     * after ACTION_SET_TEXT. Android's cross-app accessibility API cannot repair
     * a foreign invalidated session ID. This is test setup, never a key retry. */
    private fun prepareExactConnection(log: StringBuilder) {
        fun capture(): CapturedConnection {
            var captured: CapturedConnection? = null
            host.runOnMainSync {
                val method = WoiAccessibilityService.instance?.inputMethod
                captured = CapturedConnection(method?.currentInputConnection, method?.currentInputEditorInfo)
            }
            return checkNotNull(captured)
        }
        fun ready(captured: CapturedConnection): Boolean {
            if (captured.info?.packageName != testPackage || captured.info.fieldId != KeyboardTestActivity.PRIMARY_EDITOR_ID) return false
            val surrounding = captured.connection?.getSurroundingText(0, 0, 0) ?: return false
            val input = required("woi-keyboard-input")
            input.refresh()
            return surrounding.offset + surrounding.selectionStart == input.textSelectionStart &&
                surrounding.offset + surrounding.selectionEnd == input.textSelectionEnd
        }
        val started = SystemClock.elapsedRealtime()
        val before = capture()
        val initiallyReady = ready(before)
        val probeMs = SystemClock.elapsedRealtime() - started
        if (initiallyReady) {
            log.append("DETAIL exact-key fixture connection ready probe_ms=$probeMs\n")
            return
        }
        check(required("woi-keyboard-restart-input").performAction(AccessibilityNodeInfo.ACTION_CLICK))
        var after: CapturedConnection? = null
        waitFor("fixture-owned fresh input connection") {
            val current = capture()
            ready(current).also { if (it) after = current }
        }
        check(required("woi-keyboard-input").isFocused && !required("woi-keyboard-secondary-input").isFocused)
        log.append("DETAIL exact-key fixture connection prepared_by_editor=true probe_ms=$probeMs total_ms=${SystemClock.elapsedRealtime() - started} previous=${before.metadata()} fresh=${after?.metadata()}\n")
    }

    private fun native(method: String, args: Map<String, Any?> = emptyMap(), cancelClipboard: Boolean = false): Reply {
        check(WoiAccessibilityService.instance != null) { "Accessibility must already be enabled and bound; this fixture never enables it" }
        val done = CountDownLatch(1)
        var reply = Reply(null, "timeout")
        host.runOnMainSync {
            try {
                val result = object : MethodChannel.Result {
                    override fun success(result: Any?) { reply = Reply(result); done.countDown() }
                    override fun error(code: String, message: String?, details: Any?) { reply = Reply(details, code, message); done.countDown() }
                    override fun notImplemented() { reply = Reply(null, "not_implemented"); done.countDown() }
                }
                val call = MethodCall(method, args)
                if (method == "sendKeys" && (args["operations"] as? List<*>)?.any { (it as? Map<*, *>)?.get("type") == "key" } == true) {
                    val inputMethod = WoiAccessibilityService.instance?.inputMethod
                    lastKeyConnection = CapturedConnection(inputMethod?.currentInputConnection, inputMethod?.currentInputEditorInfo)
                }
                if (method == "readClipboard" || method == "writeClipboard") WoiClipboard.handle(call, result)
                else WoiAccessibilityService.handle(call, result)
                if (cancelClipboard) {
                    WoiClipboard.cancelPending()
                    WoiClipboard.cancelPending()
                }
            } catch (error: Throwable) { reply = Reply(null, "exception", error.toString()); done.countDown() }
        }
        check(done.await(6, TimeUnit.SECONDS)) { "$method did not complete" }
        return reply
    }

    private fun ok(method: String, args: Map<String, Any?> = emptyMap()): Any? {
        val result = native(method, args)
        check(result.code == null) { "$method: ${result.code}: ${result.message}" }
        return result.value
    }

    private fun waitFor(label: String, timeoutMs: Long = 5000, condition: () -> Boolean) {
        val until = SystemClock.elapsedRealtime() + timeoutMs
        while (!condition()) {
            check(SystemClock.elapsedRealtime() < until) { "Timed out: $label" }
            SystemClock.sleep(40)
        }
    }

    private fun node(description: String): AccessibilityNodeInfo? {
        fun find(parent: AccessibilityNodeInfo): AccessibilityNodeInfo? {
            if (parent.contentDescription?.toString() == description) return parent
            for (index in 0 until parent.childCount) {
                val child = parent.getChild(index) ?: continue
                val found = find(child)
                if (found != null) return found
            }
            return null
        }
        for (window in ui.windows) {
            val root = window.root ?: continue
            if (root.packageName?.toString() == testPackage) find(root)?.let { return it }
        }
        return null
    }

    private fun required(description: String) = checkNotNull(node(description)) { "Fixture not visible: $description" }
    private fun text() = required("woi-keyboard-input").text?.toString().orEmpty()
    private fun secondaryText() = required("woi-keyboard-secondary-input").text?.toString().orEmpty()
    private fun events() = required("woi-keyboard-events").text.toString().toInt()
    private fun select(start: Int, end: Int) {
        fun selected(): Boolean {
            val input = required("woi-keyboard-input")
            input.refresh()
            return input.textSelectionStart == start && input.textSelectionEnd == end
        }
        // TextView reports false for ACTION_SET_SELECTION when the caret is
        // already at the requested position (as after ACTION_SET_TEXT).
        if (selected()) return
        val changed = required("woi-keyboard-input").performAction(AccessibilityNodeInfo.ACTION_SET_SELECTION, Bundle().apply {
            putInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_START_INT, start)
            putInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_END_INT, end)
        })
        check(changed || selected()) { "Fixture editor refused selection $start..$end" }
        waitFor("fixture selection") { selected() }
    }
    private fun prepare(value: String) {
        waitFor("fixture Activity window focus") { node("woi-keyboard-window-focus")?.text?.toString() == "focused" }
        val input = required("woi-keyboard-input")
        if (!input.isFocused) check(input.performAction(AccessibilityNodeInfo.ACTION_FOCUS))
        check(input.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, Bundle().apply {
            putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, value)
        }))
        waitFor("fixture text") { text() == value }
        select(value.length, value.length)
    }
    private fun inputState(): String {
        var state = "service_absent"
        host.runOnMainSync {
            val service = WoiAccessibilityService.instance
            if (service != null) {
                val method = service.inputMethod
                state = "started=${method?.currentInputStarted},connection=${method?.currentInputConnection != null},editor_matches=${method?.currentInputEditorInfo?.packageName == testPackage}"
            }
        }
        val input = required("woi-keyboard-input")
        input.refresh()
        return "$state,window_focus=${node("woi-keyboard-window-focus")?.text},selection=${input.textSelectionStart}..${input.textSelectionEnd}"
    }

    private fun shortcutCounts() = required("woi-keyboard-shortcut-counts").text.toString()
    private fun shortcutCount(name: String): Int = shortcutCounts().split(' ')
        .firstOrNull { it.startsWith("$name=") }?.substringAfter('=')?.toIntOrNull()
        ?: error("Fixture did not expose the $name key acknowledgement")

    private fun armClipboardCheck(expected: String) {
        check(text() == expected) { "Clipboard probe must be armed from the known synthetic field" }
        check(required("woi-keyboard-clipboard-arm").performAction(AccessibilityNodeInfo.ACTION_CLICK))
        waitFor("local clipboard probe armed") { required("woi-keyboard-clipboard-state").text?.toString() == "pending" }
    }

    private fun waitForCopiedText(label: String) {
        waitFor(label) {
            check(required("woi-keyboard-clipboard-probe").performAction(AccessibilityNodeInfo.ACTION_CLICK))
            required("woi-keyboard-clipboard-state").text?.toString() == "matched"
        }
    }

    private fun key(name: String, vararg modifiers: String): Map<String, Any> =
        mapOf("type" to "key", "key" to name, "modifiers" to modifiers.toList())
    private fun send(vararg keys: Map<String, Any>): Map<*, *> =
        ok("sendKeys", mapOf("operations" to keys.toList(), "target" to testPackage)) as Map<*, *>

    private fun rebindAlreadyEnabledService(): Boolean {
        if (WoiAccessibilityService.instance != null) return false
        val resolver = host.targetContext.contentResolver
        val key = Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES
        val original = Settings.Secure.getString(resolver, key).orEmpty()
        val component = ComponentName(host.targetContext, WoiAccessibilityService::class.java)
        val entries = original.split(':')
        check(entries.any { ComponentName.unflattenFromString(it.trim()) == component }) {
            "Woi accessibility must already be enabled before this device test"
        }
        // am instrument force-stops Woi. Android marks its otherwise enabled
        // accessibility service crashed. Rebind this existing entry only and
        // restore the complete original list even when the lifecycle fails.
        try {
            check(Settings.Secure.putString(resolver, key,
                entries.filter { ComponentName.unflattenFromString(it.trim()) != component }.joinToString(":")))
            SystemClock.sleep(250)
        } finally {
            check(Settings.Secure.putString(resolver, key, original))
        }
        return true
    }

    private fun clipboardSnapshot(action: String, id: String) {
        host.context.startActivity(Intent().apply {
            component = ComponentName(testPackage, ClipboardSnapshotActivity::class.java.name)
            putExtra("request", id)
            putExtra("action", action)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        })
        if (action == "close") return
        val expected = if (action == "save") "saved" else "restored"
        waitFor("clipboard $action") {
            val state = node("woi-clipboard-snapshot-$id")?.text?.toString()
            check(state?.startsWith("error:") != true) { "Local clipboard $action failed ($state)" }
            state == expected
        }
    }

    fun run() {
        val log = StringBuilder()
        var passed = 0
        var failure: Throwable? = null
        val clipboardId = java.util.UUID.randomUUID().toString()
        var clipboardProtected = false
        var clipboardSnapshotAttempted = false
        var clipboardRestored = false
        var keyboardShowMode: Int? = null
        fun verify(name: String, block: () -> Unit) {
            try { block() }
            catch (error: Throwable) { throw IllegalStateException("Keyboard fixture [$name]: ${error.message}", error) }
            passed++
            log.append("PASS $name\n")
        }
        try {
            host.runOnMainSync { WoiBridge.ensureContext(host.targetContext) }
            check(Build.VERSION.SDK_INT >= 33) { "This exact-key fixture requires Android 13+" }
            ui = host.getUiAutomation(UiAutomation.FLAG_DONT_SUPPRESS_ACCESSIBILITY_SERVICES)
            ui.serviceInfo = ui.serviceInfo.apply { flags = flags or AccessibilityServiceInfo.FLAG_RETRIEVE_INTERACTIVE_WINDOWS }
            check(!WoiOverlay.showing) { "Dismiss the assistant before this isolated fixture; it will not alter a live assistant session" }
            if (rebindAlreadyEnabledService()) log.append("SETUP Rebound the existing accessibility service after instrumentation restart.\n")
            waitFor("pre-enabled accessibility service binding", 15000) { WoiAccessibilityService.instance != null }
            host.runOnMainSync { keyboardShowMode = WoiAccessibilityService.instance!!.softKeyboardController.showMode }
            clipboardSnapshotAttempted = true
            clipboardSnapshot("save", clipboardId)
            clipboardProtected = true
            host.context.startActivity(Intent().apply {
                component = ComponentName(testPackage, KeyboardTestActivity::class.java.name)
                // A prior failed run may leave this task in the node-only mode.
                // Recreate only the keyboard fixture task, never the clipboard snapshot task.
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK)
            })
            waitFor("fresh normal fixture activity") {
                node("woi-keyboard-input") != null && node("woi-keyboard-mode")?.text?.toString() == "normal"
            }
            ok("controlReset")
            verify("literal Unicode insertion through the background accessibility service") {
                prepare("prefix OLD suffix"); select(7, 10)
                check(ok("typeText", mapOf("text" to "雪🙂 + literal\nline")) == "set_text") { "Readable editable nodes should use acknowledged insertion" }
                waitFor("literal text insertion") { text() == "prefix 雪🙂 + literal\nline suffix" }
            }
            verify("hidden soft keyboard does not block Unicode typing") {
                check(required("woi-keyboard-hide").performAction(AccessibilityNodeInfo.ACTION_CLICK))
                waitFor("keyboard hidden") { ui.windows.none { it.type == AccessibilityWindowInfo.TYPE_INPUT_METHOD } }
                prepare("left OLD right"); select(5, 8)
                check(ok("typeText", mapOf("text" to "键盘🙂")) in setOf("ime_dispatched", "set_text"))
                waitFor("hidden keyboard insertion") { text() == "left 键盘🙂 right" }
            }
            verify("explicit background clipboard write and visible read return synthetic Unicode") {
                val value = "WOI synthetic clipboard 雪🙂\nsecond line"
                prepare("paste:")
                val before = inputState()
                check(ok("writeClipboard", mapOf("text" to value)) == true)
                val read = ok("readClipboard") as Map<*, *>
                check(read["available"] == true && read["text"] == value)
                // Paste immediately after read returns: no fixture focus
                // wait or setText/restartInput between the native operations.
                val receipt = send(mapOf("type" to "edit", "name" to "paste"))
                check(receipt["delivery"] == "applied" && receipt["backend"] == "android_accessibility_action") { "Advertised semantic paste should use the acknowledged node action" }
                try { waitFor("semantic paste") { text() == "paste:" + value } }
                catch (error: Throwable) {
                    val actual = text()
                    val classification = when (actual) {
                        "paste:" -> "unchanged"
                        value -> "replaced_entire_field"
                        value + "paste:" -> "inserted_before_prefix"
                        "paste:" + value -> "expected"
                        else -> "other_redacted"
                    }
                    log.append("DETAIL paste before=$before receipt=$receipt after=${inputState()} actual=$classification\n")
                    if (actual == "paste:") {
                        val nodePaste = required("woi-keyboard-input").performAction(AccessibilityNodeInfo.ACTION_PASTE)
                        SystemClock.sleep(160)
                        log.append("DETAIL direct node paste accepted=$nodePaste expected_text=${text() == "paste:" + value}\n")
                    }
                    val current = ok("readClipboard") as Map<*, *>
                    log.append("DETAIL clipboard still_matches_synthetic=${current["text"] == value}\n")
                    throw error
                }
            }
            verify("Stop cancels an in-flight clipboard read and its deferred window") {
                check(ok("writeClipboard", mapOf("text" to "WOI cancelled clipboard fixture")) == true)
                val reply = native("readClipboard", cancelClipboard = true)
                check(reply.code == "clipboard_cancelled")
                waitFor("cancelled clipboard window released") { required("woi-keyboard-input").isFocused }
            }
            verify("empty text remains available but an empty or nontext clipboard does not") {
                check(ok("writeClipboard", mapOf("text" to "")) == true)
                val emptyText = ok("readClipboard") as Map<*, *>
                check(emptyText["available"] == true && emptyText["text"] == "")
                host.runOnMainSync {
                    (host.targetContext.getSystemService(android.content.Context.CLIPBOARD_SERVICE) as android.content.ClipboardManager)
                        .clearPrimaryClip()
                }
                val empty = ok("readClipboard") as Map<*, *>
                check(empty["available"] == false && empty["text"] == null)
                host.runOnMainSync {
                    (host.targetContext.getSystemService(android.content.Context.CLIPBOARD_SERVICE) as android.content.ClipboardManager)
                        .setPrimaryClip(android.content.ClipData.newIntent("Woi synthetic nontext", Intent("dev.woi.test.SYNTHETIC")))
                }
                val nontext = ok("readClipboard") as Map<*, *>
                check(nontext["available"] == false && nontext["text"] == null)
            }
            verify("Ctrl+A/C/V uses editor shortcuts and preserves exact text") {
                prepare("copy sample")
                armClipboardCheck("copy sample")
                prepareExactConnection(log)
                val beforeSelected = shortcutCount("selected")
                val beforeCopy = shortcutCount("c")
                val beforePaste = shortcutCount("v")
                try {
                    check(send(key("a", "ctrl"), key("c", "ctrl"))["delivery"] == "dispatched")
                    waitFor("Ctrl+A selected the fixture text") { shortcutCount("selected") > beforeSelected }
                    waitFor("Ctrl+C reached the editor") { shortcutCount("c") > beforeCopy }
                    // Do not clear the selection until the receiving app has
                    // actually copied it. The native receipt means dispatched.
                    waitForCopiedText("Ctrl+C copied synthetic text locally")
                    select(text().length, text().length)
                    send(key("v", "ctrl"))
                    waitFor("Ctrl+V reached the editor") { shortcutCount("v") > beforePaste }
                    waitFor("paste after copy") { text() == "copy samplecopy sample" }
                } catch (error: Throwable) {
                    log.append("DETAIL copy keys=${shortcutCounts()} clipboard_flag=${required("woi-keyboard-clipboard-state").text} input=${inputState()} unchanged=${text() == "copy sample"} expected=${text() == "copy samplecopy sample"}\n")
                    diagnoseConnection(log)
                    throw error
                }
            }
            verify("Ctrl+X cuts the selection and Ctrl+V restores it") {
                prepare("cut sample")
                armClipboardCheck("cut sample")
                prepareExactConnection(log)
                val beforeCut = shortcutCount("x")
                val beforePaste = shortcutCount("v")
                try {
                    send(key("a", "ctrl"), key("x", "ctrl"))
                    waitFor("Ctrl+X reached the editor") { shortcutCount("x") > beforeCut }
                    waitFor("cut") { text().isEmpty() }
                    waitForCopiedText("Ctrl+X copied synthetic text locally")
                    send(key("v", "ctrl"))
                    waitFor("Ctrl+V after cut reached the editor") { shortcutCount("v") > beforePaste }
                    waitFor("paste after cut") { text() == "cut sample" }
                } catch (error: Throwable) {
                    log.append("DETAIL cut keys=${shortcutCounts()} clipboard_flag=${required("woi-keyboard-clipboard-state").text} input=${inputState()} empty=${text().isEmpty()} restored=${text() == "cut sample"}\n")
                    diagnoseConnection(log)
                    throw error
                }
            }
            verify("Ctrl+Alt+Shift arrives together on the actual key") {
                val before = required("woi-keyboard-chord").text.toString().toInt()
                send(key("k", "ctrl", "shift", "alt"))
                waitFor("combined chord") { required("woi-keyboard-chord").text.toString().toInt() == before + 1 }
            }
            verify("unsupported later key emits no earlier key") {
                prepare("atomic validation")
                val before = events()
                val reply = native("sendKeys", mapOf("operations" to listOf(key("a", "ctrl"), key("f24"))))
                check(reply.code == "unsupported_keys")
                SystemClock.sleep(100)
                check(events() == before && required("woi-keyboard-input").textSelectionStart == text().length)
            }
            verify("target mismatch fails without input") {
                val before = events()
                val reply = native("sendKeys", mapOf("operations" to listOf(key("a", "ctrl")), "target" to "dev.woi.nonexistent.target"))
                check(reply.code == "no_input_target")
                check(events() == before)
            }
            host.context.startActivity(Intent().apply {
                component = ComponentName(testPackage, KeyboardTestActivity::class.java.name)
                putExtra("no_input_connection", true)
                putExtra("hide_keyboard", true)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK)
            })
            waitFor("no-connection fixture") { node("woi-keyboard-mode")?.text?.toString() == "no-input-connection" }
            verify("node-only typing inserts at the caret without waiting for an IME") {
                prepare("left OLD right"); select(5, 8)
                val started = SystemClock.elapsedRealtime()
                check(ok("typeText", mapOf("text" to "无键盘🙂")) == "set_text")
                check(SystemClock.elapsedRealtime() - started < 900) { "Node fallback still waited for an absent IME" }
                waitFor("node text insertion") { text() == "left 无键盘🙂 right" }
            }
            verify("an explicitly accessibility-selected editor can be typed without input focus") {
                prepare("selected OLD text")
                check(secondaryText() == "secondary fixture") { "Secondary fixture text was changed before targeting" }
                check(required("woi-keyboard-leave-editor").performAction(AccessibilityNodeInfo.ACTION_CLICK))
                waitFor("editor input focus cleared") { !required("woi-keyboard-input").isFocused }
                val manager = host.targetContext.getSystemService(android.content.Context.ACCESSIBILITY_SERVICE) as android.view.accessibility.AccessibilityManager
                val originalFlags = ui.serviceInfo.flags
                val originalTouchExploration = manager.isTouchExplorationEnabled
                log.append("DETAIL accessibility-focus setup touch_exploration=$originalTouchExploration\n")
                try {
                    if (!originalTouchExploration) {
                        ui.serviceInfo = ui.serviceInfo.apply {
                            flags = flags or AccessibilityServiceInfo.FLAG_REQUEST_TOUCH_EXPLORATION_MODE
                        }
                        waitFor("temporary test touch exploration") { manager.isTouchExplorationEnabled }
                    }
                    val editor = required("woi-keyboard-secondary-input")
                    val selected = editor.performAction(AccessibilityNodeInfo.ACTION_ACCESSIBILITY_FOCUS)
                    editor.refresh()
                    check(selected || editor.isAccessibilityFocused) { "Fixture could not establish accessibility focus" }
                    waitFor("explicit accessibility focus") { required("woi-keyboard-secondary-input").isAccessibilityFocused }
                    editor.refresh()
                    log.append("DETAIL accessibility target before selection=${editor.textSelectionStart}..${editor.textSelectionEnd} input_focus=${editor.isFocused} a11y_focus=${editor.isAccessibilityFocused} primary_unchanged=${text() == "selected OLD text"} secondary_unchanged=${secondaryText() == "secondary fixture"}\n")
                    // Focus transitions may collapse an old selection. Verify
                    // the actual current caret before deciding the insertion.
                    check(!editor.isFocused && !required("woi-keyboard-input").isFocused) { "Fixture unexpectedly has an input-focused editor" }
                    check(editor.textSelectionStart == "secondary fixture".length && editor.textSelectionEnd == "secondary fixture".length) {
                        "Accessibility target did not expose its current end caret"
                    }
                    val receipt = ok("typeText", mapOf("text" to "target"))
                    log.append("DETAIL accessibility target receipt=$receipt\n")
                    check(receipt == "set_text") { "Accessibility-selected editor did not use text-node insertion" }
                    waitFor("accessibility-focused insertion") { secondaryText() == "secondary fixturetarget" }
                    check(text() == "selected OLD text") { "Typing changed the other editor" }
                    check(!required("woi-keyboard-input").isFocused && !required("woi-keyboard-secondary-input").isFocused) { "Typing changed input focus" }

                    check(required("woi-keyboard-input").performAction(AccessibilityNodeInfo.ACTION_FOCUS))
                    waitFor("primary editor input focus") { required("woi-keyboard-input").isFocused }
                    select(text().length, text().length)
                    val secondary = required("woi-keyboard-secondary-input")
                    secondary.performAction(AccessibilityNodeInfo.ACTION_ACCESSIBILITY_FOCUS)
                    secondary.refresh()
                    check(secondary.isAccessibilityFocused && !secondary.isFocused) { "Secondary accessibility selection was not retained" }
                    check(required("woi-keyboard-input").isFocused) { "Ordinary editor input focus was lost" }
                    val priorityReceipt = ok("typeText", mapOf("text" to " primary"))
                    log.append("DETAIL ordinary target receipt=$priorityReceipt\n")
                    check(priorityReceipt == "set_text")
                    try {
                        waitFor("ordinary input focus priority") { text() == "selected OLD text primary" }
                        check(secondaryText() == "secondary fixturetarget") { "An accessibility-selected node overrode ordinary input focus" }
                    } catch (error: Throwable) {
                        // Failure-only observation: never repair focus/cache before
                        // dispatch or relax the required intended-editor delivery.
                        fun describe(node: AccessibilityNodeInfo?): String {
                            if (node == null || node.packageName?.toString() != testPackage) return "no_fixture_node"
                            val identity = when (node.contentDescription?.toString()) {
                                "woi-keyboard-input" -> "primary"
                                "woi-keyboard-secondary-input" -> "secondary"
                                else -> "fixture_container"
                            }
                            val value = node.text?.toString().orEmpty()
                            val contents = when (value) {
                                "selected OLD text" -> "primary_before"
                                "selected OLD text primary" -> "primary_expected"
                                "secondary fixturetarget" -> "secondary_before"
                                "secondary fixturetarget primary" -> "secondary_received_primary"
                                else -> "other_redacted"
                            }
                            return "$identity,input=${node.isFocused},a11y=${node.isAccessibilityFocused},visible=${node.isVisibleToUser},editable=${node.isEditable},selection=${node.textSelectionStart}..${node.textSelectionEnd},text=$contents,length=${value.length},insert_at=${value.indexOf(" primary")}"
                        }
                        for (description in listOf("woi-keyboard-input", "woi-keyboard-secondary-input")) {
                            val observed = required(description)
                            log.append("DETAIL priority ui_cached ${describe(observed)}\n")
                            val refreshed = observed.refresh()
                            log.append("DETAIL priority ui_fresh refreshed=$refreshed ${describe(observed)}\n")
                        }
                        host.runOnMainSync {
                            val service = WoiAccessibilityService.instance
                            val input = service?.findFocus(AccessibilityNodeInfo.FOCUS_INPUT)
                            log.append("DETAIL priority service_input_cached ${describe(input)}\n")
                            val refreshed = input?.refresh()
                            log.append("DETAIL priority service_input_fresh refreshed=$refreshed ${describe(input)}\n")
                            val selected = service?.findFocus(AccessibilityNodeInfo.FOCUS_ACCESSIBILITY)
                            log.append("DETAIL priority service_accessibility ${describe(selected)}\n")
                        }
                        throw error
                    }
                    log.append("DETAIL accessibility target and ordinary input focus both preserved the other editor.\n")
                } finally {
                    ui.serviceInfo = ui.serviceInfo.apply { flags = originalFlags }
                    waitFor("original touch exploration policy") { manager.isTouchExplorationEnabled == originalTouchExploration }
                }
            }
            verify("a different window from the same app cannot receive stale editor input") {
                val before = text()
                val secondaryBefore = secondaryText()
                check(required("woi-keyboard-open-dialog").performAction(AccessibilityNodeInfo.ACTION_CLICK))
                waitFor("no-editor dialog") { node("woi-keyboard-dialog") != null }
                try {
                    val reply = native("typeText", mapOf("text" to "must not reach the old window"))
                    check(reply.code == "no_input_target") { "Dialog input incorrectly returned ${reply.code}: ${reply.value}" }
                } finally {
                    node("woi-keyboard-dialog-close")?.performAction(AccessibilityNodeInfo.ACTION_CLICK)
                }
                waitFor("dialog closed") { node("woi-keyboard-dialog") == null && node("woi-keyboard-input") != null }
                check(text() == before && secondaryText() == secondaryBefore) { "Typing reached an editor behind the dialog" }
            }
            verify("touch keyboard is visible without an editor and preserves focus") {
                required("woi-keyboard-input").performAction(AccessibilityNodeInfo.ACTION_CLEAR_ACCESSIBILITY_FOCUS)
                required("woi-keyboard-secondary-input").performAction(AccessibilityNodeInfo.ACTION_CLEAR_ACCESSIBILITY_FOCUS)
                check(required("woi-keyboard-leave-editor").performAction(AccessibilityNodeInfo.ACTION_CLICK))
                waitFor("no editor input or accessibility focus") {
                    val primary = required("woi-keyboard-input")
                    val secondary = required("woi-keyboard-secondary-input")
                    !primary.isFocused && !primary.isAccessibilityFocused && !secondary.isFocused && !secondary.isAccessibilityFocused
                }
                val reply = ok("showKeyboard") as Map<*, *>
                check(reply["focus_changed"] == false)
                check(reply["visible"] == true && reply["backend"] == "woi_touch_keyboard")
                check(reply["text_target"] == false && reply["text_input_available"] == false)
                waitFor("actual Woi touch keyboard window") {
                    ui.windows.any { it.type == AccessibilityWindowInfo.TYPE_ACCESSIBILITY_OVERLAY && it.title?.toString() == "Woi touch keyboard" }
                }
                check(!required("woi-keyboard-input").isFocused)
            }
            verify("typing with no selected editor fails without changing text") {
                val before = text()
                val reply = native("typeText", mapOf("text" to "must not appear"))
                check(reply.code == "no_input_target")
                check(text() == before && !required("woi-keyboard-input").isFocused)
            }
        } catch (error: Throwable) { failure = error }
        finally {
            try {
                host.runOnMainSync {
                    WoiAccessibilityService.cancelKeyboard()
                    WoiClipboard.cancelPending()
                    val service = WoiAccessibilityService.instance
                    val mode = keyboardShowMode
                    if (service != null && mode != null) {
                        check(service.softKeyboardController.setShowMode(mode)) { "Could not restore the pre-test keyboard show policy" }
                    }
                }
                if (WoiAccessibilityService.instance != null) {
                    ok("hideKeyboard")
                    ok("controlReset")
                }
            } catch (cleanup: Throwable) {
                if (failure == null) failure = cleanup else failure!!.addSuppressed(cleanup)
            }
            if (clipboardProtected) {
                try {
                    clipboardSnapshot("restore", clipboardId)
                    clipboardRestored = true
                    log.append("CLEANUP Original clipboard restored locally; contents were not exported.\n")
                    clipboardSnapshot("close", clipboardId)
                } catch (cleanup: Throwable) {
                    if (failure == null) failure = cleanup else failure!!.addSuppressed(cleanup)
                    log.append("CLEANUP Clipboard restore failed; the snapshot is retained in the fixture process for retry.\n")
                }
            } else if (clipboardSnapshotAttempted) {
                try { clipboardSnapshot("close", clipboardId) }
                catch (cleanup: Throwable) {
                    if (failure == null) failure = cleanup else failure!!.addSuppressed(cleanup)
                }
            }
        }
        host.finish(if (failure == null) Activity.RESULT_OK else Activity.RESULT_CANCELED, Bundle().apply {
            putInt("passed", passed)
            putString("stream", "\n$log\n$passed Android keyboard fixture checks passed.\n" + (failure?.stackTraceToString() ?: ""))
            if (failure != null) putString("failure", failure.toString())
            if (clipboardProtected && !clipboardRestored) putString("clipboard_snapshot_id", clipboardId)
        })
    }
}
