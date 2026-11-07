package dev.woi.woi

import android.content.Context
import android.content.Intent
import android.media.projection.MediaProjectionManager
import android.net.Uri
import android.os.Build
import android.provider.OpenableColumns
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.android.FlutterView
import io.flutter.embedding.engine.FlutterEngine
import java.io.File

class MainActivity : FlutterActivity() {
    private var permCallback: ((Boolean) -> Unit)? = null
    private var projectionCallback: ((Boolean) -> Unit)? = null

    /** Started (visible or about to be); the overlay hands the engine back. */
    var started = false
        private set

    /** Resumed: Woi itself is in front, so the assist gesture opens no panel. */
    var resumed = false
        private set

    // One engine for the process (WoiEngine), shared with the assistant
    // overlay; it outlives this activity.
    override fun provideFlutterEngine(context: Context): FlutterEngine = WoiEngine.obtain(context)

    override fun shouldDestroyEngineWithHost(): Boolean = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        // Plugins are registered by the engine itself (host-provided engine).
        WoiBridge.activity = this
        handleIntent(intent)
    }

    override fun onStart() {
        started = true
        WoiBridge.activity = this
        WoiA11yKeeper.ensure(this, "app start")
        // The launcher (or "open full app") wins over a floating panel.
        if (WoiOverlay.showing) WoiOverlay.dismiss()
        reattachFlutterView()
        super.onStart()
    }

    override fun onResume() {
        super.onResume()
        resumed = true
    }

    override fun onPause() {
        resumed = false
        super.onPause()
    }

    override fun onStop() {
        started = false
        super.onStop()
    }

    private fun flutterView(): FlutterView? = findViewById(FLUTTER_VIEW_ID)

    /** The overlay takes the engine: this activity's view lets go of it. */
    fun releaseFlutterView() {
        val v = flutterView() ?: return
        if (v.isAttachedToFlutterEngine) v.detachFromFlutterEngine()
    }

    fun reattachFlutterView() {
        val v = flutterView() ?: return
        val engine = WoiEngine.peek() ?: return
        if (!v.isAttachedToFlutterEngine) v.attachToFlutterEngine(engine)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleIntent(intent)
    }

    override fun onDestroy() {
        if (WoiBridge.activity === this) WoiBridge.activity = null
        val pendingProjection = projectionCallback
        val pendingPermission = permCallback
        projectionCallback = null
        permCallback = null
        pendingProjection?.invoke(false)
        pendingPermission?.invoke(false)
        super.onDestroy()
    }

    // --- permissions ---

    fun requestPerms(perms: Array<String>, cb: (Boolean) -> Unit) {
        val missing = perms.filter { checkSelfPermission(it) != android.content.pm.PackageManager.PERMISSION_GRANTED }
        if (missing.isEmpty()) return cb(true)
        if (permCallback != null) return cb(false)
        permCallback = cb
        requestPermissions(missing.toTypedArray(), REQ_PERMS)
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == REQ_PERMS) {
            val cb = permCallback
            permCallback = null
            cb?.invoke(grantResults.isNotEmpty() && grantResults.all { it == android.content.pm.PackageManager.PERMISSION_GRANTED })
        }
    }

    // --- screen share consent ---

    fun requestProjection(cb: (Boolean) -> Unit) {
        if (WoiScreen.isSharing()) return cb(true)
        if (projectionCallback != null) return cb(false)
        val mpm = getSystemService(MediaProjectionManager::class.java)
        projectionCallback = cb
        @Suppress("DEPRECATION")
        startActivityForResult(mpm.createScreenCaptureIntent(), REQ_PROJECTION)
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        @Suppress("DEPRECATION")
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != REQ_PROJECTION) return
        val cb = projectionCallback
        projectionCallback = null
        if (resultCode == RESULT_OK && data != null) {
            WoiForegroundService.startShare(this, resultCode, data)
            cb?.invoke(true)
        } else {
            cb?.invoke(false)
        }
    }

    // --- intents: assistant, open with, share ---

    private fun handleIntent(intent: Intent?) {
        if (intent == null || intent.getBooleanExtra(EXTRA_HANDLED, false)) return
        intent.putExtra(EXTRA_HANDLED, true)
        when {
            intent.getBooleanExtra(WoiSession.EXTRA_ASSIST, false) || intent.action == Intent.ACTION_ASSIST ||
                intent.action == "android.intent.action.VOICE_ASSIST" -> {
                WoiBridge.emit(
                    mapOf(
                        "type" to "assist",
                        "png" to intent.getStringExtra(WoiSession.EXTRA_PNG),
                        "width" to intent.getIntExtra(WoiSession.EXTRA_W, 0),
                        "height" to intent.getIntExtra(WoiSession.EXTRA_H, 0),
                        "originalWidth" to intent.getIntExtra(WoiSession.EXTRA_OW, 0),
                        "originalHeight" to intent.getIntExtra(WoiSession.EXTRA_OH, 0),
                        "app" to intent.getStringExtra(WoiSession.EXTRA_APP),
                        "screenText" to intent.getStringExtra(WoiSession.EXTRA_TEXT),
                        "shownAt" to intent.getLongExtra(WoiSession.EXTRA_T0, 0L),
                    )
                )
            }
            intent.action == Intent.ACTION_VIEW && intent.data != null -> importUris(listOf(intent.data!!), intent.type, null)
            intent.action == Intent.ACTION_SEND -> {
                val uri = streamExtra(intent)
                val text = intent.getStringExtra(Intent.EXTRA_TEXT)
                if (uri != null) importUris(listOf(uri), intent.type, text) else if (text != null) importUris(emptyList(), intent.type, text)
            }
            intent.action == Intent.ACTION_SEND_MULTIPLE -> {
                val uris = streamListExtra(intent)
                importUris(uris, intent.type, intent.getStringExtra(Intent.EXTRA_TEXT))
            }
        }
    }

    private fun streamExtra(i: Intent): Uri? =
        if (Build.VERSION.SDK_INT >= 33) i.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
        else @Suppress("DEPRECATION") i.getParcelableExtra(Intent.EXTRA_STREAM)

    private fun streamListExtra(i: Intent): List<Uri> =
        (if (Build.VERSION.SDK_INT >= 33) i.getParcelableArrayListExtra(Intent.EXTRA_STREAM, Uri::class.java)
        else @Suppress("DEPRECATION") i.getParcelableArrayListExtra(Intent.EXTRA_STREAM)) ?: emptyList()

    /** Copies content:// / file:// items into the cache (other apps' grants
     *  are temporary) and tells Dart to open them. */
    private fun importUris(uris: List<Uri>, type: String?, text: String?) {
        val resolver = contentResolver
        val dir = File(cacheDir, "shared").apply { mkdirs() }
        WoiBridge.io.execute {
            val files = ArrayList<Map<String, Any?>>()
            for (uri in uris) {
                try {
                    var name: String? = null
                    if (uri.scheme == "content") {
                        resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { c ->
                            if (c.moveToFirst()) name = c.getString(0)
                        }
                    }
                    if (name == null) name = uri.lastPathSegment?.substringAfterLast('/')
                    val mime = resolver.getType(uri) ?: type
                    val safe = (name ?: "shared").replace(Regex("[^A-Za-z0-9._ -]"), "_").take(80)
                    val out = File(dir, "${System.currentTimeMillis()}-$safe")
                    val input = if (uri.scheme == "file") File(uri.path!!).inputStream() else resolver.openInputStream(uri)
                    input?.use { inp -> out.outputStream().use { inp.copyTo(it) } }
                    files.add(mapOf("path" to out.absolutePath, "mime" to mime, "name" to name))
                } catch (e: Exception) {
                    Log.w(WoiBridge.TAG, "import $uri failed", e)
                    files.add(mapOf("error" to (e.message ?: e.toString()), "name" to uri.toString()))
                }
            }
            WoiBridge.emit(mapOf("type" to "open", "files" to files, "text" to text, "mime" to type))
        }
    }

    companion object {
        const val REQ_PERMS = 7101
        const val REQ_PROJECTION = 7102
        const val EXTRA_HANDLED = "woi_handled"
    }
}
