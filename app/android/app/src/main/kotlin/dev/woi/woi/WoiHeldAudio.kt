package dev.woi.woi

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioPlaybackCaptureConfiguration
import android.media.AudioRecord
import android.media.AudioRecordingConfiguration
import android.media.MediaRecorder
import android.media.audiofx.AcousticEchoCanceler
import android.media.projection.MediaProjection
import android.os.Build
import android.os.SystemClock
import android.util.Log
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import kotlin.math.max
import kotlin.math.sqrt

/** Held recording: an AEC microphone plus capturable system/media audio.
 * No audio focus is requested. Existing projection consent stays available.
 * Native ownership is released before Dart may resume ordinary listening. */
object WoiHeldAudio {
    private const val RATE = 24000
    private const val FRAMES = 480
    private val lock = Any()
    private var sequence = 0
    @Volatile private var current: Capture? = null
    private val retiring = CopyOnWriteArrayList<Capture>()
    private var lastStatus: Map<String, Any?> = emptyMap()

    private class Capture(
        val id: Int,
        val projection: MediaProjection,
        val events: EventChannel.EventSink,
    ) {
        @Volatile var cancelled = false
        @Volatile var workerStarted = false
        val done = CountDownLatch(1)
        var mic: AudioRecord? = null
        var system: AudioRecord? = null
        var projectionCallback: MediaProjection.Callback? = null
        @Volatile var samples = 0L
        @Volatile var micPower = 0.0
        @Volatile var systemPower = 0.0
        @Volatile var reason: String? = null

        fun status(): Map<String, Any?> = mapOf(
            "generation" to id,
            "samples_per_source" to samples,
            "mic_rms" to if (samples == 0L) 0.0 else sqrt(micPower / samples) / 32768.0,
            "system_rms" to if (samples == 0L) 0.0 else sqrt(systemPower / samples) / 32768.0,
            "released" to (done.count == 0L),
            "error" to reason,
        )
    }

    private fun active(capture: Capture) = current === capture && !capture.cancelled
    fun isRequested() = current?.let { !it.cancelled } == true
    fun status(): Map<String, Any?> = (current?.status() ?: lastStatus) + mapOf(
        "active" to isRequested(),
        "closing" to retiring.count { it.done.count != 0L },
    )

    val handler = object : EventChannel.StreamHandler {
        override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
            stop()
            if (Build.VERSION.SDK_INT < 29) {
                events.error("held_audio", "System audio recording requires Android 10 or newer", null)
                return
            }
            val mp = WoiScreen.projectionForAudio()
            if (mp == null) {
                events.error("held_audio", "Allow screen and audio capture, then hold the microphone again", null)
                return
            }
            val capture = Capture(++sequence, mp, events)
            current = capture
            val callback = object : MediaProjection.Callback() {
                override fun onStop() = fail(capture, "System audio permission ended; recording cancelled")
            }
            capture.projectionCallback = callback
            try {
                mp.registerCallback(callback, WoiBridge.main)
                WoiForegroundService.startHeldAudio(WoiBridge.appContext)
                waitForForeground(capture, 0)
            } catch (error: Exception) {
                fail(capture, error.message ?: "System audio permission is unavailable")
            }
        }

        override fun onCancel(arguments: Any?) = stop()
    }

    private fun waitForForeground(capture: Capture, attempts: Int) {
        if (!active(capture)) return
        val error = WoiForegroundService.heldAudioForegroundError
        if (error != null) {
            fail(capture, "Microphone foreground service failed: $error")
            return
        }
        val previousReleased = retiring.all { it.done.count == 0L }
        if (previousReleased && WoiForegroundService.heldAudioForegroundReady) {
            capture.workerStarted = true
            Thread({ record(capture) }, "woi-held-audio").start()
        } else if (attempts >= 60) {
            fail(capture, if (previousReleased) "Microphone foreground service did not start"
                else "Previous audio capture has not finished closing")
        } else {
            WoiBridge.main.postDelayed({ waitForForeground(capture, attempts + 1) }, 50)
        }
    }

    @Suppress("MissingPermission")
    private fun record(capture: Capture) {
        if (Build.VERSION.SDK_INT < 29) return
        var microphone: AudioRecord? = null
        var playback: AudioRecord? = null
        var aec: AcousticEchoCanceler? = null
        var recordingCallback: AudioManager.AudioRecordingCallback? = null
        try {
            val min = AudioRecord.getMinBufferSize(RATE, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT)
            check(min > 0) { "24 kHz audio capture is unavailable" }
            val size = max(min * 4, FRAMES * 2 * 4)
            val format = AudioFormat.Builder()
                .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                .setSampleRate(RATE).setChannelMask(AudioFormat.CHANNEL_IN_MONO).build()
            val micRecord = AudioRecord.Builder()
                .setAudioSource(MediaRecorder.AudioSource.VOICE_COMMUNICATION)
                .setAudioFormat(format).setBufferSizeInBytes(size).build()
            microphone = micRecord
            val systemRecord = AudioRecord.Builder()
                .setAudioPlaybackCaptureConfig(AudioPlaybackCaptureConfiguration.Builder(capture.projection)
                    .addMatchingUsage(AudioAttributes.USAGE_MEDIA)
                    .addMatchingUsage(AudioAttributes.USAGE_GAME)
                    .addMatchingUsage(AudioAttributes.USAGE_UNKNOWN).build())
                .setAudioFormat(format).setBufferSizeInBytes(size).build()
            playback = systemRecord
            check(micRecord.state == AudioRecord.STATE_INITIALIZED &&
                systemRecord.state == AudioRecord.STATE_INITIALIZED) {
                "Both microphone and system audio must be available"
            }
            if (AcousticEchoCanceler.isAvailable()) {
                aec = AcousticEchoCanceler.create(micRecord.audioSessionId)
                aec?.enabled = true
            }
            val callback = object : AudioManager.AudioRecordingCallback() {
                override fun onRecordingConfigChanged(configs: MutableList<AudioRecordingConfiguration>) {
                    if (configs.any { it.clientAudioSessionId == micRecord.audioSessionId && it.isClientSilenced }) {
                        fail(capture, "Android silenced the microphone; recording cancelled")
                    }
                }
            }
            recordingCallback = callback
            micRecord.registerAudioRecordingCallback(WoiBridge.appContext.mainExecutor, callback)
            // Invalidation is volatile and precedes the stop worker's lock.
            // Stop completion waits for this entire worker's finally block.
            synchronized(lock) {
                if (!active(capture)) return
                capture.mic = micRecord
                capture.system = systemRecord
                micRecord.startRecording()
                if (!active(capture)) return
                systemRecord.startRecording()
            }
            check(micRecord.recordingState == AudioRecord.RECORDSTATE_RECORDING &&
                systemRecord.recordingState == AudioRecord.RECORDSTATE_RECORDING) {
                "Both microphone and system audio must be recording"
            }
            val micFrames = ShortArray(FRAMES)
            val systemFrames = ShortArray(FRAMES)
            val queued = AtomicInteger(0)
            var ready = false
            while (active(capture)) {
                readFrames(micRecord, micFrames, capture)
                readFrames(systemRecord, systemFrames, capture)
                if (!active(capture)) break
                if (!ready) {
                    check(micRecord.activeRecordingConfiguration?.isClientSilenced != true) {
                        "Android silenced the microphone; recording cancelled"
                    }
                    ready = true
                    WoiBridge.main.post {
                        if (active(capture)) capture.events.success(mapOf("ready" to true))
                    }
                }
                val mixed = ByteArray(FRAMES * 2)
                var micPower = 0.0
                var systemPower = 0.0
                for (i in 0 until FRAMES) {
                    val m = micFrames[i].toInt()
                    val s = systemFrames[i].toInt()
                    micPower += m.toDouble() * m
                    systemPower += s.toDouble() * s
                    val value = ((m + s) * 0.7071).toInt().coerceIn(-32768, 32767)
                    mixed[i * 2] = value.toByte()
                    mixed[i * 2 + 1] = (value shr 8).toByte()
                }
                capture.micPower += micPower
                capture.systemPower += systemPower
                capture.samples += FRAMES
                check(queued.incrementAndGet() <= 25) { "Audio delivery stalled; recording cancelled" }
                WoiBridge.main.post {
                    try {
                        if (active(capture)) capture.events.success(mixed)
                    } finally { queued.decrementAndGet() }
                }
            }
        } catch (error: Throwable) {
            if (active(capture)) fail(capture, error.message ?: "Audio recording failed")
        } finally {
            try { microphone?.stop() } catch (_: Exception) {}
            try { playback?.stop() } catch (_: Exception) {}
            recordingCallback?.let { callback ->
                try { microphone?.unregisterAudioRecordingCallback(callback) } catch (_: Exception) {}
            }
            try { aec?.release() } catch (_: Exception) {}
            try { microphone?.release() } catch (_: Exception) {}
            try { playback?.release() } catch (_: Exception) {}
            synchronized(lock) {
                capture.mic = null
                capture.system = null
            }
            capture.done.countDown()
            WoiBridge.main.post {
                retiring.remove(capture)
                lastStatus = capture.status()
                Log.i(WoiBridge.TAG, "held audio released: $lastStatus")
            }
        }
    }

    private fun readFrames(record: AudioRecord, target: ShortArray, capture: Capture) {
        var offset = 0
        while (offset < target.size && active(capture)) {
            val count = record.read(target, offset, target.size - offset, AudioRecord.READ_BLOCKING)
            check(count > 0) { "An audio source stopped ($count); recording cancelled" }
            offset += count
        }
    }

    private fun fail(capture: Capture, message: String) {
        WoiBridge.main.post {
            if (!active(capture)) return@post
            capture.reason = message
            capture.events.error("held_audio", message, null)
            requestStop(capture)
            capture.events.endOfStream()
        }
    }

    fun cancel(reason: String) {
        current?.let { fail(it, reason) }
    }

    private fun requestStop(capture: Capture) {
        if (capture.cancelled) return
        capture.cancelled = true
        if (current === capture) current = null
        capture.projectionCallback?.let { callback ->
            try { capture.projection.unregisterCallback(callback) } catch (_: Exception) {}
        }
        capture.projectionCallback = null
        retiring.addIfAbsent(capture)
        if (!capture.workerStarted) {
            capture.done.countDown()
            retiring.remove(capture)
            lastStatus = capture.status()
        } else {
            // Never join or call a potentially blocking driver stop on the UI
            // thread. Holding the lock closes the start-after-cancel window.
            Thread({
                val records = synchronized(lock) { Pair(capture.mic, capture.system) }
                try { records.first?.stop() } catch (_: Exception) {}
                try { records.second?.stop() } catch (_: Exception) {}
            }, "woi-held-stop").start()
        }
        WoiForegroundService.stopHeldAudio()
    }

    fun stop() {
        current?.let { requestStop(it) }
    }

    /** Dart awaits this acknowledgement before handing the microphone back. */
    fun stopAndReply(result: MethodChannel.Result) {
        stop()
        val pending = retiring.filter { it.done.count != 0L }
        if (pending.isEmpty()) {
            result.success(true)
            return
        }
        Thread({
            val deadline = SystemClock.elapsedRealtime() + 3000
            val released = pending.all {
                it.done.await(max(1L, deadline - SystemClock.elapsedRealtime()), TimeUnit.MILLISECONDS)
            }
            WoiBridge.main.post {
                if (released) result.success(true)
                else result.error("held_audio_stop", "Audio capture is still closing; microphone handoff was not confirmed", null)
            }
        }, "woi-held-reap").start()
    }
}
