package dev.woi.woi

import org.junit.Assert.*
import org.junit.Test

class WoiScrollTest {
    private val viewport = WoiScrollBounds(40f, 120f, 1040f, 1650f)

    @Test fun downRevealsLaterContentByMovingTheFingerUp() {
        val down = WoiScrollPlan.stroke(viewport, "down", 1.0)
        val up = WoiScrollPlan.stroke(viewport, "up", 1.0)
        assertTrue(down.fromY > down.toY)
        assertTrue(up.fromY < up.toY)
        assertEquals(down.fromY, up.toY, 0.01f)
        assertEquals(down.toY, up.fromY, 0.01f)
        assertEquals(down.fromX, down.toX, 0.01f)
        for (stroke in listOf(down, up)) {
            assertTrue(viewport.contains(stroke.fromX, stroke.fromY))
            assertTrue(viewport.contains(stroke.toX, stroke.toY))
            assertTrue(stroke.fromY > viewport.top && stroke.toY > viewport.top)
            assertTrue(stroke.fromY < viewport.bottom && stroke.toY < viewport.bottom)
        }
    }

    @Test fun anchorsUsePhysicalOffsetBoundsAndStayInsideThePane() {
        val stroke = WoiScrollPlan.stroke(viewport, "down", 1.0, 320f, 1580f)
        assertEquals(320f, stroke.fromX, 0.01f)
        assertEquals(320f, stroke.toX, 0.01f)
        assertTrue(stroke.fromY < viewport.bottom)
        assertTrue(stroke.toY > viewport.top)
    }

    @Test fun fractionalViewportScrollHasProportionateTravel() {
        val full = WoiScrollPlan.stroke(viewport, "down", 1.0)
        val quarter = WoiScrollPlan.stroke(viewport, "down", 0.25)
        assertEquals((full.fromY - full.toY) / 4, quarter.fromY - quarter.toY, 0.01f)
        assertTrue(quarter.durationMs < full.durationMs)
        val right = WoiScrollPlan.stroke(viewport, "right", 0.5)
        assertTrue(right.fromX > right.toX)
        assertEquals(right.fromY, right.toY, 0.01f)
    }

    @Test fun invalidCoordinatesAmountsAndDirectionsNeverProduceAGesture() {
        val bad = listOf<() -> Unit>(
            { WoiScrollRequest("down", Double.NaN) },
            { WoiScrollRequest("down", 0.0) },
            { WoiScrollRequest("down", 6.0) },
            { WoiScrollRequest("north") },
            { WoiScrollRequest("down", x = 1f) },
            { WoiScrollRequest("down", x = Float.POSITIVE_INFINITY, y = 1f) },
            { WoiScrollPlan.stroke(viewport, "up", 1.0, 20f, 400f) },
            { WoiScrollPlan.stroke(WoiScrollBounds(0f, 0f, 20f, 900f), "down", 1.0) },
        )
        for (run in bad) {
            try { run(); fail("Expected invalid scroll to fail before dispatch") }
            catch (_: IllegalArgumentException) { }
        }
    }

    @Test fun onlyBareNavigationKeysMayBecomePageScrolling() {
        assertEquals(WoiScrollRequest("down"), WoiScrollPlan.fromKey("pagedown", emptySet()))
        assertEquals(WoiScrollRequest("up", 0.25), WoiScrollPlan.fromKey("up", emptySet()))
        assertNull(WoiScrollPlan.fromKey("pagedown", setOf("ctrl")))
        assertNull(WoiScrollPlan.fromKey("left", setOf("shift")))
        assertNull(WoiScrollPlan.fromKey("a", emptySet()))
        assertNull(WoiScrollPlan.fromKey("home", emptySet()))
    }
}
