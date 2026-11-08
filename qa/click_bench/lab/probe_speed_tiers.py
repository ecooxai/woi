#!/usr/bin/env python3
"""Bounded LIVE Codex tier smoke probe through the real lab UI.

Requires an isolated running lab server and explicit --confirm-live. It makes
exactly one trial attempt per tier/model, never retries, and never reads a key.
Only a new temporary headless Chromium profile is created and closed.
"""
from __future__ import annotations

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

MODELS = ('gpt-6-astra', 'gpt-6.1-sol')
TIERS = {'normal': 'default', 'fast': 'priority', 'ultrafast': 'ultrafast', 'flex': 'flex'}


def now():
    return datetime.now(timezone.utc).isoformat()


def save(path, report):
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix('.tmp')
    temporary.write_text(json.dumps(report, indent=2) + '\n')
    temporary.replace(path)


async def ready(cdp, expression, timeout=30):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        try:
            if await cdp.evaluate(expression):
                return
        except RuntimeError:
            pass
        await asyncio.sleep(.1)
    raise RuntimeError('UI did not become ready: ' + expression)


async def click(cdp, selector):
    rect = await cdp.evaluate('''(() => {
      const e=document.querySelector(''' + json.dumps(selector) + ''');
      if(!e)throw new Error('Missing live-probe control');
      if(e.disabled||e.closest('label')?.querySelector('input')?.disabled)
        throw new Error('Disabled live-probe control');
      e.scrollIntoView({block:'center'});const r=e.getBoundingClientRect();
      return {x:r.x+r.width/2,y:r.y+r.height/2};
    })()''')
    for kind in ('mousePressed', 'mouseReleased'):
        await cdp.command('Input.dispatchMouseEvent', {'type':kind, **rect, 'button':'left', 'clickCount':1})


def trim_result(row):
    result = {k:v for k,v in row.items() if k not in ('snapshot', 'response')}
    response = dict(row.get('response') or {})
    raw = response.pop('raw_output', None)
    if isinstance(raw, dict):
        response['raw_output'] = {k:raw[k] for k in ('calls','resolved_model','actual_service_tier','provider_status') if k in raw}
    result['response'] = response
    snapshot = row.get('snapshot') or {}
    result['capture'] = {k:snapshot[k] for k in ('id','captured_at','width','height','seed','revision','screen','viewport') if k in snapshot}
    return result


async def run(args):
    output = Path(args.output)
    report = {
        'schema_version':1, 'started_at':now(), 'status':'running',
        'url':args.url, 'mode':'LIVE Codex, real UI controls, isolated headless browser profile',
        'models':list(MODELS), 'tiers':TIERS, 'planned_trial_requests':8,
        'trial_requests_started':0, 'provider_retries':0, 'fallbacks':0,
        'api_key_live_tested':False,
        'scope':'One clean current screenshot and current instruction per request. No prior messages or expected target is sent to the model.',
        'limits':'One sample per model/tier verifies forwarding and reported behavior; it does not establish latency rankings or general account/model tier availability.',
        'trials':[],
    }
    save(output, report)
    try:
        async with b.Browser(Path(args.browser_output)) as browser:
            cdp = browser.cdp
            await cdp.command('Emulation.setDeviceMetricsOverride', {'width':1440, 'height':1100, 'deviceScaleFactor':1, 'mobile':False, 'screenWidth':1440, 'screenHeight':1100})
            await cdp.command('Page.navigate', {'url':args.url.rstrip('/')+'/?seed=7441'})
            await ready(cdp, "!!window.ClickLab&&!ClickLab.getState().loadingModels&&!ClickLab.getState().switching&&ClickLab.getState().models.length>0", 60)
            initial = await cdp.evaluate('ClickLab.getState()')
            connection = initial['connection']
            if initial['authMode'] != 'codex' or not connection.get('configured'):
                raise RuntimeError('Probe requires the existing configured Codex login; it will not switch or create credentials.')
            if not all(any(m['id']==model and m.get('available') for m in initial['models']) for model in MODELS):
                raise RuntimeError('Both bounded probe models must already be available in the current catalog.')
            report['connection'] = {k:connection.get(k) for k in ('auth_mode','mode','configured','source','revision','session_key')}
            report['catalog_models'] = [m for m in initial['models'] if m['id'] in MODELS]
            await cdp.evaluate("document.fonts.ready.then(()=>true)")
            await cdp.evaluate("(() => {ClickLab.setLayout({seed:7441,width:1280,height:480,count:12});const t=ClickLab.getLayout().targets[0];ClickLab.setInstruction('Click the '+t.label+' button.',{expectedTargetId:t.id,expectedAction:'click'});return true;})()")
            fixture = await cdp.evaluate('({capture:ClickLab.capture(),layout:ClickLab.getLayout(),instruction:document.getElementById("instruction").value})')
            png = base64.b64decode(fixture['capture']['screenshot'].split(',',1)[1])
            expected_hash = hashlib.sha256(png).hexdigest()
            image_path = output.with_name('speed-tiers-fixture.png')
            image_path.write_bytes(png)
            report['fixture'] = {'image_file':image_path.name, 'image_sha256':expected_hash, 'image_bytes':len(png), 'instruction':fixture['instruction'], 'layout':fixture['layout'], 'screen':fixture['capture']['screen']}
            save(output, report)
            print(json.dumps({'event':'ready','fixture_sha256':expected_hash,'instruction':fixture['instruction'],'models':list(MODELS)}), flush=True)
            for model in MODELS:
                await click(cdp, 'input[name="model"][value='+json.dumps(model)+'] + .model-copy')
                for tier, wire in TIERS.items():
                    await click(cdp, 'input[name="speed-tier"][value='+json.dumps(tier)+'] + span')
                    await ready(cdp, 'ClickLab.getState().speedTier==='+json.dumps(tier))
                    before = await cdp.evaluate('ClickLab.getState().results.length')
                    report['current_trial'] = {'model':model,'speed_tier':tier,'started_at':now()}
                    report['trial_requests_started'] += 1
                    save(output, report)
                    print(json.dumps({'event':'started',**report['current_trial']}), flush=True)
                    await click(cdp, '#send')
                    started = time.monotonic()
                    timeout = 620 if tier == 'flex' else 140
                    heartbeat = 30
                    while True:
                        state = await cdp.evaluate('({count:ClickLab.getState().results.length,busy:ClickLab.getState().inFlight})')
                        if state['count'] > before and not state['busy']:
                            break
                        elapsed = time.monotonic()-started
                        if elapsed > timeout:
                            raise TimeoutError(f'{model} {tier} exceeded {timeout}s UI completion limit; no retry issued.')
                        if elapsed >= heartbeat:
                            print(json.dumps({'event':'waiting','model':model,'speed_tier':tier,'seconds':round(elapsed)}), flush=True)
                            heartbeat += 30
                        await asyncio.sleep(.5)
                    evidence = await cdp.evaluate('({result:ClickLab.getState().results.at(-1),request:ClickLab.getLastRequest(),row:document.querySelector("#results-body tr").textContent,tier_detail:document.getElementById("response-tier-detail").textContent})')
                    request = evidence['request']
                    image_hash = hashlib.sha256(base64.b64decode(request['screenshot'].split(',',1)[1])).hexdigest()
                    row = trim_result(evidence['result'])
                    row['request_evidence'] = {k:v for k,v in request.items() if k != 'screenshot'}
                    row['request_fields'] = sorted(request)
                    row['image_sha256'] = image_hash
                    row['ui_row'] = evidence['row']
                    row['ui_tier_detail'] = evidence['tier_detail']
                    row['checks'] = {
                        'same_clean_png':image_hash==expected_hash,
                        'same_instruction':request['instruction']==fixture['instruction'],
                        'selected_tier_forwarded':request['speed_tier']==tier,
                        'wire_tier_expected':row.get('requested_service_tier')==wire,
                        'no_credentials_or_history':set(request)=={'model','instruction','screenshot','width','height','screen','request_id','speed_tier','connection_revision'},
                        'provider_image_matches':row['response'].get('image_sha256')==image_hash,
                        'fresh_context':row['response'].get('fresh_context') is True,
                        'connection_matches':row.get('auth_mode')=='codex',
                    }
                    report['trials'].append(row)
                    report.pop('current_trial',None)
                    save(output, report)
                    print(json.dumps({'event':'completed','model':model,'speed_tier':tier,'requested':row.get('requested_service_tier'),'actual':row.get('actual_service_tier'),'tier_status':row.get('tier_status'),'outcome':row.get('outcome'),'latency_ms':row.get('latency_ms'),'send_to_click_ms':row.get('send_to_click_ms'),'error_code':row.get('error_code'),'error':row.get('error'),'checks':row['checks']}), flush=True)
                    if not all(row['checks'].values()):
                        raise AssertionError('Live request evidence checks failed; matrix stopped without retries.')
            await cdp.evaluate('scrollTo(0,0);true')
            screenshot = await cdp.command('Page.captureScreenshot', {'format':'png','captureBeyondViewport':False})
            screenshot_path=output.with_name('speed-tiers-live-ui.png')
            screenshot_path.write_bytes(base64.b64decode(screenshot['data']))
            report['screenshot_file']=screenshot_path.name
            report['summary']={'trial_requests':len(report['trials']),'hits':sum(r['outcome']=='hit' for r in report['trials']),'misses':sum(r['outcome']=='miss' for r in report['trials']),'errors':sum(r['outcome']=='error' for r in report['trials']),'reported':sum(r['tier_status']=='reported' for r in report['trials']),'different':sum(r['tier_status']=='different' for r in report['trials']),'unreported':sum(r['tier_status']=='unreported' for r in report['trials']),'rejected':sum(r['tier_status']=='rejected' for r in report['trials'])}
            report['status']='completed'
    except Exception as exc:
        report['status']='stopped'
        report['probe_error']=f'{type(exc).__name__}: {exc}'
        raise
    finally:
        report['finished_at']=now()
        save(output,report)
        print(json.dumps({'event':'finished','status':report['status'],'completed':len(report['trials']),'report':str(output)}),flush=True)


if __name__ == '__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--url',required=True)
    parser.add_argument('--output',default='qa/click_bench/lab/results/20261107/speed-tiers-live.json')
    parser.add_argument('--browser-output',default='qa/out/click_lab/speed-tiers/live/browser')
    parser.add_argument('--confirm-live',action='store_true',help='Authorize exactly eight real Codex model attempts.')
    args=parser.parse_args()
    url=urlsplit(args.url)
    if not args.confirm_live:
        parser.error('--confirm-live is required; this probe makes real model requests.')
    if url.scheme!='http' or url.hostname not in ('127.0.0.1','localhost'):
        parser.error('--url must be a local lab server.')
    asyncio.run(run(args))
