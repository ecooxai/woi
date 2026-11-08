# Model Click Lab speed tiers, feedback, and timing — validation

Date: **2026-11-07 UTC**

## Result

The lab exposes **Normal, Fast, Ultrafast, and Flex** for both Codex login and API-key connections. The selected option is forwarded and retained with the result. The provider's reported tier remains separate from the requested tier. This distinction was exercised with real Codex responses: Fast and Ultrafast requests succeeded in this account but reported `default`; Flex was rejected.

Successful model clicks now receive black/white local feedback, and the UI displays raw image size plus measured upload, first-reply, and completion offsets. Validation passed at three levels:

| Layer | Completed validation | Real provider requests |
| --- | --- | --- |
| Existing backend isolation and click scoring | 15 tests passed | 0 |
| New speed-tier and connection backend tests | 15 tests passed | 0 |
| New provider timing backend tests | 13 tests passed | 0 |
| New isolated browser QA | 9 check groups, 19 mocked trial requests passed | 0 |
| Existing click-all browser regression | 4 scenarios, 12 mocked trial requests passed | 0 |
| New success-feedback and timing browser QA | 7 check groups, 14 gated mocked trial requests passed | 0 |
| Focused final-only responsive check | 1 mocked request; 390px and 320px wrapping passed | 0 |
| Codex integration smoke test | 8 completed requests; 6 hits, 0 misses, 2 tier rejections | 8 |
| Separate literal-Fast alias diagnostic | 1 rejected `fast` request; UI mapping stays `priority` | 1 |
| Final live instrumentation smoke test | 2 completed transport checks; 1 hit and 1 valid-response miss | 2 |

The backend suites total **43 passing tests**. The three main browser suites total **45 mocked requests**, with **one additional responsive smoke request**. Live validation used **11 provider requests total**: 8 tier-matrix calls, 1 separate alias diagnostic, and 2 final instrumentation checks.

The live tier test is **one sample per model/tier combination**, intended to verify forwarding, error handling, and returned tier evidence. It does not establish latency rankings, general click accuracy, or availability for other accounts or models. API-key connections were tested with a synthetic key and mocked transports; no real API key was available for a live API-key run.

## Request mapping and result evidence

| UI option | Responses `service_tier` | Behavior to preserve |
| --- | --- | --- |
| Normal | `default` | Explicit standard request; avoids inheriting an Auto/project default. |
| Fast | `priority` | Codex's `fast` preference maps to this wire value; API also accepts `fast`. |
| Ultrafast | `ultrafast` | Availability depends on the selected model and account. |
| Flex | `flex` | Selectable for Codex as an experiment; provider rejection is retained. |

Each test records the connection mode, selected speed tier, requested wire value, provider-reported value, tier status, and API/send-to-click timing. Rejection does not trigger an automatic retry or fallback. A response lacking provider tier evidence remains unreported even when its latency is low.

Native Realtime does not document a `service_tier` field. Its non-Normal selections remain selectable, but the adapter returns an explicit unsupported-transport result without sending a substitute request. The backend regression covers this behavior.

## Live Codex results

The eight requests ran from **2026-11-07 21:57:17 to 21:57:37 UTC** through actual speed radio and Send controls in a separate headless Chromium profile. They used the existing Codex login and an isolated local lab server. No provider retry or lab fallback occurred.

| Model | Selected | Requested | Provider reported | Tier status | Outcome | API time (ms) | Send → click (ms) |
| --- | --- | --- | --- | --- | --- | ---: | ---: |
| `gpt-6-astra` | Normal | `default` | `default` | reported | Hit | 2145.7 | 2155.0 |
| `gpt-6-astra` | Fast | `priority` | `default` | different | Hit | 1908.3 | 1914.9 |
| `gpt-6-astra` | Ultrafast | `ultrafast` | `default` | different | Hit | 3313.1 | 3319.7 |
| `gpt-6-astra` | Flex | `flex` | Not reported | rejected | Tier rejected | 581.1 | — |
| `gpt-6.1-sol` | Normal | `default` | `default` | reported | Hit | 2460.6 | 2467.1 |
| `gpt-6.1-sol` | Fast | `priority` | `default` | different | Hit | 2440.3 | 2446.7 |
| `gpt-6.1-sol` | Ultrafast | `ultrafast` | `default` | different | Hit | 2136.0 | 2142.2 |
| `gpt-6.1-sol` | Flex | `flex` | Not reported | rejected | Tier rejected | 645.5 | — |

Both Flex requests returned `HTTP 400: Unsupported service_tier: flex`. Both models returned `default` for their Fast and Ultrafast requests. Consequently, **the live run did not confirm accelerated processing for this Codex connection**. The UI exposes the difference rather than presenting the requested label as proof of the tier used.

Each request used the same clean 1280 × 480 PNG, the current instruction `Click the Kite button.`, and a unique request ID. Expected-target geometry stayed in the evaluator. The report verifies matching screenshot hashes, unchanged instruction, selected-tier forwarding, expected wire value, fresh context, matching connection, and no credentials or prior history in each request.

Fixture SHA-256:

```
dcc6142a671079b2c8d67792880e3fc803450fd9b5b6aa4a8c3bb37eea6704bd
```

Integration evidence:

- [speed-tiers-live.json](speed-tiers-live.json): per-request observations, checks, and summary.
- [speed-tiers-fixture.png](speed-tiers-fixture.png): clean input image used in all eight requests.
- [speed-tiers-live-ui.png](speed-tiers-live-ui.png): resulting UI capture.
- [probe_speed_tiers.py](../../probe_speed_tiers.py): bounded live integration helper.

### Separate literal-Fast diagnostic

A separate request at **21:58:58 UTC** sent literal `service_tier: "fast"` to the Codex Responses endpoint with `gpt-6-astra`. It returned `HTTP 400: Unsupported service_tier: fast` in **642.7 ms**, without SSE output, retry, or fallback. This diagnostic is separate from the eight UI matrix requests and does not change the UI Fast mapping of `priority`.

Evidence: [speed-tiers-fast-alias-diagnostic.json](speed-tiers-fast-alias-diagnostic.json).

## Independent browser QA

`test_speed_tiers_ui.py` injects a mock before navigation and intercepts `/api/connection`, `/api/models`, `/api/trial`, and `/api/result`. Only static assets come from the local server. The helper starts a separate temporary Chromium profile and never manipulates the user's visible desktop window.

The 19 controlled trials verified:

1. All four options remain selectable on Codex and API-key connections. Actual `/api/trial` payloads retain the selected tier and connection revision.
2. Connection, tier, and catalog changes are blocked during a single request and during every request in click-all and all-model batches. Batch results retain the same connection, revision, and tier.
3. Requested/actual differences, an unreported tier with a deliberately fast response, and a rejected tier remain distinct in visible results.
4. Metrics remain separated into backend/model/tier groups. Mixed configurations do not present a pooled hit rate or median as a comparable model/tier statistic.
5. The synthetic API key is sent only to the connection endpoint. The entry clears after success and failure. It is absent from `ClickLab.getState()`, exported data, trial payloads, local/session storage, persisted result objects, and visible/raw result details.
6. Version-2 result exports still restore and render with their tier explicitly unrecorded. No historical tier is invented.
7. Desktop/tablet/mobile layouts at 1440, 780, 390, and 320 CSS pixels avoid body overflow and retain all six connection/tier labels without clipping.
8. Request IDs are unique, and no browser errors, unexpected API routes, external fetches, or real model calls occur.

The existing click-all regression also passed after updating its strict request-field allowlist for `speed_tier`/`connection_revision` and its export schema expectation to version 3. It preserves its original scoring, timing, and event checks.

Generated local QA evidence:

- `qa/out/speed_tiers_ui/speed-tiers-ui-validation.json`
- `qa/out/click_lab/speed-tiers/click-all-regression/independent-click-all-qa.json`
- `qa/out/speed_tiers_ui/speed-tiers-ui-1440.png`
- `qa/out/speed_tiers_ui/speed-tiers-ui-390.png`
- `qa/out/speed_tiers_ui/speed-tiers-ui-390-settings.png`

Desktop and the focused 390px settings capture were visually reviewed. The connection selector, key entry, speed options, explanatory text, and model list remain readable and within the viewport. The generated `qa/out` files are reproducible test output, separate from the saved live evidence above.

## Success feedback and request timing

A separate focused harness, `test_click_feedback_ui.py`, passed **7 check groups and 14 gated mocked trials**. Response gates let the test inspect the UI during a request, between click-all requests, and after completion without relying on arbitrary sleeps.

Success feedback is rendered on the separate `#successes` overlay. Independent pixel checks confirm a black fill and white label for a correct scored model click with one observed click event. Correct moves, misses, request errors, unscored clicks, and manual clicks never acquire success paint. The state IDs, `.completed` DOM classes, and rendered overlay pixels agree.

The feedback clears before a new standalone test, click-all run, all-model comparison, or layout reset. Correct targets remain marked across later click-all attempts, including subsequent misses and errors. Every outbound screenshot remained byte-identical to its clean base PNG; neither success paint nor result markers entered the model input.

The timeline test uses deliberately distinct values:

| Measurement | Controlled value | Verified display/meaning |
| --- | ---: | --- |
| Raw PNG image | 20,432 bytes | `0.020 MB`; exact raw bytes in title/data attribute. |
| Serialized provider body | 456,789 bytes | Separate payload detail; never substituted for image size. |
| Upload completion offset | 125 ms | `+0.125 s` from provider-request start. |
| Body-send duration | 20 ms | Separate detail, never substituted for the upload offset. |
| First meaningful output delta | 450 ms | `+0.450 s`. |
| Provider response completion | 925 ms | `+0.925 s`. |
| Aggregate API latency sentinel | 7,777 ms | Never substituted for any timeline milestone. |

Upload completion means the **client finished dispatching the request body**, not verified provider receipt. Timeline offsets share the provider-request-start origin. Response completion excludes subsequent local click execution and result logging; send-to-click remains a separate measurement.

While a request is pending, unobserved milestones show `—`. Missing or not-started measurements also remain `—`, without fabricated zeroes. A final-only response explicitly labels its first output as final-only and retains `first_token_ms: null`; a failed response labels its completion **Ended**. The transport-level tests separately verify that `response.created`, empty output, and reasoning-only events are not counted as the first meaningful token.

Generated focused evidence:

- `qa/out/click_feedback_ui/click-feedback-timing-validation.json`
- `qa/out/click_feedback_ui/click-feedback-timeline-ui.png`

The desktop capture was visually reviewed: the correctly clicked Kite button is black with white text, and the image/upload/first-reply/completion timeline is readable below the test controls.

One additional isolated mocked response exercised the longer `First output (final only) +0.880 s` label at 390px and 320px. At each size, the document and body widths equal the viewport; timeline scroll width equals client width (322px and 252px respectively). All six configuration labels and four timeline fields remain visible and unclipped. The 390px screenshot was visually reviewed. This focused check did not rerun the full browser suites or make a live model call.

Responsive evidence:

- `qa/out/click_feedback_ui/click-feedback-responsive-validation.json`
- `qa/out/click_feedback_ui/click-feedback-timeline-ui-390.png`

## Live instrumentation checks

After the timing implementation was installed, **exactly two further Normal-tier requests** ran through real UI controls in an isolated headless profile, from **2026-11-07 22:05:22 to 22:05:33 UTC**. Both used the same clean 1280 × 480 image and current instruction as the earlier tier matrix. No retry or fallback occurred.

| Model | Transport | Raw PNG bytes | Serialized payload bytes | Click outcome |
| --- | --- | ---: | ---: | --- |
| `gpt-6-astra` | Responses | 33,772 | 46,829 | Hit |
| `gpt-realtime-2.1` | Realtime | 33,772 | 48,078 | Miss |

| Model | Upload complete (ms) | Body send duration (ms) | First meaningful delta (ms) | Provider finished (ms) | Send → click (ms) |
| --- | ---: | ---: | ---: | ---: | ---: |
| `gpt-6-astra` | 180.670 | 0.048 | 1996.564 | 2238.650 | 2248.500 |
| `gpt-realtime-2.1` | 1025.683 | 3.422 | 3059.726 | 3198.657 | 5426.500 |

Upload, first-output, and provider-completion values are offsets from that request's provider clock; body-send duration measures only dispatch. Both responses produced measurable nonempty streaming output, so `first_token_ms` was observed rather than inferred from setup or final completion.

Astra hit the requested button. The overlay then contained black fill and white text. Starting the Realtime test cleared the preceding success before the request completed. Realtime returned a valid action response and all instrumentation checks passed, but its predicted point **missed** the requested button; the UI correctly left the success overlay empty.

Provider completion and end-to-end click timing remain separate. In this sample, Realtime's provider response finished at +3.199 seconds, while the browser executed its click after 5.427 seconds. The full API round-trip was 5.421 seconds. Realtime's provider clock stops at the terminal response event; WebSocket teardown occurs afterward and contributes to the API-return latency (see [API transport notes](../../API.md)). These values must not be presented as interchangeable or as a model-speed comparison.

Live instrumentation evidence:

- [timing-live.json](timing-live.json)
- [timing-responses-ui.png](timing-responses-ui.png)
- [timing-realtime-ui.png](timing-realtime-ui.png)

## Backend regression scope

The 15 new backend tests cover all four wire values; fresh-message construction; explicit Normal for legacy omissions; requested versus returned tiers; SSE tier extraction; longer Flex timeout handling; rejected-tier isolation; Codex Flex forwarding without fallback; unsupported Realtime tiers; missing-key setup; memory-only runtime keys and redaction; connection/key-scoped catalog caching; in-flight connection locks; stale revisions; loopback endpoint behavior; and invalid/header-injection inputs.

The 13 timing tests additionally verify the real HTTP body-send loop, exact serialized byte length and single-use/no-replay semantics; empty and failed sends; distinct Realtime connection/session-setup/body-send stages; exclusion of lifecycle, reasoning, and empty-delta events; streamed versus final-only output; preservation of partial observations after HTTP/stream/Realtime errors; not-started metadata for unsupported transports and local validation errors; and retention of observed provider measurements if local logging fails.

All **43 tests passed**. Exact commands and output are retained in [timing-backend-tests.txt](timing-backend-tests.txt). Syntax compilation and `git diff --check` also passed during implementation.

## Reproduce

Run from the click-lab worktree. The sibling Python environment shown here is the project's existing research environment. Substitute `research/.venv/bin/python` when running from the primary checkout.

```bash
../woi/research/.venv/bin/python qa/click_bench/lab/test_lab.py
../woi/research/.venv/bin/python qa/click_bench/lab/test_speed_tiers.py
../woi/research/.venv/bin/python qa/click_bench/lab/test_timing.py
../woi/research/.venv/bin/python qa/click_bench/lab/test_speed_tiers_ui.py --url http://127.0.0.1:38631 --output qa/out/speed_tiers_ui
../woi/research/.venv/bin/python qa/click_bench/lab/test_click_all.py --url http://127.0.0.1:38631 --output qa/out/click_lab/speed-tiers/click-all-regression
../woi/research/.venv/bin/python qa/click_bench/lab/test_click_feedback_ui.py --url http://127.0.0.1:38631 --output qa/out/click_feedback_ui
```

The browser QA commands mock model trial requests and result writes. The live integration helper makes real Codex requests and is intentionally separate; this validation did not run a broad performance benchmark.

## Official references checked

- [Codex configuration reference](https://learn.chatgpt.com/docs/config-file/config-reference): `service_tier` and the `fast` → `priority` mapping.
- [Codex speed settings](https://learn.chatgpt.com/docs/agent-configuration/speed): Fast/Ultrafast support and account availability.
- [API Fast mode](https://developers.openai.com/api/docs/guides/fast-mode): accepted Fast request values and returned processing tier.
- [API Ultrafast mode](https://developers.openai.com/api/docs/guides/ultrafast-mode): `ultrafast` requests and supported models.
- [API Flex processing](https://developers.openai.com/api/docs/guides/flex-processing): `flex` requests, slower processing, and availability limits.

## Final desktop integration

The existing display `:0` lab window was reloaded at `http://127.0.0.1:38631/` with the final source. All **227 existing trials** were restored, along with the selected `gpt-realtime-2.1` model, Fast selection, instruction, and 1920 × 1080 / 12-button layout. No verification trials were injected into that window. The new success-feedback canvas is present, and the window was idle after restoration.

A final focused readiness check verified that missing credentials show **API key required** / **Codex sign-in required**. Ctrl+Enter and direct run calls with a known missing key create no request or result; returning to configured Codex restores the controls. This check made zero provider calls.
