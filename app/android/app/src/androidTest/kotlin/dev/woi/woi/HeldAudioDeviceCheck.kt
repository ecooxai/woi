package dev.woi.woi

import android.Manifest
import android.app.Activity
import android.app.Instrumentation
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.media.AudioManager
import android.media.MediaRecorder
import android.os.Build
import android.os.Bundle
import android.os.SystemClock
import android.view.WindowManager
import android.widget.TextView
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicReference

/** Substituted for MainActivity only by the audio instrumentation group.
 * The target UID owns a native microphone check, with no Flutter/chat engine. */
class HeldAudioTestActivity : Activity() {
    override fun onCreate(state: Bundle?) {
        super.onCreate(state)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        setContentView(TextView(this).apply {
            text = "Woi microphone check\nCaptured samples are discarded.\nScreen sharing stays off."
            contentDescription = "woi-held-audio-test"
            textSize = 22f
            setPadding(32, 64, 32, 32)
        })
    }
}

/** Real Android microphone lifecycle checks. All PCM callbacks are discarded;
 * only counts/RMS, errors, and native release state enter the report.
 * Run PythonInstrumentation with -e group audio. No projection is requested. */
class HeldAudioDeviceCheck(private val host: Instrumentation) {
    private var activity: HeldAudioTestActivity? = null
    private var ordinaryOpen = false
    private val log = StringBuilder()
    private val measurements = JSONArray()
    private var passed = 0
    private val ctx get() = host.targetContext

    private class DiscardSink : EventChannel.EventSink {
        val bytes = AtomicLong()
        @Volatile var ready = false
        @Volatile var sources: List<*>? = null
        @Volatile var error: String? = null
        @Volatile var ended = false
        override fun success(event: Any?) {
            when (event) {
                is ByteArray -> bytes.addAndGet(event.size.toLong())
                is Map<*, *> -> if (event["ready"] == true) {
                    sources = event["sources"] as? List<*>
                    ready = true
                }
            }
        }
        override fun error(code: String, message: String?, details: Any?) { error = "$code: $message" }
        override fun endOfStream() { ended = true }
    }

    private fun <T> main(block: () -> T): T {
        val value = AtomicReference<T>()
        val error = AtomicReference<Throwable>()
        host.runOnMainSync {
            try { value.set(block()) } catch (failure: Throwable) { error.set(failure) }
        }
        error.get()?.let { throw it }
        return value.get()
    }

    private fun waitFor(label: String, timeout: Long = 8000, condition: () -> Boolean) {
        val until = SystemClock.elapsedRealtime() + timeout
        while (!condition()) {
            check(SystemClock.elapsedRealtime() < until) { "Timed out: $label; native=${main { WoiHeldAudio.status() }}" }
            SystemClock.sleep(40)
        }
    }

    private fun assertNoProjection() {
        check(main { !WoiScreen.isSharing() && !WoiForegroundService.share }) {
            "A microphone-only hold started screen sharing"
        }
    }

    private fun verify(label: String, block: () -> Unit) {
        assertNoProjection()
        block()
        assertNoProjection()
        passed++
        log.append("PASS ").append(label).append('\n')
    }

    private fun stopHeld(): Map<String, Any?> {
        val done = CountDownLatch(1)
        var error: String? = null
        main {
            WoiHeldAudio.stopAndReply(object : MethodChannel.Result {
                override fun success(result: Any?) { done.countDown() }
                override fun error(code: String, message: String?, details: Any?) {
                    error = "$code: $message"; done.countDown()
                }
                override fun notImplemented() { error = "stop not implemented"; done.countDown() }
            })
        }
        check(done.await(5, TimeUnit.SECONDS)) { "Native release acknowledgement timed out" }
        check(error == null) { error ?: "Native release failed" }
        waitFor("held microphone released", 3000) {
            main { WoiHeldAudio.status().let { it["active"] == false && it["closing"] == 0 } }
        }
        waitFor("final release diagnostic", 3000) {
            main { WoiHeldAudio.status().let { it["generation"] == null || it["released"] == true } }
        }
        return main { WoiHeldAudio.status() }
    }

    private fun begin(): DiscardSink = DiscardSink().also { sink ->
        assertNoProjection()
        main { WoiHeldAudio.handler.onListen(null, sink) }
    }

    private fun waitReady(sink: DiscardSink) {
        waitFor("microphone ready without projection") {
            check(sink.error == null) { sink.error ?: "Capture failed" }
            sink.ready
        }
        check(sink.sources == listOf("microphone")) { "Unexpected capture sources: ${sink.sources}" }
        assertNoProjection()
    }

    private fun capture(label: String, samples: Long = 24000): Map<String, Any?> {
        val sink = begin()
        waitReady(sink)
        waitFor("$label samples", 10000) {
            check(sink.error == null) { sink.error ?: "Capture failed" }
            main { (WoiHeldAudio.status()["mic_samples"] as? Number)?.toLong() ?: 0L } >= samples
        }
        val active = main { WoiHeldAudio.status() }
        // The MI8's quiet-room AEC/NS can deliver exact zeros. Check native
        // eligibility and report real RMS; do not claim calibrated acoustics.
        val manager = ctx.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        val configuration = checkNotNull(manager.activeRecordingConfigurations.firstOrNull {
            it.clientAudioSource == MediaRecorder.AudioSource.VOICE_COMMUNICATION
        }) { "No active native microphone configuration: $active" }
        check(!configuration.isClientSilenced) { "Android silenced the microphone: $active" }
        check(sink.bytes.get() > 0) { "Native capture produced no PCM callbacks" }
        check(active["sources"] == listOf("microphone")) { active.toString() }
        val final = stopHeld()
        check(final["generation"] == active["generation"] && final["released"] == true) { final.toString() }
        val bytesAtStop = sink.bytes.get()
        SystemClock.sleep(160)
        check(sink.bytes.get() == bytesAtStop) { "PCM delivered after release acknowledgement" }
        measurements.put(JSONObject(final).put("label", label).put("discarded_pcm_bytes", bytesAtStop)
            .put("mic_client_silenced", configuration.isClientSilenced)
            .put("mic_signal_observed", (final["mic_rms"] as Number).toDouble() > 0.0))
        return final
    }

    fun run() {
        var failure: Throwable? = null
        val preferences = ctx.getSharedPreferences("woi_audio", Context.MODE_PRIVATE)
        val hadAec = preferences.contains("aec")
        val hadRoute = preferences.contains("route")
        val originalAec = preferences.getBoolean("aec", true)
        val originalRoute = preferences.getString("route", null)
        try {
            check(Build.VERSION.SDK_INT >= 29) { "Native silencing verification requires API 29+" }
            check(ctx.checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED) {
                "RECORD_AUDIO permission is not granted; device check cannot capture"
            }
            main {
                WoiBridge.ensureContext(ctx)
                check(WoiEngine.peek() == null) { "Flutter engine is active; refusing to risk sending microphone audio" }
            }
            activity = host.startActivitySync(Intent().setClassName(ctx.packageName, "dev.woi.woi.MainActivity")
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK)) as HeldAudioTestActivity
            verify("native activity starts without projection or a Flutter chat engine") {
                check(main { WoiEngine.peek() == null })
            }
            var previousGeneration = -1
            repeat(2) { index ->
                verify("microphone-only hold ${index + 1} starts without consent and releases") {
                    val result = capture("repeated_${index + 1}")
                    val generation = (result["generation"] as Number).toInt()
                    check(generation > previousGeneration)
                    previousGeneration = generation
                }
            }
            verify("immediate native cancellation cannot start a late microphone") {
                val sink = DiscardSink()
                main { WoiHeldAudio.handler.onListen(null, sink); WoiHeldAudio.stop() }
                val result = stopHeld()
                SystemClock.sleep(300)
                check(!sink.ready && sink.bytes.get() == 0L && main { !WoiHeldAudio.isRequested() })
                check((result["mic_samples"] as Number).toLong() == 0L)
                measurements.put(JSONObject(result).put("label", "immediate_cancel"))
            }
            verify("native cancellation reports an error and releases the microphone") {
                val sink = begin()
                waitReady(sink)
                main { WoiHeldAudio.cancel("Native microphone cancellation check") }
                waitFor("native cancellation error") { sink.error != null && sink.ended }
                check(sink.error!!.contains("Native microphone cancellation check")) { sink.error!! }
                val result = stopHeld()
                check(result["released"] == true)
                measurements.put(JSONObject(result).put("label", "native_cancel"))
            }
            verify("microphone-only capture restarts after cancellation without consent") {
                capture("after_cancel_recovery")
            }
            verify("ordinary native microphone resumes after held microphone release") {
                val sink = DiscardSink()
                main { WoiForegroundService.startVoice(ctx) }
                waitFor("ordinary microphone foreground service") { WoiForegroundService.voice }
                main {
                    ordinaryOpen = true
                    WoiAudio.micHandler.onListen(mapOf("aec" to originalAec, "route" to originalRoute), sink)
                }
                waitFor("ordinary microphone PCM", 15000) {
                    check(sink.error == null) { sink.error ?: "Ordinary microphone failed" }
                    sink.bytes.get() >= 4800
                }
                val status = WoiAudio.status
                check(!status.contains("silenced", ignoreCase = true) && !status.contains("yield", ignoreCase = true)) { status }
                main { WoiAudio.micHandler.onCancel(null); ordinaryOpen = false }
                measurements.put(JSONObject().put("label", "ordinary_mic_restored")
                    .put("discarded_pcm_bytes", sink.bytes.get()).put("status", status))
            }
            verify("native microphone checks never create a chat engine or projection") {
                check(main { WoiEngine.peek() == null })
            }
        } catch (error: Throwable) {
            failure = error
        } finally {
            fun clean(block: () -> Unit) {
                try { block() } catch (error: Throwable) {
                    if (failure == null) failure = error else failure.addSuppressed(error)
                }
            }
            clean { stopHeld() }
            clean { main {
                if (ordinaryOpen) WoiAudio.micHandler.onCancel(null)
                ordinaryOpen = false
                WoiForegroundService.stopVoice(ctx)
                activity?.finish()
            } }
            clean {
                val edit = preferences.edit()
                if (hadAec) edit.putBoolean("aec", originalAec) else edit.remove("aec")
                if (hadRoute) edit.putString("route", originalRoute) else edit.remove("route")
                check(edit.commit()) { "Could not restore native audio preferences" }
            }
        }
        log.append("MEASUREMENTS ").append(measurements.toString()).append('\n')
        failure?.let { log.append("FAIL ").append(it.stackTraceToString()).append('\n') }
        host.finish(if (failure == null) Activity.RESULT_OK else Activity.RESULT_CANCELED, Bundle().apply {
            putInt("passed", passed)
            putString("stream", log.toString())
            putString("audio_measurements", measurements.toString())
            failure?.let { putString("failure", it.toString()) }
        })
    }
}
