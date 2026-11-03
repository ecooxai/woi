# Woi QA — iteration 4

Release build of HEAD, real :0 desktop, PipeWire virtual mic and speaker
(`qa/run_e2e.sh`).

- Full run: `9b72f32`, 2026-11-03 08:12–08:24, output in `/tmp/woi-qa-out-iter4f`.
- Compact phase re-run: `19eba93` (harness-only change), output in `/tmp/woi-qa-out-iter4g`.

**Core: 17/19 in the full run. 18/19 with the compact re-run.** Extras: 3/3.
Before this iteration, iter3 was 11/19.

## Pass table

| Mode | Cases | Result |
|---|---|---|
| gpt-live | 01 hello, 02 click, 03 type, 04 run ls (approve), 05 show readme, 06 edit (approve), 06 edit (reject), 07 what's on screen, 08 complex task, 09 play video, 10 stop | **11/11** |
| direct (realtime-2) | 01 hello, 02 click, 04 run ls, 05 show readme | 4/5 (03 type FAIL) |
| barge-in | live 438 ms, direct 232 ms (target ≤500 ms) | **2/2** |
| compaction banner | full run FAIL; re-run PASS after 8 turns | 0/1, then 1/1 |
| extras (live) | 13 show image, 14 play tone, 15 typed text | 3/3 |

## Latency (speech end → first reply audio, ms)

| Mode | n | min | median | max |
|---|---|---|---|---|
| live | 13 | 946 | 1767 | 2601 |
| direct | 5 | 1304 | 3530 | 8046 |
| compact | 6 | 773 | 1102 | 2299 |

Other measurements:
- live session.started: 4307 ms.
- Typed message → reply audio: 2897 ms.
- 08 complex task: 37.5 s in total, including two approval dialogs.

Barge-in history:

| Run | live | direct |
|---|---|---|
| iter4c | 2138 ms | not measured |
| iter4d, before the viewer fix | 2758 ms | 209 ms |
| final | 438 ms (≈230 ms detect + ≈207 ms mute → silence) | 232 ms |

## Fixes and root causes

1. **Barge-in detector** (`barge_in.dart`).
   - The echo gain was learned from the quiet rising edge of the user's own speech, which raised the trigger threshold.
   - The 40 ms closure in "stop" reset the 120 ms voiced counter.
   - Fix: echo is learned only below half the threshold; onset is 80 ms; gaps up to 60 ms are bridged.
2. **Live mute ineffective after any viewer opened** (`linux/runner/my_application.cc`).
   - Re-registering plugins for every viewer engine installed an empty FlutterWebRTC instance on the main engine's channel.
   - Fix: viewers now register only desktop_multi_window and fvp.
3. **08 complex task.** The app was correct. The harness answered only one of the two approval dialogs (write_file, then a syntax-check run).
   - Fix: the harness handles N dialogs.
4. **14 play tone.** The fast path accepted only one noun ("the *audio file* tone dot wav" has two), so it fell back to `find`.
   - Fix: the fast path now accepts up to two nouns.
5. **Orphaned pw-record keeps the mic open.** The Dart VM ignores SIGPIPE, and the ignored signal survives exec, so capture children outlived a killed app.
   - Fix: capture is now spawned via `env --default-signal=PIPE`.
6. **Harness changes.**
   - 09 passes only with the in-app viewer.
   - 07 must name something actually visible.
   - A 0 ms barge is a FAIL.
   - Changes to the default audio devices made externally are detected and reverted.
   - The compact phase talks until compaction applies.

## Remaining failures

- **direct 03 type.** `type_text` succeeded, but the target window was not focused, because the desktop was in use during the run. This is environmental. Future runs use the nested display :11.
- **compaction banner in the full run.** It was skipped by the minGain gate, as designed. It passes with the longer scenario.
