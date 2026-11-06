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
- Iter 12 (stop while Woi speaks: talk-in-pause local cut (mic energy after the 450 ms echo tail) + no cut on peak alone, verified live with server confirmations ignored — questions cut locally 0–200 ms, 0 false local cuts; quiet false pauses resume in ~0.7 s instead of 2.4 s; truncation position frozen during pause; on-device stop-word spotting (sherpa_onnx KWS, 5 MB model, raw pre-AEC mic + reference veto on Woi's own audio, threshold 0.4) as backstop when the server misses — 1/2 live rescues at ~1 s, 0 false kws cuts after fixes; QA switch WOI_QA_IGNORE_SERVER_SPEECH; E2E reports stop_honoured/question_answered/kws_*/CPU; incremental markdown highlighting + span cache (behaviour-identical, CPU unchanged ~38% on llvmpipe); 612 tests): 92/100. Gaps: short "stop" when server VAD misses still lost ~1 in 3 of those cases (KWS recall ~2/3, English only; Chinese model 36 MB not bundled); typing ~38% CPU on software GL (needs block editor); +37 MB Linux bundle; KWS untested on Android device; media-route voice barge-in unverified on device; video viewer ~290% on llvmpipe; gpt-live untested since quota; APKs debug-signed.

- Iter 13 (verification + reliability, 2026-11-05): full desktop E2E on a private hardware-free PipeWire 33/34 (talk, click, type, bash, viewers, edit confirm/reject/undo, barge-in 166 ms, screenshot Q&A, camera, copy keys, luna compaction banner); 08 delegate now always saves requested scripts (prompt + one retry guard) 6/6 live; click "center of the screen" via a position param / the user's words, 3/3 at 2.4–2.9 s (was 6.3 s, 1/3); warm keep-alive, reduced-tier JPEG. Perf: desktop idle 1–2% CPU, busy avg 13–17%, viewer engine holds ~145 MB on software GL after close (not a leak, deferred). Gaps: phone double-reply/screenshot-skip not verified on device, host PipeWire hang blocks the live desktop app, video-frame Q&A 5.8 s (model time), standby notification visible. Score: 93/100.
## Spec: image compaction (user requirement, 2026-11-02)
When compaction runs, screenshots/images are tiered by recency:
- Newest 3 images: unchanged (full resolution as sent).
- Older images: downscaled to 1/2 of original width and height (re-encoded, e.g. JPEG/PNG), still sent as images.
- Very old images (default: beyond the newest 3 + next 5, i.e. older than the 8th newest; configurable): replaced by a short
  text description generated by gpt-6-luna (what was on screen, key text, app/window), stored on the message.
- Settings: "keep full images" (3), "keep small images" (5), "small image scale" (1/2).
- Direct mode: apply on the live server session by conversation.item.delete + re-insert of the smaller image / text item,
  between responses, never interrupting playback. gpt-live: applies to the context sent to the DelegationExecutor and
  to the reconnect startup context.
- UI: transcript keeps the original image locally (tap to view), shows a badge "sent as 1/2" or "described: …";
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
- 2026-11-05 (user): the assist panel shows the same UI as the main app. HomeScreen's body is now `WoiTabs`
  (home_screen.dart); the panel embeds it (narrow layout, Note / Chat / Terminal / Settings + input bar, no duplicated
  widgets) inside the unchanged sheet (scrim, 60% → 95% drag, fling/drag-down dismiss, moves up with the keyboard).
  Thumbnail / open full app / close sit at the end of the tab row, which is also a drag handle. Same engine and
  AppController (the panel is a route above HomeScreen). The panel starts on Chat and remembers its own last tab for
  the run (separate from the app's tab; voice view changes still switch it). Desktop check:
  `WOI_DEBUG_ASSIST_PANEL=1` shows the panel over a plain background.

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

### Perf (perf25): where a keystroke goes
- Method: release, :11, 1600x900, `WOI_FRAME_STATS=1`, the seeded long note (803 words / 4.3k chars, ~80
  highlighted list lines) focused on the left (checked by screenshot), 10 keys/s for 30 s.
- Baseline (1 clean sample, load 14.6): CPU 35.7%, ~15 frames/s while typing = ~1.5 frames per key (keys +
  caret blink), so the frame count is already close to the minimum. Per frame: build+layout ~9-13 ms on the UI
  thread (idle frames: ~2-4 ms), raster ~11-13 ms. The cost is per-frame work on the whole note, not extra frames:
  every key re-runs `highlightMarkdown` on the whole text, rebuilds every TextSpan and lays out the whole single
  paragraph, and the editor layer (the visible text) is re-rasterized on software GL.
- Fix so far (commit perf25): `MarkdownEditingController.buildTextSpan` returns the identical cached span when
  text / AI range / glow / composing / style are unchanged, so EditableText rebuilds that do not change the text
  (focus, selection, caret) skip span building and relayout. Small and safe; it does not touch the per-key path.
- After-numbers NOT measured: the parallel voice E2E window on :11 covered Woi's window, so the after/base2
  samples (1.0% / 1.0%, 0 frames) typed into nothing and are invalid. Rerun on a free display with a
  window-raise + screenshot check before typing.
- Next (needed to reach <15%): incremental highlighting (re-highlight only from the edited line to the next
  line whose fence state matches; keep the other lines' TextSpans) and splitting the editor's text into
  per-block paragraphs so a key lays out / rasters one block, not the whole note.

### Perf (perf26): incremental highlighting, measured
- Change: `MarkdownEditingController` caches each line's highlight + TextSpan by (line text, fence state before
  it, trailing newline). A key re-highlights only the line(s) whose key changed (an edit that opens/closes a
  fence re-highlights the lines up to where the fence state matches again) and reuses every other line's TextSpan
  instance; AI tint / composing split only the lines they touch. Output is char-for-char identical to
  `highlightMarkdown` (tests: start/middle/end edits, fence opened/closed by an edit, paste, undo, AI/composing).
- Method: release, own Xvfb :12 1600x900 + openbox, sandbox HOME (direct backend, push-to-talk idle), a seeded
  781-word / 80-line note (headings, lists, inline code, a code fence), editor focus checked by screenshot,
  `xdotool type --delay 100` (10 keys/s) for 30 s, CPU from /proc utime+stime of the woi pid, `WOI_FRAME_STATS=1`.
  Interleaved base/new; the host was shared (load 7-16), so the noise is large.

| sample | arm | CPU % | load | build ms/frame (10 s windows) | raster ms/frame |
|---|---|---|---|---|---|
| 1 | main (fa70143) | 40.4 | 15.7 | 7.6 / 35.4 / 28.3 | 8.1 / 21.2 / 19.9 |
| 1 | perf26 | 37.5 | 13.3 | 30.5 / 29.5 / 9.3 | 26.2 / 19.8 / 8.0 |
| 2 | main | 31.6 | 8.4 | 7.9 / 11.1 / 9.9 | 8.4 / 7.8 / 8.6 |
| 2 | perf26 | 35.3 | 7.3 | 9.2 / 13.6 / 11.6 | 8.7 / 9.1 / 10.1 |
| 3 | main | 45.6 | 9.6 | 15.8 / 22.3 / 18.1 | 15.8 / 13.6 / 14.1 |
| 3 | perf26 | 41.4 | 9.1 | 13.0 / 20.7 / 14.1 | 12.9 / 14.0 / 11.9 |
| avg | main / perf26 | 39.2 / 38.1 | | | |

- Finding: no measurable win (difference well inside the load noise; ~13-16 frames/s in both). Re-highlighting
  the whole note was not the dominant per-key cost; what remains per key is laying out the whole note as one
  paragraph (RenderEditable relayouts the full TextPainter whenever any span differs) and re-rasterizing the
  visible text layer. The change is still correct and removes the O(note) regex pass and span allocation.
- Raster/caret: the editor already sits in a RepaintBoundary, and RenderEditable's caret / selection painters are
  their own repaint boundaries (`_RenderEditableCustomPaint.isRepaintBoundary`), so a caret blink or move does not
  repaint the text picture. No cheap raster fix left: each key changes the single text picture, which software GL
  re-rasterizes in full.
- Needed for <15%: split the editor into per-block paragraphs (one RenderParagraph/EditableText-like box per
  Markdown block or line group, each in its own repaint boundary, with a shared selection/caret/IME layer), so a
  key lays out and re-rasters one block and unchanged blocks stay raster-cached. That is the block-editor rewrite
  (custom selection across blocks, IME composing, undo, scroll-to-caret); not done here.

### Android smoke test (v0.10.0+10 arm64 release, MI 8, 2026-11-04)
- Installed over versionCode 1 → 2010 with `install -r` (no signature issue); freeform task bounds (0,0)-(1080,1512) = top-left,
  full width, 70%; backend Direct realtime gpt-realtime-2.1; Stop word detection toggle on (Audio → Advanced).
- `kws: armed ▁ST O P @STOP (mic 0.40, ref 0.10)`; 30.6 s story containing "stopped" played to the end, 0 kws hits/cuts.
- CPU while speaking 33–41% of a core (162% spike at model init), RES ~310 MB.
- Caveat: mic delivered exact zeros (125/125 chunks) the whole time, incl. during Woi's speech (phone-route AEC/NS gating a
  quiet room), so the 0 false cuts is weak evidence. Android has no raw pre-AEC mic, so KWS sees the AEC'd stream (on Linux
  the AEC removed the "s" of "stop"). Needs a human "stop" on the phone while Woi talks, in both phone and media routes.

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

echo29 e29 (2026-11-04). Changes: peak alone no longer cuts. 450 ms after the pause (`pauseEchoTail`) the raw mic
RMS is measured for 250 ms. If at least 80 ms of it is ≥ floor + 10 dB (and ≥ -50 dBFS), the user is still talking:
local cut about 700 ms after the onset. A short word that is already over by then is cut only if the peak is ≥ 0.06
**and** the near-end excess is still ≥ 0.015 at the firing frame (echo false onsets 0.000/0.062 and 0.013/0.018,
real speech 0.018–0.129 at firing). Otherwise a strong onset is held for the server and then resumed, and a weak
one resumes at 900 ms. E2E, two runs alone: `after-e29a`: stop 55 ms, honoured (server confirmed, transcript "嗯。",
stayed stopped), question answered, 5 fixture turns, 0 self-talk, 2 false pauses (resumed; one echo onset with peak
**0.095**, higher than any real stop, but 0.000 at firing, so the old rule would have cut it), 0 local cuts,
0 wrong interrupts. `after-e29b`: stop 355 ms, honoured ("啊。"), question 165 ms answered (the server split it into
"어" + "How are you?", counted as self-talk), 5 fixture turns, 2 false pauses (resumed; peak 0.063 at firing 0.010),
0 local cuts, 0 wrong interrupts. The server confirmed both barge-ins in both runs, so the local-cut paths did not
fire in the E2E (they are unit-tested). **Open:** the firing-excess margin is thin (echo 0.010–0.013 vs speech ≥
0.018). A false pause still costs about 2.4 s of silence (hold); a quiet pause with firing excess < 0.015 could
resume at 900 ms.

echo30 e30 (2026-11-04). Changes: (1) QA switch `WOI_QA_IGNORE_SERVER_SPEECH=1` (read once; no effect when unset):
a server speech start that arrives while Woi speaks is held back with its turn's events until the local rules decide.
They are replayed after a local cut and dropped after a resume. `e2e_echo.sh` now reports which local rule cut,
quiet resumes, holds and wrong interrupts. (2) A quiet pause (0 ms voiced after the tail) with firing excess < 0.015
now resumes right after the measurement (~700 ms) instead of holding ~2.4 s. A server start within 1.5 s of the
onset still cuts. The hold is kept only for ambiguous pauses. E2E, two runs alone with the switch: `local-a`: **stop
not honoured** (7131 ms). The onset fired with peak 0.084 but excess 0.011 at firing, so the short-word rule did not
cut and the quiet pause resumed it. The server never sent a speech start for "stop". Question: local cut, **voice in
the pause** (117 ms voiced, mic peak 0.151), answered. 0 false pauses, 0 false local cuts, 0 wrong interrupts.
`local-b`: **stop not honoured** (7112 ms). No local onset at all and no server speech start. Question: local cut,
voice in the pause (159 ms voiced), stop 200 ms, answered. 1 false pause (echo peak **0.155**, excess 0.013 at firing),
quiet-resumed in 707 ms instead of ~2.4 s. 0 false local cuts, 0 wrong interrupts. **Findings:** the voice-in-the-pause
rule works live (both questions, margin 117–159 ms against 80 ms). The short-word rule cannot be fixed by tuning:
excess at firing is now *inverted* (real stop 0.011 < echo 0.013), and peak overlaps too (echo up to 0.155). Thresholds
left unchanged. A short "stop" said over Woi is caught only by the server (or not at all, as in both runs here). It
needs a different cue, e.g. the onset's spectral or pitch shape against the reference, or a longer post-tail window
for the word's end.

echo31 (2026-11-04): stop-word spotting prototype, offline only. `sherpa_onnx` 2.0.1 (pub, Apache-2.0, Linux/Android
prebuilt; Linux x64 adds libonnxruntime 27 MB + libsherpa-onnx-c-api 4.9 MB) with the English zipformer KWS model
`kws-zipformer-gigaspeech-3.3M-2024-01-01` (int8 encoder+decoder+joiner+tokens 5.3 MB; the zh wenetspeech model is
a separate 36 MB download). Script `app/tool/kws_proto.dart`, fed the six E2E `mic.wav` (local-a/b, after-e28a/b,
after-e29a/b). Note: these captures are the **raw mic before the AEC** (echo at full level), so false alarms are
a worst case. Stop fixture alone: detected. Keyword "stop" only (BPE `▁ST O P`), on the mic: threshold 0.2 → 5/6 stops,
5 false hits in 6 runs; 0.25–0.35 → 4/6, 5 false; 0.4 → 4/6, 3 false; 0.5 → 1/6. Every false hit is Woi's own
"stopped" in the echo (clipping and room smear hide the "-ed"). Adding "wait"/"hold on"/"pause" adds false hits on
"waited" and "stayed". **Reference check:** the same spotter run on what Woi plays (spk.raw), threshold 0.1, fires on
4 of the 5 false hits (never on the user's stop, which is not in the reference). Mic 0.4 + reference veto → 4/6 hits,
0 false; mic 0.2 + veto → 5/6, 1 false in 6 runs. Latency: hit within ~0.4 s of the word's end. CPU: 5–8 % of
one core per stream (two streams while Woi is audible); Silero VAD ~1–2 % but it marks echo as speech (106–235 s
of "speech" per run), so it does not separate echo from the user. Not integrated yet (time box). Plan: one
background isolate with two spotters (mic after AEC at 16 kHz, reference stamped with its play time =
write time + queued ms), run only while Woi is audible or paused; a mic hit without a reference hit in
[T − 2 s, T + 0.3 s] → pause + local cut logged `kws`; setting `stopWordDetection` (default on) + keyword list
(default just "stop"); model in `app/assets/kws/` copied to the data dir on first use (Android assets are not files).
Integrated (echo31 round 2): `sherpa_onnx` is a normal dependency; model (int8 + tokens + MODEL_README, Apache-2.0)
in `app/assets/kws/`, copied to `<dataDir>/kws/` on first use. `SherpaStopWordSpotter`
(`app/lib/core/audio/stop_word_spotter.dart`): background isolate, mic spotter 0.4 + reference spotter 0.1, mic hit
held until the reference covers T + 0.3 s, veto [T − 2 s, T + 0.3 s] (`kwsReferenceVetoes`). Pipeline: fed only while
Woi is playing / paused / in the echo tail (mic after the AEC; reference stamped now + queued ms); a hit while
speaking or paused → `_pause()` + `_localCut('kws ...')` (`kwsCuts`), else ignored (`kwsIgnored`). Settings
`stopWordDetection` (default on) + `stopWords` (default ["stop"], longest-match BPE mapping), Audio → Advanced and
`set_setting stop_word_detection / stop_words`. Linux release bundle +37 MB (onnxruntime 27.0 + sherpa C API 4.9 +
model 5.3). Not yet run live: E2E next.
Live E2E (echo31 round 3, release build on :11, gpt-realtime-2.1 direct, `qa/aec/e2e_echo.sh`). Smoke test: model copied
to `<dataDir>/kws/` on first use, `kws: armed ▁ST O P @STOP (mic 0.40, ref 0.10)`, isolate runs, no errors in any run.
New QA hooks: `WOI_QA_DUMP_KWS_MIC=<path>` (spotter's mic as raw s16 + `.times`; e2e `QA_DUMP_KWS_MIC=1`),
`WOI_QA_KWS_MIC_THRESHOLD`, e2e summary keys `kws_*` and `cpu_pct_speaking_idle` (woi utime+stime per 1 s, % of one
core while the speaker is active / silent); `tool/kws_proto.dart` reads the bundled model names and raw dumps.
Fixes found live: (1) **the AEC eats the "s" of a stop said over Woi** (AEC'd dump: one 200 ms "-top" burst; zero hits
over the whole run even at 0.2), while the raw mic of the same run gives the hit at onset +1.1 s at 0.4. Linux now spots
on a second capture of the source **before the AEC** (`RawMicCapable.openRawMic`, pw-record, only when echo
cancellation is on and stop words are enabled); Woi's own words are left to the reference veto. (2) The reference
stream was never flushed after Woi's last word, so a final "I've stopped." was not decoded and not vetoed: the
reference is now padded with silence up to the mic clock once Woi's audio ended. (3) Reference hits were pruned
10 s behind the *latest written* reference, which runs tens of seconds ahead of playback (server faster than real
time): Woi's "the bell rang once, then stopped" was pruned before it played → false kws cut in kws-c. Now pruned by
the wall clock; reference hits are logged.

| run | mode | build | stop ms | stop honoured | kws cuts / false / ignored / vetoes / ref hits | question ms, answered | false pauses | wrong interrupts | CPU % speaking / silent |
|---|---|---|---|---|---|---|---|---|---|
| kws-a | QA (server speech ignored) | AEC mic | 425 (short-word cut +1.11 s) | yes | 0 / 0 / 0 / 0 / – (stop missed) | 391, yes | 0 | 0 | 34.1 / 20.9 |
| kws-b | QA | raw mic | 22 (pause at onset +0.36 s, **kws cut +1.03 s**, lag 13 ms) | yes | 1 / 0 / 1 / 0 / – | 233, yes | 1 | 0 | 40.2 / 22.7 |
| kws-c | normal | raw mic, padding | 241 (server) | yes | 1 / **1** ("then stopped", fix 3) / 0 / 0 / – | 273, yes | 1 | 1 (the kws cut) | 37.2 / 24.2 |
| kws-d | normal | all fixes | 391 (server) | yes | 0 / 0 / 0 / 0 / 1 | 295, yes | 1 | 0 | 33.6 / 18.7 |
| kws-e | QA | all fixes | 7173 (missed) | no | 0 / 0 / 0 / 0 / 2 | 307, yes | 2 | 0 | 36.7 / 20.5 |

Threshold: **mic stays 0.4**. Offline sweeps on the raw mic: kws-b 0.5–0.2 all give the stop and one late "stopped"
(vetoed by the padded reference now); kws-c 0.3 and below add a hit on Woi's echoed "then stopped"; kws-e's stop is not
found even at 0.2 (the word lands on loud echo), and 0.25 adds an echo hit. Lower thresholds buy no recall here, only
false hits. Recall over speech with the raw mic: 2 of 3 stops (kws-b live, kws-a offline), cut ~1.0–1.1 s after the
onset (the word ends ~0.5 s in; the model fires ~0.4 s after the end + 0.3 s veto wait), so kws is a backstop behind
the server (~240–390 ms) and the local pause, not a faster path. CPU: no kws-off baseline was run; the app on :11
(software GL) uses ~34–40 % of a core while speaking vs ~19–24 % silent (UI animation + audio + two spotters).
Known: pause/resume re-writes the unheard audio, so the reference sees it twice (two stamps; the resumed one is the
right one; extra stamps can only veto, never cut).

### Android: keeping the accessibility service on (MI 8, LineageOS 22.2 / Android 15)

Findings: before the fix the setting was `enabled_accessibility_services=null`, `accessibility_enabled=0`; the
last change was the 13:16:57 install (`am_kill … stop dev.woi.woi due to installPackageLI`, release build
versionCode 2010). There was no Woi crash in the logs and no battery kill (Woi was not on the deviceidle whitelist).
With this build neither a same-signature update nor `am force-stop` dropped the service: the system rebound it
by itself in about 1 s. So it is most likely dropped by some installs (e.g. release/debug swaps, downgrades) and
by restricted settings (an ACCESS_RESTRICTED_SETTINGS rejection was recorded that morning), not by crashes.
Mechanisms (WoiA11yKeeper.kt):
- With `WRITE_SECURE_SETTINGS` (granted once: `adb shell pm grant dev.woi.woi android.permission.WRITE_SECURE_SETTINGS`)
  Woi appends `dev.woi.woi/.WoiAccessibilityService` to the list (never removes or reorders others) and sets
  `accessibility_enabled=1`: after an update (MY_PACKAGE_REPLACED), on boot, when the system binds the assistant
  service (also after a force-stop), on app start, on assistant activation, on `accessibilityStatus`, when a screen
  action finds the service off, and every 30 s while the foreground service runs. Logs `a11y re-enabled (<reason>)`.
- Every service callback (events, connect, gesture/screenshot callbacks, posted aside blocks, node walks) is wrapped
  so an exception is logged instead of killing the process; nodes are recycled below API 33.
- `android:isAccessibilityTool="true"` (Android 12+, ignored before).
- Settings → Android → Screen control: state, "Accessibility settings", and a one-time battery-optimization
  exemption prompt.

## Pre-connect mic capture (mic34, 2026-11-05)

User: on app start / Android assist activation, connect AND record at once; push the recorded audio when the session is
up, then keep streaming. Before: `TurnPipeline._connect` opened the mic only after `backend.connect()` returned
(WS handshake + `session.update` ack, ~1–3 s), and every reconnect closed it first, so the first words were lost.
Now (`lib/core/pipeline/pre_connect_buffer.dart`, `turn_pipeline.dart`):
- The platform mic opens right after the backend is created, before `connect()`; a platform mic stays open across
  reconnects (connection drops, session expiry, settings that need a new session) and its post-AEC chunks go to a
  `PreConnectBuffer` while status != connected (hands-free, or push-to-talk while held; the mic button is enabled while
  connecting). Cap 15 s, oldest dropped.
- Ready = `connect()` returned (WS: after `session.updated`). In the same synchronous step as the switch to connected
  the buffer is flushed via `sendAudio` (`input_audio_buffer.append`) in ≤200 ms frames, so no live chunk can come in
  between: no gap or duplicate at the seam. Leading silence > 1 s is trimmed to 300 ms before the first voiced chunk
  (level gate: >= -50 dBFS and floor + 10 dB).
- Speech in the buffer grabs the screenshot then; it is attached to the turn the server opens after the flush
  (instead of the 1.2 s timer). The flushed audio also goes into that turn's clip.
- Status shows "Listening… connecting" / "Listening… reconnecting" (cyan) while capturing.
- The mic closes when an auto-reconnect gives up or hits the usage limit, on mute and on suspend. A failed first
  launch connect closes it until the retry starts.
- Gap: WebRTC (gpt-live) captures through its own media track, created inside `connect()` (getUserMedia before the
  offer), so it records from the start of the call setup, but audio before the RTP path is up is not buffered.

### Assist activation: mic from the gesture (mic37, 2026-11-05)

Before (phone log, release 0.11.0, Direct realtime over WS): assist shown → `voice: resuming` 12 ms (the overlay calls
`appIsResumed`, so the lifecycle event does arrive) → `mic started` 4.4–5.3 s later, i.e. only after connect.
Now: `WoiSession.onShow` (overlay) calls `WoiAudio.startEarly`, which starts AudioRecord at once (last route/AEC from
prefs) and buffers chunks natively; Dart's mic open adopts that recorder and gets the buffered chunks first, then live
(same ordered stream), and mic34's `PreConnectBuffer` holds them until connected and trims leading silence. Not adopted
in 10 s or panel hidden first: dropped. `AppController.assistantShown` (overlay event) also resumes a suspended
session and unmutes a muted mic directly, without waiting for the lifecycle event or the screenshot.
Logs: `early mic: recording from activation`, `early mic: adopted after N ms, flushing K chunks (M ms)`,
`pre-connect: flushed M ms`.
Measured on the MI 8 (debug build, 2026-11-05): warm (suspended) gesture → mic recording 387 ms (was ~4.4 s, after
connect), connect end +2.5 s; cold (force-stopped) gesture → mic recording 367 ms (before the engine: engine +1.6 s,
Dart mic open +4.5 s adopts 5.7 s of buffered audio, connect end +9.2 s; before this change the mic opened only after
connect). The ~370 ms is native (setMode IN_COMMUNICATION + AudioRecord). Open: with another app's media playing,
entering call mode re-routes that playback to the earpiece and the HAL took 4.8 s (main thread, also delays the panel).
