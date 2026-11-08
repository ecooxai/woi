package dev.woi.woi

import android.Manifest
import android.app.Activity
import android.app.Instrumentation
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioRecord
import android.media.AudioTrack
import android.media.AudioTimestamp
import android.media.MediaRecorder
import android.os.Bundle
import org.json.JSONObject
import org.json.JSONArray
import org.webrtc.PeerConnectionFactory
import org.webrtc.audio.JavaAudioDeviceModule
import org.webrtc.audio.WoiAudioRouteAccess
import java.util.Random
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong
import kotlin.math.PI
import kotlin.math.ln
import kotlin.math.sin

/** Native media AEC checks. Saves aggregate metrics only, never microphone PCM. */
class MediaAecDeviceCheck(private val host: Instrumentation) {
    private val ctx get() = host.targetContext
    private val report = JSONObject()
    private val log = StringBuilder()
    private var activity: Activity? = null
    private var passed = 0

    private fun verify(name: String, block: () -> Unit) {
        block()
        passed++
        log.append("PASS ").append(name).append('\n')
    }

    fun run() {
        try {
            host.runOnMainSync { WoiBridge.ensureContext(ctx) }
            verify("native JNI cancellation, double talk and reset") { synthetic() }
            verify("live ADM Media and Phone attributes") {
                PeerConnectionFactory.initialize(PeerConnectionFactory.InitializationOptions.builder(ctx).createInitializationOptions())
                val module = JavaAudioDeviceModule.builder(ctx)
                    .setUseHardwareAcousticEchoCanceler(false)
                    .setUseHardwareNoiseSuppressor(false)
                    .createAudioDeviceModule()
                try {
                    WoiAudioRouteAccess.configure(module, true)
                    check(WoiAudioRouteAccess.usage(module) == AudioAttributes.USAGE_MEDIA)
                    WoiAudioRouteAccess.configure(module, false)
                    check(WoiAudioRouteAccess.usage(module) == AudioAttributes.USAGE_VOICE_COMMUNICATION)
                    WoiAudioRouteAccess.configure(module, true)
                    check(WoiAudioRouteAccess.usage(module) == AudioAttributes.USAGE_MEDIA)
                    report.put("live_route_switch", "media-phone-media")
                } finally { module.release() }
            }
            verify("real Media speaker/microphone cancellation") { acoustic() }
            report.put("status", "passed").put("checks", passed)
            finish(Activity.RESULT_OK)
        } catch (error: Throwable) {
            log.append("FAIL ").append(error.stackTraceToString())
            report.put("status", "failed").put("error", error.toString()).put("checks", passed)
            finish(Activity.RESULT_CANCELED)
        } finally {
            host.runOnMainSync { activity?.finish() }
        }
    }

    private fun finish(code: Int) {
        ctx.filesDir.resolve("qa-media-aec.json").writeText(report.toString(2))
        host.finish(code, Bundle().apply {
            putString("stream", log.toString() + report.toString(2) + "\n")
            putInt("passed", passed)
        })
    }

    private fun bytePcm(samples: DoubleArray): ByteArray = ByteArray(samples.size * 2).also { out ->
        for (i in samples.indices) {
            val v = samples[i].toInt().coerceIn(-32767, 32767)
            out[i * 2] = v.toByte(); out[i * 2 + 1] = (v shr 8).toByte()
        }
    }

    private fun sample(pcm: ByteArray, index: Int): Double =
        ((pcm[index * 2].toInt() and 255) or (pcm[index * 2 + 1].toInt() shl 8)).toShort().toDouble()

    // Bound a digital-zero residual by half an int16 LSB, rather than reporting
    // hundreds of fictitious dB from a division-by-zero epsilon.
    private fun db(before: Double, after: Double, samples: Long) =
        10 * ln((before + 1e-12) / maxOf(after, .25 * samples)) / ln(10.0)

    private fun synthetic() {
        val rate = 24000
        val count = rate * 16
        val random = Random(112608)
        val far = DoubleArray(count)
        var lp = 0.0
        for (i in far.indices) {
            lp = lp * .55 + random.nextGaussian() * .45
            far[i] = lp * 10000 * (.45 + .55 * sin(i * 2 * PI / (rate * 1.1)).let { it * it })
        }
        val farPcm = bytePcm(far)
        val echo = DoubleArray(count)
        for ((delay, gain) in listOf(720 to .55, 1488 to .22, 2520 to -.12))
            for (i in delay until count) echo[i] += sample(farPcm, i - delay) * gain
        val near = DoubleArray(count) { i ->
            if (i < rate * 8) 0.0 else {
                val t = i.toDouble() / rate
                2400 * (sin(2 * PI * 181 * t) + .4 * sin(2 * PI * 577 * t)) * (.4 + .6 * sin(2 * PI * 2.7 * t).let { it * it })
            }
        }
        val aec = WoiMediaEchoCanceller()
        // Exercise the release JNI entry points directly with a sample-exact
        // synthetic reference; no microphone or network is involved here.
        val handle = aec.javaClass.getDeclaredField("handle").apply { isAccessible = true }.getLong(aec)
        val process = aec.javaClass.getDeclaredMethod("nativeProcess", java.lang.Long.TYPE, ByteArray::class.java, ByteArray::class.java)
            .apply { isAccessible = true }
        fun run(input: ByteArray): DoubleArray {
            val out = DoubleArray(count)
            for (off in 0 until count step 480) {
                val value = process.invoke(aec, handle, input.copyOfRange(off * 2, (off + 480) * 2),
                    farPcm.copyOfRange(off * 2, (off + 480) * 2)) as ByteArray
                for (i in 0 until 480) out[off + i] = sample(value, i)
            }
            return out
        }
        try {
            val onlyEcho = run(bytePcm(echo))
            var rawPower = 0.0; var cleanPower = 0.0
            for (i in count - rate * 4 until count) { rawPower += echo[i] * echo[i]; cleanPower += onlyEcho[i] * onlyEcho[i] }
            val erle = db(rawPower, cleanPower, (rate * 4).toLong())
            check(erle >= 20) { "Native attenuation only $erle dB" }
            report.put("synthetic_attenuation_db", erle)
            val mixed = run(bytePcm(DoubleArray(count) { echo[it] + near[it] }))
            var xx = 0.0; var yy = 0.0; var xy = 0.0
            for (i in count - rate * 4 until count) {
                val x = near[i - 480]; val y = mixed[i]
                xx += x * x; yy += y * y; xy += x * y
            }
            val correlation = xy / kotlin.math.sqrt(xx * yy)
            val gain = xy / xx
            check(correlation >= .75 && gain in .45..1.35) { "Double talk correlation=$correlation gain=$gain" }
            report.put("near_end_correlation", correlation).put("near_end_gain", gain).put("algorithmic_delay_ms", 20)
            aec.javaClass.getDeclaredMethod("nativeReset", java.lang.Long.TYPE).apply { isAccessible = true }.invoke(aec, handle)
            val reset = run(bytePcm(echo))
            cleanPower = 0.0
            for (i in count - rate * 4 until count) cleanPower += reset[i] * reset[i]
            val resetDb = db(rawPower, cleanPower, (rate * 4).toLong())
            check(resetDb >= 20) { "Reset attenuation only $resetDb dB" }
            report.put("reset_attenuation_db", resetDb)
        } finally { aec.close() }
    }

    // The probe reads only clock positions and ring coverage from the installed
    // production wrapper. It never changes that wrapper or exports microphone
    // samples. Correlation is calculated locally against our synthetic signal.
    private data class ClockProbe(val json: JSONObject, val predictedStart: Long,
                                  val captureStartNanos: Long, val renderOriginNanos: Long)
    private val aecFields = HashMap<String, java.lang.reflect.Field>()
    private fun field(aec: WoiMediaEchoCanceller, name: String): java.lang.reflect.Field =
        aecFields.getOrPut(name) { aec.javaClass.getDeclaredField(name).apply { isAccessible = true } }

    private fun clockProbe(aec: WoiMediaEchoCanceller, count: Int, started: Long, accepted: Long): ClockProbe {
        val rate = WoiMediaEchoCanceller.RATE
        val timestamp = field(aec, "captureTimestamp").get(aec) as AudioTimestamp
        val renderTimestamp = field(aec, "outputTimestamp").get(aec) as AudioTimestamp
        val consumed = field(aec, "captureFrames").getLong(aec)
        val anchorFrame = field(aec, "anchorFrame").getLong(aec)
        val anchorNs = field(aec, "anchorNanos").getLong(aec)
        val endFrame = field(aec, "endFrame").getLong(aec)
        val lead = field(aec, "REFERENCE_LEAD_NS").getLong(aec)
        val tags = field(aec, "frameTags").get(aec) as LongArray
        val samples = field(aec, "rendered").get(aec) as ShortArray
        val captureStart = if (timestamp.nanoTime > 0) {
            timestamp.nanoTime + (consumed - count - timestamp.framePosition) * 1_000_000_000L / rate
        } else started - count * 1_000_000_000L / rate
        val prediction = anchorFrame + (captureStart + lead - anchorNs) * rate / 1_000_000_000L
        val selected = field(aec, "lastReferenceFrame").getLong(aec)
        val requested = if (selected == Long.MIN_VALUE) prediction else selected
        var matched = 0; var nonzero = 0; var missingFuture = 0; var missingPast = 0; var missingTags = 0
        for (i in 0 until count) {
            val frame = requested + i
            when {
                anchorNs == 0L || selected == Long.MIN_VALUE || frame < 0 -> missingPast++
                frame >= endFrame -> missingFuture++
                tags[(frame % tags.size).toInt()] != frame -> missingTags++
                else -> {
                    matched++
                    if (samples[(frame % tags.size).toInt()].toInt() != 0) nonzero++
                }
            }
        }
        return ClockProbe(JSONObject()
            .put("capture_consumed_frames", consumed)
            .put("capture_hardware_frame", timestamp.framePosition)
            .put("capture_timestamp_available", timestamp.nanoTime > 0)
            .put("capture_timestamp_age_ms", (started - timestamp.nanoTime) / 1_000_000.0)
            .put("capture_start_age_ms", (started - captureStart) / 1_000_000.0)
            .put("capture_processing_ms", (System.nanoTime() - started) / 1_000_000.0)
            .put("render_hardware_frame", renderTimestamp.framePosition)
            .put("render_timestamp_age_ms", (started - renderTimestamp.nanoTime) / 1_000_000.0)
            .put("render_anchor_frame", anchorFrame)
            .put("render_anchor_age_ms", (started - anchorNs) / 1_000_000.0)
            .put("render_reference_end", endFrame)
            .put("writer_accepted_end", accepted)
            .put("accepted_not_tagged_frames", accepted - endFrame)
            .put("timestamp_prediction_start_frame", prediction)
            .put("reference_cursor_available", selected != Long.MIN_VALUE)
            .put("requested_start_frame", requested)
            .put("requested_end_frame", requested + count)
            .put("reference_covered_samples", matched)
            .put("reference_nonzero_samples", nonzero)
            .put("missing_future_samples", missingFuture)
            .put("missing_past_samples", missingPast)
            .put("missing_tag_samples", missingTags), requested, captureStart,
            anchorNs - anchorFrame * 1_000_000_000L / rate)
    }

    private fun correlationProbe(pcm: ByteArray, history: ShortArray, historyLock: Any,
                                 accepted: AtomicLong, predicted: Long): JSONObject {
        val count = pcm.size / 2
        val stride = 4
        val (origin, available) = synchronized(historyLock) {
            val end = minOf(accepted.get().toInt(), history.size)
            val start = maxOf(0, end - count - 24000 * 3 / 5)
            start to history.copyOfRange(start, end)
        }
        val points = count / stride
        val mic = DoubleArray(points) { sample(pcm, it * stride) }
        val micMean = mic.sum() / points
        var micPower = 0.0
        for (i in mic.indices) { mic[i] -= micMean; micPower += mic[i] * mic[i] }
        var best = 0.0; var bestStart = -1L
        for (offset in 0..maxOf(0, available.size - count) step stride) {
            if (offset + count > available.size) break
            var xy = 0.0; var xx = 0.0; var sum = 0.0
            for (i in 0 until points) {
                val reference = available[offset + i * stride].toDouble()
                xy += mic[i] * reference; xx += reference * reference; sum += reference
            }
            xx -= sum * sum / points
            val correlation = xy / kotlin.math.sqrt(maxOf(1e-9, xx * micPower))
            if (kotlin.math.abs(correlation) > kotlin.math.abs(best)) {
                best = correlation; bestStart = (origin + offset).toLong()
            }
        }
        return JSONObject().put("peak_correlation", best)
            .put("peak_render_start_frame", bestStart)
            .put("predicted_minus_peak_ms", (predicted - bestStart) / 24.0)
            .put("search_origin_frame", origin).put("search_samples", available.size)
    }

    @Suppress("MissingPermission", "DEPRECATION")
    private fun acoustic() {
        check(ctx.checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED)
        // PythonInstrumentation substitutes a native activity for MainActivity
        // in this group, so the foreground microphone check cannot start chat.
        activity = host.startActivitySync(Intent().setClassName(ctx.packageName, "${ctx.packageName}.MainActivity")
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        val manager = ctx.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        val savedMode = manager.mode
        val savedVolume = manager.getStreamVolume(AudioManager.STREAM_MUSIC)
        val volume = maxOf(1, minOf(savedVolume, manager.getStreamMaxVolume(AudioManager.STREAM_MUSIC) / 3))
        var record: AudioRecord? = null
        var track: AudioTrack? = null
        val aec = WoiMediaEchoCanceller()
        // A second, identical packaged DSP processes the same capture using a
        // once-aligned continuous sample cursor. This is diagnostic only; the
        // actual wrapper's 6 dB acceptance gate remains unchanged.
        val continuous = WoiMediaEchoCanceller()
        val continuousHandle = field(continuous, "handle").getLong(continuous)
        val continuousProcess = continuous.javaClass.getDeclaredMethod("nativeProcess", java.lang.Long.TYPE,
            ByteArray::class.java, ByteArray::class.java).apply { isAccessible = true }
        var continuousNextFrame: Long? = null
        var continuousSeedChunk = -1
        var continuousSeedFrame = 0L
        var continuousMissing = 0L
        var continuousEnergy = 0.0
        var continuousMeasured = 0L
        var continuousProcessingMaxMs = 0.0
        val keepWriting = AtomicBoolean(true)
        var writer: Thread? = null
        val acceptedFrames = AtomicLong()
        val stimulusClipped = AtomicLong()
        val referenceHistory = ShortArray(24000 * 20) // generated test audio only
        val referenceLock = Any()
        val probes = JSONArray()
        report.put("clock_reference_probes", probes)
        try {
            manager.mode = AudioManager.MODE_NORMAL
            manager.setStreamVolume(AudioManager.STREAM_MUSIC, volume, 0)
            val rec = AudioRecord(MediaRecorder.AudioSource.VOICE_RECOGNITION, 24000,
                AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT,
                maxOf(AudioRecord.getMinBufferSize(24000, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT), 15360))
            record = rec
            check(rec.state == AudioRecord.STATE_INITIALIZED)
            val output = AudioTrack.Builder()
                .setAudioAttributes(AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_MEDIA)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH).build())
                .setAudioFormat(AudioFormat.Builder().setSampleRate(24000).setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                    .setEncoding(AudioFormat.ENCODING_PCM_16BIT).build())
                .setBufferSizeInBytes(maxOf(AudioTrack.getMinBufferSize(24000, AudioFormat.CHANNEL_OUT_MONO, AudioFormat.ENCODING_PCM_16BIT), 4800))
                .setTransferMode(AudioTrack.MODE_STREAM).build()
            track = output
            check(output.audioAttributes.usage == AudioAttributes.USAGE_MEDIA)
            check(manager.mode == AudioManager.MODE_NORMAL)
            aec.beginOutput()
            rec.startRecording()
            output.play()
            writer = Thread {
                var frame = 0L
                val random = Random(1008)
                var lp = 0.0
                while (keepWriting.get()) {
                    val signal = DoubleArray(480) {
                        lp = lp * .6 + random.nextGaussian() * .4
                        lp * 18000
                    }
                    val pcm = bytePcm(signal)
                    val written = output.write(pcm, 0, pcm.size)
                    if (written <= 0) break
                    synchronized(referenceLock) {
                        for (i in 0 until written / 2) {
                            val index = frame + i
                            val value = sample(pcm, i).toInt()
                            if (kotlin.math.abs(value) >= 32760) stimulusClipped.incrementAndGet()
                            if (index < referenceHistory.size) referenceHistory[index.toInt()] = value.toShort()
                        }
                        acceptedFrames.set(frame + written / 2)
                    }
                    aec.rendered(output, pcm, 0, written, frame)
                    frame += written / 2
                }
            }.apply { start() }
            val buf = ByteArray(3840)
            var previousProbe: ClockProbe? = null
            var matchedSamples = 0L; var nonzeroSamples = 0L; var futureMissing = 0L
            var stepMinimum = Long.MAX_VALUE; var stepMaximum = Long.MIN_VALUE
            var stepAbsolute = 0L; var discontinuousChunks = 0
            var captureJitterMs = 0.0; var renderOriginJitterMs = 0.0
            var rawEnergy = 0.0; var cleanedEnergy = 0.0; var measured = 0L
            var capturedClipped = 0L
            val rawBySecond = DoubleArray(10)
            val cleanBySecond = DoubleArray(10)
            val samplesBySecond = LongArray(10)
            // 10 seconds total, measuring the last 5 after convergence. No PCM
            // from this microphone ever leaves this method or goes to a file.
            for (chunk in 0 until 125) {
                var filled = 0
                while (filled < buf.size) {
                    val n = rec.read(buf, filled, buf.size - filled)
                    check(n > 0) { "Capture failed: $n" }
                    filled += n
                }
                val (cleaned, probe) = synchronized(aec) {
                    val started = System.nanoTime()
                    val processed = aec.capture(rec, buf)
                    // The same monitor prevents the renderer from tagging an
                    // accepted write between capture and its coverage snapshot.
                    processed to clockProbe(aec, buf.size / 2, started, acceptedFrames.get())
                }
                matchedSamples += probe.json.getInt("reference_covered_samples")
                nonzeroSamples += probe.json.getInt("reference_nonzero_samples")
                futureMissing += probe.json.getInt("missing_future_samples")
                previousProbe?.let { previous ->
                    val stepError = probe.predictedStart - previous.predictedStart - buf.size / 2
                    stepMinimum = minOf(stepMinimum, stepError); stepMaximum = maxOf(stepMaximum, stepError)
                    stepAbsolute += kotlin.math.abs(stepError)
                    if (kotlin.math.abs(stepError) > 1) discontinuousChunks++
                    val captureStep = (probe.captureStartNanos - previous.captureStartNanos - 80_000_000L) / 1_000_000.0
                    val renderStep = (probe.renderOriginNanos - previous.renderOriginNanos) / 1_000_000.0
                    captureJitterMs = maxOf(captureJitterMs, kotlin.math.abs(captureStep))
                    renderOriginJitterMs = maxOf(renderOriginJitterMs, kotlin.math.abs(renderStep))
                    probe.json.put("reference_step_error_samples", stepError)
                        .put("capture_step_error_ms", captureStep).put("render_origin_step_ms", renderStep)
                }
                previousProbe = probe
                if (chunk % 20 == 19) {
                    val correlation = correlationProbe(buf, referenceHistory, referenceLock, acceptedFrames, probe.predictedStart)
                    val keys = correlation.keys()
                    while (keys.hasNext()) { val key = keys.next(); probe.json.put(key, correlation.get(key)) }
                    probe.json.put("chunk", chunk).put("playback_underruns", output.underrunCount)
                        .put("playback_head", output.playbackHeadPosition.toLong() and 0xffffffffL)
                        .put("record_sample_rate", rec.sampleRate).put("track_sample_rate", output.sampleRate)
                    probes.put(probe.json)
                }
                if (continuousNextFrame == null && chunk >= 19 &&
                    probe.json.getBoolean("capture_timestamp_available") &&
                    probe.json.getInt("reference_covered_samples") == buf.size / 2) {
                    continuousNextFrame = probe.predictedStart
                    continuousSeedFrame = probe.predictedStart
                    continuousSeedChunk = chunk
                }
                continuousNextFrame?.let { first ->
                    val reference = ByteArray(buf.size)
                    synchronized(referenceLock) {
                        val available = minOf(acceptedFrames.get(), referenceHistory.size.toLong())
                        for (i in 0 until buf.size / 2) {
                            val at = first + i
                            if (at < 0 || at >= available) { continuousMissing++; continue }
                            val value = referenceHistory[at.toInt()].toInt()
                            reference[i * 2] = value.toByte(); reference[i * 2 + 1] = (value shr 8).toByte()
                        }
                    }
                    val started = System.nanoTime()
                    val comparison = continuousProcess.invoke(continuous, continuousHandle, buf, reference) as ByteArray
                    continuousProcessingMaxMs = maxOf(continuousProcessingMaxMs, (System.nanoTime() - started) / 1_000_000.0)
                    continuousNextFrame = first + buf.size / 2
                    if (chunk >= 62) for (i in 0 until comparison.size / 2) {
                        val value = sample(comparison, i)
                        continuousEnergy += value * value; continuousMeasured++
                    }
                }
                val second = chunk * 80 / 1000
                for (i in 0 until buf.size / 2) {
                    val raw = sample(buf, i); val clean = sample(cleaned, i)
                    rawBySecond[second] += raw * raw
                    cleanBySecond[second] += clean * clean
                    samplesBySecond[second]++
                    if (chunk >= 62) {
                        rawEnergy += raw * raw; cleanedEnergy += clean * clean; measured++
                        if (kotlin.math.abs(raw) >= 32760) capturedClipped++
                    }
                }
            }
            val windows = JSONArray()
            var elapsedSamples = 0L
            for (second in samplesBySecond.indices) {
                val samples = samplesBySecond[second]
                windows.put(JSONObject().put("start_ms", elapsedSamples / 24.0)
                    .put("end_ms", (elapsedSamples + samples) / 24.0)
                    .put("acoustic_attenuation_db", db(rawBySecond[second], cleanBySecond[second], samples))
                    .put("raw_rms", kotlin.math.sqrt(rawBySecond[second] / samples) / 32768)
                    .put("cleaned_rms", kotlin.math.sqrt(cleanBySecond[second] / samples) / 32768))
                elapsedSamples += samples
            }
            report.put("production_acoustic_windows", windows)
            val inputDevice = rec.routedDevice
            val outputDevice = output.routedDevice
            report.put("physical_routes", JSONObject()
                .put("record_device_type", inputDevice?.type ?: -1).put("record_device_id", inputDevice?.id ?: -1)
                .put("track_device_type", outputDevice?.type ?: -1).put("track_device_id", outputDevice?.id ?: -1))
            report.put("clipping", JSONObject().put("capture_clipped_samples", capturedClipped)
                .put("capture_measured_samples", measured).put("stimulus_clipped_samples", stimulusClipped.get())
                .put("stimulus_written_samples", acceptedFrames.get()))
            report.put("continuous_reference_comparison", JSONObject()
                .put("comparison_only", true).put("seed_chunk", continuousSeedChunk)
                .put("seed_reference_frame", continuousSeedFrame).put("reference_missing_samples", continuousMissing)
                .put("measured_samples", continuousMeasured).put("processing_ms_max", continuousProcessingMaxMs)
                .put("acoustic_attenuation_db", if (continuousMeasured > 0) db(rawEnergy, continuousEnergy, continuousMeasured) else 0)
                .put("cleaned_rms", if (continuousMeasured > 0) kotlin.math.sqrt(continuousEnergy / continuousMeasured) / 32768 else 0))
            report.put("reference_summary", JSONObject()
                .put("total_samples", 125 * buf.size / 2)
                .put("covered_samples", matchedSamples).put("nonzero_samples", nonzeroSamples)
                .put("missing_future_samples", futureMissing)
                .put("step_error_samples_min", stepMinimum).put("step_error_samples_max", stepMaximum)
                .put("step_error_absolute_samples", stepAbsolute).put("discontinuous_chunks", discontinuousChunks)
                .put("capture_step_error_ms_max", captureJitterMs).put("render_origin_step_ms_max", renderOriginJitterMs))
            val rawRms = kotlin.math.sqrt(rawEnergy / measured) / 32768
            val cleanedRms = kotlin.math.sqrt(cleanedEnergy / measured) / 32768
            val attenuation = db(rawEnergy, cleanedEnergy, measured)
            report.put("acoustic_attenuation_db", attenuation).put("raw_rms", rawRms).put("cleaned_rms", cleanedRms)
                .put("media_volume", volume).put("mode", manager.mode).put("playback_usage", output.audioAttributes.usage)
            check(rawRms > .001) { "Insufficient speaker signal for acoustic measurement: $rawRms" }
            check(attenuation >= 6) { "Media AEC acoustic attenuation only $attenuation dB; inspect timing/reference" }
            // Explicit stop/flush/reopen exercises playback epoch reset without
            // freeing a live JNI handle or leaving stale future reference data.
            keepWriting.set(false)
            writer?.join(500)
            aec.stopOutput(output)
            output.pause(); output.flush()
            aec.beginOutput()
            check(manager.mode == AudioManager.MODE_NORMAL)
        } finally {
            keepWriting.set(false)
            try { track?.stop() } catch (_: Exception) { }
            writer?.join(1000)
            try { record?.stop() } catch (_: Exception) { }
            record?.release()
            track?.release()
            aec.close()
            continuous.close()
            manager.setStreamVolume(AudioManager.STREAM_MUSIC, savedVolume, 0)
            manager.mode = savedMode
        }
    }
}
