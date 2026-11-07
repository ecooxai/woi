# Compact chat native visual QA

This check uses the existing release binary after the build owner signals readiness. It does not build or use a production login/history. Display `:74` is reserved for this check; root's integrated network E2E stays on `:71`.

## Prepared fixture

`python3 qa/ui_native_visual.py prepare` creates synthetic settings and history under ignored `qa/out/ui-native`. It seeds a user exchange, an older assistant reply without model metadata, and a current reply attributed to `gpt-live-1.1`. Synthetic retained context makes the used-context arc visible.

The launcher uses Xvfb and Openbox on `:74`, a private network namespace, a masked Codex authentication directory, and separate XDG state/cache/runtime paths. HOME and CODEX_HOME are unchanged. Host audio endpoints are unavailable to the app and its mic is forced off. The API key is a harmless offline placeholder; no credential is loaded or sent.

## Run after build-ready signal

1. `python3 qa/ui_native_visual.py start --binary <built-bundle/woi>`.
2. Inspect `qa/out/ui-native/shots/desktop-initial.png` using rubyterm's `get_image` before choosing any click coordinates.
3. Check the desktop composer: text field above one row; status and context at the left; mic and send at the right; send at the far right. There should be no model badge or mic-mode selector in the composer.
4. Inspect assistant footers: the attributed reply shows `gpt-live-1.1` directly below it; the legacy reply says `Model not recorded`. User messages have no model footer.
5. Move to the status icon, capture the hover details, and click it to capture the detail popup. Check text readability and popup positioning. This isolated profile is offline, so connection failure/reconnect details are expected.
6. Click the context circle and capture its detail popup. Check used/available context, the retained-summary breakdown, and controls remain readable. Dismiss with Escape.
7. Run `python3 qa/ui_native_visual.py resize --width 360 --height 740`; select the Chat tab if the narrow layout opens Note. Inspect the fresh screenshot, check no clipping/overlap, model footer placement, and all bottom controls fit.
8. Repeat at `400 x 860`, including status and context popup screenshots. Compare send placement with the desktop layout.
9. Read the private app log for Flutter exceptions/overflow. Record observed results and screenshot names in `qa/out/ui-native/report.txt`.
10. `python3 qa/ui_native_visual.py stop` terminates only this script's recorded private processes. It leaves the user's desktop, audio, root's E2E display, and production app alone.

Use `python3 qa/ui_native_visual.py shot --name <descriptive-name>` after each interaction. All UI actions must explicitly target `DISPLAY=:74` and the recorded window; choose coordinates from the latest screenshot. The widget suite separately verifies taps, hold cancellation, 48dp targets, live model attribution persistence, and old PTT activation behavior, which cannot be exercised as live network behavior in this offline profile.

## Settings follow-up

Use the same private offline fixture after the settings build is ready. Keep
its evidence in `qa/out/acceptance-0.16.0/ui/`. The launcher writes to
`qa/out/ui-native` and replaces its logs and initial screenshot: archive that
directory before starting this phase, then copy the new captures and logs into
the phase-specific evidence directory before another start.
Open Settings with Ctrl+, and choose coordinates only from a fresh screenshot.

- Inspect desktop and narrow layouts in light and dark themes. Confirm clear
  Connection, Model, Preferences and bottom Advanced sections without clipped
  controls or oversized repeated descriptions.
- Codex login status precedes API access. Backend offers Codex login or API;
  transport/model names belong in Model.
- Audio exposes the two requested quick choices and a More selector. Check the
  selected state and long/custom values; realtime and live choices must retain
  their explicit family. Text model remains independent of compaction.
- Voice offers Marin/Echo plus More. In a live configuration, incompatible
  realtime voices are unavailable with a concise explanation and the current
  supported live voice remains visible.
- Changing models in this synthetic profile must preserve authentication, while
  API makes live choices unavailable. Do not enter real credentials or invoke a
  real login flow. Core tests verify persistence and provider request contents.
- Advanced starts collapsed. Expand it, reach all internal groups, search for a
  buried option such as stop words or workspace, clear the search, and verify
  the intended expansion state returns. Check narrow dropdown/popup placement.
- Check saved edits and custom fields through the widget interaction regressions;
  controller notifications must not overwrite an unfinished local edit.
- Read the private app log for overflow/exception patterns, record observed
  outcomes and the binary hash, and stop only this launcher's recorded processes.

On the actual phone, inspect the installed Settings view and Android-only
controls without changing authentication, models, audio preferences or other
user settings. Wait for inertial scrolling and reconnection-driven layout
changes to settle, then inspect a fresh screenshot before choosing a tap target,
especially near sliders. Expanding/collapsing sections and scrolling are transient. Return
to the user's previous view and hide the keyboard afterward. Do not publish
account identifiers, credentials or conversation contents in screenshots.
