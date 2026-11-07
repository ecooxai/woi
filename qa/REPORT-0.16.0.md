# Woi 0.16.0 acceptance record

Branch: `gpt-6-astra-pro/woi-settings-cleanup-20261107`.
Base: `b945fcf` (`v0.15.1`), published before this task began.

## Scope

Reorganize Settings into Connection, Model, Preferences and one collapsed
Advanced section at the bottom. Connection separates login method from audio
model selection. Model contains audio, text and voice choices; custom values,
independent compaction configuration and the effective usage-guard model remain
visible and editable as appropriate.

## Selection behavior

- Connection/model/voice helpers retain the existing JSON schema and saved
  inactive-family values. API uses realtime audio; returning from API to Codex
  preserves the realtime selection.
- Voice choices affect only the active family's voice. Invalid combinations
  receive a clear reason rather than silently changing another setting.
- Editing an inactive API key does not reconnect a Codex session.
- The live backend forwards nonempty explicit custom model IDs. Empty models,
  known realtime IDs on the live transport, and unsupported live voices fail
  before transport creation. Provider rejection is visible without a substitute
  request. Existing invalid legacy live voices remain saved and visible so the
  user can choose a supported voice explicitly.

## Completed verification

- Focused settings, live-backend and managed-capture tests: **46/46 passed**.
- Independent helper/backend review: passed; no storage or compatibility blocker.
- Focused Settings and Home navigation tests: **10/10 passed**. They cover model
  and voice compatibility, saved custom values, search, narrow layouts, pending
  drafts and caret preservation, field-level merging, debounce/disposal saves,
  reactive usage-guard notices, and Back/Escape sign-in dismissal.
- Full application static analysis: **no issues**.
- Independent source/test review: passed. All **31** previously editable
  settings and existing authentication, diagnostics and Android actions remain
  reachable. Cancelling sign-in preserves settings.
- Full offline Flutter suite (`WOI_LIVE=0 flutter test --no-pub --reporter
  expanded`): **803 passed, 15 skipped**, exit 0.

The first Linux and ARM64 Android release candidates compiled successfully.
Native review then found a selected-dropdown height regression (about 24 px
instead of a full touch target). Those artifacts are retained only as superseded
candidate evidence. The actual dropdown button now keeps a minimum 48 px hit
area; the regression taps near its lower edge, chooses a model and verifies the
saved setting at phone and desktop widths. Final corrected source passed the
full analysis and 803-test suite above.

Native review captured 22 screenshots across desktop/narrow, light/dark,
compatible/incompatible choices, custom IDs, Advanced/search and sign-in
dismissal. Both private app logs contained no layout or unhandled exceptions.
Final corrected Linux and ARM64 Android release builds both passed. Native
checks of the rebuilt Linux app passed at desktop/light and 360 px/dark sizes;
near-edge taps opened the selected-model menus and saved a new choice in both
layouts. No overflow, unhandled exception, assertion, GTK-critical or fatal
entries appeared in the final private app log. All private test processes were
stopped.

The exact ARM64 APK was installed as an update on the connected phone and the
app restarted: version **0.16.0**, version code **2017**. The complete enabled
accessibility-service list and flag were preserved, Woi remained bound, and the
new process produced no fresh fatal startup errors. Actual-phone Settings
inspection passed: Connection, Model, Preferences, Advanced and search render
cleanly, and existing account/model/voice selections remain intact.

During phone QA, a tap after scrolling briefly changed Reply delay from its
original 2.0 s to 1.1 s. It was restored to exactly **2.0 s**, then verified in a
recreated Settings view. The expected reconnect completed without a new visible
error. The search was cleared, Advanced returned to its collapsed default, and
the phone was returned to Chat with an empty composer and hidden keyboard.
No other observed preference was changed.

The 15 full-suite skips require opt-in provider access, native desktop test
environments/benchmarks, a configured acoustic rig, or a native PTY library
path. Arbitrary custom model IDs are forwarded and rejection is surfaced;
provider acceptance of arbitrary custom IDs is not established by this offline
suite. Native audio/control code is unchanged from the separately verified
0.15.1 release.

Evidence belongs under ignored `qa/out/acceptance-0.16.0/`. The previous patch's
verified builds and evidence remain available separately.

## Artifacts

The Linux archive contains the complete tested bundle (55 entries, 39 regular
files), including required libraries and the pinned Codex executable. Its
contents and permissions match the compiled bundle. The ARM64 APK package,
version and ABI match the release configuration. Both artifacts refer to the
same frozen application source.

```text
f6c2e24ccd0fd72778f7206a0a69b9a645529327b36e45815c2c2490fef6a955  woi-0.16.0-android-arm64.apk
b0c94cde02af585b664a5407313452fc52565f9a7fef6aadc0489097bdc0eb08  woi-0.16.0-linux-x64.tar.gz
```
