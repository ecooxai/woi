#!/usr/bin/env python3
"""Virtual, pinned acoustic loop: never changes system defaults or uses hardware."""
import array, json, math, os, random, subprocess, sys, time, wave
from pathlib import Path

root=Path(__file__).resolve().parents[2]
out=root/'qa'/'out'/'aec-reconnect'
out.mkdir(parents=True,exist_ok=True)
name='woi_reconnect_qa_'+str(os.getpid())
speaker=name+'_speaker'; room=name+'_room'; mic=name+'_mic'
modules=[]
def run(*args):
    return subprocess.check_output(args,text=True,timeout=10).strip()
def defaults():
    return (run('pactl','get-default-source'),run('pactl','get-default-sink'))
def load(*args):
    modules.append(run('pactl','load-module',*args))
def rms(path):
    a=array.array('h'); a.frombytes(path.read_bytes())
    # Ignore the capture start and end; the stationary far signal is present
    # throughout this 2 s window after four seconds of convergence.
    a=a[4*24000:6*24000]
    if len(a)<24000: raise RuntimeError('not enough captured PCM: '+str(path))
    return max(1e-9,math.sqrt(sum(float(v)*v for v in a)/len(a)))
before=defaults()
rng=random.Random(41); samples=array.array('h'); prev=0.0
for i in range(7*24000):
    prev=.88*prev+rng.uniform(-1,1)*.12
    samples.append(int(max(-.9,min(.9,prev*.7+math.sin(i*2*math.pi*731/24000)*.14))*32767))
with wave.open(str(out/'signal.wav'),'wb') as w:
    w.setnchannels(1); w.setsampwidth(2); w.setframerate(24000); w.writeframes(samples.tobytes())
try:
    load('module-null-sink','sink_name='+speaker,'sink_properties=device.description=WoiQaSpeaker')
    load('module-null-sink','sink_name='+room,'sink_properties=device.description=WoiQaRoom')
    load('module-remap-source','master='+room+'.monitor','source_name='+mic,'source_properties=device.description=WoiQaMic')
    load('module-loopback','source='+speaker+'.monitor','sink='+room,'latency_msec=60','source_dont_move=true','sink_dont_move=true')
    if defaults()!=before: raise RuntimeError('virtual devices unexpectedly changed defaults')
    env=os.environ.copy(); env['PATH']=str(Path.home()/'.local/flutter/bin')+':'+env.get('PATH','')
    with (out/'probe.log').open('w') as log:
        p=subprocess.run(['dart','run','tool/aec_reconnect_check.dart',speaker,mic,room,str(out)],cwd=root/'app',env=env,stdout=log,stderr=subprocess.STDOUT,timeout=95)
    if p.returncode: raise RuntimeError('AEC probe failed; see '+str(out/'probe.log'))
    metrics=[]
    for stage in ['initial','warm_reconnect','cold_reconnect','shutdown_race','near_voice']:
        raw=rms(out/(stage+'-raw.raw')); clean=rms(out/(stage+'-aec.raw'))
        reduction=20*math.log10(raw/clean)
        metrics.append({'stage':stage,'raw_rms':round(raw,3),'aec_rms':round(clean,3),'reduction_db':round(reduction,2)})
        if stage!='near_voice' and reduction<20: raise RuntimeError(str(metrics[-1]))
        if stage=='near_voice' and abs(reduction)>6: raise RuntimeError('near voice changed too much: '+str(metrics[-1]))
    result={'passed':True,'defaults_unchanged':defaults()==before,'metrics':metrics}
    (out/'result.json').write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps(result,indent=2))
finally:
    for module in reversed(modules):
        try: run('pactl','unload-module',module)
        except Exception as e: print('cleanup:',e,file=sys.stderr)
    if defaults()!=before: raise RuntimeError('audio defaults changed during probe')
