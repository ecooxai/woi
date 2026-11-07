# Separate click-lab window

From the Woi repository:

```sh
python3 qa/click_bench/lab/launch.py --display :0
```

The launcher finds an existing Woi research virtual environment with `websockets`, starts a loopback server on a free port, and opens an isolated Chromium app window. It stores its own PIDs, URL, logs, and profile under `qa/out/click_lab/`. Running it again reuses its healthy server and window. It does not change the main Woi process or other browser profiles. Pass `--python path/to/python` or `--browser path/to/chromium` when needed. `--no-browser` starts the server only; `--headless --out qa/out/click_lab/ui_check` creates an isolated browser for UI verification.

## Using the surface

The top panel is a deterministic pixel image with real local HTML button hit regions. **Randomize** changes the seed; **Size** changes the transmitted image dimensions. The preview is fitted to the window, while returned coordinates always refer to the original image pixels. Browser-reported screen dimensions and device pixel ratio are shown separately.

Type a current instruction such as `Click the Cedar button` or `Move the pointer to the Cedar button. Do not click.` Choose a model radio and send. Audio/realtime models receive this text instruction through their own transport. **Test all available models** runs one fresh trial per eligible catalog entry on the same image and instruction. Access and capability are verified by the trial, not assumed from catalog presence.

The captured PNG excludes pointer/result markers. Each result's **View image** opens the exact transmitted image. Returned coordinates are dispatched only inside the local surface; a move emits no click. The page records actual button events independently of the requested target and never uses expected coordinates to correct model output.

Automatic scoring requires one recognized button label. Unrecognized or ambiguous instructions are unscored. **Scoring and request details** allows an explicit expected button and action; those values are only used by the local scorer and the separate result log. No target list, expected rectangle, prior request, or history is sent to the model. Layout changes are disabled during a trial or comparison, and the executor rejects stale captures.

**Export JSON** includes captures, per-trial responses, expected geometry, actual click/move events, usage, latency, and summary counts. API errors, malformed output, misses, and unscored trials remain distinguishable. The displayed scored hit rate excludes API/response errors; those have a separate count.

## Local automation contract

`window.ClickLab` is intentionally available for local browser QA. Its target geometry is not included in `/api/trial` requests.

- `generateLayout({seed,width,height,count})`: pure deterministic layout generator.
- `setLayout({seed,width,height,count})`: render a new layout; rejects during a trial.
- `getLayout()`: snapshot dimensions, seed, revision, and local target boxes.
- `capture()`: clean PNG, width/height, screen metadata, and revision.
- `getState()`: models, selection, busy flags, summary, and trial results (PNG data omitted).
- `setInstruction(text,{expectedTargetId,expectedAction})`: set the current input and optional local expected values (`auto` or `none` accepted for the target).
- `selectModel(id)`, `refreshModels(true)`, `runTrial({model,instruction,expectedTargetId,expectedAction})`, `runBatch()`.
- `getEvents()`, `clearEvents()`, `getLastRequest()`: inspect local events and the exact isolated request.
- `executeForTest({action,x,y}, snapshot?)`: execute a local calibration action without an API request or benchmark result; checks current snapshot revision and dispatches real local DOM input events. Returned coordinates are neither clamped nor corrected.
- `exportData()`, `showLastCapture()`.

`qa/click_bench/lab/API.md` defines the server protocol. The backend owns authentication, fresh sessions, model discovery, and private evidence persistence.

## Confirming models against the actual lab UI

The real visible app is recorded in `qa/out/click_lab/runtime.json`; its dedicated Chromium profile contains `DevToolsActivePort`. A separate headless instance can be used to avoid disturbing the user's window.

1. Call `ClickLab.setLayout({seed,width,height,count:12})` and retain the returned target list locally. Supported presets include `2560 × 1440` for image-detail tests. Each target has `id`, `label`, `x`, `y`, `w`, `h`, and `size`; pixel rectangles refer to the canvas image.
2. Capture with `ClickLab.capture()`. Send only its PNG, width/height and three-field `screen` object, plus the current instruction/model/new request ID, to `/api/trial`. Do not pass the local target list, expected action, seed, revision, or prior responses.
3. Before applying the returned point, ensure the layout revision is still the captured revision. Scroll `#board-frame` into view, read `document.querySelector('#board').getBoundingClientRect()`, and map the model's image-pixel point to browser CSS coordinates:

   ```text
   clientX = canvasRect.left + modelX / capture.width * canvasRect.width
   clientY = canvasRect.top  + modelY / capture.height * canvasRect.height
   ```

   CDP `Input.dispatchMouseEvent` uses CSS coordinates. Do not multiply by DPR. Canvas PNG dimensions stay explicit and unchanged when browser DPR changes.
4. Move the CDP pointer outside the surface, then call `ClickLab.clearEvents()`. Dispatch `mouseMoved` at the mapped point. For `click`, also dispatch `mousePressed` and `mouseReleased` with the left button. For `move`, dispatch no press or release.
5. Read `ClickLab.getEvents()`. Actual hit regions are `button.target-hitbox[data-target="button-N"]`, with `aria-label` equal to their visible label. The returned event fields are `type` (`pointermove`, `mousedown`, `mouseup`, `click`), `target_id`, screenshot-pixel `x`/`y`, `source`, and `isTrusted`. CDP input is trusted and recorded as source `manual`; the normal app's synthetic controlled execution is source `model` and untrusted. Ground-truth checks should use the observed event's target ID, not substitute an expected target.
6. Keep errors, wrong actions, wrong points and unscored trials separate. Store actual raw response metadata, including the backend's image-detail setting, with each case. The UI's expandable latest-response details preserve that metadata unchanged.

Use identical clean PNGs and instructions for paired model comparisons. The main canvas never includes previous result markers; those are drawn on a separate overlay canvas. A fresh layout resets the overlay. The local API prevents layout mutation during an in-flight UI trial.

## Selected-model click-all runs

`await ClickLab.runClickAll()` clicks every current target with the selected model, one fresh request per target. It locks the current layout and model and uses only `Click the LABEL button.` as each current instruction. The named run, complete target order and local scoring metadata are never added to `/api/trial`.

`ClickLab.stopBatch()` requests a stop after the current request. `ClickLab.getState().clickAllRun` returns the latest summary; `clickAllRuns` returns all local run summaries. A stopped run retains its completed attempts. A second send, model comparison or click-all run is rejected while a batch is active.

Summary fields include `planned_buttons`, `completed_attempts`, `successful_clicks`, `failed_attempts`, `accuracy`, `missed_clicks`, `invalid_actions`, `request_errors`, `local_errors`, `latency_sample_count`, `latency_excluded_attempts`, `mean_send_to_click_ms`, `min_send_to_click_ms`, `max_send_to_click_ms` and `total_wall_ms`. `ordered_target_ids`, `ordered_target_labels` and `trials` are local evidence. Unattempted targets do not enter the score denominator.

Each normal trial records `request_sent_perf_ms`, `request_sent_at`, `timing_clock_origin_ms`, `click_dispatched_perf_ms`, `click_dispatched_at` and `send_to_click_ms`. The start is immediately before `fetch`; the end is immediately after the observed local click's synchronous dispatch returns. This excludes subsequent result persistence. Local events include `performance_ms` and `event_timestamp_ms` for checking the timeline. `api_latency_ms` is the backend's API measurement and `response_wall_ms` is the browser's request/response wait; neither is substituted for send-to-click timing.

Timing samples include wrong-target clicks. An API error, invalid output, out-of-bounds point, stale response or non-click action produces no click-time sample. A valid zero-duration measurement is distinct from a missing measurement (`null`). Total run wall time includes image capture and per-trial logging and stops after the final attempted target; writing the finished summary occurs afterward.

Per-trial `/api/result` records include local `run` metadata. A separate `record_type: click_all_summary` record stores the completed/stopped summary. Export schema version 2 adds `click_all_runs`. `ClickLab.restoreData(exportedData)` restores local results and run summaries without sending or executing anything; it supports previous schema-1 exports and marks imported in-progress runs interrupted. The model catalog is always refreshed separately. This supports preserving the current window through a frontend reload.

The global event history retains its latest 5,000 events. Each controlled action has a separate current-dispatch buffer, so history rollover cannot remove that action’s click/move evidence or latency measurement.
