package dev.woi.woi

import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.PowerManager
import android.provider.Settings
import android.util.Log

/**
 * Keeps Woi's accessibility service switched on.
 *
 * Android removes a service from enabled_accessibility_services whenever its
 * package is force-stopped, and every APK install/update force-stops the
 * package ("stop dev.woi.woi due to installPackageLI"), so each update turned
 * screen control off. When the app holds WRITE_SECURE_SETTINGS (granted once
 * with `adb shell pm grant dev.woi.woi android.permission.WRITE_SECURE_SETTINGS`)
 * it puts itself back: after an update (MY_PACKAGE_REPLACED), on boot, on app
 * start, on assistant activation and every 30 s while the foreground service
 * runs. Other services in the list are left as they are (append only).
 */
object WoiA11yKeeper {
    private const val PERM = "android.permission.WRITE_SECURE_SETTINGS"

    fun component(ctx: Context) = ComponentName(ctx, WoiAccessibilityService::class.java)

    fun canSelfEnable(ctx: Context) =
        ctx.checkSelfPermission(PERM) == PackageManager.PERMISSION_GRANTED

    private fun listed(ctx: Context, raw: String?): Boolean {
        val me = component(ctx)
        return raw.orEmpty().split(':').any { ComponentName.unflattenFromString(it.trim()) == me }
    }

    fun enabled(ctx: Context): Boolean = try {
        val cr = ctx.contentResolver
        Settings.Secure.getInt(cr, Settings.Secure.ACCESSIBILITY_ENABLED, 0) == 1 &&
            listed(ctx, Settings.Secure.getString(cr, Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES))
    } catch (e: Throwable) {
        false
    }

    fun batteryExempt(ctx: Context): Boolean = try {
        ctx.getSystemService(PowerManager::class.java).isIgnoringBatteryOptimizations(ctx.packageName)
    } catch (e: Throwable) {
        false
    }

    /** Re-enables the service if it is off and the grant allows it. Cheap
     *  when already on (two settings reads). Returns true if it is on. */
    fun ensure(ctx: Context, reason: String): Boolean {
        try {
            if (enabled(ctx)) return true
            if (!canSelfEnable(ctx)) {
                Log.i(WoiBridge.TAG, "a11y off ($reason); no WRITE_SECURE_SETTINGS to re-enable")
                return false
            }
            val cr = ctx.contentResolver
            val cur = Settings.Secure.getString(cr, Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES).orEmpty()
            if (!listed(ctx, cur)) {
                val me = component(ctx).flattenToShortString()
                val next = if (cur.isBlank()) me else "${cur.trimEnd(':')}:$me"
                Settings.Secure.putString(cr, Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES, next)
            }
            if (Settings.Secure.getInt(cr, Settings.Secure.ACCESSIBILITY_ENABLED, 0) != 1) {
                Settings.Secure.putInt(cr, Settings.Secure.ACCESSIBILITY_ENABLED, 1)
            }
            Log.i(WoiBridge.TAG, "a11y re-enabled ($reason)")
            return enabled(ctx)
        } catch (e: Throwable) {
            Log.w(WoiBridge.TAG, "a11y re-enable failed ($reason)", e)
            return false
        }
    }

    fun status(ctx: Context): Map<String, Any> = mapOf(
        "enabled" to enabled(ctx),
        "bound" to (WoiAccessibilityService.instance != null),
        "canSelfEnable" to canSelfEnable(ctx),
        "batteryExempt" to batteryExempt(ctx),
    )

    /** One-time system prompt to exempt Woi from battery optimization. */
    fun requestBatteryExemption(ctx: Context): Boolean {
        if (batteryExempt(ctx)) return true
        return try {
            @Suppress("BatteryLife")
            val i = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, Uri.parse("package:${ctx.packageName}"))
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            ctx.startActivity(i)
            false
        } catch (e: Throwable) {
            Log.w(WoiBridge.TAG, "battery exemption prompt failed", e)
            try {
                ctx.startActivity(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            } catch (_: Throwable) {}
            false
        }
    }
}

/** After an update or a reboot: put the accessibility service back. */
class WoiA11yReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        WoiA11yKeeper.ensure(context, intent.action ?: "broadcast")
    }
}
