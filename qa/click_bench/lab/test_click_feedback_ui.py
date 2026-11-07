#!/usr/bin/env python3
"""Focused independent QA for success feedback and request timing.

Uses the accepted speed-tier harness's isolated browser and API connection mocks.
Model responses are controlled, including gated in-flight observations; no real
model call or visible-desktop interaction occurs. Pixel checks inspect only the
local success overlay and confirm its pixels never enter the captured base PNG.
"""
from __future__ import annotations

import argparse
import asyncio
import base64
from datetime import datetime, timezone
import json
from pathlib import Path
import re

import test_speed_tiers_ui as base

TIMING = {
    'origin': 'provider_request_start',
    'upload_complete_ms': 125.0,
    'upload_duration_ms': 20.0,
    'first_token_ms': 450.0,
    'first_output_ms': 450.0,
    'first_output_source': 'stream_delta',
    'finish_ms': 925.0,
    'status': 'completed',
    'upload_measurement': 'client_send_completion',
    'note': 'Independent QA fixture: offsets and body duration intentionally differ.',
}
UNKNOWN = {**TIMING, 'upload_complete_ms': None, 'upload_duration_ms': None,
           'first_token_ms': None, 'first_output_ms': None, 'first_output_source': None,
           'finish_ms': None, 'status': 'not_started', 'upload_measurement': None}
FINAL_ONLY = {**TIMING, 'first_token_ms': None, 'first_output_ms': 880.0,
              'first_output_source': 'final_only'}

INIT = base.INIT + r'''
(() => {
  const prior=window.fetch.bind(window),wire={normal:'default',fast:'priority',ultrafast:'ultrafast',flex:'flex'};
  const q=window.__feedback={requests:[],pending:[],plan:[],planIndex:0,clean:null,rawBytes:null,promise:null};
  q.begin=(plan)=>{q.plan=plan;q.planIndex=0;q.clean=ClickLab.capture().screenshot;q.rawBytes=atob(q.clean.split(',')[1]).length;};
  q.release=()=>{const next=q.pending.shift();if(!next)throw new Error('No gated model response');next.resolve();return next.index;};
  window.fetch=async(input,options={})=>{
    const url=new URL(typeof input==='string'?input:input.url,location.href);
    if(url.pathname!=='/api/trial')return prior(input,options);
    const payload=JSON.parse(options.body),plan=q.plan[q.planIndex++]||{},index=q.requests.length;
    const info={index,model:payload.model,request_id:payload.request_id,tier:payload.speed_tier,
      clean_png:payload.screenshot===q.clean,image_bytes:atob(payload.screenshot.split(',')[1]).length,
      completed_at_send:ClickLab.getState().completedTargetIds||[]};
    q.requests.push(info);
    if(plan.gate!==false)await new Promise(resolve=>q.pending.push({index,resolve}));
    const layout=ClickLab.getLayout(),target=layout.targets.find(t=>payload.instruction.includes(t.label))||layout.targets[0],outcome=plan.outcome||'hit';
    const result={request_id:payload.request_id,model:payload.model,auth_mode:__speedQA.mode,speed_tier:payload.speed_tier,
      requested_service_tier:wire[payload.speed_tier],actual_service_tier:wire[payload.speed_tier],tier_status:'reported',
      connection_revision:__speedQA.revision,action:outcome==='move'?'move':'click',x:target.x+target.w/2,y:target.y+target.h/2,
      latency_ms:7777,fresh_context:true,image_detail:'original',image_bytes:info.image_bytes,
      request_image_bytes:info.image_bytes,request_payload_bytes:456789};
    if(Object.hasOwn(plan,'timing'))result.timing=plan.timing;
    if(outcome==='miss'){result.x=1;result.y=1;}
    if(outcome==='error'){Object.assign(result,{action:null,x:null,y:null,error:'Controlled model failure',error_code:'mock_provider_error'});if(result.timing&&result.timing.status==='completed')result.timing={...result.timing,status:'error'};}
    return new Response(JSON.stringify(result),{status:outcome==='error'?503:200,headers:{'Content-Type':'application/json'}});
  };
})();'''


def check(value, message):
    base.check(value, message)


def displayed_ms(text):
    match = re.search(r'([0-9]+(?:\.[0-9]+)?)\s*(ms|s)\b', text)
    if not match:
        raise AssertionError('No displayed duration in '+repr(text))
    return float(match[1]) * (1000 if match[2]=='s' else 1)


def check_offset(text, expected, name):
    actual = displayed_ms(text)
    check(abs(actual-expected)<=10, f'{name}: displayed {actual} ms instead of {expected} ms: {text!r}')


async def inspect(cdp):
    return await cdp.evaluate(r'''(() => {
      const state=ClickLab.getState(),canvas=document.getElementById('successes');
      if(!canvas)throw new Error('Missing success overlay');
      const ctx=canvas.getContext('2d'),targets=ClickLab.getLayout().targets.map(t=>{
        const data=ctx.getImageData(t.x,t.y,t.w,t.h).data;let black=0,white=0,painted=0;
        for(let i=0;i<data.length;i+=4){if(data[i+3]>0)painted++;if(data[i+3]>200&&data[i]<15&&data[i+1]<15&&data[i+2]<15)black++;if(data[i+3]>100&&data[i]>235&&data[i+1]>235&&data[i+2]>235)white++;}
        return {id:t.id,completed:document.querySelector('[data-target="'+t.id+'"]').classList.contains('completed'),black,white,painted};
      });
      const fields=Object.fromEntries(['request-image-size','request-upload','request-first-reply','request-finished'].map(id=>{
        const e=document.getElementById(id);if(!e)throw new Error('Missing timeline field '+id);
        return [id,{text:e.textContent,title:e.title,data:{...e.dataset},label:e.parentElement.textContent}];
      }));
      const timeline=document.getElementById('request-timeline'),latest=state.results.at(-1);
      return {completed:state.completedTargetIds,targets,clean_png:ClickLab.capture().screenshot===__feedback.clean,
        raw_bytes:__feedback.rawBytes,fields,timeline:{hidden:timeline.hidden,text:timeline.textContent},
        status:document.getElementById('run-status').textContent,inFlight:state.inFlight,batching:state.batching,
        pending:__feedback.pending.map(x=>x.index),latest:latest?{request_id:latest.request_id,hit:latest.hit,outcome:latest.outcome,
          prediction:latest.prediction,execution:latest.execution,response:latest.response}:null,
        privacy:__speedQA.assertPrivacy(),errors:__speedQA.errors};
    })()''')


def assert_overlay(data, ids, context):
    check(set(data['completed'])==set(ids),context+': completion state '+str(data['completed']))
    check({t['id'] for t in data['targets'] if t['completed']}==set(ids),context+': DOM completion state differs')
    for t in data['targets']:
        if t['id'] in ids:
            check(t['black']>50 and t['white']>3,context+': success is not black with white text '+str(t))
        else:
            check(t['painted']==0,context+': non-success target was painted '+str(t))
    check(data['clean_png'],context+': local feedback contaminated the model PNG')
    check(all(data['privacy'].values()),context+': secret leaked')
    check(not data['errors'],context+': browser errors '+str(data['errors']))


async def start(cdp, method, plan, instruction=None, expected=None):
    await base.idle(cdp)
    if instruction is not None:
        opts={'expectedTargetId':expected.get('target','auto'),'expectedAction':expected.get('action','auto')} if expected else {}
        await cdp.evaluate('ClickLab.setInstruction('+json.dumps(instruction)+','+json.dumps(opts)+')')
    count=await cdp.evaluate('__feedback.requests.length')
    await cdp.evaluate('(() => {__feedback.begin('+json.dumps(plan)+');__feedback.promise=ClickLab.'+method+'();return true;})()')
    await base.ready(cdp,'__feedback.requests.length>'+str(count)+'&&__feedback.pending.length===1')
    return count


async def release(cdp, wait_next=None):
    await cdp.evaluate('__feedback.release()')
    if wait_next is not None:
        await base.ready(cdp,'__feedback.requests.length==='+str(wait_next)+'&&__feedback.pending.length===1')
    else:
        await cdp.evaluate('(async()=>{await __feedback.promise;return true;})()')
        await base.idle(cdp)
    return await inspect(cdp)


async def run(args):
    output=Path(args.output);output.mkdir(parents=True,exist_ok=True)
    report={'timestamp':datetime.now(timezone.utc).isoformat(),'mode':'mocked API, isolated headless browser',
            'real_model_calls':0,'checks':[],'scenarios':{},'screenshots':[]}
    async with base.b.Browser(output) as browser:
        cdp=browser.cdp
        await cdp.command('Page.addScriptToEvaluateOnNewDocument',{'source':INIT})
        await cdp.command('Emulation.setDeviceMetricsOverride',{'width':1440,'height':1100,'deviceScaleFactor':1,'mobile':False})
        await cdp.command('Page.navigate',{'url':args.url.rstrip('/')+'/?seed=7441'})
        await base.ready(cdp,"!!window.ClickLab&&ClickLab.getState().models.length===3")
        await base.prepare(cdp)
        targets=await cdp.evaluate('ClickLab.getLayout().targets')
        ids=[t['id'] for t in targets]
        label=targets[0]['label']
        instruction='Click the '+label+' button.'

        # A known successful click: inspect both in-flight placeholders and actual overlay pixels.
        await start(cdp,'runTrial',[{'timing':TIMING}],instruction,{'target':ids[0],'action':'click'})
        pending=await inspect(cdp)
        assert_overlay(pending,[],'first in-flight request')
        check(not pending['timeline']['hidden'] and pending['inFlight'],'No ongoing request timeline')
        check('complete' not in pending['status'].lower() and 'finished' not in pending['status'].lower(),'Pending request advertised as finished')
        for name in ['request-upload','request-first-reply','request-finished']:
            check(re.search(r'—|pending|waiting|not yet',pending['fields'][name]['text'],re.I),name+': pending measurement is fabricated '+pending['fields'][name]['text'])
        hit=await release(cdp)
        assert_overlay(hit,[ids[0]],'correct scored click')
        check(hit['latest']['hit'] is True and hit['latest']['execution']['click_count']==1,'Synthetic click did not score correctly')
        fields=hit['fields']
        check_offset(fields['request-upload']['text'],TIMING['upload_complete_ms'],'Upload completion')
        check_offset(fields['request-first-reply']['text'],TIMING['first_token_ms'],'First token')
        check_offset(fields['request-finished']['text'],TIMING['finish_ms'],'Provider finish')
        byte_value=fields['request-image-size']['data'].get('bytes')
        check(byte_value is not None and int(byte_value)==hit['raw_bytes'],'Image size does not expose raw PNG byte count')
        check(str(hit['raw_bytes']) in re.sub(r'(?<=\d)[,\s](?=\d)','',fields['request-image-size']['title']),'Image size title missing exact bytes')
        check(hit['latest']['response']['request_payload_bytes']!=hit['raw_bytes'],'Test fixture failed to distinguish image/payload bytes')
        check('7777' not in hit['timeline']['text'] and '7.777' not in hit['timeline']['text'],'Timeline incorrectly used aggregate API latency')
        report['scenarios']['correct_click_and_timeline']={'pending':pending,'finished':hit}
        report['checks'].append('Only correct observed clicks paint black/white; pending fields stay unknown and timeline uses backend offsets')

        # A new standalone request resets the former success before its response.
        await start(cdp,'runTrial',[{'outcome':'move','timing':TIMING}],'Move the pointer to the '+label+' button.',{'target':ids[0],'action':'move'})
        move_pending=await inspect(cdp);assert_overlay(move_pending,[],'new standalone reset')
        move=await release(cdp);assert_overlay(move,[],'correct move')
        check(move['latest']['hit'] is True and move['latest']['execution']['click_count']==0,'Move test did not isolate a correct zero-click action')
        report['scenarios']['move_and_standalone_reset']=move
        for outcome in ['miss','error']:
            await start(cdp,'runTrial',[{'outcome':outcome,'timing':UNKNOWN if outcome=='error' else TIMING}],instruction,{'target':ids[0],'action':'click'})
            finished=await release(cdp);assert_overlay(finished,[],outcome)
            report['scenarios'][outcome]=finished
            if outcome=='error':
                for name in ['request-upload','request-first-reply','request-finished']:
                    check('—' in finished['fields'][name]['text'],name+': missing metric was replaced by a number')
                check(finished['latest']['response']['timing']['status']=='not_started','Error fixture lost unknown timing')
        await start(cdp,'runTrial',[{'timing':TIMING}],'Click a button.',{'target':'none','action':'click'})
        unscored=await release(cdp);assert_overlay(unscored,[],'unscored click')
        check(unscored['latest']['outcome']=='unscored','Unscored fixture unexpectedly scored')
        report['scenarios']['unscored']=unscored
        report['checks'].append('New standalone runs clear successes; correct moves, misses, errors, and unscored clicks never success-paint')

        # Final-only output is usable evidence, not a fabricated first-token timestamp.
        await start(cdp,'runTrial',[{'timing':FINAL_ONLY}],instruction,{'target':ids[0],'action':'click'})
        final_only=await release(cdp);assert_overlay(final_only,[ids[0]],'final-only hit')
        check_offset(final_only['fields']['request-first-reply']['text'],FINAL_ONLY['first_output_ms'],'Final-only first output')
        check('final' in final_only['fields']['request-first-reply']['label'].lower(),'Final-only output is labelled as a streamed first token')
        check(final_only['latest']['response']['timing']['first_token_ms'] is None,'Final-only result invented TTFT')
        report['scenarios']['final_only']=final_only
        report['checks'].append('Final-only output is explicitly labelled and retains null first_token_ms')

        # Click-all keeps prior successes across later failures, while resetting at start.
        count=await start(cdp,'runClickAll',[{'outcome':x,'timing':TIMING} for x in ['hit','miss','hit','error']],instruction,{'target':ids[0],'action':'click'})
        first=await inspect(cdp);assert_overlay(first,[],'new click-all reset')
        steps=[first]
        for n,want in [(1,[ids[0]]),(2,[ids[0]]),(3,[ids[0],ids[2]])]:
            state=await release(cdp,wait_next=count+n+1);assert_overlay(state,want,'click-all step '+str(n));steps.append(state)
        end=await release(cdp);assert_overlay(end,[ids[0],ids[2]],'click-all finished');steps.append(end)
        check('ended' in end['fields']['request-finished']['label'].lower(),'Failed provider request incorrectly labelled finished')
        check_offset(end['fields']['request-finished']['text'],TIMING['finish_ms'],'Failure completion offset')
        report['scenarios']['click_all']=steps
        report['checks'].append('Click-all starts clean and preserves earlier correct-click feedback through later misses/errors')

        # All-model comparison is another top-level reset boundary, not a new image.
        count=await start(cdp,'runBatch',[{'outcome':x,'timing':TIMING} for x in ['hit','move','error']],instruction,{'target':ids[0],'action':'click'})
        reset=await inspect(cdp);assert_overlay(reset,[],'new all-model batch reset')
        steps=[reset]
        for n in [1,2]:
            state=await release(cdp,wait_next=count+n+1);assert_overlay(state,[ids[0]],'all-model batch step '+str(n));steps.append(state)
        end=await release(cdp);assert_overlay(end,[ids[0]],'all-model batch complete');steps.append(end)
        report['scenarios']['all_models']=steps
        report['checks'].append('All-model comparison resets at start and uses the same clean captured PNG')

        # Layout refresh resets success paint; manual clicks must not mark model success.
        await cdp.evaluate('ClickLab.setLayout({seed:7441,width:1280,height:480,count:4})')
        reset=await inspect(cdp);assert_overlay(reset,[],'layout reset')
        await base.click(cdp,'[data-target="'+ids[0]+'"]')
        manual=await inspect(cdp);assert_overlay(manual,[],'manual click')
        report['scenarios']['layout_and_manual']={'reset':reset,'manual':manual}
        report['checks'].append('Layout refresh resets paint and manual clicks cannot claim model success')

        # Finish with an illustrative completed result and capture only the isolated browser.
        await start(cdp,'runTrial',[{'timing':TIMING}],instruction,{'target':ids[0],'action':'click'})
        finish=await release(cdp);assert_overlay(finish,[ids[0]],'final illustrative result')
        await cdp.evaluate("document.getElementById('request-timeline').scrollIntoView({block:'center'})")
        shot=await cdp.command('Page.captureScreenshot',{'format':'png','captureBeyondViewport':False})
        (output/'click-feedback-timeline-ui.png').write_bytes(base64.b64decode(shot['data']))
        report['screenshots'].append('click-feedback-timeline-ui.png')
        requests=await cdp.evaluate('__feedback.requests')
        check(len(requests)==14,'Unexpected mocked request count: '+str(len(requests)))
        check(all(r['clean_png'] for r in requests),'One model request included local completion paint')
        check(len({r['request_id'] for r in requests})==len(requests),'Request IDs repeated')
        final=await cdp.evaluate('({errors:__speedQA.errors,blocked:__speedQA.blocked,privacy:__speedQA.assertPrivacy()})')
        check(not final['errors'] and not final['blocked'] and all(final['privacy'].values()),'Final isolation/privacy check failed')
        report['requests']=requests;report['final']=final
        report['checks'].append('Every screenshot matches its clean baseline; no external calls, browser errors, or credential leakage')
    report['passed']=True
    path=output/'click-feedback-timing-validation.json';path.write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps({'passed':True,'checks':len(report['checks']),'mocked_trials':len(report['requests']),'report':str(path),'screenshots':report['screenshots']},indent=2))
    return report


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--url',default='http://127.0.0.1:38631')
    parser.add_argument('--output',default='qa/out/click_feedback_ui')
    asyncio.run(run(parser.parse_args()))


if __name__=='__main__':
    main()
