# Woi model click lab

Compare how accurately audio and text models locate buttons in a screenshot. The lab opens in its own desktop window and keeps actions inside its test surface.

## Open or reopen

From the Woi repository:

```sh
python3 qa/click_bench/lab/launch.py --display :0
```

The launcher reuses its healthy server and window. It uses an existing Woi research Python environment when available. On a fresh checkout, install `requirements.txt` in a virtual environment and pass its interpreter with `--python path/to/python`. Chromium or Chrome is required; `--browser path/to/chromium` selects it explicitly.

## Run a test

1. **Randomize** places named buttons in new positions. Choose a capture size, including **2560 × 1440** for high-resolution tests.
2. Type an instruction such as `Click the Cedar button` or `Move the pointer to the Cedar button. Do not click.`
3. Choose a model radio and press **Send test**. **Click all buttons** tests every button with the selected model, using a separate fresh request for each button. **Test all available models** sends the same current image and instruction to each eligible model once.
4. Check the actual hit, returned point, action and time in **Results**. **View image** shows the exact clean PNG sent for that trial; **Export JSON** saves the evidence.

Each attempt starts fresh with one image and the current text instruction. Earlier messages and results are excluded. Audio/realtime models receive text through their audio-model transport; these trials measure visual targeting and action selection, not speech recognition.

The **capture size** is the coordinate system used by the model. The fitted preview and browser-reported **screen CSS size/DPR** are separate. Results are mapped to the actual local button regions, and a move produces zero click events. This is a controlled lab test rather than an operating-system-wide input test.

Automatic scoring recognizes a unique named button in the instruction. For other instructions, select an expected target under **Scoring and request details**; ambiguous targets stay unscored. Expected geometry is used only for local scoring and never sent to the model.

Model entries come from the account catalog when available, with app-registry candidates as a labeled fallback. An eligible entry may still reject access, screenshots or a requested capability; those failures remain visible. Image detail defaults to original for catalog-supported text models and high for Realtime. The actual setting is recorded under **Latest response details**.

## Connection and speed

Choose **Codex login** or **API key** in the Model panel. Codex uses the existing login. API mode can reuse an existing Woi/environment key or accept a password-masked key in the lab. A key entered here stays in the local server process until it is cleared or the server restarts; it is not saved to Woi settings, browser storage, or trial exports. Switching connections refreshes the model catalog.

Choose a speed for the selected model before sending a test:

| Choice | Responses request value | Behavior |
| --- | --- | --- |
| Normal | `default` | Explicit standard processing, independent of a project's automatic default. |
| Fast | `priority` | Codex's Fast tier; the provider can report `priority` or `fast`. |
| Ultrafast | `ultrafast` | Attempt the selected model/account's Ultrafast service. |
| Flex | `flex` | Attempt Flex processing; also selectable with Codex login. |

All four choices remain selectable. Account/model restrictions are shown in the result. The lab never retries a rejected tier at another speed or substitutes another model. The result table, click-all summaries, and JSON exports retain the selected tier, actual wire value, and provider-reported tier separately. Missing provider metadata stays **unreported**. Comparisons are grouped by connection, model, and selected speed.

Native Realtime does not expose a service-tier parameter. Its Normal option uses the existing session; another speed returns an explicit unsupported result without sending an undocumented field or delegating to a text model. Connection and speed controls are frozen during tests and batches. A connection revision check also rejects stale requests from another window.

Official references: [Codex speed](https://learn.chatgpt.com/docs/agent-configuration/speed), [configuration mapping](https://learn.chatgpt.com/docs/config-file/config-reference), [API Fast](https://developers.openai.com/api/docs/guides/fast-mode), [API Ultrafast](https://developers.openai.com/api/docs/guides/ultrafast-mode), and [API Flex](https://developers.openai.com/api/docs/guides/flex-processing).

## Successful clicks and request timing

A correctly scored click turns its button **black with white text**. Correct pointer moves, wrong-button clicks, and failed requests do not mark a button completed. A new single test, click-all run, or model comparison resets the colors; successes remain visible throughout a click-all run. Randomizing or resizing the surface also resets them.

Completed-button colors are local feedback on a separate display layer. The PNG sent to the model keeps the original button colors and excludes previous success and pointer markers, preserving identical inputs for comparisons.

Each request reports the source PNG size and a provider-request timeline:

- **Upload:** elapsed time until the client finishes dispatching the request body containing the image and prompt. This observes local send completion, not an acknowledgment that the provider received every byte.
- **First reply:** elapsed time to the first nonempty streamed text or tool-argument output. Session/response-created events do not count. If only a final result is observed, the UI identifies that final-only output and leaves the true first-token measurement unavailable.
- **Finished:** elapsed time until the provider response completes, or the request ends in an error.

These offsets share the provider-request start time. The browser's existing send-to-click timing remains separate and includes the local request/response path and click execution. Missing measurements stay unavailable. Evidence includes raw image bytes, serialized provider payload bytes, upload dispatch duration, and the measurement method; API keys and image base64 are excluded from server JSON logs.

## Click-all score and timing

A click-all run freezes the current layout and model until it finishes or you choose **Stop after this request**. The current request completes before stopping, and partial progress stays visible.

The score is **successful clicks / completed attempts**; progress is **completed / planned buttons**. API errors and invalid/non-click replies are failed completed attempts. Buttons that were never attempted are excluded from the score.

Average, fastest and slowest **send → click** times begin immediately before each request is sent and end after its actual local click event is dispatched. Every executed click contributes, including clicks on the wrong target. An error or reply with no click contributes no timing sample. The sample count is shown explicitly. **Total wall time** covers the complete run through its final attempt, including screenshot capture, waits, gaps and per-trial result logging. API-only time remains a separate table column. JSON export retains run summaries, target order and per-click timing/event evidence locally.

## Results and details

- [Speed tiers, click feedback, and request timing validation](results/20261107/SPEED_TIERS_VALIDATION.md)
- [Final model comparison and actual-window confirmation](results/20261107/RESULTS.md)
- [Click-all workflow validation and live timing](results/20261107/CLICK_ALL_VALIDATION.md)
- [Corrected 16-model screening data](results/20261107/corrected-screening-summary.json)
- [Why original image detail matters](results/20261107/IMAGE_DETAIL_DIAGNOSIS.md)
- [All reports and per-trial evidence](results/20261107/)
- [Initial all-high screening report](results/20261107/screening-high-report.json)
- [API protocol and authentication](API.md)
- [UI controls, coordinate mapping and local QA API](UI.md)

The 192-trial all-high baseline, 120-trial original-detail text retest, and 120-trial actual-window confirmation are reported separately. Read their recorded image policies and fixture descriptions before comparing scores.
