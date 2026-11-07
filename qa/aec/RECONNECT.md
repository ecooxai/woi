# Linux system-reference AEC reconnect check

Run from the repository root with PipeWire, pipewire-pulse, `pactl`, `pw-play`,
`pw-record`, and Flutter's Dart available:

```sh
python3 qa/aec/reconnect_smoke.py
```

The rig creates uniquely named virtual speaker, room, microphone, and loopback
nodes. All capture and playback is pinned to them; the rig does not set default
sound devices or play through physical speakers. It checks that defaults stay
unchanged and unloads its own modules in `finally`. Do not run concurrently with
another instance of this script because output filenames are shared.

A seven-second deterministic noise-and-tone signal is played into the virtual
speaker, then echoed into the virtual microphone with a 60 ms loopback delay.
The production `PipewireEchoCancel` class supplies its cleaned source. The raw
and cleaned microphone streams are recorded side by side. The same procedure
runs after a quick release/reacquire, a full linger shutdown, and an acquire
that overlaps shutdown. A final independent near-end signal is played into
the room only to verify that useful microphone audio survives.

The pass thresholds are at least 20 dB far-end RMS suppression after convergence
(seconds 4–6), and no more than 6 dB gain change for the independent near-end
signal. `qa/out/aec-reconnect/result.json` contains measurements and `probe.log`
contains the source names used for each generation. Raw PCM files are 24 kHz,
mono, signed 16-bit little-endian. These virtual-loop measurements test routing
and reconnection; they are not physical-room or speech recognition scores.

## Recorded validation, 2026-11-07

| Stage | Far-end RMS reduction |
| --- | ---: |
| Initial capture | 49.88 dB |
| Quick reconnect | 75.42 dB |
| Cold reconnect | 64.10 dB |
| Shutdown race | 62.16 dB |

The independent near-end signal changed by 0.52 dB, and system defaults stayed
unchanged. Flutter regression tests additionally cover a reconnect while the
previous user releases, a disappeared source after an audio-server restart,
late startup after disposal, crashed-host config cleanup, native RTC source
publication delay, cancellation during that delay, and held-recording cleanup.
