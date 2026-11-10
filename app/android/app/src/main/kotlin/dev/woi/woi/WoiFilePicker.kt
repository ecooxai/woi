package dev.woi.woi

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.provider.OpenableColumns
import android.view.Gravity
import android.widget.TextView
import android.webkit.MimeTypeMap
import io.flutter.plugin.common.MethodChannel
import java.lang.ref.WeakReference
import java.util.UUID

internal object WoiFilePicker {
    private data class Pending(val id: String, val result: MethodChannel.Result)
    private var pending: Pending? = null
    private var owner: WeakReference<WoiFilePickerActivity>? = null
    const val MAX_FILE_BYTES = 20 * 1024 * 1024
    const val MAX_TOTAL_BYTES = 32 * 1024 * 1024
    const val MAX_FILES = 8

    fun pick(result: MethodChannel.Result) {
        if (pending != null) { result.error("picker_busy", "A file browser is already open", null); return }
        val panelShowing = WoiOverlay.showing
        val reply = if (panelShowing) WoiOverlay.releasing(result, samePanelOnly = true) else result
        try {
            if (panelShowing) WoiOverlay.stepAside(true)
            val request = Pending(UUID.randomUUID().toString(), reply)
            pending = request
            val context = WoiAccessibilityService.instance ?: WoiBridge.appContext
            context.startActivity(Intent(context, WoiFilePickerActivity::class.java).apply {
                putExtra("request", request.id)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_EXCLUDE_FROM_RECENTS)
            })
        } catch (error: Throwable) {
            pending = null
            reply.error("file_picker", error.message ?: "Android could not open the file browser", null)
        }
    }

    fun attach(activity: WoiFilePickerActivity, id: String?): Boolean {
        if (id == null || pending?.id != id) return false
        owner = WeakReference(activity)
        return true
    }

    fun selected(activity: WoiFilePickerActivity, id: String, uris: List<Uri>) {
        if (pending?.id != id) return
        if (uris.size > MAX_FILES) { complete(id, error = "Choose up to 8 files at a time"); return }
        if (uris.isEmpty()) { complete(id, value = emptyList<Any>()); return }
        WoiBridge.io.execute {
            try {
                var total = 0
                val files = uris.map { uri ->
                    require(uri.scheme == "content" || uri.scheme == "file") { "This file provider is unsupported" }
                    var name: String? = null
                    activity.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE), null, null, null)?.use { cursor ->
                        if (cursor.moveToFirst()) {
                            name = cursor.getString(0)
                            if (!cursor.isNull(1)) require(cursor.getLong(1) <= MAX_FILE_BYTES) { "Each attachment must be 20 MB or smaller" }
                        }
                    }
                    val bytes = activity.contentResolver.openInputStream(uri)?.use { WoiClipboardContent.boundedBytes(it, MAX_FILE_BYTES) }
                        ?: throw IllegalStateException("The selected file is no longer available")
                    total += bytes.size
                    require(total <= MAX_TOTAL_BYTES) { "Attachments must total 32 MB or less" }
                    val title = name ?: uri.lastPathSegment?.substringAfterLast('/') ?: "attachment"
                    val mime = activity.contentResolver.getType(uri)
                        ?: MimeTypeMap.getSingleton().getMimeTypeFromExtension(title.substringAfterLast('.', "").lowercase())
                        ?: "application/octet-stream"
                    mapOf("bytes" to bytes, "name" to title, "mimeType" to mime)
                }
                WoiBridge.main.post { complete(id, value = files) }
            } catch (error: Throwable) {
                WoiBridge.main.post { complete(id, error = error.message ?: "The selected file could not be read") }
            }
        }
    }

    fun abandoned(id: String) { if (pending?.id == id) complete(id, value = emptyList<Any>()) }

    private fun complete(id: String, value: Any? = null, error: String? = null) {
        val request = pending?.takeIf { it.id == id } ?: return
        pending = null
        val activity = owner?.get()
        owner = null
        activity?.finish()
        val deadline = android.os.SystemClock.uptimeMillis() + 700
        fun release() {
            if (activity != null && !activity.isDestroyed && activity.hasWindowFocus() && android.os.SystemClock.uptimeMillis() < deadline) {
                WoiBridge.main.postDelayed(::release, 32)
                return
            }
            if (error == null) request.result.success(value) else request.result.error("file_picker", error, null)
        }
        WoiBridge.main.postDelayed(::release, if (activity == null) 0 else 32)
    }
}

class WoiFilePickerActivity : Activity() {
    private var requestId: String? = null
    override fun onCreate(state: Bundle?) {
        super.onCreate(state)
        requestId = intent.getStringExtra("request")
        if (!WoiFilePicker.attach(this, requestId)) { finish(); return }
        setContentView(TextView(this).apply {
            text = "Choose files to attach"
            textSize = 16f
            gravity = Gravity.CENTER
            val pad = (24 * resources.displayMetrics.density).toInt()
            setPadding(pad, pad, pad, pad)
        })
        if (state == null) {
            try {
                @Suppress("DEPRECATION")
                startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                    addCategory(Intent.CATEGORY_OPENABLE)
                    type = "*/*"
                    putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                }, 7204)
            } catch (_: Exception) { requestId?.let { WoiFilePicker.abandoned(it) } }
        }
    }
    @Deprecated("Uses the platform Activity result contract without an AndroidX lifecycle host")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != 7204) return
        val id = requestId ?: return
        val uris = if (resultCode != RESULT_OK) emptyList() else data?.clipData?.let { clip ->
            (0 until clip.itemCount).map { clip.getItemAt(it).uri }
        } ?: listOfNotNull(data?.data)
        WoiFilePicker.selected(this, id, uris.distinct())
    }
    override fun onDestroy() {
        if (!isChangingConfigurations) requestId?.let { WoiFilePicker.abandoned(it) }
        super.onDestroy()
    }
}
