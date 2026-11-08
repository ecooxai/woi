# Woi 0.21.0 — GPT-Live capability check and Advanced Model Click Lab

Date: 2026-11-08 (UTC). Branch: `gpt-6-astra-pro/woi-live-model-lab-20261108`.
Base: `5097c3404f3fd9d473e629aef80ec2fb0108c389` (0.20.0). Application version: `0.21.0+22`; Android ARM64 version code: `2022`.

## Exact gpt-live-1.1 capability check

The exact model was probed through the routes Woi uses on 2026-11-08, 17:28–17:30 UTC. The probes used only a generated image, known text, and a prerecorded synthetic audio fixture. They did not open a real microphone, capture a private screen, execute a device pointer/keyboard action, or call a second model.

Two valid AVAS sessions started successfully and accepted text-context controls. This distinguishes capability rejection from a failed login or unavailable model.

| Check | Observed result |
| --- | --- |
| Exact model on standard `/v1/realtime` | Rejected with `invalid_model`. |
| `session.update` with `session.tools` in a healthy AVAS session | Rejected with `unknown_parameter`, parameter `session.tools`. |
| Function tools included in initial AVAS call creation | HTTP 201 from call creation, then sideband HTTP 404 and no `session.started`; the ordinary control call started successfully. A 201 response alone is not proof of a usable session. |
| `session.context.append` with the required text plus `image_url` | Rejected with `unknown_parameter`, parameter `content[0].image_url`. |
| Single image item in `response.item.create` | Rejected because `item.content[0].text` is required. |
| Direct `response.create` | Rejected because Responses delegation is required. |
| Synthetic spoken click request | Emitted `delegation.created` targeting the client. |
| Client returns a no-action test result | `delegation.context.append` was acknowledged. |

**Conclusion:** native image/function-tool benchmarking remains unavailable for `gpt-live-1.1` on Woi's current routes. Delegated tool use works. A visual grounding task needs an image-capable backend; a deterministic client action such as an explicit typing/keyboard/clipboard command does not inherently require another model. Existing Woi fast paths remain in place.

The user's request to prefer the live model itself was conditional on native support. The saved Luna pointer preference is therefore retained; no unsupported native route or silent model substitution is introduced. The lab explanation distinguishes native image/function calls from working delegated tool use.

[Publication-safe exact-model capability evidence](click_bench/lab/results/20261108/live-capabilities.json) records the controls, outcomes and source hashes. Its SHA-256 is `3617cba824481679ed7d0121ad9df6b2cc7657863eda6b20dc447daa8195f54a`.

Detailed sanitized evidence is retained locally under `qa/out/live-capabilities-20261108/`:

- `capability-results.json` — SHA-256 `a48a956a7be4d20a03659456f3d2de19fce72b5813d7bbc0d68bcc508ebbbd34`.
- `capability-followup.json` — SHA-256 `8020e5557b596ddf8d0385b1c698f5cf0fd1ed59efb9e8594df7e89fb050e24c`.
- `capability-summary.json` — concise result and probe scope.

## Model Click Lab integration

The existing lab was developed on the separate `gpt-6-astra-pro/woi-click-lab-speed-tiers-20261107` branch at `d4fec27`. Its source and recorded earlier evidence are imported into this release; the sibling worktree and its server are not modified.

The existing HTML/CSS/JavaScript interface is bundled with Woi. Settings → Advanced opens an app-owned loopback host in the platform browser, using Woi's configured connection without requiring a separate Python service, a development checkout, or an ADB port bridge. The benchmark is isolated from the assistant conversation and operating-system input. Each trial uses the selected model, one synthetic screenshot and the current instruction; its tool result is applied only inside the lab target surface.

The host loads all three bundled assets before opening a browser, reuses an existing host on repeated launches, and closes provider work on Woi shutdown. The Advanced button flushes pending settings edits, suppresses duplicate opens and permits retry after a browser launch error. Android uses an ordinary browser launch, without the sign-in keepalive notification.

Each trial pins the connection mode, credentials and revision. Connection changes are blocked while trials or catalog requests are active. The backend preserves selected and provider-reported model identities separately and does not retry at another model or speed tier. One-off API keys stay in server memory and are excluded from exports. The loopback API uses a per-runtime fragment/header token, checks local Host/Origin provenance, bounds uploads and concurrent work, and validates screenshot structure and dimensions before contacting a provider.

First output timing requires nonempty streamed text or function arguments; a completed response alone cannot supply a first-token measurement. HTTP upload timing explicitly records the local Dart client sink flush, not provider acknowledgment. Realtime records enqueue separately and leaves upload completion/duration unavailable.

## Automated validation

| Gate | Result |
| --- | --- |
| Full Flutter analyzer | No issues. |
| Full Flutter suite | **1,073 passed, 15 opt-in skipped, 0 failed.** |
| Final focused Dart host/backend/Settings tests | **23 passed** after the Android navigation correction. The earlier 22 tests were included in the full-suite run. |
| Imported standalone lab regression suite | **43 passed.** |
| Bundled speed-tier browser regression | **9 checks / 19 mocked trials passed.** |
| Bundled click-feedback/timing browser regression | **7 checks / 14 mocked trials passed.** |
| Browser layout checks | Desktop, tablet, 390 px and 320 px widths passed. |
| Browser request provenance | Synthetic launch token required on every intercepted API request; no unmocked API request or model call. |
| Independent source review | No remaining blocking issue; corrected action-scope and timing wording, verified exact-model routing and cleanup. |

The first focused run exposed a catalog map typing error, which was fixed before the successful gate. A temporary-key source-label error was fixed and covered by regression. An over-broad controller formatter pass was removed before the clean full analyzer; existing controller formatting is preserved. The first release attempt used stale test-mode plugin registration with `--no-pub`; the normal release build regenerates production-only tooling. Detailed logs remain under `qa/out/acceptance-0.21.0/`.

## Platform and release acceptance

Both final release builds passed from **503 frozen application files**, source fingerprint `2ab2b3d10d80813c314abcd2ea99602404105b7b37200dd3c88c6955ce73836f`. The final whole-project analyzer reports no issues. The complete Flutter suite ran before device acceptance; the subsequent document-entry correction was covered by the final 23 focused tests and another full analyzer run.

### Android

The MI 8 (Android 15 / API 35) was updated in place to **0.21.0**, ARM64 version code **2022**. The installed APK hash matches the packaged release. Existing input method, accessibility and assistant selections and previously granted permissions were retained. Woi accessibility is bound, with no crashed entry, and Woi was returned to the foreground after closing only the test browser tab. The harness did not read or modify clipboard contents.

The first physical launch exposed an Android-specific failure: Brave marks an app-opened top-level document as `Sec-Fetch-Site: cross-site`, `Sec-Fetch-Mode: navigate`, `Sec-Fetch-Dest: document` (without `Sec-Fetch-User`). The host now permits only this read-only entry navigation to `/` or `/index.html` after exact Host validation. API calls, subresources, other methods and iframe/fetch requests retain their existing origin/token protections. Regression tests and independent review cover these boundaries.

The rebuilt app opened the lab successfully from Advanced settings. With Brave foregrounded and Woi behind it, **gpt-6.1-sol** received the fresh synthetic screenshot and returned a click on the expected Cobalt button. Selected and provider-resolved IDs were both `gpt-6.1-sol`; exactly one model click was recorded. The 540 px CSS viewport (DPR 2) had no horizontal overflow. The host and successful result remained healthy **178 seconds** after the launch check, before cleanup.

### Linux

The native Advanced launcher was operated on a private display using isolated app data. Its URL opener was captured for an isolated browser, leaving the user's desktop/browser profile untouched. **gpt-realtime-2.1** directly accepted the screenshot and function tool, resolved to the same model, and produced exactly one correct Cobalt click. No Luna substitution, microphone input or OS pointer action was used.

That real Realtime trial preceded the final Android entry-page correction. Fingerprint comparison proves that only the host and its test changed; the provider backend and all UI assets are unchanged. The final Linux build was reopened and verified again: both permitted external document entries returned 200; wrong Host and cross-site API requests remained 403; the health API returned 403 without its token and 200 with valid local authorization. Served, canonical and packaged asset bytes match. Only the recorded private test processes were stopped, and the local socket closed.

### Evidence and packages

[Publication-safe runtime acceptance](click_bench/lab/results/20261108/runtime-acceptance.json) records exact models, outcomes, measured timing semantics and artifact hashes. Timing values are single acceptance samples, not a model performance comparison. [Android launcher screenshot](click_bench/lab/results/20261108/android-model-lab-launcher.png) and [successful Android trial](click_bench/lab/results/20261108/android-browser.png) contain only the Settings launcher or synthetic lab surface.

The APK passes ZIP integrity, AArch64 library, bundled-lab-asset and signer checks. Its signer is unchanged (`54921a3a54191e8545842cdf135b7603043f58e9e392c77fb484c0cccd8e3f4f`). The packaged SpeexDSP binary and license notice are preserved; this release did not rerun acoustic tests. The Linux archive passes complete file/hash/mode/type verification, expected executable and dependency presence, x86-64 architecture, version metadata and lab-asset parity checks.

| Artifact | Bytes | SHA-256 |
| --- | ---: | --- |
| `woi-0.21.0-android-arm64.apk` | 101829023 | `37691be23a8f576a8701f9d27280dcb34fbb009a0311502b239576b2209a96c1` |
| `woi-0.21.0-linux-x64.tar.gz` | 168917366 | `242ff00ca91ea09693549ef1f3764ba82abb2e7bc11c870206e6fc4da3bd4829` |
| `woi-0.21.0-SHA256SUMS.txt` | 189 | `aabc77fbd26c7d56adbe146b8b42d4bdfa522b9ca2adbd4a76cbbcf1e52695c6` |


## Sources

- [Official GPT-Live 1 model page](https://developers.openai.com/api/docs/models/gpt-live-1): image input is not supported. This is family documentation, not a public model card for the exact Codex `gpt-live-1.1` identifier.
- [Official GPT-Live delegation and tools guide](https://developers.openai.com/api/docs/guides/live-delegation): the voice model delegates work to an independently configured Responses model or client backend.
- [Official GPT-Live introduction](https://developers.openai.com/api/docs/guides/live): distinguishes the conversational voice model from the backend that reasons and executes tools.
- [Existing Woi protocol research](../research/REALTIME_API.md): prior AVAS observations; rechecked here instead of relying on the older date alone.
