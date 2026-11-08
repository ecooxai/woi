package dev.woi.woi

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class WoiMediaReferenceCursorTest {
    @Test fun measuredTimestampJitterDoesNotSkipOrReplayReferenceSamples() {
        val cursor = WoiMediaReferenceCursor()
        // Jumps observed with uninterrupted PCM, zero playback underruns and
        // complete reference coverage on the physical Android media route.
        val jitter = longArrayOf(0, -693, 217, -84, 131, -26, 72, -112)
        val stream = ArrayList<Long>()
        jitter.forEachIndexed { block, offset ->
            val start = cursor.next(10000L + block * 1920 + offset, 1920)!!
            repeat(1920) { stream.add(start + it) }
        }
        assertEquals((10000L until 10000L + jitter.size * 1920).toList(), stream)
    }

    @Test fun waitsForAnAnchorWithoutConsumingReferenceTime() {
        val cursor = WoiMediaReferenceCursor()
        assertNull(cursor.next(null, 1920))
        assertNull(cursor.next(null, 1920))
        assertEquals(-227L, cursor.next(-227, 1920))
        assertEquals(1693L, cursor.next(null, 1920))
    }

    @Test fun resumeReseedsInExistingTrackFrameNumbering() {
        val cursor = WoiMediaReferenceCursor()
        assertEquals(48000L, cursor.next(48000, 1920))
        cursor.reset()
        assertNull(cursor.next(null, 1920))
        assertEquals(72000L, cursor.next(72000, 1920))
        assertEquals(73920L, cursor.next(72080, 1920))
    }

    @Test fun flushStartsNewTrackFrameNumbering() {
        val cursor = WoiMediaReferenceCursor()
        cursor.next(96000, 1920)
        cursor.reset()
        assertEquals(-480L, cursor.next(-480, 480))
        assertEquals(0L, cursor.next(800, 960))
        assertEquals(960L, cursor.next(2000, 1920))
    }

    @Test fun onlyAnExplicitEpochResetCanMoveAnEstablishedCursor() {
        val cursor = WoiMediaReferenceCursor()
        assertEquals(0L, cursor.next(0, 480))
        assertEquals(480L, cursor.next(2400000, 480))
        cursor.reset()
        assertEquals(2400480L, cursor.next(2400480, 480))
    }
}
