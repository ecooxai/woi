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
 *  - "media": playback is an ordinary USAGE_MEDIA stream, capture uses
 *    VOICE_RECOGNITION plus the AcousticEchoCanceler effect where the device
 *    has one; the shared Dart echo guard covers the rest.
 *
 * Also owns the transient audio focus (other apps' music ducks while Woi
 * speaks).
 */
object WoiAudioRoute {
    const val PHONE = "phone"
    const val MEDIA = "media"

    @Volatile var route = PHONE
        private set

    private var commActive = false
    private var savedMode = AudioManager.MODE_NORMAL
    private var savedSpeaker = false

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

    /** Enters the call path (phone route, mic open). Main thread. */
    fun enterCommunication() {
        if (!isPhone || commActive) return
        val am = am()
        commActive = true
        savedMode = am.mode
        @Suppress("DEPRECATION")
        savedSpeaker = am.isSpeakerphoneOn
        try {
            am.mode = AudioManager.MODE_IN_COMMUNICATION
        } catch (e: Exception) {
            Log.w(WoiBridge.TAG, "MODE_IN_COMMUNICATION refused", e)
        }
        selectDevice(am)
        ensureCallVolume(am)
        Log.i(WoiBridge.TAG, "audio route: phone (mode=${am.mode}, device=${deviceName(am)})")
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

    /**
     * The call stream has its own volume, often low after a call on the
     * earpiece. Raised to 70% when it is below half (never lowered).
     */
    private fun ensureCallVolume(am: AudioManager) {
        val s = AudioManager.STREAM_VOICE_CALL
        val max = am.getStreamMaxVolume(s)
        val cur = am.getStreamVolume(s)
        if (max > 0 && cur * 2 < max) {
            val v = (max * 7 + 9) / 10
            try {
                am.setStreamVolume(s, v, 0)
                Log.i(WoiBridge.TAG, "call volume $cur -> $v of $max")
            } catch (e: Exception) {
                Log.w(WoiBridge.TAG, "call volume not raised", e)
            }
        }
    }

    // ---------------- audio focus ----------------

    private var focus: AudioFocusRequest? = null

    /** Other apps duck (or pause) while Woi speaks. Any thread. */
    fun requestSpeechFocus() {
        WoiBridge.main.post {
            if (focus != null) return@post
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
