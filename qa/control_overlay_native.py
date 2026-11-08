#!/usr/bin/env python3
"""Verify native indicators and physical takeover using two private X displays.

Example: python3 qa/control_overlay_native.py --outer-display 72 --inner-display 73
Requires Xvfb, Xephyr, xdotool, C++ compiler, gtk+-3.0, xi, and x11 development files, ImageMagick import/convert.
Compiles the actual native overlay source; no Flutter build or user desktop is used.
"""
import argparse
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import time


parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--outer-display', type=int, default=72)
parser.add_argument('--inner-display', type=int, default=73)
parser.add_argument('--out', type=Path, default=Path('qa/out/control-native'))
args = parser.parse_args()
if min(args.outer_display, args.inner_display) < 10 or args.outer_display == args.inner_display:
    parser.error('use two distinct private displays numbered 10 or higher')
out = args.out
out.mkdir(parents=True, exist_ok=True)
outer = {**os.environ, 'DISPLAY': f':{args.outer_display}', 'GDK_BACKEND': 'x11'}
inner = {**os.environ, 'DISPLAY': f':{args.inner_display}', 'GDK_BACKEND': 'x11',
         'WOI_CONTROL_TEST_OUT': str(out.resolve())}


def cmd(argv, env=inner):
    return subprocess.run(argv, env=env, check=True, capture_output=True, text=True).stdout.strip()


def display_ready(env):
    return subprocess.run(['xdotool', 'getmouselocation'], env=env, capture_output=True).returncode == 0


def wait_display(env):
    for _ in range(80):
        if display_ready(env):
            return
        time.sleep(.05)
    raise RuntimeError(f"display {env['DISPLAY']} not ready")


for env in (outer, inner):
    if display_ready(env):
        raise RuntimeError(f"display {env['DISPLAY']} already exists; refusing to use it")
flags = shlex.split(cmd(['pkg-config', '--cflags', '--libs', 'gtk+-3.0', 'xi', 'x11']))
subprocess.run(['c++', '-std=c++17', '-Wall', '-Werror', '-ffunction-sections',
                '-fdata-sections', '-Wl,--gc-sections', '-Iapp/linux/flutter/ephemeral',
                'qa/lib/control_overlay_native.cc', '-o', str(out / 'harness'), *flags], check=True)
if not shutil.which('import') or not shutil.which('convert'):
    raise RuntimeError('ImageMagick import/convert are required for pointer color/hotspot screenshots')
servers = []
harness = None
try:
    servers.append(subprocess.Popen(['Xvfb', outer['DISPLAY'], '-screen', '0', '1280x800x24', '-ac'],
                                    stdout=open(out / 'xvfb.log', 'w'), stderr=subprocess.STDOUT))
    wait_display(outer)
    servers.append(subprocess.Popen(['Xephyr', inner['DISPLAY'], '-screen', '1000x700', '-ac', '-no-host-grab'],
                                    env=outer, stdout=open(out / 'xephyr.log', 'w'), stderr=subprocess.STDOUT))
    wait_display(inner)
    host = cmd(['xdotool', 'search', '--name', 'Xephyr'], outer).splitlines()[-1]
    cmd(['xdotool', 'mousemove', '--window', host, '100', '100'], outer)
    time.sleep(.2)
    results = []
    for mode in ('synthetic', 'physical'):
        harness = subprocess.Popen([str(out / 'harness')], env=inner,
                                   stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        ready = harness.stdout.readline().strip()
        assert ready in ('READY composed=0', 'READY composed=1'), ready
        composited = ready.endswith('=1')
        target = cmd(['xdotool', 'search', '--name', 'Woi native overlay target']).splitlines()[-1]
        cmd(['xdotool', 'windowfocus', target])
        cmd(['xdotool', 'type', '--delay', '12', '--', 'overlaytest'])
        baseline = out / f'{mode}-baseline.png'
        cmd(['import', '-display', inner['DISPLAY'], '-window', 'root', str(baseline)])
        def pixel(shot, x, y):
            raw = subprocess.run(['convert', str(shot), '-crop', f'1x1+{x}+{y}',
                                  '+repage', '-depth', '8', 'rgb:-'],
                                 check=True, capture_output=True).stdout
            assert len(raw) == 3, raw
            return tuple(raw)
        cmd(['xdotool', 'mousemove', '640', '430'])
        for button, rgb in (('none', (92, 190, 255)), ('left', (52, 155, 231)),
                            ('right', (255, 166, 166)), ('none', (92, 190, 255))):
            harness.stdin.write(button + '\n')
            harness.stdin.flush()
            assert harness.stdout.readline().strip() == f'BUTTON {button}'
            if button != 'none':
                cmd(['xdotool', 'click', '1' if button == 'left' else '3'])
            time.sleep(.15)
            shot = out / f'{mode}-pointer-{button}.png'
            cmd(['import', '-display', inner['DISPLAY'], '-window', 'root', str(shot)])
            for dx, dy in ((4, 12), (16, 32)):
                background = pixel(baseline, 640 + dx, 430 + dy)
                # Private Xephyr can run without a compositor. In that case
                # root captures expose the premultiplied RGB values directly;
                # the harness independently verifies real alpha on Cairo's
                # RGBA surface. On a composited display verify the blend too.
                expected = tuple((color + (back if composited else 0)) / 2
                                 for color, back in zip(rgb, background))
                actual = pixel(shot, 640 + dx, 430 + dy)
                assert all(abs(a - b) <= 2 for a, b in zip(actual, expected)), (button, actual, expected)
            assert pixel(shot, 630, 442) != expected, 'Cursor hotspot drifted or circular marker remained'
        if mode == 'physical':
            # Take over during the third trailing second. Outer XTEST reaches
            # Xephyr as a physical source; the app's inner XTEST stays ignored.
            time.sleep(2.3)
            cmd(['xdotool', 'mousemove', '--window', host, '200', '200'], outer)
            cmd(['xdotool', 'mousemove', '--window', host, '250', '220'], outer)
        stdout, stderr = harness.communicate(timeout=12)
        harness = None
        (out / f'{mode}.log').write_text(stdout + stderr)
        expected = 'cancelled=0' if mode == 'synthetic' else 'cancelled=1'
        assert expected in stdout, stdout + stderr
        assert 'arrow_palette=1 hotspot=1 keyboard_alpha=1' in stdout, stdout + stderr
        assert 'clicks=1' in stdout, stdout + stderr
        assert 'text=overlaytest' in stdout, stdout + stderr
        results.append({'scenario': mode, 'cancelled': mode == 'physical',
                        'click_through': True, 'typing_focus_preserved': True,
                        'arrow_palette_and_hotspot': True, 'neutral_reset': True,
                        'pointer_and_keyboard_half_alpha': True, 'desktop_composited': composited,
                        'takeover_after_input_ms': 2300 if mode == 'physical' else None})
        time.sleep(.2)
    (out / 'result.json').write_text(json.dumps(results, indent=2) + '\n')
    print(json.dumps(results))
finally:
    if harness and harness.poll() is None:
        harness.terminate()
        harness.communicate(timeout=2)
    for process in reversed(servers):
        process.terminate()
    for process in reversed(servers):
        try:
            process.wait(timeout=2)
        except subprocess.TimeoutExpired:
            process.kill()
