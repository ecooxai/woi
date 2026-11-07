# Click accuracy lab protocol

The standalone window uses a loopback-only Python server (port 8766 by default).
Run `python qa/click_bench/lab/server.py --port 8766` after installing
`qa/click_bench/lab/requirements.txt` in a virtual environment. The existing Woi
research environment also works. No frontend dependencies or asset downloads.

## GET /api/models

Returns `models`, `auth`, `source`, `warnings`, and `discovered_at`. Every model has
`id`, `name`, `kind` (`audio`, `text`, `other`), `transport`, `available`, `reason`,
`source`, `availability`, `test_status`, `reasoning_effort`, `image_detail`, and
`supports_image_detail_original` (true, false, or unknown/null). `available` means
eligible to attempt, not a claim that the current account has proven access.
`test_status` and `last_error` update after real calls. Refresh with `?refresh=1`.

The live Codex catalog is queried with the current Woi credentials. Public API
model discovery is also attempted. When that scope is unavailable, audio
candidates come from Woi's existing model registry and are labeled as such.
Every returned model is shown, including hidden catalog entries. Live audio
models are shown as unsupported for direct screenshot input; no delegated text
model is silently substituted or credited to Live.

## POST /api/trial

```json
{
  "model": "gpt-realtime-2.1",
  "instruction": "Click the Cedar button.",
  "screenshot": "data:image/png;base64,...",
  "width": 1280,
  "height": 720,
  "screen": {"width": 1920, "height": 1080, "devicePixelRatio": 1},
  "request_id": "unique-request-id"
}
```

Only these fields are allowed. PNG dimensions and checksums are verified.
The screenshot is the controlled target surface, not the whole operating system.
`screen.width/height` report browser Screen CSS dimensions; screenshot `width`
and `height` are authoritative for coordinates. DPR is reported, not multiplied.
No target names list, target rectangles, expected action, prior messages, or
history can be sent to this endpoint. A fresh one-message Responses request or
fresh WebSocket session with `conversation: none` and explicit one-message input
is used each time. Existing Woi credentials are only read, never refreshed here.

Successful API calls return `action: click|move`, `x`, `y`, `request_id`, `model`,
`resolved_model`, `latency_ms` (including handshake), `usage`, `error: null`, and
metadata including image hash, resolution, endpoint, reasoning, selected image
detail/policy, protocol version, and raw final function-call output. Coordinates are screenshot pixels. Invalid, non-finite,
or out-of-bounds coordinates produce an explicit error and are never clamped.
Models are required to produce exactly one `screen_action` tool call.

All model responses are parsed under the same schema. Catalog models advertising
low reasoning are tested with low effort; no tiny output-token cap can consume
the reasoning budget before the tool call. API rejection, timeout, rate limits,
unsupported image input, invalid output, and wrong coordinates remain distinct.
No coordinate correction, accessibility lookup, or real OS input occurs here.

## POST /api/result

Stores a client-generated scoring record with `request_id`. This is separate
from `/api/trial`; target truth and hit evidence are never passed to a model.
Its content can include actual local button click / pointer event results.

The server stores private evidence in `qa/out/click_lab/` by default: one PNG per
image hash, a `trials.jsonl` request/response log, and optional `results.jsonl`.
The JSON logs omit credentials and base64 images. Model errors are structured
trial results with `error_code`; malformed local requests have an HTTP 4xx code.

## Image detail and benchmark versions

`screenshot-only-v2` defaults to `WOI_LAB_IMAGE_DETAIL=auto`. This sends
`detail: "original"` to Responses models whose catalog explicitly advertises
`supports_image_detail_original: true`, and `detail: "high"` to Realtime and
other candidates. The PNG bytes and declared dimensions do not change.

Use `--image-detail high` (or `WOI_LAB_IMAGE_DETAIL=high`) to reproduce the
initial all-high configuration. Use `--image-detail original` to require original
mode for Responses models; an explicitly unsupported capability or Realtime
transport is rejected without fallback. When the public catalog omits capability
metadata, an explicit original override is attempted and the provider response
is recorded. Auto never assumes missing capability metadata means support.

Every trial records `image_detail`, `image_detail_policy`, and `protocol`.
The original `screenshot-only-v1` all-high screening is preserved as a separate
configuration; do not merge its hit rates with the native-detail rerun.

OpenAI's [image guide](https://developers.openai.com/api/docs/guides/images-vision)
and [computer-use integration guide](https://developers.openai.com/api/docs/guides/tools-computer-use-integration)
recommend original detail for precise coordinates when supported. High detail
can resize internally, so identical source PNG bytes alone do not establish that
the model is reasoning in the original coordinate space. Resolution diagnostics
must keep each configuration labeled rather than silently correcting points.

## Authentication and boundaries

Default authentication follows Woi's `~/.local/share/woi/settings.json` selected
backend. Codex login uses `~/.codex/auth.json` read-only. API mode uses Woi's key,
`OPENAI_API_KEY`, or the existing Codex API key in that order. Explicit overrides
are `WOI_LAB_AUTH=codex|api`, `WOI_LAB_SETTINGS`, `CODEX_HOME`, and
`WOI_LAB_API_BASE` (HTTPS only). Secrets never enter the page or evidence logs.

The server binds only to loopback. It validates Host, Origin, Sec-Fetch-Site,
JSON content type, request length, and request IDs; rejects cross-origin CORS
preflights; serves an explicit static-file allowlist; and limits concurrent
model requests. Use the launcher for a separate Chromium app window.
