# WOI click-accuracy lab results — 7 November 2026

## Findings

The confirmed text model **gpt-6-luna** hit every tested target in the actual ClickLab UI when sent original-detail screenshots. See the separate screening and confirmation counts below.
`gpt-5.6-luna` made a genuine wrong-button move: it was asked for **Moss** and landed on **Sage**. The trusted browser event and saved source screenshot preserve that miss; it was not retried or removed.
**gpt-realtime-2** and **gpt-realtime-2.1** tied at **11/30 (36.7%)** in actual-UI confirmation. The small median-latency difference does not establish an accuracy winner. Audio models were prompted with text; these measurements isolate screenshot localization, not speech recognition or voice quality.

Selecting image detail materially changes the result. Five text candidates missed the four 2560×1440 screenshots under `high` detail; the paired `original` retest uses byte-identical screenshots, the same instructions, the same reasoning effort, and the same system-prompt hash. This is a configuration comparison, not evidence that those text models lack accurate vision.

## Model screening — 12 matched trials per model

Text rows use the corrected v2 `original` policy. Audio rows retain the v1 `high` policy, which is also the v2 policy for Realtime. Each model gets six clicks and six moves over the same three randomized layouts. No accessibility/vision fallback corrects its coordinates.

| Model | Type | Detail | Clicks | Moves | Total hits | Median / p90 seconds | API/output errors |
|---|---|---|---:|---:|---:|---:|---:|
| gpt-5.6-luna | text | original | 6/6 | 6/6 | 12/12 (100.0%) | 2.73 / 3.64 | 0 |
| codex-auto-review | text | original | 6/6 | 6/6 | 12/12 (100.0%) | 2.82 / 3.91 | 0 |
| gpt-6-sol | text | original | 6/6 | 6/6 | 12/12 (100.0%) | 2.99 / 3.40 | 0 |
| gpt-6-luna | text | original | 6/6 | 6/6 | 12/12 (100.0%) | 3.03 / 3.25 | 0 |
| gpt-5.6-sol | text | original | 6/6 | 6/6 | 12/12 (100.0%) | 3.15 / 3.79 | 0 |
| gpt-6.1-terra | text | original | 6/6 | 6/6 | 12/12 (100.0%) | 3.26 / 5.30 | 0 |
| gpt-6-astra | text | original | 6/6 | 6/6 | 12/12 (100.0%) | 3.51 / 3.85 | 0 |
| gpt-reserve | text | original | 6/6 | 6/6 | 12/12 (100.0%) | 3.67 / 4.15 | 0 |
| gpt-5.6-terra | text | original | 6/6 | 6/6 | 12/12 (100.0%) | 3.69 / 4.06 | 0 |
| gpt-6.1-sol | text | original | 6/6 | 6/6 | 12/12 (100.0%) | 3.79 / 4.18 | 0 |
| gpt-realtime-2 | audio | high | 3/6 | 3/6 | 6/12 (50.0%) | 5.32 / 6.09 | 0 |
| gpt-realtime-2.1 | audio | high | 3/6 | 3/6 | 6/12 (50.0%) | 5.65 / 6.29 | 0 |
| gpt-realtime-1.5 | audio | high | 1/6 | 3/6 | 4/12 (33.3%) | 4.02 / 5.12 | 0 |
| gpt-realtime-2.1-mini | audio | high | 1/6 | 1/6 | 2/12 (16.7%) | 4.67 / 5.19 | 0 |
| gpt-realtime | audio | high | 0/6 | 1/6 | 1/12 (8.3%) | 4.03 / 4.60 | 0 |
| gpt-realtime-mini | audio | high | 0/6 | 1/6 | 1/12 (8.3%) | 5.13 / 6.02 | 0 |

### Screening by native capture size

| Model | 960×720 | 1280×720 | 2560×1440 |
|---|---:|---:|---:|
| gpt-5.6-luna | 4/4 | 4/4 | 4/4 |
| codex-auto-review | 4/4 | 4/4 | 4/4 |
| gpt-6-sol | 4/4 | 4/4 | 4/4 |
| gpt-6-luna | 4/4 | 4/4 | 4/4 |
| gpt-5.6-sol | 4/4 | 4/4 | 4/4 |
| gpt-6.1-terra | 4/4 | 4/4 | 4/4 |
| gpt-6-astra | 4/4 | 4/4 | 4/4 |
| gpt-reserve | 4/4 | 4/4 | 4/4 |
| gpt-5.6-terra | 4/4 | 4/4 | 4/4 |
| gpt-6.1-sol | 4/4 | 4/4 | 4/4 |
| gpt-realtime-2 | 4/4 | 2/4 | 0/4 |
| gpt-realtime-2.1 | 3/4 | 2/4 | 1/4 |
| gpt-realtime-1.5 | 2/4 | 2/4 | 0/4 |
| gpt-realtime-2.1-mini | 0/4 | 2/4 | 0/4 |
| gpt-realtime | 1/4 | 0/4 | 0/4 |
| gpt-realtime-mini | 0/4 | 1/4 | 0/4 |

`codex-auto-review` and `gpt-reserve` are retained because the account catalog exposed them and they accepted the requested task. Their measured coordinate behavior does not establish suitability as general conversational model choices.

## Controlled high-detail versus original-detail comparison

| Text model | High detail, all 12 | Original detail, all 12 | High, 2560×1440 | Original, 2560×1440 |
|---|---:|---:|---:|---:|
| gpt-5.6-luna | 8/12 | 12/12 | 0/4 | 4/4 |
| codex-auto-review | 8/12 | 12/12 | 0/4 | 4/4 |
| gpt-6-sol | 12/12 | 12/12 | 4/4 | 4/4 |
| gpt-6-luna | 8/12 | 12/12 | 0/4 | 4/4 |
| gpt-5.6-sol | 12/12 | 12/12 | 4/4 | 4/4 |
| gpt-6.1-terra | 12/12 | 12/12 | 4/4 | 4/4 |
| gpt-6-astra | 12/12 | 12/12 | 4/4 | 4/4 |
| gpt-reserve | 8/12 | 12/12 | 0/4 | 4/4 |
| gpt-5.6-terra | 8/12 | 12/12 | 0/4 | 4/4 |
| gpt-6.1-sol | 12/12 | 12/12 | 4/4 | 4/4 |

In the original high-detail run, Luna's large-image coordinates were approximately 0.82177 times the source coordinates; several other affected text models returned approximately 0.8 times them. The exact browser mapping passed its oracle checks. Earlier repository results used 1600×900 images, while the app's locator caps capture width at 1920 pixels; the new 2560-pixel cases extended that earlier scope.

## Confirmation in the actual ClickLab UI — 30 new trials per selected model

These use the final UI's canvas capture and target elements, a different fixture from screening. Each selected model gets the same 30 screenshots/instructions: 15 clicks and 15 moves. A trusted browser input event must land in the requested element; returning a plausible coordinate alone cannot pass. These counts are kept separate from screening.

| Model | Clicks | Moves | Total hits | Median / p90 seconds | Median / p90 center error, px | API/output errors |
|---|---:|---:|---:|---:|---:|---:|
| gpt-6-luna | 15/15 | 15/15 | 30/30 (100.0%) | 1.95 / 2.27 | 0.45 / 0.57 | 0 |
| gpt-5.6-luna | 15/15 | 14/15 | 29/30 (96.7%) | 2.30 / 2.96 | 0.47 / 0.53 | 0 |
| gpt-realtime-2 | 5/15 | 6/15 | 11/30 (36.7%) | 4.88 / 5.17 | 50.72 / 211.85 | 0 |
| gpt-realtime-2.1 | 4/15 | 7/15 | 11/30 (36.7%) | 4.99 / 5.82 | 50.06 / 221.41 | 0 |

### Confirmation by native capture size

| Model | 960x720 | 1280x480 | 2560x1440 |
|---|---:|---:|---:|
| gpt-6-luna | 10/10 | 12/12 | 8/8 |
| gpt-5.6-luna | 9/10 | 12/12 | 8/8 |
| gpt-realtime-2 | 5/10 | 6/12 | 0/8 |
| gpt-realtime-2.1 | 5/10 | 6/12 | 0/8 |

## Verification and interpretation

- The standardized fixture passed 12/12 oracle actions. The actual UI passed 30/30 oracle actions, with DPR 1 and 2 and both action types.
- Fifteen independent integrity tests cover fresh requests, fresh and closed Realtime sockets, forbidden history/target fields, finite and in-bounds coordinates, correct action/event scoring, and error denominators. Separate mocked UI checks cover responsive layout, marker-free captures, frozen layouts, stale capture rejection, and clicks versus pointer moves.
- Each model request contains only its model ID, current instruction, one screenshot, screenshot dimensions, screen metadata, and a fresh request ID. No target rectangles, element list, previous answers, or prior messages are sent.
- Text requests use one Responses input message, `store:false`, and no prior-response identifier. Each audio trial opens a new Realtime socket and uses `conversation:none` with one text-plus-image input.
- Predictions outside the image are rejected, never clamped. API failures, malformed outputs, and timeouts are separate from genuine misses. Raw and sanitized trial records preserve all attempted trials.
- There were 0 provider-reported model-ID substitutions and 0 responses without a provider-reported model ID across these 432 formal trials.
- The comparison tables report backend model-adapter API duration, including creation of a new Realtime connection. They exclude evaluator page replay and click dispatch. Local HTTP request/response median/p90 times are retained separately in JSON; those also stop before evaluator click execution. These are not the new Click all buttons browser-side request-send-to-executed-click measurements. No speech synthesis timing is claimed.
- These three formal comparison phases contain 432 requests. Any subsequent Click all buttons integration run is a separate workflow check and is not pooled into their scores or timing columns.
- These are small, controlled button-localization tests. Perfect results on 12 or 30 trials do not establish reliability on arbitrary desktop applications. Wilson 95% intervals are included in JSON.

## Catalog and account scope

The current Codex login exposed ten text candidates through its live catalog. Six Realtime candidates came from Woi's registered audio-model list and were each verified with twelve live trials. The public `/v1/models` listing returned HTTP 403 for missing `api.model.read` scope under this login, so this report does not claim a global inventory of every OpenAI model or availability in other accounts.

`gpt-live-1.1`, `gpt-live-1`, and `gpt-live-1-codex` remain listed in the UI with an explicit unsupported reason: their live frontend does not directly accept the screenshot input tested here. Delegating images to a separate vision model would measure that delegated model, so no direct click score is assigned to these three entries.

Text trials used `https://chatgpt.com/backend-api/codex/responses`; Realtime trials used `wss://api.openai.com/v1/realtime`. Credentials were read server-side and are absent from reports and browser requests.

## Evidence

- `corrected-screening-summary.json`: corrected 16-model comparison.
- `screening-high-report.json` and `screening-high-trials.jsonl`: immutable all-high baseline.
- `screening-original-report.json` and `screening-original-trials.jsonl`: paired original-detail text rerun.
- `confirmation-ui-report.json` and `confirmation-ui-trials.jsonl`: actual-window confirmation, kept separate.
- `integrity.json`, `ui-integrity.json`, `confirmation-ui-oracle.json`: independent integrity and oracle evidence.
- `provenance.json`: phase counts, provider endpoints, protocol/prompt/row hashes, and final source hashes.
- `screening-cases.json` and `confirmation-ui-cases.json`: evaluator-only case manifests, native geometry and screenshot hashes.
- `confirmation-text-misses.json`: the preserved incorrect text-model action and its expected/actual target.
- Representative source screenshots are included beside this report. Full captures and provider traces remain under `qa/out/click_lab/benchmark/20261107/`.

## Click all buttons workflow

The selected-model batch workflow has separate browser-event QA and live integration evidence in [CLICK_ALL_VALIDATION.md](CLICK_ALL_VALIDATION.md). Its request-send-to-executed-click timings and scores are not pooled into the 432 formal model comparison trials above.
