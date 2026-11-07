# Woi 0.18.0 acceptance record

Branch: `gpt-6-astra-pro/woi-jpeg-context-luna-pointer-20261107`.
Base: `e3a03cd` (Woi 0.17.0).

## Requested behavior

- Default image model `gpt-image-2.6-flare`, low quality, 1024 × 1024, JPG.
  The prior default model migrates; custom model choices are preserved.
- Completed generation moves to the bottom of its originating conversation.
- Generated images enter live/delegated context as actual JPEG bytes, retain
  stable reference IDs, and restore when reconnecting/reopening their chat.
- `generate_image` supports explicit edits with a saved reference image via
  public Images edits or the Codex native image tool. Originals are preserved.
- Default-on GPT-6 Luna pointer agent receives a fresh screenshot and a clear
  request, calls only the requested pointer function, and returns no prose.
- User message text appears above image attachments.

## Implementation decisions

JPEG handling validates and converts the actual image bytes; file extensions,
MIME types, dimensions and sizes describe the saved data. EXIF orientation is
baked, and transparent pixels are composited on white for JPEG. Explicit output
sizes are enforced with a centered contain fit, preserving the entire image
without stretching or cropping. Automatic sizing retains the provider size.
Provider dimensions remain available separately from final file dimensions.

Image completion retains its reference ID and moves to the end after any
intervening chat messages. Context delivery is queued before the visible
completion notification. A separate pending-artwork queue prevents camera or
screen frames from evicting a completed image during connection. Three recent
uncompacted generated images restore into new sessions; live delegation marks
these references persistent rather than expiring them like camera frames.

Edits select an explicit message ID within the originating chat or prefer its
latest artwork over automatic screen captures. A missing reference fails before
any provider request. Fresh generations do not inherit an edit reference.

Pointer requests use exact `gpt-6-luna`, `reasoning.effort: none`, a required
single function call and only the relevant pointer tool schema. The model gets
no unrelated chat history. A missing target, invalid coordinates, unexpected
function, cancellation or provider failure sends no native pointer input. The
coordinate transform belongs to the immutable capture given to Luna. Existing
click/move tools route through the same service when enabled; disabling the
setting restores their previous path and refreshes tool visibility.

## Live provider evidence

The first live Codex generation used the requested exact model, low quality,
1024 × 1024 and JPEG parameters. It produced valid red-square/blue-circle artwork
in 13,674 ms, but the provider returned **1536 × 1024**, **64,397 bytes** despite
the explicit requested size. The original evidence is retained unchanged. This
observed mismatch prompted the final contain-fit sizing step above. No alternate
model or extra generation request was used.

A separate 1024 × 1024 JPEG reference was created from that original using the
production normalization helper (52,034 bytes). One live Codex edit changed the
red square to green while retaining the blue circle and white composition. It
finished in **15,710 ms**, saved **1024 × 1024 JPEG, 63,918 bytes**, and recorded
the provider's original 1254 × 1254 dimensions separately. Both input files
remained byte-for-byte unchanged. These were exactly one generation and one edit
with `gpt-image-2.6-flare`; no alternate model or retry was used. Public API-key
generation/edit wire formats are covered by fixtures; the live calls used Codex.

Two live `gpt-6-luna` calls used the production pointer delegate with an 800 × 600
JPEG fixture and a recording input adapter, so they did not move or click the
desktop. The click returned (200, 211), one pixel from its target center, in
**2,001 ms**. The move returned the exact target center (620, 430) in **1,628 ms**.
Each made one required, valid function call with reasoning disabled. Capture
scale and origin were applied correctly to physical coordinates. These are
fixture/provider latencies, not end-to-end native-input timing guarantees.

## Automated validation

- `flutter analyze --no-pub`: clean; no issues (6.44 seconds wall time).
- `flutter test --no-pub`: **937 passed, 15 skipped** (118.89 seconds).
- The pointer guard regression run passed all **55 pointer tests**, including
  affirmative/negative clause order, explicit cancellation and in-flight invalidation.
- The earlier focused integration run passed all **130 tests**, covering image defaults,
  encoding and EXIF, generation/edit wire payloads, chat completion order,
  reconnect/context isolation, camera queue pressure, pointer validation and
  cancellation, settings migration, user attachment order and image metadata.

## Native UI validation

The release Linux app was inspected with an isolated synthetic conversation
using the real saved edit, at desktop width and 360 × 740. The settings visibly show `gpt-image-2.6-flare`, 1024 × 1024, JPG,
low quality and Luna pointer control enabled. User text appears above its image
attachment. The completed edit follows the intervening messages at the bottom.
Its large viewer reports the saved **1024 × 1024 px, 63.9 KB, 15.7 s** metadata,
not the provider's pre-normalization dimensions. Desktop and narrow layouts,
light and dark composer captures showed no clipping or rendering exceptions.
The root reviewer independently inspected the settings, narrow attachment and
narrow viewer captures. Expected network/authentication banners came from the
isolated QA profile. Private QA processes were stopped after capture.

A final review also caught and corrected a pointer guard edge case: a positive
click request containing a negative target constraint must remain actionable,
while genuine stop/cancel commands still cancel pending input. Regression tests
cover this distinction. The final production build follows that correction. Ambiguous unpunctuated
negative requests remain cancelled; a clear affirmative clause is required.

## Final builds and artifacts

The final Linux release build passed in **63.81 seconds**, and the final ARM64
Android build passed in **109.16 seconds**. All 166 declared production source
files stayed unchanged throughout final analysis, tests, both builds and
packaging. The combined production source fingerprint is
`0c54b41d5d1e58e99642c50a1c8caed55fffdf7712009ad089927e0c08f4180b`.

A final native startup smoke using the rebuilt Linux binary also passed, with a
visible 1400 × 900 window and clean completed-image metadata and dark composer.
No rendering exceptions or overflow occurred; the private QA processes were
stopped afterward. The earlier eight UI checks remain applicable because the
final correction changed only pointer request handling.

The Linux archive contains **55 entries / 39 files**, all independently matched
to the final bundle by contents, sizes, modes and paths. The binary is x86-64,
version 0.18.0, build 19. Its executable SHA-256 is
`705a0ef34ff5fe403917009457d70ad079a5c1a6c85c6317ee4c77b83a937e3d`;
its Dart AOT library SHA-256 is
`bb2d59bd7146e9cc63c44a482f11f209986babcc3487a0300303696945e16d29`.

The Android APK is `dev.woi.woi`, version **0.18.0**, version code **2019**, with
**arm64-v8a only**. All 22 native libraries are ELF64 AArch64, ZIP integrity
passes, and APK signature verification matches the prior release certificate:
`54921a3a54191e8545842cdf135b7603043f58e9e392c77fb484c0cccd8e3f4f`.
The release copy matches the built APK exactly. No phone installation or restart
was performed.

| Artifact | Bytes | SHA-256 |
| --- | ---: | --- |
| `woi-0.18.0-linux-x64.tar.gz` | 168,802,097 | `0535085f25b20e49b2a642a59e1754820d308a65566c89cfeac6783cbc80d094` |
| `woi-0.18.0-android-arm64.apk` | 101,193,268 | `ab71ca47e172d16c9faff83090ed5b306b50431333ee24c226089e311f08dd0a` |

`woi-0.18.0-SHA256SUMS.txt` is 189 bytes with SHA-256
`a0782250ed8b068d819128f769041d45cc21b19a4b0c4ce191ad405d1da2e66b`.
An independent checksum verification passed for both artifacts.

Working evidence is under `qa/out/acceptance-0.18.0/`, including
`validation-final.json`, `native-final.json`, `release-artifacts.json`, the
per-platform artifact records and provider probe results. Native captures are
under `qa/out/ui-native-018/shots/`.

## Reference documentation

- [GPT Image prompting and output parameters](https://developers.openai.com/api/docs/guides/image-prompting)
- [Image edits API](https://developers.openai.com/api/reference/resources/images/methods/edit)
- [Responses image tool](https://developers.openai.com/api/docs/guides/tools-image-generation)
- [GPT-6 Luna](https://developers.openai.com/api/docs/models/gpt-6-luna)
