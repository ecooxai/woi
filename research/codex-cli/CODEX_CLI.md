# Bundling the Codex CLI and driving `codex login` (Linux x64 + Android arm64)

Verified 2026-11-03 with codex-cli **0.166.0** on Linux x64 (CachyOS) and on the Xiaomi MI 8 (LineageOS,
Android 15 / SDK 35, arm64-v8a, kernel 4.9, adb 2d4f6bc0), from adb shell **and** from inside a throwaway APK.
No real login was completed; everything was verified up to "URL captured, callback server listening,
browser redirect reaches it". Lines marked **UNVERIFIED** come from strings in the binary or from reasoning.

| File | Purpose |
|---|---|
| `fetch_codex.sh` | downloads the pinned npm tarballs, checks the npm sha512 integrity, unpacks to `bin/{x64,arm64}/` (gitignored) |
| `connect_proxy.py` | minimal HTTP CONNECT proxy (the DNS workaround for Android; see 3.2) for adb testing |
| `android-exec-test/` | throwaway APK (no Gradle: aapt2/javac/d8) that execs `libcodex.so` from nativeLibraryDir, runs the login, opens a Custom Tab. `build.sh` → `out/` (gitignored) |

---

## 1. Binaries

| | x64 | arm64 |
|---|---|---|
| npm spec | `@openai/codex@0.166.0-linux-x64` | `@openai/codex@0.166.0-linux-arm64` |
| tarball | 164 MB | 157 MB |
| path in tarball | `package/vendor/x86_64-unknown-linux-musl/bin/codex` | `package/vendor/aarch64-unknown-linux-musl/bin/codex` |
| `codex` | 319,346,888 B, `static-pie linked, stripped` | 277,549,176 B, `statically linked, stripped` |
| `codex-path/rg` | 5.4 MB, static-pie | 4.5 MB, **dynamically linked against glibc** (`/lib/ld-linux-aarch64.so.1`): does **not** run on Android ("No such file or directory") |
| other | `codex-code-mode-host` (78 MB), `codex-resources/bwrap`, `codex-resources/voice/` (gstreamer voice host, 40 MB) | same (71 MB, bwrap, voice host 42 MB) |

* The installed x64 binary: `/home/a/.config/nvm/versions/node/v22.22.2/lib/node_modules/@openai/codex/node_modules/@openai/codex-linux-x64/vendor/x86_64-unknown-linux-musl/bin/codex`
  (byte-identical to the tarball). `bin/codex.js` only `execve`s it and sets `CODEX_MANAGED_BY_NPM=1` and
  `CODEX_MANAGED_PACKAGE_ROOT`; the app should exec the native binary directly and **not** set those (they only
  affect update hints).
* `vendor/<triple>/codex-package.json` describes the layout (`entrypoint bin/codex`, `pathDir codex-path`,
  `resourcesDir codex-resources`). **For login and auth only `codex` is needed.** `rg` is for the agent's file
  search, bwrap is the Linux sandbox, voice-host is Codex voice mode. None of them are needed by Woi.
* On Android the APK grows by **~113 MB** (lib deflated in the APK) and the install takes **~390 MB** (APK +
  extracted 265 MiB `.so`). That's a lot for "just login"; see the 6.3 plan B.

## 2. Linux recipe (verified)

```sh
mkdir -p "$CODEX_HOME"                     # MUST exist: codex errors "CODEX_HOME points to ..., but that path does not exist"
env CODEX_HOME="$CODEX_HOME" BROWSER=true \
    codex -c 'cli_auth_credentials_store="file"' login </dev/null
```
* No proxy or certs needed on Linux: codex finds `/etc/ssl/certs/ca-certificates.crt` and friends itself.
* Default for the app on Linux: `CODEX_HOME=~/.codex` (reuse an existing login). Experiments: always a temp dir.
* Avoid `CODEX_HOME` under `$TMPDIR` (e.g. both in `/tmp`): harmless but noisy stderr
  `WARNING: proceeding, even though we could not create PATH aliases: Refusing to create helper binaries under temporary dir ...`.

## 3. Android recipe (verified on the MI 8)

### 3.1 Packaging and exec (W^X)
* Ship as `android/app/src/main/jniLibs/arm64-v8a/libcodex.so`, and in `android/app/build.gradle.kts`:
  `android { packaging { jniLibs { useLegacyPackaging = true } } }` (equivalent to manifest
  `android:extractNativeLibs="true"`). The installer extracts it to
  `applicationInfo.nativeLibraryDir` (`/data/app/~~…/<pkg>-…/lib/arm64/libcodex.so`, mode r-x).
* **Verified in the APK (targetSdk 35):** `ProcessBuilder(nativeLibraryDir + "/libcodex.so", "--version")` → `codex-cli 0.166.0`, rc 0, 102 ms.
  The same file copied to `filesDir` and chmod +x → `error=13, Permission denied` (W^X / SELinux `app_data_file`
  is not executable for targetSdk ≥ 29). So nativeLibraryDir is the only way.
* Flutter has no API for nativeLibraryDir: add a MethodChannel in `MainActivity.kt` that returns
  `applicationInfo.nativeLibraryDir`, then `Process.start(path, args, environment: …)` from Dart.
* Restrict ABIs to arm64-v8a (`ndk { abiFilters += "arm64-v8a" }`) or `--split-per-abi`, otherwise the
  same 113 MB counts per ABI if you add x86_64 later.

### 3.2 DNS: no /etc/resolv.conf on Android → use a localhost CONNECT proxy
The static musl binary resolves names through `/etc/resolv.conf`, which doesn't exist on Android (and `/etc` is
read-only). musl then falls back to `127.0.0.1:53` and **every request fails** with
`Error logging in: error sending request for url (https://auth.openai.com/api/accounts/deviceauth/usercode)`.
Verified fix: run an HTTP CONNECT proxy on `127.0.0.1:<random port>` inside the app (Dart:
`ServerSocket.bind('127.0.0.1', 0)`, read `CONNECT host:port`, `Socket.connect(host, port)` through the
Android resolver, reply `HTTP/1.1 200 Connection Established`, pipe both ways) and pass
`HTTPS_PROXY=http://127.0.0.1:<port>`. TLS stays end-to-end. Verified: `HTTPS_PROXY`, `https_proxy` and
`ALL_PROXY` all work. The browser OAuth flow needs this too: after the callback, codex POSTs the code to
`https://auth.openai.com/oauth/token`.

### 3.3 TLS roots: pass a PEM bundle
codex (rustls + native roots) looks only at Linux paths (`/etc/ssl/certs/ca-certificates.crt`, `/etc/pki/...`).
None exist on Android → TLS fails even when the proxy works. Verified fix: concatenate the system CA files
into one PEM file in app storage and set `SSL_CERT_FILE` (or `CODEX_CA_CERTIFICATE`; both verified):
* the source dir is `/apex/com.android.conscrypt/cacerts` (Android 14+, updatable) or else
  `/system/etc/security/cacerts`. Both are world-readable, 145 files on the MI 8, each a plain PEM.
  `cat dir/* > cacerts.pem` (758 KB) works.
* `SSL_CERT_DIR=/system/etc/security/cacerts` does **not** work (tested).
* The bundle ignores user-installed CAs. That only matters behind a corporate MITM proxy.

### 3.4 Full env (used by the APK test, all verified)
```
HOME=<filesDir>/home                    # adb shell has HOME=/ (read-only) → harmless "could not create PATH aliases" warning
TMPDIR=<cacheDir>                       # must not contain CODEX_HOME (see §2)
CODEX_HOME=<filesDir>/codex             # mkdir first
SSL_CERT_FILE=<filesDir>/cacerts.pem    # §3.3
HTTPS_PROXY=http://127.0.0.1:<port>     # §3.2
BROWSER=true                            # /system/bin/true (toybox): codex must not try to open anything
args: libcodex.so -c cli_auth_credentials_store="file" login
stdin: closed / </dev/null
```
No TTY is needed. The browser login prints plain text (no ANSI). `--device-auth` prints ANSI colours even
without a TTY and ignores `NO_COLOR`/`TERM=dumb`, so strip `\x1b\[[0-9;]*m`.

### 3.5 Custom Tab → 127.0.0.1:1455 → codex inside the app (verified)
* The codex callback server binds **`127.0.0.1:1455` (IPv4 only, falls back to 1457; see §4.1)**; the redirect_uri is
  `http://127.0.0.1:1455/auth/callback` (the "localhost" in the banner is cosmetic).
* APK test: the app spawned `codex login`, captured the URL **21–30 ms** after spawn, then opened a Custom Tab
  (the default browser on the MI 8 is Brave → `org.chromium.chrome.browser.customtabs.CustomTabActivity`, same
  task) at `http://127.0.0.1:1455/auth/callback?code=x&state=x`. codex logged
  `codex_login::server: received login callback path=/auth/callback ... state_valid=false` and answered
  `400 State mismatch`. So browser (another UID) → loopback → codex in the app UID works. No Brave
  "HTTPS upgrade" interference for 127.0.0.1.
* Also opened the **real** auth URL in the Custom Tab and left the app in the background for 68 s: the app
  process was at `procState=15 (LAST_ACTIVITY), oom_adj 700`, and codex still answered a callback in 30 ms.
  **Caveat:** this phone has `use_freezer=false` (kernel 4.9). On modern devices the cached-app freezer
  freezes background apps (and their child processes) about 10 s after they become *cached*, e.g. if the user switches
  to a mail/2FA/password app during login. Then the callback hangs. **Mitigation (UNVERIFIED):** run a foreground
  service (e.g. type `shortService` or `specialUse`) while the login is pending. Same idea guards against LMK.
* Without androidx.browser, a Custom Tab is just `ACTION_VIEW` + extras Bundle with
  `putBinder("android.support.customtabs.extra.SESSION", null)`. In Flutter use `flutter_custom_tabs` or
  `url_launcher` (`LaunchMode.inAppBrowserView`).
* After success, codex's success page stays in the tab. Bring the app back with
  `startActivity(Intent(this, MainActivity::class.java).addFlags(FLAG_ACTIVITY_REORDER_TO_FRONT))` (verified,
  that's what the test does) or `CLEAR_TOP|SINGLE_TOP`.
* App-side HTTP to `http://127.0.0.1:1455` (e.g. `/cancel`) from Java `HttpURLConnection` needs
  `android:usesCleartextTraffic="true"` or a network-security-config allowing 127.0.0.1. With a raw Dart
  `Socket` you don't need it.

## 4. `codex login` output and behaviour (identical on Linux and Android)

### 4.1 Browser OAuth (default)
Everything goes to **stderr**. stdout stays empty. Exact output (state/code_challenge redacted):
```
Starting local login server on http://localhost:1455.
If your browser did not open, navigate to this URL to authenticate:

https://auth.openai.com/oauth/authorize?response_type=code&client_id=app_EMoamEEZ73f0CkXaXp7hrann&redirect_uri=http%3A%2F%2F127.0.0.1%3A1455%2Fauth%2Fcallback&code_challenge=<R>&code_challenge_method=S256&state=<R>&scope=openid+profile+email+offline_access+api.connectors.read+api.connectors.invoke&id_token_add_organizations=true&codex_cli_simplified_flow=true&originator=codex_cli_rs

On a remote or headless machine? Use `codex login --device-auth` instead.
```
(Possibly preceded by a `WARNING: proceeding, even though we could not create PATH aliases: ...` line.)

**URL capture regex** (match per stderr line):
```
^(https://auth\.openai\.com/oauth/authorize\?\S+)$
```
Port (1455, or the 1457 fallback): `Starting local login server on http://localhost:(\d+)\.`. Use it for `/cancel`.
The URL is ready ~20–30 ms after spawn. It contains `state` and the PKCE `code_challenge`. They aren't secrets
like tokens, but don't log them (redact `(state|code_challenge|code)=[^&]+`).

**Browser opening:** codex calls `$BROWSER <url>` if set, else tries xdg-open etc. (verified with a fake
`BROWSER` script: it was called with the URL). `BROWSER=true` suppresses it (verified on Linux and Android).
With no `BROWSER` and no xdg-open in PATH, it fails silently and just prints the URL. On Linux the app could
also let codex open the system browser itself, but `BROWSER=true` + opening it ourselves keeps one code path.

**Callback server endpoints** (tiny-http on 127.0.0.1:1455):
| request | response |
|---|---|
| `GET /auth/callback?code&state` | wrong/missing state → `400 State mismatch`; codex **keeps running**. Valid → token exchange, writes `auth.json`, serves the success page |
| `GET /cancel` | `200 Login cancelled`; codex exits **rc 1** with `Error logging in: Login cancelled` |
| anything else | `404` |

**Port already taken by another `codex login`:** the new instance calls `/cancel` on the old one and takes the
port over (verified: the old one exits with `Error logging in: Login cancelled`). So don't run two logins.
**Port held by a non-codex process (verified):** codex falls back to **1457** (banner
`...http://localhost:1457.` and `redirect_uri=http%3A%2F%2F127.0.0.1%3A1457%2F...`). Whether auth.openai.com
accepts the 1457 redirect wasn't tested. If 1455 and 1457 are both taken: rc 1,
`Error logging in: Port 127.0.0.1:1457 is already in use`. There's no CLI flag for the port. **So never hard-code
1455:** take the port from the banner/URL.

**Success (UNVERIFIED, from binary strings):** stderr `Successfully logged in.`, exit **0**,
`$CODEX_HOME/auth.json` written (0600; `auth_mode: "chatgpt"`, `tokens.{id_token,access_token,refresh_token,account_id}`,
`last_refresh`). Treat "rc==0 AND auth.json parses with tokens.access_token" as success. Failures:
rc 1 + `Error logging in: <reason>`.

**Timeout: none.** A `codex login` with no callback was still waiting after **25 min** (killed by `timeout 1500`,
verified on Linux). The app must impose its own timeout (suggest 10 min) and then `/cancel` it.

**Diagnostics:** `$CODEX_HOME/log/codex-login.log` gets `starting browser login flow`, `received login callback
... state_valid=...` (handy to prove the redirect arrived; no tokens in it).

### 4.2 Fallback A: device code (`codex login --device-auth`), verified up to the code display
Output on **stdout**, with ANSI colours (strip them):
```
Welcome to Codex [v0.166.0]
OpenAI's command-line coding agent

Follow these steps to sign in with ChatGPT using device code authorization:

1. Open this link in your browser and sign in to your account
   https://auth.openai.com/codex/device

2. Enter this one-time code (expires in 15 minutes)
   XXXX-XXXXX

Continue only if you started this login in Codex. If a website or another person gave you this code, cancel.
```
Regexes (after stripping ANSI): URL `^\s*(https://auth\.openai\.com/codex/device)\s*$`, code
`^\s*([A-Z0-9]{4}-[A-Z0-9]{4,5})\s*$`. No local port, so it works even if 1455 is unusable or the app gets
frozen. It polls `/deviceauth/token`, times out after 15 min (`device auth timed out after 15 minutes`). It needs network
(proxy + certs on Android: verified working from the APK and adb). A server may answer
`device code login is not enabled for this Codex server` (string in binary). Some ChatGPT accounts/workspaces
must enable device-code login in settings (UNVERIFIED). Cancel with SIGINT/SIGTERM.

### 4.3 Fallback B: API key (`--with-api-key`), verified
`printf %s "$KEY" | codex login --with-api-key` → stdout `Reading API key from stdin...` /
`API key saved. Authentication is checked when you send a request.`, rc 0, writes `auth.json`
`{"auth_mode":"apikey","OPENAI_API_KEY":"sk-..."}` (not validated). Woi would then use the api-key paths
(REALTIME_API.md "API-key variant"). `--with-access-token` is **not** a ChatGPT-token import: it expects an
"agent identity JWT" (`invalid agent identity JWT format`). Not useful.

### 4.4 Status / logout
* `codex login status`: `Not logged in` → **rc 1**; `Logged in using ChatGPT` / `API key configured - sk-…***` → rc 0.
  It only reads auth.json. It does **not** prove the token still works. The app should decide validity itself
  (JWT `exp` + refresh as in `research/codex_auth.py`; refresh tokens rotate and must be written back).
* `codex logout` → `Successfully logged out`, rc 0, deletes auth.json.

## 5. Login state machine (for the app)

```
CHECK ─ auth.json ok (access_token exp > now+5min, or refresh succeeded & persisted) ─────────────► READY
  │ missing / refresh 401
  ▼
SPAWN  mkdir CODEX_HOME; [Android: start CONNECT proxy, write cacerts.pem, start FGS]
       exec codex -c cli_auth_credentials_store="file" login   (env §3.4, stdin closed)
  ▼
WAIT_URL  read stderr lines; regex §4.1 ── no match in 15 s, or process exits ──► FAILED(stderr tail)
  ▼
OPEN_BROWSER  Linux: xdg-open/url_launcher; Android: Custom Tab ── (show URL + "copy" as backup)
  ▼
WAIT_CALLBACK  watch: process exit, (optional) inotify/poll auth.json
  ├─ rc 0 && auth.json valid ────────────────────────────────────────────► READY (bring app to front, stop FGS/proxy)
  ├─ rc 1 "Error logging in: Login cancelled" ──────────────────────────► CANCELLED (user can retry)
  ├─ rc≠0 other "Error logging in: …" ──────────────────────────────────► FAILED → offer retry / device code (§4.2)
  ├─ app timeout (codex has none; e.g. 10 min) ─┐
  └─ user taps Cancel ──────────────────────────┴─► GET http://127.0.0.1:<port>/cancel (fallback SIGTERM) → CANCELLED
```
Make sure only one login runs at a time (a second one cancels the first, §4.1). Kill the child on app exit.

## 6. Version pinning, updates, plan B

### 6.1 Pinning
* Pin one version (`CODEX_VERSION` + npm `dist.integrity` in `fetch_codex.sh`) for both arches. Keep the
  app's `originator`/`version` headers (REALTIME_API.md §1) in step with it.
* Build: `fetch_codex.sh` → copy `bin/x64/codex` into the Linux bundle, and `bin/arm64/codex` →
  `app/android/app/src/main/jniLibs/arm64-v8a/libcodex.so` (gitignored, fetched in CI/build script, never committed).
* To bump: `npm view @openai/codex version`, then `npm view @openai/codex@<v>-linux-{x64,arm64} dist.integrity`,
  update both, re-run the §4.1 output check (the URL regex and the stderr format are the contract), commit.

### 6.2 Self-update
Don't use codex's self-update (on Android it can't write nativeLibraryDir anyway). Updates ship with app releases.

### 6.3 Plan B: native PKCE login without the binary (UNTESTED)
Woi only needs `auth.json`. The flow above is plain OAuth2 PKCE: client_id `app_EMoamEEZ73f0CkXaXp7hrann`,
authorize URL as in §4.1, redirect `http://127.0.0.1:1455/auth/callback`, token exchange at
`https://auth.openai.com/oauth/token`. Doing it in Dart (HttpServer on 127.0.0.1:1455 plus a Custom Tab) would
drop the 113 MB APK cost and both Android workarounds (proxy, cert bundle), since Dart uses Android's
resolver and trust store. It means mirroring `codex-rs/login/src/server.rs` (token-exchange body, auth.json
schema, success redirect) and tracking upstream changes, so it's a deliberate trade-off. Bundling codex is only
worth it if the app also wants to run codex itself (`codex exec`, MCP, etc.), and then the same proxy + cert env applies.

## 7. Gotchas (summary)
1. Android: no `/etc/resolv.conf` → **HTTPS_PROXY to an in-app CONNECT proxy** is required for any network call.
2. Android: no Linux CA paths → **SSL_CERT_FILE** (concatenated `/apex/com.android.conscrypt/cacerts/*`). `SSL_CERT_DIR` is ignored.
3. `CODEX_HOME` must exist before exec.
4. All browser-login output is on **stderr**; device-auth output is on **stdout** with ANSI colours (ignores `NO_COLOR`).
5. Callback server is IPv4 `127.0.0.1:1455` only (1457 if 1455 is held by a non-codex process); redirect_uri uses 127.0.0.1, not localhost.
5b. The browser login has **no timeout** (still waiting after 25 min), so the app needs its own.
6. A second `codex login` silently cancels the first.
7. Wrong-state callbacks don't kill the server. `/cancel` does (rc 1).
8. arm64 `codex-path/rg` is glibc-dynamic and won't run on Android (only matters for agent use).
9. exec only from nativeLibraryDir (`useLegacyPackaging = true`); copies in filesDir give EACCES.
10. Cached-app freezer (not active on the MI 8) can stall the callback; hold a foreground service during login.
11. Set `-c cli_auth_credentials_store="file"` (the default is already file, but this guards against a keyring config
    on Linux desktops; codex has a keyring backend).
12. adb shell quirks (only for manual testing): `HOME=/` is read-only, and `TMPDIR=/data/local/tmp` makes codex refuse
    helper links under CODEX_HOME in /data/local/tmp. Set HOME/TMPDIR explicitly.
