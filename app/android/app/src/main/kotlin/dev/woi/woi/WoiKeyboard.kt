package dev.woi.woi

import android.view.KeyEvent

/** Validated requests shared by the accessibility adapter and native tests.
 * No hidden input APIs, shell injection, IME switching, or permission changes. */
internal sealed class WoiKeyOperation {
    data class Global(val name: String) : WoiKeyOperation()
    data class Edit(val name: String) : WoiKeyOperation()
    data class Chord(val key: String, val modifiers: Set<String>) : WoiKeyOperation()
}

internal data class WoiKeyStroke(val action: Int, val keyCode: Int, val metaState: Int)

internal interface WoiKeySink {
    fun send(stroke: WoiKeyStroke)
    fun clearMetaKeyStates(states: Int)
}

/** A cancellation token belongs to the request that started before focus
 * handoff. Cancellation invalidates old callbacks without poisoning a later
 * approved request or requiring a new default input method. */
internal class WoiKeyboardEpoch {
    private var generation = 0L
    fun capture(): Long = generation
    fun cancel() { generation++ }
    fun check(request: Long) {
        kotlin.check(request == generation) { "Keyboard request was cancelled" }
    }
}

/** Android's public keyboard keycodes. Unsupported keys fail before dispatch. */
internal object WoiKeyboard {
    private data class Modifier(val name: String, val code: Int, val mask: Int)
    private val modifiers = listOf(
        Modifier("ctrl", KeyEvent.KEYCODE_CTRL_LEFT, KeyEvent.META_CTRL_ON or KeyEvent.META_CTRL_LEFT_ON),
        Modifier("shift", KeyEvent.KEYCODE_SHIFT_LEFT, KeyEvent.META_SHIFT_ON or KeyEvent.META_SHIFT_LEFT_ON),
        Modifier("alt", KeyEvent.KEYCODE_ALT_LEFT, KeyEvent.META_ALT_ON or KeyEvent.META_ALT_LEFT_ON),
        Modifier("super", KeyEvent.KEYCODE_META_LEFT, KeyEvent.META_META_ON or KeyEvent.META_META_LEFT_ON),
    )
    val modifierMask: Int = modifiers.fold(0) { state, modifier -> state or modifier.mask }
    private val globalNames = setOf("back", "home", "recents", "notifications", "quick_settings")
    private val editNames = setOf("copy", "paste", "cut", "select_all", "enter", "clear_selection")
    private val namedCodes = mapOf(
        "enter" to KeyEvent.KEYCODE_ENTER, "escape" to KeyEvent.KEYCODE_ESCAPE,
        "tab" to KeyEvent.KEYCODE_TAB, "space" to KeyEvent.KEYCODE_SPACE,
        "backspace" to KeyEvent.KEYCODE_DEL, "delete" to KeyEvent.KEYCODE_FORWARD_DEL,
        "insert" to KeyEvent.KEYCODE_INSERT, "home" to KeyEvent.KEYCODE_MOVE_HOME,
        "end" to KeyEvent.KEYCODE_MOVE_END, "pageup" to KeyEvent.KEYCODE_PAGE_UP,
        "pagedown" to KeyEvent.KEYCODE_PAGE_DOWN, "up" to KeyEvent.KEYCODE_DPAD_UP,
        "down" to KeyEvent.KEYCODE_DPAD_DOWN, "left" to KeyEvent.KEYCODE_DPAD_LEFT,
        "right" to KeyEvent.KEYCODE_DPAD_RIGHT, "plus" to KeyEvent.KEYCODE_PLUS,
        "minus" to KeyEvent.KEYCODE_MINUS, "period" to KeyEvent.KEYCODE_PERIOD,
        "comma" to KeyEvent.KEYCODE_COMMA, "slash" to KeyEvent.KEYCODE_SLASH,
        "backslash" to KeyEvent.KEYCODE_BACKSLASH, "semicolon" to KeyEvent.KEYCODE_SEMICOLON,
        "equal" to KeyEvent.KEYCODE_EQUALS, "print" to KeyEvent.KEYCODE_SYSRQ,
        "menu" to KeyEvent.KEYCODE_MENU, "capslock" to KeyEvent.KEYCODE_CAPS_LOCK,
        "'" to KeyEvent.KEYCODE_APOSTROPHE, "[" to KeyEvent.KEYCODE_LEFT_BRACKET,
        "]" to KeyEvent.KEYCODE_RIGHT_BRACKET, "`" to KeyEvent.KEYCODE_GRAVE,
    )

    fun keyCode(key: String): Int {
        namedCodes[key]?.let { return it }
        modifiers.firstOrNull { it.name == key }?.let { return it.code }
        if (key.length == 1 && key[0] in 'a'..'z') return KeyEvent.KEYCODE_A + (key[0] - 'a')
        if (key.length == 1 && key[0] in '0'..'9') return KeyEvent.KEYCODE_0 + (key[0] - '0')
        if (Regex("f([1-9]|1[0-2])").matches(key)) return KeyEvent.KEYCODE_F1 + key.substring(1).toInt() - 1
        throw IllegalArgumentException("Android cannot send key '$key'; use type_text for literal characters")
    }

    fun parse(raw: Any?): List<WoiKeyOperation> {
        val list = raw as? List<*> ?: throw IllegalArgumentException("operations must be a list")
        require(list.isNotEmpty() && list.size <= 64) { "sendKeys needs between 1 and 64 operations" }
        val operations = list.map { value ->
            val item = value as? Map<*, *> ?: throw IllegalArgumentException("invalid keyboard operation")
            when (item["type"]) {
                "global" -> {
                    val name = item["name"] as? String ?: throw IllegalArgumentException("global action name required")
                    require(name in globalNames) { "unknown global action $name" }
                    WoiKeyOperation.Global(name)
                }
                "edit" -> {
                    val name = item["name"] as? String ?: throw IllegalArgumentException("edit action name required")
                    require(name in editNames) { "unknown edit action $name" }
                    WoiKeyOperation.Edit(name)
                }
                "key" -> {
                    val key = item["key"] as? String ?: throw IllegalArgumentException("key required")
                    keyCode(key)
                    val rawModifiers = item["modifiers"] as? List<*> ?: throw IllegalArgumentException("modifiers must be a list")
                    require(rawModifiers.all { value -> value is String && modifiers.any { it.name == value } }) { "unknown key modifier" }
                    val mods = rawModifiers.map { it as String }.toSet()
                    require(mods.size == rawModifiers.size) { "duplicate key modifier" }
                    require(mods.isEmpty() || modifiers.none { it.name == key }) { "a modifier tap cannot contain other modifiers" }
                    WoiKeyOperation.Chord(key, mods)
                }
                else -> throw IllegalArgumentException("unknown keyboard operation type")
            }
        }
        // Navigation can replace the target app. Never partially execute a
        // batch whose later editor target cannot be validated in advance.
        require(operations.none { it is WoiKeyOperation.Global } || operations.all { it is WoiKeyOperation.Global }) {
            "Send Android system navigation and editor shortcuts in separate requests"
        }
        return operations
    }

    fun validateSdk(operations: List<WoiKeyOperation>, sdk: Int) {
        require(sdk >= 33 || operations.none { it is WoiKeyOperation.Chord }) {
            "Exact keyboard shortcuts require Android 13 or newer and a focused input connection; semantic edit actions remain available"
        }
    }

    /** Sends one real chord. Cleanup always targets the same input connection,
     * including when a key-down throws after dispatch or the user cancels. */
    fun dispatch(chord: WoiKeyOperation.Chord, sink: WoiKeySink, check: () -> Unit) {
        val code = keyCode(chord.key)
        val held = mutableListOf<Modifier>()
        var mainDown = false
        var state = 0
        var failure: Throwable? = null
        var cleanupNeeded = false
        val bareModifier = modifiers.firstOrNull { it.name == chord.key }
        try {
            check()
            cleanupNeeded = true
            sink.clearMetaKeyStates(modifierMask)
            for (modifier in modifiers.filter { it.name in chord.modifiers }) {
                check()
                held.add(modifier)
                state = state or modifier.mask
                sink.send(WoiKeyStroke(KeyEvent.ACTION_DOWN, modifier.code, state))
            }
            check()
            mainDown = true
            sink.send(WoiKeyStroke(KeyEvent.ACTION_DOWN, code, state or (bareModifier?.mask ?: 0)))
        } catch (error: Throwable) {
            failure = error
        } finally {
            fun release(block: () -> Unit) {
                try { block() } catch (error: Throwable) {
                    if (failure == null) failure = error else if (failure !== error) failure!!.addSuppressed(error)
                }
            }
            if (mainDown) release { sink.send(WoiKeyStroke(KeyEvent.ACTION_UP, code, state)) }
            for (modifier in held.asReversed()) {
                state = state and modifier.mask.inv()
                release { sink.send(WoiKeyStroke(KeyEvent.ACTION_UP, modifier.code, state)) }
            }
            if (cleanupNeeded) release { sink.clearMetaKeyStates(modifierMask) }
        }
        failure?.let { throw it }
    }

    /** True only for the current external app, never Woi's composer or a stale
     * connection to another package. An editable accessibility node is not
     * required: terminal/browser input connections may expose no such node. */
    fun acceptsConnection(ownPackage: String, foregroundPackage: String?, editorPackage: String?, started: Boolean): Boolean =
        started && !foregroundPackage.isNullOrBlank() && foregroundPackage != ownPackage &&
            !editorPackage.isNullOrBlank() && editorPackage != ownPackage && editorPackage == foregroundPackage

    fun matchesTarget(requested: String?, packageName: String, title: String?): Boolean =
        requested.isNullOrBlank() || packageName.contains(requested.trim(), ignoreCase = true) ||
            title?.contains(requested.trim(), ignoreCase = true) == true

    /** ACTION_SET_TEXT fallback for old Android: preserve the current selection,
     * including reversed selection, rather than replacing all editor content. */
    fun insertText(current: String, selectionStart: Int, selectionEnd: Int, text: String): Pair<String, Int> {
        require(selectionStart in 0..current.length && selectionEnd in 0..current.length) {
            "The editor did not expose its cursor; focus a text field or use an Android 13+ input connection"
        }
        val start = minOf(selectionStart, selectionEnd)
        val end = maxOf(selectionStart, selectionEnd)
        return (current.substring(0, start) + text + current.substring(end)) to (start + text.length)
    }
}
