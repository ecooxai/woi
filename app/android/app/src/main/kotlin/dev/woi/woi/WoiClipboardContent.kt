package dev.woi.woi

import android.content.ClipData
import android.content.ClipDescription
import android.content.ContentProvider
import android.content.ContentValues
import android.content.Context
import android.database.Cursor
import android.database.MatrixCursor
import android.graphics.BitmapFactory
import android.net.Uri
import android.os.ParcelFileDescriptor
import android.provider.OpenableColumns
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.InputStream
import java.util.UUID

internal object WoiClipboardContent {
    const val MAX_IMAGE_BYTES = 12 * 1024 * 1024
    const val MAX_PIXELS = 32L * 1024 * 1024

    fun boundedBytes(input: InputStream, maximum: Int): ByteArray {
        val output = ByteArrayOutputStream()
        val buffer = ByteArray(16 * 1024)
        while (true) {
            val count = input.read(buffer)
            if (count < 0) break
            require(output.size().toLong() + count <= maximum) { "The selected content exceeds the size limit" }
            output.write(buffer, 0, count)
        }
        return output.toByteArray()
    }

    fun imageMime(bytes: ByteArray): String {
        require(bytes.isNotEmpty() && bytes.size <= MAX_IMAGE_BYTES) { "Clipboard images must be 12 MB or smaller" }
        val options = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(bytes, 0, bytes.size, options)
        require(options.outWidth > 0 && options.outHeight > 0 && options.outWidth.toLong() * options.outHeight <= MAX_PIXELS) {
            "The clipboard image is invalid or larger than 32 megapixels"
        }
        return options.outMimeType?.takeIf { it.startsWith("image/") }
            ?: throw IllegalArgumentException("The clipboard image format is unsupported")
    }

    fun read(context: Context, clip: ClipData?): Map<String, Any?> {
        val item = clip?.takeIf { it.itemCount > 0 }?.getItemAt(0)
        val text = item?.text?.toString()
        require(text == null || text.length <= 100000) { "Clipboard text exceeds the 100000 UTF-16 unit limit" }
        val result = mutableMapOf<String, Any?>("text" to text)
        val uri = item?.uri ?: return result
        if (uri.scheme != "content" && uri.scheme != "file") return result
        val resolver = context.contentResolver
        val mime = resolver.getType(uri) ?: clip?.description?.let { description ->
            (0 until description.mimeTypeCount).map { description.getMimeType(it) }.firstOrNull { it.startsWith("image/") }
        }
        if (mime?.startsWith("image/") != true) return result
        val bytes = resolver.openInputStream(uri)?.use { boundedBytes(it, MAX_IMAGE_BYTES) }
            ?: throw IllegalStateException("The clipboard image is no longer available")
        val actualMime = imageMime(bytes)
        var name: String? = null
        if (uri.scheme == "content") {
            resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
                if (cursor.moveToFirst()) name = cursor.getString(0)
            }
        }
        result["image"] = mapOf("bytes" to bytes, "mimeType" to actualMime, "name" to (name ?: "clipboard.${extension(actualMime)}"))
        return result
    }

    fun createClip(context: Context, arguments: Map<*, *>): ClipData {
        val image = arguments["image"] as? Map<*, *> ?: throw IllegalArgumentException("image is required")
        val bytes = image["bytes"] as? ByteArray ?: throw IllegalArgumentException("Image bytes are required")
        val mime = imageMime(bytes)
        val text = arguments["text"] as? String
        require(text == null || text.length <= 100000) { "Clipboard text exceeds the 100000 UTF-16 unit limit" }
        val dir = File(context.cacheDir, "clipboard-images").apply { mkdirs() }
        // Keep recent copies alive for readers that retain a granted URI.
        dir.listFiles()?.filter { System.currentTimeMillis() - it.lastModified() > 7L * 24 * 60 * 60 * 1000 }?.forEach { it.delete() }
        val file = File(dir, "${UUID.randomUUID()}.${extension(mime)}")
        file.writeBytes(bytes)
        val uri = Uri.Builder().scheme("content").authority("${context.packageName}.clipboard").appendPath(file.name).build()
        val types = if (text == null) arrayOf(mime) else arrayOf(mime, "text/plain")
        return ClipData(ClipDescription("Woi image", types), ClipData.Item(text, null, null, uri))
    }

    fun extension(mime: String): String = when (mime.lowercase()) {
        "image/jpeg" -> "jpg"
        "image/gif" -> "gif"
        "image/webp" -> "webp"
        "image/bmp", "image/x-ms-bmp" -> "bmp"
        else -> "png"
    }
}

/** Read-only, URI-granted access to images explicitly copied by the user. */
class WoiClipboardProvider : ContentProvider() {
    override fun onCreate() = true
    private fun file(uri: Uri): File {
        val name = uri.lastPathSegment ?: throw IllegalArgumentException("Missing image")
        require(uri.pathSegments.size == 1 && Regex("[A-Za-z0-9.-]+").matches(name)) { "Invalid image URI" }
        val root = File(requireNotNull(context).cacheDir, "clipboard-images").canonicalFile
        val result = File(root, name).canonicalFile
        require(result.parentFile == root && result.isFile) { "Clipboard image is unavailable" }
        return result
    }
    override fun getType(uri: Uri): String = when (file(uri).extension) {
        "jpg" -> "image/jpeg"
        "gif" -> "image/gif"
        "webp" -> "image/webp"
        "bmp" -> "image/bmp"
        else -> "image/png"
    }
    override fun query(uri: Uri, projection: Array<out String>?, selection: String?, selectionArgs: Array<out String>?, sortOrder: String?): Cursor {
        val file = file(uri)
        val columns = projection ?: arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE)
        return MatrixCursor(columns).apply { addRow(columns.map { if (it == OpenableColumns.SIZE) file.length() else if (it == OpenableColumns.DISPLAY_NAME) "clipboard.${file.extension}" else null }) }
    }
    override fun openFile(uri: Uri, mode: String): ParcelFileDescriptor {
        require(mode == "r") { "Clipboard images are read-only" }
        return ParcelFileDescriptor.open(file(uri), ParcelFileDescriptor.MODE_READ_ONLY)
    }
    override fun insert(uri: Uri, values: ContentValues?): Uri? = throw UnsupportedOperationException()
    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?): Int = throw UnsupportedOperationException()
    override fun update(uri: Uri, values: ContentValues?, selection: String?, selectionArgs: Array<out String>?): Int = throw UnsupportedOperationException()
}
