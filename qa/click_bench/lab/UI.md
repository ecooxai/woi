# Separate click-lab window

From the Woi repository:

```sh
python3 qa/click_bench/lab/launch.py --display :0
```

The launcher finds an existing Woi research virtual environment with `websockets`, starts a loopback server on a free port, and opens an isolated Chromium app window. It stores its own PIDs, URL, logs, and profile under `qa/out/click_lab/`. Running it again reuses its healthy server and window. It does not change the main Woi process or other browser profiles. Pass `--python path/to/python` or `--browser path/to/chromium` when needed. `--no-browser` starts the server only; `--headless --out qa/out/click_lab/ui_check` creates an isolated browser for UI verification.

## Using the surface

The top panel is a deterministic pixel image with real local HTML button hit regions. **Randomize** changes the seed; **Size** changes the transmitted image dimensions. The preview is fitted to the window, while returned coordinates always refer to the original image pixels. Browser-reported screen dimensions and device pixel ratio are shown separately.

Type a current instruction such as `Click the Cedar button` or `Move the pointer to the Cedar button. Do not click.` Choose a model radio and send. Audio/realtime models receive this text instruction through their own transport. **Test all available models** runs one fresh trial per eligible catalog entry on the same image and instruction. Access and capability are verified by the trial, not assumed from catalog presence.

The captured PNG excludes success colors and pointer/result markers. Each result's **View image** opens the exact transmitted image. Returned coordinates are dispatched only inside the local surface; a move emits no click. The page records actual button events independently of the requested target and never uses expected coordinates to correct model output.

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


## Connection and speed tiers

The model panel has independent **Connection**, **Speed tier**, and **Model** choices. Codex login reads the existing Codex credentials; API key mode uses the configured key or a session key entered in the masked field. A session key lives in the local server memory until it stops. The field is cleared after a connection update, no key is placed in browser storage or result exports, and **Forget session key** restores use of the configured key. Missing API credentials leave the controls available so a key can be entered or Codex can be selected again.

Normal, Fast, Ultrafast, and Flex remain selectable for both connections. Their request values are `default`, `priority`, `ultrafast`, and `flex`. Support depends on the model, endpoint, and account. Codex Flex remains selectable as an experiment. Realtime has no tier field, so a non-normal selection records an explicit unsupported result without a fallback model or a misleading standard request.

Each test freezes `auth_mode`, `speed_tier`, and the server's `connection_revision`. The request adds only `speed_tier` and `connection_revision` to the screenshot protocol; authentication remains server-side. A click-all run or all-model comparison captures these values once and uses that snapshot throughout. Connection and tier controls stay disabled until the complete run ends, even during gaps between requests. A response claiming a different connection or selection is rejected before any local action.

The results table and details show the selected tier, `requested_service_tier`, `actual_service_tier`, `tier_status`, and `tier_note`. A provider omission is shown as **not reported**, and an actual tier differing from the request is shown explicitly. Aggregate comparison cards group by connection, model, and selected tier. Mixed configurations have no pooled hit-rate or latency number. Click-all summaries keep the selected connection/tier plus per-attempt provider observations.

Export schema 3 retains this evidence, grouped metrics, and the current nonsecret `test_configuration`. Importing schema 1 or 2 is still supported; older trials without tier/authentication evidence are labeled **Tier not recorded** / **Connection not recorded**, never assigned the current selection. Restoring historical results does not change the server connection.

Additional local QA hooks:

- `ClickLab.setSpeedTier('normal' | 'fast' | 'ultrafast' | 'flex')` (alias `selectSpeedTier`); rejects changes during a run.
- `ClickLab.changeConnection('codex' | 'api', optionalKey)`; absent key preserves the session key, explicit empty string clears it.
- `ClickLab.refreshConnection()` reads safe connection metadata and rejects use during a run.
- `ClickLab.getState()` includes `speedTier`, `authMode`, `connection`, `switching`, and `loadingModels` without exposing credentials.
- `ClickLab.getLastRequest()` shows the exact screenshot/trial payload, including tier and connection revision.


## Correct-click feedback and request measurements

A **scored correct model click** turns that button black with white text. The scorer must observe exactly one click on the expected button, a matching action, and a point inside its rectangle. A correct pointer move, wrong button, manual click, unscored action, request error, or invalid response does not mark a button complete.

A standalone **Send test**, **Click all buttons**, or **Test all available models** starts with the original colors. Successful buttons remain black through the current top-level run, including successive click-all requests. The next run, a layout change, **Randomize**, **Clear**, or restoring an export resets this feedback. Imported results are never replayed as clicks or painted onto the current layout.

Success colors are local presentation feedback on the separate `#successes` canvas. It uses the same pixel rectangles, rounded corners, font, and label positions as the original buttons; the pointer/expected-region markers remain on their own higher layer. The `#board` canvas, source target colors, and captured PNG never change because of a result. Therefore every trial on the same layout still receives the identical clean screenshot, even while the user can see previously completed buttons in black. `.target-hitbox.completed` and `ClickLab.getState().completedTargetIds` expose this local state for QA.

After capture, a compact request timeline appears below the run status and is repeated for each result. While waiting, image size is known and provider stages remain **—**. Completed measurements come from the provider adapter; the browser does not substitute total latency or loopback transfer timing for a missing stage.

| Display | Evidence and meaning |
| --- | --- |
| **Image N MB** | Raw captured PNG byte count, divided by 1,000,000. Adaptive precision keeps small files visible. The tooltip includes exact bytes and the separately measured provider request body size; base64/JSON overhead is not counted as PNG size. |
| **Upload +N s** | `timing.upload_complete_ms`: offset from provider-request start until the client finishes dispatching the request body. It does not prove provider receipt. The tooltip/details retain `upload_duration_ms`, the time spent sending the body, and the adapter's `upload_measurement` description. |
| **First reply +N s** | `timing.first_token_ms`: the first nonempty streamed text or tool-argument delta. Empty events or response headers are not treated as model output. |
| **First output (final only) +N s** | When `first_output_source` is `final_only`, the adapter observed only the final output. The UI shows `first_output_ms` with this explicit label; it does not present it as a first-token measurement. |
| **Finished +N s** / **Ended +N s** | `timing.finish_ms`: response completion or failure offset. Error results use **Ended**, retain available partial measurements, and leave unavailable stages as **—**. Local click execution and result logging happen later. |

All displayed offsets have `timing.origin: provider_request_start`. Provider requests that never start have `status: not_started` and no fabricated stages. The latest-response details include the complete measurement definitions and adapter note. The existing API total and send-to-click measurements remain separate.

Per-trial schema-3 results and click-all attempt summaries preserve `request_image_bytes`, `request_payload_bytes`, and the backend's nested `timing` object. Older imports without provider timing display unknown stages; a stored PNG still allows its exact image size to be calculated. `ClickLab.getState().requestTimeline` exposes the currently displayed measurements without credentials. `#request-image-size` exposes its exact bytes via `data-bytes`; `#request-upload`, `#request-first-reply`, and `#request-finished` expose measured values via `data-value` only when available.
