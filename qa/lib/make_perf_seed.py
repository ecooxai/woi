#!/usr/bin/env python3
"""Writes perf test data into a Woi data dir (XDG_DATA_HOME/woi):

  make_perf_seed.py DATA_DIR [--messages 200] [--notes 8]

* one long conversation (DATA_DIR/conversations/cperf-long.json) with
  --messages entries: user/assistant text (some Markdown + code), tool calls,
  system notes and a few screenshots (1600x900 PNGs) so thumbnails decode;
* --notes extra conversations with only a note (note tabs / "More" list);
* the long conversation is the most recent one, so Woi opens it on start.
"""
import json, os, subprocess, sys, datetime, random

args = sys.argv[1:]
if not args:
    sys.exit(__doc__)
data = args[0]
n_msgs = int(args[args.index('--messages') + 1]) if '--messages' in args else 200
n_notes = int(args[args.index('--notes') + 1]) if '--notes' in args else 8
conv_dir = os.path.join(data, 'conversations'); os.makedirs(conv_dir, exist_ok=True)
img_dir = os.path.join(data, 'images'); os.makedirs(img_dir, exist_ok=True)
note_dir = os.path.join(data, 'notes'); os.makedirs(note_dir, exist_ok=True)

shots = []
for i in range(4):
    p = os.path.join(img_dir, f'perfshot{i}.png')
    if not os.path.exists(p):
        subprocess.run(['ffmpeg', '-loglevel', 'error', '-y', '-f', 'lavfi', '-i',
                        f'testsrc2=size=1600x900:rate=1', '-frames:v', '1', p], check=True)
    shots.append(p)

rnd = random.Random(5)
words = ('the build passed after fixing the linker flags and the cache was warm so it took only a few seconds '
         'open the file in the viewer then scroll to the section about audio latency and copy the numbers').split()
t0 = datetime.datetime(2026, 11, 3, 9, 0, 0)

def sentence(n):
    return ' '.join(rnd.choice(words) for _ in range(n)).capitalize() + '.'

msgs = []
for i in range(n_msgs):
    at = (t0 + datetime.timedelta(seconds=20 * i)).isoformat()
    k = i % 10
    m = {'id': f'mperf{i:04d}', 'createdAt': at}
    if k in (0, 4, 7):
        m.update(kind='user', text=sentence(rnd.randint(5, 18)))
        if i % 40 == 0:
            m['image'] = {'path': shots[(i // 40) % len(shots)], 'w': 1600, 'h': 900, 'ow': 1600, 'oh': 900}
    elif k == 2:
        m.update(kind='tool', tool={
            'callId': f'call{i}', 'name': 'run_bash', 'args': json.dumps({'command': 'ls -la /tmp'}),
            'status': 'success', 'result': json.dumps({'stdout': '\n'.join(sentence(4) for _ in range(6)), 'exit_code': 0}),
            'startedAt': at, 'finishedAt': at})
    elif k == 9:
        m.update(kind='system', text='Context compacted: 12.1k → 3.4k tokens', meta={'type': 'compaction'})
    else:
        body = ' '.join(sentence(rnd.randint(6, 16)) for _ in range(rnd.randint(1, 4)))
        if i % 15 == 1:
            body += '\n\n```bash\nflutter build linux --release\nls build/linux/x64/release/bundle\n```'
        if i % 12 == 3:
            body = '**Summary**\n\n- ' + '\n- '.join(sentence(6) for _ in range(4))
        m.update(kind='assistant', text=body)
    msgs.append(m)

now = datetime.datetime.now()
for j in range(n_notes):
    cid = f'cperfnote{j}'
    at = (now - datetime.timedelta(hours=j + 1)).isoformat()
    title = f'Project note {j + 1}: ' + ' '.join(rnd.choice(words) for _ in range(3))
    with open(os.path.join(conv_dir, cid + '.json'), 'w') as f:
        json.dump({'version': 1, 'id': cid, 'title': title, 'createdAt': at, 'updatedAt': at, 'messages': []}, f)
    md = f'# {title}\n\n## Todos\n- [ ] {sentence(5)}\n- [x] {sentence(4)}\n\n## Facts\n- {sentence(8)}\n'
    with open(os.path.join(note_dir, cid + '.json'), 'w') as f:
        json.dump({'version': 1, 'conversationId': cid, 'markdown': md, 'updatedAt': at}, f)

conv = {'version': 1, 'id': 'cperf-long', 'title': 'Perf: long chat history', 'createdAt': t0.isoformat(),
        'updatedAt': now.isoformat(), 'messages': msgs}
with open(os.path.join(conv_dir, 'cperf-long.json'), 'w') as f:
    json.dump(conv, f)
lines = '\n'.join(f'- line {i}: {sentence(8)}' for i in range(80))
with open(os.path.join(note_dir, 'cperf-long.json'), 'w') as f:
    json.dump({'version': 1, 'conversationId': 'cperf-long', 'markdown': '# Perf note\n\n' + lines + '\n',
               'updatedAt': now.isoformat()}, f)
print(f'seeded {n_msgs} messages + {n_notes} notes into {data}')
