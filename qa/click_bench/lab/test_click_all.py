#!/usr/bin/env python3
"""Independent click-all browser QA. Every model call and result write is mocked.

Uses a separate Chromium profile; never touches the user's visible lab state.
The click listener measures browser DOM events independently of app statistics.
Run: ../woi/research/.venv/bin/python qa/click_bench/lab/test_click_all.py --url http://127.0.0.1:38631
"""
from __future__ import annotations

import argparse
import asyncio
import base64
import hashlib
import json
from pathlib import Path
import statistics
import time

import benchmark as b


INIT = r'''(() => {
  const realFetch=window.fetch.bind(window),realCapture=HTMLCanvasElement.prototype.toDataURL;
  window.__qa={requests:[],clicks:[],persistence:[],captures:[],errors:[],locks:{},active:null,config:{}};
  const pause=ms=>new Promise(resolve=>setTimeout(resolve,ms));
  addEventListener('error',e=>__qa.errors.push(e.message));
  addEventListener('unhandledrejection',e=>__qa.errors.push(String(e.reason)));
  addEventListener('click',event=>{
    const frame=document.getElementById('board-frame');
    if(!frame||!frame.contains(event.target))return;
    __qa.clicks.push({request_id:__qa.active,perf_ms:performance.now(),target_id:event.target.closest('[data-target]')?.dataset.target||null,isTrusted:event.isTrusted});
  },true);
  HTMLCanvasElement.prototype.toDataURL=function(...args){
    if(!__qa.config.active)return realCapture.apply(this,args);
    const index=__qa.captures.length,start=performance.now();
    if(__qa.config.capture_error_at===index){__qa.captures.push({start,end:performance.now(),error:true});throw new Error('Independent QA forced capture failure');}
    while(performance.now()-start<(__qa.config.capture_delay_ms||0)){}
    const result=realCapture.apply(this,args);
    __qa.captures.push({start,end:performance.now(),error:false});return result;
  };
  window.fetch=async(input,options={})=>{
    const url=new URL(typeof input==='string'?input:input.url,location.href);
    if(url.pathname==='/api/trial'){
      if(!__qa.config.active)throw new Error('Unplanned model request blocked by independent QA');
      const sent=performance.now(),payload=JSON.parse(options.body),index=__qa.requests.length;
      __qa.active=payload.request_id;__qa.requests.push({payload,sent_perf_ms:sent,layout:ClickLab.getLayout()});
      if(index===0){
        const forbidden={layout:()=>ClickLab.setLayout({seed:1}),model:()=>ClickLab.selectModel('gpt-6.1-sol'),instruction:()=>ClickLab.setInstruction('Previous history must never be sent'),restore:()=>ClickLab.restoreData({results:[]})};
        for(const [name,fn] of Object.entries(forbidden)){try{fn();__qa.locks[name]=false;}catch{__qa.locks[name]=true;}}
        for(const [name,fn] of Object.entries({overlapping_batch:()=>ClickLab.runClickAll(),overlapping_trial:()=>ClickLab.runTrial()})){
          Promise.resolve().then(fn).then(()=>__qa.locks[name]=false,()=>__qa.locks[name]=true);
        }
        __qa.locks.controls=['resolution','button-count','randomize','instruction','refresh-models','click-all','batch','send'].every(id=>document.getElementById(id).disabled);
        __qa.locks.radios=[...document.querySelectorAll('input[name=model]')].every(el=>el.disabled);
        __qa.locks.active=ClickLab.getState().batching&&ClickLab.getState().inFlight;
      }
      const outcome=__qa.config.outcomes[index]||'hit',delay=__qa.config.delays[index]??30;
      await pause(delay);
      const layout=ClickLab.getLayout(),label=payload.instruction.replace(/^(Click the |Move the pointer to the )/,'').replace(/ button\.$/,''),target=layout.targets.find(t=>t.label===label);
      if(!target)throw new Error('No exact instruction target in QA layout');
      let response={action:'click',x:target.x+target.w/2,y:target.y+target.h/2,request_id:payload.request_id,model:payload.model,latency_ms:999999,fresh_context:true,image_detail:'original'},status=200;
      if(outcome==='miss')Object.assign(response,{x:5,y:5});
      if(outcome==='move')response.action='move';
      if(outcome==='bounds')response.x=layout.width+1;
      if(outcome==='mismatch')response.request_id='not-the-request';
      if(outcome==='error'){response={error:'Independent QA simulated upstream failure',error_code:'api_error',request_id:payload.request_id,model:payload.model};status=503;}
      __qa.requests[index].returned_perf_ms=performance.now();
      return new Response(JSON.stringify(response),{status,headers:{'Content-Type':'application/json'}});
    }
    if(url.pathname==='/api/result'){
      const data=JSON.parse(options.body),entry={request_id:data.request_id,record_type:data.record_type||'trial',sent_perf_ms:performance.now()};
      __qa.persistence.push(entry);await pause(data.record_type==='click_all_summary'?(__qa.config.summary_delay_ms||0):(__qa.config.persistence_delay_ms||0));entry.finished_perf_ms=performance.now();
      return new Response('{"ok":true}',{status:200,headers:{'Content-Type':'application/json'}});
    }
    if((options.method||'GET').toUpperCase()!=='GET')throw new Error('Unexpected write blocked by independent QA');
    return realFetch(input,options);
  };
})();'''


def check(value, message):
    if not value:
        raise AssertionError(message)


async def ready(cdp, expression, limit=150):
    for _ in range(limit):
        try:
            if await cdp.evaluate(expression):
                return
        except RuntimeError:
            pass
        await asyncio.sleep(.05)
    raise AssertionError('Timed out: '+expression)


async def click_control(cdp, control):
    rect = await cdp.evaluate("(() => {const e=document.getElementById("+json.dumps(control)+");e.scrollIntoView({block:'center'});const r=e.getBoundingClientRect();return {x:r.x+r.width/2,y:r.y+r.height/2};})()")
    for kind in ('mousePressed', 'mouseReleased'):
        await cdp.command('Input.dispatchMouseEvent', {'type':kind, **rect, 'button':'left', 'clickCount':1})


async def run_scenario(cdp, url, name, config, stop=False, narrow=False):
    await cdp.command('Emulation.setDeviceMetricsOverride', {'width':780 if narrow else 1440,'height':1200 if narrow else 1100,'deviceScaleFactor':2 if narrow else 1,'mobile':False})
    await cdp.command('Page.navigate', {'url':url+'/?seed=7441'})
    await ready(cdp, "!!window.ClickLab && ClickLab.getState().models.some(m=>m.id==='gpt-6-luna'&&m.available)")
    setup = {'seed':7441,'width':2560 if narrow else 1280,'height':1440 if narrow else 480,'count':config['count']}
    await cdp.evaluate("(() => {ClickLab.setLayout("+json.dumps(setup)+");ClickLab.selectModel('gpt-6-luna');__qa.cleanScreenshot=ClickLab.capture().screenshot;__qa.initialLayout=ClickLab.getLayout();__qa.config="+json.dumps(config)+";__qa.config.active=true;__qa.external_start=performance.now();window.__qaPromise=ClickLab.runClickAll();return true;})()")
    if stop:
        await ready(cdp, '__qa.requests.length===1 && ClickLab.getState().inFlight')
        await click_control(cdp, 'stop')
        stopped = await cdp.evaluate('ClickLab.getState().clickAllRun.stop_requested')
        check(stopped, name+': stop control did not request stop')
    await cdp.evaluate('window.__qaPromise')
    data = await cdp.evaluate(r'''(() => {
      const summary=ClickLab.getState().clickAllRun,state=ClickLab.getState(),exported=ClickLab.exportData();
      const fields=['button-run-score','button-run-completed','button-run-total','button-run-mean','button-run-min','button-run-max','button-run-timing-note','button-run-failures','button-run-badge'];
      const ui=Object.fromEntries(fields.map(id=>[id,document.getElementById(id).textContent]));
      __qa.config.active=false;
      const restored=ClickLab.restoreData(exported),after=ClickLab.getState().clickAllRun;
      return {name:__qa.config.name,summary,ui,requests:__qa.requests,clicks:__qa.clicks,persistence:__qa.persistence,captures:__qa.captures,
        errors:__qa.errors,locks:__qa.locks,initial_layout:__qa.initialLayout,final_layout:ClickLab.getLayout(),clean_screenshot:__qa.cleanScreenshot,
        external_start:__qa.external_start,returned_perf_ms:performance.now(),unlocked:!state.batching&&!state.inFlight&&!document.getElementById('click-all').disabled,
        export_schema:exported.schema_version,export_run_count:exported.click_all_runs.length,restored,restored_summary:after};
    })()''')
    data['name']=name
    validate_common(data, config)
    return data


def validate_common(data, config):
    name=data['name']; s=data['summary']; requests=data['requests']
    check(not data['errors'], name+': browser errors '+str(data['errors']))
    check(data['unlocked'], name+': controls remained locked')
    check(all(data['locks'].values()) and len(data['locks'])==9, name+': concurrent controls were not frozen '+str(data['locks']))
    check(data['initial_layout']==data['final_layout'], name+': layout mutated')
    check(len({r['payload']['request_id'] for r in requests})==len(requests), name+': reused request id')
    check(all(set(r['payload'])==b.REQUEST_KEYS|{'speed_tier','connection_revision'} for r in requests), name+': non-current payload fields')
    check(all(r['payload']['model']=='gpt-6-luna' for r in requests), name+': model changed')
    check(all(r['payload']['screenshot']==data['clean_screenshot'] for r in requests), name+': screenshot changed or overlay leaked')
    check(all(r['layout']==data['initial_layout'] for r in requests), name+': request layout changed')
    expected=data['initial_layout']['targets'][:len(requests)]
    check([r['payload']['instruction'] for r in requests]==['Click the '+t['label']+' button.' for t in expected], name+': skipped, duplicated, or wrong target order')
    check(s['planned_buttons']==config['count'], name+': wrong planned count')
    check(s['completed_attempts']==len(s['trials']), name+': wrong completed denominator')
    check(s['successful_clicks']==sum(t['category']=='hit' for t in s['trials']), name+': wrong success count')
    check(s['failed_attempts']==s['completed_attempts']-s['successful_clicks'], name+': wrong failure count')
    check(s['accuracy']==(s['successful_clicks']/s['completed_attempts'] if s['completed_attempts'] else None), name+': wrong accuracy denominator')
    samples=[t['send_to_click_ms'] for t in s['trials'] if t['click_count']>0]
    check(s['latency_sample_count']==len(samples)==len(data['clicks']), name+': click sample count disagrees with observed DOM events')
    check(s['latency_excluded_attempts']==len(s['trials'])-len(samples), name+': excluded sample count')
    for field,expected_stat in [('mean_send_to_click_ms',statistics.mean(samples) if samples else None),('min_send_to_click_ms',min(samples) if samples else None),('max_send_to_click_ms',max(samples) if samples else None)]:
        check(s[field]==expected_stat or (samples and abs(s[field]-expected_stat)<1e-8), name+': wrong '+field)
    independent_samples=[]
    for t in s['trials']:
        clicks=[e for e in data['clicks'] if e['request_id']==t['request_id']]
        if t['click_count']:
            check(len(clicks)==1, name+': duplicate or missing DOM click')
            req=next(r for r in requests if r['payload']['request_id']==t['request_id'])
            actual=clicks[0]['perf_ms']-req['sent_perf_ms'];independent_samples.append(actual)
            check(abs(actual-t['send_to_click_ms'])<20, name+': send-to-click timer disagrees with independent event listener')
            check(abs(t['send_to_click_ms']-(t['click_dispatched_perf_ms']-t['request_sent_perf_ms']))<1e-8, name+': timing timestamp arithmetic')
            check(t['api_latency_ms']==999999 and t['send_to_click_ms']<10000, name+': used fake API duration as end-to-end time')
            persistence=next(p for p in data['persistence'] if p['request_id']==t['request_id'])
            check(persistence['sent_perf_ms']>=t['click_dispatched_perf_ms'], name+': persistence preceded actual click')
        else:
            check(not clicks and t['send_to_click_ms'] is None, name+': non-click attempt acquired a sample')
    summary_record=next(p for p in data['persistence'] if p['record_type']=='click_all_summary')
    check(abs((summary_record['sent_perf_ms']-s['started_perf_ms'])-s['total_wall_ms'])<30, name+': wall timer did not end before summary persistence')
    check(data['returned_perf_ms']-summary_record['sent_perf_ms']>=config.get('summary_delay_ms',0)-5, name+': missing controlled summary persistence delay')
    check(s['total_wall_ms']>=sum(config['delays'][:len(requests)])+config.get('persistence_delay_ms',0)*len(requests)-20, name+': wall timer omitted request/persistence time')
    check(data['export_schema']==3 and data['restored']['click_all_runs']==1 and data['restored_summary']['trials']==s['trials'], name+': export/restore lost run evidence')
    check(data['restored_summary']['total_wall_ms']==s['total_wall_ms'], name+': export/restore altered elapsed time')
    check(data['ui']['button-run-score']==f"{s['successful_clicks']} / {s['completed_attempts']}", name+': UI score incorrect')
    check(data['ui']['button-run-completed']==f"{s['completed_attempts']} / {s['planned_buttons']}", name+': UI progress incorrect')
    check(str(len(samples))+' executed clicks' in data['ui']['button-run-timing-note'], name+': UI missing sample count')
    data['independent_send_to_click_ms']=independent_samples
    data['checks_passed']=True


def sanitize(data):
    for request in data['requests']:
        p=request['payload'];raw=base64.b64decode(p.pop('screenshot').split(',',1)[1]);p['screenshot_sha256']=hashlib.sha256(raw).hexdigest()
    raw=base64.b64decode(data.pop('clean_screenshot').split(',',1)[1]);data['clean_screenshot_sha256']=hashlib.sha256(raw).hexdigest()
    return data



async def event_cap_regression(args):
    output=Path(args.output);output.mkdir(parents=True,exist_ok=True)
    async with b.Browser(output) as browser:
        cdp=browser.cdp
        await cdp.command('Page.addScriptToEvaluateOnNewDocument', {'source':INIT})
        await cdp.command('Page.navigate', {'url':args.url+'/?seed=7441'})
        await ready(cdp, "!!window.ClickLab && ClickLab.getState().models.some(m=>m.id==='gpt-6-luna'&&m.available)")
        result=await cdp.evaluate(r'''(async()=>{
          ClickLab.setLayout({seed:7441,width:1280,height:480,count:4});ClickLab.selectModel('gpt-6-luna');ClickLab.clearEvents();
          const frame=document.getElementById('board-frame'),rect=frame.getBoundingClientRect();
          for(let i=0;i<5005;i++)frame.dispatchEvent(new MouseEvent('mousedown',{bubbles:true,clientX:rect.x+5,clientY:rect.y+5,button:0}));
          const before=ClickLab.getEvents().length,targets=ClickLab.getLayout().targets;
          __qa.config={active:true,outcomes:['hit','move'],delays:[35,35],persistence_delay_ms:0};
          const click=await ClickLab.runTrial({instruction:'Click the '+targets[0].label+' button.',expectedTargetId:targets[0].id,expectedAction:'click'});
          const afterClick=ClickLab.getEvents().length;
          const move=await ClickLab.runTrial({instruction:'Move the pointer to the '+targets[1].label+' button.',expectedTargetId:targets[1].id,expectedAction:'move'});
          const afterMove=ClickLab.getEvents().length;
          return {before,afterClick,afterMove,click,move,observed_clicks:__qa.clicks,requests:__qa.requests.map(r=>({request_id:r.payload.request_id,sent_perf_ms:r.sent_perf_ms})),errors:__qa.errors};
        })()''')
    check((result['before'],result['afterClick'],result['afterMove'])==(5000,5000,5000),'event history cap did not remain at 5000')
    click,move=result['click'],result['move']
    check(click['hit'] is True and click['execution']['click_count']==1,'saturated history lost current click')
    check([e['type'] for e in click['execution']['events']]==['pointermove','mousedown','mouseup','click'],'current click event buffer incorrect')
    check(move['hit'] is True and move['execution']['click_count']==0,'saturated history lost current move or added click')
    check([e['type'] for e in move['execution']['events']]==['pointermove'],'current move event buffer incorrect')
    check(all(e['request_id']==trial['request_id'] for trial in (click,move) for e in trial['execution']['events']),'current dispatch contains old events')
    check(click['send_to_click_ms'] is not None and move['send_to_click_ms'] is None,'saturated history corrupted click timing')
    check(len(result['observed_clicks'])==1,'move generated extra DOM click')
    measured=result['observed_clicks'][0]['perf_ms']-result['requests'][0]['sent_perf_ms']
    check(abs(measured-click['send_to_click_ms'])<20,'saturated history timer disagrees with independent click listener')
    check(not result['errors'],'browser errors during event-cap check')
    result.update(all_passed=True,model_api_calls=0,mocked_trial_requests=2,independent_send_to_click_ms=measured,
                  scope='Single focused saturated-history regression after the per-dispatch buffer fix. Global event log stays capped at 5000; exact-center click and move retain their own evidence.',
                  app_js_sha256=hashlib.sha256(Path(__file__).with_name('app.js').read_bytes()).hexdigest())
    path=output/'event-cap-regression.json';path.write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps({'all_passed':True,'model_api_calls':0,'mocked_trial_requests':2,'history_lengths':[result[k] for k in ('before','afterClick','afterMove')],'click_events':len(click['execution']['events']),'move_events':len(move['execution']['events']),'send_to_click_ms':click['send_to_click_ms'],'report':str(path)},indent=2))

async def main(args):
    output=Path(args.output);output.mkdir(parents=True,exist_ok=True)
    scenarios=[]
    async with b.Browser(output) as browser:
        cdp=browser.cdp
        await cdp.command('Page.addScriptToEvaluateOnNewDocument', {'source':INIT})
        common={'persistence_delay_ms':80,'summary_delay_ms':120,'capture_delay_ms':40}
        mixed=await run_scenario(cdp,args.url,'mixed-six',dict(common,count=6,outcomes=['hit','miss','error','move','bounds','mismatch'],delays=[30,70,110,150,50,50]))
        s=mixed['summary'];check((s['successful_clicks'],s['completed_attempts'],s['missed_clicks'],s['invalid_actions'],s['request_errors'],s['local_errors'],s['latency_sample_count'])==(1,6,1,2,1,1,2),'mixed outcome category/accounting mismatch')
        check(s['status']=='completed' and s['accuracy']==1/6,'mixed run status or denominator')
        scenarios.append(sanitize(mixed))
        stopped=await run_scenario(cdp,args.url,'stop-during-first-request',dict(common,count=5,outcomes=['hit'],delays=[450]),stop=True)
        s=stopped['summary'];check((s['status'],s['completed_attempts'],s['successful_clicks'],s['accuracy'],s['failed_attempts'])==('stopped',1,1,1,0),'stopped run counted unattempted buttons as misses')
        check(len(stopped['requests'])==1 and s['stop_requested'],'stopped run sent extra request')
        scenarios.append(sanitize(stopped))
        failed=await run_scenario(cdp,args.url,'capture-failure-after-one-dpr2',dict(common,count=5,outcomes=['hit'],delays=[40],capture_error_at=1),narrow=True)
        s=failed['summary'];check((s['status'],s['completed_attempts'],s['successful_clicks'],s['local_errors'],s['accuracy'])==('error',2,1,1,.5),'local capture failure did not retain completed/partial accounting')
        check(len(failed['requests'])==1,'capture failure sent extra request')
        scenarios.append(sanitize(failed))
        errors=await run_scenario(cdp,args.url,'no-click-samples',dict(common,count=4,outcomes=['error']*4,delays=[30]*4))
        s=errors['summary'];check((s['completed_attempts'],s['successful_clicks'],s['request_errors'],s['latency_sample_count'],s['accuracy'])==(4,0,4,0,0),'all errors incorrectly scored or timed')
        check(all(errors['ui']['button-run-'+key]=='—' for key in ('mean','min','max')),'no-sample UI should use an em dash')
        scenarios.append(sanitize(errors))
    report={'schema_version':1,'created_at':time.strftime('%Y-%m-%dT%H:%M:%SZ',time.gmtime()),'all_passed':True,'source':'independent headless Chromium/CDP browser observations','model_api_calls':0,'mocked_trial_requests':sum(len(s['requests']) for s in scenarios),'external_result_writes':0,'scope':'Batch sequencing, stable screenshot/model, payload isolation, actual DOM click observation, accounting, end-to-end timestamps, stop/partial/error handling, persistence timing, export/restore. Synthetic app clicks are intentionally not OS input.','scenarios':scenarios}
    path=output/'independent-click-all-qa.json';path.write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps({'all_passed':True,'scenarios':len(scenarios),'mocked_requests':report['mocked_trial_requests'],'model_api_calls':0,'report':str(path),'outcomes':[{k:s['summary'][k] for k in ('status','planned_buttons','completed_attempts','successful_clicks','latency_sample_count','total_wall_ms')} for s in scenarios]},indent=2),flush=True)


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--url',default='http://127.0.0.1:38631')
    parser.add_argument('--output',default='qa/out/click_lab/click_all/independent_qa')
    parser.add_argument('--event-cap-only',action='store_true',help='Only the focused saturated-history regression; two mocked calls.')
    args=parser.parse_args()
    asyncio.run(event_cap_regression(args) if args.event_cap_only else main(args))
