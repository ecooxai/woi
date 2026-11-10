package dev.woi.woi

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.ImageFormat
import android.graphics.Rect
import android.graphics.YuvImage
import android.hardware.camera2.CameraCaptureSession
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraDevice
import android.hardware.camera2.CameraManager
import android.hardware.camera2.CaptureRequest
import android.media.Image
import android.media.ImageReader
import android.os.Handler
import android.os.HandlerThread
import android.os.SystemClock
import android.util.Log
import android.util.Range
import java.io.ByteArrayOutputStream

/** Camera2 preview owned by WoiMediaCapture and the camera foreground service.
 * The readiness callback is delivered on the first encoded frame, and again
 * with an error if an active device is disconnected. Frames are never saved. */
object WoiCamera {
    private const val MAX_W = 960
    private const val FPS = 4
    private const val TAG = WoiBridge.TAG
    private var thread: HandlerThread? = null
    private var device: CameraDevice? = null
    private var session: CameraCaptureSession? = null
    private var reader: ImageReader? = null
    @Volatile private var epoch = 0L
    @Volatile var frameCount = 0L
        private set
    val isOpen get() = device != null
    val isStreaming get() = isOpen && frameCount > 0

    @SuppressLint("MissingPermission")
    fun open(ctx: Context, front: Boolean, requestId: Long, state: (String?) -> Unit) {
        close()
        val owner = ++epoch
        fun fail(error: String) {
            if (epoch != owner) return
            close()
            state(error)
        }
        try {
            val cm = ctx.getSystemService(CameraManager::class.java)
            val id = cm.cameraIdList.firstOrNull {
                val facing = cm.getCameraCharacteristics(it).get(CameraCharacteristics.LENS_FACING)
                facing == if (front) CameraCharacteristics.LENS_FACING_FRONT else CameraCharacteristics.LENS_FACING_BACK
            } ?: run { fail(if (front) "No front camera is available." else "No back camera is available."); return }
            val ch = cm.getCameraCharacteristics(id)
            val rotation = ch.get(CameraCharacteristics.SENSOR_ORIENTATION) ?: 0
            val mirror = ch.get(CameraCharacteristics.LENS_FACING) == CameraCharacteristics.LENS_FACING_FRONT
            val sizes = ch.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP)
                ?.getOutputSizes(ImageFormat.YUV_420_888)?.toList().orEmpty()
            val size = sizes.filter { maxOf(it.width, it.height) <= MAX_W && it.width * 3 >= it.height * 4 }
                .maxByOrNull { it.width * it.height }
                ?: sizes.minByOrNull { it.width * it.height }
                ?: run { fail("No usable camera capture size."); return }
            val fpsRange = ch.get(CameraCharacteristics.CONTROL_AE_AVAILABLE_TARGET_FPS_RANGES)
                ?.minByOrNull { it.upper * 100 + it.lower }
            val t = HandlerThread("woi-camera").apply { start() }
            val h = Handler(t.looper)
            thread = t
            val r = ImageReader.newInstance(size.width, size.height, ImageFormat.YUV_420_888, 3)
            reader = r
            var lastEncoded = 0L
            var lastDelivered = SystemClock.elapsedRealtime()
            r.setOnImageAvailableListener({ rd ->
                val img = try { rd.acquireLatestImage() } catch (_: Exception) { null } ?: return@setOnImageAvailableListener
                try {
                    val now = SystemClock.elapsedRealtime()
                    if (epoch == owner && now - lastEncoded >= 1000L / FPS) {
                        lastEncoded = now
                        val frame = toJpeg(img, rotation, mirror)
                        if (frame != null) WoiBridge.main.post {
                            if (epoch != owner) return@post
                            lastDelivered = SystemClock.elapsedRealtime()
                            frameCount++
                            if (frameCount == 1L) state(null)
                            if (epoch == owner) WoiBridge.emit(frame + mapOf("requestId" to requestId))
                        }
                    }
                } catch (e: Exception) {
                    Log.w(TAG, "camera frame failed", e)
                } finally { img.close() }
            }, h)
            fun checkFrames() {
                if (epoch != owner) return
                if (frameCount > 0 && SystemClock.elapsedRealtime() - lastDelivered > 6000) {
                    fail("Camera stopped delivering frames.")
                } else WoiBridge.main.postDelayed(::checkFrames, 2000)
            }
            WoiBridge.main.postDelayed(::checkFrames, 2000)
            cm.openCamera(id, object : CameraDevice.StateCallback() {
                override fun onOpened(cam: CameraDevice) {
                    if (epoch != owner) { cam.close(); return }
                    device = cam
                    try {
                        @Suppress("DEPRECATION")
                        cam.createCaptureSession(listOf(r.surface), object : CameraCaptureSession.StateCallback() {
                            override fun onConfigured(s: CameraCaptureSession) {
                                if (epoch != owner) { s.close(); return }
                                session = s
                                try {
                                    val request = cam.createCaptureRequest(CameraDevice.TEMPLATE_PREVIEW).apply {
                                        addTarget(r.surface)
                                        if (fpsRange != null) set(CaptureRequest.CONTROL_AE_TARGET_FPS_RANGE, fpsRange)
                                        set(CaptureRequest.CONTROL_AF_MODE, CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_PICTURE)
                                    }.build()
                                    s.setRepeatingRequest(request, null, h)
                                    Log.i(TAG, "camera capture configured ${size.width}x${size.height}")
                                } catch (e: Exception) { fail("Camera start failed: ${e.message}") }
                            }
                            override fun onConfigureFailed(s: CameraCaptureSession) {
                                s.close()
                                fail("Camera capture session could not start.")
                            }
                        }, WoiBridge.main)
                    } catch (e: Exception) { fail("Camera session failed: ${e.message}") }
                }
                override fun onDisconnected(cam: CameraDevice) {
                    cam.close()
                    fail("Camera disconnected.")
                }
                override fun onError(cam: CameraDevice, error: Int) {
                    cam.close()
                    fail("Android camera error $error.")
                }
            }, WoiBridge.main)
        } catch (e: Exception) { fail("Camera open failed: ${e.message ?: e.javaClass.simpleName}") }
    }

    fun close() {
        epoch++
        frameCount = 0
        try { session?.close() } catch (_: Exception) {}
        try { device?.close() } catch (_: Exception) {}
        try { reader?.close() } catch (_: Exception) {}
        session = null
        device = null
        reader = null
        thread?.quitSafely()
        thread = null
    }

    /**
     * YUV_420_888 -> upright NV21 -> JPEG. Rotation/mirroring happen while
     * copying the planes (one pass over plain arrays), so a frame costs one
     * JPEG encode; the old path encoded, decoded, rotated a Bitmap and
     * encoded again (~37% CPU at 4 fps on the MI 8). Sizes above [MAX_W]
     * (no smaller camera size) still go through a scaled Bitmap.
     */
    private fun toJpeg(img: Image, rotation: Int, mirror: Boolean): Map<String, Any>? {
        val w = img.width and 1.inv()
        val h = img.height and 1.inv()
        val rot = ((rotation % 360) + 360) % 360
        val swap = rot == 90 || rot == 270
        val ow = if (swap) h else w
        val oh = if (swap) w else h
        val nv21 = ByteArray(ow * oh * 3 / 2)
        val yp = img.planes[0]
        val up = img.planes[1]
        val vp = img.planes[2]
        val ya = bytesOf(yp.buffer)
        val ua = bytesOf(up.buffer)
        val va = bytesOf(vp.buffer)
        copyPlane(ya, yp.rowStride, yp.pixelStride, w, h, rot, mirror, nv21, 0, 1)
        val cw = w / 2
        val ch = h / 2
        // NV21 chroma: V then U, interleaved.
        copyPlane(va, vp.rowStride, vp.pixelStride, cw, ch, rot, mirror, nv21, ow * oh, 2)
        copyPlane(ua, up.rowStride, up.pixelStride, cw, ch, rot, mirror, nv21, ow * oh + 1, 2)
        val raw = ByteArrayOutputStream(ow * oh / 4)
        YuvImage(nv21, ImageFormat.NV21, ow, oh, null).compressToJpeg(Rect(0, 0, ow, oh), 80, raw)
        val bytes = raw.toByteArray()
        if (maxOf(ow, oh) <= MAX_W) {
            return mapOf("type" to "camera", "jpeg" to bytes, "width" to ow, "height" to oh)
        }
        val bmp = BitmapFactory.decodeByteArray(bytes, 0, bytes.size) ?: return null
        val s = MAX_W.toFloat() / maxOf(ow, oh)
        val out = Bitmap.createScaledBitmap(bmp, (ow * s).toInt(), (oh * s).toInt(), true)
        bmp.recycle()
        val jpg = ByteArrayOutputStream()
        out.compress(Bitmap.CompressFormat.JPEG, 80, jpg)
        val res = mapOf("type" to "camera", "jpeg" to jpg.toByteArray(), "width" to out.width, "height" to out.height)
        out.recycle()
        return res
    }

    private fun bytesOf(b: java.nio.ByteBuffer): ByteArray {
        b.rewind()
        return ByteArray(b.remaining()).also { b.get(it) }
    }

    /**
     * Copies a [w]x[h] plane (row/pixel strides [rs]/[ps]) into [dst] at
     * [off] every [step] bytes, rotated clockwise by [rot] degrees and
     * mirrored horizontally afterwards when [mirror] is set (front camera).
     */
    private fun copyPlane(src: ByteArray, rs: Int, ps: Int, w: Int, h: Int, rot: Int, mirror: Boolean, dst: ByteArray, off: Int, step: Int) {
        val ow = if (rot == 90 || rot == 270) h else w
        val oh = if (rot == 90 || rot == 270) w else h
        // Source index of output pixel (ox, oy).
        fun at(ox: Int, oy: Int): Int {
            val x = if (mirror) ow - 1 - ox else ox
            return when (rot) {
                90 -> (h - 1 - x) * rs + oy * ps
                180 -> (h - 1 - oy) * rs + (w - 1 - x) * ps
                270 -> x * rs + (w - 1 - oy) * ps
                else -> oy * rs + x * ps
            }
        }
        val last = src.size - 1
        var o = off
        for (oy in 0 until oh) {
            var i = at(0, oy)
            val d = if (ow > 1) at(1, oy) - i else 0
            for (ox in 0 until ow) {
                dst[o] = src[if (i > last) last else i]
                o += step
                i += d
            }
        }
    }
}
