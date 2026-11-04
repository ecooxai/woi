# Click accuracy bench

Measures where click_screen clicks land, from the voice model's tool call down to
the real X event. Results and the analysis are summarised in research/REALTIME_API.md
("Click accuracy").

Results go to `$WOI_BENCH_RESULTS`, by default `$TMPDIR/click_bench_results`.
Auth comes from `$CODEX_HOME/auth.json`, read-only: tokens are never printed and the
file is never refreshed or written. Models: gpt-realtime-2.1 and gpt-6-luna only.

## Synthetic screens (model only, no app)
- `targets.py --layout N --out DIR --render-only` renders a 1600x900 page and its target boxes
  into `pages/` (layouts 0-2 are checked in).
- `bench_rt.py`: realtime x/y accuracy. Variants: base, native, img512, grid,
  note_scale, som, som_text.
- `bench_zoom.py`: two-stage realtime zoom.
- `bench_luna.py`: luna with the app's click tool.
- `bench_ground.py`: luna as a locator, using the app's `kLocateInstructions`;
  `--res crop` crops around a hint.
- `probe_*.py`: measure the image budget (tokens and detail) of realtime vs luna.
- `fit.py`: affine fit of the errors (a scale or offset bug would fit cleanly).

## End to end on a nested X display (:11)
1. `python web/server.py 8765 $WOI_BENCH_RESULTS/web`. Then start Chromium on :11
   with `--force-renderer-accessibility --kiosk http://127.0.0.1:8765/`, with
   `DBUS_SESSION_BUS_ADDRESS` set so its AT-SPI tree is visible. The page posts its
   35 target boxes and logs every mousedown.
2. Save the screen as `$WOI_BENCH_RESULTS/web/shot_web.png`
   (`ffmpeg -f x11grab -i :11 -frames:v 1 ...`).
3. Stage A: `python bench_web_rt.py --spec old|target`. gpt-realtime-2.1 answers
   "Click <target>" with the app's click_screen tool, on the 1280-wide capture
   the app sends.
4. Stage B: `app/test/live/click_bench_live_test.dart`. It replays those tool
   calls through the app's planClick, locator chain, LinuxScreenCapture and
   xdotool, then reads the click position from the page's log. Set
   `WOI_CLICK_MODE` to one of:
   - `oracle`: the exact centres, which checks the coordinate mapping
   - `xy`
   - `element`
   - `vision`
   - `chain`
5. `python marks_stageb.py $WOI_BENCH_RESULTS/web` draws the clicks over the
   screenshot.
