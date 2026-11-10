# Woi v0.22.1 — verification and improvement report

Date: November 10, 2026. This report describes the improvement release following the separately published [v0.22.0](https://github.com/ecooxai/woi/releases/tag/v0.22.0), whose [original verification report](https://github.com/ecooxai/woi/blob/v0.22.0/qa/REPORT-0.22.0.md) remains unchanged. The initial release was verified at 08:55:31 UTC. The requested four-hour improvement period was completed, and work continued to resolve two concrete integrated-test blockers and finish the accepted release.

## Release and build identity

[Release and source tag](https://github.com/ecooxai/woi/releases/tag/v0.22.1) · [ARM64 APK](https://github.com/ecooxai/woi/releases/download/v0.22.1/woi-0.22.1-android-arm64.apk) · [SHA-256 checksums](https://github.com/ecooxai/woi/releases/download/v0.22.1/woi-0.22.1-SHA256SUMS.txt) · [Build provenance](https://github.com/ecooxai/woi/releases/download/v0.22.1/woi-0.22.1-provenance.json)

| Field | Verified final value |
| --- | --- |
| Flutter version | `0.22.1+24` |
| Android package / version | `dev.woi.woi` / `0.22.1` / version code `2024` |
| Native Android ABI | `arm64-v8a` only |
| APK | `woi-0.22.1-android-arm64.apk` — **102,271,983 bytes** |
| APK SHA-256 | `47a223ab7188271ab98563a15d9c1eb6432b6fc17e030cdc90aad15ee6f43f8c` |
| Signing certificate SHA-256 | `54921a3a54191e8545842cdf135b7603043f58e9e392c77fb484c0cccd8e3f4f` — matches v0.22.0 |
| Matching AndroidTest APK | Built successfully, 94,280 bytes; signature and target package verified; not installed or executed on a phone |

The normal pub-enabled Flutter release build completed successfully at 16:34:23 UTC. Its matching AndroidTest build began 0.356 seconds later, with no intervening Flutter test, analysis or dependency-regeneration command, and completed successfully at 16:34:31 UTC. The main APK and R8 mapping stayed byte-identical across the test build, and the Flutter and Gradle main APKs matched. ZIP integrity, unique entries, Android manifest version/package, ARM64 contents and signature continuity were verified. The final artifact is preserved separately from the earlier unpublished candidate14 package.

The complete Flutter suite passed **1,484 tests, with 15 existing optional skips and zero failures**. Full analysis reported **No issues found**. These gates ran at **0.22.1+24** on the exact corrected application and test source freeze used for final packaging. Source verification remained identical before and after the suite and analyzer.

- Final source/test map: `b570aac5e3e02f09aff55499fa47e66334aef329bfc40b39837871dd650434a5` (557 files).
- Final production map: `95da34282f240a1c4b2d5a633d94867778225cefb25ebb8c2cbc7a0e2ed38a8c` (401 files).
- Final Linux `libapp.so`: `8a006a534387585ebf7dde247b81c5d79dcbb2f4933a7ff6fa47928e65a96266`.

The corrected Linux bundle contains 42 individually verified immutable files, with matching paths, sizes, SHA-256 hashes, modes and internal-symlink checks. Compared with the immediate predecessor, it changes the application binary and includes an empty 45-byte generated native-assets manifest; both use version metadata 0.22.1/24. Its separately bound shell acceptance is described below. The earlier Note Run, AI edit and idle observations remain explicitly tied to the predecessor artifact.

The 15 skips comprise nine optional provider/live-OpenAI cases, one AT-SPI case, one ClickBench case, two native-PTY cases whose library could not load, one offline-AEC case and one live-X11 case. Their absence is explicit; they are not counted as passes. Individual focused gates overlap and are not added to the integrated total.

## Original requested features and observed scope

| Requested feature | Implementation and exercised behavior | Boundary |
| --- | --- | --- |
| Clipboard tab, text/image history and actions | Text and image capture; exact Unicode/multiline Copy/Paste; normalized-image Copy; Send-to-AI staging and removal; duplicate handling; Capture, Find and Clear/Cancel. Compact and large-text actions were checked in the isolated Linux app. | Staging is distinct from a completed assistant-tool action. Physical Android cross-UID image clipboard acceptance remains open. |
| Note word selection and Copy | Selected and whole-note Copy returned exact text. Formatting, Undo/Redo, source dock, previews and durable pasted images were exercised. Deletion refresh and title consistency were repaired without discarding custom titles/editor state. | Final Note Run and approved AI edit/Undo results are stated separately below. |
| Image paste into editor and chat | A pasted note image remained after removal of its clipboard-history entry. Chat image staging/removal retained the draft. The viewer expanded, zoomed, reset and closed. | Android keyboard, paste and multiple-attachment behavior needs physical-device acceptance. |
| Native file picker | Linux Open/Cancel, multiple selected attachments, removal and exact draft/selection retention were exercised. | No new physical Android picker/select/cancel/assistant-return acceptance. |
| Live append beyond 500 bytes | Fixed native control-event delivery. A separate 1,704-byte Unicode input completed as five bounded parts plus one completion. A fresh delayed real search later completed nine ordered, acknowledged sends totaling 3,763 bytes of application-level bodies. | These checks establish bounded local delivery and receipts, not raw remote byte/hash equality or persistence of a requested 1,800-character written explanation. |
| Image/link previews | Note links/source dock, source navigation and chat image viewer were exercised. Generated attachments use compact labels only when explicit metadata and the complete suffix agree; complete Copy and provider text are preserved. | Ambiguous legacy text remains literal. Recorded sent-size fixtures prove UI rendering, not a fresh provider transmission. External-viewer coverage is narrower. |
| Grouped settings | All 11 Linux groups were inspected in normal/compact/large-text layouts. Theme changes persisted and were restored; About and shortcuts were exercised. | Most alternate effects are visible-only; the Android-only group is absent on Linux. |

Other bounded isolated checks covered terminal and Find, draft preservation, synthetic voice/PTT, pointer and keyboard actions, web search and source navigation, one configured image generation and one source-bound edit, and one selected-model Click Lab trial/export. The successful PageUp check is keyboard scrolling; it is not acceptance of a dedicated screen-scroll tool. This report does not claim that every function or setting was executed.

## Improvements after v0.22.0

| Change | Accepted source | Verification |
| --- | --- | --- |
| Keep the selected top-level tab visible through viewport/text-scale changes, and keep voice-error actions reachable at compact widths/200% text while retaining drafts and images. | [c953424](https://github.com/ecooxai/woi/commit/c953424d1ad2bd74e73ca809700a3e29c605efa4) | 71 focused tests, clean analysis, independent source/native review. |
| Correct contextual action routing and bounded dependent input; focus the intended target and deliver text once through the screenshot/pointer/key/text sequence. | [635a3ca](https://github.com/ecooxai/woi/commit/635a3ca7a64c110cabc770d0f820fadb375b86b5) | 183 focused tests, clean analysis, independent native acceptance. |
| Refresh Notes immediately after deletion and use consistent system-only headings across active/inactive tabs and History while preserving custom titles. | [367be92](https://github.com/ecooxai/woi/commit/367be92a9c8077c5b1de6a1c3d7caf360952fb90) | 73 focused tests, clean analysis, independent source/native review. |
| Compact trusted attachment labels, correct image labels/recorded dimensions, and scrollable compact Clipboard Clear confirmation. | [78f1758](https://github.com/ecooxai/woi/commit/78f1758d2fa8d55496e7ae8678d740ccc74d5879) | 229 focused tests, clean analysis, independent source/native review. |
| Consume native data-channel control/transcript/turn events with one authority, bounded readiness and stale/cancellation guards; keep sideband audio separate; close native resources promptly and late sockets after Stop. | [a8faf96](https://github.com/ecooxai/woi/commit/a8faf966f0804450a9b9ae20374e0af4e7eda8c6) | 144 focused tests, clean analysis, independent source/native acceptance. |
| Use the live-specific sideband ping policy while retaining the generic 20-second default; serialize same-message audio writes; correct the continuation test fixture. | [ed93b43](https://github.com/ecooxai/woi/commit/ed93b43a2c3310e6b4c0e879bf6da9aad1a17bd5) | Reviewed local-peer and controlled-storage regressions, accepted delayed native search, and the then-current 1,458-test integrated gate. |
| Recognize explicit shell-tool requests, including bounded fronted locations, and suppress unrelated nonvisual screenshot speculation while retaining approval and cwd handling. | [bcf238c](https://github.com/ecooxai/woi/commit/bcf238cdc22af881e0f4155a2c3c223daa2890f2) | 187 focused tests, preserved failing-before cases, independent exact-source review, and the new 1,484-test integrated gate. |

## Live transport acceptance and its limits

A private observation found that the native data channel delivered a context acknowledgement while the application ignored that ingress path and eventually timed out. A separate retained-media comparison did not repair delivery. The accepted correction consumes data-channel control events with a fixed per-session authority; it does not keep the microphone alive as a workaround or blindly merge duplicate acknowledgement streams.

During the accepted data-channel iteration, an early 94-byte ordinary input received its acknowledgement in 280 ms and produced transcript plus 5.6 seconds of reply audio. A separate delayed synthetic Unicode input of 1,689 characters / 1,704 UTF-8 bytes completed as five bounded developer parts plus one completion, with every acknowledgement, exact composer/sent-message Copy and 3.2 seconds of reply audio. Clicking the actual red Stop button while the first part was pending suppressed all later parts and the completion even when that part's acknowledgement arrived afterward. This proves app-side suppression, not server termination.

Explicit Reconnect preserved an exact 61-byte unsent Unicode draft. A private synthetic PTT fixture produced the expected user transcript, 1.88 seconds of saved user audio from a 2.17-second fixture and one assistant reply with 4.6 seconds of audio. These are null-source/synthetic checks, not physical-microphone acceptance or proof that every original audio byte was saved.

The original real-search attempt retained its 316-character / 318-byte tool result and 13 source records plus one inline URL, but a sideband 1001 closure interrupted composed-answer delivery. It was not retried under the same request. That failure remains distinct from the subsequent accepted fresh search.

The later live-only ping change was supported by a local raw-peer regression and a separately reviewed delayed control. The generic socket's 20-second default remains unchanged. The evidence does not identify the initiator of every historical 1001 closure.

The accepted fresh search before the final shell-routing correction used one connection and one ordinary 274-byte UI request, submitted 47.007 seconds after readiness. One `web_search` invocation was recorded; the trace also included a screenshot tool, so this is not a claim of one tool or one internal HTTP request in total. The result delivery sent eight developer parts plus one completion, with body sizes **484, 378, 494, 494, 488, 494, 493, 188 and 250 bytes**. All nine ordered acknowledgements arrived on the same call. The first send was at readiness +69.774 seconds and the last acknowledgement at +72.389 seconds. Local dispatch-to-acknowledgement intervals were 239–460 ms; these application callbacks are not measured wire round-trip latency.

The saved search result was **377 characters / 379 UTF-8 bytes with 13 source records**. The brief assistant reply was **129 characters / 131 bytes**, with an independently verified **11.0-second, 24 kHz mono WAV** and the corresponding visible UI. The prompt's requested 1,800-character written explanation was not persisted by this ordinary typed-action path. Its existing 2,400-character tool-result budget and short-sentence spoken cue remain unchanged. No full written-answer, exact remote payload hash, or validity/distinctness of all 13 source URLs is claimed.

The accepted delayed-search runtime closed normally, with zero capture streams and unchanged protected process identities. Earlier aborted harness/setup attempts and one guardian-terminated runtime are retained separately. An app-owned uncorked null-source stream was observed at startup in the existing setup; sender detachment alone is not evidence of device release before append. Verified zero-capture teardown is the separate condition used here.

## Integrated failures were resolved, not waived

The first integrated run found an outdated single-use streaming-model fixture. A legitimate second continuation response attempted to complete the fixture's one-shot signal twice. Three test lines supplied a terminal second response and asserted the two requests and final answer while preserving the original early-dispatch/dedup checks. Its ten focused tests passed; production did not change for that repair.

The next integrated run reached a resumed-turn audio duration timeout. An isolated run passed, but the failure was investigated rather than dismissed. The exact retained synthetic record had stale **200 ms metadata beside a complete 400 ms WAV**. Source review found unordered writes and unconditional completion assignments for the same message. A controlled original-code write-order regression separately reproduced **both WAV and metadata reverting to 200 ms**. The narrow per-message write queue orders actual file persistence and metadata completion, allows unrelated messages to proceed, and recovers after a failed write. The repaired controlled regression and original affected tests passed, followed by the complete green integrated gate. The observed integrated file was not truncated; the controlled case establishes that additional ordering risk separately.

## Versioned UI checks and the corrected shell route

The immediate predecessor versioned bundle (candidate14) received exactly three user requests with no provider-request retry:

| Case | Observed outcome |
| --- | --- |
| Selected Note Run | The exact 67-byte selection was sent; the 145-byte note and 44-byte unsent draft remained exact. A reply and 3.6-second audio were delivered with no tool calls. The literal `NOTE-RUN-628` oracle was **not met**: the saved text was `NOTE-RUN- six two eight`. This is qualified functional dispatch/preservation coverage. |
| Approved AI note edit and local Undo | One 147-byte request showed only the requested line replacement. The original 145-byte note remained unchanged before Apply; one Apply produced the exact 144-byte expected note; one local AI Undo restored the exact 145-byte original without another user/provider request. The note-control result succeeded and 7.8-second narration was saved. One incidental ordinary-route screenshot was recorded. Draft-preservation evidence above belongs to the Note Run case. |
| Original shell approval attempt | One exact 259-byte request returned acknowledgement and 4.4-second audio with zero tools, zero shell invocation, no approval dialog and no Run/Deny click. The private cwd stayed empty. Approval/execution was **not demonstrated** by this predecessor attempt. |

Independent source review then identified a local classification miss: the explicit “Call run_bash…” wording fell through to ordinary live text even though the registered shell tool and its confirmation handler were available. The native voice transport does not itself provide that function-tool route. The subsequent narrow repair recognizes the explicit shell request and uses the same bounded fronted-location parsing for routing and nonvisual speculation suppression. Approval, registry and working-directory checks remain intact. Direct and fronted missing/stale-image regressions were verified, including failing-before evidence; this is not attributed to a delegated model refusing the original command.

On the corrected candidate15 build, the same exact 259-byte request produced one shell-tool call and no other tools. Before approval, the pending 34-byte command, private working directory and five-second timeout were verified, and the real confirmation dialog was inspected. One Run click executed the command once. Its result was exactly 19 bytes of stdout (`SHELL-APPROVAL-628` followed by a newline), empty stderr, exit code zero and no timeout. The private directory remained empty.

There were two UI Send attempts. The first occurred while the voice session was offline and was explicitly not dispatched: there were no stored user turns, tool calls or dispatch events, and the exact draft remained. After explicit reconnect and fresh readiness/no-pending-replay checks, the second click created the sole actual provider request. There was no subsequent resend, tool replay or repeated approval.

The shell result was delivered through acknowledged 469-byte and 382-byte developer appends plus a 250-byte activation append. **Spoken follow-up remains unconfirmed:** no assistant text or audio was saved before the existing confirmed-reply timeout, 60.002 seconds after the final acknowledgement. The saved trace shows no post-result disconnect, standby or cancellation before that deadline. The cause is not established, and successful command execution is not a broader voice-response acceptance claim.

The corrected native session closed normally. Its owned application, wrapper, guardian and clipboard helper exited, capture and clipboard ownership returned to zero, and protected user/target/infrastructure process identities remained unchanged. No service/device reset or running-user-app restart occurred.

Setup input-tool mismatches were preserved and corrected through private clipboard paste and exact copy-back before provider requests. The records distinguish immediate snapshots of early clipboard helpers from the explicitly observed final ownership transition. The predecessor provider and idle sessions both closed normally with their owned processes/helpers gone, zero capture/clipboard ownership and unchanged protected process identities.

## Bounded performance observation

The one matched idle sample was taken on candidate14 before the final explicit-shell routing correction. Its results remain bound to that predecessor, alongside the earlier candidate4 baseline:

| Metric | Earlier candidate4 baseline | Candidate14 predecessor |
| --- | ---: | ---: |
| Elapsed seconds | 20.040 | 20.039 |
| CPU seconds | 0.12 | 0.07 |
| Percentage of one core | 0.60% | 0.35% |
| RSS minimum, KiB | 270,488 | 263,084 |
| RSS median, KiB | 291,162 | 273,148 |
| RSS maximum, KiB | 296,888 | 277,020 |
| Lifetime high-water RSS, KiB | 363,596 | 358,792 |

The canonical seven-file fixture hash-matched the earlier record: six history entries and three images totaling 32,769,264 bytes. The actual Clipboard/history view was checked at 360×860 and 100% text. Both observations used software rendering, muted microphone, an empty clipboard, private XDG/TMPDIR and a warm shared host with network namespace isolation disabled. SDK, provider and artifact activity was held during the new 20-second sample; the process start identity was checked on every sample, without screenshots during measurement. In the new sample, `XDG_STATE_HOME` was additionally private whereas the baseline left it inherited. These are two bounded shared-host observations, not evidence of a measured speedup, a statistical/device benchmark or new startup/readiness timing. No additional performance run is presented for the later routing correction.

## Distribution and remaining acceptance limits

The GitHub prerelease contains the ARM64 APK, a checksum file and safe provenance binding the exact committed application map to the build inputs. It retains the project's established development signer. The independently verified Linux bundle is kept separate from the already running user executable. Default user profiles and drafts were not inspected or migrated during isolated QA; final launcher activation is guarded separately and does not restart the running app.

At 16:32:40 UTC on November 10, the ordinary read-only ADB inventory for this corrected final build returned no attached transports. No phone was installed, reset or used for instrumentation. Physical Android acceptance therefore remains open, including cross-UID image clipboard behavior, on-screen keyboard/selection, picker and assistant-return behavior, microphone/camera permissions and device performance. Continuous physical capture and most alternate setting effects also remain outside the accepted coverage. Synthetic/null-source Linux audio and a matched Android build do not substitute for those hardware checks.

The original v0.22.0 tag, APK and provenance remain immutable. Private profiles, raw provider logs, screenshots, credentials, intermediate diagnostics and binaries are excluded from the source commit. The public assets contain the APK, checksums and safe provenance; the report states measured outcomes and their boundaries without exposing private runtime data.
