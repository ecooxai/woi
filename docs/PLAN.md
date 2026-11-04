# Plan (CTO)

## Architecture
- `app/` Flutter (Dart) app — Linux first, later Android/macOS/iOS from same codebase. NO Rust, NO TypeScript, NO Tauri.
  Core (`app/lib/core`): auth (codex ~/.codex/auth.json or OpenAI API key), realtime WS client,
  audio capture/playback, turn detection, screenshot (X11), input injection (xdotool), bash runner,
  file read/edit with user confirmation, sub-model delegation (Responses API), background context compression (gpt-6-luna).
  Platform specifics behind interfaces in `app/lib/platform/` so mobile ports swap implementations.
- UI (`app/lib/ui`): transcript history (text, images, audio clips), context-size meter, settings, confirm dialogs,
  media popup windows (image/audio/video/text viewer).
- `research/` protocol probes and TTS test fixtures.

## Workstreams
1. Realtime API discovery via Codex auth (research/).
2. App scaffold + platform layer.
3. Integration: voice loop + tools.
4. Context compression + delegation.
5. UI polish, E2E tests with TTS fixtures.

## Decisions log
- 2026-11-02: gpt-live-* only reachable via WebRTC (AVAS) + sideband WS; no client tools/images → actions via
  delegation.created → client DelegationExecutor (gpt-6-luna + tools + screenshot, escalate to gpt-6.1-sol).
- Direct mode: /v1/realtime WS with gpt-realtime-1.5 (native tools + images) — also the OpenAI-API-key path.
- Default backend: gpt-live-1.1 (user requirement); Direct mode selectable for lowest tool latency.

## Iteration log
- Iter 0 (scaffold + research): UI, platform layer, tools, mock backend; protocol verified; 10 TTS fixtures. Score 22/100.
- Iter 1 (direct WS backend, Responses compressor+delegate, live 9/9): 48/100.
- Iter 2 (gpt-live live 10/10, premium UI desktop+phone): 64/100. Defects: missing user transcripts, context accounting, black viewer, ~2.7s latency.
- Iter 3 (transcripts bound per turn, unified context meter, viewer GL fix, thinking cue; QA harness 58% on pre-fix build): 68/100.
- Iter 4 (notes + Markdown editor, in-app fvp video, barge-in fix live 438ms/direct 232ms, screenshot tiers, approvals, orphan mic fix; QA 17/19 full, 18/19 with compact re-run, extras 3/3; latency live median 1.77s): 76/100. Gaps: UI still heavy/dark, no terminal/login, direct latency 3.5s, no Android.
- Iter 5 (minimal light UI, status in input bar, note tabs/New/More/Run, radio settings, tabbed PTY terminal, bundled codex, native PKCE login screen, last-3-turns-raw; idle CPU on :11 472%→4.35%, RSS 1020→505 MB; 302 tests green): 81/100. Gaps: RSS >300 MB, video 324% / scroll 78% CPU on llvmpipe, terminal fd leak per closed tab, no camera/send_keys/voice control of all functions, no Android.
- Iter 6 (send_keys, voice control of all app functions via AppActions, 5s auto-apply edits + undo, camera frames per turn, media context (image/video frame/audio), gpt-live auto-reconnect, black-video fix, NVIDIA/Mesa fix; QA on :11 43/46 with all 3 failures = ChatGPT quota 429; idle 3.4% CPU / 267 MB PSS): 85/100.
- Iter 7 (Android on MI 8: default assistant via long-press home with assist screenshot, accessibility click/type/send_keys, screen share, Camera2, open/share intents → in-app viewer + questions, PKCE Custom Tab, terminal; typed turn → audio 0.9–1.1 s; PSS 183–213 MB; 396 tests green): 87/100. Gaps: Android idle CPU 28% (WebRTC threads), scroll/video ~3 cores on software GL, assist thumbnail renders black in chat, gpt-live/delegation/compaction re-test pending quota reset (~2026-11-05), fat APK (use --split-per-abi), mac/iOS not started.
- Iter 8 (perf + polish): chat scroll on :11 324%→48% CPU (main window on Skia's CPU rasterizer when there is no DRI3 — llvmpipe JIT shaders in two GL contexts were ~60 ms CPU/frame; one SelectionArea per chat), camera on :11 107%→11.5%, idle RSS 320→200 MB; Android: muted foreground 0–2%, listening 14–15%, camera+preview 28–32%, reconnect backoff 20–36%→0% between attempts, image descriptions pause on 429; "black assist thumbnail" was a dark Camera frame (assist PNG verified fine; encoder now opaque sRGB). Gaps: video viewer ~290% on llvmpipe (needs GL), listening at the 15% edge, first camera tap shows no preview. Score: 89/100.
- Iter 9 (Android assistant panel mic via microphone foreground service, verified spoken over the browser; panel 60%→95%; freeform 100%×70%; Linux PipeWire WebRTC echo canceller (virtual rig 62–70 dB, near-end −0.8 dB, 7.5% CPU); auto reconnect at launch/limit/60-min cap; Codex usage check + luna guard; unified tabs; editor Format dropdown + Copy line/paragraph/H1; idle 1.2% on :11; v0.8.0 GitHub pre-release; 474 tests green): 90/100. Gaps: REAL-ROOM ECHO — on built-in speakers only ~15–30 dB is cancelled and Woi talked to itself (live :0 run on push-to-talk until fixed, agent echo15); typing 11 keys/s ~89% and reply 34% on :11 (agent perf16); video viewer ~290% on llvmpipe; gpt-live untested since quota; release APKs debug-signed.

## Spec: image compaction (user requirement, 2026-11-02)
When compaction runs, screenshots/images are tiered by recency:
- Newest 3 images: unchanged (full resolution as sent).
- Older images: downscaled to 1/5 of original width and height (re-encoded, e.g. JPEG/PNG), still sent as images.
- Very old images (default: beyond the newest 3 + next 5, i.e. older than the 8th newest; configurable): replaced by a short
  text description generated by gpt-6-luna (what was on screen, key text, app/window), stored on the message.
- Settings: "keep full images" (3), "keep small images" (5), "small image scale" (1/5).
- Direct mode: apply on the live server session by conversation.item.delete + re-insert of the smaller image / text item,
  between responses, never interrupting playback. gpt-live: applies to the context sent to the DelegationExecutor and
  to the reconnect startup context.
- UI: transcript keeps the original image locally (tap to view), shows a badge "sent as 1/5" or "described: …";
  context meter and banner reflect the savings.

## Backlog (next iteration)
- BUG: run_bash with cwd "~" fails — expand ~ / $HOME in all path args (run_bash cwd, read/show/edit/list paths).
- gpt-realtime-2 live 9/9: eos→first audio median 1967ms (vs 2614ms on 1.5); speaks preamble before tool call.

## Spec: note-focused assistant (user requirement, 2026-11-02)
- Every chat has a Markdown note. Starting a new chat opens the note editor by default.
- Note editor: Markdown editing with live preview/toggle, headings/checklists/code, autosave per chat (stored with the conversation).
- The user can switch between the Note view and the Chat history view (tabs / segmented control; on wide desktop a
  split view with both visible is allowed, with a toggle). Keyboard: Ctrl+1 note, Ctrl+2 chat.
- Both the AI and the user can write to the note. AI tools: read_note, update_note (append / replace section by heading /
  replace all / check off item). AI edits to the note do NOT need confirmation (unlike files), but are highlighted briefly
  and undoable (Ctrl+Z / an "AI edited" chip with undo).
- The note content is sent to the AI EVERY TURN as pinned context (never compacted or summarized; it's counted in the context
  meter as its own segment). Direct mode: refresh the pinned note item / instructions before each response.
  gpt-live: include it in the delegation context and in the session/reconnect startup context; voice model must know it exists.
- System prompt: the assistant proactively records important info (decisions, todos, facts, file paths) in the note.

## Spec: in-app media viewing (user requirement, 2026-11-02)
- show_file for image / video / audio / text ALWAYS renders inside Woi's own view or its own viewer window. Never launch
  external apps (no VLC/xdg-open). Video needs an embedded player that works on Linux without sudo installs
  (candidates: fvp (bundled mdk), media_kit (needs libmpv), or an ffmpeg-decode-to-texture fallback), portable to
  Android/macOS/iOS later.

## Spec batch 2026-11-03 (user requirements)
### UI simplification
- Clean, modern, minimalist style. DEFAULT LIGHT THEME (dark optional in settings). Less glow/glass; generous whitespace,
  crisp typography, subtle shadows. Orb stays but simpler/elegant.
- Settings use radio-button lists for choices (models, voices, backend mode, theme) instead of dropdowns.
### Note editor UX
- Top-right "New note" icon button.
- Recent notes as tabs at top: show the 4 most recent; a "More" button opens a dropdown list of all other notes (searchable).
### Context compaction rule
- The last 3 turns are ALWAYS sent raw (verbatim text + their images). Only turns older than 3 turns are compressed
  when compaction runs. (Image tiers spec still applies to images inside older turns.)
### Built-in terminal
- In-app terminal with tabs (new/close/rename tab, scrollback, copy/paste, ANSI colors, resize), real PTY shell.
  Accessible as a third view (Note / Chat / Terminal). The AI's run_bash output can be shown in a terminal tab.
### Bundled Codex CLI + login
- Ship the codex CLI inside the app (Linux x64 now; Android arm64 from npm @openai/codex@<ver>-linux-arm64, musl static).
- On app start, if no valid Codex auth: prompt the user to log in → run `codex login` (first/default method = browser OAuth
  with localhost callback), capture the auth URL, open it (Linux: system browser or in-app webview; Android: Chrome Custom
  Tab); the callback reaches the codex process's localhost server; resulting auth.json is used by the app.
- Use an app-private CODEX_HOME on Android; on Linux default to ~/.codex (use existing login if valid).
### Android port (after Linux is solid)
- Same Flutter app on Android (test device: Xiaomi MI 8, LineageOS Android 15/SDK 35, arm64, adb serial 2d4f6bc0).
- Platform impls: audio (mic/playback), screenshot (MediaProjection or assistant screenshot), input (AccessibilityService
  for click/type), shell/terminal (app sandbox shell + bundled codex), files (app storage + SAF).
- Codex binary packaged as lib/arm64-v8a/libcodex.so (extracted to nativeLibraryDir, executable under W^X).
- Android system assistant: implement VoiceInteractionService/VoiceInteractionSessionService so the user can set Woi as
  default digital assistant; long-press home wakes it; ALWAYS include the assist screenshot (onHandleScreenshot) and send to AI.

## Roadmap
- Iter 4 (running): notes + in-app media (branch notes-media), backend QA fixes (main).
- Iter 5: UI simplification (light/minimal/radios), editor UX tabs, compaction rule (raw last 3 turns), built-in terminal,
  bundled codex CLI + login flow (Linux).
- Iter 6: Android port + system assistant + codex arm64 + on-device testing.
- Iter 7+: polish, QA, perf, scoring toward 99.

## Decision 2026-11-03: bundled codex CLI (spike verified, research/codex-cli/CODEX_CLI.md)
- Bundle codex 0.166.0 (x64 on Linux; arm64 as lib/arm64-v8a/libcodex.so on Android, ~+113 MB APK) — user requirement,
  and also usable in the built-in terminal. Login: `BROWSER=true codex login`, parse stderr URL regex and port line,
  app-side timeout + GET /cancel; fallback --device-auth. Android needs in-app CONNECT proxy (HTTPS_PROXY) for DNS,
  SSL_CERT_FILE = concatenated /apex/com.android.conscrypt/cacerts, HOME/TMPDIR/CODEX_HOME pre-created,
  foreground service during login.

## Decision 2026-11-03 (revised, user): NO bundled codex on Android
- Auth on Android = native Dart OAuth2 PKCE (CODEX_CLI.md §6.3): client_id from codex, Dart HttpServer on 127.0.0.1:1455
  callback, authorize URL opened in Chrome Custom Tab, token exchange at auth.openai.com/oauth/token, write auth.json in
  app-private storage (same schema as codex so refresh logic is shared). Foreground service during login if needed.
- Linux: same native login code path when ~/.codex/auth.json is missing/invalid; codex CLI still bundled on Linux
  (user asked earlier) for use in the built-in terminal. Supersedes the Android part of the previous decision.

## Spec batch 2026-11-03 #2 (user)
- Minimal UI: REMOVE the decorative effect area above the editor (orb panel / glow / particles); no heavy decorative
  animations. Status (connection, listening/thinking/speaking, tool activity) is shown INSIDE the bottom input bar.
- Editor top bar: a "Run" button — sends the current line (cursor line, or selection if any) to the AI as a user turn.
- Testing happens on the embedded nested display DISPLAY=:11 (Xephyr 1600x900 + openbox, kept running; started by CTO:
  `DISPLAY=:0 Xephyr :11 -screen 1600x1000 -resizeable -ac -nolisten tcp` then `DISPLAY=:11 openbox`). Never on :0.
- PERFORMANCE FIRST: monitor CPU and RAM of all woi processes (main + viewer sub-windows) during idle, listening,
  speaking, typing in editor, scrolling history. Targets: idle CPU < 2% of one core, active voice < 15%, RSS < 300 MB,
  no leaks over a 10-min session, 60 fps scrolling. Script: qa/perf_monitor.sh (pidstat/ps sampling → CSV + summary).
- Perf finding 2026-11-03 (CTO): pre-iter5 UI on :11 (Xephyr = Mesa llvmpipe software GL) burns ~321% CPU / ~900 MB RSS
  while OFFLINE+MUTED — the animated voice orb repaints every frame. Rule: zero running tickers/animations when idle;
  any animation only while actively listening/speaking, throttled, inside RepaintBoundary. :11 is a good canary because
  every frame costs real CPU there. Merge gate: idle woi on :11 < 5% CPU, RSS < 300 MB.

## Spec batch 2026-11-03 #3 (user)
Linux first (finish), then Android:
- Camera: user says "open camera" → camera on (live preview tile in the UI); while on, attach the latest camera frame
  to every user turn (like screenshots, same compaction tiers). "close camera" stops it. Linux: v4l2 (/dev/video*).
- Key events: tool `send_keys` (e.g. "ctrl+c", "esc", "ctrl+v", "ctrl+a", "alt+tab") to a target window, default =
  the current/active window (not Woi). Linux: xdotool key --window. Android: AccessibilityService global/IME actions.
- Every app function is voice-controllable: note edit/insert/replace/undo/redo/new/switch/rename/delete, switch views
  (note/chat/terminal), open settings values (model, theme, voice), mic mode, camera, terminal tab new/run/close,
  viewer open/close/pause/seek. Expose as tools / delegation fast paths.
- Edits: note edits AND other-file edits auto-apply after 5 s (diff preview with countdown; user can Reject/Apply now
  by click or voice "cancel"/"apply"). Undo works for applied edits (note undo stack + file backup restore).
- Media context: when an image/audio/video is open in the viewer and the user asks about it, send it: image as image,
  audio as audio (or transcript), video → current playing frame as an image (+ timestamp).
Android (after Linux): default assistant (VoiceInteractionService, long-press home, always send assist screenshot),
"open with"/share-target intents for image/audio/video/text files, screen share (MediaProjection continuous frames per
turn), send key events to the current app (esc/back, ctrl+c copy, paste, select all) via AccessibilityService.

## Spec 2026-11-03 #4 (user): Android assistant as a floating overlay
- Invoking the assistant (long-press home, power-button long-press / assist gesture, ASSIST intent) must NOT switch to
  the Woi app: Woi shows a floating panel OVER the current app (VoiceInteractionSession window / overlay), the
  underlying app stays visible above it.
- Default panel height: 60% of the screen height, anchored at the bottom; the user can drag-resize (handle) up to 95%
  (and down to a minimum, e.g. 35%); size remembered.
- The panel holds the compact Woi UI: transcript of the current turn(s), input bar with status + mic, and an
  "open full app" button. The assist screenshot of the underlying app is attached as before. Dismiss with
  back / tap outside / swipe down; actions (click/type/send_keys via accessibility) operate on the app underneath
  (the panel must not steal those events: hide/shrink during gestures if needed).

## Spec 2026-11-03 #5 (user): Android app starts in a freeform window
- Try to launch Woi (the full app, from the launcher and when the assistant hands off to "open full app") in a
  freeform window by default: width 100% of the screen, height 70%, docked at the bottom.
- Approach: the manifest `<layout android:defaultWidth="100%" android:defaultHeight="70%" android:gravity="bottom">`
  on MainActivity plus `resizeableActivity`, and ActivityOptions.setLaunchBounds / launch windowing mode when Woi
  launches itself. Needs freeform support on the device (Android 15: developer option
  `enable_freeform_support`, or the desktop windowing mode); when it's unavailable, fall back to full screen without errors.
- The assistant floating panel (#4: 60% by default, resizable to 95%) stays as is.

## Spec 2026-11-03 #6 (user): testing on gpt-realtime-2.1, echo cancellation, unified tab UI
- Testing defaults to Direct realtime with gpt-realtime-2.1 (free on the ChatGPT login; probed: 2.1 and 2.1-mini
  exist, 2.2/3 don't). gpt-live costs quota: only test it when explicitly needed (`PHASES=live`). App default
  realtime model: gpt-realtime-2.1.
- Echo cancellation: the mic picks up system audio (other apps and Woi's own playback). Cancel it: Linux via a
  PipeWire echo-cancel node (webrtc AEC; reference = the default sink's monitor, so all system audio is cancelled),
  owned by the app, never changing the user's default devices; Android via VOICE_COMMUNICATION +
  AcousticEchoCanceler/NoiseSuppressor (and WebRTC's AEC on gpt-live). Setting: on by default.
- Unified, simplified UI: the whole app is tab-like: Note, Chat, Terminal, Settings are tabs in one tab strip that
  starts at the left edge (no "Woi" title on the left); settings is a tab, not a separate screen/dialog.
- Delegation (complex tasks, gpt-live delegation tool loop) defaults to gpt-6-luna; gpt-6.1-sol is an optional
  setting (expensive) and is never used in tests.
- Codex usage check: read the ChatGPT/Codex rate-limit usage (5-hour window and weekly window, as Codex CLI's
  /status shows: e.g. the `x-codex-primary/secondary-used-percent` response headers or the backend usage endpoint)
  and show it in the UI. When EITHER window has < 20% remaining, delegation/compaction use gpt-6-luna even if the user
  selected gpt-6.1-sol (show why), and Woi tells the user when gpt-live/realtime quota is low.
  - Done (usage14): `wham/usage` endpoint + `x-codex-*` headers → `CodexUsage`; guard threshold setting
    `usageGuardPercent`; settings meter; one-time chat notice; `app_control usage`. Gap: the realtime/gpt-live
    connections' own responses are not read for headers (only Responses API calls + the 10-min fetch).

### #6 tab UI: as built
- "Unify and simplify UI, make the whole app tab-like": Note, Chat, Terminal and Settings are top-level tabs in one
  strip starting at the left edge (icons + labels; on phones only the selected tab shows its label). The "Woi"
  title is removed; the header keeps only the side-by-side toggle (wide windows) and the history button on the right.
- Settings is a tab hosting the settings content inline (radio sections, section rail on wide layouts); no
  separate route. Ctrl+1..4 select the tabs, Ctrl+, opens Settings, Esc leaves it; voice "open settings" /
  "show chat" (app_control show_view, delegation fast paths) select the tabs.
- One tab language (`WoiTab`: label + accent underline): the note's file tabs (New, 4 recent, More) and the terminal
  tabs are the lighter secondary row inside their tab; the editor's Run button is tonal.
- Split view (>=1280 px): Note and Chat side by side and both read as selected; Terminal/Settings are full size,
  going back restores the split. No new animations (idle stays at ~0 frames).

## Spec 2026-11-04 #7 (user)
- FIX FIRST: the Android assistant panel floating over another app can't use the mic (Android blocks capture for an
  app that isn't foreground: needs a microphone-type foreground service / the session must own capture).
- Editor: no edit/preview icon toggle in the top bar; all Markdown format buttons merged into ONE dropdown; a Copy
  button copies the whole note; long-pressing Copy offers: current line, current paragraph (text between blank lines),
  current H1 section.
- Perf: on the embedded test display Woi uses too much CPU even when idle; find the cost. Target: < 30% most of the
  time (idle ≈ 0%) on :11 (software GL).

### #7 editor + idle CPU: as built
- Editor toolbar: one **Format** dropdown (headings, inline styles, lists, quote, code block, link, Preview) with the
  shortcut shown on every entry; undo/redo; **Copy** (whole note, Ctrl+Shift+C; long-press / right-click: line,
  paragraph, H1 section at the cursor, "Copied …" confirmation); Run. No edit/preview toggle: Preview is in the
  menu (Ctrl+Shift+P), Esc or the "Preview ×" chip returns to editing. Voice: `note_control` `copy` + `what`, fast
  path "copy this paragraph". Extraction is `lib/core/notes/note_copy.dart` (unit tested).
- Idle CPU on :11 (software GL): with the mic really muted (or a silent source) Woi is already ~1% idle on every tab.
  The high readings came from states that never ended or animated at 60 fps: switching to push-to-talk mid-utterance
  left "Hearing you…" and the bubble's listening dots running forever (now the turn closes); the dots were a 60 fps
  controller (now 5 fps steps, still after 20 s); tool spinners, progress sweeps and the compaction meter ran at the
  display rate (now 12 fps timer-driven, in repaint boundaries). QA: `WOI_MIC_MODE` forces the launch mic mode,
  `PERF_SILENT_MIC=1` gives `qa/perf_scenarios.sh` a silent PipeWire source, keys go through XTEST.
- Typing: every keystroke re-counted the pinned note's tokens, sent a `session.update` and started the context
  meter's 700 ms tween (~45 frames per key). The pinned-note sync is now debounced (600 ms, at most every 3 s while
  typing) and the meter fill is quantized to 1/80 steps, so a key costs ~1 frame. What remains is the full-window
  software raster (~20 ms a frame) plus the editor rebuild; sustained 11 keys/s still reads ~80%, a 3 keys/s pace ~10%.
- Reply: the voice level publishes at 10 Hz (was 15).

### Perf (perf16)
- Typing in a note rebuilds only the text field: toolbar, AI chip and preview rebuild only when what they show
  changes; the footer (words, chars, save state) is a `ThrottledBuilder` (<= 4 Hz) in its own layer; the field sits
  in repaint boundaries; highlighting merges adjacent same-style runs (~35% less text layout per key on a 4,400-char
  note); the editor scrollbar stays visible (no fade frames per Enter).
- A streaming reply rebuilds only its own bubble (`messageRenderSignature` per tile, `RepaintBoundary`); the
  pipeline coalesces transcript deltas to at most ~15 notifications/s (one trailing notify per burst; phase
  changes notify at once). `ThrottledBuilder`: <= 1 rebuild per interval, final state always shown.
- Test counts (unit/widget): 10 calls/s for 3 s at 250 ms → 9–12 runs; 500 ms of changes every 50 ms → 4 builds;
  30 deltas in one interval → 1 notification; a delta leaves other tiles' builds untouched.
- Typing A/B on :11 (release, 10 keys/s, 30 s, 3 samples each, load avg ~30–50): main 50.1 / 59.1 / 51.6% CPU
  (avg 53.6%), 17.5–21.5 frames/s, RSS growth +69–74 MB → perf16 47.0 / 46.0 / 47.8% (avg 46.9%), 14.7–17.9
  frames/s, RSS growth +38–49 MB. Sustained 10 keys/s is still above 30%; the floor is the full-window software
  raster (~20 ms/frame on llvmpipe).
- RAM while typing: Dart heap stays ~15–26 MB; the growth is native (anon) memory, ~+50 MB over 60 s, and stays
  after typing stops (MALLOC_ARENA_MAX=2 no help; with NO_AT_BRIDGE=1 idle RSS fell to ~100 MB — the AT-SPI
  bridge is the lead). Reduced, not fixed.
- Video viewer on llvmpipe (~290%) not touched in this branch.
