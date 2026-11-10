#!/usr/bin/env python3
"""Private-display visual QA for an already-built WOI Linux release.

Preparation is the default and never launches the app. Run `start` only after
its build owner releases the binary. Synthetic state lives under qa/out.
No HOME/CODEX_HOME changes, real login, host audio, or network are used.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import time

REPO = Path(__file__).resolve().parents[1]
OUT = REPO / 'qa/out/ui-native'
DISPLAY = ':74'
STATE = OUT / 'state.json'


def run(argv, **kwargs):
    return subprocess.run(argv, check=True, text=True, capture_output=True, **kwargs).stdout.strip()


def pid_stamp(pid):
    try:
        return Path(f'/proc/{pid}/stat').read_text().rsplit(')', 1)[1].split()[19]
    except FileNotFoundError:
        return None


def load_state():
    if not STATE.exists():
        raise SystemExit('No private UI QA session; run start after the build is ready.')
    return json.loads(STATE.read_text())


def environment():
    env = os.environ.copy()
    for name in list(env):
        if name.startswith('OPENAI_') or name in ('DBUS_SESSION_BUS_ADDRESS', 'WAYLAND_DISPLAY', 'SSH_AUTH_SOCK'):
            env.pop(name, None)
    env.update(
        DISPLAY=DISPLAY,
        GDK_BACKEND='x11',
        LIBGL_ALWAYS_SOFTWARE='1',
        NO_AT_BRIDGE='1',
        XDG_DATA_HOME=str(OUT / 'data'),
        XDG_CONFIG_HOME=str(OUT / 'config'),
        XDG_CACHE_HOME=str(OUT / 'cache'),
        XDG_RUNTIME_DIR=str(OUT / 'runtime'),
        TMPDIR=str(OUT / 'tmp'),
        PIPEWIRE_RUNTIME_DIR=str(OUT / 'runtime'),
        PULSE_SERVER='unix:' + str(OUT / 'runtime/no-pulse'),
        WOI_MIC_MODE='muted',
        XAUTHORITY=str(OUT / 'empty-xauth'),
    )
    return env


def prepare():
    if STATE.exists():
        previous = json.loads(STATE.read_text())
        if any(pid_stamp(p['pid']) == p['stamp'] for p in previous.get('processes', [])):
            raise SystemExit('Stop the existing private QA session before preparing again.')
    for name in ('data/woi/conversations', 'config', 'cache', 'runtime', 'tmp', 'shots'):
        (OUT / name).mkdir(parents=True, exist_ok=True)
    (OUT / 'runtime').chmod(0o700)
    (OUT / 'empty-xauth').write_text('')
    settings = {
        'backendMode': 'apiKey',
        'apiKey': 'woi-ui-qa-offline-placeholder',
        'micMode': 'muted',
        'echoCancellation': False,
        'compressionThreshold': 10000,
        'idleStandbySeconds': 0,
        'theme': 'light',
    }
    settings_path = OUT / 'data/woi/settings.json'
    settings_path.write_text(json.dumps(settings, indent=2))
    settings_path.chmod(0o600)
    stamp = '2026-11-07T12:00:00.000Z'
    conversation = {
        'version': 1,
        'id': 'native-ui-visual-qa',
        'title': 'Compact chat visual QA',
        'createdAt': stamp,
        'updatedAt': stamp,
        'customTitle': True,
        'summary': 'Synthetic retained context for visual QA. ' * 220,
        'messages': [
            {'id': 'qa-user', 'kind': 'user', 'createdAt': stamp,
             'text': 'Please check the compact chat layout.'},
            {'id': 'qa-old-reply', 'kind': 'assistant', 'createdAt': stamp,
             'text': 'An older saved reply has no model attribution.'},
            {'id': 'qa-next-user', 'kind': 'user', 'createdAt': stamp,
             'text': 'How does the microphone work?'},
            {'id': 'qa-reply', 'kind': 'assistant', 'createdAt': stamp,
             'text': 'Tap the microphone to listen. Hold it to record microphone and system audio, then release to send.',
             'meta': {'model': 'gpt-live-1.1'}},
        ],
    }
    (OUT / 'data/woi/conversations/native-ui-visual-qa.json').write_text(json.dumps(conversation, indent=2))
    print('Prepared synthetic offline state at', OUT.relative_to(REPO))


def start(binary, clipboard_image=None, text_scale=1.0):
    if Path('/tmp/.X11-unix/X74').exists():
        raise SystemExit('Display :74 already exists; refusing to share or replace it.')
    binary = Path(binary).resolve()
    if not binary.is_file():
        raise SystemExit('Release binary is missing. This script never builds it.')
    if not (OUT / 'data/woi/settings.json').exists():
        prepare()
    env = environment()
    if not 0.5 <= text_scale <= 3:
        raise SystemExit('Choose a text scale between 0.5 and 3.')
    # A keyfile backend writes only to this fixture's XDG_CONFIG_HOME. Never
    # modify the user's dconf session or desktop-wide accessibility settings.
    env['GSETTINGS_BACKEND'] = 'keyfile'
    run(['gsettings', 'set', 'org.gnome.desktop.interface', 'text-scaling-factor', str(text_scale)], env=env)
    observed_scale = run(['gsettings', 'get', 'org.gnome.desktop.interface', 'text-scaling-factor'], env=env)
    state = {'display': DISPLAY, 'binary': str(binary), 'text_scale': float(observed_scale), 'processes': []}

    def spawn(label, argv):
        with (OUT / f'{label}.log').open('wb') as log:
            process = subprocess.Popen(argv, env=env, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        state['processes'].append({'name': label, 'pid': process.pid, 'stamp': pid_stamp(process.pid)})
        STATE.write_text(json.dumps(state, indent=2))
        return process

    try:
        server = spawn('xvfb', ['Xvfb', DISPLAY, '-screen', '0', '1600x1000x24', '-ac', '-nolisten', 'tcp'])
        for _ in range(80):
            if server.poll() is not None:
                raise RuntimeError('Private display exited; inspect xvfb.log.')
            if subprocess.run(['xdotool', 'getdisplaygeometry'], env=env, stdout=subprocess.DEVNULL,
                              stderr=subprocess.DEVNULL).returncode == 0:
                break
            time.sleep(0.1)
        else:
            raise RuntimeError('Private display did not become ready.')
        spawn('openbox', ['openbox'])
        if clipboard_image is not None:
            seed = Path(clipboard_image).resolve()
            seed_hash = hashlib.sha256(seed.read_bytes()).hexdigest()
            owner = spawn('clipboard', ['xclip', '-quiet', '-selection', 'clipboard', '-t', 'image/png', '-i', str(seed)])
            for _ in range(40):
                if owner.poll() is not None:
                    raise RuntimeError('Private clipboard owner exited; inspect clipboard.log.')
                captured = subprocess.run(['xclip', '-selection', 'clipboard', '-out', '-t', 'image/png'],
                                          env=env, capture_output=True, timeout=3)
                if captured.returncode == 0 and hashlib.sha256(captured.stdout).hexdigest() == seed_hash:
                    break
                time.sleep(0.05)
            else:
                raise RuntimeError('Private clipboard image did not become readable.')
            state['clipboard_seed_sha256'] = seed_hash
            STATE.write_text(json.dumps(state, indent=2))
        auth_dir = Path(os.environ.get('CODEX_HOME') or (Path.home() / '.codex')).resolve()
        app = spawn('app', ['bwrap', '--unshare-net', '--ro-bind', '/', '/', '--dev', '/dev', '--proc', '/proc',
                            '--tmpfs', str(auth_dir), '--bind', str(OUT), str(OUT),
                            '--chdir', str(OUT), '--', str(binary)])
        for _ in range(100):
            if app.poll() is not None:
                raise RuntimeError('Offline app exited; inspect app.log.')
            result = subprocess.run(['xdotool', 'search', '--onlyvisible', '--name', '^Woi$'],
                                    env=env, capture_output=True, text=True)
            if result.returncode == 0 and result.stdout.strip():
                state['window'] = result.stdout.splitlines()[0]
                STATE.write_text(json.dumps(state, indent=2))
                resize(1400, 900)
                snapshot('desktop-initial')
                print('Private app ready; display :74, window', state['window'])
                return
            time.sleep(0.2)
        raise RuntimeError('Private app window not found; inspect app.log.')
    except BaseException:
        stop()
        raise


def resize(width, height):
    if width < 320 or height < 500 or width > 1500 or height > 940:
        raise SystemExit('Choose a QA client size within 320..1500 by 500..940.')
    state = load_state()
    run(['xdotool', 'windowsize', state['window'], str(width), str(height),
         'windowmove', state['window'], '40', '30', 'windowactivate', '--sync', state['window']], env=environment())
    time.sleep(0.8)
    print(run(['xdotool', 'getwindowgeometry', '--shell', state['window']], env=environment()))


def snapshot(name):
    if not re.fullmatch(r'[a-z0-9][a-z0-9_-]*', name):
        raise SystemExit('Screenshot name must contain lowercase letters, digits, hyphens or underscores.')
    state = load_state()
    path = OUT / 'shots' / f'{name}.png'
    run(['import', '-display', DISPLAY, '-window', state['window'], str(path)], env=environment())
    print(path.relative_to(REPO))


def stop():
    if not STATE.exists():
        return
    state = load_state()
    for process in reversed(state.get('processes', [])):
        if process['stamp'] is not None and pid_stamp(process['pid']) == process['stamp']:
            try:
                os.killpg(process['pid'], signal.SIGTERM)
            except ProcessLookupError:
                pass
    deadline = time.monotonic() + 3
    while Path('/tmp/.X11-unix/X74').exists() and time.monotonic() < deadline:
        time.sleep(0.05)
    STATE.unlink(missing_ok=True)
    print('Stopped only the recorded private UI QA processes.')


parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('action', choices=('prepare', 'start', 'resize', 'shot', 'stop'), nargs='?', default='prepare')
parser.add_argument('--binary', default=str(REPO / 'app/build/linux/x64/release/bundle/woi'))
parser.add_argument('--clipboard-image', help='Synthetic PNG to own the private clipboard before app startup')
parser.add_argument('--text-scale', type=float, default=1.0, help='Private GSettings text scale; never changes the desktop session')
parser.add_argument('--width', type=int, default=400)
parser.add_argument('--height', type=int, default=860)
parser.add_argument('--name', default='current')
args = parser.parse_args()
if args.action == 'prepare':
    prepare()
elif args.action == 'start':
    start(args.binary, args.clipboard_image, args.text_scale)
elif args.action == 'resize':
    resize(args.width, args.height)
elif args.action == 'shot':
    snapshot(args.name)
else:
    stop()
