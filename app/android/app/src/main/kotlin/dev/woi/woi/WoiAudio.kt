package dev.woi.woi

import android.annotation.SuppressLint
import android.content.Context
import android.media.AudioAttributes
import android.media.AudioManager
import android.media.AudioRecordingConfiguration
import android.os.Build
import android.os.SystemClock
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
 * The route (WoiAudioRoute) picks the call path (default: call mode,
 * VOICE_COMMUNICATION capture, voice-call playback) or the media path. The
 * mic yields to other apps: while another app records, Woi's AudioRecord is
 * released and the call mode dropped; it comes back when that recording
 * ends. The player pauses its AudioTrack after a second without data so an
 * idle Woi keeps the audio HAL asleep.
 */
object WoiAudio {
    private const val RATE = 24000
    // 80 ms: each chunk costs a thread wakeup, a platform-channel hop and a
    // WebSocket message; 40 ms chunks made listening ~18% CPU, 80 ms ~12%.
    // Server VAD and the local barge-in detector see audio <= 40 ms later.
    private const val CHUNK_BYTES = RATE * 2 * 80 / 1000
    // MediaRecorder.AudioSource.HOTWORD (@SystemApi): always-on hotword
    // clients do not count as "another app using the mic".
    private const val HOTWORD_SOURCE = 1999

    // ---------------- microphone ----------------

    @Volatile private var record: AudioRecord? = null

    /** What the last mic open got, for the settings / diagnostics. */
    @Volatile var status = "not started"
        private set
    private var micThread: Thread? = null
    private var aec: AcousticEchoCanceler? = null
    private var ns: NoiseSuppressor? = null

    // The Dart side's mic stream: open while [micSink] is set, even when the
    // recorder itself is released because another app is recording.
    private var micSink: EventChannel.EventSink? = null
    private var micAec = true
    private var ourSession = 0
    private var yielded = false
    // One self-heal restart per mic open (see the dead-mic check below).
    private var healed = false
    private var healNoted = false
    @Volatile private var micZeros = false
    private var recCallback: AudioManager.AudioRecordingCallback? = null

    val micHandler = object : EventChannel.StreamHandler {
        override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
            try {
                val args = arguments as? Map<*, *>
                val aecArg = args?.get("aec") as? Boolean ?: true
                val routeArg = args?.get("route") as? String
                WoiBridge.appContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
                    .putBoolean(KEY_AEC, aecArg).putString(KEY_ROUTE, routeArg).apply()
                if (adoptEarly(events, aecArg, routeArg)) return
                micAec = aecArg
                if (WoiAudioRoute.setRoute(routeArg)) playerClose()
                openMic(events)
            } catch (e: Throwable) {
                events.error("mic", e.message ?: e.toString(), null)
            }
        }

        override fun onCancel(arguments: Any?) = closeMic()
    }

    private fun am(): AudioManager = WoiBridge.appContext.getSystemService(Context.AUDIO_SERVICE) as AudioManager

    private fun openMic(events: EventChannel.EventSink) {
        closeMic()
        micSink = events
        healed = false
        healNoted = false
        val cb = object : AudioManager.AudioRecordingCallback() {
            override fun onRecordingConfigChanged(configs: MutableList<AudioRecordingConfiguration>) = evaluate(configs)
        }
        recCallback = cb
        am().registerAudioRecordingCallback(cb, WoiBridge.main)
        if (othersRecording(am().activeRecordingConfigurations)) {
            yield()
        } else {
            startRecord()
        }
    }

    // ---------------- early capture (assist activation) ----------------
    //
    // The assist gesture starts recording right away, before Dart (cold start:
    // engine + controller init, ~1-2 s) opens its mic stream. The chunks wait
    // here; the Dart mic open adopts the running recorder and gets them first,
    // in order, then the live chunks: no gap, no duplicate. Dart buffers them
    // until the voice session is up (PreConnectBuffer) and trims leading
    // silence. Nobody adopting it within [EARLY_TIMEOUT_MS] drops it.

    private const val PREFS = "woi_audio"
    private const val KEY_AEC = "aec"
    private const val KEY_ROUTE = "route"
    private const val EARLY_TIMEOUT_MS = 10_000L
    private const val EARLY_MAX_BYTES = RATE * 2 * 15
    private var early: java.util.ArrayDeque<ByteArray>? = null
    private var earlyBytes = 0
    private var earlyAt = 0L
    private val earlyTimeout = Runnable {
        if (early != null && micSink == null) {
            Log.i(WoiBridge.TAG, "early mic: not adopted in ${EARLY_TIMEOUT_MS} ms, closing")
            dropEarly()
        }
    }

    /** Assist activation: starts the recorder now (main thread). No-op while
     *  Dart's mic is open, already early, or without the permission. */
    fun startEarly(ctx: Context) {
        try {
            if (micSink != null || early != null || record != null) return
            WoiBridge.ensureContext(ctx)
            if (!WoiBridge.hasPermission(ctx, android.Manifest.permission.RECORD_AUDIO)) return
            if (othersRecording(am().activeRecordingConfigurations)) return
            val prefs = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            micAec = prefs.getBoolean(KEY_AEC, true)
            if (WoiAudioRoute.setRoute(prefs.getString(KEY_ROUTE, null))) playerClose()
            early = java.util.ArrayDeque()
            earlyBytes = 0
            earlyAt = SystemClock.elapsedRealtime()
            startRecord()
            WoiBridge.main.postDelayed(earlyTimeout, EARLY_TIMEOUT_MS)
            Log.i(WoiBridge.TAG, "early mic: recording from activation")
        } catch (e: Throwable) {
            Log.w(WoiBridge.TAG, "early mic failed", e)
            dropEarly()
        }
    }

    /** Dart opens its mic: takes over the early recorder when its settings
     *  match, sending the buffered chunks first. */
    private fun adoptEarly(events: EventChannel.EventSink, aecArg: Boolean, routeArg: String?): Boolean {
        val q = early ?: return false
        val routeSame = (if (routeArg == WoiAudioRoute.MEDIA) WoiAudioRoute.MEDIA else WoiAudioRoute.PHONE) == WoiAudioRoute.route
        if (record == null || aecArg != micAec || !routeSame) {
            dropEarly()
            return false
        }
        WoiBridge.main.removeCallbacks(earlyTimeout)
        early = null
        micSink = events
        healed = false
        healNoted = false
        val cb = object : AudioManager.AudioRecordingCallback() {
            override fun onRecordingConfigChanged(configs: MutableList<AudioRecordingConfiguration>) = evaluate(configs)
        }
        recCallback = cb
        am().registerAudioRecordingCallback(cb, WoiBridge.main)
        Log.i(
            WoiBridge.TAG,
            "early mic: adopted after ${SystemClock.elapsedRealtime() - earlyAt} ms, " +
                "flushing ${q.size} chunks (${earlyBytes * 1000L / (RATE * 2)} ms)"
        )
        for (c in q) events.success(c)
        return true
    }

    /** The panel went before Dart took the early recorder. */
    fun cancelEarly() = dropEarly()

    private fun dropEarly() {
        WoiBridge.main.removeCallbacks(earlyTimeout)
        if (early == null) return
        early = null
        earlyBytes = 0
        if (micSink == null) {
            stopRecord()
            WoiAudioRoute.leaveCommunication()
            syncPlayerRoute()
        }
    }

    private fun deliver(chunk: ByteArray) {
        val sink = micSink
        if (sink != null) return sink.success(chunk)
        val q = early ?: return
        q.addLast(chunk)
        earlyBytes += chunk.size
        while (earlyBytes > EARLY_MAX_BYTES && q.size > 1) earlyBytes -= q.removeFirst().size
    }

    private fun closeMic() {
        if (early != null) {
            WoiBridge.main.removeCallbacks(earlyTimeout)
            early = null
            earlyBytes = 0
        }
        recCallback?.let { am().unregisterAudioRecordingCallback(it) }
        recCallback = null
        val wasYielded = yielded
        yielded = false
        micSink = null
        stopRecord()
        WoiAudioRoute.leaveCommunication()
        syncPlayerRoute()
        if (wasYielded) emitMicState(false)
    }

    /** Another app's capture (any source but hotword), silenced or not. */
    private fun othersRecording(configs: List<AudioRecordingConfiguration>): Boolean = configs.any {
        it.clientAudioSessionId != ourSession && it.clientAudioSource != HOTWORD_SOURCE
    }

    private fun evaluate(configs: List<AudioRecordingConfiguration>) {
        val sink = micSink ?: return
        val others = othersRecording(configs)
        if (others && !yielded) {
            yield()
        } else if (!others && yielded) {
            // Let the other app finish releasing the input first.
            WoiBridge.main.postDelayed({
                if (micSink === sink && yielded && !othersRecording(am().activeRecordingConfigurations)) {
                    yielded = false
                    Log.i(WoiBridge.TAG, "mic free again: resuming")
                    try {
                        startRecord()
                        emitMicState(false)
                    } catch (e: Throwable) {
                        sink.error("mic", e.message ?: e.toString(), null)
                    }
                }
            }, 400)
        } else if (!others && !yielded && Build.VERSION.SDK_INT >= 29) {
            val mine = configs.firstOrNull { it.clientAudioSessionId == ourSession }
            if (mine?.isClientSilenced == true) Log.w(WoiBridge.TAG, "mic silenced by the system")
        }
    }

    /** Releases the recorder (and the call mode) while another app records. */
    private fun yield() {
        yielded = true
        Log.i(WoiBridge.TAG, "another app is recording: pausing Woi's mic")
        stopRecord()
        WoiAudioRoute.leaveCommunication()
        syncPlayerRoute()
        emitMicState(true)
    }

    private fun emitMicState(paused: Boolean) {
        WoiBridge.emit(
            mapOf(
                "type" to "micState",
                "paused" to paused,
                "reason" to if (paused) "Mic paused: another app is using it" else null,
            )
        )
    }

    @SuppressLint("MissingPermission")
    private fun startRecord(keepFocus: Boolean = false) {
        stopRecord(keepFocus)
        WoiAudioRoute.enterCommunication()
        syncPlayerRoute()
        val min = AudioRecord.getMinBufferSize(RATE, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT)
        val phone = WoiAudioRoute.isPhone
        // Phone route: VOICE_COMMUNICATION in MODE_IN_COMMUNICATION runs the
        // HAL's call echo canceller (referenced to the output mix). Media
        // route: VOICE_COMMUNICATION in MODE_NORMAL plus the AEC/NS effects
        // on the record session, and Woi's media track plays on that same
        // session so the effect has it as its echo reference.
        // (VOICE_RECOGNITION + AEC left most of Woi's voice in the capture
        // on a MI 8: the effect had no reference for a separate media track.)
        val source = if (micAec) MediaRecorder.AudioSource.VOICE_COMMUNICATION else MediaRecorder.AudioSource.MIC
        val rec = AudioRecord(
            source, RATE,
            AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT, maxOf(min, CHUNK_BYTES * 4)
        )
        if (rec.state != AudioRecord.STATE_INITIALIZED) {
            rec.release()
            WoiAudioRoute.leaveCommunication()
            throw IllegalStateException("AudioRecord not initialized (RECORD_AUDIO granted?)")
        }
        ourSession = rec.audioSessionId
        micZeros = false
        val route = if (phone) "phone route" else "media route"
        if (micAec) {
            if (AcousticEchoCanceler.isAvailable()) aec = AcousticEchoCanceler.create(rec.audioSessionId)?.apply { enabled = true }
            if (NoiseSuppressor.isAvailable()) ns = NoiseSuppressor.create(rec.audioSessionId)?.apply { enabled = true }
            val src = if (phone) "VOICE_COMMUNICATION, call mode" else "VOICE_COMMUNICATION, media mode"
            status = when {
                aec?.enabled == true -> "active ($route: $src + platform AEC${if (ns?.enabled == true) " + NS" else ""})"
                phone -> "active ($route: $src; call echo canceller, no separate AEC effect)"
                else -> "$route: $src; no platform AEC effect on this device"
            }
        } else {
            status = "off (MIC source, $route)"
        }
        rec.startRecording()
        record = rec
        syncPlayerRoute()
        if (!phone) WoiAudioRoute.requestListenFocus()
        micThread = Thread({
            val buf = ByteArray(CHUNK_BYTES)
            // Residual-echo diagnostics: mean mic RMS while Woi's track plays.
            var echoSum = 0.0
            var echoN = 0
            // Start-up diagnostics: rms + silenced flag once a second for 5 s.
            val t0 = System.nanoTime()
            var diagSum = 0.0
            var diagN = 0
            var diagSec = 1
            // Dead-mic check: a live mic never delivers exact digital zeros
            // (even AEC/NS leave a noise floor); seen on a MI 8 after a
            // relaunch with the capture reported as not silenced.
            var zeroSince = 0L
            var zeroReported = false
            // Idle (Woi silent) mic level, every 10 s.
            var idleSum = 0.0
            var idleN = 0
            var idleZero = 0
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
                val r = rms(chunk)
                val now = System.nanoTime()
                if (diagSec <= 5) {
                    diagSum += r; diagN++
                    if (now - t0 >= diagSec * 1_000_000_000L) {
                        val silenced = if (Build.VERSION.SDK_INT >= 29) {
                            try { rec.activeRecordingConfiguration?.isClientSilenced } catch (_: Exception) { null }
                        } else null
                        Log.i(WoiBridge.TAG, "mic start +%ds: rms %.4f silenced=%s".format(diagSec, diagSum / diagN, silenced))
                        diagSum = 0.0; diagN = 0; diagSec++
                    }
                }
                if (r == 0.0) {
                    if (zeroSince == 0L) zeroSince = now
                    else if (!zeroReported && now - zeroSince > 2_000_000_000L) {
                        zeroReported = true
                        micZeros = true
                        WoiBridge.main.post { onDeadMic(rec) }
                    }
                } else {
                    zeroSince = 0L
                    zeroReported = false
                    micZeros = false
                }
                if (!paused) {
                    echoSum += r; echoN++
                    if (echoN == 25) {
                        Log.i(WoiBridge.TAG, "mic rms while playing (2 s): %.4f".format(echoSum / echoN))
                        echoSum = 0.0; echoN = 0
                    }
                } else {
                    if (echoN > 0) { echoSum = 0.0; echoN = 0 }
                    idleSum += r; idleN++
                    if (r == 0.0) idleZero++
                    if (idleN == 125) {
                        Log.i(WoiBridge.TAG, "mic rms idle (10 s): %.4f, all-zero chunks %d/125".format(idleSum / idleN, idleZero))
                        idleSum = 0.0; idleN = 0; idleZero = 0
                    }
                }
                WoiBridge.main.post { if (record === rec) deliver(chunk) }
            }
        }, "woi-mic").apply {
            priority = Thread.MAX_PRIORITY
            start()
        }
        Log.i(WoiBridge.TAG, "mic started: $status")
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

    /**
     * The recorder delivered exact zeros for over 2 s while active. On a
     * MI 8 this is also what VOICE_COMMUNICATION + NS deliver in a quiet
     * room (the HAL input is live, -95..-70 dBFS; the effects gate it to 0),
     * so this is a cheap one-shot safety net, not proof of a dead mic. Restarts
     * it once per mic open. Main thread. While Woi speaks the restart waits
     * for the reply to end: a new recorder means a new session, and the
     * media track (bound to the old session) would be rebuilt mid-reply.
     */
    private fun onDeadMic(rec: AudioRecord) {
        val sink = micSink
        if (record !== rec || sink == null || yielded || !micZeros) return
        val silenced = if (Build.VERSION.SDK_INT >= 29) rec.activeRecordingConfiguration?.isClientSilenced else null
        // Zeros with silenced=false are the platform AEC/NS gating a quiet
        // room (measured on the MI 8: HAL input live, app gets 0): normal, so
        // no restart. Only a client Android really silenced is restarted.
        if (silenced != true) {
            if (!healNoted) {
                healNoted = true
                Log.i(WoiBridge.TAG, "mic quiet (exact zeros, not silenced): effects gating a quiet room")
            }
            return
        }
        if (healed) {
            if (healNoted) return
            healNoted = true
            Log.w(WoiBridge.TAG, "mic delivers only zeros (silenced=$silenced); already restarted once, not again")
            return
        }
        if (!paused) {
            Log.w(WoiBridge.TAG, "mic delivers only zeros (silenced=$silenced); restart after Woi's reply")
            WoiBridge.main.postDelayed({ onDeadMic(rec) }, 500)
            return
        }
        healed = true
        Log.w(WoiBridge.TAG, "mic delivered only zeros for 2 s (silenced=$silenced): restarting the recorder (self-heal)")
        try {
            // Keeps the media route's listen focus: no resume blip for the
            // paused app.
            startRecord(keepFocus = true)
        } catch (e: Throwable) {
            sink.error("mic", e.message ?: e.toString(), null)
        }
    }

    private fun rms(pcm: ByteArray): Double {
        var sum = 0.0
        var i = 0
        while (i + 1 < pcm.size) {
            val v = ((pcm[i].toInt() and 0xff) or (pcm[i + 1].toInt() shl 8)) / 32768.0
            sum += v * v
            i += 2
        }
        return Math.sqrt(sum / maxOf(1, pcm.size / 2))
    }

    private fun stopRecord(keepFocus: Boolean = false) {
        if (!keepFocus) WoiAudioRoute.abandonListenFocus()
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
    // Whether [track] was built for the call path (USAGE_VOICE_COMMUNICATION).
    private var trackCall = false
    // The record session [track] shares (0: none).
    private var trackSession = 0

    private fun wantCallTrack() = WoiAudioRoute.isPhone && WoiAudioRoute.inCommunication

    /** Rebuilds the track when the call mode changed under it. Main thread. */
    private fun syncPlayerRoute() {
        if (track != null && (trackCall != wantCallTrack() || trackSession != wantSession())) playerClose()
    }

    /** The recorder's session for the track (both routes, AEC on), else 0. */
    private fun wantSession() = if (record != null && micAec) ourSession else 0

    fun playerOpen(): Boolean {
        if (track != null) return true
        val min = AudioTrack.getMinBufferSize(RATE, AudioFormat.CHANNEL_OUT_MONO, AudioFormat.ENCODING_PCM_16BIT)
        // Phone route in call mode: a voice-call stream (same session as the
        // recorder, so session-bound effects see both). Otherwise media.
        trackCall = wantCallTrack()
        val attrs = if (trackCall) WoiAudioRoute.playbackAttributes()
        else AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_MEDIA)
            .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH).build()
        val b = AudioTrack.Builder()
        trackSession = wantSession()
        if (trackSession != 0) b.setSessionId(trackSession)
        val t = b
            .setAudioAttributes(attrs)
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
                        WoiAudioRoute.abandonSpeechFocus()
                    }
                    continue
                }
                val gen = generation
                synchronized(trackLock) {
                    if (track !== t) return@Thread
                    if (paused) { t.play(); paused = false; WoiAudioRoute.requestSpeechFocus() }
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
        WoiAudioRoute.abandonSpeechFocus()
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
        WoiAudioRoute.abandonSpeechFocus()
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
