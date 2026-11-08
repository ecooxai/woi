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
import android.view.accessibility.AccessibilityNodeInfo
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/** Prepared for an isolated Android 13+ emulator/test device only. Starting the
 * app's instrumentation restarts its target process, so do not run this against
 * the user's active Woi installation. It does not grant/rebind accessibility,
 * switch the IME/assistant, or start Flutter/audio. The copy tests use fixture
 * clipboard content, so the test belongs on an isolated test profile/device. */
class KeyboardDeviceCheck(private val host: Instrumentation) {
    private lateinit var ui: UiAutomation
    private val testPackage get() = host.context.packageName
    private data class Reply(val value: Any?, val code: String? = null, val message: String? = null)

    private fun native(method: String, args: Map<String, Any?> = emptyMap()): Reply {
        check(WoiAccessibilityService.instance != null) { "Accessibility must already be enabled and bound; this fixture never enables it" }
        val done = CountDownLatch(1)
        var reply = Reply(null, "timeout")
        host.runOnMainSync {
            try {
                WoiAccessibilityService.handle(MethodCall(method, args), object : MethodChannel.Result {
                    override fun success(result: Any?) { reply = Reply(result); done.countDown() }
                    override fun error(code: String, message: String?, details: Any?) { reply = Reply(details, code, message); done.countDown() }
                    override fun notImplemented() { reply = Reply(null, "not_implemented"); done.countDown() }
                })
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

    private fun waitFor(label: String, condition: () -> Boolean) {
        val until = SystemClock.elapsedRealtime() + 5000
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
    private fun events() = required("woi-keyboard-events").text.toString().toInt()
    private fun select(start: Int, end: Int) {
        check(required("woi-keyboard-input").performAction(AccessibilityNodeInfo.ACTION_SET_SELECTION, Bundle().apply {
            putInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_START_INT, start)
            putInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_END_INT, end)
        }))
    }
    private fun prepare(value: String) {
        val input = required("woi-keyboard-input")
        if (!input.isFocused) check(input.performAction(AccessibilityNodeInfo.ACTION_FOCUS))
        check(input.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, Bundle().apply {
            putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, value)
        }))
        waitFor("fixture text") { text() == value }
        select(value.length, value.length)
    }
    private fun key(name: String, vararg modifiers: String): Map<String, Any> =
        mapOf("type" to "key", "key" to name, "modifiers" to modifiers.toList())
    private fun send(vararg keys: Map<String, Any>): Map<*, *> =
        ok("sendKeys", mapOf("operations" to keys.toList(), "target" to testPackage)) as Map<*, *>

    fun run() {
        val log = StringBuilder()
        var passed = 0
        var failure: Throwable? = null
        fun verify(name: String, block: () -> Unit) { block(); passed++; log.append("PASS $name\n") }
        try {
            check(Build.VERSION.SDK_INT >= 33) { "This exact-key fixture requires Android 13+" }
            ui = host.getUiAutomation(UiAutomation.FLAG_DONT_SUPPRESS_ACCESSIBILITY_SERVICES)
            ui.serviceInfo = ui.serviceInfo.apply { flags = flags or AccessibilityServiceInfo.FLAG_RETRIEVE_INTERACTIVE_WINDOWS }
            check(!WoiOverlay.showing) { "Dismiss the assistant before this isolated fixture; it will not alter a live assistant session" }
            check(WoiAccessibilityService.instance != null) { "Accessibility must already be bound; no permission or service-list changes are performed" }
            host.context.startActivity(Intent().apply {
                component = ComponentName(testPackage, KeyboardTestActivity::class.java.name)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            })
            waitFor("fixture activity") { node("woi-keyboard-input") != null }
            ok("controlReset")
            verify("literal Unicode insertion through the background accessibility service") {
                prepare("prefix OLD suffix"); select(7, 10)
                check(ok("typeText", mapOf("text" to "雪🙂 + literal\nline")) == "ime_dispatched")
                waitFor("literal text insertion") { text() == "prefix 雪🙂 + literal\nline suffix" }
            }
            verify("Ctrl+A/C/V uses editor shortcuts and preserves exact text") {
                prepare("copy sample")
                check(send(key("a", "ctrl"), key("c", "ctrl"))["delivery"] == "dispatched")
                select(text().length, text().length)
                send(key("v", "ctrl"))
                waitFor("paste after copy") { text() == "copy samplecopy sample" }
            }
            verify("Ctrl+X cuts the selection and Ctrl+V restores it") {
                prepare("cut sample")
                send(key("a", "ctrl"), key("x", "ctrl"))
                waitFor("cut") { text().isEmpty() }
                send(key("v", "ctrl"))
                waitFor("paste after cut") { text() == "cut sample" }
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
        } catch (error: Throwable) { failure = error }
        finally {
            if (WoiAccessibilityService.instance != null) try { ok("controlReset") } catch (_: Throwable) { }
        }
        host.finish(if (failure == null) Activity.RESULT_OK else Activity.RESULT_CANCELED, Bundle().apply {
            putInt("passed", passed)
            putString("stream", "\n$log\n$passed Android keyboard fixture checks passed.\n" + (failure?.stackTraceToString() ?: ""))
            if (failure != null) putString("failure", failure.toString())
        })
    }
}
