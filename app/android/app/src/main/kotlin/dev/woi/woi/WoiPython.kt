package dev.woi.woi

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.os.Bundle
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.Message
import android.os.Messenger
import android.os.SystemClock
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import java.util.UUID

/** Method-channel owner for one disposable Python worker at a time. */
object WoiPython {
    private val main = Handler(Looper.getMainLooper())
    private var active = false

    fun run(context: Context, call: MethodCall, result: MethodChannel.Result) {
        if (active) {
            result.success(mapOf("exit_code" to 75, "stderr" to "Python is busy; wait for the current call"))
            return
        }
        val code = call.argument<String>("code") ?: ""
        if (code.isBlank() || code.length > 65536) {
            result.error("python_arguments", "Python code must contain 1 to 65536 characters", null)
            return
        }
        active = true
        val owner = context.applicationContext
        val intent = Intent(owner, WoiPythonService::class.java)
        val jobId = UUID.randomUUID().toString()
        val started = SystemClock.elapsedRealtime()
        val timeoutMs = (call.argument<Number>("timeout_ms")?.toLong() ?: 30000).coerceIn(100, 300000)
        var remote: Messenger? = null
        var ownedWorker: WoiPythonIdentity? = null
        var cleanupSent = false
        var bound = false
        var completed = false
        var pending: Map<String, Any?>? = null
        lateinit var connection: ServiceConnection
        lateinit var deadline: Runnable
        lateinit var reapFallback: Runnable

        fun cleanWorker(): Boolean? {
            if (cleanupSent) return true
            val worker = ownedWorker ?: return null
            cleanupSent = true
            return WoiPythonProcess.killOwned(worker)
        }

        fun finish(payload: Map<String, Any?>) {
            if (completed) return
            completed = true
            // Also reap children when source called os._exit and Binder died first.
            cleanWorker()
            main.removeCallbacks(deadline)
            main.removeCallbacks(reapFallback)
            if (bound) {
                try { owner.unbindService(connection) } catch (_: Exception) {}
                bound = false
            }
            active = false
            result.success(payload + ("ms" to (SystemClock.elapsedRealtime() - started)))
        }

        fun reap(payload: Map<String, Any?>) {
            if (completed || pending != null) return
            pending = payload
            val cleaned = cleanWorker()
            if (cleaned != true) {
                if (cleaned == false) {
                    pending = payload + mapOf("exit_code" to 1, "stderr" to
                        "${payload["stderr"] ?: ""}\nPython worker's private process group could not be verified for cleanup".trim())
                }
                try { remote?.send(Message.obtain(null, WoiPythonService.STOP)) } catch (_: Exception) {}
                owner.stopService(intent)
            }
            // Binder death usually completes immediately; keep an upper
            // bound if the service never reached its READY handshake.
            main.postDelayed(reapFallback, 500)
        }

        deadline = Runnable {
            reap(mapOf("exit_code" to -9, "timed_out" to true, "stderr" to "Python exceeded its time limit"))
        }
        reapFallback = Runnable {
            finish(pending ?: mapOf("exit_code" to 1, "stderr" to "Python worker did not respond"))
        }
        val replies = Messenger(Handler(Looper.getMainLooper()) { message ->
            if (!completed) {
                when (message.what) {
                    WoiPythonService.READY -> {
                        val connected = try { remote?.binder?.pingBinder() == true } catch (_: Exception) { false }
                        val identity = if (connected && message.data.getString("job_id") == jobId) WoiPythonProcess.verify(owner, message.arg1, message.arg2,
                            message.data.getLong("start_ticks"), message.sendingUid,
                            message.data.getString("process_name")) else null
                        if (identity == null) {
                            reap(mapOf("exit_code" to 1, "stderr" to "Python worker handshake could not be verified"))
                        } else {
                            ownedWorker = identity
                            if (pending != null) {
                                // A deadline may expire during service startup.
                                cleanWorker()
                            } else {
                                try { remote?.send(Message.obtain(null, WoiPythonService.START).apply {
                                    data = Bundle().apply { putString("job_id", jobId) }
                                }) } catch (error: Exception) {
                                    reap(mapOf("exit_code" to 1, "stderr" to "Unable to start Python: ${error.message}"))
                                }
                            }
                        }
                    }
                    WoiPythonService.DONE -> {
                        try {
                            val json = JSONObject(message.data.getString("json") ?: "{}")
                            val payload = mutableMapOf<String, Any?>()
                            for (key in json.keys()) payload[key] = json.opt(key).takeUnless { it == JSONObject.NULL }
                            reap(payload)
                        } catch (error: Exception) {
                            reap(mapOf("exit_code" to 1, "stderr" to "Invalid Python worker result: ${error.message}"))
                        }
                    }
                }
            }
            true
        })
        connection = object : ServiceConnection {
            override fun onServiceConnected(name: ComponentName, service: IBinder) {
                if (completed) return
                remote = Messenger(service)
                if (pending != null) {
                    try { remote?.send(Message.obtain(null, WoiPythonService.STOP)) } catch (_: Exception) {}
                    return
                }
                try {
                    remote!!.send(Message.obtain(null, WoiPythonService.RUN).apply {
                        replyTo = replies
                        data = Bundle().apply {
                            putString("job_id", jobId)
                            putString("code", code)
                            putString("cwd", call.argument<String>("cwd") ?: owner.filesDir.absolutePath)
                            putInt("max_output_chars", (call.argument<Number>("max_output_chars")?.toInt() ?: 8000).coerceIn(256, 16000))
                        }
                    })
                } catch (error: Exception) {
                    reap(mapOf("exit_code" to 1, "stderr" to "Unable to start Python: ${error.message}"))
                }
            }

            override fun onServiceDisconnected(name: ComponentName) {
                finish(pending ?: mapOf("exit_code" to 1, "stderr" to "Python worker exited unexpectedly"))
            }

            override fun onBindingDied(name: ComponentName) {
                finish(pending ?: mapOf("exit_code" to 1, "stderr" to "Python worker binding ended"))
            }

            override fun onNullBinding(name: ComponentName) {
                finish(mapOf("exit_code" to 1, "stderr" to "Python worker could not start"))
            }
        }
        main.postDelayed(deadline, timeoutMs)
        try {
            bound = owner.bindService(intent, connection, Context.BIND_AUTO_CREATE)
            if (!bound) finish(mapOf("exit_code" to 1, "stderr" to "Python service is unavailable"))
        } catch (error: Exception) {
            finish(mapOf("exit_code" to 1, "stderr" to (error.message ?: "Python service failed")))
        }
    }
}
