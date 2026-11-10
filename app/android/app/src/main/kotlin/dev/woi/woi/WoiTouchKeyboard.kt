package dev.woi.woi

import android.content.Context
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.Rect
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.os.SystemClock
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.WindowManager
import android.widget.LinearLayout
import android.widget.TextView
import io.flutter.plugin.common.MethodChannel

internal sealed class WoiTouchKey {
    data class Text(val value: String) : WoiTouchKey()
    data class Chord(val key: String, val modifiers: Set<String>) : WoiTouchKey()
    data class Edit(val name: String) : WoiTouchKey()
    data class Global(val name: String) : WoiTouchKey()
}

/** Plain touch characters use the acknowledged literal-text path. A real
 * shortcut preserves every selected modifier instead of pretending to edit. */
internal object WoiTouchKeys {
    private val shifted = mapOf("1" to "!", "2" to "@", "3" to "#", "4" to "$", "5" to "%", "6" to "^",
        "7" to "&", "8" to "*", "9" to "(", "0" to ")", "." to ">", "/" to "?")
    fun input(key: String, modifiers: Set<String>): WoiTouchKey {
        require(modifiers.all { it in setOf("ctrl", "alt", "shift", "super") }) { "Unknown touch-key modifier" }
        val character = when {
            key == "space" -> " "
            key.length == 1 -> key
            else -> null
        }
        if (character != null && modifiers.all { it == "shift" }) {
            val text = if ("shift" in modifiers) shifted[character] ?: character.uppercase() else character
            return WoiTouchKey.Text(text)
        }
        val physical = when (key) { "." -> "period"; "/" -> "slash"; else -> key }
        WoiKeyboard.keyCode(physical)
        return WoiTouchKey.Chord(physical, modifiers.toSet())
    }
}

/** A genuine touch keyboard that needs no editor and never changes the user's
 * selected IME. TYPE_ACCESSIBILITY_OVERLAY uses the already-enabled service.
 * NOT_FOCUSABLE leaves all input focus with the underlying app. The backing is
 * about half transparent while key labels remain opaque and readable. */
internal class WoiTouchKeyboard(
    private val service: WoiAccessibilityService,
    private val onUserTouch: () -> Unit,
    private val onInput: (WoiTouchKey) -> Unit,
) {
    private val wm = service.getSystemService(Context.WINDOW_SERVICE) as WindowManager
    private val density get() = service.resources.displayMetrics.density
    private fun dp(value: Int) = (value * density + 0.5f).toInt()
    private var root: LinearLayout? = null
    private var rows: LinearLayout? = null
    private var status: TextView? = null
    private var params: WindowManager.LayoutParams? = null
    private var heldPanel = false
    private var atTop = false
    private var functions = false
    private val modifiers = linkedSetOf<String>()
    private var statusUntil = 0L
    private var captureSuspensions = 0
    private var suspendedView: LinearLayout? = null
    private var suspendedFlags = 0
    private var suspendedVisibility = View.VISIBLE
    val visible: Boolean get() = root?.let { it.isAttachedToWindow && it.isShown && it.width > 0 && it.height > 0 } == true

    fun bounds(): Rect? {
        val view = root ?: return null
        if (!visible) return null
        val xy = IntArray(2)
        view.getLocationOnScreen(xy)
        return Rect(xy[0], xy[1], xy[0] + view.width, xy[1] + view.height)
    }

    fun show(afterLayout: () -> Unit) {
        check(captureSuspensions == 0 && !WoiMediaCapture.consentInProgress) {
            "Woi keyboard is suspended while Android capture consent is open. Retry after consent."
        }
        root?.let { it.post(afterLayout); return }
        if (WoiOverlay.showing) {
            WoiOverlay.stepAside(true)
            heldPanel = true
        }
        val panel = object : LinearLayout(service) {
            override fun dispatchTouchEvent(event: MotionEvent): Boolean {
                if (event.actionMasked == MotionEvent.ACTION_DOWN) onUserTouch()
                return super.dispatchTouchEvent(event)
            }
        }.apply {
            orientation = LinearLayout.VERTICAL
            isFocusable = false
            contentDescription = "Woi touch keyboard"
            setPadding(dp(4), dp(4), dp(4), dp(4))
            background = GradientDrawable().apply { cornerRadius = dp(12).toFloat(); setColor(Color.argb(132, 12, 25, 41)) }
        }
        val header = LinearLayout(service).apply { orientation = LinearLayout.HORIZONTAL }
        header.addView(label("Woi keyboard", 14f).apply { setPadding(dp(8), 0, 0, 0) }, LinearLayout.LayoutParams(0, dp(32), 1f))
        header.addView(button("Move", "Move keyboard to the other edge") { dock() }, LinearLayout.LayoutParams(dp(64), dp(32)))
        header.addView(button("Hide", "Hide Woi keyboard") { hide() }, LinearLayout.LayoutParams(dp(64), dp(32)))
        panel.addView(header)
        status = label("Tap a text field to type; page and phone keys work here", 11f).apply {
            contentDescription = "Woi keyboard status"
            setPadding(dp(8), dp(2), dp(8), dp(2))
            maxLines = 2
        }.also { panel.addView(it, LinearLayout.LayoutParams(-1, dp(34))) }
        rows = LinearLayout(service).apply { orientation = LinearLayout.VERTICAL }.also { panel.addView(it) }
        root = panel
        rebuildKeys()
        val lp = WindowManager.LayoutParams(-1, -2, WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL,
            PixelFormat.TRANSLUCENT).apply {
            gravity = (if (atTop) Gravity.TOP else Gravity.BOTTOM) or Gravity.CENTER_HORIZONTAL
            title = "Woi touch keyboard"
            softInputMode = WindowManager.LayoutParams.SOFT_INPUT_ADJUST_NOTHING
        }
        params = lp
        try {
            wm.addView(panel, lp)
            panel.post(afterLayout)
        } catch (error: Throwable) {
            hide()
            throw error
        }
    }

    /** A modal capture permission window must never be covered by this
     * accessibility overlay. Keep the same view/modifiers and its assistant
     * panel lease, but make the window invisible and unable to take touches.
     * Explicit hide or service teardown removes the view, so release cannot
     * resurrect a keyboard the user no longer wants. Main thread only. */
    fun suspendForCapture(): () -> Unit {
        if (captureSuspensions++ == 0) {
            val view = root
            val lp = params
            suspendedView = view
            if (view != null && lp != null) {
                suspendedFlags = lp.flags
                suspendedVisibility = view.visibility
                view.visibility = View.INVISIBLE
                lp.flags = lp.flags or WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE
                try { wm.updateViewLayout(view, lp) }
                catch (error: Throwable) {
                    captureSuspensions--
                    suspendedView = null
                    hide()
                    throw error
                }
            }
        }
        var released = false
        return {
            if (!released) {
                released = true
                captureSuspensions--
                if (captureSuspensions == 0) {
                    val view = suspendedView
                    suspendedView = null
                    val lp = params
                    if (view != null && root === view && lp != null && view.isAttachedToWindow) {
                        lp.flags = suspendedFlags
                        view.visibility = suspendedVisibility
                        try { wm.updateViewLayout(view, lp) }
                        catch (_: Throwable) { hide() }
                    }
                }
            }
        }
    }

    fun hide() {
        root?.let { try { wm.removeView(it) } catch (_: Throwable) {} }
        root = null
        rows = null
        status = null
        params = null
        modifiers.clear()
        functions = false
        statusUntil = 0
        if (heldPanel) {
            heldPanel = false
            WoiOverlay.releasing(object : MethodChannel.Result {
                override fun success(result: Any?) {}
                override fun error(code: String, message: String?, details: Any?) {}
                override fun notImplemented() {}
            }).success(null)
        }
    }

    fun feedback(message: String, error: Boolean = false) {
        statusUntil = SystemClock.uptimeMillis() + if (error) 4000 else 1600
        status?.text = message
        status?.setTextColor(if (error) Color.rgb(255, 225, 150) else Color.WHITE)
    }

    fun targetStatus(message: String) {
        if (SystemClock.uptimeMillis() < statusUntil) return
        if (status?.text != message) status?.text = message
        status?.setTextColor(Color.WHITE)
    }

    fun relayout() { if (root != null) rebuildKeys() }

    private fun dock() {
        val view = root ?: return
        val lp = params ?: return
        atTop = !atTop
        lp.gravity = (if (atTop) Gravity.TOP else Gravity.BOTTOM) or Gravity.CENTER_HORIZONTAL
        wm.updateViewLayout(view, lp)
    }

    private fun label(text: String, size: Float) = TextView(service).apply {
        this.text = text
        textSize = size
        gravity = Gravity.CENTER_VERTICAL
        setTextColor(Color.WHITE)
        setTypeface(Typeface.DEFAULT, Typeface.BOLD)
        setShadowLayer(dp(1).toFloat(), 0f, dp(1).toFloat(), Color.BLACK)
        isFocusable = false
    }

    private fun button(text: String, description: String = text, selected: Boolean = false, action: () -> Unit) = label(text, 13f).apply {
        contentDescription = description
        gravity = Gravity.CENTER
        minWidth = 0
        setPadding(0, 0, 0, 0)
        background = GradientDrawable().apply {
            cornerRadius = dp(5).toFloat()
            setColor(if (selected) Color.argb(175, 25, 115, 185) else Color.argb(18, 225, 237, 255))
            setStroke(dp(1), Color.argb(if (selected) 220 else 100, 210, 230, 255))
        }
        setOnClickListener { action() }
    }

    private fun rebuildKeys() {
        val container = rows ?: return
        container.removeAllViews()
        val landscape = service.resources.configuration.orientation == android.content.res.Configuration.ORIENTATION_LANDSCAPE
        val height = dp(if (landscape) 30 else 40)
        fun row(keys: List<Triple<String, Float, View>>) {
            val line = LinearLayout(service).apply { orientation = LinearLayout.HORIZONTAL }
            for ((_, weight, view) in keys) line.addView(view, LinearLayout.LayoutParams(0, height, weight).apply { setMargins(dp(1), dp(1), dp(1), dp(1)) })
            container.addView(line)
        }
        fun key(code: String, title: String = code, weight: Float = 1f): Triple<String, Float, View> {
            val shifted = if (code.length == 1 && modifiers == setOf("shift")) WoiTouchKeys.input(code, modifiers) as? WoiTouchKey.Text else null
            val shown = shifted?.value ?: title
            return Triple(code, weight, button(shown, "Woi key $title") {
                val input = WoiTouchKeys.input(code, modifiers)
                modifiers.clear()
                rebuildKeys()
                onInput(input)
            })
        }
        fun modifier(code: String, title: String): Triple<String, Float, View> = Triple(code, 1.1f,
            button(title, "Woi modifier $title", code in modifiers) {
                if (!modifiers.add(code)) modifiers.remove(code)
                rebuildKeys()
            })
        fun global(code: String, title: String) = Triple(code, 1f, button(title, "Woi $title") {
            modifiers.clear(); rebuildKeys(); onInput(WoiTouchKey.Global(code))
        })
        fun edit(code: String, title: String) = Triple(code, 1f, button(title, "Woi $title") {
            modifiers.clear(); rebuildKeys(); onInput(WoiTouchKey.Edit(code))
        })
        row((if (functions) (1..12).map { key("f$it", "F$it") } else "1234567890".map { key(it.toString()) }) + key(if (functions) "delete" else "backspace", if (functions) "Del" else "⌫", 1.3f))
        row("qwertyuiop".map { key(it.toString()) })
        row("asdfghjkl".map { key(it.toString()) } + key("enter", "Enter", 1.4f))
        row(listOf(modifier("shift", "Shift")) + "zxcvbnm".map { key(it.toString()) } + key(".") + key("/"))
        row(listOf(modifier("ctrl", "Ctrl"), modifier("alt", "Alt"), modifier("super", "Meta"),
            Triple("fn", 0.9f, button("Fn", "Woi function keys", functions) { functions = !functions; rebuildKeys() }),
            key("space", "Space", 2.6f), key("tab", "Tab"), key("escape", "Esc")))
        row(listOf(key("home", "Home"), key("end", "End"), key("pageup", "PgUp"), key("pagedown", "PgDn"),
            key("left", "←"), key("up", "↑"), key("down", "↓"), key("right", "→")))
        row(listOf(global("back", "Back"), global("home", "Phone"), global("recents", "Apps"),
            edit("copy", "Copy"), edit("paste", "Paste"), edit("cut", "Cut"), edit("select_all", "All")))
    }
}
