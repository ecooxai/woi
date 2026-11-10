package dev.woi.woi

import android.Manifest
import android.app.Activity
import android.app.Instrumentation
import android.app.NotificationManager
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.os.Bundle
import android.os.SystemClock
import android.view.WindowManager
import android.widget.TextView
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/** Test-APK host only: no Flutter engine, account, model or image upload. */
class MediaCaptureTestActivity : Activity() {
    override fun onCreate(state: Bundle?) {
        super.onCreate(state)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        setContentView(TextView(this).apply {
            text = "Woi capture check\nCamera/screen frames are discarded.\nAndroid consent remains required."
            contentDescription = "woi-media-capture-test"
            textSize = 22f
            setPadding(32, 64, 32, 32)
        })
    }
}

/** Production method dispatcher + real Camera2/MediaProjection/foreground service.
 * Reports contain states/counts only. No frames are read, saved or sent.
 * media_capture_screen waits for the operator to accept the genuine OS dialog;
 * it never clicks, grants, replaces, or reuses Android projection consent. */
class MediaCaptureDeviceCheck(private val host: Instrumentation, private val acceptScreen: Boolean) {
    private val ctx get() = host.targetContext
    private val log = StringBuilder()
    private var passed = 0
    private var activity: Activity? = null

    private fun main(block: () -> Unit) = host.runOnMainSync(block)

    private fun call(name: String, arguments: Map<String, Any?> = emptyMap()): Map<String, Any?> {
        val done = CountDownLatch(1)
        var answer: Map<String, Any?>? = null
        var error: String? = null
        main {
            // Keep the release dispatcher private; this reflection exists only
            // in the separately installed instrumentation APK.
            val handle = WoiBridge::class.java.getDeclaredMethod("handle", MethodCall::class.java, MethodChannel.Result::class.java)
            handle.isAccessible = true
            try {
                handle.invoke(WoiBridge, MethodCall(name, arguments), object : MethodChannel.Result {
                    override fun success(result: Any?) {
                        @Suppress("UNCHECKED_CAST")
                        answer = result as? Map<String, Any?>
                        done.countDown()
                    }
                    override fun error(code: String, message: String?, details: Any?) { error = "$code: $message"; done.countDown() }
                    override fun notImplemented() { error = "not implemented"; done.countDown() }
                })
            } catch (failure: Throwable) { error = failure.cause?.message ?: failure.message; done.countDown() }
        }
        check(done.await(5, TimeUnit.SECONDS)) { "$name did not reply" }
        check(error == null) { "$name: $error" }
        return checkNotNull(answer) { "$name returned no capture state" }
    }

    private fun status(kind: String) = call("mediaCaptureStatus", mapOf("kind" to kind))
    private fun waitFor(kind: String, state: String, timeout: Long = 12_000): Map<String, Any?> {
        val deadline = SystemClock.elapsedRealtime() + timeout
        var value = status(kind)
        while (value["state"] != state && SystemClock.elapsedRealtime() < deadline) {
            check(value["state"] !in listOf("error", "denied")) { "$kind: $value" }
            SystemClock.sleep(80)
            value = status(kind)
        }
        check(value["state"] == state) { "$kind did not reach $state: $value" }
        return value
    }

    private fun verify(name: String, check: () -> Unit) {
        check()
        passed++
        log.append("PASS ").append(name).append('\n')
        host.sendStatus(0, Bundle().apply { putString("stream", "PASS $name\n") })
    }

    fun run() {
        var result = Activity.RESULT_OK
        try {
            main { WoiBridge.ensureContext(ctx) }
            check(ctx.checkSelfPermission(Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED) {
                "Grant camera permission through Android before this check; instrumentation never grants it."
            }
            activity = host.startActivitySync(Intent(Intent.ACTION_MAIN).setClassName(ctx.packageName, "${ctx.packageName}.MainActivity")
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            host.waitForIdleSync()
            verify("initial capture state is off") {
                check(status("camera")["on"] == false && status("screen")["on"] == false)
                check(!WoiCamera.isOpen && !WoiScreen.hasProjection())
            }
            verify("camera dispatcher returns pending until a real first frame") {
                val requested = call("cameraOpen", mapOf("front" to false))
                check(requested["on"] == false && requested["pending"] == true) { requested.toString() }
                val repeated = call("cameraOpen", mapOf("front" to false))
                check(repeated["requestId"] == requested["requestId"])
                val active = waitFor("camera", "active")
                check((active["frames"] as Number).toLong() > 0 && WoiCamera.isStreaming)
                main {
                    val service = checkNotNull(WoiForegroundService.instance)
                    check(service.foregroundServiceType and ServiceInfo.FOREGROUND_SERVICE_TYPE_CAMERA != 0)
                    check(ctx.getSystemService(NotificationManager::class.java).activeNotifications.any { it.id == 42 })
                }
            }
            verify("camera remains owned by its foreground service while the app is backgrounded") {
                main { activity?.moveTaskToBack(true) }
                val before = (status("camera")["frames"] as Number).toLong()
                SystemClock.sleep(800)
                val after = status("camera")
                check(after["on"] == true && (after["frames"] as Number).toLong() > before)
            }
            verify("front camera switch waits for its own first frame") {
                val requested = call("cameraOpen", mapOf("front" to true))
                check(requested["on"] == false && requested["pending"] == true)
                val active = waitFor("camera", "active")
                check(active["facing"] == "front" && WoiCamera.isStreaming)
            }
            verify("camera stop releases hardware and is repeatable") {
                check(call("cameraClose")["state"] == "inactive")
                check(call("cameraClose")["on"] == false)
                check(!WoiCamera.isOpen && !WoiCamera.isStreaming)
            }
            verify("cancelled request cannot be revived by a stale readiness callback") {
                var old = 0L
                main {
                    old = (WoiMediaCapture.start("camera")["requestId"] as Number).toLong()
                    WoiMediaCapture.stop("camera")
                    WoiMediaCapture.ready("camera", old)
                }
                check(status("camera")["state"] == "inactive" && !WoiCamera.isOpen)
            }
            verify("permission denial and startup failure stay inactive") {
                main {
                    val request = (WoiMediaCapture.start("camera")["requestId"] as Number).toLong()
                    WoiMediaCapture.cameraPermission(checkNotNull(activity), request, false)
                }
                check(status("camera")["state"] == "denied" && !WoiCamera.isOpen)
                main {
                    val request = (WoiMediaCapture.start("camera")["requestId"] as Number).toLong()
                    WoiMediaCapture.failed("camera", request, "Controlled startup timeout check")
                    WoiMediaCapture.ready("camera", request)
                }
                check(status("camera")["state"] == "error" && !WoiCamera.isOpen)
            }
            verify("screen request shows real consent and stop cancels pending projection") {
                val requested = call("shareStart")
                check(requested["state"] == "permission_pending" && requested["on"] == false)
                SystemClock.sleep(800)
                check(status("screen")["on"] == false && !WoiScreen.isSharing())
                check(call("shareStop")["state"] == "inactive")
                check(call("shareStop")["state"] == "inactive")
                fun consentTaskVisible() = ctx.getSystemService(android.app.ActivityManager::class.java).appTasks.any {
                    it.taskInfo.baseIntent.component?.className == WoiMediaConsentActivity::class.java.name &&
                        it.taskInfo.numActivities > 0
                }
                val deadline = SystemClock.elapsedRealtime() + 5000
                while (consentTaskVisible() && SystemClock.elapsedRealtime() < deadline) SystemClock.sleep(40)
                check(!consentTaskVisible()) { "Stopped projection left its Android consent task on screen" }
                check(!WoiScreen.hasProjection())
            }
            if (acceptScreen) verify("approved projection becomes active only after a real frame and stops cleanly") {
                val requested = call("shareStart")
                check(requested["on"] == false)
                host.sendStatus(0, Bundle().apply { putString("stream", "WAITING: complete the real Android screen sharing consent dialog.\n") })
                val active = waitFor("screen", "active", 90_000)
                check((active["frames"] as Number).toLong() > 0 && WoiScreen.isSharing())
                main {
                    check(checkNotNull(WoiForegroundService.instance).foregroundServiceType and ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION != 0)
                }
                check(call("shareStop")["on"] == false)
                check(!WoiScreen.hasProjection() && WoiScreen.frameCount == 0L)
            }
        } catch (error: Throwable) {
            result = Activity.RESULT_CANCELED
            log.append("FAIL ").append(error.message ?: error.javaClass.simpleName).append('\n')
        } finally {
            main { WoiMediaCapture.stopAll(); activity?.finish() }
        }
        host.finish(result, Bundle().apply {
            putString("stream", log.toString())
            putInt("passed", passed)
            putBoolean("camera_released", !WoiCamera.isOpen)
            putBoolean("projection_released", !WoiScreen.hasProjection())
        })
    }
}
