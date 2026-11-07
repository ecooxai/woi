#!/usr/bin/env python3
"""Exactly two LIVE Normal-tier UI probes: Responses and native Realtime.

Use a separate lab server and --confirm-live. No keys are read, no retries are
issued, and only a temporary headless Chromium profile is created/closed.
"""
import argparse
import asyncio
import base64
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import time
from urllib.parse import urlsplit

import benchmark as b
from probe_speed_tiers import click, ready, save, trim_result

MODELS=('gpt-6-astra','gpt-realtime-2.1')


async def feedback(cdp):
    return await cdp.evaluate('''(() => {
      const state=ClickLab.getState(),t=state.layout.targets[0],canvas=document.getElementById('successes');
      const pixels=canvas.getContext('2d').getImageData(t.x,t.y,t.w,t.h).data;
      let black=0,white=0,opaque=0;
      for(let i=0;i<pixels.length;i+=4){
        if(pixels[i+3])opaque++;
        if(pixels[i+3]===255&&pixels[i]===0&&pixels[i+1]===0&&pixels[i+2]===0)black++;
        if(pixels[i+3]===255&&pixels[i]===255&&pixels[i+1]===255&&pixels[i+2]===255)white++;
      }
      return {completed:state.completedTargetIds,busy:state.inFlight,black_pixels:black,white_pixels:white,opaque_pixels:opaque};
    })()''')


async def run(args):
    output=Path(args.output)
    report={'schema_version':1,'started_at':datetime.now(timezone.utc).isoformat(),
            'status':'running','url':args.url,'auth_mode':'codex','planned_trial_requests':2,
            'trial_requests_started':0,'retries':0,'fallbacks':0,
            'scope':'Two live Normal-tier requests through real UI controls in a separate headless profile. Provider timeline and local click feedback; no speed ranking.',
            'trials':[]}
    save(output,report)
    try:
        async with b.Browser(Path(args.browser_output)) as browser:
            cdp=browser.cdp
            await cdp.command('Emulation.setDeviceMetricsOverride',{'width':1440,'height':1550,'deviceScaleFactor':1,'mobile':False,'screenWidth':1440,'screenHeight':1550})
            await cdp.command('Page.navigate',{'url':args.url.rstrip('/')+'/?seed=7441'})
            await ready(cdp,"!!window.ClickLab&&!ClickLab.getState().loadingModels&&!ClickLab.getState().switching&&ClickLab.getState().models.length>0",60)
            state=await cdp.evaluate('ClickLab.getState()')
            if state['authMode']!='codex' or not state['connection'].get('configured'):
                raise RuntimeError('Existing Codex login required; no connection changes will be made.')
            for model in MODELS:
                if not any(m['id']==model and m.get('available') for m in state['models']):
                    raise RuntimeError('Bounded smoke model unavailable: '+model)
            await cdp.evaluate('document.fonts.ready.then(()=>true)')
            await cdp.evaluate("(() => {ClickLab.setLayout({seed:7441,width:1280,height:480,count:12});const t=ClickLab.getLayout().targets[0];ClickLab.setInstruction('Click the '+t.label+' button.',{expectedTargetId:t.id,expectedAction:'click'});return true;})()")
            capture=await cdp.evaluate('ClickLab.capture()')
            png=base64.b64decode(capture['screenshot'].split(',',1)[1]);expected_hash=hashlib.sha256(png).hexdigest()
            fixture=output.with_name('timing-fixture.png');fixture.write_bytes(png)
            report['fixture']={'image_file':fixture.name,'image_bytes':len(png),'image_sha256':expected_hash,'layout':await cdp.evaluate('ClickLab.getLayout()')}
            await click(cdp,'input[name="speed-tier"][value="normal"] + span')
            for model in MODELS:
                await click(cdp,'input[name="model"][value='+json.dumps(model)+'] + .model-copy')
                before=await feedback(cdp)
                count=await cdp.evaluate('ClickLab.getState().results.length')
                report['trial_requests_started']+=1;report['current_model']=model;save(output,report)
                print(json.dumps({'event':'started','model':model}),flush=True)
                await click(cdp,'#send')
                pending=await feedback(cdp)
                start=time.monotonic();heartbeat=30
                while True:
                    status=await cdp.evaluate('({count:ClickLab.getState().results.length,busy:ClickLab.getState().inFlight})')
                    if status['count']>count and not status['busy']:break
                    elapsed=time.monotonic()-start
                    if elapsed>145:raise TimeoutError(model+' did not finish within145s; no retry issued.')
                    if elapsed>=heartbeat:
                        print(json.dumps({'event':'waiting','model':model,'seconds':round(elapsed)}),flush=True);heartbeat+=30
                    await asyncio.sleep(.5)
                data=await cdp.evaluate('({result:ClickLab.getState().results.at(-1),request:ClickLab.getLastRequest(),capture:ClickLab.capture(),timeline:document.querySelector(".request-timeline")?.textContent,details:document.getElementById("response-timing-detail").textContent})')
                after=await feedback(cdp);row=trim_result(data['result'])
                request_hash=hashlib.sha256(base64.b64decode(data['request']['screenshot'].split(',',1)[1])).hexdigest()
                after_hash=hashlib.sha256(base64.b64decode(data['capture']['screenshot'].split(',',1)[1])).hexdigest()
                response=row['response'];t=response.get('timing') or {}
                row.update(request_fields=sorted(data['request']),image_sha256=request_hash,
                           ui_timeline=data['timeline'],ui_timing_details=data['details'],feedback_before=before,
                           feedback_pending=pending,feedback_after=after)
                row['checks']={'same_clean_image':request_hash==expected_hash,
                               'feedback_excluded_from_capture':after_hash==expected_hash,
                               'reset_at_start_observed':pending['busy'] and not pending['completed'] and pending['opaque_pixels']==0,
                               'normal_forwarded':data['request']['speed_tier']=='normal',
                               'raw_image_bytes_exact':response.get('request_image_bytes')==len(png),
                               'payload_larger_than_image':isinstance(response.get('request_payload_bytes'),int) and response['request_payload_bytes']>len(png),
                               'timing_origin':t.get('origin')=='provider_request_start',
                               'timing_status':t.get('status') in ('completed','error'),
                               'measured_upload':isinstance(t.get('upload_complete_ms'),(int,float)),
                               'measured_finish':isinstance(t.get('finish_ms'),(int,float)),
                               'black_white_after_hit':after['black_pixels']>0 and after['white_pixels']>0 if row['outcome']=='hit' else None,
                               'miss_keeps_success_clear':not after['completed'] and after['opaque_pixels']==0 if row['outcome']=='miss' else None}
                await cdp.evaluate('scrollTo(0,0);true')
                shot=await cdp.command('Page.captureScreenshot',{'format':'png','captureBeyondViewport':False})
                name='timing-responses-ui.png' if response.get('transport')=='responses' else 'timing-realtime-ui.png'
                output.with_name(name).write_bytes(base64.b64decode(shot['data']));row['screenshot_file']=name
                report['trials'].append(row);report.pop('current_model',None);save(output,report)
                print(json.dumps({'event':'completed','model':model,'outcome':row['outcome'],'transport':response.get('transport'),
                                  'request_image_bytes':response.get('request_image_bytes'),'request_payload_bytes':response.get('request_payload_bytes'),
                                  'timing':t,'checks':row['checks'],'error':row.get('error')}),flush=True)
            report['summary']={'trial_requests':len(report['trials']),'hits':sum(r['outcome']=='hit' for r in report['trials']),'misses':sum(r['outcome']=='miss' for r in report['trials']),'errors':sum(r['outcome']=='error' for r in report['trials']),'all_applicable_checks_passed':all(v is not False for r in report['trials'] for v in r['checks'].values())}
            report['status']='completed'
    except Exception as exc:
        report['status']='stopped';report['probe_error']=str(exc);raise
    finally:
        report['finished_at']=datetime.now(timezone.utc).isoformat();save(output,report)
        print(json.dumps({'event':'finished','status':report['status'],'completed':len(report['trials']),'report':str(output)}),flush=True)


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--url',required=True)
    parser.add_argument('--output',default='qa/click_bench/lab/results/20261107/timing-live.json')
    parser.add_argument('--browser-output',default='qa/out/click_lab/speed-tiers/live/timing-browser')
    parser.add_argument('--confirm-live',action='store_true')
    args=parser.parse_args();url=urlsplit(args.url)
    if not args.confirm_live:parser.error('--confirm-live is required for two actual model attempts.')
    if url.scheme!='http' or url.hostname not in ('127.0.0.1','localhost'):parser.error('Use a loopback lab URL.')
    asyncio.run(run(args))
