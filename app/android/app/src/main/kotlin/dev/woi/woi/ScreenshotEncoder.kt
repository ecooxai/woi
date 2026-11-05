package dev.woi.woi

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.ColorSpace
import android.graphics.Paint
import android.graphics.Rect
import android.os.Build
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileOutputStream
import kotlin.math.roundToInt

/**
 * Screenshot bitmap -> opaque 8-bit sRGB JPEG (or PNG), scaled to
 * `scale` x the screen's physical pixels (Settings > Screen & camera;
 * defaults 50 % / JPEG 80). Runs on a background thread (callers use
 * WoiBridge.io), never on the UI thread.
 *
 * Screenshots may be HARDWARE bitmaps (GPU buffer; not readable pixel by
 * pixel), in the display's colour space (Display P3 / F16 on wide-gamut
 * phones), with an alpha channel the opaque screen does not use. Here the
 * pixels are read back into a software copy, marked opaque and drawn
 * (filtered) into an sRGB bitmap without alpha, so the output is plain
 * 8-bit sRGB whatever the source. The log line shows the source format
 * ([Result.source]).
 */
object ScreenshotEncoder {
    const val DEFAULT_SCALE = 0.5
    const val DEFAULT_QUALITY = 80

    private const val PREFS = "woi_screenshot"
    private const val KEY_SCALE = "scale"
    private const val KEY_QUALITY = "quality"

    data class Result(val width: Int, val height: Int, val source: String, val bytes: Int)

    /** Settings pushed from Dart ("screenshotPrefs"): used by the assist screenshot. */
    fun scale(ctx: Context): Double =
        ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getFloat(KEY_SCALE, DEFAULT_SCALE.toFloat()).toDouble()

    fun quality(ctx: Context): Int =
        ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getInt(KEY_QUALITY, DEFAULT_QUALITY)

    fun savePrefs(ctx: Context, scale: Double, quality: Int) {
        ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
            .putFloat(KEY_SCALE, scale.coerceIn(0.01, 1.0).toFloat())
            .putInt(KEY_QUALITY, quality.coerceIn(1, 100))
            .apply()
    }

    /**
     * Target size: [scale] x the physical [ow]x[oh] (aspect kept, never larger
     * than the screen nor than the [srcW]-wide source bitmap, at least 1x1),
     * also capped at [maxWidth] when > 0. Same math as Dart's screenshotSize.
     */
    fun scaledSize(ow: Int, oh: Int, scale: Double, maxWidth: Int = 0, srcW: Int = ow): Pair<Int, Int> {
        if (ow <= 0 || oh <= 0) return Pair(maxOf(ow, 1), maxOf(oh, 1))
        val s = if (scale.isFinite() && scale > 0) scale.coerceIn(0.01, 1.0) else 1.0
        var w = (ow * s).roundToInt().coerceIn(1, ow)
        if (maxWidth in 1 until w) w = maxWidth
        if (srcW in 1 until w) w = srcW
        val h = if (w == ow) oh else (oh.toDouble() * w / ow).roundToInt().coerceIn(1, oh)
        return Pair(w, h)
    }

    /**
     * Encodes [src] (showing a screen of [ow]x[oh] physical pixels): JPEG at
     * [quality] (1-100), or PNG when [quality] <= 0.
     */
    fun encode(src: Bitmap, scale: Double, quality: Int, maxWidth: Int, ow: Int, oh: Int, out: java.io.OutputStream): Result {
        val (dw, dh) = scaledSize(ow, oh, scale, maxWidth, src.width)
        val soft = if (src.config == Bitmap.Config.ARGB_8888 && src.isMutable) src
        else src.copy(Bitmap.Config.ARGB_8888, true) ?: error("screenshot readback failed")
        val source = describe(src, soft)
        soft.setHasAlpha(false)
        val dst =
            if (Build.VERSION.SDK_INT >= 26) {
                Bitmap.createBitmap(dw, dh, Bitmap.Config.ARGB_8888, false, ColorSpace.get(ColorSpace.Named.SRGB))
            } else {
                Bitmap.createBitmap(dw, dh, Bitmap.Config.ARGB_8888).apply { setHasAlpha(false) }
            }
        Canvas(dst).drawBitmap(soft, null, Rect(0, 0, dw, dh), Paint(Paint.FILTER_BITMAP_FLAG))
        if (soft !== src) soft.recycle()
        val counting = CountingStream(out)
        if (quality > 0) dst.compress(Bitmap.CompressFormat.JPEG, quality.coerceIn(1, 100), counting)
        else dst.compress(Bitmap.CompressFormat.PNG, 100, counting)
        dst.recycle()
        return Result(dw, dh, source, counting.count)
    }

    /** Encodes to bytes: {bytes, width, height, originalWidth, originalHeight}. */
    fun encodeToMap(src: Bitmap, scale: Double, quality: Int, maxWidth: Int, ow: Int, oh: Int): Map<String, Any?> {
        val bos = ByteArrayOutputStream(128 * 1024)
        val r = encode(src, scale, quality, maxWidth, ow, oh, bos)
        return mapOf(
            "bytes" to bos.toByteArray(),
            "width" to r.width,
            "height" to r.height,
            "originalWidth" to ow,
            "originalHeight" to oh,
        )
    }

    /** Encodes into [out] (assist screenshot). */
    fun write(src: Bitmap, scale: Double, quality: Int, out: File): Result =
        FileOutputStream(out).use { encode(src, scale, quality, 0, src.width, src.height, it) }

    /** Source format for the log: config, colour space, alpha range of a pixel grid. */
    private fun describe(src: Bitmap, soft: Bitmap): String {
        var aMin = 255
        var aMax = 0
        for (gy in 1..7) {
            for (gx in 1..7) {
                val a = soft.getPixel(soft.width * gx / 8, soft.height * gy / 8) ushr 24
                if (a < aMin) aMin = a
                if (a > aMax) aMax = a
            }
        }
        val cs = if (Build.VERSION.SDK_INT >= 26) src.colorSpace?.name else null
        return "${src.config} ${cs ?: "?"} hasAlpha=${src.hasAlpha()} premul=${src.isPremultiplied} alpha=$aMin..$aMax"
    }

    private class CountingStream(private val out: java.io.OutputStream) : java.io.OutputStream() {
        var count = 0
        override fun write(b: Int) { out.write(b); count++ }
        override fun write(b: ByteArray, off: Int, len: Int) { out.write(b, off, len); count += len }
        override fun flush() = out.flush()
    }
}
