package dev.woi.woi

import android.view.KeyEvent
import org.junit.Assert.*
import org.junit.Test

class WoiKeyboardTest {
    private class Sink : WoiKeySink {
        val events = mutableListOf<WoiKeyStroke>()
        val clears = mutableListOf<Int>()
        var onSend: ((WoiKeyStroke) -> Unit)? = null
        override fun send(stroke: WoiKeyStroke) { events.add(stroke); onSend?.invoke(stroke) }
        override fun clearMetaKeyStates(states: Int) { clears.add(states) }
    }

    private fun failure(block: () -> Unit): Throwable {
        try { block() } catch (error: Throwable) { return error }
        throw AssertionError("Expected failure")
    }

    @Test fun combinedModifiersSurroundTheActualKeyAndReleaseInReverseOrder() {
        val sink = Sink()
        WoiKeyboard.dispatch(WoiKeyOperation.Chord("k", setOf("ctrl", "alt", "shift", "super")), sink) { }
        assertEquals(listOf(KeyEvent.KEYCODE_CTRL_LEFT, KeyEvent.KEYCODE_SHIFT_LEFT,
            KeyEvent.KEYCODE_ALT_LEFT, KeyEvent.KEYCODE_META_LEFT, KeyEvent.KEYCODE_K,
            KeyEvent.KEYCODE_K, KeyEvent.KEYCODE_META_LEFT, KeyEvent.KEYCODE_ALT_LEFT,
            KeyEvent.KEYCODE_SHIFT_LEFT, KeyEvent.KEYCODE_CTRL_LEFT), sink.events.map { it.keyCode })
        assertEquals(List(5) { KeyEvent.ACTION_DOWN } + List(5) { KeyEvent.ACTION_UP }, sink.events.map { it.action })
        val actualKey = sink.events.filter { it.keyCode == KeyEvent.KEYCODE_K }
        assertEquals(listOf(WoiKeyboard.modifierMask, WoiKeyboard.modifierMask), actualKey.map { it.metaState })
        assertEquals(0, sink.events.last().metaState)
        assertEquals(listOf(WoiKeyboard.modifierMask, WoiKeyboard.modifierMask), sink.clears)
    }

    @Test fun explicitControlCAndShiftControlCAreDifferentRealChords() {
        val plain = Sink(); val shifted = Sink()
        WoiKeyboard.dispatch(WoiKeyOperation.Chord("c", setOf("ctrl")), plain) { }
        WoiKeyboard.dispatch(WoiKeyOperation.Chord("c", setOf("ctrl", "shift")), shifted) { }
        assertEquals(4, plain.events.size)
        assertEquals(6, shifted.events.size)
        assertEquals(0, plain.events.first { it.keyCode == KeyEvent.KEYCODE_C }.metaState and KeyEvent.META_SHIFT_ON)
        assertTrue(shifted.events.first { it.keyCode == KeyEvent.KEYCODE_C }.metaState and KeyEvent.META_SHIFT_ON != 0)
    }

    @Test fun bareModifierTapCarriesDownStateAndReleasesIt() {
        for ((name, code) in listOf("ctrl" to KeyEvent.KEYCODE_CTRL_LEFT, "shift" to KeyEvent.KEYCODE_SHIFT_LEFT,
            "alt" to KeyEvent.KEYCODE_ALT_LEFT, "super" to KeyEvent.KEYCODE_META_LEFT)) {
            val sink = Sink()
            WoiKeyboard.dispatch(WoiKeyOperation.Chord(name, emptySet()), sink) { }
            assertEquals(listOf(code, code), sink.events.map { it.keyCode })
            assertNotEquals(0, sink.events.first().metaState)
            assertEquals(0, sink.events.last().metaState)
        }
    }

    @Test fun keyDownFailureStillReleasesTheKeyAndEveryModifier() {
        val sink = Sink()
        val problem = IllegalStateException("connection stopped after key down")
        sink.onSend = { if (it.action == KeyEvent.ACTION_DOWN && it.keyCode == KeyEvent.KEYCODE_V) throw problem }
        assertSame(problem, failure { WoiKeyboard.dispatch(WoiKeyOperation.Chord("v", setOf("ctrl", "alt")), sink) { } })
        assertEquals(listOf(KeyEvent.KEYCODE_V, KeyEvent.KEYCODE_ALT_LEFT, KeyEvent.KEYCODE_CTRL_LEFT),
            sink.events.filter { it.action == KeyEvent.ACTION_UP }.map { it.keyCode })
        assertEquals(0, sink.events.last().metaState)
        assertEquals(2, sink.clears.size)
    }

    @Test fun cleanupContinuesEvenWhenEveryReleaseThrowsTheSameFailure() {
        val sink = Sink()
        val problem = IllegalStateException("disconnected")
        sink.onSend = { if (it.keyCode == KeyEvent.KEYCODE_X || it.action == KeyEvent.ACTION_UP) throw problem }
        assertSame(problem, failure { WoiKeyboard.dispatch(WoiKeyOperation.Chord("x", setOf("ctrl", "shift")), sink) { } })
        assertEquals(listOf(KeyEvent.KEYCODE_X, KeyEvent.KEYCODE_SHIFT_LEFT, KeyEvent.KEYCODE_CTRL_LEFT),
            sink.events.filter { it.action == KeyEvent.ACTION_UP }.map { it.keyCode })
        assertEquals(2, sink.clears.size)
    }

    @Test fun cancellationBeforeDispatchEmitsNothing() {
        val sink = Sink()
        failure { WoiKeyboard.dispatch(WoiKeyOperation.Chord("a", setOf("ctrl")), sink) { error("user took control") } }
        assertTrue(sink.events.isEmpty())
        assertTrue(sink.clears.isEmpty())
    }

    @Test fun focusChangeAfterModifierDownReleasesWithoutSendingTheMainKey() {
        val sink = Sink()
        var focused = true
        sink.onSend = { if (it.action == KeyEvent.ACTION_DOWN) focused = false }
        failure { WoiKeyboard.dispatch(WoiKeyOperation.Chord("a", setOf("ctrl", "shift")), sink) { check(focused) } }
        assertEquals(listOf(KeyEvent.KEYCODE_CTRL_LEFT, KeyEvent.KEYCODE_CTRL_LEFT), sink.events.map { it.keyCode })
        assertEquals(listOf(KeyEvent.ACTION_DOWN, KeyEvent.ACTION_UP), sink.events.map { it.action })
        assertEquals(0, sink.events.last().metaState)
    }

    @Test fun completeBatchIsValidatedBeforeExecutionAndUnsupportedKeysAreRejected() {
        val raw = listOf(
            mapOf("type" to "key", "key" to "a", "modifiers" to listOf("ctrl")),
            mapOf("type" to "key", "key" to "f24", "modifiers" to emptyList<String>()),
        )
        assertTrue(failure { WoiKeyboard.parse(raw) } is IllegalArgumentException)
        assertTrue(failure { WoiKeyboard.keyCode("🙂") } is IllegalArgumentException)
        assertTrue(failure { WoiKeyboard.parse(listOf(mapOf("type" to "key", "key" to "v", "modifiers" to listOf("ctrl", "fn")))) } is IllegalArgumentException)
        assertTrue(failure { WoiKeyboard.parse(listOf(mapOf("type" to "key", "key" to "ctrl", "modifiers" to listOf("alt")))) } is IllegalArgumentException)
    }

    @Test fun sdkGateAllowsSemanticEditsButNotRawChordsOnOlderAndroid() {
        val edit = listOf(WoiKeyOperation.Edit("copy"))
        val raw = listOf(WoiKeyOperation.Chord("c", setOf("ctrl")))
        WoiKeyboard.validateSdk(edit, 24)
        assertTrue(failure { WoiKeyboard.validateSdk(raw, 32) } is IllegalArgumentException)
        WoiKeyboard.validateSdk(raw, 33)
    }

    @Test fun systemNavigationCannotPartiallyRunBeforeEditorKeys() {
        val mixed = listOf(mapOf("type" to "global", "name" to "home"),
            mapOf("type" to "key", "key" to "c", "modifiers" to listOf("ctrl")))
        assertTrue(failure { WoiKeyboard.parse(mixed) } is IllegalArgumentException)
        assertEquals(2, WoiKeyboard.parse(listOf(mapOf("type" to "global", "name" to "back"),
            mapOf("type" to "global", "name" to "home"))).size)
    }

    @Test fun editorConnectionRequiresCurrentExternalPackageAndStartedInput() {
        assertTrue(WoiKeyboard.acceptsConnection("woi", "browser", "browser", true))
        assertFalse(WoiKeyboard.acceptsConnection("woi", "woi", "woi", true))
        assertFalse(WoiKeyboard.acceptsConnection("woi", "browser", "woi", true))
        assertFalse(WoiKeyboard.acceptsConnection("woi", "browser", "terminal", true))
        assertFalse(WoiKeyboard.acceptsConnection("woi", "browser", "browser", false))
        assertFalse(WoiKeyboard.acceptsConnection("woi", null, "browser", true))
    }

    @Test fun explicitTargetMustMatchCurrentPackageOrTitle() {
        assertTrue(WoiKeyboard.matchesTarget("Chrome", "com.android.chrome", "Example"))
        assertTrue(WoiKeyboard.matchesTarget("notes", "com.editor", "Notes – draft"))
        assertFalse(WoiKeyboard.matchesTarget("terminal", "com.android.chrome", "Example"))
        assertTrue(WoiKeyboard.matchesTarget(null, "com.editor", null))
    }

    @Test fun textInsertionPreservesUnicodeAndReversedSelections() {
        val text = "literal + \"quote\"\n雪🙂"
        assertEquals(("prefix " + text + " suffix") to (7 + text.length),
            WoiKeyboard.insertText("prefix OLD suffix", 10, 7, text))
        assertEquals("ab🙂cd" to 4, WoiKeyboard.insertText("abcd", 2, 2, "🙂"))
        assertEquals(text to text.length, WoiKeyboard.insertText("", 0, 0, text))
        assertTrue(failure { WoiKeyboard.insertText("existing", -1, -1, "new") } is IllegalArgumentException)
    }
    @Test fun stopBetweenBatchStepsPreventsTheSecondChord() {
        val epoch = WoiKeyboardEpoch()
        val request = epoch.capture()
        val first = Sink(); val second = Sink()
        WoiKeyboard.dispatch(WoiKeyOperation.Chord("a", setOf("ctrl")), first) { epoch.check(request) }
        epoch.cancel()
        assertTrue(failure {
            WoiKeyboard.dispatch(WoiKeyOperation.Chord("c", setOf("ctrl")), second) { epoch.check(request) }
        } is IllegalStateException)
        assertEquals(4, first.events.size)
        assertTrue(second.events.isEmpty())
        assertTrue(second.clears.isEmpty())
    }

    @Test fun stopDuringModifierPressStillReleasesThePressedModifier() {
        val epoch = WoiKeyboardEpoch()
        val request = epoch.capture()
        val sink = Sink()
        sink.onSend = { if (it.action == KeyEvent.ACTION_DOWN) epoch.cancel() }
        failure { WoiKeyboard.dispatch(WoiKeyOperation.Chord("k", setOf("ctrl", "shift", "alt")), sink) { epoch.check(request) } }
        assertEquals(listOf(KeyEvent.KEYCODE_CTRL_LEFT, KeyEvent.KEYCODE_CTRL_LEFT), sink.events.map { it.keyCode })
        assertEquals(listOf(KeyEvent.ACTION_DOWN, KeyEvent.ACTION_UP), sink.events.map { it.action })
        assertEquals(0, sink.events.last().metaState)
        assertEquals(2, sink.clears.size)
    }

    @Test fun stoppedFocusHandoffCannotStartLateButANewApprovedRequestCan() {
        val epoch = WoiKeyboardEpoch()
        // Capture when the request enters, before its delayed focus callback.
        val waitingForFocus = epoch.capture()
        epoch.cancel()
        val approvedRequest = epoch.capture()
        val stale = Sink(); val approved = Sink()
        failure { WoiKeyboard.dispatch(WoiKeyOperation.Chord("x", emptySet()), stale) { epoch.check(waitingForFocus) } }
        WoiKeyboard.dispatch(WoiKeyOperation.Chord("v", setOf("ctrl")), approved) { epoch.check(approvedRequest) }
        assertTrue(stale.events.isEmpty())
        assertEquals(listOf(KeyEvent.KEYCODE_CTRL_LEFT, KeyEvent.KEYCODE_V, KeyEvent.KEYCODE_V, KeyEvent.KEYCODE_CTRL_LEFT),
            approved.events.map { it.keyCode })
    }

}
