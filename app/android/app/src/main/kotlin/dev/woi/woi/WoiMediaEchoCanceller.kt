package dev.woi.woi

import android.media.AudioRecord
import android.media.AudioTimestamp
import android.media.AudioTrack

/**
 * Software acoustic echo cancellation for MODE_NORMAL / USAGE_MEDIA.
 *
 * A shared AudioRecord/AudioTrack session does not make Android's hardware AEC
 * receive media playback. This feeds the actual PCM accepted by AudioTrack to
 * SpeexDSP. The two monotonic audio clocks seed a continuous sample cursor;
 * their normal timestamp jitter must not insert or drop reference samples.
 * No app UI, input connection, network, or microphone transmission gate is used.
 * Only Woi's own PCM is a reference; unrelated apps retain Android audio focus
 * behavior. Each microphone owns one instance, closed only after its reader exits.
 */
class WoiMediaEchoCanceller : AutoCloseable {
    companion object {
        const val RATE = 24000
        // 20 ms gives ten adaptive partitions for the 200 ms room tail.
        // The finer 10 ms / twenty-partition configuration stalled on a valid
        // colored, multi-reflection vector; keep that vector in both regressions.
        private const val FRAME = RATE / 50
        private const val TAIL_MS = 200
        private const val CAPACITY = RATE * 4
        // Leave a causal margin while AudioTrack's timestamp starts reporting.
        // Once clocks settle the adaptive filter learns this fixed lead too.
        private const val REFERENCE_LEAD_NS = 50_000_000L
        init { System.loadLibrary("woi_audio_dsp") }
    }

    private var handle = nativeCreate(RATE, FRAME, RATE * TAIL_MS / 1000).also {
        check(it != 0L) { "Media echo canceller could not be initialized" }
    }
    private val rendered = ShortArray(CAPACITY)
    private val frameTags = LongArray(CAPACITY) { Long.MIN_VALUE }
    private var anchorFrame = 0L
    private var anchorNanos = 0L
    private var endFrame = 0L
    private var captureFrames = 0L
    private var outputEpoch = false
    private var epochStartedNanos = 0L
    private var outputUnderruns = -1
    private val referenceCursor = WoiMediaReferenceCursor()
    // Aggregate device checks observe the exact range used, never microphone PCM.
    private var lastReferenceFrame = Long.MIN_VALUE
    private val captureTimestamp = AudioTimestamp()
    private val outputTimestamp = AudioTimestamp()

    /** New/flush/resumed playback starts a fresh clock-alignment epoch. */
    @Synchronized
    fun beginOutput() {
        frameTags.fill(Long.MIN_VALUE)
        anchorNanos = 0L
        anchorFrame = 0L
        endFrame = 0L
        outputEpoch = true
        epochStartedNanos = System.nanoTime()
        outputUnderruns = -1
        // Keep the DSP's delayed microphone overlap and learned room response.
        // Resetting native state here would drop 20 ms at every reply boundary.
        referenceCursor.reset()
    }

    /** Called after a successful write, with exactly the bytes Android accepted. */
    @Synchronized
    fun rendered(track: AudioTrack, pcm: ByteArray, offset: Int, byteCount: Int, firstFrame: Long) {
        if (handle == 0L || byteCount <= 0) return
        if (!outputEpoch) beginOutput()
        val now = System.nanoTime()
        val underruns = try { track.underrunCount } catch (_: Exception) { outputUnderruns }
        if (outputUnderruns >= 0 && underruns > outputUnderruns) {
            // A real playout gap changes the mapping from track frames to time.
            // Reseed once at that boundary, never for ordinary timestamp jitter.
            referenceCursor.reset()
            epochStartedNanos = now
        }
        outputUnderruns = underruns
        val timestampOk = try { track.getTimestamp(outputTimestamp) } catch (_: Exception) { false }
        if (timestampOk && outputTimestamp.nanoTime >= epochStartedNanos &&
            now - outputTimestamp.nanoTime in -100_000_000L..250_000_000L) {
            anchorFrame = outputTimestamp.framePosition
            anchorNanos = outputTimestamp.nanoTime
        } else {
            // playbackHeadPosition excludes the frames still queued for the HAL.
            // A bounded hardware latency estimate is used only until timestamped
            // playout is available, including after a long idle pause.
            anchorFrame = track.playbackHeadPosition.toLong() and 0xffffffffL
            anchorNanos = now + 40_000_000L
        }
        for (i in 0 until byteCount / 2) {
            val frame = firstFrame + i
            val slot = (frame % CAPACITY).toInt()
            val p = offset + i * 2
            rendered[slot] = ((pcm[p].toInt() and 255) or (pcm[p + 1].toInt() shl 8)).toShort()
            frameTags[slot] = frame
        }
        endFrame = maxOf(endFrame, firstFrame + byteCount / 2)
    }

    /** Drop queued samples on cancellation but keep the already audible tail. */
    @Synchronized
    fun stopOutput(track: AudioTrack) {
        if (!outputEpoch) return
        val now = System.nanoTime()
        val timestampOk = try { track.getTimestamp(outputTimestamp) } catch (_: Exception) { false }
        if (timestampOk && outputTimestamp.nanoTime > 0 && now - outputTimestamp.nanoTime in -100_000_000L..250_000_000L) {
            anchorFrame = outputTimestamp.framePosition
            anchorNanos = outputTimestamp.nanoTime
        }
        val played = track.playbackHeadPosition.toLong() and 0xffffffffL
        endFrame = minOf(endFrame, played)
        outputEpoch = false
    }

    /** Reader thread: process each complete capture block before it reaches Dart. */
    @Synchronized
    fun capture(record: AudioRecord, pcm: ByteArray): ByteArray {
        if (handle == 0L || pcm.isEmpty()) return pcm
        val count = pcm.size / 2
        val firstCaptureFrame = captureFrames
        captureFrames += count
        val now = System.nanoTime()
        val ok = try {
            record.getTimestamp(captureTimestamp, AudioTimestamp.TIMEBASE_MONOTONIC) == AudioRecord.SUCCESS
        } catch (_: Exception) { false }
        val startNanos = if (ok && captureTimestamp.nanoTime > 0) {
            captureTimestamp.nanoTime + (firstCaptureFrame - captureTimestamp.framePosition) * 1_000_000_000L / RATE
        } else now - count * 1_000_000_000L / RATE
        val reference = ByteArray(pcm.size)
        val prediction = if (anchorNanos == 0L) null else
            anchorFrame + (startNanos + REFERENCE_LEAD_NS - anchorNanos) * RATE / 1_000_000_000L
        val firstRenderFrame = referenceCursor.next(prediction, count)
        lastReferenceFrame = firstRenderFrame ?: Long.MIN_VALUE
        if (firstRenderFrame != null) {
            for (i in 0 until count) {
                val frame = firstRenderFrame + i
                if (frame < 0 || frame >= endFrame) continue
                val slot = (frame % CAPACITY).toInt()
                if (frameTags[slot] != frame) continue
                val s = rendered[slot].toInt()
                reference[i * 2] = s.toByte()
                reference[i * 2 + 1] = (s shr 8).toByte()
            }
        }
        // Always retain the same 20 ms overlap/add latency, including silent
        // render intervals; switching to raw PCM would duplicate/drop samples
        // at every reply boundary. Noise suppression/AGC are disabled in C.
        return nativeProcess(handle, pcm, reference)
    }

    @Synchronized
    override fun close() {
        if (handle == 0L) return
        nativeDestroy(handle)
        handle = 0L
        frameTags.fill(Long.MIN_VALUE)
    }

    private external fun nativeCreate(rate: Int, frame: Int, tail: Int): Long
    private external fun nativeProcess(handle: Long, capture: ByteArray, reference: ByteArray): ByteArray
    private external fun nativeReset(handle: Long)
    private external fun nativeDestroy(handle: Long)
}
