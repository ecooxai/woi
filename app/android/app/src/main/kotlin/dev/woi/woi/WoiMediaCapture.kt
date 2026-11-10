package dev.woi.woi

import android.app.Activity
import android.content.Context
import android.content.Intent
import io.flutter.plugin.common.MethodChannel
import java.lang.ref.WeakReference

/** Camera/projection requests have one owner, including their permission UI.
 * Methods and callbacks run on the main thread. A request is active only after
 * its first usable frame; late callbacks from stopped requests are ignored. */
internal object WoiMediaCapture {
    const val CAMERA = "camera"
    const val SCREEN = "screen"
    private const val CONSENT_TIMEOUT_MS = 120_000L
    private const val START_TIMEOUT_MS = 10_000L
    private data class Capture(
        val kind: String,
        var id: Long = 0,
        var revision: Long = 0,
        var state: String = "inactive",
        var error: String? = null,
        var message: String = "Capture is off.",
        var front: Boolean = false,
    )
    private data class Request(val kind: String, val id: Long)
    private val camera = Capture(CAMERA)
    private val screen = Capture(SCREEN)
    private var nextId = 0L
    private var revision = 0L
    private val queue = ArrayDeque<Request>()
    private var prompt: Request? = null
    private var consent: WeakReference<WoiMediaConsentActivity>? = null
    private var overlayLease: MethodChannel.Result? = null
    private var keyboardLease: (() -> Unit)? = null
    private var releasing = false
    val consentInProgress: Boolean get() = prompt != null || releasing

    private fun capture(kind: String) = when (kind) {
        CAMERA -> camera
        SCREEN -> screen
        else -> throw IllegalArgumentException("Unknown capture source")
    }
    private fun current(kind: String, id: Long) = capture(kind).id == id
    private fun pending(c: Capture) = c.state == "permission_pending" || c.state == "starting"

    fun status(kind: String): Map<String, Any?> {
        val c = capture(kind)
        return mapOf(
            "ok" to (c.error == null), "state" to c.state,
            "on" to (c.state == "active"), "pending" to pending(c),
            "requestId" to c.id, "revision" to c.revision,
            "message" to c.message,
            "error" to c.error,
            "facing" to if (kind == CAMERA) (if (c.front) "front" else "back") else null,
            "frames" to if (c.state != "active") 0L else if (kind == CAMERA) WoiCamera.frameCount else WoiScreen.frameCount,
        )
    }

    private fun update(c: Capture, state: String, message: String, error: String? = null) {
        c.state = state
        c.message = message
        c.error = error
        c.revision = ++revision
        WoiBridge.emit(status(c.kind) + mapOf("type" to "capture", "kind" to c.kind))
        // Existing UI integration also listens for the system's share stop.
        if (c.kind == SCREEN) WoiBridge.emit(mapOf("type" to "share", "on" to (state == "active"), "error" to error))
    }

    fun start(kind: String, front: Boolean? = null): Map<String, Any?> {
        val c = capture(kind)
        val desiredFront = front ?: c.front
        if ((c.state == "active" || pending(c)) && (kind != CAMERA || desiredFront == c.front)) return status(kind)
        if (c.state == "active" || pending(c)) stop(kind)
        c.id = ++nextId
        if (kind == CAMERA) c.front = desiredFront
        val request = Request(kind, c.id)
        update(c, "permission_pending", if (kind == CAMERA)
            "Opening Android camera permission. The camera is not active yet; check status after permission is handled."
        else "Complete Android's screen sharing consent. Sharing is not active yet; check status after consent.")
        queue.addLast(request)
        launchNext()
        WoiBridge.main.postDelayed({
            if (current(kind, request.id) && c.state == "permission_pending") {
                failed(kind, request.id, "Android capture permission timed out. Request capture again when ready.")
            }
        }, CONSENT_TIMEOUT_MS)
        return status(kind)
    }

    fun stop(kind: String): Map<String, Any?> {
        val c = capture(kind)
        val oldId = c.id
        c.id = ++nextId // Invalidate consent, service starts and first-frame callbacks.
        closeSource(kind)
        update(c, "inactive", if (kind == CAMERA) "Camera is off." else "Screen sharing is off.")
        finishPrompt(kind, oldId)
        return status(kind)
    }

    fun stopAll() {
        stop(CAMERA)
        stop(SCREEN)
    }

    private fun closeSource(kind: String) {
        if (kind == CAMERA) {
            WoiCamera.close()
            WoiForegroundService.cameraStopped()
        } else WoiScreen.stop(WoiBridge.appContext, notify = false)
    }

    private fun launchNext() {
        if (prompt != null || releasing) return
        var next: Request? = null
        while (queue.isNotEmpty()) {
            val candidate = queue.removeFirst()
            if (current(candidate.kind, candidate.id) && capture(candidate.kind).state == "permission_pending") {
                next = candidate
                break
            }
        }
        val request = next ?: return
        prompt = request
        try {
            if (WoiOverlay.showing) {
                overlayLease = WoiOverlay.releasing(object : MethodChannel.Result {
                    override fun success(result: Any?) {}
                    override fun error(code: String, message: String?, details: Any?) {}
                    override fun notImplemented() {}
                })
                WoiOverlay.stepAside(true)
            }
            keyboardLease = WoiAccessibilityService.instance?.suspendTouchKeyboardForCapture()
            // An accessibility service can bring up explicit user-requested
            // consent even when the assistant engine has no MainActivity.
            val ctx = WoiAccessibilityService.instance ?: WoiBridge.appContext
            ctx.startActivity(Intent(ctx, WoiMediaConsentActivity::class.java).apply {
                putExtra("kind", request.kind)
                putExtra("request", request.id)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_EXCLUDE_FROM_RECENTS)
            })
            WoiBridge.main.postDelayed({
                if (prompt == request && consent?.get() == null) failed(request.kind, request.id,
                    "Android did not open the capture permission window. Open Woi and request capture again.")
            }, 3500)
        } catch (e: Exception) {
            failed(request.kind, request.id, "Android could not open capture permission: ${e.message ?: e.javaClass.simpleName}")
        }
    }

    fun attach(activity: WoiMediaConsentActivity, kind: String, id: Long): Boolean {
        if (prompt != Request(kind, id) || !current(kind, id) || !pending(capture(kind))) return false
        consent = WeakReference(activity)
        return true
    }

    fun requestValid(kind: String, id: Long) = (kind == CAMERA || kind == SCREEN) && current(kind, id) && capture(kind).state == "permission_pending"
    fun isStarting(kind: String, id: Long) = current(kind, id) && capture(kind).state == "starting"
    fun ownsForeground(kind: String) = capture(kind).state in setOf("starting", "active")
    fun foregroundFailed(kind: String, error: String) = failed(kind, capture(kind).id, error)

    fun cameraPermission(activity: Activity, id: Long, granted: Boolean) {
        if (!requestValid(CAMERA, id)) return
        if (!granted) { denied(CAMERA, id, "Camera permission was not granted."); return }
        begin(CAMERA, id)
        WoiForegroundService.startCamera(activity, id, camera.front)
    }

    fun projectionPermission(activity: Activity, id: Long, code: Int, data: Intent?) {
        if (!requestValid(SCREEN, id)) return
        if (code != Activity.RESULT_OK || data == null) { denied(SCREEN, id, "Screen sharing consent was not granted."); return }
        begin(SCREEN, id)
        WoiForegroundService.startShare(activity, code, data, id)
    }

    private fun begin(kind: String, id: Long) {
        update(capture(kind), "starting", "Android permission accepted; waiting for the first capture frame.")
        WoiBridge.main.postDelayed({
            if (current(kind, id) && capture(kind).state == "starting") failed(kind, id,
                "Capture did not produce a frame. It has been stopped; request capture again to retry.")
        }, START_TIMEOUT_MS)
    }

    /** Only called after the foreground service has acquired the correct type. */
    fun openCamera(ctx: Context, id: Long, front: Boolean) {
        if (!current(CAMERA, id) || camera.state != "starting") {
            WoiForegroundService.cameraStopped()
            return
        }
        WoiCamera.open(ctx, front, id) { error ->
            if (error == null) ready(CAMERA, id) else failed(CAMERA, id, error)
        }
    }

    fun openProjection(ctx: Context, id: Long, code: Int, data: Intent) {
        if (!current(SCREEN, id) || screen.state != "starting") {
            WoiForegroundService.shareStopped(ctx)
            return
        }
        if (!WoiScreen.start(ctx, code, data, id)) failed(SCREEN, id, "Android could not start screen capture.")
    }

    fun ready(kind: String, id: Long) {
        val c = capture(kind)
        if (!current(kind, id) || c.state != "starting") return
        update(c, "active", if (kind == CAMERA) "Camera is active; a live frame has been received." else "Screen sharing is active; a live frame has been received.")
        finishPrompt(kind, id)
    }

    fun failed(kind: String, id: Long, error: String) {
        val c = capture(kind)
        if (!current(kind, id) || (!pending(c) && c.state != "active")) return
        closeSource(kind)
        update(c, "error", error, error)
        finishPrompt(kind, id)
    }

    private fun denied(kind: String, id: Long, message: String) {
        if (!current(kind, id)) return
        closeSource(kind)
        update(capture(kind), "denied", message, message)
        finishPrompt(kind, id)
    }

    fun projectionStopped(id: Long) {
        if (!current(SCREEN, id)) return
        closeSource(SCREEN)
        update(screen, "inactive", "Screen sharing was stopped by Android.")
        finishPrompt(SCREEN, id)
    }

    fun serviceStopped() {
        for (c in listOf(camera, screen)) {
            if (c.state == "starting" || c.state == "active") failed(c.kind, c.id, "Android stopped the capture foreground service.")
        }
    }

    fun abandoned(activity: WoiMediaConsentActivity, kind: String, id: Long) {
        if (consent?.get() === activity && current(kind, id) && pending(capture(kind))) {
            denied(kind, id, "Capture permission was cancelled.")
        }
    }

    private fun finishPrompt(kind: String, id: Long) {
        if (prompt != Request(kind, id)) { launchNext(); return }
        prompt = null
        val activity = consent?.get()
        consent = null
        val lease = overlayLease
        overlayLease = null
        val restoreKeyboard = keyboardLease
        keyboardLease = null
        releasing = true
        activity?.finish()
        // Let the real permission window release focus before the assistant
        // panel restores it or another capture consent is opened.
        fun released() {
            // A system permission dialog can still own the display when its
            // host loses focus. Keep all visibility leases until that host is
            // destroyed, then let the next queued request acquire its leases.
            if (activity != null && !activity.isDestroyed) {
                WoiBridge.main.postDelayed(::released, 32)
                return
            }
            restoreKeyboard?.invoke()
            lease?.success(null)
            releasing = false
            launchNext()
        }
        WoiBridge.main.postDelayed(::released, if (activity == null) 0 else 32)
    }
}
