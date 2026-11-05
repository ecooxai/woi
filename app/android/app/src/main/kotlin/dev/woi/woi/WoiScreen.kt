package dev.woi.woi

import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.PixelFormat
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.media.Image
import android.media.ImageReader
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Handler
import android.os.HandlerThread
import android.util.Log
import android.view.WindowManager

/**
 * Screen share: a MediaProjection mirrored into an ImageReader. Only the
 * newest frame is kept (as the raw Image, no per-frame conversion), so a
 * static screen costs nothing; [frame] converts it to a JPEG on demand when a
 * turn starts.
 */
object WoiScreen {
    private var projection: MediaProjection? = null
    private var display: VirtualDisplay? = null
    private var reader: ImageReader? = null
    private var thread: HandlerThread? = null
    private val lock = Object()
    private var latest: Image? = null
    private var frames = 0L
    private var realW = 0
    private var realH = 0

    fun isSharing() = projection != null

    fun realSize(ctx: Context): Pair<Int, Int> {
        val wm = ctx.getSystemService(WindowManager::class.java)
        val b = wm.maximumWindowMetrics.bounds
        return Pair(b.width(), b.height())
    }

    /** Called by the foreground service after startForeground(mediaProjection). */
    fun start(ctx: Context, resultCode: Int, data: Intent): Boolean {
        stop(ctx, notify = false)
        val mpm = ctx.getSystemService(MediaProjectionManager::class.java)
        val mp = mpm.getMediaProjection(resultCode, data) ?: return false
        val (w, h) = realSize(ctx)
        realW = w
        realH = h
        // Half resolution is plenty for the model (and 4x cheaper to copy).
        val scale = if (w > 1080) 1080f / w else 0.5f.coerceAtLeast(720f / w).coerceAtMost(1f)
        val vw = (w * scale).toInt() and 1.inv()
        val vh = (h * scale).toInt() and 1.inv()
        val t = HandlerThread("woi-share").apply { start() }
        val handler = Handler(t.looper)
        val r = ImageReader.newInstance(vw, vh, PixelFormat.RGBA_8888, 3)
        r.setOnImageAvailableListener({ rd ->
            val img = try { rd.acquireLatestImage() } catch (e: Exception) { null } ?: return@setOnImageAvailableListener
            synchronized(lock) {
                latest?.close()
                latest = img
                frames++
            }
        }, handler)
        mp.registerCallback(object : MediaProjection.Callback() {
            override fun onStop() {
                WoiBridge.main.post { stop(ctx) }
            }
        }, WoiBridge.main)
        projection = mp
        reader = r
        thread = t
        display = mp.createVirtualDisplay(
            "woi-share", vw, vh, ctx.resources.displayMetrics.densityDpi,
            DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR, r.surface, null, handler
        )
        Log.i(WoiBridge.TAG, "screen share ${vw}x$vh of ${w}x$h")
        WoiBridge.emit(mapOf("type" to "share", "on" to true))
        return true
    }

    fun stop(ctx: Context, notify: Boolean = true) {
        val mp = projection ?: return
        projection = null
        display?.release(); display = null
        synchronized(lock) { latest?.close(); latest = null }
        reader?.close(); reader = null
        thread?.quitSafely(); thread = null
        try { mp.stop() } catch (_: Exception) {}
        WoiForegroundService.shareStopped(ctx)
        if (notify) WoiBridge.emit(mapOf("type" to "share", "on" to false))
    }

    /** Newest frame, scaled and JPEG/PNG-encoded ({bytes, width, height, originalWidth, originalHeight}). */
    fun frame(scale: Double, quality: Int, maxWidth: Int): Map<String, Any?>? {
        val bmp: Bitmap
        synchronized(lock) {
            val img = latest ?: return null
            val plane = img.planes[0]
            val pixelStride = plane.pixelStride
            val rowPadding = plane.rowStride - pixelStride * img.width
            val full = Bitmap.createBitmap(img.width + rowPadding / pixelStride, img.height, Bitmap.Config.ARGB_8888)
            plane.buffer.rewind()
            full.copyPixelsFromBuffer(plane.buffer)
            bmp = if (rowPadding == 0) full else Bitmap.createBitmap(full, 0, 0, img.width, img.height).also { full.recycle() }
        }
        val out = ScreenshotEncoder.encodeToMap(bmp, scale, quality, maxWidth, realW.takeIf { it > 0 } ?: bmp.width, realH.takeIf { it > 0 } ?: bmp.height)
        bmp.recycle()
        return out + mapOf("frames" to frames)
    }
}
