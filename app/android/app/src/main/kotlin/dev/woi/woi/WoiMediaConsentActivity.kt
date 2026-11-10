package dev.woi.woi

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.media.projection.MediaProjectionManager
import android.os.Bundle
import android.view.Gravity
import android.view.WindowManager
import android.widget.TextView

/** A visible, non-exported owner for Android capture consent. Never uses
 * noHistory: the OS permission/MediaProjection dialog must return here. */
class WoiMediaConsentActivity : Activity() {
    private var kind = ""
    private var request = 0L
    private var asked = false

    override fun onCreate(state: Bundle?) {
        super.onCreate(state)
        kind = intent.getStringExtra("kind") ?: ""
        request = intent.getLongExtra("request", 0)
        if (!WoiMediaCapture.attach(this, kind, request)) { finish(); return }
        asked = state?.getBoolean("asked") ?: false
        window.setSoftInputMode(WindowManager.LayoutParams.SOFT_INPUT_STATE_ALWAYS_HIDDEN)
        setFinishOnTouchOutside(false)
        setContentView(TextView(this).apply {
            text = if (kind == WoiMediaCapture.CAMERA) "Woi camera access" else "Share your screen with Woi"
            textSize = 18f
            gravity = Gravity.CENTER
            val pad = (28 * resources.displayMetrics.density).toInt()
            setPadding(pad, pad, pad, pad)
            contentDescription = text
        })
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (!hasFocus || asked || !WoiMediaCapture.requestValid(kind, request)) return
        asked = true
        // A drawn foreground window is required for camera while-in-use
        // permission and its foreground service on current Android versions.
        window.decorView.post {
            if (!WoiMediaCapture.requestValid(kind, request) || isFinishing) return@post
            try {
                if (kind == WoiMediaCapture.CAMERA) {
                    if (checkSelfPermission(Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED) {
                        WoiMediaCapture.cameraPermission(this, request, true)
                    } else requestPermissions(arrayOf(Manifest.permission.CAMERA), CAMERA_PERMISSION)
                } else {
                    val manager = getSystemService(MediaProjectionManager::class.java)
                    startActivityForResult(manager.createScreenCaptureIntent(), PROJECTION_PERMISSION)
                }
            } catch (e: Exception) {
                WoiMediaCapture.failed(kind, request, "Android capture permission failed: ${e.message ?: e.javaClass.simpleName}")
            }
        }
    }

    override fun onSaveInstanceState(outState: Bundle) {
        outState.putBoolean("asked", asked)
        super.onSaveInstanceState(outState)
    }

    override fun onRequestPermissionsResult(code: Int, permissions: Array<out String>, results: IntArray) {
        super.onRequestPermissionsResult(code, permissions, results)
        if (code == CAMERA_PERMISSION) WoiMediaCapture.cameraPermission(this, request,
            results.isNotEmpty() && results.all { it == PackageManager.PERMISSION_GRANTED })
    }

    override fun onActivityResult(code: Int, result: Int, data: Intent?) {
        super.onActivityResult(code, result, data)
        if (code == PROJECTION_PERMISSION) WoiMediaCapture.projectionPermission(this, request, result, data)
    }

    override fun finish() {
        // Finishing only this host can leave Android's projection child on
        // screen (and its task reusable by a later capture request). Cancelling
        // our own started-for-result activity never accepts projection consent.
        if (kind == WoiMediaCapture.SCREEN) finishActivity(PROJECTION_PERMISSION)
        super.finish()
    }

    override fun onDestroy() {
        if (!isChangingConfigurations) WoiMediaCapture.abandoned(this, kind, request)
        super.onDestroy()
    }

    companion object {
        private const val CAMERA_PERMISSION = 7241
        private const val PROJECTION_PERMISSION = 7242
    }
}
