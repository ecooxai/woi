#!/usr/bin/env python3
"""Verify and publish click-all integration evidence. Makes no API calls."""
from __future__ import annotations

import argparse
import base64
import hashlib
import json
from pathlib import Path
import shutil
import statistics
from datetime import datetime

HERE=Path(__file__).resolve().parent
REPO=HERE.parents[2]


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def close(a,b,tolerance=1e-6):
    assert abs(a-b)<=tolerance,(a,b)


def publish(raw,output):
    def read(name):return json.loads((raw/name).read_text())
    run=read('live_run.json');trials=read('live_trials.json');events=read('live_events.json');manifest=read('live_manifest.json');exported=read('live_window_export.json')
    qa=read('independent_qa/independent-click-all-qa.json');cap=read('independent_qa/event-cap-regression.json')
    assert qa['all_passed'] and cap['all_passed'] and qa['model_api_calls']==cap['model_api_calls']==0
    assert run['status']=='completed' and run['model']=='gpt-6-luna'
    assert run['planned_buttons']==run['completed_attempts']==len(trials)==len(run['trials'])==12
    assert len({t['request_id'] for t in trials})==len(trials)
    assert run['ordered_target_ids']==[t['expected_target']['id'] for t in trials]
    assert run['ordered_target_labels']==[t['expected_target']['label'] for t in trials]
    input_hash=sha(raw/'live_input.png');assert manifest['input_sha256']==input_hash
    sample=[];sanitized=[]
    for i,t in enumerate(trials):
        r=t['response'];s=t['snapshot'];target=t['expected_target'];summary=run['trials'][i]
        assert t['model']==r['model']==r['resolved_model']==run['model']
        assert r['request_id']==t['request_id']==summary['request_id']
        assert r['fresh_context'] and r['protocol']=='screenshot-only-v2' and r['image_detail']=='original'
        assert r['image_sha256']==input_hash and not r.get('error')
        assert t['instruction']=='Click the '+target['label']+' button.'
        assert t['prediction']['action']=='click' and t['expected_action']=='click'
        assert target['x']<=t['prediction']['x']<target['x']+target['w'] and target['y']<=t['prediction']['y']<target['y']+target['h']
        assert s['revision']==manifest['layout']['revision'] and s['seed']==manifest['layout']['seed']
        assert (s['width'],s['height'])==(manifest['layout']['width'],manifest['layout']['height'])
        captured=exported['captures'][t['capture_id']]['screenshot']
        assert hashlib.sha256(base64.b64decode(captured.split(',',1)[1])).hexdigest()==input_hash
        execution=t['execution'];assert execution['click_count']==1 and execution['target_id']==target['id']
        assert [e['type'] for e in execution['events']]==['pointermove','mousedown','mouseup','click']
        assert all(e['request_id']==t['request_id'] and e['target_id']==target['id'] for e in execution['events'])
        external=next(e for e in events if e['request_id']==t['request_id']);assert external['events']==execution['events']
        click=next(e for e in execution['events'] if e['type']=='click')
        assert t['request_sent_perf_ms']<=click['performance_ms']<=t['click_dispatched_perf_ms']
        close(t['send_to_click_ms'],t['click_dispatched_perf_ms']-t['request_sent_perf_ms'])
        close(t['send_to_click_ms'],summary['send_to_click_ms'])
        for iso,perf in [('request_sent_at','request_sent_perf_ms'),('click_dispatched_at','click_dispatched_perf_ms')]:
            timestamp=datetime.fromisoformat(t[iso].replace('Z','+00:00')).timestamp()*1000
            close(timestamp,t['timing_clock_origin_ms']+t[perf],1.1)
        assert t['hit'] and t['outcome']=='hit' and t['persisted'] and summary['category']=='hit'
        sample.append(t['send_to_click_ms'])
        keep=('request_id','model','instruction','capture_id','expected_target','expected_action','prediction','outcome','hit','coordinate_hit','action_match','api_latency_ms','response_wall_ms','request_sent_perf_ms','click_dispatched_perf_ms','timing_clock_origin_ms','request_sent_at','click_dispatched_at','send_to_click_ms','execution','persisted')
        item={k:t[k] for k in keep};item['response']={k:r.get(k) for k in ('resolved_model','protocol','image_detail','image_detail_policy','fresh_context','image_sha256','prompt_sha256','endpoint','error','error_code')};sanitized.append(item)
    assert run['successful_clicks']==sum(t['hit'] for t in trials)==12 and run['accuracy']==1
    assert all(run[k]==0 for k in ('failed_attempts','missed_clicks','invalid_actions','request_errors','local_errors','latency_excluded_attempts'))
    assert run['latency_sample_count']==len(sample) and run['summary_persisted']
    close(run['mean_send_to_click_ms'],statistics.mean(sample));close(run['min_send_to_click_ms'],min(sample));close(run['max_send_to_click_ms'],max(sample))
    close(run['elapsed_ms'],run['total_wall_ms'])
    iso_total=(datetime.fromisoformat(run['finished_at'].replace('Z','+00:00'))-datetime.fromisoformat(run['started_at'].replace('Z','+00:00'))).total_seconds()*1000
    close(iso_total,run['total_wall_ms'],1.1)
    assert run['total_wall_ms']>=sum(sample)
    event_count=manifest['initial_event_count']+sum(len(t['execution']['events']) for t in trials)
    assert event_count<5000
    assert cap['app_js_sha256']==sha(HERE/'app.js'),'Event-cap regression did not exercise final app.js'
    raw_files=('live_run.json','live_trials.json','live_events.json','live_manifest.json','live_input.png','live_window_export.json','independent_qa/independent-click-all-qa.json','independent_qa/event-cap-regression.json')
    report={'schema_version':1,'all_independent_checks_passed':True,'formal_model_comparison_trials':432,'separate_live_integration_trials':12,'integration_model':run['model'],'input_sha256':input_hash,
            'raw_evidence_sha256':{n:sha(raw/n) for n in raw_files},'source_js_sha256_at_live_run':manifest['source_js_sha256'],'source_js_sha256_after_event_buffer_fix':cap['app_js_sha256'],
            'event_history_count_at_start':manifest['initial_event_count'],'recorded_integration_event_count':event_count-manifest['initial_event_count'],'below_history_cap':True,
            'timing_scope':'Browser monotonic request-send through executed local click, distinct from API duration in the formal model comparison. Includes actual wrong-target clicks when present; no-click attempts have no sample.',
            'execution_scope':'App dispatches synthetic browser DOM events inside the lab; not OS pointer input. Formal model comparisons separately used trusted CDP input.',
            'run':run,'trials':sanitized,'independent_mock_scenarios':len(qa['scenarios']),'independent_mock_requests':qa['mocked_trial_requests'],'event_cap_mock_requests':cap['mocked_trial_requests']}
    output.mkdir(parents=True,exist_ok=True)
    (output/'click-all-live-integration.json').write_text(json.dumps(report,indent=2)+'\n')
    shutil.copyfile(raw/'independent_qa/event-cap-regression.json',output/'click-all-event-cap-regression.json')
    shutil.copyfile(raw/'live_input.png',output/'click-all-live-input.png')
    shutil.copyfile(raw/'live_result_window.png',output/'click-all-live-result.png')
    def seconds(value):return f'{value/1000:.3f} s'
    lines=['# Click all buttons: workflow validation','',
      'This is a separate integration check of the selected-model batch workflow. Its 12 live requests are **not pooled** into the 432 formal model-comparison trials in [RESULTS.md](RESULTS.md). The table below measures browser request-send-to-executed-click time; the formal comparison tables measure backend API duration.','',
      '## Live selected-model run','',
      '| Measure | Observed result |','|---|---:|',
      f"| Model | `{run['model']}` |",f"| Successful / completed | {run['successful_clicks']} / {run['completed_attempts']} (100%) |",f"| Completed / planned | {run['completed_attempts']} / {run['planned_buttons']} |",f"| Total run wall time | {seconds(run['total_wall_ms'])} |",f"| Average send → executed click | {seconds(run['mean_send_to_click_ms'])} |",f"| Minimum send → executed click | {seconds(run['min_send_to_click_ms'])} |",f"| Maximum send → executed click | {seconds(run['max_send_to_click_ms'])} |",f"| Timing samples | {run['latency_sample_count']} |",'| API, invalid-action, and local errors | 0 |','',
      f"The run used one stable {manifest['layout']['width']} × {manifest['layout']['height']} screenshot, seed {manifest['layout']['seed']}, and `original` image detail. All 12 request IDs were unique; each response reported the requested model and fresh-context protocol. All stored captures and returned input hashes match the exact PNG saved as `click-all-live-input.png`. Every target had one executed click and recorded matching target events. The run summary and all trial records were persisted.",'',
      'The independent publication check recomputed mean/min/max from per-trial monotonic timestamps, matched them to recorded click events, checked ISO timestamps, verified target bounds and provider/model IDs, and recomputed screenshot and raw-evidence hashes. The app dispatches browser DOM events within its controlled surface; these UI integration events are synthetic. The separate formal benchmark used trusted Chromium CDP input.','',
      '## Controlled failure and timing checks','',
      'Four independent browser scenarios used 12 mocked API responses, with zero model calls and zero external result writes. An independent DOM listener measured the actual local clicks. Deliberately false provider latency values could not affect the displayed send-to-click measurements. Controlled capture and persistence delays verified the timer boundaries.','',
      '| Scenario | Score | Progress | Timing samples | Outcome |','|---|---:|---:|---:|---|']
    labels={'mixed-six':'Mixed hit, miss, API error, move, out-of-bounds, mismatched response','stop-during-first-request':'Stop during first request','capture-failure-after-one-dpr2':'Capture failure after one hit at DPR 2','no-click-samples':'All requests fail'}
    for row in qa['scenarios']:
        s=row['summary'];lines.append(f"| {labels[row['name']]} | {s['successful_clicks']}/{s['completed_attempts']} | {s['completed_attempts']}/{s['planned_buttons']} | {s['latency_sample_count']} | {s['status']} |")
    lines.extend(['','The mixed run included the wrong-target click in timing statistics and excluded the four attempts without a click. Stop was activated using trusted CDP input while the first request was in flight. Unattempted buttons were excluded from accuracy. Layout/model controls stayed locked; overlapping requests were rejected; all requests contained only current instruction, screenshot, resolution, model and request ID. Marker-free screenshots remained byte-identical. Schema-2 export/restore preserved the run and timestamps.','',
      '## Long-session event-history regression','',
      'Review found that slicing the capped 5,000-event global history could lose current-dispatch evidence after the cap was reached. The frontend now collects a separate buffer for each dispatch while retaining the capped history for inspection. A focused two-response mock regression filled the history to its cap, then performed an exact-center click and pointer move. Both were hits; the click retained four events and a measured timing sample, and the move retained one pointer event with zero clicks and no click-time sample. The history stayed at 5,000 throughout.','',
      f"The live run began with {manifest['initial_event_count']} recorded events and added {event_count-manifest['initial_event_count']}, so it was below the cap and unaffected by that defect. Its captured source hash and the fixed source hash are recorded separately; the paid run was not repeated.",'',
      '## Timing and score definitions','',
      '- Accuracy is successful clicks divided by completed attempts. Progress is completed attempts divided by planned buttons.',
      '- Each click timer starts immediately before the request is sent and ends after the observed local click dispatch. Executed misses count as samples. API errors and other attempts without a click have no timing sample.',
      '- Total wall time includes captures, all request waits, gaps and per-trial persistence. Final summary persistence occurs after that timer ends.',
      '- Average, minimum and maximum show the sample count; when there are no clicks, those values are absent rather than zero.','',
      '## Evidence','',
      '- [click-all-live-integration.json](click-all-live-integration.json): independently verified live summary, sanitized trials, click events and provenance hashes.',
      '- [click-all-independent-qa.json](click-all-independent-qa.json): controlled mixed/error/stop/partial-run evidence and independent event timestamps.',
      '- [click-all-event-cap-regression.json](click-all-event-cap-regression.json): focused post-fix click/move evidence at the full history cap.',
      '- [click-all-live-input.png](click-all-live-input.png) and [click-all-live-result.png](click-all-live-result.png): source screenshot and completed visible run.',
      '- Regenerate the live audit with `report_click_all.py`; no model calls are made. Raw exports remain under `qa/out/click_lab/click_all/`.',''])
    (output/'CLICK_ALL_VALIDATION.md').write_text('\n'.join(lines))
    print(json.dumps({'all_independent_checks_passed':True,'live_hits':12,'live_attempts':12,'event_history_total':event_count,'total_wall_ms':run['total_wall_ms'],'mean_send_to_click_ms':run['mean_send_to_click_ms'],'min_send_to_click_ms':run['min_send_to_click_ms'],'max_send_to_click_ms':run['max_send_to_click_ms'],'report':str(output/'CLICK_ALL_VALIDATION.md')},indent=2))


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--raw',type=Path,default=REPO/'qa/out/click_lab/click_all')
    parser.add_argument('--out',type=Path,default=HERE/'results/20261107')
    args=parser.parse_args();publish(args.raw,args.out)
