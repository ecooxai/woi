# Woi E2E QA report — iteration 3 (2026-11-02)

## Status (2026-11-05)
Audit of the bugs below against main (code, unit/widget tests, git history). No audio E2E was run for it (PipeWire hung), so
behaviour that only shows live is marked accordingly. Paths are under `app/`.

| # | Bug | Status | Evidence |
|---|---|---|---|
| 1 | gpt-live phantom user bubble, transcripts shifted | Fixed | d1b7434 (transcripts bound by item id / turn key); test/live_webrtc_backend_test.dart:175 |
| 2 | Image/text viewer windows black | Fixed (live only) | 6523729 (runner clears GLX context before FlView realize), e8e0a27 (video CPU decode without DRI3); iter-4 QA in docs/PLAN.md:31 |
| 3 | Barge-in > 500 ms | Fixed, needs audio re-check | 16f8442 + later barge-in/kws work; iter-4 E2E live 438 ms / direct 232 ms (docs/PLAN.md:31); a short "stop" missed by server VAD is still lost ~1 in 3 (docs/PLAN.md:39) |
| 4 | gpt-live typed messages never answered | Fixed | 16f8442; test/live_webrtc_backend_test.dart:277 |
| 5 | Compaction never below threshold | Fixed | 340b90c (per-backend accounting; gpt-live counts only the latest image) + screenshot tiers 44e6f6d/4a76111; test/context_manager_test.dart:138, test/image_tiers_test.dart |
| 6 | Claims success without acting | Mitigated (prompt), needs E2E | ac642ea (no success claims before tool results, real outcome voiced); lib/core/voice/live_webrtc_backend.dart:857 |
| 7 | Luna invents paths (/home/oai) | Fixed | 46999e6 (cwd validated, real HOME passed to delegates); test/tool_registry_test.dart:193 |
| 8 | Idle "Stop" delegated | Fixed | 16f8442 (stop phrases handled locally, delegations declined); test/turn_pipeline_test.dart:1196, 1221, 1254; test/live_webrtc_backend_test.dart:351 |
| 9 | Video opens in external VLC | Fixed | 46f2d9e (embedded fvp viewer, no external players); test/ui/video_viewer_test.dart |
| 10 | Approval dialog doesn't raise/focus Woi | Fixed | bce7bfd (GTK present + xdotool windowactivate + cue); lib/platform/window_attention.dart, lib/ui/app.dart:42; test/platform/window_attention_test.dart:18, test/ui/confirmations_test.dart:150 |
| 11 | Case-sensitive file lookups | Fixed | 46999e6 (`resolveExisting` unique case-insensitive match, lib/platform/linux/linux_files.dart:46); test/tool_registry_test.dart:265 |
| P3 | Esc doesn't close Settings | Fixed | bce7bfd, then Settings became a tab (aeefb7a): lib/ui/screens/home_screen.dart:350; test/ui/view_switch_test.dart:56, test/ui/home_layout_test.dart |
| P3 | Dialogs render over Settings | Fixed / obsolete | bce7bfd popped Settings before approvals; Settings is now an inline tab (aeefb7a), so a dialog over it is an ordinary dialog over the current view |
| P3 | Ctrl+N doesn't leave Settings | Fixed now | Regressed with the Settings tab (aeefb7a): Ctrl+N made a note but stayed on Settings. Now switches to the note view: lib/ui/screens/home_screen.dart:337; test/ui/home_layout_test.dart:367 |
| P3 | Edit proposes a duplicate "buy milk" line | Unclear (model behaviour) | No code-level guard; covered only by the E2E check qa/run_e2e.sh:379 |
| P3 | "VOICE MARIN" shown in gpt-live mode | Fixed | 46999e6 (gpt-live has its own voice setting, cove, and the label shows it) |
| P3 | Narrow layouts: header icons, ring unit, big thumbnails | Mostly fixed | Header replaced by the tab strip (aeefb7a); ring shows `NN%` (lib/ui/widgets/context_meter.dart:154); thumbnails capped 300x220 (6304a0a, lib/ui/widgets/message_tile.dart:307). Icon centring not re-checked visually |
| P3 | Filler and result phrases repeat | Mitigated (prompt), needs E2E | ac642ea (single acknowledgement); lib/core/voice/live_webrtc_backend.dart:857 |
| P3 | Model calls the app "Aurora" | Fixed (prompt) | ac642ea; lib/core/app_controller.dart:52; test/live_webrtc_backend_test.dart:337 |
| P3 | Stray `2` + backspace before typed text | Fixed | e0ee81d (key-ups instead of --clearmodifiers); test/linux_input_args_test.dart:5 |
| P3 | Relative paths resolve against $HOME | Fixed | 46999e6 (workspace dir = launch dir unless $HOME or /); test/files_test.dart, test/tool_registry_test.dart:253 |

Still open or unverified, all needing a live/audio run: 3 (short-stop recall), 6, the duplicate edit line, the filler
repetition, and a visual check of the narrow header.

**Build:** release HEAD `bac1a82`, Linux X11 :0. Harness: `qa/run_e2e.sh`. Fixtures play through a PipeWire virtual mic
(`qa_virtual_mic`). The app runs with `HOME=/tmp/woi-qa-sandbox`, and click/type actions target an xterm.
Screenshots: `qa/shots/`. Raw output: `/tmp/woi-qa-out-run{2,3}`.

## Summary
| Area | Result |
|---|---|
| gpt-live fixtures 01–10 + reject | 7 pass, 2 partial, 2 fail out of 11 |
| Direct subset (hello, click, type, bash, show) | 4/5 (viewer black) |
| Barge-in ≤500 ms | FAIL (live 2693 ms, direct 1622 ms) |
| Compaction @2000 | banner OK, session continues; never gets below the threshold |
| Extra (image, tone, typed text) | 0/3 |
| **Core pass rate** | **11/19 = 58%** |

| Latency, end of playback → first audio (ms) | n | min | median | max |
|---|---|---|---|---|
| gpt-live voice | 18 | 863 | 1752 | 2481 |
| Direct (gpt-realtime-1.5 at the time) | 5 | 1395 | 3178 | 4646 |
| gpt-live connect | 1 | | 2399 | |

## Bugs
### P1
1. **gpt-live: a phantom user bubble every turn, and transcripts shifted by one turn.** Each saved utterance carries the next turn's text. Direct mode is fine. (`live_01_hello.jpg`, `compact_final.jpg`)
2. **The image and text viewer windows render solid black** in both modes, while the model says "it's on your screen". (`media_13_viewer_black_screen.jpg`)
3. **Barge-in doesn't stop playback in time:** 2693 ms (live) and 1622 ms (direct) against a 500 ms target. A stray "there." bubble appears afterwards. (`live_barge_after.jpg`, `direct_barge_after.jpg`)
4. **gpt-live: typed messages never get a reply.** The text is appended to the context, but no response is requested, so the app sits at "Thinking..." forever. (`live_15_typed_text.jpg`)
### P2
5. **Compaction never gets below the threshold.** Screenshots are counted at 765 tokens each and never summarised, even though gpt-live sends no images. The ring shows a bare "100", and the popover opens by itself.
6. **The assistant claims success without acting** (show README with no tool call; fixture 08 says "saved" with no file written).
7. **The luna delegate invents paths** (`/home/oai`), giving a misleading ProcessException. Validate the cwd and tell the delegate the real $HOME.
8. **An idle "Stop" is delegated,** and luna presses Escape in the focused window. Handle stop/cancel locally.
9. **Video opens in an external VLC** that keeps running after Woi closes.
10. **The approval dialog doesn't raise or focus Woi,** so Enter/Esc go to another window.
11. **File lookups are case-sensitive** (readme.md, demo.MP4): a red card first, then success after list_dir.
### P3
- Esc doesn't close Settings; dialogs render over Settings; Ctrl+N doesn't leave Settings.
- The edit proposes a duplicate "buy milk" line.
- "VOICE MARIN" is shown in gpt-live mode (actual voice: cove); Settings lists only realtime voices.
- Narrow layouts: header icons off-centre, the context ring has no unit, and screenshot thumbnails dominate user bubbles.
- Filler and result phrases repeat ("On it, running that now. Thanks, I'm running it now.").
- The model calls the app "Aurora" (the WM's name).
- Direct mode types a stray `2` + backspace before the text.
- Relative paths resolve against $HOME, not the launch directory.

## How to run
    qa/run_e2e.sh                                    # builds HEAD into /tmp/woi-qa, all phases
    PHASES="media" QA_BIN=/path/to/bundle/woi qa/run_e2e.sh
