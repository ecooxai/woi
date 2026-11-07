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
