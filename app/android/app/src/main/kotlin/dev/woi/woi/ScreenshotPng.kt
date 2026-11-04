package dev.woi.woi

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.ColorSpace
import android.graphics.Paint
import android.graphics.Rect
import android.os.Build
import java.io.File
import java.io.FileOutputStream

/**
 * Screenshot bitmap -> opaque 8-bit sRGB PNG, scaled to at most [maxWidth].
 *
 * The assist screenshot (VoiceInteractionSession.onHandleScreenshot) may be a
 * HARDWARE bitmap (GPU buffer; not readable pixel by pixel), in the
 * display's colour space (Display P3 / F16 on wide-gamut phones), with an
 * alpha channel the opaque screen does not use. createScaledBitmap +
 * compress kept all of that: an RGBA PNG whose colour handling depended on
 * the source. Here the pixels are read back into a software copy, marked
 * opaque and drawn into an sRGB bitmap without alpha, so the PNG is plain
 * 8-bit sRGB whatever the source (and ~8% smaller: no alpha bytes).
 * The log line shows the source format ([Result.source]).
 */
object ScreenshotPng {
    data class Result(val width: Int, val height: Int, val source: String)

    fun write(src: Bitmap, maxWidth: Int, out: File): Result {
        val w = src.width
        val h = src.height
        val dw = minOf(w, maxWidth).coerceAtLeast(1)
        val dh = (h.toLong() * dw / w).toInt().coerceAtLeast(1)
        val soft = src.copy(Bitmap.Config.ARGB_8888, true) ?: error("screenshot readback failed")
        val source = describe(src, soft)
        soft.setHasAlpha(false)
        val dst =
            if (Build.VERSION.SDK_INT >= 26) {
                Bitmap.createBitmap(dw, dh, Bitmap.Config.ARGB_8888, false, ColorSpace.get(ColorSpace.Named.SRGB))
            } else {
                Bitmap.createBitmap(dw, dh, Bitmap.Config.ARGB_8888).apply { setHasAlpha(false) }
            }
        Canvas(dst).drawBitmap(soft, null, Rect(0, 0, dw, dh), Paint(Paint.FILTER_BITMAP_FLAG))
        soft.recycle()
        FileOutputStream(out).use { dst.compress(Bitmap.CompressFormat.PNG, 100, it) }
        dst.recycle()
        return Result(dw, dh, source)
    }

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
}
