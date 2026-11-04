package dev.woi.woi

import android.annotation.SuppressLint
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.AudioTrack
import android.media.MediaPlayer
import android.media.MediaRecorder
import android.media.audiofx.AcousticEchoCanceler
import android.media.audiofx.NoiseSuppressor
import android.util.Log
import io.flutter.plugin.common.EventChannel
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit

/**
 * PCM16 / 24 kHz / mono capture and playback for the direct realtime
 * backends (gpt-live uses flutter_webrtc's own audio device module).
 *
 * Capture uses the VOICE_COMMUNICATION source with the platform echo
 * canceller and noise suppressor. The player pauses its AudioTrack after a
 * second without data so an idle Woi keeps the audio HAL asleep.
 */
object WoiAudio {
    private const val RATE = 24000
    // 80 ms: each chunk costs a thread wakeup, a platform-channel hop and a
    // WebSocket message; 40 ms chunks made listening ~18% CPU, 80 ms ~12%.
    // Server VAD and the local barge-in detector see audio <= 40 ms later.
    private const val CHUNK_BYTES = RATE * 2 * 80 / 1000

    // ---------------- microphone ----------------

    @Volatile private var record: AudioRecord? = null
    private var micThread: Thread? = null
    private var aec: AcousticEchoCanceler? = null
    private var ns: NoiseSuppressor? = null

    val micHandler = object : EventChannel.StreamHandler {
        override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
            try {
                startMic(events)
            } catch (e: Throwable) {
                events.error("mic", e.message ?: e.toString(), null)
            }
        }

        override fun onCancel(arguments: Any?) = stopMic()
    }

    @SuppressLint("MissingPermission")
    private fun startMic(events: EventChannel.EventSink) {
        stopMic()
        val min = AudioRecord.getMinBufferSize(RATE, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT)
        val rec = AudioRecord(
            MediaRecorder.AudioSource.VOICE_COMMUNICATION, RATE,
            AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT, maxOf(min, CHUNK_BYTES * 4)
        )
        if (rec.state != AudioRecord.STATE_INITIALIZED) {
            rec.release()
            throw IllegalStateException("AudioRecord not initialized (RECORD_AUDIO granted?)")
        }
        if (AcousticEchoCanceler.isAvailable()) aec = AcousticEchoCanceler.create(rec.audioSessionId)?.apply { enabled = true }
        if (NoiseSuppressor.isAvailable()) ns = NoiseSuppressor.create(rec.audioSessionId)?.apply { enabled = true }
        rec.startRecording()
        record = rec
        micThread = Thread({
            val buf = ByteArray(CHUNK_BYTES)
            while (record === rec) {
                var off = 0
                while (off < buf.size && record === rec) {
                    val n = rec.read(buf, off, buf.size - off)
                    if (n <= 0) break
                    off += n
                }
                if (off <= 0 || record !== rec) {
                    if (off < 0) break
                    continue
                }
                val chunk = buf.copyOf(off)
                WoiBridge.main.post { if (record === rec) events.success(chunk) }
            }
        }, "woi-mic").apply {
            priority = Thread.MAX_PRIORITY
            start()
        }
        Log.i(WoiBridge.TAG, "mic started aec=${aec?.enabled} ns=${ns?.enabled}")
        // The system silences capture (zeros, no error) for apps that are
        // neither in front nor running a microphone foreground service.
        WoiBridge.main.postDelayed({
            if (record === rec) {
                val silenced = rec.activeRecordingConfiguration?.isClientSilenced
                if (silenced == true) Log.w(WoiBridge.TAG, "mic is silenced by the system (background without a microphone FGS?)")
                else Log.i(WoiBridge.TAG, "mic capturing (silenced=$silenced)")
            }
        }, 1500)
    }

    private fun stopMic() {
        val rec = record ?: return
        record = null
        try { rec.stop() } catch (_: Exception) {}
        micThread?.join(200)
        micThread = null
        aec?.release(); aec = null
        ns?.release(); ns = null
        rec.release()
    }

    // ---------------- streaming player ----------------

    private var track: AudioTrack? = null
    private var writer: Thread? = null
    private val queue = LinkedBlockingQueue<ByteArray>()
    @Volatile private var generation = 0
    @Volatile private var paused = true
    private val trackLock = Object()

    fun playerOpen(): Boolean {
        if (track != null) return true
        val min = AudioTrack.getMinBufferSize(RATE, AudioFormat.CHANNEL_OUT_MONO, AudioFormat.ENCODING_PCM_16BIT)
        val t = AudioTrack.Builder()
            .setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_ASSISTANT)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                    .build()
            )
            .setAudioFormat(
                AudioFormat.Builder().setSampleRate(RATE).setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                    .setEncoding(AudioFormat.ENCODING_PCM_16BIT).build()
            )
            .setBufferSizeInBytes(maxOf(min, RATE * 2 / 10))
            .setTransferMode(AudioTrack.MODE_STREAM)
            .setPerformanceMode(AudioTrack.PERFORMANCE_MODE_LOW_LATENCY)
            .build()
        track = t
        paused = true
        writer = Thread({
            var lastData = System.nanoTime()
            while (track === t) {
                val chunk = queue.poll(250, TimeUnit.MILLISECONDS)
                if (chunk == null) {
                    if (!paused && System.nanoTime() - lastData > 1_000_000_000L) {
                        synchronized(trackLock) { if (track === t) { t.pause(); paused = true } }
                    }
                    continue
                }
                val gen = generation
                synchronized(trackLock) {
                    if (track !== t) return@Thread
                    if (paused) { t.play(); paused = false }
                }
                var off = 0
                // 20 ms slices so a stop() lands quickly.
                while (off < chunk.size && gen == generation && track === t) {
                    val n = t.write(chunk, off, minOf(960, chunk.size - off))
                    if (n <= 0) break
                    off += n
                }
                lastData = System.nanoTime()
            }
        }, "woi-player").apply { start() }
        return true
    }

    fun playerWrite(pcm: ByteArray) {
        if (track == null) playerOpen()
        queue.offer(pcm)
    }

    fun playerStop() {
        generation++
        queue.clear()
        val t = track ?: return
        synchronized(trackLock) {
            try {
                t.pause()
                t.flush()
                paused = true
            } catch (_: Exception) {}
        }
    }

    fun playerClose() {
        val t = track ?: return
        track = null
        generation++
        queue.clear()
        writer?.join(300)
        writer = null
        synchronized(trackLock) {
            try { t.stop() } catch (_: Exception) {}
            t.release()
        }
    }

    // ---------------- clips (wav files) ----------------

    private val clips = HashMap<Int, MediaPlayer>()
    private var nextClip = 1

    fun clipPlay(path: String): Int {
        val id = nextClip++
        val mp = MediaPlayer()
        mp.setAudioAttributes(
            AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_MEDIA)
                .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH).build()
        )
        mp.setDataSource(path)
        mp.setOnCompletionListener { finishClip(id) }
        mp.setOnErrorListener { _, _, _ -> finishClip(id); true }
        mp.prepare()
        mp.start()
        clips[id] = mp
        return id
    }

    fun clipStop(id: Int) = finishClip(id)

    private fun finishClip(id: Int) {
        val mp = clips.remove(id) ?: return
        try { mp.stop() } catch (_: Exception) {}
        mp.release()
        WoiBridge.emit(mapOf("type" to "clipDone", "id" to id))
    }
}
