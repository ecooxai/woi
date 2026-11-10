package dev.woi.woi

import org.junit.Assert.*
import org.junit.Test

class WoiTouchKeyboardTest {
    @Test fun lettersAreLiteralButModifiedShortcutsPreserveAllModifiers() {
        assertEquals(WoiTouchKey.Text("a"), WoiTouchKeys.input("a", emptySet()))
        assertEquals(WoiTouchKey.Text("A"), WoiTouchKeys.input("a", setOf("shift")))
        assertEquals(WoiTouchKey.Text("!"), WoiTouchKeys.input("1", setOf("shift")))
        assertEquals(WoiTouchKey.Text(" "), WoiTouchKeys.input("space", emptySet()))
        assertEquals(WoiTouchKey.Chord("a", setOf("ctrl", "alt", "shift", "super")),
            WoiTouchKeys.input("a", setOf("ctrl", "alt", "shift", "super")))
        assertEquals(WoiTouchKey.Chord("period", setOf("ctrl")), WoiTouchKeys.input(".", setOf("ctrl")))
    }

    @Test fun navigationDoesNotBecomeLiteralWords() {
        for (key in listOf("tab", "escape", "enter", "home", "end", "pageup", "pagedown", "left", "right", "backspace", "f12")) {
            assertEquals(WoiTouchKey.Chord(key, emptySet()), WoiTouchKeys.input(key, emptySet()))
        }
    }

    @Test fun plainDeletionPreservesTheRestOfTheEditorAndWholeUnicodeCharacters() {
        assertEquals(WoiKeyboard.TextEdit("A雪B", 1, 1), WoiKeyboard.textKey("A🙂雪B", 3, 3, "backspace", emptySet()))
        assertEquals(WoiKeyboard.TextEdit("AB", 1, 1), WoiKeyboard.textKey("A🙂雪B", 1, 4, "delete", emptySet()))
        assertEquals(WoiKeyboard.TextEdit("A🙂B", 3, 3), WoiKeyboard.textKey("A🙂雪B", 3, 3, "delete", emptySet()))
    }

    @Test fun caretKeysKeepLineBoundariesAndShiftSelection() {
        assertEquals(WoiKeyboard.TextEdit("ab\ncd", 3, 3), WoiKeyboard.textKey("ab\ncd", 4, 4, "home", emptySet()))
        assertEquals(WoiKeyboard.TextEdit("ab\ncd", 5, 5), WoiKeyboard.textKey("ab\ncd", 4, 4, "end", emptySet()))
        assertEquals(WoiKeyboard.TextEdit("A🙂B", 3, 1), WoiKeyboard.textKey("A🙂B", 3, 3, "left", setOf("shift")))
        assertNull(WoiKeyboard.textKey("abc", 3, 3, "backspace", setOf("ctrl")))
        assertNull(WoiKeyboard.textKey("abc", 3, 3, "up", emptySet()))
    }
}
