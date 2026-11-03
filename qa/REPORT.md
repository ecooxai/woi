# Woi E2E QA report — iteration 3 (2026-11-02)

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
