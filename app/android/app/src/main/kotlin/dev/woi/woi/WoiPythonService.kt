package dev.woi.woi

import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.Message
import android.os.Messenger
import android.os.Process
import android.system.ErrnoException
import android.system.Os
import android.system.OsConstants
import com.chaquo.python.Python
import com.chaquo.python.android.AndroidPlatform
import org.json.JSONObject
import java.io.File
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

internal data class WoiPythonIdentity(val pid: Int, val group: Int, val startTicks: Long)

/** Linux process groups cover ordinary inheriting children, not code which
 * deliberately escapes into another session. Never signal the app's group. */
internal object WoiPythonProcess {
    fun identity(pid: Int): WoiPythonIdentity? = try {
        val fields = File("/proc/$pid/stat").readText().substringAfterLast(")").trim().split(Regex("\\s+"))
        WoiPythonIdentity(pid, fields[2].toInt(), fields[19].toLong())
    } catch (_: Exception) { null }

    private fun isWorker(context: Context, pid: Int): Boolean = try {
        val uid = File("/proc/$pid/status").useLines { lines ->
            lines.first { it.startsWith("Uid:") }.trim().split(Regex("\\s+"))[1].toInt()
        }
        File("/proc/$pid/cmdline").readText().substringBefore('\u0000') == "${context.packageName}:woi_python" &&
            uid == Process.myUid()
    } catch (_: Exception) { false }

    fun establish(context: Context): Int {
        val pid = Process.myPid()
        check(isWorker(context, pid)) { "Python must run in its dedicated service process" }
        // Os.setpgid/getpgid are not public Android APIs. setsid creates a
        // private session/group when this worker is not already a group leader.
        if (identity(pid)?.group != pid) Os.setsid()
        check(identity(pid)?.group == pid) { "Unable to create Python's private process group" }
        return pid
    }

    fun verify(context: Context, pid: Int, group: Int, startTicks: Long,
               senderUid: Int, processName: String?): WoiPythonIdentity? {
        if (senderUid != Process.myUid() || processName != "${context.packageName}:woi_python") return null
        if (pid <= 1 || pid == Process.myPid() || group != pid || startTicks <= 0) return null
        val app = identity(Process.myPid()) ?: return null
        if (group == app.group) return null
        // Android may hide a sibling process's /proc files even with the same
        // UID. READY comes from the explicitly bound, non-exported service;
        // Messenger authenticates sendingUid, and that service checked its own
        // name/UID/private group before any user source can receive START.
        val observed = identity(pid)
        if (observed != null && (observed.group != group || observed.startTicks != startTicks)) return null
        return WoiPythonIdentity(pid, group, startTicks)
    }

    fun killOwned(worker: WoiPythonIdentity): Boolean {
        if (worker.pid <= 1 || worker.pid == Process.myPid()) return false
        val current = identity(worker.pid)
        // Where proc is readable, reject PID reuse. Ownership was recorded via
        // authenticated READY before START. If its leader exits, an occupied
        // process group keeps its ID while the inheriting children live.
        if (current != null && current.startTicks != worker.startTicks) return false
        val app = identity(Process.myPid())
        if (app != null && worker.group == worker.pid && worker.group != app.group &&
            (current == null || current.group == worker.group)) {
            try {
                Os.kill(-worker.group, OsConstants.SIGKILL)
                return true
            } catch (error: ErrnoException) {
                if (error.errno == OsConstants.ESRCH) return true
            }
        }
        // If group identity changed, only this verified worker PID is safe.
        if (current != null) Process.killProcess(worker.pid)
        return false
    }

    fun stopService(context: Context, ownGroup: Int) {
        val pid = Process.myPid()
        if (!isWorker(context, pid)) return
        if (ownGroup == pid && identity(pid)?.group == pid) {
            try { Os.kill(-pid, OsConstants.SIGKILL); return } catch (_: ErrnoException) {}
        }
        Process.killProcess(pid)
    }
}

/**
 * CPython never runs inside the voice/UI process. The caller owns this
 * short-lived worker and its private process group. Source runs only after
 * the owner verifies READY and acknowledges START.
 */
class WoiPythonService : Service() {
    companion object {
        const val RUN = 1
        const val READY = 2
        const val DONE = 3
        const val STOP = 4
        const val START = 5
    }

    private data class Request(val reply: Messenger, val jobId: String, val code: String, val cwd: String, val limit: Int)
    private val busy = AtomicBoolean(false)
    private val worker = Executors.newSingleThreadExecutor()
    private var ownGroup = 0
    private var pending: Request? = null
    private val channel = Messenger(Handler(Looper.getMainLooper()) { message ->
        when (message.what) {
            STOP -> if (message.sendingUid == Process.myUid()) WoiPythonProcess.stopService(this, ownGroup)
            RUN -> prepare(message)
            START -> start(message)
        }
        true
    })

    override fun onBind(intent: Intent): IBinder = channel.binder

    private fun prepare(message: Message) {
        val reply = message.replyTo ?: return
        if (!busy.compareAndSet(false, true)) {
            send(reply, JSONObject().put("exit_code", 75).put("stderr", "Python worker is busy").toString())
            return
        }
        try {
            check(message.sendingUid == Process.myUid()) { "Python caller UID does not match" }
            val jobId = message.data.getString("job_id") ?: ""
            check(jobId.length in 1..64) { "Python job identity is missing" }
            val code = message.data.getString("code") ?: ""
            check(code.isNotBlank() && code.length <= 65536) { "Python code must contain 1 to 65536 characters" }
            ownGroup = WoiPythonProcess.establish(this)
            pending = Request(reply, jobId, code,
                message.data.getString("cwd") ?: filesDir.absolutePath,
                message.data.getInt("max_output_chars", 8000).coerceIn(256, 16000))
            val self = checkNotNull(WoiPythonProcess.identity(Process.myPid()))
            reply.send(Message.obtain(null, READY, Process.myPid(), ownGroup).apply {
                data = Bundle().apply {
                    putString("job_id", jobId)
                    putLong("start_ticks", self.startTicks)
                    putString("process_name", "${packageName}:woi_python")
                }
            })
        } catch (error: Exception) {
            send(reply, JSONObject().put("exit_code", 1)
                .put("stderr", error.message ?: "Python worker setup failed").toString())
        }
    }

    private fun start(message: Message) {
        val request = pending ?: return
        if (message.sendingUid != Process.myUid() || message.data.getString("job_id") != request.jobId) {
            send(request.reply, JSONObject().put("exit_code", 1)
                .put("stderr", "Python START identity did not match READY").toString())
            return
        }
        pending = null
        execute(request)
    }

    private fun execute(request: Request) {
        worker.execute {
            val json = try {
                if (!Python.isStarted()) Python.start(AndroidPlatform(this))
                Python.getInstance().getModule("woi_python")
                    .callAttr("run", request.code, request.cwd, request.limit).toString()
            } catch (error: Throwable) {
                JSONObject().put("exit_code", 1)
                    .put("stderr", error.message ?: error.javaClass.simpleName).toString()
            }
            send(request.reply, json)
        }
    }

    private fun send(reply: Messenger, json: String) {
        try {
            reply.send(Message.obtain(null, DONE).apply {
                data = Bundle().apply { putString("json", json) }
            })
        } catch (_: Exception) {
            WoiPythonProcess.stopService(this, ownGroup)
        }
    }

    override fun onDestroy() {
        pending = null
        worker.shutdownNow()
        super.onDestroy()
        WoiPythonProcess.stopService(this, ownGroup)
    }
}
