#!/usr/bin/env python3
"""Independent browser QA for Click Lab connection and speed tiers.

All API requests are intercepted before navigation. No credentials, model quota,
server configuration, result files, or user's visible browser are touched. The
existing benchmark Browser/CDP helper uses a new temporary Chromium profile.

Run from the repository with a live lab server (static assets only are used):
  ../woi/research/.venv/bin/python qa/click_bench/lab/test_speed_tiers_ui.py \
    --url http://127.0.0.1:38631 --output qa/out/speed_tiers_ui
"""
from __future__ import annotations

import argparse
import asyncio
import base64
from datetime import datetime, timezone
import json
from pathlib import Path
import time

import benchmark as b

TIERS = {"normal": "default", "fast": "priority", "ultrafast": "ultrafast", "flex": "flex"}
MODELS = ["gpt-6-luna", "gpt-6.1-sol", "gpt-realtime-2.1"]
SYNTHETIC_KEY = "sk-test-WoiSpeedTierQAOnlySynthetic000000000000"

INIT = r'''(() => {
  const realFetch=window.fetch.bind(window);
  const wire={normal:'default',fast:'priority',ultrafast:'ultrafast',flex:'flex'};
  const key='sk-test-WoiSpeedTierQAOnlySynthetic000000000000';
  const q=window.__speedQA={requests:[],connectionWrites:[],persistence:[],errors:[],blocked:[],
    mode:'codex',revision:0,keySet:false,failNextConnection:false,next:{},freeze:false,lockChecks:[]};
  const pause=ms=>new Promise(resolve=>setTimeout(resolve,ms));
  const response=(data,status=200)=>new Response(JSON.stringify(data),{status,headers:{'Content-Type':'application/json'}});
  const connection=()=>({auth_mode:q.mode,mode:q.mode,configured:q.mode==='codex'||q.keySet,
    source:q.mode==='codex'?'Independent mock Codex login':'Independent mock API key',
    revision:q.revision,session_key:q.keySet,
    speed_tiers:Object.entries(wire).map(([id,service_tier])=>({id,label:id,service_tier}))});
  addEventListener('error',event=>q.errors.push(event.message));
  addEventListener('unhandledrejection',event=>q.errors.push(String(event.reason)));
  q.assertPrivacy=()=>{
    const values={state:ClickLab.getState(),export:ClickLab.exportData(),request:ClickLab.getLastRequest(),
      localStorage:Object.fromEntries(Object.entries(localStorage)),sessionStorage:Object.fromEntries(Object.entries(sessionStorage)),
      rawResponse:document.getElementById('raw-response').textContent,
      visibleResults:document.getElementById('results-body').textContent,
      persistence:q.persistence};
    return Object.fromEntries(Object.entries(values).map(([name,value])=>[name,!JSON.stringify(value).includes(key)]));
  };
  q.checkFrozen=async()=>{
    const state=ClickLab.getState(),before={authMode:state.authMode,speedTier:state.speedTier,connection:state.connection};
    const checks={controls:[...document.querySelectorAll('input[name=auth-mode],input[name=speed-tier],#api-key,#save-api-key,#refresh-models')].every(e=>e.disabled)};
    try{ClickLab.selectSpeedTier(state.speedTier==='normal'?'fast':'normal');checks.speed=false;}catch{checks.speed=true;}
    try{await ClickLab.changeConnection(state.authMode==='codex'?'api':'codex');checks.connection=false;}catch{checks.connection=true;}
    try{await ClickLab.refreshModels();checks.catalog=false;}catch{checks.catalog=true;}
    const after=ClickLab.getState();checks.unchanged=after.authMode===before.authMode&&after.speedTier===before.speedTier&&JSON.stringify(after.connection)===JSON.stringify(before.connection);
    q.lockChecks.push(checks);
  };
  window.fetch=async(input,options={})=>{
    const url=new URL(typeof input==='string'?input:input.url,location.href),method=(options.method||'GET').toUpperCase();
    if(url.origin!==location.origin){q.blocked.push(url.origin+url.pathname);throw new Error('External request blocked by speed-tier QA');}
    if(url.pathname==='/api/connection'){
      if(method==='POST'){
        const body=JSON.parse(options.body||'{}');
        q.connectionWrites.push({auth_mode:body.auth_mode,keys:Object.keys(body).sort(),has_key:body.api_key===key,key_length:typeof body.api_key==='string'?body.api_key.length:0});
        if(q.failNextConnection){q.failNextConnection=false;return response({error:'Independent QA connection failure',error_code:'authentication'},401);}
        if(!['codex','api'].includes(body.auth_mode))return response({error:'Invalid connection'},400);
        q.mode=body.auth_mode;q.revision++;if(Object.hasOwn(body,'api_key'))q.keySet=Boolean(body.api_key);
      }
      return response(connection());
    }
    if(url.pathname==='/api/models')return response({auth:{mode:q.mode,configured:connection().configured},connection:connection(),
      source:['Independent browser QA'],models:[
        {id:'gpt-6-luna',kind:'text',transport:'responses',available:connection().configured,service_tiers:[{id:'priority',name:'Fast'}]},
        {id:'gpt-6.1-sol',kind:'text',transport:'responses',available:connection().configured,service_tiers:[{id:'priority',name:'Fast'}]},
        {id:'gpt-realtime-2.1',kind:'audio',transport:'realtime',available:connection().configured}
      ]});
    if(url.pathname==='/api/trial'){
      const payload=JSON.parse(options.body||'{}'),saved={...payload},config={...q.next};delete saved.screenshot;q.next={};
      q.requests.push({payload:saved,keys:Object.keys(payload).sort(),auth_mode:q.mode,connection_revision:q.revision,
        png:typeof payload.screenshot==='string'&&payload.screenshot.startsWith('data:image/png;base64,'),secret:JSON.stringify(payload).includes(key)});
      if(q.freeze)await q.checkFrozen();
      await pause(config.delay_ms??30);
      const layout=ClickLab.getLayout(),target=layout.targets.find(t=>payload.instruction.includes(t.label))||layout.targets[0];
      const requested=wire[payload.speed_tier],actual=config.actual===null?null:config.actual||requested;
      let result={request_id:payload.request_id,model:payload.model,auth_mode:q.mode,speed_tier:payload.speed_tier,
        connection_revision:q.revision,requested_service_tier:requested,actual_service_tier:actual,
        tier_status:actual===null?'unreported':actual===requested?'reported':'different',
        tier_note:actual===null?'Provider has not reported a tier.':actual===requested?'Provider reported the requested tier.':'Provider reported a different service tier.',
        action:'click',x:target.x+target.w/2,y:target.y+target.h/2,latency_ms:config.latency_ms??85,fresh_context:true,
        image_detail:'original',raw_output:{calls:[{name:'click',arguments:{x:target.x+target.w/2,y:target.y+target.h/2}}]}};
      if(config.legacy)for(const field of ['auth_mode','speed_tier','connection_revision','requested_service_tier','actual_service_tier','tier_status','tier_note'])delete result[field];
      if(config.reject)Object.assign(result,{action:null,x:null,y:null,error:'Provider rejected this speed tier; no fallback was attempted.',error_code:'tier_rejected',actual_service_tier:null,tier_status:'rejected'});
      return response(result,config.reject?422:200);
    }
    if(url.pathname==='/api/result'){
      q.persistence.push(JSON.parse(options.body||'{}'));return response({ok:true});
    }
    if(url.pathname.startsWith('/api/')){q.blocked.push(url.pathname);throw new Error('Unexpected API route blocked by speed-tier QA');}
    if(method!=='GET'){q.blocked.push(method+' '+url.pathname);throw new Error('Unexpected write blocked by speed-tier QA');}
    return realFetch(input,options);
  };
})();'''


def check(value, message):
    if not value:
        raise AssertionError(message)


async def ready(cdp, expression, seconds=12):
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        try:
            if await cdp.evaluate(expression):
                return
        except RuntimeError:
            pass
        await asyncio.sleep(.05)
    raise AssertionError("Timed out waiting for " + expression)


async def click(cdp, selector):
    rect = await cdp.evaluate("(() => {const e=document.querySelector("+json.dumps(selector)+");if(!e)throw new Error('Missing QA control');e.scrollIntoView({block:'center'});const r=e.getBoundingClientRect();return {x:r.x+r.width/2,y:r.y+r.height/2,disabled:e.disabled};})()")
    check(not rect.pop('disabled', False), 'Disabled control: '+selector)
    for kind in ('mousePressed', 'mouseReleased'):
        await cdp.command('Input.dispatchMouseEvent', {'type': kind, **rect, 'button': 'left', 'clickCount': 1})


async def idle(cdp):
    await ready(cdp, "!!window.ClickLab&&!ClickLab.getState().switching&&!ClickLab.getState().loadingModels&&!ClickLab.getState().inFlight&&!ClickLab.getState().batching")


async def select_tier(cdp, tier):
    await click(cdp, f'input[name="speed-tier"][value="{tier}"] + span')
    await ready(cdp, 'ClickLab.getState().speedTier==='+json.dumps(tier))


async def select_backend(cdp, mode):
    await idle(cdp)
    if await cdp.evaluate('ClickLab.getState().authMode') != mode:
        await click(cdp, f'input[name="auth-mode"][value="{mode}"] + span')
        await ready(cdp, 'ClickLab.getState().authMode==='+json.dumps(mode))
    await idle(cdp)


async def enter_key(cdp, expect_failure=False):
    await cdp.evaluate("document.getElementById('api-key').value="+json.dumps(SYNTHETIC_KEY))
    if expect_failure:
        await cdp.evaluate('__speedQA.failNextConnection=true')
    before = await cdp.evaluate('__speedQA.connectionWrites.length')
    await click(cdp, '#save-api-key')
    await ready(cdp, '__speedQA.connectionWrites.length>'+str(before))
    await idle(cdp)
    info = await cdp.evaluate("({cleared:document.getElementById('api-key').value==='',write:__speedQA.connectionWrites.at(-1),privacy:__speedQA.assertPrivacy(),status:document.getElementById('run-status').textContent})")
    check(info['cleared'], 'API key input retained the submitted key')
    check(info['write']['has_key'], 'The connection endpoint did not receive the synthetic key')
    check(info['write']['keys'] == ['api_key', 'auth_mode'], 'Connection request contains unexpected fields')
    check(all(info['privacy'].values()), 'Key leaked into '+str(info['privacy']))
    if expect_failure:
        check('failed' in info['status'].lower(), 'Connection failure was not visible')
    return info


async def prepare(cdp, model='gpt-6-luna', count=4):
    await idle(cdp)
    await cdp.evaluate("(() => {ClickLab.setLayout({seed:7441,width:1280,height:480,count:"+str(count)+"});ClickLab.selectModel("+json.dumps(model)+");const t=ClickLab.getLayout().targets[0];ClickLab.setInstruction('Click the '+t.label+' button.',{expectedTargetId:t.id,expectedAction:'click'});})()")


async def run_trial(cdp, config=None, freeze=False):
    await cdp.evaluate('Object.assign(__speedQA,{next:'+json.dumps(config or {})+',freeze:'+str(freeze).lower()+'})')
    await cdp.evaluate('ClickLab.runTrial()')
    data = await cdp.evaluate("({result:ClickLab.getState().results.at(-1),request:__speedQA.requests.at(-1),row:document.querySelector('#results-body tr').textContent,detail:document.getElementById('response-tier-detail').textContent,privacy:__speedQA.assertPrivacy(),locks:__speedQA.lockChecks.splice(0),errors:__speedQA.errors})")
    await cdp.evaluate('__speedQA.freeze=false')
    check(data['request']['png'], 'Trial did not carry a PNG screenshot')
    check(not data['request']['secret'], 'API key was sent in the trial payload')
    expected_fields = b.REQUEST_KEYS | {'speed_tier', 'connection_revision'}
    check(set(data['request']['keys']) == expected_fields, 'Unexpected trial fields: '+str(data['request']['keys']))
    check(all(data['privacy'].values()), 'Private key leaked: '+str(data['privacy']))
    check(not data['errors'], 'Browser errors: '+str(data['errors']))
    if freeze:
        check(data['locks'] and all(all(v.values()) for v in data['locks']), 'Configuration changed in flight: '+str(data['locks']))
    data['result'].pop('snapshot', None)
    return data


async def layout_check(cdp, width, height, mobile=False):
    await cdp.command('Emulation.setDeviceMetricsOverride', {'width':width,'height':height,'deviceScaleFactor':1,'mobile':mobile})
    await cdp.evaluate("new Promise(r=>requestAnimationFrame(()=>requestAnimationFrame(r)))")
    data = await cdp.evaluate(r'''(() => {
      const labels=[...document.querySelectorAll('.speed-segments label,.connection-segments label')].map(el=>{
        const span=el.querySelector('span'),range=document.createRange();range.selectNodeContents(span);
        const text=range.getBoundingClientRect(),box=span.getBoundingClientRect(),label=el.getBoundingClientRect(),style=getComputedStyle(span);
        return {text:span.textContent,visible:box.width>0&&box.height>0&&style.visibility!=='hidden'&&style.display!=='none',
          clipped:span.scrollWidth>span.clientWidth+1||span.scrollHeight>span.clientHeight+1||text.width>box.width+1||text.height>box.height+1,
          inside:label.left>=-1&&label.right<=innerWidth+1,width:box.width,height:box.height};
      });
      return {width:innerWidth,body:document.body.scrollWidth,document:document.documentElement.scrollWidth,labels,
        tier_options:[...document.querySelectorAll('input[name=speed-tier]')].map(e=>({value:e.value,disabled:e.disabled})),
        errors:__speedQA.errors};
    })()''')
    check(data['body'] <= data['width']+1 and data['document'] <= data['width']+1, 'Body overflow at '+str(width)+': '+str(data))
    check(len(data['labels']) == 6 and all(x['visible'] and not x['clipped'] and x['inside'] for x in data['labels']), 'Hidden/clipped configuration labels at '+str(width)+': '+str(data['labels']))
    check([x['value'] for x in data['tier_options']] == list(TIERS), 'Wrong speed tier options')
    check(not any(x['disabled'] for x in data['tier_options']), 'Selectable tiers disabled while idle')
    return data


async def screenshot(cdp, output, name):
    await cdp.evaluate('scrollTo(0,0)')
    data = await cdp.command('Page.captureScreenshot', {'format':'png','captureBeyondViewport':False})
    path = output / name
    path.write_bytes(base64.b64decode(data['data']))
    return path.name


async def run(args):
    output = Path(args.output)
    output.mkdir(parents=True, exist_ok=True)
    report = {'timestamp':datetime.now(timezone.utc).isoformat(),'url':args.url,'mode':'mocked APIs, isolated headless profile',
              'real_model_calls':0,'checks':[],'cases':{},'screenshots':[]}
    async with b.Browser(output) as browser:
        cdp = browser.cdp
        await cdp.command('Page.addScriptToEvaluateOnNewDocument', {'source':INIT})
        await cdp.command('Emulation.setDeviceMetricsOverride', {'width':1440,'height':1100,'deviceScaleFactor':1,'mobile':False})
        await cdp.command('Page.navigate', {'url':args.url.rstrip('/')+'/?seed=7441'})
        await ready(cdp, "!!window.ClickLab&&ClickLab.getState().models.length===3")
        await idle(cdp)
        report['checks'].append('Mocked catalog loaded; all API writes intercepted')

        # Both connections retain all four choices, including experimental Codex Flex.
        matrix=[]
        for mode in ['codex','api']:
            await select_backend(cdp, mode)
            if mode=='api':
                report['cases']['api_key_success']=await enter_key(cdp)
            await prepare(cdp)
            for tier,wire in TIERS.items():
                await select_tier(cdp,tier)
                trial=await run_trial(cdp, freeze=True)
                result,request=trial['result'],trial['request']
                check(request['payload']['speed_tier']==tier, f'{mode}/{tier}: outbound tier changed')
                check(request['auth_mode']==mode and request['payload']['connection_revision']==request['connection_revision'], f'{mode}/{tier}: backend revision changed')
                check(result['auth_mode']==mode and result['speed_tier']==tier, f'{mode}/{tier}: result lost test configuration')
                check(result['requested_service_tier']==wire and result['actual_service_tier']==wire, f'{mode}/{tier}: request/report tier mismatch')
                check(result['outcome']=='hit', f'{mode}/{tier}: synthetic click missed')
                check(wire in trial['row'] and ('Codex login' if mode=='codex' else 'API key') in trial['row'], f'{mode}/{tier}: configuration missing from visible result')
                matrix.append({'backend':mode,'tier':tier,'wire':wire,'payload':request['payload'],'locks':trial['locks'],'visible':trial['row']})
        report['cases']['tier_matrix']=matrix
        report['checks'].append('Eight Codex/API × Normal/Fast/Ultrafast/Flex combinations forwarded and frozen')

        # Returned tier must be treated as evidence, independently of request and latency.
        await select_tier(cdp,'fast')
        mismatch=await run_trial(cdp,{'actual':'default','latency_ms':1})
        check(mismatch['result']['actual_service_tier']=='default' and mismatch['result']['requested_service_tier']=='priority', 'Mismatch tier evidence collapsed')
        check('priority' in mismatch['row'] and 'default' in mismatch['row'] and 'different' in mismatch['row'].lower(), 'Downgrade not visible')
        unknown=await run_trial(cdp,{'actual':None,'latency_ms':1})
        check(unknown['result']['actual_service_tier'] is None and unknown['result']['tier_status'] not in ('confirmed','reported'), 'Unreported tier falsely confirmed')
        check('not reported' in unknown['row'].lower() and 'confirmed' not in unknown['row'].lower(), 'Unknown tier was not visibly unknown')
        rejected=await run_trial(cdp,{'reject':True})
        check(rejected['result']['outcome']=='error' and rejected['result']['tier_status']=='rejected', 'Tier rejection not preserved')
        check('rejected' in rejected['row'].lower(), 'Tier rejection not visible')
        report['cases']['observations']={name:{'row':trial['row'],'requested':trial['result']['requested_service_tier'],'actual':trial['result']['actual_service_tier'],'status':trial['result']['tier_status']} for name,trial in [('mismatch',mismatch),('unreported',unknown),('rejected',rejected)]}
        report['checks'].append('Requested/actual mismatch, unreported fast response, and rejection stay distinct')

        # Separate model dimension as well as both auth modes and all four tiers.
        await prepare(cdp,'gpt-6.1-sol')
        await run_trial(cdp)
        metrics=await cdp.evaluate('ClickLab.getState().metrics')
        expected={(mode,'gpt-6-luna',tier) for mode in ['codex','api'] for tier in TIERS}|{('api','gpt-6.1-sol','fast')}
        actual={(g['auth_mode'],g['model'],g['speed_tier']) for g in metrics['groups']}
        check(actual==expected, 'Metrics mixed backend/model/tier buckets: '+str(actual))
        check(metrics['mixed_configurations'] and metrics['hit_rate'] is None and metrics['median_latency_ms'] is None, 'Mixed groups presented a single comparable accuracy/latency')
        dom_count=await cdp.evaluate("document.querySelectorAll('#comparison-groups .comparison-group').length")
        check(dom_count==len(expected), 'Visible comparison groups missing')
        report['cases']['grouped_metrics']=metrics
        report['checks'].append('Nine backend/model/tier metric groups, including rejected/unreported evidence')

        report['cases']['api_key_failure']=await enter_key(cdp,expect_failure=True)
        report['checks'].append('API key input cleared on success and failure; no key in state, export, requests, storage, or results')

        # Batch settings are frozen for their entire lifetime, even between requests.
        batch_cases=[]
        for name,method,tier,mode in [('click_all','runClickAll','flex','codex'),('all_models','runBatch','ultrafast','api')]:
            await select_backend(cdp,mode)
            await prepare(cdp)
            await select_tier(cdp,tier)
            before=await cdp.evaluate('__speedQA.requests.length')
            await cdp.evaluate('__speedQA.freeze=true;__speedQA.lockChecks=[]')
            await cdp.evaluate('ClickLab.'+method+'()')
            data=await cdp.evaluate('({requests:__speedQA.requests.slice('+str(before)+'),locks:__speedQA.lockChecks,privacy:__speedQA.assertPrivacy(),state:ClickLab.getState()})')
            await cdp.evaluate('__speedQA.freeze=false')
            check(len(data['requests'])==(4 if name=='click_all' else len(MODELS)), name+': wrong request count')
            check(all(r['payload']['speed_tier']==tier and r['auth_mode']==mode for r in data['requests']),name+': tier or backend changed')
            check(len({r['payload']['connection_revision'] for r in data['requests']})==1,name+': connection revision changed')
            check(data['locks'] and all(all(lock.values()) for lock in data['locks']),name+': configuration lock failed')
            check(all(data['privacy'].values()),name+': key leaked')
            if name=='click_all':
                summary=data['state']['clickAllRun'];check(summary['auth_mode']==mode and summary['speed_tier']==tier,name+': summary lost config')
            check(not data['state']['inFlight'] and not data['state']['batching'],name+': controls remained locked')
            batch_cases.append({'name':name,'requests':data['requests'],'locks':data['locks'],'privacy':data['privacy']})
        report['cases']['batches']=batch_cases
        report['checks'].append('Click-all and all-model batches keep backend, revision, and tier fixed for every request')

        # Legacy schemas remain readable without inventing historical tier evidence.
        legacy=await cdp.evaluate(r'''(() => {
          const exported=ClickLab.exportData(),old=JSON.parse(JSON.stringify(exported.results[0]));
          for(const k of ['auth_mode','speed_tier','connection_revision','requested_service_tier','actual_service_tier','tier_status','tier_note']){delete old[k];if(old.response)delete old.response[k];}
          const restored=ClickLab.restoreData({schema_version:2,results:[old],captures:exported.captures,click_all_runs:[]});
          return {restored,row:document.querySelector('#results-body tr').textContent,metrics:ClickLab.getState().metrics,privacy:__speedQA.assertPrivacy()};
        })()''')
        check(legacy['restored']['results']==1 and 'legacy' in legacy['row'].lower() and 'not recorded' in legacy['row'].lower(),'Legacy result gained fabricated tier data')
        check('confirmed' not in legacy['row'].lower() and all(legacy['privacy'].values()),'Legacy result falsely confirmed a tier or leaked key')
        report['cases']['legacy_restore']=legacy
        report['checks'].append('Version-2 legacy results render with tier not recorded')

        layouts=[]
        for width,height,mobile in [(1440,1100,False),(780,1100,False),(390,844,True),(320,760,True)]:
            await select_backend(cdp,'api')
            layouts.append(await layout_check(cdp,width,height,mobile))
            if width in (1440,390):report['screenshots'].append(await screenshot(cdp,output,f'speed-tiers-ui-{width}.png'))
        report['cases']['layouts']=layouts
        report['checks'].append('Desktop/tablet/390px/320px layouts avoid body overflow and keep all six option labels readable')
        final=await cdp.evaluate('({errors:__speedQA.errors,blocked:__speedQA.blocked,request_count:__speedQA.requests.length,ids:__speedQA.requests.map(r=>r.payload.request_id),privacy:__speedQA.assertPrivacy()})')
        check(not final['errors'] and not final['blocked'],'Browser errors or unplanned route: '+str(final))
        check(len(final['ids'])==len(set(final['ids'])),'Fresh requests reused an ID')
        check(all(final['privacy'].values()),'Final privacy check failed')
        report['cases']['final']=final
        report['checks'].append('Every request ID unique; no browser errors, external calls, or secret leakage')
    report['passed']=True
    path=output/'speed-tiers-ui-validation.json'
    path.write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps({'passed':True,'checks':len(report['checks']),'mocked_trials':report['cases']['final']['request_count'],'report':str(path),'screenshots':report['screenshots']},indent=2))
    return report


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--url',default='http://127.0.0.1:38631')
    parser.add_argument('--output',default='qa/out/speed_tiers_ui')
    args=parser.parse_args()
    asyncio.run(run(args))


if __name__=='__main__':
    main()
