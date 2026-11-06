package dev.woi.woi

import android.content.ContentValues
import android.content.Context
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import java.io.File

/** Saves app files (e.g. a message's audio) to the user's Downloads. */
object WoiDownloads {
    /** Copies [path] to Download/Woi/[name]; returns where it went. */
    fun save(ctx: Context, path: String, name: String, mime: String): String {
        val src = File(path)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val values = ContentValues().apply {
                put(MediaStore.Downloads.DISPLAY_NAME, name)
                put(MediaStore.Downloads.MIME_TYPE, mime)
                put(MediaStore.Downloads.RELATIVE_PATH, "${Environment.DIRECTORY_DOWNLOADS}/Woi")
                put(MediaStore.Downloads.IS_PENDING, 1)
            }
            val resolver = ctx.contentResolver
            val uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
                ?: throw IllegalStateException("could not create the download")
            try {
                resolver.openOutputStream(uri)!!.use { out -> src.inputStream().use { it.copyTo(out) } }
                values.clear()
                values.put(MediaStore.Downloads.IS_PENDING, 0)
                resolver.update(uri, values, null, null)
            } catch (e: Exception) {
                resolver.delete(uri, null, null)
                throw e
            }
            return "Download/Woi/$name"
        }
        // Before Android 10 the shared Downloads needs a storage permission:
        // use the app's own Downloads folder instead.
        val dir = File(ctx.getExternalFilesDir(Environment.DIRECTORY_DOWNLOADS), "Woi").apply { mkdirs() }
        val target = File(dir, name)
        src.copyTo(target, overwrite = true)
        return target.absolutePath
    }
}
