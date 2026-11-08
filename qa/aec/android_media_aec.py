#!/usr/bin/env python3
"""Offline regression for the exact native Android media-route canceller.

Builds the vendored C implementation for the host, then measures residual echo
and near-end speech preservation. It does not access a microphone, provider,
user credentials, or connected devices. Run before the Android release build.
"""
from __future__ import annotations
import ctypes
import json
import math
from pathlib import Path
import subprocess
import numpy as np

ROOT = Path(__file__).resolve().parents[2]
SRC = ROOT / 'app/android/app/src/main/cpp'
OUT = ROOT / 'build/android-audio'
RATE, FRAME = 24000, 480


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    library = OUT / 'libwoi_echo_test.so'
    sources = [SRC / 'woi_echo.c'] + [SRC / 'speexdsp/libspeexdsp' / n for n in (
        'mdf.c', 'preprocess.c', 'fftwrap.c', 'smallft.c', 'filterbank.c')]
    subprocess.run(['cc', '-std=c99', '-O3', '-shared', '-fPIC', '-DFLOATING_POINT',
                    '-DUSE_SMALLFT', '-DEXPORT=', '-I' + str(SRC / 'speexdsp/include'),
                    '-I' + str(SRC / 'speexdsp/libspeexdsp'), *map(str, sources),
                    '-lm', '-o', str(library)], check=True)
    lib = ctypes.CDLL(str(library))
    ptr = ctypes.POINTER(ctypes.c_int16)
    lib.woi_echo_create.argtypes = [ctypes.c_int] * 3
    lib.woi_echo_create.restype = ctypes.c_void_p
    lib.woi_echo_process.argtypes = [ctypes.c_void_p, ptr, ptr, ptr, ctypes.c_int]
    lib.woi_echo_process.restype = ctypes.c_int
    lib.woi_echo_destroy.argtypes = [ctypes.c_void_p]
    lib.woi_echo_reset.argtypes = [ctypes.c_void_p]
    lib.woi_echo_reset.restype = ctypes.c_int

    def pcm(x):
        return np.clip(np.rint(x), -32767, 32767).astype(np.int16)

    def cancel(mic, render, state):
        output = np.empty_like(mic)
        for off in range(0, len(mic), FRAME):
            a, b, c = mic[off:off + FRAME], render[off:off + FRAME], output[off:off + FRAME]
            lib.woi_echo_process(state, a.ctypes.data_as(ptr), b.ctypes.data_as(ptr),
                                c.ctypes.data_as(ptr), len(a))
        return output.astype(float)

    def power(x):
        return float(np.mean(np.square(np.asarray(x, dtype=float)))) + 1e-9

    def erle(raw, cleaned):
        # A digital-zero int16 residual means below quantization resolution,
        # not 200+ dB of physical attenuation. Use a half-LSB RMS floor.
        return 10 * math.log10(power(raw) / max(power(cleaned), .25))

    rng = np.random.default_rng(112608)
    count = RATE * 20
    noise = rng.standard_normal(count)
    # Independent broadband excitation, lightly colored like speech. A changing
    # envelope avoids giving an adaptive filter only an easy stationary tone.
    far = np.convolve(noise, [0.35, 0.25, 0.17, 0.12, 0.07], mode='same')
    envelope = 0.45 + 0.55 * np.sin(np.arange(count) * (2 * np.pi / (RATE * 1.1))) ** 2
    far = pcm(far * envelope * 10000)
    echo = np.zeros(count)
    for delay, gain in [(RATE * 30 // 1000, 0.55), (RATE * 62 // 1000, 0.22), (RATE * 105 // 1000, -0.12)]:
        echo[delay:] += far[:-delay].astype(float) * gain
    capture = pcm(echo + rng.standard_normal(count) * 5)
    state = lib.woi_echo_create(RATE, FRAME, RATE // 5)
    assert state, 'native state allocation failed'
    try:
        cleaned = cancel(capture, far, state)
        stable_erle = erle(capture[-RATE * 4:], cleaned[-RATE * 4:])
        assert stable_erle >= 20, f'stationary echo attenuation too low: {stable_erle:.2f} dB'
        # Same echo, independent near-end speech over it. Require the output
        # to retain correlation and gain, preventing a mute-all "fix".
        t = np.arange(count) / RATE
        near = 2400 * (np.sin(2 * np.pi * 181 * t) + 0.4 * np.sin(2 * np.pi * 577 * t))
        near *= (0.4 + 0.6 * np.sin(2 * np.pi * 2.7 * t) ** 2)
        near[:RATE * 12] = 0
        mixed = pcm(echo + near)
        result = cancel(mixed, far, state)
        # Speex's overlap/add residual suppressor has exactly one 20 ms
        # frame of algorithmic delay. Compare against that delayed near-end
        # signal; a zero-lag comparison incorrectly treats the delay as loss.
        speech_expected = near[-RATE * 4 - FRAME:-FRAME]
        speech_actual = result[-RATE * 4:]
        speech_correlation = float(np.corrcoef(speech_expected, speech_actual)[0, 1])
        speech_gain = float(np.dot(speech_expected, speech_actual) / np.dot(speech_expected, speech_expected))
        assert speech_correlation >= .75, f'near-end correlation lost: {speech_correlation:.3f}'
        assert .45 <= speech_gain <= 1.35, f'near-end speech gain invalid: {speech_gain:.3f}'
        lib.woi_echo_reset(state)
        restarted = cancel(capture, far, state)
        restart_erle = erle(capture[-RATE * 4:], restarted[-RATE * 4:])
        assert restart_erle >= 20, f'reset recovery failed: {restart_erle:.2f} dB'
        report = {'status': 'passed', 'sample_rate': RATE, 'frame_ms': 20, 'tail_ms': 200,
                  'echo_attenuation_db': round(stable_erle, 2),
                  'algorithmic_delay_ms': 20,
                  'near_end_correlation': round(speech_correlation, 4),
                  'near_end_gain': round(speech_gain, 4),
                  'reset_attenuation_db': round(restart_erle, 2)}
        report['device_vector'] = device_vector_regression(lib, cancel, erle, pcm)
        report['frame_contract'] = frame_contract_regression(lib, cancel, pcm)
        (OUT / 'software-aec-results.json').write_text(json.dumps(report, indent=2) + '\n')
        print(json.dumps(report))
    finally:
        lib.woi_echo_destroy(state)


def frame_contract_regression(lib, cancel, pcm):
    """Reject fragments atomically and prove reset cannot replay old overlap."""
    ptr = ctypes.POINTER(ctypes.c_int16)
    first = lib.woi_echo_create(RATE, FRAME, RATE // 5)
    control = lib.woi_echo_create(RATE, FRAME, RATE // 5)
    fresh = lib.woi_echo_create(RATE, FRAME, RATE // 5)
    assert first and control and fresh
    try:
        time = np.arange(RATE * 2) / RATE
        warm_mic = pcm(9000 * np.sin(2 * np.pi * 181 * time))
        warm_ref = pcm(np.random.default_rng(787).normal(0, 4000, len(time)))
        warmed = cancel(warm_mic, warm_ref, first)
        control_warmed = cancel(warm_mic, warm_ref, control)
        assert np.array_equal(warmed, control_warmed)
        assert np.max(abs(warmed[-FRAME:])) > 100, 'reset probe must contain audible pre-reset overlap'
        mic = warm_mic[-FRAME:].copy()
        ref = warm_ref[-FRAME:].copy()
        sentinel = np.full(FRAME - 1, 12345, dtype=np.int16)
        rejected = lib.woi_echo_process(first, mic.ctypes.data_as(ptr), ref.ctypes.data_as(ptr),
                                        sentinel.ctypes.data_as(ptr), FRAME - 1)
        assert rejected == -1, 'partial native frame was not rejected'
        assert np.all(sentinel == 12345), 'rejected partial frame mutated output'
        # A failed partial operation must leave all filter/delay state identical
        # to an instance which never received it.
        continued = cancel(mic, ref, first)
        expected = cancel(mic, ref, control)
        assert np.array_equal(continued, expected), 'rejected partial frame advanced signal history'
        assert lib.woi_echo_reset(first) == 1
        # Nonzero reference forces the processed path, so delayed raw bypass
        # cannot conceal old preprocess overlap after reset.
        silence = np.zeros(FRAME * 3, dtype=np.int16)
        active_ref = np.tile(ref, 3)
        reset_audio = cancel(silence, active_ref, first)
        fresh_audio = cancel(silence, active_ref, fresh)
        assert np.array_equal(reset_audio, fresh_audio), 'reset retained preprocessor signal history'
        assert np.all(reset_audio[:FRAME] == 0), 'reset replayed pre-reset audio'
        return {'partial_rejected_without_state_change': True,
                'reset_matches_fresh_instance': True,
                'first_reset_frame_silent': True}
    finally:
        for state in [first, control, fresh]:
            lib.woi_echo_destroy(state)


class JavaRandom:
    """Exact java.util.Random Gaussian sequence used by the device fixture."""
    def __init__(self, seed):
        self.seed = (seed ^ 0x5DEECE66D) & ((1 << 48) - 1)
        self.cached = None

    def bits(self, count):
        self.seed = (self.seed * 0x5DEECE66D + 11) & ((1 << 48) - 1)
        return self.seed >> (48 - count)

    def uniform(self):
        return ((self.bits(26) << 27) + self.bits(27)) / (1 << 53)

    def gaussian(self):
        if self.cached is not None:
            value, self.cached = self.cached, None
            return value
        while True:
            x, y = 2 * self.uniform() - 1, 2 * self.uniform() - 1
            radius = x * x + y * y
            if 0 < radius < 1:
                scale = math.sqrt(-2 * math.log(radius) / radius)
                self.cached = y * scale
                return x * scale


def device_vector_regression(lib, cancel, erle, pcm):
    # Preserve the independently failing device vector: colored excitation,
    # three delayed reflections, truncating quantization and no added noise.
    # Merely substituting the original easier host vector would hide this case.
    count = RATE * 16
    random = JavaRandom(112608)
    far = np.empty(count)
    low_pass = 0.
    for i in range(count):
        low_pass = low_pass * .55 + random.gaussian() * .45
        far[i] = low_pass * 10000 * (.45 + .55 * math.sin(i * 2 * math.pi / (RATE * 1.1)) ** 2)
    far = np.clip(np.trunc(far), -32767, 32767).astype(np.int16)
    echo = np.zeros(count)
    for delay, gain in [(720, .55), (1488, .22), (2520, -.12)]:
        echo[delay:] += far[:-delay].astype(float) * gain
    capture = np.clip(np.trunc(echo), -32767, 32767).astype(np.int16)
    time = np.arange(count) / RATE
    near = 2400 * (np.sin(2 * np.pi * 181 * time) + .4 * np.sin(2 * np.pi * 577 * time))
    near *= .4 + .6 * np.sin(2 * np.pi * 2.7 * time) ** 2
    near[:RATE * 8] = 0
    state = lib.woi_echo_create(RATE, FRAME, RATE // 5)
    assert state
    try:
        output = cancel(capture, far, state)
        attenuation = erle(capture[-RATE * 4:], output[-RATE * 4:])
        assert attenuation >= 20, f'device vector still fails: {attenuation:.2f} dB'
        mixed = np.clip(np.trunc(echo + near), -32767, 32767).astype(np.int16)
        output = cancel(mixed, far, state)
        expected = near[-RATE * 4 - FRAME:-FRAME]
        actual = output[-RATE * 4:]
        correlation = float(np.corrcoef(expected, actual)[0, 1])
        gain = float(np.dot(expected, actual) / np.dot(expected, expected))
        assert correlation >= .75 and .45 <= gain <= 1.35, (correlation, gain)
        lib.woi_echo_reset(state)
        reset = cancel(capture, far, state)
        reset_attenuation = erle(capture[-RATE * 4:], reset[-RATE * 4:])
        assert reset_attenuation >= 20
        # No render activity: ordinary near-end speech must survive as well.
        lib.woi_echo_reset(state)
        alone = cancel(pcm(near), np.zeros(count, dtype=np.int16), state)
        alone_gain = float(np.dot(expected, alone[-RATE * 4:]) / np.dot(expected, expected))
        assert .8 <= alone_gain <= 1.2, f'near-only speech attenuated: {alone_gain}'
        return {'echo_attenuation_db': round(attenuation, 2),
                'near_end_correlation': round(correlation, 4),
                'near_end_gain': round(gain, 4),
                'near_only_gain': round(alone_gain, 4),
                'reset_attenuation_db': round(reset_attenuation, 2),
                'measurement_floor_rms_lsb': .5}
    finally:
        lib.woi_echo_destroy(state)


if __name__ == '__main__':
    main()
