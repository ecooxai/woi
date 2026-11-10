package dev.woi.woi

import android.app.Activity
import android.app.Instrumentation
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Color
import android.os.Build
import android.os.Bundle
import android.os.SystemClock
import android.widget.TextView
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/** Test host has no Flutter engine, microphone, camera, provider connection or account access. */
class ClipboardTestActivity : Activity() {
    override fun onCreate(state: Bundle?) {
        super.onCreate(state)
        setContentView(TextView(this).apply {
            text = "Woi clipboard check\nSynthetic data only. The previous clipboard is restored."
            textSize = 20f
            setPadding(30, 70, 30, 30)
        })
    }
}

class ClipboardDeviceCheck(private val host: Instrumentation) {
    private val ctx get() = host.targetContext
    private var passed = 0
    private val log = StringBuilder()
    private fun main(block: () -> Unit) = host.runOnMainSync(block)
    private data class Reply(val value: Any?, val error: String?)
    private fun call(name: String, arguments: Map<String, Any?> = emptyMap()): Reply {
        val done = CountDownLatch(1)
        var value: Any? = null
        var error: String? = null
        main {
            WoiClipboard.handle(MethodCall(name, arguments), object : MethodChannel.Result {
                override fun success(result: Any?) { value = result; done.countDown() }
                override fun error(code: String, message: String?, details: Any?) { error = code; done.countDown() }
                override fun notImplemented() { error = "not_implemented"; done.countDown() }
            })
        }
        check(done.await(12, TimeUnit.SECONDS)) { "Clipboard method did not complete" }
        return Reply(value, error)
    }
    private fun verify(name: String, body: () -> Unit) {
        body()
        passed++
        log.append("PASS ").append(name).append('\n')
        host.sendStatus(0, Bundle().apply { putString("stream", "PASS $name\n") })
    }
    fun run() {
        var activity: Activity? = null
        var previous: ClipData? = null
        var captured = false
        var outcome = Activity.RESULT_OK
        val manager = ctx.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
        try {
            main { WoiBridge.ensureContext(ctx) }
            activity = host.startActivitySync(Intent(Intent.ACTION_MAIN).setClassName(ctx.packageName, "${ctx.packageName}.MainActivity").addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            host.waitForIdleSync()
            val deadline = SystemClock.elapsedRealtime() + 3000
            while (activity?.hasWindowFocus() != true && SystemClock.elapsedRealtime() < deadline) SystemClock.sleep(30)
            check(activity?.hasWindowFocus() == true) { "Synthetic test host did not gain clipboard focus" }
            main { previous = manager.primaryClip }
            check(ClipboardSnapshotActivity.canSafelyReplace(previous)) { "Original URI clipboard cannot be safely replaced by this fixture" }
            captured = true
            val bitmap = Bitmap.createBitmap(3, 2, Bitmap.Config.ARGB_8888)
            bitmap.eraseColor(Color.MAGENTA)
            bitmap.setPixel(2, 1, Color.GREEN)
            val bytes = ByteArrayOutputStream().also { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }.toByteArray()
            bitmap.recycle()
            verify("Unicode text write/read preserves exact content") {
                check(call("writeClipboard", mapOf("text" to "alpha 雪🙂\nbravo")).value == true)
                val read = call("readClipboard")
                check(read.error == null)
                check((read.value as? Map<*, *>)?.get("text") == "alpha 雪🙂\nbravo")
            }
            verify("passive rich read never launches a focus window") {
                // Explicit read acknowledges after its temporary window releases
                // focus; Android may restore the previous Activity a frame later.
                val focusedBy = SystemClock.elapsedRealtime() + 3000
                while (activity?.hasWindowFocus() != true && SystemClock.elapsedRealtime() < focusedBy) SystemClock.sleep(30)
                check(activity?.hasWindowFocus() == true) { "Test host focus did not return after explicit read" }
                val reply = call("readClipboardContent", mapOf("allowFocus" to false))
                check(reply.error == null && reply.value == null) { "Passive read unexpectedly requested a focus handoff: ${reply.error}" }
                check(activity?.hasWindowFocus() == true) { "Passive read moved focus away from the test host" }
            }
            verify("image copy exposes a read-only content URI with original bytes") {
                val reply = call("writeClipboardContent", mapOf("image" to mapOf("bytes" to bytes, "mimeType" to "image/png", "name" to "synthetic.png")))
                check(reply.error == null && reply.value == true)
                val clip = manager.primaryClip ?: error("Image clipboard is unavailable")
                val uri = clip.getItemAt(0).uri ?: error("Image copy returned no URI")
                check(uri.scheme == "content" && ctx.contentResolver.getType(uri) == "image/png")
                check(ctx.contentResolver.openInputStream(uri)?.use { it.readBytes().contentEquals(bytes) } == true)
                var rejected = false
                try { ctx.contentResolver.openFileDescriptor(uri, "w")?.close() } catch (_: Throwable) { rejected = true }
                check(rejected) { "Clipboard provider allowed a write" }
            }
            verify("explicit image read survives the focused clipboard Activity handoff") {
                val read = call("readClipboardContent")
                check(read.error == null)
                val image = (read.value as? Map<*, *>)?.get("image") as? Map<*, *> ?: error("Image payload absent")
                check((image["bytes"] as? ByteArray)?.contentEquals(bytes) == true)
                check(image["mimeType"] == "image/png")
            }
            verify("invalid and oversized images leave the current clipboard unchanged") {
                for (invalid in listOf(byteArrayOf(1, 2, 3), ByteArray(WoiClipboardContent.MAX_IMAGE_BYTES + 1))) {
                    check(call("writeClipboardContent", mapOf("image" to mapOf("bytes" to invalid))).error != null)
                }
                val read = call("readClipboardContent")
                val image = (read.value as Map<*, *>)["image"] as Map<*, *>
                check((image["bytes"] as ByteArray).contentEquals(bytes))
            }
        } catch (error: Throwable) {
            outcome = Activity.RESULT_CANCELED
            log.append("FAIL ").append(error.javaClass.simpleName).append(": ").append(error.message).append('\n')
        } finally {
            main {
                WoiClipboard.cancelPending()
                if (captured) {
                    if (previous != null) manager.setPrimaryClip(previous!!)
                    else if (Build.VERSION.SDK_INT >= 28) manager.clearPrimaryClip()
                    else manager.setPrimaryClip(ClipData.newPlainText("", ""))
                }
                activity?.finish()
            }
            log.append(if (captured) "CLEANUP original clipboard restored; no content logged.\n" else "CLEANUP original clipboard untouched; no content logged.\n")
        }
        host.finish(outcome, Bundle().apply { putString("stream", log.toString()); putInt("passed", passed) })
    }
}
