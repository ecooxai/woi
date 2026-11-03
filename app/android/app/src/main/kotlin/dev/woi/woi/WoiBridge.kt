package dev.woi.woi

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.util.Log
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

/**
 * Platform side of lib/platform/android: one method channel for requests
 * ("woi/android"), one event channel for things the OS starts (shared files,
 * assistant invocations, screen-share state, clip completion) and one event
 * channel for microphone PCM.
 */
object WoiBridge {
    const val TAG = "Woi"
    val main = Handler(Looper.getMainLooper())
    val io = Executors.newSingleThreadExecutor()

    private var sink: EventChannel.EventSink? = null
    private val pending = ArrayList<Map<String, Any?>>()
    var activity: MainActivity? = null
    lateinit var appContext: Context

    /** Sends an event to Dart (queued until Dart listens). Any thread. */
    fun emit(event: Map<String, Any?>) {
        main.post {
            val s = sink
            if (s == null) pending.add(event) else s.success(event)
        }
    }

    fun attach(act: MainActivity, engine: FlutterEngine) {
        activity = act
        appContext = act.applicationContext
        val messenger = engine.dartExecutor.binaryMessenger
        EventChannel(messenger, "woi/android/events").setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                sink = events
                val queued = ArrayList(pending)
                pending.clear()
                for (e in queued) events.success(e)
            }

            override fun onCancel(arguments: Any?) {
                sink = null
            }
        })
        EventChannel(messenger, "woi/android/mic").setStreamHandler(WoiAudio.micHandler)
        MethodChannel(messenger, "woi/android").setMethodCallHandler { call, result ->
            try {
                handle(call, result)
            } catch (e: Throwable) {
                Log.w(TAG, "method ${call.method} failed", e)
                result.error("failed", e.message ?: e.toString(), null)
            }
        }
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        val ctx = appContext
        when (call.method) {
            "init" -> {
                val dm = ctx.resources.displayMetrics
                val (w, h) = WoiScreen.realSize(ctx)
                result.success(
                    mapOf(
                        "filesDir" to ctx.filesDir.absolutePath,
                        "cacheDir" to ctx.cacheDir.absolutePath,
                        "nativeLibDir" to ctx.applicationInfo.nativeLibraryDir,
                        "sdk" to Build.VERSION.SDK_INT,
                        "model" to "${Build.MANUFACTURER} ${Build.MODEL}",
                        "screenWidth" to w,
                        "screenHeight" to h,
                        "density" to dm.density.toDouble(),
                        "package" to ctx.packageName,
                    )
                )
            }
            "status" -> result.success(
                mapOf(
                    "accessibility" to (WoiAccessibilityService.instance != null),
                    "sharing" to WoiScreen.isSharing(),
                    "assistant" to isDefaultAssistant(ctx),
                    "mic" to hasPermission(ctx, android.Manifest.permission.RECORD_AUDIO),
                )
            )
            "requestPermissions" -> {
                val act = activity ?: return result.success(false)
                @Suppress("UNCHECKED_CAST")
                val perms = (call.argument<List<String>>("permissions") ?: emptyList())
                act.requestPerms(perms.toTypedArray()) { granted -> result.success(granted) }
            }
            "openUrl" -> {
                val url = call.argument<String>("url")!!
                val keepAlive = call.argument<Boolean>("keepAlive") ?: false
                if (keepAlive) WoiForegroundService.startLogin(ctx)
                result.success(openUrl(url))
            }
            "loginDone" -> {
                WoiForegroundService.stopLogin(ctx)
                result.success(true)
            }
            "voiceActive" -> {
                // Keeps the microphone usable while Woi is in the background
                // (screen share, acting in other apps).
                val on = call.argument<Boolean>("on") ?: false
                if (on) WoiForegroundService.startVoice(ctx) else WoiForegroundService.stopVoice(ctx)
                result.success(true)
            }
            // --- audio ---
            "playerOpen" -> result.success(WoiAudio.playerOpen())
            "playerWrite" -> {
                WoiAudio.playerWrite(call.arguments as ByteArray)
                result.success(null)
            }
            "playerStop" -> {
                WoiAudio.playerStop()
                result.success(null)
            }
            "playerClose" -> {
                WoiAudio.playerClose()
                result.success(null)
            }
            "clipPlay" -> result.success(WoiAudio.clipPlay(call.argument<String>("path")!!))
            "clipStop" -> {
                WoiAudio.clipStop(call.argument<Int>("id")!!)
                result.success(null)
            }
            // --- accessibility input ---
            "a11yOpenSettings" -> {
                val i = Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                ctx.startActivity(i)
                result.success(true)
            }
            "click", "doubleClick", "typeText", "global", "node", "a11yScreenshot", "focusTarget" ->
                WoiAccessibilityService.handle(call, result)
            // --- screen share ---
            "shareStart" -> {
                val act = activity ?: return result.success(false)
                act.requestProjection { ok -> result.success(ok) }
            }
            "shareStop" -> {
                WoiScreen.stop(ctx)
                result.success(true)
            }
            "shareFrame" -> {
                val maxW = call.argument<Int>("maxWidth") ?: 1280
                io.execute {
                    val f = WoiScreen.frame(maxW)
                    main.post { result.success(f) }
                }
            }
            "moveToBack" -> {
                result.success(activity?.moveTaskToBack(true) ?: false)
            }
            else -> result.notImplemented()
        }
    }

    fun hasPermission(ctx: Context, p: String) =
        ctx.checkSelfPermission(p) == android.content.pm.PackageManager.PERMISSION_GRANTED

    fun isDefaultAssistant(ctx: Context): Boolean {
        val v = Settings.Secure.getString(ctx.contentResolver, "voice_interaction_service") ?: return false
        return v.startsWith(ctx.packageName + "/")
    }

    /** Chrome Custom Tab when a browser supports it, else any browser. */
    private fun openUrl(url: String): Boolean {
        val ctx: Context = activity ?: appContext
        val uri = Uri.parse(url)
        val tab = Intent(Intent.ACTION_VIEW, uri).apply {
            // What androidx.browser's CustomTabsIntent sets: a (null) session
            // binder marks the intent as a Custom Tab request.
            val extras = Bundle()
            extras.putBinder("android.support.customtabs.extra.SESSION", null)
            putExtras(extras)
            putExtra("android.support.customtabs.extra.SHARE_STATE", 2)
            if (ctx !is Activity) addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        val pkg = customTabsPackage(ctx)
        if (pkg != null) tab.setPackage(pkg)
        return try {
            ctx.startActivity(tab)
            true
        } catch (e: Exception) {
            Log.w(TAG, "custom tab failed, plain browser", e)
            try {
                ctx.startActivity(Intent(Intent.ACTION_VIEW, uri).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                true
            } catch (e2: Exception) {
                false
            }
        }
    }

    private fun customTabsPackage(ctx: Context): String? {
        val pm = ctx.packageManager
        val browsers = pm.queryIntentActivities(Intent(Intent.ACTION_VIEW, Uri.parse("https://example.com")), 0)
        val withTabs = browsers.map { it.activityInfo.packageName }.filter { pkg ->
            val svc = Intent("android.support.customtabs.action.CustomTabsService").setPackage(pkg)
            pm.resolveService(svc, 0) != null
        }
        val default = pm.resolveActivity(Intent(Intent.ACTION_VIEW, Uri.parse("https://example.com")), 0)
            ?.activityInfo?.packageName
        return if (default != null && withTabs.contains(default)) default else withTabs.firstOrNull()
    }
}
