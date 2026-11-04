package dev.woi.woi

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.ImageFormat
import android.graphics.Matrix
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

/**
 * "open camera" on Android: Camera2 with a small YUV ImageReader at the
 * lowest frame rate the camera offers; at most [FPS] frames a second are
 * turned into upright JPEGs (<= [MAX_W] px wide) and sent to Dart as
 * `{type: camera, jpeg, width, height}` events. Everything is released on
 * [close]. Needs the CAMERA permission (requested by Dart first).
 */
object WoiCamera {
    private const val MAX_W = 960
    private const val FPS = 4
    private const val TAG = WoiBridge.TAG

    private var thread: HandlerThread? = null
    private var handler: Handler? = null
    private var device: CameraDevice? = null
    private var session: CameraCaptureSession? = null
    private var reader: ImageReader? = null
    private var lastFrameAt = 0L
    private var rotation = 0
    private var mirror = false

    val isOpen get() = device != null

    @SuppressLint("MissingPermission")
    fun open(ctx: Context, front: Boolean, done: (String?) -> Unit) {
        if (device != null) return done(null)
        val cm = ctx.getSystemService(CameraManager::class.java)
        val id = try {
            cm.cameraIdList.firstOrNull {
                val f = cm.getCameraCharacteristics(it).get(CameraCharacteristics.LENS_FACING)
                f == if (front) CameraCharacteristics.LENS_FACING_FRONT else CameraCharacteristics.LENS_FACING_BACK
            } ?: cm.cameraIdList.firstOrNull()
        } catch (e: Exception) {
            return done("camera unavailable: ${e.message}")
        } ?: return done("this phone has no camera")
        val ch = cm.getCameraCharacteristics(id)
        rotation = ch.get(CameraCharacteristics.SENSOR_ORIENTATION) ?: 0
        mirror = ch.get(CameraCharacteristics.LENS_FACING) == CameraCharacteristics.LENS_FACING_FRONT
        val map = ch.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP)
        val sizes = map?.getOutputSizes(ImageFormat.YUV_420_888)?.toList().orEmpty()
        // Largest 4:3 or 16:9 size not wider than 1280 (smallest available otherwise).
        val size = sizes.filter { it.width <= 1280 }.maxByOrNull { it.width * it.height }
            ?: sizes.minByOrNull { it.width * it.height }
            ?: return done("no usable camera size")
        val fpsRange = ch.get(CameraCharacteristics.CONTROL_AE_AVAILABLE_TARGET_FPS_RANGES)
            ?.minByOrNull { it.upper * 100 + it.lower }

        val t = HandlerThread("woi-camera").apply { start() }
        val h = Handler(t.looper)
        thread = t
        handler = h
        val r = ImageReader.newInstance(size.width, size.height, ImageFormat.YUV_420_888, 3)
        reader = r
        r.setOnImageAvailableListener({ rd ->
            val img = try { rd.acquireLatestImage() } catch (e: Exception) { null } ?: return@setOnImageAvailableListener
            try {
                val now = SystemClock.elapsedRealtime()
                if (now - lastFrameAt >= 1000L / FPS) {
                    lastFrameAt = now
                    val frame = toJpeg(img)
                    if (frame != null) WoiBridge.emit(frame)
                }
            } catch (e: Exception) {
                Log.w(TAG, "camera frame failed", e)
            } finally {
                img.close()
            }
        }, h)

        var answered = false
        fun answer(err: String?) {
            if (answered) return
            answered = true
            WoiBridge.main.post { done(err) }
        }
        try {
            cm.openCamera(id, object : CameraDevice.StateCallback() {
                override fun onOpened(cam: CameraDevice) {
                    device = cam
                    try {
                        @Suppress("DEPRECATION")
                        cam.createCaptureSession(listOf(r.surface), object : CameraCaptureSession.StateCallback() {
                            override fun onConfigured(s: CameraCaptureSession) {
                                session = s
                                try {
                                    val req = cam.createCaptureRequest(CameraDevice.TEMPLATE_PREVIEW).apply {
                                        addTarget(r.surface)
                                        if (fpsRange != null) set(CaptureRequest.CONTROL_AE_TARGET_FPS_RANGE, fpsRange)
                                        set(CaptureRequest.CONTROL_AF_MODE, CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_PICTURE)
                                    }.build()
                                    s.setRepeatingRequest(req, null, h)
                                    Log.i(TAG, "camera $id open ${size.width}x${size.height} fps=$fpsRange rot=$rotation")
                                    answer(null)
                                } catch (e: Exception) {
                                    answer("camera start failed: ${e.message}")
                                    close()
                                }
                            }

                            override fun onConfigureFailed(s: CameraCaptureSession) {
                                answer("camera session failed")
                                close()
                            }
                        }, h)
                    } catch (e: Exception) {
                        answer("camera session failed: ${e.message}")
                        close()
                    }
                }

                override fun onDisconnected(cam: CameraDevice) {
                    answer("camera disconnected")
                    close()
                }

                override fun onError(cam: CameraDevice, error: Int) {
                    answer("camera error $error")
                    close()
                }
            }, h)
        } catch (e: Exception) {
            close()
            done("camera open failed: ${e.message}")
        }
    }

    fun close() {
        try { session?.close() } catch (_: Exception) {}
        try { device?.close() } catch (_: Exception) {}
        try { reader?.close() } catch (_: Exception) {}
        session = null
        device = null
        reader = null
        thread?.quitSafely()
        thread = null
        handler = null
    }

    /** YUV_420_888 -> NV21 -> JPEG, rotated upright and scaled to [MAX_W]. */
    private fun toJpeg(img: Image): Map<String, Any>? {
        val w = img.width
        val h = img.height
        val nv21 = ByteArray(w * h * 3 / 2)
        val y = img.planes[0]
        val u = img.planes[1]
        val v = img.planes[2]
        var o = 0
        val yb = y.buffer
        for (row in 0 until h) {
            yb.position(row * y.rowStride)
            yb.get(nv21, o, w)
            o += w
        }
        val ub = u.buffer
        val vb = v.buffer
        val ps = u.pixelStride
        for (row in 0 until h / 2) {
            for (col in 0 until w / 2) {
                val i = row * u.rowStride + col * ps
                nv21[o++] = vb.get(row * v.rowStride + col * v.pixelStride)
                nv21[o++] = ub.get(i)
            }
        }
        val raw = ByteArrayOutputStream()
        YuvImage(nv21, ImageFormat.NV21, w, h, null).compressToJpeg(Rect(0, 0, w, h), 85, raw)
        val bytes = raw.toByteArray()
        if (rotation == 0 && !mirror && w <= MAX_W) {
            return mapOf("type" to "camera", "jpeg" to bytes, "width" to w, "height" to h)
        }
        val bmp = BitmapFactory.decodeByteArray(bytes, 0, bytes.size) ?: return null
        val s = MAX_W.toFloat() / maxOf(w, h)
        val m = Matrix().apply {
            if (s < 1f) postScale(s, s)
            postRotate(rotation.toFloat())
            if (mirror) postScale(-1f, 1f)
        }
        val out = Bitmap.createBitmap(bmp, 0, 0, w, h, m, true)
        bmp.recycle()
        val jpg = ByteArrayOutputStream()
        out.compress(Bitmap.CompressFormat.JPEG, 80, jpg)
        val res = mapOf("type" to "camera", "jpeg" to jpg.toByteArray(), "width" to out.width, "height" to out.height)
        out.recycle()
        return res
    }
}
