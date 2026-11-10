package dev.woi.woi

import android.Manifest
import android.accessibilityservice.AccessibilityServiceInfo
import android.app.Activity
import android.app.Instrumentation
import android.app.UiAutomation
import android.content.ComponentName
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Rect
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.SystemClock
import android.provider.Browser
import android.provider.Settings
import android.view.InputDevice
import android.view.MotionEvent
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import android.view.accessibility.AccessibilityWindowInfo
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicLong

/** Test-APK only. Production WoiBridge -> WoiAccessibilityService dispatch and
 * the real touch-key callbacks perform every accepted input operation. UI
 * automation taps simulate the user's finger on known fixture/keyboard keys;
 * they never swipe or inject keys into Brave/Settings/the editor directly.
 *
 * Requires an operator-prepared adb reverse and static page at the loopback URL
 * below. That page has no inputs: its sticky accessible label is exactly
 * "Woi scroll position: N" (Math.round(scrollY)), followed by 80 paragraphs
 * "Woi marker NN". The harness exports only known page offsets, fixture
 * counters and Settings movement booleans, never other app text or images.
 * It neither chooses an IME nor reads/writes the clipboard. */
class ExternalInputDeviceCheck(private val host: Instrumentation) {
    private val ctx get() = host.targetContext
    private val fixturePackage get() = host.context.packageName
    private val brave = "com.brave.browser"
    private val settings = "com.android.settings"
    private val page = "http://127.0.0.1:8765/woi-input"
    private lateinit var ui: UiAutomation
    private val log = StringBuilder()
    private var passed = 0
    private val eventSequence = AtomicLong()
    private val eventLock = Any()
    private var lastScroll: ScrollSample? = null

    private data class Reply(val value: Any?, val code: String? = null, val message: String? = null)
    private data class Focus(val packageName: String, val windowId: Int)
    private data class ScrollSample(val sequence: Long, val packageName: String, val y: Int,
        val deltaY: Int, val from: Int, val to: Int)
    private data class PaneSnapshot(val fingerprint: Int, val firstRow: Int?, val bounds: Rect)

    /** Reflection is confined to the instrumentation APK; no exported release
     * command receiver or test-only production shortcut is introduced. */
    private fun native(name: String, args: Map<String, Any?> = emptyMap()): Reply {
        val done = CountDownLatch(1)
        var reply = Reply(null, "timeout")
        host.runOnMainSync {
            try {
                val handle = WoiBridge::class.java.getDeclaredMethod("handle", MethodCall::class.java, MethodChannel.Result::class.java)
                handle.isAccessible = true
                handle.invoke(WoiBridge, MethodCall(name, args), object : MethodChannel.Result {
                    override fun success(result: Any?) { reply = Reply(result); done.countDown() }
                    override fun error(code: String, message: String?, details: Any?) { reply = Reply(details, code, message); done.countDown() }
                    override fun notImplemented() { reply = Reply(null, "not_implemented"); done.countDown() }
                })
            } catch (error: Throwable) {
                reply = Reply(null, "exception", error.cause?.message ?: error.message)
                done.countDown()
            }
        }
        check(done.await(10, TimeUnit.SECONDS)) { "$name did not finish" }
        return reply
    }

    private fun ok(name: String, args: Map<String, Any?> = emptyMap()): Any? {
        val reply = native(name, args)
        check(reply.code == null) { "$name: ${reply.code}: ${reply.message}" }
        return reply.value
    }

    private fun waitFor(label: String, timeout: Long = 6000, predicate: () -> Boolean) {
        val deadline = SystemClock.elapsedRealtime() + timeout
        while (!predicate()) {
            check(SystemClock.elapsedRealtime() < deadline) { "Timed out: $label" }
            SystemClock.sleep(60)
        }
    }

    private fun verify(name: String, action: () -> Unit) {
        action()
        passed++
        log.append("PASS $name\n")
        host.sendStatus(0, Bundle().apply { putString("stream", "PASS $name\n") })
    }

    private fun recycle(node: AccessibilityNodeInfo?) = WoiAccessibilityService.recycle(node)

    private fun focusedApp(): Focus? {
        for (window in ui.windows) {
            if (window.type != AccessibilityWindowInfo.TYPE_APPLICATION || !window.isFocused) continue
            val root = window.root ?: continue
            try { root.packageName?.toString()?.let { return Focus(it, window.id) } }
            finally { recycle(root) }
        }
        return null
    }

    private fun hasEditableFocus(pkg: String): Boolean {
        for (window in ui.windows) {
            if (window.type != AccessibilityWindowInfo.TYPE_APPLICATION || !window.isFocused) continue
            val root = window.root ?: continue
            try {
                if (root.packageName?.toString() != pkg) continue
                val node = root.findFocus(AccessibilityNodeInfo.FOCUS_INPUT)
                try { return node?.isEditable == true } finally { recycle(node) }
            } finally { recycle(root) }
        }
        return false
    }

    private fun find(pkg: String, predicate: (AccessibilityNodeInfo) -> Boolean): AccessibilityNodeInfo? {
        var visited = 0
        fun visit(node: AccessibilityNodeInfo, depth: Int): AccessibilityNodeInfo? {
            if (++visited > 1800 || depth > 60) return null
            if (node.isVisibleToUser && predicate(node)) return AccessibilityNodeInfo.obtain(node)
            for (i in 0 until node.childCount) {
                if (visited >= 1800) break
                val child = node.getChild(i) ?: continue
                try { visit(child, depth + 1)?.let { return it } } finally { recycle(child) }
            }
            return null
        }
        for (window in ui.windows) {
            val root = window.root ?: continue
            try {
                if (root.packageName?.toString() == pkg) visit(root, 0)?.let { return it }
            } finally { recycle(root) }
        }
        return null
    }

    private fun described(pkg: String, description: String) = find(pkg) { it.contentDescription?.toString() == description }
    private fun fixtureNode(description: String) = checkNotNull(described(fixturePackage, description)) { "Fixture node missing: $description" }
    private fun fixtureText(description: String): String {
        val node = fixtureNode(description)
        return try { node.text?.toString().orEmpty() } finally { recycle(node) }
    }

    private fun pagePosition(): Int? {
        if (focusedApp()?.packageName != brave) return null
        val node = find(brave) { it.text?.toString()?.matches(Regex("Woi scroll position: [0-9]+")) == true } ?: return null
        return try { node.text.toString().substringAfter(": ").toIntOrNull() } finally { recycle(node) }
    }

    private fun position() = checkNotNull(pagePosition()) { "Controlled Brave scroll marker is unavailable" }

    /** The node location is freshly read in physical display coordinates. */
    private fun tapDescription(pkg: String, description: String) {
        waitFor("touch target $description") {
            described(pkg, description)?.let { recycle(it); true } == true
        }
        val node = checkNotNull(described(pkg, description))
        val bounds = Rect()
        try { check(node.isEnabled && node.isVisibleToUser); node.getBoundsInScreen(bounds) }
        finally { recycle(node) }
        check(bounds.width() > 0 && bounds.height() > 0) { "Touch target has no visible bounds: $description" }
        val now = SystemClock.uptimeMillis()
        fun event(action: Int, time: Long) = MotionEvent.obtain(now, time, action,
            bounds.exactCenterX(), bounds.exactCenterY(), 0).apply { source = InputDevice.SOURCE_TOUCHSCREEN }
        val down = event(MotionEvent.ACTION_DOWN, now)
        try { check(ui.injectInputEvent(down, true)) { "User-finger down was refused" } } finally { down.recycle() }
        SystemClock.sleep(45)
        val up = event(MotionEvent.ACTION_UP, SystemClock.uptimeMillis())
        try { check(ui.injectInputEvent(up, true)) { "User-finger up was refused" } } finally { up.recycle() }
        SystemClock.sleep(80)
    }

    private fun touchKey(label: String) = tapDescription(ctx.packageName, "Woi key $label")
    private fun modifier(label: String) = tapDescription(ctx.packageName, "Woi modifier $label")
    private fun keyboardStatus(): String? {
        val node = described(ctx.packageName, "Woi keyboard status") ?: return null
        return try { node.text?.toString() } finally { recycle(node) }
    }

    private fun showKeyboard(): Map<*, *> {
        ok("controlReset") // represents a fresh explicitly requested test action
        val reply = ok("showKeyboard") as Map<*, *>
        check(reply["visible"] == true && reply["backend"] == "woi_touch_keyboard") { "The production route did not show a Woi touch keyboard" }
        waitFor("actual touch keyboard window") {
            ui.windows.any { it.type == AccessibilityWindowInfo.TYPE_ACCESSIBILITY_OVERLAY && it.title?.toString() == "Woi touch keyboard" }
        }
        return reply
    }

    private fun scroll(direction: String, strategy: String = "auto"): Map<*, *> {
        ok("controlReset")
        return ok("scroll", mapOf("direction" to direction, "amount" to 1.0, "strategy" to strategy)) as Map<*, *>
    }

    private fun openControlledPage() {
        host.context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(page)).apply {
            setPackage(brave)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            putExtra(Browser.EXTRA_APPLICATION_ID, ctx.packageName)
            putExtra("create_new_tab", true)
        })
        waitFor("controlled Brave page", 15000) { pagePosition() != null }
        waitFor("non-editable Brave viewport") { !hasEditableFocus(brave) }
        SystemClock.sleep(350)
    }

    /** Settings fingerprints include only transient hashed row identities and
     * bounds inside its scroll pane. No Settings labels or account text are
     * retained in results. Scroll events independently confirm the action. */
    private fun settingsPane(): PaneSnapshot? {
        val candidates = mutableListOf<AccessibilityNodeInfo>()
        var visited = 0
        fun collect(node: AccessibilityNodeInfo, depth: Int) {
            if (++visited > 1000 || depth > 50) return
            if (node.isVisibleToUser && node.isScrollable) candidates.add(AccessibilityNodeInfo.obtain(node))
            for (i in 0 until node.childCount) {
                if (visited >= 1000) break
                val child = node.getChild(i) ?: continue
                try { collect(child, depth + 1) } finally { recycle(child) }
            }
        }
        for (window in ui.windows) {
            if (window.type != AccessibilityWindowInfo.TYPE_APPLICATION || !window.isFocused) continue
            val root = window.root ?: continue
            try { if (root.packageName?.toString() == settings) collect(root, 0) } finally { recycle(root) }
        }
        try {
            val pane = candidates.maxByOrNull { node -> Rect().also(node::getBoundsInScreen).let { it.width().toLong() * it.height() } } ?: return null
            val bounds = Rect().also(pane::getBoundsInScreen)
            var fingerprint = 1
            var firstRow: Int? = null
            var count = 0
            fun capture(node: AccessibilityNodeInfo, depth: Int) {
                if (++count > 500 || depth > 35) return
                val b = Rect().also(node::getBoundsInScreen)
                if (!node.isVisibleToUser || !Rect.intersects(bounds, b)) return
                node.collectionItemInfo?.rowIndex?.takeIf { it >= 0 }?.let { firstRow = minOf(firstRow ?: it, it) }
                fingerprint = 31 * fingerprint + (node.viewIdResourceName?.hashCode() ?: 0)
                fingerprint = 31 * fingerprint + (node.text?.toString()?.hashCode() ?: 0)
                fingerprint = 31 * fingerprint + b.top
                fingerprint = 31 * fingerprint + b.bottom
                for (i in 0 until node.childCount) {
                    val child = node.getChild(i) ?: continue
                    try { capture(child, depth + 1) } finally { recycle(child) }
                }
            }
            capture(pane, 0)
            return PaneSnapshot(fingerprint, firstRow, bounds)
        } finally { candidates.forEach(::recycle) }
    }

    private fun settingsEventAfter(sequence: Long): ScrollSample? = synchronized(eventLock) {
        lastScroll?.takeIf { it.packageName == settings && it.sequence > sequence }
    }

    private fun ensurePreviouslyEnabledService() {
        if (WoiAccessibilityService.instance != null) return
        val resolver = ctx.contentResolver
        val key = Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES
        val original = Settings.Secure.getString(resolver, key).orEmpty()
        val component = ComponentName(ctx, WoiAccessibilityService::class.java)
        val entries = original.split(':')
        check(entries.any { ComponentName.unflattenFromString(it.trim()) == component }) { "Enable Woi accessibility through Android before this check" }
        check(ctx.checkSelfPermission(Manifest.permission.WRITE_SECURE_SETTINGS) == PackageManager.PERMISSION_GRANTED) {
            "The previously enabled service must be rebound after instrumentation restart; no permission is granted by this fixture"
        }
        // Same isolated-test rebind as KeyboardDeviceCheck. Rebind only the
        // already enabled Woi entry and restore the complete original list.
        try {
            check(Settings.Secure.putString(resolver, key, entries.filter {
                ComponentName.unflattenFromString(it.trim()) != component
            }.joinToString(":")))
            SystemClock.sleep(250)
        } finally { check(Settings.Secure.putString(resolver, key, original)) }
    }

    fun run() {
        var failure: Throwable? = null
        val ime = Settings.Secure.getString(ctx.contentResolver, Settings.Secure.DEFAULT_INPUT_METHOD)
        var showMode: Int? = null
        try {
            check(Build.VERSION.SDK_INT >= 33) { "Exact touch-key acceptance needs Android 13+" }
            host.runOnMainSync { WoiBridge.ensureContext(ctx) }
            ui = host.getUiAutomation(UiAutomation.FLAG_DONT_SUPPRESS_ACCESSIBILITY_SERVICES)
            ui.serviceInfo = ui.serviceInfo.apply { flags = flags or AccessibilityServiceInfo.FLAG_RETRIEVE_INTERACTIVE_WINDOWS }
            ui.setOnAccessibilityEventListener { event ->
                val pkg = event.packageName?.toString()
                if (event.eventType == AccessibilityEvent.TYPE_VIEW_SCROLLED && (pkg == settings || pkg == brave)) {
                    val sample = ScrollSample(eventSequence.incrementAndGet(), pkg!!, event.scrollY,
                        event.scrollDeltaY, event.fromIndex, event.toIndex)
                    synchronized(eventLock) { lastScroll = sample }
                }
            }
            ensurePreviouslyEnabledService()
            waitFor("existing accessibility service", 15000) { WoiAccessibilityService.instance != null }
            check(!WoiOverlay.showing) { "Close the live assistant panel before this isolated native fixture" }
            host.runOnMainSync { showMode = WoiAccessibilityService.instance!!.softKeyboardController.showMode }
            ok("hideKeyboard")
            openControlledPage()
            verify("Brave production dispatcher scrolls down and up with accessibility/gesture fallback") {
                val before = position()
                val down = scroll("down")
                waitFor("Brave down movement") { (pagePosition() ?: before) > before + 60 }
                val afterDown = position()
                val up = scroll("up")
                waitFor("Brave up movement") { (pagePosition() ?: afterDown) < afterDown - 60 }
                log.append("DETAIL brave_auto before=$before down=$afterDown up=${position()} down_backend=${down["backend"]} up_backend=${up["backend"]}\n")
            }
            verify("Brave explicit gesture strategy moves actual page content both ways") {
                val before = position()
                val down = scroll("down", "gesture")
                check(down["backend"].toString().contains("gesture"))
                waitFor("Brave gesture down movement") { (pagePosition() ?: before) > before + 60 }
                val afterDown = position()
                scroll("up", "gesture")
                waitFor("Brave gesture up movement") { (pagePosition() ?: afterDown) < afterDown - 60 }
                log.append("DETAIL brave_gesture before=$before down=$afterDown up=${position()}\n")
            }
            verify("non-editor Brave page shows a real touch keyboard without changing external focus") {
                val beforeFocus = focusedApp()
                check(beforeFocus?.packageName == brave && !hasEditableFocus(brave))
                val shown = showKeyboard()
                check(shown["focus_changed"] == false && shown["text_target"] == false)
                check(focusedApp() == beforeFocus && !hasEditableFocus(brave))
            }
            verify("finger taps on actual PgDn and PgUp keys move Brave while preserving its focus") {
                val beforeFocus = focusedApp()
                val before = position()
                touchKey("PgDn")
                waitFor("touch PgDn completion") { keyboardStatus()?.startsWith("Page down dispatched") == true }
                waitFor("touch PgDn content movement") { (pagePosition() ?: before) > before + 40 }
                val afterDown = position()
                check(focusedApp() == beforeFocus && !hasEditableFocus(brave))
                touchKey("PgUp")
                waitFor("touch PgUp completion") { keyboardStatus()?.startsWith("Page up dispatched") == true }
                waitFor("touch PgUp content movement") { (pagePosition() ?: afterDown) < afterDown - 40 }
                check(focusedApp() == beforeFocus && !hasEditableFocus(brave))
                log.append("DETAIL brave_touch before=$before down=$afterDown up=${position()}\n")
                ok("hideKeyboard")
            }
            host.context.startActivity(Intent(Settings.ACTION_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            waitFor("Settings root scroll pane") { focusedApp()?.packageName == settings && settingsPane() != null }
            SystemClock.sleep(350)
            verify("Settings receives production gesture scrolling with observed content movement down and up") {
                val before = checkNotNull(settingsPane())
                val beforeSequence = eventSequence.get()
                scroll("down", "gesture")
                waitFor("Settings down scroll event and content change") {
                    settingsEventAfter(beforeSequence) != null && settingsPane()?.fingerprint != before.fingerprint
                }
                val afterDown = checkNotNull(settingsPane())
                val downEvent = checkNotNull(settingsEventAfter(beforeSequence))
                check(downEvent.deltaY >= 0) { "Settings moved opposite the requested down direction" }
                val downSequence = eventSequence.get()
                scroll("up", "gesture")
                waitFor("Settings up scroll event and content change") {
                    settingsEventAfter(downSequence) != null && settingsPane()?.fingerprint != afterDown.fingerprint
                }
                val afterUp = checkNotNull(settingsPane())
                val upEvent = checkNotNull(settingsEventAfter(downSequence))
                val movedUp = upEvent.deltaY < 0 || (downEvent.y >= 0 && upEvent.y >= 0 && upEvent.y < downEvent.y) ||
                    (downEvent.from >= 0 && upEvent.from >= 0 && upEvent.from < downEvent.from) ||
                    (afterDown.firstRow != null && afterUp.firstRow != null && afterUp.firstRow < afterDown.firstRow)
                check(movedUp) { "Settings content changed, but upward scroll direction was not acknowledged" }
                log.append("DETAIL settings content_changed_down=true content_changed_up=true offsets=${downEvent.y}->${upEvent.y} rows=${downEvent.from}->${upEvent.from}\n")
            }
            host.context.startActivity(Intent().apply {
                component = ComponentName(fixturePackage, KeyboardTestActivity::class.java.name)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK)
                putExtra("hide_keyboard", true)
            })
            waitFor("fresh synthetic editor") { described(fixturePackage, "woi-keyboard-input")?.let { recycle(it); true } == true }
            waitFor("synthetic editor focus") { focusedApp()?.packageName == fixturePackage && hasEditableFocus(fixturePackage) }
            check(fixtureText("woi-keyboard-input") == "alpha beta") { "The fixture did not start fresh" }
            showKeyboard()
            verify("actual touch letters, Shift and Backspace edit the synthetic receiver") {
                var expected = "alpha beta"
                for ((key, text) in listOf("Space" to " ", "w" to "w", "o" to "o", "i" to "i")) {
                    touchKey(key)
                    expected += text
                    waitFor("touch text acknowledgement") { fixtureText("woi-keyboard-input") == expected }
                }
                modifier("Shift")
                touchKey("a")
                waitFor("Shift touch letter") { fixtureText("woi-keyboard-input") == "$expected" + "A" }
                touchKey("⌫")
                waitFor("touch Backspace") { fixtureText("woi-keyboard-input") == expected }
                check(fixtureText("woi-keyboard-secondary-input") == "secondary fixture")
                check(focusedApp()?.packageName == fixturePackage)
            }
            verify("touch Ctrl+Alt+Shift+K is acknowledged by the actual editor after typing") {
                val before = fixtureText("woi-keyboard-chord").toInt()
                modifier("Ctrl"); modifier("Alt"); modifier("Shift"); touchKey("k")
                try {
                    waitFor("receiving editor combined-modifier acknowledgement") { fixtureText("woi-keyboard-chord").toInt() == before + 1 }
                } catch (error: Throwable) {
                    log.append("DETAIL fixture_connection ${fixtureText("woi-keyboard-primary-connection")} events=${fixtureText("woi-keyboard-events")} status=${keyboardStatus()}\n")
                    throw error
                }
                check(fixtureText("woi-keyboard-input") == "alpha beta woi")
            }
            verify("touch Ctrl+A selects real editor text and a following letter replaces it") {
                modifier("Ctrl"); touchKey("a")
                waitFor("Ctrl+A actual selection") {
                    val node = fixtureNode("woi-keyboard-input")
                    try { node.textSelectionStart == 0 && node.textSelectionEnd == node.text?.length } finally { recycle(node) }
                }
                touchKey("r")
                waitFor("typing replaces actual selection") { fixtureText("woi-keyboard-input") == "r" }
                check(fixtureText("woi-keyboard-secondary-input") == "secondary fixture")
            }
            verify("capture consent suspends touch keys and stop restores the prior keyboard") {
                fun keyboardVisible() = ui.windows.any { window ->
                    if (window.type != AccessibilityWindowInfo.TYPE_ACCESSIBILITY_OVERLAY ||
                        window.title?.toString() != "Woi touch keyboard") false
                    else window.root?.let { root -> try { root.isVisibleToUser } finally { recycle(root) } } == true
                }
                check(keyboardVisible())
                val pending = ok("shareStart") as Map<*, *>
                check(pending["pending"] == true && pending["on"] == false)
                waitFor("real Android projection consent window") {
                    ui.windows.any { window ->
                        window.isFocused && window.root?.let { root ->
                            try { root.packageName?.toString() == "com.android.systemui" } finally { recycle(root) }
                        } == true
                    }
                }
                check(!keyboardVisible()) { "Touch keyboard covers Android consent" }
                check((ok("shareStop") as Map<*, *>)["on"] == false)
                check((ok("shareStop") as Map<*, *>)["on"] == false)
                waitFor("prior keyboard and receiver restored after cancelled consent") {
                    keyboardVisible() && focusedApp()?.packageName == fixturePackage
                }
                check(!WoiScreen.hasProjection())
            }
            verify("selected Android input method and show policy are preserved") {
                check(Settings.Secure.getString(ctx.contentResolver, Settings.Secure.DEFAULT_INPUT_METHOD) == ime)
                var current: Int? = null
                host.runOnMainSync { current = WoiAccessibilityService.instance?.softKeyboardController?.showMode }
                check(current == showMode)
            }
        } catch (error: Throwable) { failure = error }
        finally {
            try {
                host.runOnMainSync { WoiMediaCapture.stopAll() }
                if (::ui.isInitialized) ui.setOnAccessibilityEventListener(null)
                if (WoiAccessibilityService.instance != null) {
                    host.runOnMainSync { WoiAccessibilityService.cancelKeyboard() }
                    ok("hideKeyboard")
                    ok("controlReset")
                }
                check(Settings.Secure.getString(ctx.contentResolver, Settings.Secure.DEFAULT_INPUT_METHOD) == ime) { "Selected IME changed during the fixture" }
                log.append("CLEANUP Woi touch keyboard hidden; original selected IME retained; no clipboard access.\n")
            } catch (cleanup: Throwable) {
                if (failure == null) failure = cleanup else failure!!.addSuppressed(cleanup)
            }
        }
        host.finish(if (failure == null) Activity.RESULT_OK else Activity.RESULT_CANCELED, Bundle().apply {
            putString("stream", "\n$log\n$passed external input acceptance checks passed.\n" + (failure?.stackTraceToString() ?: ""))
        })
    }
}
