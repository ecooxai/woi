package dev.woi.woi

import android.app.Activity
import android.app.Instrumentation
import android.content.Intent
import android.os.Bundle
import android.os.Process
import android.os.SystemClock
import android.system.ErrnoException
import android.system.Os
import android.system.OsConstants
import java.io.File
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/** Installed only in the Android test APK; exercises the real CPython service. */
class PythonInstrumentation : Instrumentation() {
    private var group: String? = null
    override fun onCreate(arguments: Bundle?) {
        super.onCreate(arguments)
        group = arguments?.getString("group")
        start()
    }

    // Keep the target UID/projection token, but never start Flutter or a chat
    // connection during the native audio checks. This is test-APK code only.
    override fun newActivity(cl: ClassLoader, className: String, intent: Intent): Activity {
        if (group == "audio" && className == "dev.woi.woi.MainActivity") {
            return HeldAudioTestActivity()
        }
        return super.newActivity(cl, className, intent)
    }

    private fun execute(code: String, timeoutMs: Long = 15000): Map<String, Any?> {
        val done = CountDownLatch(1)
        var value: Map<String, Any?>? = null
        var error: String? = null
        runOnMainSync {
            WoiPython.run(targetContext, MethodCall("pythonRun", mapOf(
                "code" to code,
                "cwd" to targetContext.filesDir.absolutePath,
                "timeout_ms" to timeoutMs,
                "max_output_chars" to 8000,
            )), object : MethodChannel.Result {
                override fun success(result: Any?) {
                    @Suppress("UNCHECKED_CAST")
                    value = result as? Map<String, Any?>
                    done.countDown()
                }
                override fun error(code: String, message: String?, details: Any?) {
                    error = "$code: $message"
                    done.countDown()
                }
                override fun notImplemented() {
                    error = "Python method is not implemented"
                    done.countDown()
                }
            })
        }
        check(done.await(timeoutMs + 10000, TimeUnit.MILLISECONDS)) { "Python callback did not complete" }
        check(error == null) { error ?: "unknown Python error" }
        return checkNotNull(value)
    }

    private fun processState(pid: Int): Triple<String, Int, Long>? = try {
        val fields = File("/proc/$pid/stat").readText().substringAfterLast(")").trim().split(Regex("\\s+"))
        Triple(fields[0], fields[2].toInt(), fields[19].toLong())
    } catch (_: java.io.FileNotFoundException) { null }

    private fun processExists(pid: Int): Boolean = try {
        Os.kill(pid, 0)
        true
    } catch (error: ErrnoException) {
        if (error.errno == OsConstants.ESRCH) false else throw error
    }

    override fun onStart() {
        if (group == "audio") {
            HeldAudioDeviceCheck(this).run()
            return
        }
        if (group == "control") {
            ControlOverlayDeviceCheck(this).run()
            return
        }
        val log = StringBuilder()
        var passed = 0
        fun verify(name: String, body: () -> Unit) {
            body()
            passed++
            log.append("PASS ").append(name).append('\n')
        }
        try {
            verify("real arithmetic") {
                val result = execute("from decimal import Decimal\nprint(137 * 281)\nprint(Decimal('0.1') + Decimal('0.2'))")
                check(result["exit_code"] == 0) { result.toString() }
                check(result["stdout"] == "38497\n0.3\n") { result.toString() }
            }
            verify("worker owns a private process group") {
                val result = execute("import os\nprint(os.getpid(), os.getpgrp())")
                val ids = result["stdout"].toString().trim().split(Regex("\\s+")).map { it.toInt() }
                check(ids.size == 2 && ids[0] == ids[1] && ids[0] != Process.myPid()) { result.toString() }
                check(processState(Process.myPid())?.second != ids[1])
            }
            verify("binary and native descriptor output") {
                val result = execute("""
                    import os, sys
                    sys.stdout.buffer.write(b'binary-out\n')
                    os.write(1, b'native-out\n')
                    sys.stderr.buffer.write(b'binary-err\n')
                    os.write(2, b'native-err\n')
                """.trimIndent())
                check(result["exit_code"] == 0) { result.toString() }
                check(result["stdout"] == "binary-out\nnative-out\n") { result.toString() }
                check(result["stderr"] == "binary-err\nnative-err\n") { result.toString() }
            }
            verify("subprocess output is returned") {
                val result = execute("""
                    import subprocess
                    subprocess.run(['/system/bin/sh', '-c', 'printf child-out; printf child-err >&2'], check=True)
                """.trimIndent())
                check(result["exit_code"] == 0) { result.toString() }
                check(result["stdout"] == "child-out" && result["stderr"] == "child-err") { result.toString() }
            }
            verify("exceptions are returned") {
                val result = execute("raise ValueError('python-device-check')")
                check(result["exit_code"] == 1) { result.toString() }
                check(result["stderr"].toString().contains("python-device-check"))
            }
            verify("output is bounded") {
                val result = execute("print('HEAD' + 'x' * 100000 + 'TAIL')")
                check(result["truncated"] == true)
                check(result["stdout"].toString().length < 8200)
                check(result["stdout"].toString().endsWith("TAIL\n"))
            }
            verify("hard timeout") {
                val result = execute("while True: pass", 1500)
                check(result["timed_out"] == true) { result.toString() }
                check((result["ms"] as Number).toLong() < 5000)
            }
            verify("timeout reaps an inheriting sleeping child") {
                val pidFile = File(targetContext.filesDir, "python-child-${System.nanoTime()}.pid")
                var childPid = 0
                var childGroup = 0
                try {
                    val result = execute("""
                        import os, subprocess, time
                        child = subprocess.Popen(['/system/bin/sh', '-c', 'sleep 30'])
                        assert os.getpgid(child.pid) == os.getpgrp()
                        with open('${pidFile.name}', 'w') as record:
                            record.write(str(child.pid) + ' ' + str(os.getpgrp()))
                        while True:
                            time.sleep(1)
                    """.trimIndent(), 5000)
                    check(result["timed_out"] == true) { result.toString() }
                    check(pidFile.isFile) { "The child did not start before the timeout" }
                    val ids = pidFile.readText().trim().split(Regex("\\s+")).map { it.toLong() }
                    childPid = ids[0].toInt()
                    childGroup = ids[1].toInt()
                    check(childPid > 1 && childPid != Process.myPid())
                    check(childGroup > 1 && childGroup != processState(Process.myPid())?.second)
                    // Unlike sibling /proc files, signal 0 is available for a
                    // same-UID child. ESRCH proves it was reaped, not just hidden.
                    val until = SystemClock.elapsedRealtime() + 3000
                    while (processExists(childPid) && SystemClock.elapsedRealtime() < until) Thread.sleep(25)
                    check(!processExists(childPid)) { "Python's sleeping child survived the timeout" }
                    val next = execute("print('child cleanup ok')")
                    check(next["stdout"] == "child cleanup ok\n") { next.toString() }
                } finally {
                    val appGroup = processState(Process.myPid())?.second
                    if (childPid > 1 && childPid != Process.myPid() && childGroup > 1 &&
                        appGroup != null && childGroup != appGroup && childGroup != Process.myPid()) {
                        try { if (processExists(childPid)) Os.kill(-childGroup, OsConstants.SIGKILL) } catch (_: ErrnoException) {}
                    }
                    pidFile.delete()
                }
            }
            verify("recovery after timeout") {
                val result = execute("print(6 * 7)")
                check(result["exit_code"] == 0 && result["stdout"] == "42\n") { result.toString() }
            }
            verify("worker crash leaves app alive") {
                val crashed = execute("import os\nos._exit(3)")
                check(crashed["exit_code"] != 0)
                val next = execute("print('alive')")
                check(next["stdout"] == "alive\n") { next.toString() }
            }
            finish(Activity.RESULT_OK, Bundle().apply {
                putString("stream", "\n$log\n$passed Python device checks passed.\n")
                putInt("passed", passed)
            })
        } catch (error: Throwable) {
            finish(Activity.RESULT_CANCELED, Bundle().apply {
                putString("stream", "\n$log\nFAILED: ${error.stackTraceToString()}\n")
                putInt("passed", passed)
                putString("failure", error.toString())
            })
        }
    }
}
