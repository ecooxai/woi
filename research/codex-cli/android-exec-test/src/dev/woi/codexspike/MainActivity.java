package dev.woi.codexspike;

import android.app.Activity;
import android.content.Intent;
import android.net.Uri;
import android.os.Bundle;
import android.util.Log;
import android.widget.TextView;

import java.io.*;
import java.net.*;
import java.nio.charset.StandardCharsets;
import java.util.*;
import java.util.concurrent.TimeUnit;
import java.util.regex.*;

/**
 * Throwaway spike: proves that an app can exec the bundled codex binary from
 * nativeLibraryDir, run `codex login` with the right env, capture the auth URL, and that a
 * Custom Tab redirect to http://127.0.0.1:1455/auth/callback reaches codex inside the app.
 * Everything is logged to logcat tag "CodexSpike". Tokens are never logged; state and
 * code_challenge are redacted.
 */
public class MainActivity extends Activity {
    static final String TAG = "CodexSpike";
    // Matches the line codex prints on stderr (see CODEX_CLI.md).
    static final Pattern AUTH_URL = Pattern.compile("(https://auth\\.openai\\.com/oauth/authorize\\?\\S+)");
    static final Pattern ANSI = Pattern.compile("\u001B\\[[0-9;]*m");
    TextView tv;
    final StringBuilder shown = new StringBuilder();

    void log(String s) {
        Log.i(TAG, s);
        runOnUiThread(() -> { shown.append(s).append('\n'); tv.setText(shown); });
    }

    static String redact(String s) {
        return s.replaceAll("(state|code_challenge|code)=[^&\\s]+", "$1=<R>")
                .replaceAll("[A-Z0-9]{4}-[A-Z0-9]{4,5}", "<CODE>");
    }

    @Override protected void onCreate(Bundle b) {
        super.onCreate(b);
        tv = new TextView(this);
        tv.setTextIsSelectable(true);
        setContentView(tv);
        new Thread(this::run, "spike").start();
    }

    File codexHome, home, tmp, certs;
    int proxyPort;

    Map<String, String> env(ProcessBuilder pb) {
        Map<String, String> e = pb.environment();
        e.put("HOME", home.getPath());
        e.put("TMPDIR", tmp.getPath());
        e.put("CODEX_HOME", codexHome.getPath());
        e.put("SSL_CERT_FILE", certs.getPath());
        e.put("HTTPS_PROXY", "http://127.0.0.1:" + proxyPort);
        e.put("BROWSER", "true"); // /system/bin/true: codex must not try to open a browser itself
        e.put("NO_COLOR", "1");
        return e;
    }

    String exe() { return new File(getApplicationInfo().nativeLibraryDir, "libcodex.so").getPath(); }

    /** Runs a command to completion (or timeout), returns combined output. */
    String runCmd(long timeoutSec, String... args) throws Exception {
        ProcessBuilder pb = new ProcessBuilder(args).redirectErrorStream(true);
        env(pb);
        Process p = pb.start();
        p.getOutputStream().close();
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        Thread t = new Thread(() -> { try { p.getInputStream().transferTo(out); } catch (IOException ignored) {} });
        t.start();
        boolean done = p.waitFor(timeoutSec, TimeUnit.SECONDS);
        if (!done) p.destroy();
        t.join(2000);
        return "rc=" + (done ? p.exitValue() : "timeout") + " out=" + redact(ANSI.matcher(out.toString("UTF-8")).replaceAll("")).trim();
    }

    void run() {
        try {
            String nld = getApplicationInfo().nativeLibraryDir;
            File so = new File(exe());
            log("nativeLibraryDir=" + nld);
            log("libcodex.so exists=" + so.exists() + " size=" + so.length() + " canExecute=" + so.canExecute());
            codexHome = new File(getFilesDir(), "codex"); codexHome.mkdirs();
            home = new File(getFilesDir(), "home"); home.mkdirs();
            tmp = getCacheDir();
            certs = new File(getFilesDir(), "cacerts.pem");
            buildCertBundle(certs);
            proxyPort = startConnectProxy();
            log("CONNECT proxy on 127.0.0.1:" + proxyPort);

            long t0 = System.nanoTime();
            log("[version] " + runCmd(30, exe(), "--version") + " (" + (System.nanoTime() - t0) / 1000000 + " ms)");
            log("[status] " + runCmd(30, exe(), "login", "status"));

            // W^X check: the same binary copied into app data must NOT be executable.
            File copy = new File(getFilesDir(), "codex-copy");
            try (InputStream in = new FileInputStream(so); OutputStream o = new FileOutputStream(copy)) { in.transferTo(o); }
            copy.setExecutable(true);
            try { log("[exec from filesDir] " + runCmd(10, copy.getPath(), "--version")); }
            catch (Exception e) { log("[exec from filesDir] FAILED as expected: " + e.getMessage()); }
            copy.delete();

            browserLogin();
            deviceAuthProbe();
            log("DONE");
        } catch (Throwable e) {
            log("ERROR " + Log.getStackTraceString(e));
        }
    }

    void browserLogin() throws Exception {
        ProcessBuilder pb = new ProcessBuilder(exe(), "login");
        env(pb);
        Process p = pb.start();
        p.getOutputStream().close();
        BufferedReader err = new BufferedReader(new InputStreamReader(p.getErrorStream(), StandardCharsets.UTF_8));
        String url = null, line;
        long t0 = System.nanoTime();
        while ((line = err.readLine()) != null) {
            log("[login stderr] " + redact(line));
            Matcher m = AUTH_URL.matcher(line);
            if (m.find()) { url = m.group(1); break; }
        }
        log("[login] url captured=" + (url != null) + " after " + (System.nanoTime() - t0) / 1000000 + " ms");
        log("[login] port 1455 reachable from app: " + httpGet("http://127.0.0.1:1455/"));
        final BufferedReader errF = err;
        Thread drain = new Thread(() -> { try { String l; while ((l = errF.readLine()) != null) log("[login stderr] " + redact(l)); } catch (IOException ignored) {} });
        drain.start();

        boolean real = getIntent().getBooleanExtra("realauth", false);
        // Default: send the browser straight to the callback with a bogus state. codex answers
        // 400 "State mismatch" and logs the hit, which proves browser -> 127.0.0.1:1455 -> app process.
        String target = real ? url : "http://127.0.0.1:1455/auth/callback?code=spike&state=spike";
        log("[login] opening Custom Tab: " + redact(target));
        runOnUiThread(() -> openCustomTab(Uri.parse(target)));
        File logf = new File(codexHome, "log/codex-login.log");
        boolean hit = false;
        for (int i = 0; i < (real ? 600 : 30) && !hit; i++) {
            Thread.sleep(1000);
            if (!p.isAlive()) break;
            hit = !real && readFile(logf).contains("received login callback");
        }
        log("[login] callback seen in codex-login.log=" + hit);
        for (String l : readFile(logf).split("\n")) if (l.contains("callback")) log("[codex-login.log] " + redact(l));
        if (p.isAlive()) log("[login] cancel -> " + httpGet("http://127.0.0.1:1455/cancel"));
        boolean exited = p.waitFor(10, TimeUnit.SECONDS);
        log("[login] exited=" + exited + " rc=" + (exited ? p.exitValue() : -1)
                + " auth.json exists=" + new File(codexHome, "auth.json").exists());
        drain.join(1000);
        startActivity(new Intent(this, MainActivity.class).addFlags(Intent.FLAG_ACTIVITY_REORDER_TO_FRONT));
    }

    void deviceAuthProbe() throws Exception {
        // Network check through proxy + cert bundle: device-auth fetches a user code from auth.openai.com.
        String r = runCmd(8, exe(), "login", "--device-auth");
        log("[device-auth] got code page=" + r.contains("auth.openai.com/codex/device") + " " + (r.length() > 300 ? r.substring(0, 300) : r));
    }

    void openCustomTab(Uri uri) {
        Intent i = new Intent(Intent.ACTION_VIEW, uri);
        Bundle extras = new Bundle();
        extras.putBinder("android.support.customtabs.extra.SESSION", null); // marks it as a Custom Tab
        i.putExtras(extras);
        startActivity(i);
    }

    void buildCertBundle(File out) throws IOException {
        File dir = new File("/apex/com.android.conscrypt/cacerts");
        if (!dir.isDirectory()) dir = new File("/system/etc/security/cacerts");
        File[] fs = dir.listFiles();
        int n = 0;
        try (OutputStream o = new FileOutputStream(out)) {
            if (fs != null) for (File f : fs) {
                try (InputStream in = new FileInputStream(f)) { in.transferTo(o); o.write('\n'); n++; }
            }
        }
        log("cert bundle from " + dir + ": " + n + " files, " + out.length() + " bytes");
    }

    int startConnectProxy() throws IOException {
        ServerSocket ss = new ServerSocket(0, 50, InetAddress.getByName("127.0.0.1"));
        new Thread(() -> {
            while (true) {
                try { Socket c = ss.accept(); new Thread(() -> proxyConn(c)).start(); }
                catch (IOException e) { return; }
            }
        }, "proxy").start();
        return ss.getLocalPort();
    }

    void proxyConn(Socket c) {
        try {
            InputStream in = c.getInputStream();
            StringBuilder head = new StringBuilder();
            int ch;
            while ((ch = in.read()) != -1) { head.append((char) ch); if (head.toString().endsWith("\r\n\r\n")) break; }
            String[] parts = head.toString().split("\\s+");
            if (parts.length < 2 || !parts[0].equals("CONNECT")) { c.close(); return; }
            int idx = parts[1].lastIndexOf(':');
            String host = parts[1].substring(0, idx);
            int port = Integer.parseInt(parts[1].substring(idx + 1));
            log("[proxy] CONNECT " + host + ":" + port);
            Socket s = new Socket(host, port); // Android resolver (works under the app's network policy)
            c.getOutputStream().write("HTTP/1.1 200 Connection Established\r\n\r\n".getBytes(StandardCharsets.US_ASCII));
            Thread up = new Thread(() -> pump(c, s));
            up.start();
            pump(s, c);
        } catch (Exception e) {
            log("[proxy] error " + e);
            try { c.close(); } catch (IOException ignored) {}
        }
    }

    static void pump(Socket a, Socket b) {
        try { a.getInputStream().transferTo(b.getOutputStream()); } catch (IOException ignored) {}
        try { b.shutdownOutput(); } catch (IOException ignored) {}
    }

    static String httpGet(String u) {
        try {
            HttpURLConnection c = (HttpURLConnection) new URL(u).openConnection();
            c.setConnectTimeout(3000); c.setReadTimeout(3000);
            int code = c.getResponseCode();
            InputStream s = code >= 400 ? c.getErrorStream() : c.getInputStream();
            String body = s == null ? "" : new String(s.readAllBytes(), StandardCharsets.UTF_8);
            return code + " " + body.trim();
        } catch (Exception e) { return "ERR " + e; }
    }

    static String readFile(File f) {
        try (InputStream in = new FileInputStream(f)) { return new String(in.readAllBytes(), StandardCharsets.UTF_8); }
        catch (IOException e) { return ""; }
    }
}
