# Woi 0.17.0 acceptance record

Branch: `gpt-6-astra-pro/woi-images-search-settings-20261107`.
Base: `3fef690` (the committed 0.16.0 settings cleanup).

## Scope

- Backend selection immediately reveals Codex account status and usage, or the
  API-key field. Inactive credential drafts are retained and saved safely.
- Image model discovery, custom IDs and quality choices in Settings. The exact
  requested default is `gpt-image-flare-2.1`, quality `low`.
- `generate_image` runs independently in the background, persists its pending
  state and completed attachment in the originating chat, and reports failures
  or interruption explicitly. Switching/reopening chats retains the correct
  conversation; deletion prevents late writes and removes generated files.
- Generated images retain actual encoded bytes, pixel dimensions, model,
  quality and elapsed generation time. Large image and generic file viewers
  show file metadata, including the separate Linux viewer window.
- `web_search` is enabled by default, performs native live searches through
  Responses, and preserves clickable HTTP(S) source links in chat. Disabling
  search updates the active session and blocks stale tool dispatches.
- Linux microphone/send visuals are 40 px and camera 44 px, with 48 px hit
  targets. Android retains 48 px controls. The camera has a light green circle
  when off and a darker green circle when on.
- Ordinary Android source links open without starting the sign-in foreground
  service. PKCE login retains its existing keep-alive flow.

## Live provider verification

One real Codex image request used the exact default model and low quality with
`gpt-6-luna` as its orchestration model. It returned a valid **1254 × 1254 PNG**,
**1,038,573 bytes**, in **13,694 ms**. The prompt was a simple green circle on
white. No replacement model or second provider image request was used. Image
header, byte size and SHA-256 were checked independently. Evidence:
`qa/out/acceptance-0.17.0/image-live.json` and connector terminal `34594`.
This is one smoke-test latency, not a general performance guarantee.

A real Codex search for official Dart Future documentation returned a completed
native search and usable `api.dart.dev` sources in **3,872 ms** with
`gpt-6-luna`. Connector terminal: `34584`.

Codex's model-list endpoint did not advertise image models, despite the
successful exact-default generation. Settings therefore labels its documented
candidate list accurately and preserves the selected/custom ID. Other image
models were not exhaustively generated against this account.

No saved API key or `OPENAI_API_KEY` was available for a live public-API request. Local HTTP/SSE
mock transport regressions exercise both API-key and Codex request routes,
exact model/quality forwarding, provider errors, source parsing and failure
handling. They do not establish API-account entitlement.

## Verification and delivery

- Final static analysis: **no issues**.
- Full offline Flutter suite: **843 passed, 15 skipped**, exit 0; 109.12 s.
- Focused settings/composer regressions: **44 passed**.
- Final Linux release build: **passed**, 58.59 s.
- Final ARM64 Android release build: **passed**, 102.91 s.
- Native Linux UI review: **passed** on desktop and 360 px layouts, including
  conditional backend fields, image controls, default-on web search, light/dark
  composer, interrupted/error states, the corrected large-image dialog,
  separate image viewer and generic file-size metadata.
- Linux archive: all **39 regular files** checked against the final bundle for
  contents and permissions; executable mode retained.
- Android package: **dev.woi.woi**, **0.17.0**, version code **2018**, with all
  **22 native libraries** restricted to **arm64-v8a**. APK signature verifies and
  its signing certificate matches the previous 0.16.0 release.

The full suite covers request bodies and errors for both auth routes, source
links, active-session tool gating, queued image dispatch, chat switching and
reopening, interrupted jobs, deletion racing with queued writes, failed history
writes, generated-file cleanup, viewer metadata and Android link behavior.

One initial full run exposed a widget-test teardown deadlock: the strengthened
history flush waited for a fake-zone file-write continuation while teardown had
stopped pumping that zone. The test now conditionally drains I/O and callbacks
with a bounded timeout, preserving all assertions and production flush behavior.
The corrected complete run above passed. The 15 skips require opt-in provider,
native desktop/acoustic or PTY environments, as in the prior release.

Native review of the first candidate found Flutter fallback yellow underlines
in the large-image dialog. The dialog now supplies its themed text inheritance.
Its regression opens the actual dialog route at 360 × 740 and checks rendered
caption, metadata and zoom-label decorations, as well as exact file facts. Both
packages were rebuilt and verified from the corrected source.

Native final evidence is in `native-final.json`, `native-final.md` and the
clean screenshots `017-final-desktop-chat.png` and
`017-final-narrow-lightbox.png`. The isolated UI profile had networking blocked;
provider connectivity was verified separately by the real calls above. No
phone installation, app restart, permission or accessibility changes were made.

### Release payloads

| Artifact | Bytes | SHA-256 |
| --- | ---: | --- |
| `woi-0.17.0-linux-x64.tar.gz` | 167,567,805 | `0e4cc84bc3167b5bbed6210831cdd0663e8c4b42e73e6886f8a7f415cce0597b` |
| `woi-0.17.0-android-arm64.apk` | 100,931,032 | `3dcb2cb63477b4354e87f289baac577630f5141e7beaafc1e1d37dddac62db2f` |

The Linux executable fingerprint is
`705a0ef34ff5fe403917009457d70ad079a5c1a6c85c6317ee4c77b83a937e3d`;
its compiled Dart library fingerprint is
`002698fe612f8bcb462008a4594df1477c8ad6a4e29158f633e715181bf2da70`.
The Linux archive was compared with these exact final build files.

Working evidence is under `qa/out/acceptance-0.17.0/`; release payloads and the
checksum manifest are under `qa/out/release/`.

## Reference documentation

- [Codex search configuration](https://learn.chatgpt.com/docs/config-file/config-basic)
- [Responses web search](https://developers.openai.com/api/docs/guides/tools-web-search)
- [Image generation](https://developers.openai.com/api/docs/guides/image-generation)

The installed account was tested directly for the requested exact image model;
its success is based on the live result above, not inferred from a public model
name or from the text-model catalog.
