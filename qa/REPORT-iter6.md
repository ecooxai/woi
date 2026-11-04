# Woi QA — iteration 6 (2026-11-03)

Release build of HEAD on the nested display :11 (Xephyr + openbox, Mesa llvmpipe), with a PipeWire virtual mic.
Harness: `QA_DISPLAY=:11 qa/run_e2e.sh`. Output is in `/tmp/woi-qa-iter6/` and perf data in `/tmp/woi-perf-iter6/`.

**Total: 43/46.** All 3 failures are HTTP 429 from the ChatGPT account's weekly usage limit, not app bugs.
gpt-live, delegation (gpt-6-luna/sol) and compaction (luna) were blocked, so the voice phases ran on Direct realtime (gpt-realtime-2).

| Phase | Result | Response latency |
|---|---|---|
| gpt-live connect | FAIL (429) | – |
| Fixtures 01–15 + barge-in (direct) | 15/16; 08 complex task fails because delegation hits the 429 | median 3.2 s; barge-in stop 69 ms |
| Direct subset | 6/6 | median 2.3 s |
| Compaction | 10 turns pass; the summary step fails (429) | 1.3–1.5 s |
| Media (image/audio/video in-app) | 5/5 | 1.1–1.3 s |
| New features (typed turns) | 6/6 | 1.2–1.9 s |

New-feature checks:
- **Camera:** "what do you see" named what was on the test card.
- **send_keys:** select all + copy in the xterm, verified with xclip.
- **Note edit:** auto-applied after 5 s, and "undo that" removed it.
- **Video:** "what's happening now" described the current frame.

## Fixes
- **Black video on Xephyr.** There is no DRI3, so mdk's VAAPI frames can't be shared with EGL. Without DRI3 the app now decodes on the CPU (e8e0a27).
- **NVIDIA GLX driver loaded next to Mesa** because of the PRIME env vars in the user's shell. On a server without DRI3 the runner re-execs pinned to Mesa and restores the vars for children (d310f07).
- **Video CPU.** Video windows now use Skia, the texture is capped at the video size, and freed memory is returned to the OS (abba717, bb8a082). On :11, 720p went from 471% to 305% CPU.
- **"Connecting…" after a failed voice session** now shows Offline. Voice session and compaction failures are now logged (6d32176, beca18b).
- **Earlier in the iteration:**
  - The status settles after fast-path turns.
  - gpt-live auto-reconnects.
  - The muted mic ignores the server's speech start.
  - A muted call never creates an enabled mic track.
  - The camera is thinned to ≤8 fps.

## Performance on :11 (200-message chat seeded)

| Scenario | CPU | RSS | PSS |
|---|---|---|---|
| Idle | 3.4% | 306 MB | 267 MB |
| Scroll | 321% | 354 MB | 308 MB |
| Video 720p | 305% | 525 MB | 468 MB |
| Camera | 81% | 415 MB | 357 MB |

Idle without a seeded chat: 290 MB RSS / 251 MB PSS. About 78 MB of that is the llvmpipe driver, which a real GPU doesn't load.

## Gaps
- gpt-live, delegation and compaction need a re-test after the quota resets (~2026-11-05).
- Scroll and video still use about 3 cores under software rendering.
- One terminal test flaked under full-suite load.
