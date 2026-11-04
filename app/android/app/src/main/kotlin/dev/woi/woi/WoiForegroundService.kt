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

    override fun onCreate() {
        super.onCreate()
        instance = this
    }

    override fun onDestroy() {
        if (instance === this) instance = null
        super.onDestroy()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_VOICE -> voice = true
            ACTION_LOGIN -> login = true
            ACTION_SHARE -> share = true
            ACTION_STOP_ALL -> {
                voice = false; login = false
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
        if (voice && hasMic()) type = type or ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
        if (share) type = type or ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION
        if (login) type = type or ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
        val any = voice || login || share
        if (type == 0 && (any || force)) type = ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
        if (type != 0) {
            try {
                startForeground(NOTIF_ID, notification(), type)
            } catch (e: Exception) {
                Log.w(WoiBridge.TAG, "startForeground($type) failed", e)
                if (share) {
                    share = false
                    WoiBridge.emit(mapOf("type" to "share", "on" to false, "error" to (e.message ?: "$e")))
                }
            }
        }
        if (!(voice || login || share)) {
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf()
            return false
        }
        return true
    }

    private fun hasMic() = WoiBridge.hasPermission(this, android.Manifest.permission.RECORD_AUDIO)

    private fun notification(): Notification {
        val nm = getSystemService(NotificationManager::class.java)
        if (nm.getNotificationChannel(CHANNEL) == null) {
            nm.createNotificationChannel(NotificationChannel(CHANNEL, "Woi session", NotificationManager.IMPORTANCE_LOW))
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
            if (voice) "voice on" else null,
            if (login) "waiting for sign-in" else null,
        ).joinToString(" · ")
        return Notification.Builder(this, CHANNEL)
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
        private const val NOTIF_ID = 42
        const val ACTION_VOICE = "woi.voice"
        const val ACTION_LOGIN = "woi.login"
        const val ACTION_SHARE = "woi.share"
        const val ACTION_STOP_ALL = "woi.stop_all"

        // Process-wide state (one service instance).
        @Volatile var voice = false
        @Volatile var login = false
        @Volatile var share = false

        private fun send(ctx: Context, action: String, extra: (Intent) -> Unit = {}) {
            val i = Intent(ctx, WoiForegroundService::class.java).setAction(action)
            extra(i)
            try {
                ctx.startForegroundService(i)
            } catch (e: Exception) {
                Log.w(WoiBridge.TAG, "foreground service $action refused", e)
            }
        }

        @Volatile var instance: WoiForegroundService? = null

        private fun off(apply: () -> Unit) {
            WoiBridge.main.post {
                apply()
                instance?.refresh()
            }
        }

        fun startVoice(ctx: Context) { if (!voice || instance == null) send(ctx, ACTION_VOICE) }
        fun stopVoice(@Suppress("UNUSED_PARAMETER") ctx: Context) = off { voice = false }
        fun startLogin(ctx: Context) = send(ctx, ACTION_LOGIN)
        fun stopLogin(@Suppress("UNUSED_PARAMETER") ctx: Context) = off { login = false }
        fun startShare(ctx: Context, code: Int, data: Intent) = send(ctx, ACTION_SHARE) {
            it.putExtra("code", code)
            it.putExtra("data", data)
        }

        fun shareStopped(@Suppress("UNUSED_PARAMETER") ctx: Context) = off { share = false }
    }
}
