package dev.woi.woi

import android.Manifest
import android.app.Activity
import android.app.Instrumentation
import android.app.UiAutomation
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioTrack
import android.media.MediaRecorder
import android.media.projection.MediaProjectionConfig
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Bundle
import android.os.SystemClock
import android.view.WindowManager
import android.view.accessibility.AccessibilityNodeInfo
import android.widget.TextView
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicReference
import kotlin.math.PI
import kotlin.math.sin

/** Substituted for MainActivity only by the audio instrumentation group.
 * The target UID owns real projection consent; no Flutter engine is created. */
class HeldAudioTestActivity : Activity() {
    @Volatile var consentResult: Int? = null

    override fun onCreate(state: Bundle?) {
        super.onCreate(state)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        setContentView(TextView(this).apply {
            text = "Woi native audio check\nCaptured samples are discarded.\nNo chat connection is opened."
            contentDescription = "woi-held-audio-test"
            textSize = 22f
            setPadding(32, 64, 32, 32)
        })
    }

    @Suppress("DEPRECATION")
    fun requestShare() {
        consentResult = null
        val manager = getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
        val intent = if (Build.VERSION.SDK_INT >= 34) {
            manager.createScreenCaptureIntent(MediaProjectionConfig.createConfigForDefaultDisplay())
        } else manager.createScreenCaptureIntent()
        startActivityForResult(intent, 4128)
    }

    @Deprecated("Uses the platform activity result API to mirror native production consent")
    override fun onActivityResult(request: Int, code: Int, data: Intent?) {
        super.onActivityResult(request, code, data)
        if (request != 4128) return
        consentResult = code
        if (code == RESULT_OK && data != null) WoiForegroundService.startShare(this, code, data)
    }
}

/** Real Android AudioRecord/projection checks. All PCM callbacks are discarded;
 * only source counts/RMS, errors, and native release state enter the report.
 * Run PythonInstrumentation with -e group audio. This does not test UI gestures. */
class HeldAudioDeviceCheck(private val host: Instrumentation) {
    private lateinit var ui: UiAutomation
    private var activity: HeldAudioTestActivity? = null
    private var fixture: AudioTrack? = null
    private var ordinaryOpen = false
    private val log = StringBuilder()
    private val measurements = JSONArray()
    private var passed = 0
    private val ctx get() = host.targetContext

    private class DiscardSink : EventChannel.EventSink {
        val bytes = AtomicLong()
        @Volatile var ready = false
        @Volatile var error: String? = null
        @Volatile var ended = false
        override fun success(event: Any?) {
            when (event) {
                is ByteArray -> bytes.addAndGet(event.size.toLong())
                is Map<*, *> -> if (event["ready"] == true) ready = true
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

    private fun verify(label: String, block: () -> Unit) {
        block()
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
        waitFor("held sources released", 3000) {
            main { WoiHeldAudio.status().let { it["active"] == false && it["closing"] == 0 } }
        }
        // The release callback and diagnostic update are separate main posts.
        waitFor("final release diagnostic", 3000) {
            main { WoiHeldAudio.status().let { it["generation"] == null || it["released"] == true } }
        }
        return main { WoiHeldAudio.status() }
    }

    private fun begin(): DiscardSink = DiscardSink().also { sink ->
        main { WoiHeldAudio.handler.onListen(null, sink) }
    }

    private fun capture(label: String, samples: Long = 48000): Pair<DiscardSink, Map<String, Any?>> {
        val sink = begin()
        waitFor("$label ready") {
            check(sink.error == null) { sink.error ?: "Capture failed" }
            sink.ready
        }
        waitFor("$label samples", 10000) {
            check(sink.error == null) { sink.error ?: "Capture failed" }
            main { (WoiHeldAudio.status()["samples_per_source"] as? Number)?.toLong() ?: 0L } >= samples
        }
        val active = main { WoiHeldAudio.status() }
        // A quiet MI8 VOICE_COMMUNICATION path may gate to exact zeros
        // (also documented in WoiAudio). No external near-end stimulus is
        // supplied here: require an unsilenced native capture configuration,
        // report its actual RMS, and never claim physical microphone signal.
        val manager = ctx.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        val micConfiguration = checkNotNull(manager.activeRecordingConfigurations.firstOrNull {
            it.clientAudioSource == MediaRecorder.AudioSource.VOICE_COMMUNICATION
        }) { "No active native microphone configuration: $active" }
        check(!micConfiguration.isClientSilenced) { "Android silenced the microphone: $active" }
        check((active["system_rms"] as Number).toDouble() > 0.000001) {
            "Capturable media is absent or muted: $active; media volume=${(ctx.getSystemService(Context.AUDIO_SERVICE) as AudioManager).getStreamVolume(AudioManager.STREAM_MUSIC)}"
        }
        check(sink.bytes.get() > 0) { "Native capture produced no PCM callbacks" }
        val final = stopHeld()
        check(final["generation"] == active["generation"] && final["released"] == true) { final.toString() }
        val bytesAtStop = sink.bytes.get()
        SystemClock.sleep(160)
        check(sink.bytes.get() == bytesAtStop) { "PCM delivered after release acknowledgement" }
        measurements.put(JSONObject(final).put("label", label).put("discarded_pcm_bytes", bytesAtStop)
            .put("mic_client_silenced", micConfiguration.isClientSilenced)
            .put("mic_signal_observed", (final["mic_rms"] as Number).toDouble() > 0.0))
        return Pair(sink, final)
    }

    private fun consentButton(): AccessibilityNodeInfo? {
        fun find(node: AccessibilityNodeInfo): AccessibilityNodeInfo? {
            val label = node.text?.toString()?.trim()?.lowercase()
            if (node.isEnabled && node.isClickable &&
                (node.viewIdResourceName == "android:id/button1" ||
                    label in setOf("start now", "start", "share screen", "share", "allow"))) return node
            for (i in 0 until node.childCount) {
                find(node.getChild(i) ?: continue)?.let { return it }
            }
            return null
        }
        val root = ui.rootInActiveWindow ?: return null
        if (root.packageName?.toString() !in setOf("com.android.systemui", "android")) return null
        return find(root)
    }

    private fun approveShare(cancelWhilePending: Boolean = false) {
        main { checkNotNull(activity).requestShare() }
        waitFor("actual projection consent dialog") { consentButton() != null }
        if (cancelWhilePending) {
            // Native half of release-during-consent. Dart gesture cancellation
            // is covered separately; granting consent must not start a recorder.
            stopHeld()
        }
        check(checkNotNull(consentButton()).performAction(AccessibilityNodeInfo.ACTION_CLICK)) {
            "Could not approve the visible Android projection dialog"
        }
        waitFor("projection foreground service") {
            check(activity?.consentResult != Activity.RESULT_CANCELED) { "Projection consent was cancelled" }
            main { WoiScreen.isSharing() && WoiScreen.projectionForAudio() != null }
        }
        check(main { !WoiHeldAudio.isRequested() }) { "Consent unexpectedly opened a held recorder" }
    }

    private fun startFixture() {
        check(Build.VERSION.SDK_INT >= 29)
        val rate = 24000
        val tone = ShortArray(rate * 2) { index ->
            (32767 * 0.035 * (sin(2 * PI * 731 * index / rate) + sin(2 * PI * 1097 * index / rate))).toInt().toShort()
        }
        val track = AudioTrack.Builder()
            .setAudioAttributes(AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_MEDIA)
                .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                .setAllowedCapturePolicy(AudioAttributes.ALLOW_CAPTURE_BY_ALL).build())
            .setAudioFormat(AudioFormat.Builder().setSampleRate(rate)
                .setChannelMask(AudioFormat.CHANNEL_OUT_MONO).setEncoding(AudioFormat.ENCODING_PCM_16BIT).build())
            .setBufferSizeInBytes(tone.size * 2).setTransferMode(AudioTrack.MODE_STATIC).build()
        fixture = track
        check(track.state != AudioTrack.STATE_UNINITIALIZED) { "Known media AudioTrack could not initialize" }
        check(track.write(tone, 0, tone.size) == tone.size) { "Known media fixture was not fully written" }
        check(track.state == AudioTrack.STATE_INITIALIZED)
        check(track.setLoopPoints(0, tone.size, -1) == AudioTrack.SUCCESS)
        track.play()
        check(track.playState == AudioTrack.PLAYSTATE_PLAYING)
        SystemClock.sleep(160)
    }

    private fun stopFixture() {
        fixture?.let { track ->
            fixture = null
            try { track.stop() } finally { track.release() }
        }
    }

    fun run() {
        var failure: Throwable? = null
        val preferences = ctx.getSharedPreferences("woi_audio", Context.MODE_PRIVATE)
        val hadAec = preferences.contains("aec")
        val hadRoute = preferences.contains("route")
        val originalAec = preferences.getBoolean("aec", true)
        val originalRoute = preferences.getString("route", null)
        try {
            check(Build.VERSION.SDK_INT >= 29) { "Audio playback capture requires API 29+" }
            check(ctx.checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED) {
                "RECORD_AUDIO permission is not granted; device check cannot capture"
            }
            main {
                WoiBridge.ensureContext(ctx)
                check(WoiEngine.peek() == null) { "Flutter engine is active; refusing to risk sending ambient microphone audio" }
            }
            ui = host.getUiAutomation(UiAutomation.FLAG_DONT_SUPPRESS_ACCESSIBILITY_SERVICES)
            activity = host.startActivitySync(Intent().setClassName(ctx.packageName, "dev.woi.woi.MainActivity")
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK)) as HeldAudioTestActivity
            verify("native activity has no Flutter chat engine") { check(main { WoiEngine.peek() == null }) }
            verify("cold capture without consent fails explicitly") {
                check(main { !WoiScreen.isSharing() }) { "Expected a fresh instrumentation process" }
                val sink = begin()
                waitFor("missing projection error") { sink.error != null }
                check(sink.error!!.contains("Allow screen and audio capture")) { sink.error!! }
                check(!sink.ready && sink.bytes.get() == 0L)
                stopHeld()
            }
            verify("release during actual projection consent leaves capture closed") {
                approveShare(cancelWhilePending = true)
                SystemClock.sleep(200)
                check(main { !WoiHeldAudio.isRequested() })
            }
            startFixture()
            var previousGeneration = -1
            repeat(2) { index ->
                verify("mic and known system media capture ${index + 1} releases both sources") {
                    val result = capture("repeated_${index + 1}").second
                    val generation = (result["generation"] as Number).toInt()
                    check(generation > previousGeneration)
                    previousGeneration = generation
                }
            }
            verify("immediate native cancellation cannot start a late recorder") {
                val sink = DiscardSink()
                main { WoiHeldAudio.handler.onListen(null, sink); WoiHeldAudio.stop() }
                val result = stopHeld()
                SystemClock.sleep(300)
                check(!sink.ready && sink.bytes.get() == 0L && main { !WoiHeldAudio.isRequested() })
                measurements.put(JSONObject(result).put("label", "immediate_cancel"))
            }
            verify("projection revocation cancels capture and releases both sources") {
                val sink = begin()
                waitFor("capture before revocation") {
                    check(sink.error == null) { sink.error ?: "Capture failed" }
                    sink.ready && sink.bytes.get() > 0
                }
                main { checkNotNull(WoiScreen.projectionForAudio()).stop() }
                waitFor("projection revocation error") { sink.error != null }
                check(sink.error!!.contains("permission ended", ignoreCase = true)) { sink.error!! }
                val result = stopHeld()
                waitFor("revoked projection cleared") { main { !WoiScreen.isSharing() } }
                check(result["released"] == true)
                measurements.put(JSONObject(result).put("label", "projection_revoked"))
            }
            verify("new projection after revocation records both sources") {
                approveShare()
                capture("after_projection_recovery")
            }
            stopFixture()
            verify("ordinary native microphone resumes after held sources release") {
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
            verify("native checks never create a chat engine") { check(main { WoiEngine.peek() == null }) }
        } catch (error: Throwable) {
            failure = error
        } finally {
            fun clean(block: () -> Unit) {
                try { block() } catch (error: Throwable) {
                    if (failure == null) failure = error else failure?.addSuppressed(error)
                }
            }
            clean { stopHeld() }
            clean { stopFixture() }
            clean { main {
                if (ordinaryOpen) WoiAudio.micHandler.onCancel(null)
                ordinaryOpen = false
                WoiScreen.stop(ctx)
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
