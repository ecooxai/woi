package dev.woi.woi

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.util.Log

/**
 * One foreground service for everything that must keep running while Woi is
 * not in front: the microphone (voice session), screen share
 * (mediaProjection) and the sign-in callback server (dataSync, so the cached
 * app freezer does not stop the loopback server while the browser is open).
 */
class WoiForegroundService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    /** Cheap accessibility check while Woi runs in the background. */
    private val keepA11y = object : Runnable {
        override fun run() {
            WoiA11yKeeper.ensure(this@WoiForegroundService, "periodic")
            WoiBridge.main.postDelayed(this, A11Y_CHECK_MS)
        }
    }

    override fun onCreate() {
        super.onCreate()
        instance = this
        WoiBridge.main.post(keepA11y)
    }

    override fun onDestroy() {
        WoiBridge.main.removeCallbacks(keepA11y)
        heldAudioForegroundReady = false
        if (heldAudio) WoiHeldAudio.cancel("Recording service stopped")
        if (instance === this) instance = null
        super.onDestroy()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_VOICE -> { voice = true; voiceWarm = false }
            ACTION_LOGIN -> login = true
            ACTION_SHARE -> share = true
            ACTION_HELD_AUDIO -> heldAudio = WoiHeldAudio.isRequested()
            ACTION_STOP_ALL -> {
                voice = false; voiceWarm = false; login = false; heldAudio = false
                WoiHeldAudio.cancel("Recording stopped")
                WoiScreen.stop(this)
                share = false
                WoiBridge.emit(mapOf("type" to "stopAll"))
            }
        }
        // startForegroundService() needs a startForeground() call even when
        // this request turned everything off.
        if (!refresh(force = true)) return START_NOT_STICKY
        if (intent?.action == ACTION_SHARE) {
            val code = intent.getIntExtra("code", 0)
            @Suppress("DEPRECATION")
            val data: Intent? = intent.getParcelableExtra("data")
            if (data == null || !WoiScreen.start(this, code, data)) {
                share = false
                refresh()
                WoiBridge.emit(mapOf("type" to "share", "on" to false, "error" to "projection refused"))
            }
        }
        return START_NOT_STICKY
    }

    /** Re-posts the notification with the types in use, or stops. */
    fun refresh(force: Boolean = false): Boolean {
        var type = 0
        // Warm (session kept, mic closed): no microphone type, so no
        // mic-in-use notification; dataSync keeps the socket's process from
        // being frozen until the keep-alive ends.
        if (micOn() && hasMic()) type = type or ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
        if (share) type = type or ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION
        if (login) type = type or ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
        val any = voice || login || share || heldAudio
        if (type == 0 && (any || force)) type = ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
        if (type != 0) {
            try {
                startForeground(NOTIF_ID, notification(), type)
                heldAudioForegroundReady = heldAudio && (type and ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE) != 0
                if (heldAudioForegroundReady) heldAudioForegroundError = null
            } catch (e: Exception) {
                Log.w(WoiBridge.TAG, "startForeground($type) failed", e)
                heldAudioForegroundReady = false
                if (heldAudio) {
                    heldAudioForegroundError = e.message ?: e.javaClass.simpleName
                    WoiHeldAudio.cancel("Microphone foreground service was refused")
                }
                if (share) {
                    share = false
                    WoiBridge.emit(mapOf("type" to "share", "on" to false, "error" to (e.message ?: "$e")))
                }
            }
        }
        if (!(voice || login || share || heldAudio)) {
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf()
            return false
        }
        return true
    }

    private fun micOn() = heldAudio || (voice && !voiceWarm)

    /** Only the warm voice session runs: the quiet (minimised) notification. */
    private fun quiet() = voice && voiceWarm && !login && !share && !heldAudio

    private fun hasMic() = WoiBridge.hasPermission(this, android.Manifest.permission.RECORD_AUDIO)

    private fun notification(): Notification {
        val nm = getSystemService(NotificationManager::class.java)
        if (nm.getNotificationChannel(CHANNEL) == null) {
            nm.createNotificationChannel(NotificationChannel(CHANNEL, "Woi session", NotificationManager.IMPORTANCE_LOW))
        }
        val quiet = quiet()
        if (quiet && nm.getNotificationChannel(CHANNEL_WARM) == null) {
            // MIN: no status bar icon, collapsed at the bottom of the shade.
            nm.createNotificationChannel(
                NotificationChannel(CHANNEL_WARM, "Woi standby (mic off)", NotificationManager.IMPORTANCE_MIN)
            )
        }
        val open = PendingIntent.getActivity(
            this, 0, Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE
        )
        val stop = PendingIntent.getService(
            this, 1, Intent(this, WoiForegroundService::class.java).setAction(ACTION_STOP_ALL),
            PendingIntent.FLAG_IMMUTABLE
        )
        val what = listOfNotNull(
            if (share) "sharing the screen" else null,
            if (heldAudio) "recording microphone" else null,
            if (micOn()) "voice on" else if (voice) "standby · mic off" else null,
            if (login) "waiting for sign-in" else null,
        ).joinToString(" · ")
        return Notification.Builder(this, if (quiet) CHANNEL_WARM else CHANNEL)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle("Woi")
            .setContentText(what)
            .setContentIntent(open)
            .setOngoing(true)
            .addAction(Notification.Action.Builder(null, if (share) "Stop sharing" else "Stop", stop).build())
            .build()
    }

    companion object {
        private const val CHANNEL = "woi_session"
        private const val CHANNEL_WARM = "woi_standby"
        private const val NOTIF_ID = 42
        private const val A11Y_CHECK_MS = 30_000L
        const val ACTION_VOICE = "woi.voice"
        const val ACTION_LOGIN = "woi.login"
        const val ACTION_SHARE = "woi.share"
        const val ACTION_HELD_AUDIO = "woi.held_audio"
        const val ACTION_STOP_ALL = "woi.stop_all"

        // Process-wide state (one service instance).
        @Volatile var voice = false
        /** Voice session kept warm with the mic closed (see [warmVoice]). */
        @Volatile var voiceWarm = false
        @Volatile var login = false
        @Volatile var share = false
        @Volatile var heldAudio = false
        @Volatile var heldAudioForegroundReady = false
        @Volatile var heldAudioForegroundError: String? = null

        private fun send(ctx: Context, action: String, extra: (Intent) -> Unit = {}) {
            val i = Intent(ctx, WoiForegroundService::class.java).setAction(action)
            extra(i)
            try {
                ctx.startForegroundService(i)
            } catch (e: Exception) {
                Log.w(WoiBridge.TAG, "foreground service $action refused", e)
                if (action == ACTION_HELD_AUDIO) {
                    heldAudioForegroundError = e.message ?: e.javaClass.simpleName
                    heldAudioForegroundReady = false
                    WoiHeldAudio.cancel("Microphone foreground service could not start")
                }
            }
        }

        @Volatile var instance: WoiForegroundService? = null

        private fun off(apply: () -> Unit) {
            WoiBridge.main.post {
                apply()
                instance?.refresh()
            }
        }

        /**
         * Microphone-type service. Leaving warm goes through
         * startForegroundService again so Android re-evaluates the
         * while-in-use (mic) eligibility now, while Woi is visible.
         */
        fun startVoice(ctx: Context) { if (!voice || voiceWarm || instance == null) send(ctx, ACTION_VOICE) }
        fun stopVoice(@Suppress("UNUSED_PARAMETER") ctx: Context) = off { voice = false; voiceWarm = false }

        /**
         * The mic closed but the session stays connected (assistant panel
         * dismissed): drop the microphone type and its notification; a quiet
         * dataSync one keeps the process alive. [startVoice] goes back.
         */
        fun warmVoice(@Suppress("UNUSED_PARAMETER") ctx: Context) = off { if (voice) voiceWarm = true }
        fun startHeldAudio(ctx: Context) {
            heldAudioForegroundReady = false
            heldAudioForegroundError = null
            send(ctx, ACTION_HELD_AUDIO)
        }
        fun stopHeldAudio() {
            heldAudio = WoiHeldAudio.isRequested()
            if (!heldAudio) heldAudioForegroundReady = false
            off {
                heldAudio = WoiHeldAudio.isRequested()
                if (!heldAudio) heldAudioForegroundReady = false
            }
        }

        fun startLogin(ctx: Context) = send(ctx, ACTION_LOGIN)
        fun stopLogin(@Suppress("UNUSED_PARAMETER") ctx: Context) = off { login = false }
        fun startShare(ctx: Context, code: Int, data: Intent) = send(ctx, ACTION_SHARE) {
            it.putExtra("code", code)
            it.putExtra("data", data)
        }

        fun shareStopped(@Suppress("UNUSED_PARAMETER") ctx: Context) = off {
            // A previous projection may finish stopping after its replacement
            // starts. Derive the service type from the current owner.
            share = WoiScreen.isSharing()
        }
    }
}
