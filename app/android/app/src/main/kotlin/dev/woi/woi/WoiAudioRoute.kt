package dev.woi.woi

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioDeviceInfo
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.os.Build
import android.util.Log

/**
 * The Android audio route for Woi's own capture/playback (WoiAudio):
 *
 *  - "phone" (default): the platform's call path. While the mic is open
 *    the audio mode is MODE_IN_COMMUNICATION, playback uses
 *    USAGE_VOICE_COMMUNICATION and capture VOICE_COMMUNICATION, so the
 *    HAL's call echo canceller (referenced to the whole output mix, other
 *    apps' media included) runs. Output goes to a headset when one is
 *    connected (Bluetooth / wired / USB), else the loudspeaker.
 *  - "media": playback remains an ordinary USAGE_MEDIA stream. Capture uses
 *    VOICE_RECOGNITION in MODE_NORMAL with timestamp-aligned SpeexDSP software
 *    echo cancellation against Woi's actual rendered PCM. Other apps' media
 *    pauses while the mic is open (transient focus), because its PCM is not
 *    available to this canceller without a separate capture permission.
 *
 * Also owns the transient audio focus (other apps' music ducks while Woi
 * speaks).
 */
object WoiAudioRoute {
    const val PHONE = "phone"
    const val MEDIA = "media"

    @Volatile var route = PHONE
        private set

    // Main thread, or the audio thread during WoiAudio's early start (the
    // main thread leaves the call mode alone meanwhile).
    @Volatile private var commActive = false
    @Volatile private var savedMode = AudioManager.MODE_NORMAL
    @Volatile private var savedSpeaker = false

    private fun am(): AudioManager = WoiBridge.appContext.getSystemService(Context.AUDIO_SERVICE) as AudioManager

    val isPhone get() = route == PHONE
    val inCommunication get() = commActive

    /** Sets the route; returns true when it changed. */
    fun setRoute(r: String?): Boolean {
        val next = if (r == MEDIA) MEDIA else PHONE
        if (next == route) return false
        route = next
        return true
    }

    fun playbackAttributes(): AudioAttributes = AudioAttributes.Builder()
        .setUsage(if (isPhone) AudioAttributes.USAGE_VOICE_COMMUNICATION else AudioAttributes.USAGE_MEDIA)
        .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
        .build()

    /** Enters the call path (phone route, mic open). Main thread (or the
     *  audio thread for WoiAudio's early start). */
    fun enterCommunication() {
        if (!isPhone || commActive) return
        val am = am()
        commActive = true
        savedMode = am.mode
        @Suppress("DEPRECATION")
        savedSpeaker = am.isSpeakerphoneOn
        val t0 = android.os.SystemClock.elapsedRealtime()
        try {
            am.mode = AudioManager.MODE_IN_COMMUNICATION
        } catch (e: Exception) {
            Log.w(WoiBridge.TAG, "MODE_IN_COMMUNICATION refused", e)
        }
        // The call volume on its own thread: reading/setting it took 4.5 s on
        // a MI 8 while another app played media, and nothing waits for it
        // (it only matters once Woi speaks).
        volume.post { ensureCallVolume(am) }
        Log.i(WoiBridge.TAG, "audio route: phone (mode=${am.mode}; setMode ${android.os.SystemClock.elapsedRealtime() - t0} ms)")
    }

    /**
     * Picks the call device (headset, else the loudspeaker). Called by
     * WoiAudio right after the recorder started: with another app's media
     * playing this took ~4.8 s on a MI 8, and the capture need not wait for
     * it (the input follows the device once it is set). Same thread as
     * [enterCommunication].
     */
    fun selectCommunicationDevice() {
        if (!commActive) return
        val am = am()
        val t0 = android.os.SystemClock.elapsedRealtime()
        selectDevice(am)
        Log.i(WoiBridge.TAG, "audio route: device=${deviceName(am)} (${android.os.SystemClock.elapsedRealtime() - t0} ms)")
    }

    /** Back to MODE_NORMAL (mic closed, paused for another app, media route). */
    fun leaveCommunication() {
        if (!commActive) return
        commActive = false
        val am = am()
        try {
            if (Build.VERSION.SDK_INT >= 31) am.clearCommunicationDevice()
            else @Suppress("DEPRECATION") { am.isSpeakerphoneOn = savedSpeaker }
            am.mode = if (savedMode == AudioManager.MODE_IN_COMMUNICATION) AudioManager.MODE_NORMAL else savedMode
        } catch (e: Exception) {
            Log.w(WoiBridge.TAG, "restoring the audio mode failed", e)
        }
        Log.i(WoiBridge.TAG, "audio route: left communication (mode=${am.mode})")
    }

    /** Headset (Bluetooth, wired, USB) when connected, else the loudspeaker. */
    private fun selectDevice(am: AudioManager) {
        if (Build.VERSION.SDK_INT >= 31) {
            val devices = am.availableCommunicationDevices
            val order = listOf(
                AudioDeviceInfo.TYPE_BLE_HEADSET,
                AudioDeviceInfo.TYPE_BLUETOOTH_SCO,
                AudioDeviceInfo.TYPE_WIRED_HEADSET,
                AudioDeviceInfo.TYPE_USB_HEADSET,
                AudioDeviceInfo.TYPE_WIRED_HEADPHONES,
                AudioDeviceInfo.TYPE_BUILTIN_SPEAKER,
            )
            val pick = order.firstNotNullOfOrNull { t -> devices.firstOrNull { it.type == t } }
            if (pick != null && !am.setCommunicationDevice(pick)) {
                Log.w(WoiBridge.TAG, "setCommunicationDevice(${pick.type}) refused")
            }
        } else {
            val outs = am.getDevices(AudioManager.GET_DEVICES_OUTPUTS)
            val headset = outs.any {
                it.type == AudioDeviceInfo.TYPE_WIRED_HEADSET || it.type == AudioDeviceInfo.TYPE_WIRED_HEADPHONES ||
                    it.type == AudioDeviceInfo.TYPE_BLUETOOTH_SCO || it.type == AudioDeviceInfo.TYPE_USB_HEADSET
            }
            @Suppress("DEPRECATION")
            am.isSpeakerphoneOn = !headset
        }
    }

    private fun deviceName(am: AudioManager): String =
        if (Build.VERSION.SDK_INT >= 31) am.communicationDevice?.let { "type ${it.type}" } ?: "default"
        else @Suppress("DEPRECATION") if (am.isSpeakerphoneOn) "speaker" else "earpiece/headset"

    private val volume: android.os.Handler by lazy {
        android.os.Handler(android.os.HandlerThread("woi-volume").apply { start() }.looper)
    }

    /**
     * The call stream has its own volume, often low after a call on the
     * earpiece. Raised to 70% when it is below half (never lowered).
     */
    private fun ensureCallVolume(am: AudioManager) {
        val t0 = android.os.SystemClock.elapsedRealtime()
        val s = AudioManager.STREAM_VOICE_CALL
        val max = am.getStreamMaxVolume(s)
        val cur = am.getStreamVolume(s)
        if (max > 0 && cur * 2 < max) {
            val v = (max * 7 + 9) / 10
            try {
                am.setStreamVolume(s, v, 0)
                Log.i(WoiBridge.TAG, "call volume $cur -> $v of $max (${android.os.SystemClock.elapsedRealtime() - t0} ms)")
            } catch (e: Exception) {
                Log.w(WoiBridge.TAG, "call volume not raised", e)
            }
        } else {
            Log.i(WoiBridge.TAG, "call volume $cur of $max kept (${android.os.SystemClock.elapsedRealtime() - t0} ms)")
        }
    }

    // ---------------- audio focus ----------------

    private var focus: AudioFocusRequest? = null

    // Media route: other apps' media pauses while Woi's mic is open. Their
    // audio is not in the software AEC reference (only Woi's own track is), so
    // a podcast would otherwise reach the server as user speech.
    private var listenFocus: AudioFocusRequest? = null
    @Volatile private var listenLost = false

    fun requestListenFocus() {
        WoiBridge.main.post {
            if (listenFocus != null || isPhone) return@post
            val req = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT)
                .setAudioAttributes(
                    AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_ASSISTANT)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH).build()
                )
                .setOnAudioFocusChangeListener { c -> listenLost = c < 0 }
                .build()
            listenFocus = req
            listenLost = false
            val r = am().requestAudioFocus(req)
            Log.i(WoiBridge.TAG, "media route: listen focus (other media pauses) result=$r")
        }
    }

    fun abandonListenFocus() {
        WoiBridge.main.post {
            val req = listenFocus ?: return@post
            listenFocus = null
            am().abandonAudioFocusRequest(req)
        }
    }

    /** Other apps duck (or pause) while Woi speaks. Any thread. */
    fun requestSpeechFocus() {
        WoiBridge.main.post {
            // Another app took the listen focus (e.g. the user started a
            // podcast): take it back when Woi speaks, which pauses it again.
            val lf = listenFocus
            if (lf != null && listenLost) {
                listenLost = false
                val r = am().requestAudioFocus(lf)
                Log.i(WoiBridge.TAG, "media route: listen focus taken back result=$r")
            }
            if (focus != null || listenFocus != null) return@post
            val req = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK)
                .setAudioAttributes(playbackAttributes())
                .setOnAudioFocusChangeListener { }
                .build()
            focus = req
            am().requestAudioFocus(req)
        }
    }

    fun abandonSpeechFocus() {
        WoiBridge.main.post {
            val req = focus ?: return@post
            focus = null
            am().abandonAudioFocusRequest(req)
        }
    }
}
