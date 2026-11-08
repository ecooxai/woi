package dev.woi.woi

import android.content.Context
import android.media.AudioManager
import com.cloudwebrtc.webrtc.FlutterWebRTCPlugin
import org.webrtc.audio.WoiAudioRouteAccess

/** Applies the user's route before a new live peer connection opens playout. */
object WoiLiveAudio {
    @Volatile private var selectedRoute = "phone"

    fun configure(route: String?): Map<String, Any> {
        val module = FlutterWebRTCPlugin.sharedSingleton?.audioDeviceModule
            ?: throw IllegalStateException("WebRTC audio is not initialized")
        selectedRoute = if (route == "media") "media" else "phone"
        WoiAudioRouteAccess.configure(module, selectedRoute == "media")
        return status()
    }

    fun status(): Map<String, Any> {
        val module = FlutterWebRTCPlugin.sharedSingleton?.audioDeviceModule
        val manager = WoiBridge.appContext.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        return mapOf(
            "route" to selectedRoute,
            "mode" to manager.mode,
            "playbackUsage" to (module?.let { WoiAudioRouteAccess.usage(it) } ?: -1),
            "initialized" to (module != null),
        )
    }
}
