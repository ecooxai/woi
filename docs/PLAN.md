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
- Iter 10 (click accuracy: click_screen target by name via AT-SPI/Android a11y + luna vision fallback, 35/35 bench hits — realtime image downscale was the cause; wide split view (tab content left, chat always right, draggable divider) + card-free layout; voice control matrix docs/VOICE_CONTROL.md 36 existing + 19 added (disconnect/reconnect, clear chat w/ approval, compact, 11 settings); Linux echo: deferred server interrupts (stop 0.54–0.83 s, was 7.4 s), far-field NR, short foreign/filler echo rule, per-turn decision log; Android audio: phone route (call-mode AEC, default) + media route (VOICE_COMMUNICATION+AEC on Woi's session, half-duplex, pauses other media), ducking, mic yields to other recorders, verified on MI 8; freeform at top-left; typing CPU 54→47%; live :0 back to hands-free; v0.10.0 GitHub pre-release Android+Linux; 565 tests): 91/100. Gaps: echo turns on laptop speakers still ~2–3 per E2E (no reduction yet); media-route voice barge-in unverified on device (no in-room voice source); one unexplained fullscreen relaunch on Android; typing ~47% CPU on :11 (>30% target), native RAM growth (AT-SPI bridge); video viewer ~290% on llvmpipe; Settings page still card-heavy; gpt-live untested since quota; APKs debug-signed.
- Iter 11 (Settings regrouped into 9 plain sections with search + Advanced expanders, no cards, status chip shows model only; Linux echo: root cause of lost "stop" found — WebRTC NS + transient suppression cut the user's voice ~23 dB during Woi's speech, now off (double-talk near-end loss 26.6→3.9 dB, ERLE unchanged; steady-state AEC3 is 39–47 dB, low averages come from delay jumps + convergence); empty/filler deferred turns no longer cut Woi (0 wrong interrupts in 2 E2E runs, was 2–3); broken armed probe removed; E2E fixture scoring fixed; perf: typing benchmark was typing into the chat pane (fixed), AT-SPI/semantics hypothesis measured and rejected (31.5% vs 28.2% CPU, RSS plateaus at ~+47 MB = caches, not a leak); 576 tests): 91/100. Gaps: stop while Woi speaks still depends on server VAD (361 ms / 2.7 s / lost over 3 runs; echo27 in progress); typing ~28–31% CPU (no profile yet); media-route voice barge-in unverified on device; one unexplained Android fullscreen relaunch; video viewer ~290% on llvmpipe; voices still a radio list; gpt-live untested since quota; APKs debug-signed.

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
  freeform window by default: width 100% of the screen, height 70%, anchored at the top-left (0,0).
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

### Perf (perf24)
- `qa/perf_scenarios.sh` typing clicked at 60% width, which in the split view is the chat pane, so keys went
  nowhere (earlier "typing" numbers from this script, incl. ~47%, were not note typing); now clicks at 30%.
- Hypothesis "Woi's own AT-SPI bridge + per-frame semantics tree cause typing CPU / RSS growth" was tested and
  REJECTED (release, :11, 1600x900 checked by screenshot, 10 keys/s into the note, interleaved 3x3):
  | arm | CPU mean (samples) | RSS growth 30 s | 60 s |
  |---|---|---|---|
  | bridge+semantics on | 31.5% (26/34/33) | +44/+30/+46 MB | +47 MB |
  | bridge+semantics off | 28.2% (27/31/27) | +40/+40/+40 MB | +47 MB |
  | idle | ~1-3% | flat | |
  Difference is within load noise and RSS growth plateaus (~+47 MB, caches warming, not a leak), so the
  change was NOT merged (it would remove screen-reader support for no gain). Next: count frames per key and
  profile the editor (layout of the whole note per keystroke?) with `--profile` + DevTools timeline.

## Real-room echo (echo15)
P0: on built-in speakers + mic the PipeWire WebRTC canceller removes only ~15–30 dB in a real room; server VAD
heard the residual as the user and Woi answered its own words ("Pointer moved…" → user turn "Boiner moot").
Layers, from the device to the conversation:
- **Canceller (unchanged), measured** — `qa/aec/offline_matrix.sh` runs WebRTC AEC3 with PipeWire's config offline on
  a rendered echo path (speaker drive + clip, room IR, delay jump, drift; `render_echo.py`, `aec3_offline.cc`,
  `erle.py`): ERLE only 12.7 dB at reply starts / 17.9 dB in the body (residual −34 / −41 dBFS), near-end loss 0.9
  dB, double-talk near-end −27 dB; reference 20–300 ms off barely matters, 600 ms early breaks it (1 dB). The VAD
  proxy still sees 1 false start per 30 s of Woi speech (8 without a canceller). `qa/aec/pw_latency.sh`: the
  canceller itself adds ~47 ms at node.latency 480/48000 (62 ms in double talk), ~65 ms at 960; 256 crashes PW 1.6.7.
- **Echo guard** (`core/pipeline/echo_guard.dart`) — knows Woi's playback sample-exactly and compares each 10 ms mic
  frame in 8 bands with the echo that playback can produce (delay window −40..600 ms, lag tracked by envelope
  correlation, per-band coupling learned on echo-only frames). In hands-free, while echo is expected the server gets
  silence instead of the mic; a near-end onset (≥2 bands 8 dB above predicted echo, 100 ms) opens the gate and the
  held 400 ms is sent first, so the user's first syllable is not lost. No added latency outside Woi's speech (the mic
  passes straight through); push-to-talk and Android managed capture are not gated.
- **Soft local barge-in** — a local onset pauses playback instead of cutting; the server's speech start confirms
  (cancel + hold as before), otherwise playback resumes after 900 ms where it paused.
- **Transcript guard + self-talk breaker** (`core/pipeline/echo_transcript.dart`) — a user turn that starts while Woi
  is audible is held (tool calls too) until its transcript is final; if it matches what Woi was saying (consonant
  skeletons, voiced/voiceless merged) it is dropped (reply, tool calls, server item, bubble) and the cut-off reply
  plays on. Three echo turns within 90 s pause hands-free (mic → muted) with a notice.
- **QA** — `WOI_AUDIO_SINK` / `WOI_AUDIO_SOURCE` pin playback, mic and AEC to given nodes; `qa/aec/e2e_echo.sh` runs
  the release build on :11 (Direct, gpt-realtime-2.1) with its voice fed back through a virtual room (drive ×3 +
  clip, IR, 150 ms) on qa_e2e_* null sinks.

Numbers (`qa/aec/guard_eval.sh`, 12 rigs = turns/stress × 3 seeds × near-end −24/−30 dBFS, 505 s of Woi speech):
| stream to server VAD | false user turns |
|---|---|
| raw mic (no canceller) | 130 (15.5/min) |
| canceller only (before) | 24 (2.85/min) |
| canceller + echo guard (after) | 9 (1.07/min), 0 in the conversational "turns" rigs except 1 at −24 dBFS |
False local onsets (pauses): guard 19 vs old broadband BargeInDetector 34. Barge-in detection: guard 11/18 vs old
14/18 items over Woi's speech; guard detects 200–380 ms after speech start (median 330 ms, capture time, plus
~50 ms canceller latency). The transcript guard catches the remaining echo turns that do get through.

E2E (`qa/aec/e2e_echo.sh`, after build only, 2026-11-04; the before run was not completed): of 4 user turns 2 were
self-talk ("That's", "What?"), 0 echo turns dropped by the transcript guard, 7 false local onsets (pause + resume),
and "Stop" / the question barge-in stopped Woi only after 7.4 s / 8.3 s (the 2 fixture barge-ins never became user
turns). Mic level p50 −25 dBFS. **Open:** the guard is not yet good enough on this virtual room (clip + IR, no
real speaker roll-off, so its low-band advantage is gone) — false onsets and missed barge-ins; needs the before run
for comparison and tuning (onset threshold vs the room's coupling) before the live :0 app leaves push-to-talk.

Barge-in first (2026-11-04): the silence gate is now **off by default** (`TurnPipeline.echoGate`). Offline it lost
7/18 real interrupts. Lowering the onset threshold did not get them back (margin 6/4 dB, onset 60 ms: 12/18, 45-54
false onsets). The misses are short words in double talk only 2-3 dB above the predicted echo; the gate then kept
them from the server, which is what made "Stop" take 7.4 s in the E2E. The server now always gets the canceller's
output, so barge-in recall is back to canceller + server VAD (the pre-echo15 behaviour) plus the local soft pause.
Echo turns are left to the transcript guard and the self-talk breaker, so the server sees false turns at the
canceller rate again (2.85/min offline). After an onset the guard re-arms once the near end has been quiet for 200 ms
(before: once per reply).

Deferred turns + far_field (2026-11-04): the session uses `noise_reduction: far_field` (no headset detection yet;
gpt-realtime-2.1 echoes `{"type":"far_field","strength":1.0}`). From `response.created` until the reply's audio plus
1.3 s of echo tail are over, `session.update` sets turn_detection `create_response` / `interrupt_response` false;
verified live on gpt-realtime-2.1: a partial update (only `audio.input.turn_detection`) is accepted mid-response
(`session.updated` ~0.5 s later), the response then plays on through a server speech start and no response is
created for the turn. Such a turn reaches the pipeline as `SpeechStarted(deferred)`: local detector fired (onset
within 1.5 s or paused) → cut + `acceptTurn` at once; else Woi talks on while the pipeline waits up to 600 ms
(`deferWindow`) for the transcript (echo → item deleted, Woi never cut; not echo / stop → cut), then interrupts
anyway. Accepted turns get `response.create` when they end. Measured: the final transcript ("Stop.") arrives
~1.4 s after `speech_started`, so the 600 ms window practically always times out and only the local detector
saves latency; echo is still dropped later by the transcript guard (cut + resume) as before.
E2E (`e2e_echo.sh after-defer`, gate off, deferred turns, far_field) vs the gate-on run above:
| | gate on (before) | deferred + far_field |
|---|---|---|
| "Stop" stops Woi | 7.4 s | 0.54 s (local onset → immediate) |
| question barge-in stops Woi | 8.3 s | 0.04 s (local pause) |
| barge-ins that became user turns | 0/2 | 2/2 |
| self-talk user turns | 2 | 2 ("아", "하고": echo transcribed as Korean, so the guard cannot match it) |
| false local onsets (pause + resume) | 7 | 8 |
One deferred turn occurred (timeout → cut). Next: pin the transcription `language` to the UI language so echo is
transcribed in English and the guard can match it; a headset → `near_field` switch.

Why AEC3 cancels so little (aec25, 2026-11-04, offline rig, `render_echo.py` + `aec3_offline.cc` at 48 kHz mono,
exactly PipeWire 1.6.7's config; the installed libspa-aec-webrtc only exposes high_pass_filter, noise_suppression,
voice_detection, transient_suppression, mobile_mode, gain_control, so no AEC3 tuning knobs). The app's host is
already mono at the graph rate (48 kHz), reference = default-sink monitor, so no channel/rate mismatch.
- **Low ERLE = the delay jump, not the settings or the clipping.** Steady state AEC3 reaches 39-47 dB (far-only
  5-20 s). The 12.7/17.9 dB figures are energy-weighted and dominated by the rig's +120 ms delay jump at 52 s
  (ERLE 4 dB for 4 s, still 15 dB 10 s later) plus the first 1-5 s of convergence (15 dB). Without the jump: 22.4 /
  26.0 dB (turns), 25.0 / 26.5 dB (stress). Jumps of 20/60 ms recover (24.6/23.4 dB at reply starts); +-10 ms
  jitter costs ~1 dB. Speaker overdrive: drive 1.0 instead of 2.2 gives only +2/+5 dB; no drift +5/+9 dB.
- **None of the exposed args change ERLE** (+-0.5 dB): HPF, voice_detection, NS, TS. mobile_mode (AECM) outputs
  silence at 48 kHz: unusable.
- **NS + transient suppression ate the user, not the echo**: double-talk near-end -26.6 dB with them, -3.9 dB
  without (turns rig; stress -20.5 -> -7.4), ERLE and VAD false starts unchanged, near-only loss 0.9 dB both.
  NS alone off: -18.5 dB, TS alone off: -14.5 dB (stress) — both have to go. That is the lost short "stop": it
  was cut ~23 dB more than the echo. **Applied**: `aec.args` NS and TS off (`pipewire_aec.dart`).

| rig / setting | ERLE start / body (dB) | residual start / body (dBFS) | near-only loss | double-talk near-end | VAD false starts |
|---|---|---|---|---|---|
| turns, Woi before (gain_control off) | 12.7 / 17.9 | -34.1 / -40.8 | 0.9 | -26.6 dB | 1 |
| turns, NS + TS off (applied) | 12.7 / 17.9 | -34.1 / -40.8 | 0.9 | **-3.9 dB** | 1 |
| turns, TS off only | 12.7 / 17.9 | -34.1 / -40.8 | 0.9 | -31.3 dB | 2 |
| turns, no delay jump | 22.4 / 26.0 | -43.8 / -49.0 | 0.9 | -26.5 dB | 0 |
| turns, no delay jump, NS + TS off | 22.2 / 25.8 | -43.6 / -48.7 | 0.9 | -3.6 dB | 0 |
| stress, default | 13.0 / 15.6 | -34.2 / -38.8 | 1.1 | -20.2 dB | 3 |
| stress, NS + TS off | 12.9 / 15.7 | -34.2 / -38.8 | 1.0 | -7.4 dB | 3 |
| stress, no delay jump | 25.0 / 26.5 | -46.3 / -49.7 | 1.1 | -20.5 dB | 0 |
| stress, drive 1.0 (less clipping) | 15.3 / 20.3 | -36.4 / -43.7 | 1.1 | -20.0 dB | - |
| stress, no drift | 17.9 / 24.3 | -39.1 / -47.5 | 1.1 | -20.6 dB | - |
| stress, linear + static (no clip/jump/drift) | 25.3 / 33.1 | -46.3 / -56.5 | 1.1 | -20.5 dB | - |
| stress, jump 20 / 60 / -60 ms | 24.6 / 23.4 / 13.0 start | - | 1.1 | -20 dB | - |
Next: in the real graph, delay jumps come from quantum changes (the sink's ALSA delay moves with the quantum while
the monitor does not) and xruns. The host sets no `node.latency`, so other clients can move the quantum while
Woi talks. Pinning it (480/48000 measured OK, 256 crashes) is the next thing to try; it needs a live check.
Lowering Woi's playback gain buys little (drive 2.2 -> 1.0: +2-5 dB).

Short foreign / filler echo (echo21, 2026-11-04): the transcriber turns fragments of English echo into short
Korean ("아", "하고"), which [isEchoOf] cannot match. New rule (`shortEchoReason` in `echo_transcript.dart`), applied
where the transcript guard decides (held echo-suspect turns, deferred turns): a turn that began while Woi was
audible or in its echo tail, with no local onset (paused or onset within 1.5 s), whose final transcript is short
(≤ 2 words, ≤ 4 Han/kana chars) and either a pure filler ("uh", "아", "嗯", "あ", "э") or in a script that neither
Woi's reply nor any of the user's last 5 turns use, is echo: item dropped, Woi plays on, logged as "taken as echo".
Stop requests are never dropped: `isStopPhrase` plus a multilingual list (停 / 等一下 / 别说了 / 그만 / 잠깐 / 待って /
стоп / Stopp …). A Chinese user is not affected (their turns are Han, so Han passes); a first-ever short turn in a
new language over Woi without a local onset can be lost (Woi keeps talking; the user repeats). The transcription
`language` hint was not added: it would force-mistranscribe a multilingual user and the rule above needs no
session change. `e2e_echo.sh` now skips the mic levels instead of crashing when `mic.wav` is empty.
E2E `after-lang` (one run, not comparable): "Stop" 3.3 s (vs 0.54 s), question barge-in 0.47 s, 5 non-fixture
user turns (3 empty, "다음에 또 봐요." = 4 words so not short, "어?" not dropped), 1 echo turn dropped by the
transcript guard ("What?"), 0 by the new rule, 20 false local onsets (vs 8), 5 deferred timeouts. The run was
degraded: the echo guard never locked a lag (`lag null` on every onset), `mic.wav` came out empty, and the full test
suite ran concurrently. Needs a clean re-run; log the final user transcript + echo-suspect state per turn to see
why "어?" passed (likely not an echo suspect: started outside Woi's audible window / 20 s `_spoken` horizon).
Each user turn now logs one line at its final transcript: `user turn: "<40 chars>" suspect= deferred= local=
audible= guard= window=<ms left in the echo window> -> kept | kept (stop|deferred: why) | dropped (short: why |
echo match | deferred echo match)`.
E2E `after-lang2` (clean: rig checked first with a pw-record capture, no test suite running, mic.wav 17 MB of audio
but no finalized WAV header so mic levels were still skipped): "Stop" 0.83 s (vs 0.54 s), question barge-in 0.38 s
(vs 0.04 s), 0 echo turns dropped, 0 short-rule drops, 0 deferred turns (vs 1 timeout), 14 false local onsets (vs 8),
3 non-fixture turns (vs 2): "maq" and 2 empty. All three had `local=y` (the local detector had paused Woi), so the
short rule correctly did not apply. "maq" is the "Stop" fixture itself mistranscribed over the echo (onset at the
fixture time, `interrupted=true`): Woi was stopped by the barge-in, not by the stop phrase. The 2 empty turns were
released with no reply. "어?" did not recur. `lag null` on every onset is normal on this rig: the after-defer
reference run logged `lag null` too, so the guard not locking a lag was not what degraded `after-lang`. The echo
window is not too short: suspects started with 6 to 35 s still left in it (`queuedMs` + 1.3 s, and the whole reply
is queued), so extending the tail would change nothing. `audible=n` on every turn even while the guard expected echo
(`_out.isPlaying` reads false while playback is queued): suspects still get flagged through the guard and the window.
Barge-in latencies swing a lot between single runs (the stop latency depends on when the onset fires); no rule change.

`audible=n` explained (echo22, 2026-11-04): the player clock was right (`PlaybackClock.isPlaying` is true from the
first write until the queued audio has played; now unit-tested). The per-turn log read `_assistantAudible` *after*
`_bargeIn()` / the local-onset `_pause()` had stopped the player, and every suspect turn in `after-lang2` was
`local=y` (paused or cut), so it always said `n`. Fix: the state is snapshotted before the cut and logged as
`audible=y` (playing/queued) | `p` (paused by a local onset) | `t` (echo tail) | `n`. `_assistantAudible` now also
covers a 300 ms room tail after playback ends or is cut (echo suspicion, the onset detector's `audible`, the local
VAD's sensitivity, the gate); phase, `_bargeIn`, the local onset (nothing to pause in the tail) and the Android
half-duplex gate (`_sendGated`, it has its own 300 ms hangover) use the player state only, so their behaviour is
unchanged. Expected E2E effect: none on decisions (suspects were already flagged via the guard / echo window), only
truthful logs. `e2e_echo.sh` now reads mic.wav's samples from the file length (pw-record is killed, so the header
sizes are never finalized); re-parsed `after-lang2`: mic p50 −25.0 / p90 −19.9 dBFS. **Open:** `e2e_echo.sh
after-audible` was not run (time limit); run it to confirm no regression and get per-turn `audible=` tags.

Lost "stop" (echo22, 2026-11-04, `after-audible` P0: stop 7170 ms, server never sent speech_started). Why: in the
E2E room the 0.3 s "Stop" lands at about the echo's level (mic around it −20…−22 dBFS, echo p50 −25 / p90 −20), so
excess over the predicted echo is tiny (0.017; 0.008 in `after-armed`) and the local onset fires ~0.4 s late, near the
word's end. While Woi speaks the session runs server_vad threshold 0.5 / prefix 300 / silence 500 with
`create_response`/`interrupt_response` false (only those two flip; threshold unchanged). The server VAD never fires on
the steady echo and a short word at ~0 dB SNR does not move it; a 1.5 s "Hello, how are you?" is confirmed after ~1 s.
Tried (a+c): an unconfirmed onset stays armed. 0.7 s after resuming (1.6 s after the onset, unless a speech start
came) the mic around it (2.2 s ring) is committed as its own item (`input_audio_buffer.clear` / `append` / `commit`),
transcribed, deleted, never answered (`VoiceBackend.probeSpan` → `ProbeTranscript`); a stop phrase within 5 s cuts the
reply (`probeStops`). Unit-tested. E2E `after-armed` (probe at resume, no delay yet): **stop still lost, 6522 ms**, the
stop clip transcribed as "" (so did all 5 echo-only clips; gpt-4o-mini-transcribe gives nothing at that SNR), question
0.24 s, 1 extra turn ("iu"), 7 resumed onsets. The undelayed probe cleared the buffer 166 ms before the server
confirmed the question, which split it ("iu" + probe "How are you?"): hence the 0.7 s delay and the cancel on
speech start (not yet E2E-verified). **Open:** server-side transcription cannot rescue a word buried in the echo; next
is a local decision (option c: the guard's voice bands / excess on the paused span decide "do not resume" and cut,
or a semantic_vad / lower-threshold session while speaking, b), then rerun `e2e_echo.sh`.

echo22 e26 (2026-11-04, after aec25 NS/TS off; `after-nsoff`: stop 361 ms, question 1064 ms, self-talk "" / "啊", 3
replies interrupted, 2 of them wrongly). Changes: (1) a deferred server turn that has no local onset now keeps Woi
playing when `deferWindow` runs out. It stays undecided until a local onset or a non-echo transcript interrupts, or
an empty or echo transcript drops it unanswered. (2) `shortEchoReason` now also applies to local-onset turns that
start while Woi is audible (y/p), so a lone "啊" resumes the reply. Stop phrases are still never echo. (3) Removed the
armed probe (`probeSpan`/`ProbeTranscript`). Every live probe got `input_audio_buffer_commit_empty`, even with
clear/append/commit sent in one tick. Earlier, the clip transcribed as "" at that SNR anyway, and clearing the live
buffer split a real turn. (4) `e2e_echo.sh` matches fixtures fuzzily (first word, or ≥50% word overlap).
E2E, two runs alone: `after-e26a`: stop 2660 ms (server speech start came 1.8 s after the onset; transcribed "好。",
interrupted as a stop request), question 1304 ms, 5 fixture turns + "好。" (the stop), 0 wrong interrupts, 4 resumed
onsets, the empty deferred turn dropped without a cut. `after-e26b`: **stop lost, 7200 ms** (onset resumed, no server
speech start at all), question 1252 ms, 5 fixture turns, 0 self-talk, 0 wrong interrupts, 4 resumed onsets.
False cuts are fixed. Stop is still decided by whether the server VAD fires (361 / 2660 / 7200 ms over three runs).
**Open:** a local "do not resume" decision on the paused span (option c above).

echo27 e27 (2026-11-04). Changes: (1) while Woi is audible (defer mode), the server VAD runs with threshold 0.3,
prefix 300 ms and silence 400 ms. It goes back to 0.5 / 300 / 500 after the echo tail, with one `session.update` per
transition. (2) Local hold: an onset whose peak excess RMS over the voiced run (`EchoGuard.onsetPeakRms`) is
≥ 0.012 is not resumed after 900 ms. It stays paused up to 1.5 s more, waiting for a server speech start (which
cuts). If none arrives, it resumes where it paused. E2E, two runs alone: `after-e27a`: stop 441 ms, question 173 ms,
5 fixture turns, 0 self-talk, 0 wrong interrupts, 2 resumed onsets (1 false: peak 0.018, held 2.4 s; the other was the
stop). `after-e27b`: stop 501 ms, question 317 ms, 5 fixture turns, 0 self-talk, 0 wrong interrupts, 1 resumed onset
(the stop). Two empty echo speech starts were dropped without a cut. **Caveat:** the script's stop figure only
measures the pause. In both runs the server VAD **never** fired on "stop", even at 0.3, so after the hold Woi
resumed (2.4 s gap) and the stop was not honoured. Peak excess RMS separates the cases cleanly: stop / question /
fixture onsets were 0.067-0.141, the false onset 0.018. **Next:** treat an unconfirmed held onset with peak ≥ ~0.04 as
a local stop (cut instead of resume), and make `e2e_echo.sh` check that Woi is still silent 3 s after the stop.

echo28 e28 (2026-11-04). Changes: (1) local stop cut: an onset the server never confirmed whose peak excess RMS is
≥ 0.04 (`TurnPipeline.onsetCutMinRms`; ≥ 0.06 cuts at the 900 ms confirm window, else after the 1.5 s hold) stops Woi
like a confirmed barge-in (reply cancelled, truncated at the heard position; the playback tracker now freezes while
paused) with no new response. Weaker onsets keep hold/resume. (2) An echo/filler transcript after a strong onset no
longer resumes the cut reply. (3) `e2e_echo.sh` reports `stop_honoured` (no speaker audio 0.25–3 s after the stop),
`question_answered` / `question_resumed_old`, `local_cuts`, and pauses/cuts outside the user fixtures. E2E:
`after-e28a` (before (2)): stop 341 ms but **not honoured**. The server did confirm, but the transcript was "어", so the
short-echo rule resumed the reply (948 ms of audio). Question 367 ms: locally cut at 900 ms (peak 0.123), and the late
deferred "How are you?" was answered. 5 fixture turns, 0 self-talk, 0 false pauses/cuts. `after-e28b`: stop 396 ms,
**honoured** (local cut, peak 0.089, 0 ms of audio after it), question 254 ms answered, 5 fixture turns, 0 self-talk,
but **1 false local cut**: an echo onset with peak 0.062 (excess 0.000 at the firing frame) stopped the story about a
minute in. Peak alone does not separate echo from the user (false 0.062 vs real 0.067–0.141). **Next:** a sustained
criterion before cutting, such as frames ≥ 0.04 in the run, or near-end energy while paused (Woi silent, after the
~450 ms echo tail).
