(() => {
  'use strict';
  const $ = id => document.getElementById(id);
  const canvas = $('board'), ctx = canvas.getContext('2d');
  const marker = $('markers'), mark = marker.getContext('2d');
  const feedback = $('successes'), success = feedback.getContext('2d');
  const words = ['Amber','Birch','Cobalt','Delta','Echo','Fern','Garnet','Harbor','Indigo','Jade','Kite','Lemon','Maple','Nova','Opal','Pearl','Quartz','Reed','Silver','Teal','Umber','Violet','Willow','Zinc','Aspen','Brook','Cedar','Dune','Ember','Flint','Grove','Hazel','Iris','Juniper','Lotus','Moss','Olive','Pine','Robin','Sage'];
  const paints = [
    ['#eaf2ff','#bdd3f2','#2b5e9a'],['#ebf6f0','#b7d9c9','#34735b'],
    ['#f4edff','#d9c5ee','#78539e'],['#fff2e5','#edcfb0','#9b682e'],
    ['#e8f5f8','#b8dce4','#347c8d'],['#fff0f2','#e9c4cd','#a85d71'],
    ['#326fbd','#326fbd','#ffffff'],['#f0f2f6','#cfd6e0','#586779']
  ];
  const state = {seed:0,width:1280,height:480,count:12,revision:0,targets:[],models:[],selectedModel:null,
    inFlight:false,batching:false,stop:false,results:[],events:[],lastRequest:null,lastSnapshot:null,
    dispatch:null,modelSource:'',suggestedAction:'click',catalog:null,batchKind:null,batchToken:null,buttonRuns:[],activeButtonRun:null,runTimer:null,speedTier:'normal',connectionInfo:null,authMode:'codex',connectionRevision:null,switching:false,loadingModels:false,completedTargetIds:new Set(),requestTimeline:null};
  const copy = v => JSON.parse(JSON.stringify(v));
  const tierLabels={normal:'Normal',fast:'Fast',ultrafast:'Ultrafast',flex:'Flex'};
  function backendLabel(mode){return mode==='codex'?'Codex login':mode==='api'?'API key':'Connection not recorded';}
  function tierLabel(value){return tierLabels[value]||'Tier not recorded';}
  function safeConnection(value){
    const raw=value?.connection||value||{},auth=raw.auth||{},mode=raw.auth_mode||raw.mode||auth.mode||state.authMode;
    return {auth_mode:['codex','api'].includes(mode)?mode:state.authMode,
      configured:raw.configured??raw.ready??auth.configured??null,source:raw.source||auth.source||'',
      error:typeof raw.error==='string'?raw.error:raw.error?.message||raw.reason||auth.reason||null,error_code:raw.error_code||null,
      revision:raw.connection_revision??raw.revision??null,session_key:raw.session_key===true,
      api_key_configured:raw.api_key_configured??raw.api?.configured??null,
      api_key_source:raw.api_key_source||raw.api?.source||'',
      speed_tiers:Array.isArray(raw.speed_tiers)?copy(raw.speed_tiers):null};
  }
  function adoptConnection(value){
    state.connectionInfo=safeConnection(value);state.authMode=state.connectionInfo.auth_mode;state.connectionRevision=state.connectionInfo.revision;
    renderConfiguration();return copy(state.connectionInfo);
  }
  function selectedSettings(){return {auth_mode:state.authMode,speed_tier:state.speedTier,connection_revision:state.connectionRevision};}
  function renderConfiguration(){
    for(const input of document.querySelectorAll('input[name=auth-mode]'))input.checked=input.value===state.authMode;
    for(const input of document.querySelectorAll('input[name=speed-tier]'))input.checked=input.value===state.speedTier;
    $('api-key-panel').hidden=state.authMode!=='api';$('clear-api-key').hidden=!state.connectionInfo?.session_key;$('speed-selection').textContent=tierLabel(state.speedTier);
    const info=state.connectionInfo,configured=info?.configured;
    $('connection-status').className=`configuration-note${configured===false?' error':''}`;
    $('connection-status').textContent=state.switching?'Updating connection…':info?.error||
      (configured===false?(state.authMode==='api'?'Enter an API key below, or configure one in Woi.':'No usable Codex login was found. Sign in to Codex, then refresh.'):
      `${backendLabel(state.authMode)}${configured===true?' ready':''}${info?.source?` · ${info.source}`:''}`);
    const model=state.models.find(m=>m.id===state.selectedModel),audio=model&&modelKind(model)==='audio';
    let note=state.speedTier==='normal'?'Standard processing. The provider-reported tier is saved with the result.':
      state.speedTier==='fast'?'Requests Priority processing. Availability depends on the model and account.':
      state.speedTier==='ultrafast'?'Requests Ultrafast processing. Supported models and account access are required.':
      state.authMode==='codex'?'Flex is experimental with Codex login. You can try it; any rejection stays in the result.':
      'Requests Flex processing. It can take longer; availability depends on the model and account.';
    if(audio&&state.speedTier!=='normal')note='Realtime does not expose a speed tier. You can select this to record an explicit unsupported result; choose a text model to test tier processing.';
    $('speed-tier-note').textContent=note;
  }
  function setSpeedTier(value){
    if(state.inFlight||state.batching||state.switching)throw new Error('The test configuration is frozen while a run or connection update is active.');
    if(!Object.hasOwn(tierLabels,value))throw new Error('Choose Normal, Fast, Ultrafast, or Flex.');
    state.speedTier=value;renderConfiguration();return value;
  }
  async function refreshConnection(){
    if(state.inFlight||state.batching)throw new Error('The connection is frozen while a test is running.');
    try{
      const response=await fetch('/api/connection',{cache:'no-store'}),data=await response.json();
      if(!response.ok&&response.status===404)return null;
      if(!response.ok&&!data.auth_mode&&!data.mode&&!data.connection)throw new Error(typeof data.error==='string'?data.error:`HTTP ${response.status}`);
      return adoptConnection(data);
    }catch(error){$('connection-status').textContent=`Connection status unavailable: ${error.message}`;return null;}
  }
  async function changeConnection(mode,apiKey){
    if(state.inFlight||state.batching||state.switching)throw new Error('The connection is frozen while a test is running.');
    if(!['codex','api'].includes(mode))throw new Error('Choose Codex login or API key.');
    state.switching=true;lockControls();renderConfiguration();
    const body={auth_mode:mode};if(typeof apiKey==='string')body.api_key=apiKey.trim();
    try{
      const response=await fetch('/api/connection',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(body),cache:'no-store'});
      const data=await response.json();
      if(!response.ok)throw new Error(typeof data.error==='string'?data.error:data.error?.message||`HTTP ${response.status}`);
      adoptConnection(data);state.models=[];state.selectedModel=null;renderModels();
      await refreshModels(true);return copy(state.connectionInfo);
    }catch(error){
      await refreshConnection();setStatus(`Connection update failed: ${error.message}`,'error');throw error;
    }finally{
      $('api-key').value='';delete body.api_key;state.switching=false;renderConfiguration();lockControls();
    }
  }
  function resultTier(result){return result.speed_tier??result.response?.speed_tier??result.run?.speed_tier??null;}
  function resultBackend(result){return result.auth_mode??result.response?.auth_mode??result.run?.auth_mode??'unknown';}
  function tierEvidence(result){
    const response=result.response||{},requested=result.requested_service_tier??response.requested_service_tier??null;
    const actual=result.actual_service_tier??response.actual_service_tier??null;
    return {requested,actual,status:result.tier_status||response.tier_status||(actual?(requested===actual?'confirmed':'reported'):'not_reported'),
      note:result.tier_note||response.tier_note||null};
  }
  function measuredNumber(value){return typeof value==='number'&&Number.isFinite(value)&&value>=0?value:null;}
  function pngBytes(dataUrl){
    if(typeof dataUrl!=='string'||!dataUrl.startsWith('data:image/png;base64,'))return null;
    const encoded=dataUrl.slice(dataUrl.indexOf(',')+1);return Math.floor(encoded.length*3/4)-(encoded.endsWith('==')?2:encoded.endsWith('=')?1:0);
  }
  function formatMegabytes(bytes){
    if(measuredNumber(bytes)===null)return '—';
    const mb=bytes/1000000;return mb.toFixed(bytes>0&&bytes<1000?6:bytes<1000000?3:2)+' MB';
  }
  function formatOffset(value){return measuredNumber(value)===null?'—':'+'+(value/1000).toFixed(value<1000?3:2)+' s';}
  function requestMeasurements(result){
    const response=result.response||{},raw=result.timing??response.timing;
    return {request_id:result.request_id||null,model:result.model||null,pending:result.pending===true,failed:!!(result.error||response.error),
      request_image_bytes:measuredNumber(result.request_image_bytes??response.request_image_bytes??response.image_bytes)??pngBytes(result.snapshot?.screenshot),
      request_payload_bytes:measuredNumber(result.request_payload_bytes??response.request_payload_bytes),
      timing:raw&&typeof raw==='object'&&!Array.isArray(raw)?copy(raw):null};
  }
  function timelineParts(data){
    const t=data.timing?.origin==='provider_request_start'?data.timing:{},upload=measuredNumber(t.upload_complete_ms),token=measuredNumber(t.first_token_ms),output=measuredNumber(t.first_output_ms),finish=measuredNumber(t.finish_ms);
    const finalOnly=token===null&&t.first_output_source==='final_only',first=finalOnly?output:token;
    const bytes=data.request_image_bytes,payload=data.request_payload_bytes,exact=bytes===null?'Raw PNG size unavailable.':bytes.toLocaleString('en-US')+' bytes of raw PNG; 1 MB = 1,000,000 bytes.';
    const body=payload===null?' Provider request body size unavailable.':' Provider request body: '+payload.toLocaleString('en-US')+' bytes, including image encoding and text.';
    const bodyDuration=measuredNumber(t.upload_duration_ms)===null?' Body-send duration unavailable.':' Body-send duration: '+(t.upload_duration_ms/1000).toFixed(3)+' s.';
    return [
      {key:'image-size',label:'Image',value:formatMegabytes(bytes),raw:bytes,title:exact+body},
      {key:'upload',label:'Upload',value:formatOffset(upload),raw:upload,title:'Elapsed from provider-request start until the client finished sending the request body; this is not confirmation of provider receipt.'+bodyDuration+(t.upload_measurement?' Measurement: '+t.upload_measurement+'.':'')},
      {key:'first-reply',label:finalOnly?'First output (final only)':'First reply',value:formatOffset(first),raw:first,title:finalOnly?'Elapsed from provider-request start until final-only model output was received. No first-token measurement was available.':'Elapsed from provider-request start to the first nonempty text or tool-argument delta. An unavailable first-token measurement is shown as —.'},
      {key:'finished',label:data.failed||t.status==='error'?'Ended':'Finished',value:formatOffset(finish),raw:finish,title:'Elapsed from provider-request start until the response finished or failed. Local click execution and result logging occur afterward.'}
    ];
  }
  function fillTimeline(container,data,withIds=false){
    container.replaceChildren();
    for(const part of timelineParts(data)){
      const item=textNode('span','','request-measure');item.dataset.measure=part.key;item.title=part.title;
      if(withIds)item.id='request-'+part.key;
      if(part.raw!==null)item.dataset.value=String(part.raw);
      if(part.key==='image-size'&&part.raw!==null)item.dataset.bytes=String(part.raw);
      item.append(textNode('span',part.label+' ','measure-label'),textNode('strong',part.value,'measure-value'));container.append(item);
    }
  }
  function renderRequestTimeline(){
    const data=state.requestTimeline;$('request-timeline').hidden=!data;if(!data)return;
    const status=data.timing?.status;
    $('request-timeline-state').textContent=data.pending?'Request in progress':status==='not_started'?'Not sent to provider':data.failed||status==='error'?'Request failed':'Latest request';
    fillTimeline($('request-timeline-values'),data,true);
    $('request-timeline-note').textContent=data.pending?'Waiting for provider measurements. Image size is the raw PNG.':'Times start at the model request. Upload marks client dispatch; unavailable measurements are —.';
  }
  function timingDescription(result){
    const data=requestMeasurements(result),t=data.timing?.origin==='provider_request_start'?data.timing:{};
    const raw=data.request_image_bytes===null?'not recorded':data.request_image_bytes.toLocaleString('en-US')+' bytes';
    const payload=data.request_payload_bytes===null?'not recorded':data.request_payload_bytes.toLocaleString('en-US')+' bytes';
    const duration=measuredNumber(t.upload_duration_ms)===null?'—':(t.upload_duration_ms/1000).toFixed(3)+' s';
    return 'Raw PNG: '+raw+' · provider request body: '+payload+' · upload complete: '+formatOffset(t.upload_complete_ms)+' · body-send duration: '+duration+' · first token: '+formatOffset(t.first_token_ms)+' · first output: '+formatOffset(t.first_output_ms)+' ('+(t.first_output_source||'not reported')+') · finished / ended: '+formatOffset(t.finish_ms)+' · timing status: '+(t.status||'not reported')+'. All offsets use the provider request clock. Upload measures client dispatch, not provider receipt.'+(t.upload_measurement?' Measurement: '+t.upload_measurement+'.':'')+(t.note?' '+t.note:'');
  }
  const randomSeed = () => crypto.getRandomValues(new Uint32Array(1))[0];
  function rng(seed) {let a = seed >>> 0; return () => {a += 0x6D2B79F5; let t=a;t=Math.imul(t^(t>>>15),t|1);t^=t+Math.imul(t^(t>>>7),t|61);return ((t^(t>>>14))>>>0)/4294967296;};}
  function shuffled(list, r) {const a=[...list];for(let i=a.length-1;i>0;i--){const j=Math.floor(r()*(i+1));[a[i],a[j]]=[a[j],a[i]];}return a;}
  function generateLayout(options={}) {
    const width=Math.round(Number(options.width ?? 1280)),height=Math.round(Number(options.height ?? 480));
    const count=Math.min(40,Math.max(1,Math.round(Number(options.count ?? 12)))),seed=Number(options.seed ?? 1)>>>0;
    if(!Number.isFinite(count))throw new Error('Button count must be a finite number.');
    if(!Number.isFinite(width)||!Number.isFinite(height)||width<320||height<200||width>3840||height>2160)throw new Error('Surface size must be between 320 × 200 and 3840 × 2160.');
    const r=rng(seed),labels=shuffled(words,r).slice(0,count),cols=Math.ceil(Math.sqrt(count*width/height/1.65)),rows=Math.ceil(count/cols);
    const margin=20,cw=(width-margin*2)/cols,ch=(height-margin*2)/rows,targets=[];
    const cells=shuffled(Array.from({length:cols*rows},(_,i)=>i),r);
    for(let i=0;i<count;i++){
      const cell=cells[i],col=cell%cols,row=Math.floor(cell/cols),size=i%3;
      const font=[12,14,16][size],label=labels[i],minW=Math.ceil(label.length*font*.62+22);
      const w=Math.max(36,Math.min(cw-12,Math.max(minW,[72,112,156][size]+Math.round(r()*16))));
      const h=Math.max(18,Math.min(ch-12,[26,38,50][size]));
      const x=Math.round(margin+col*cw+6+r()*Math.max(0,cw-w-12));
      const y=Math.round(margin+row*ch+6+r()*Math.max(0,ch-h-12));
      const paint=paints[Math.floor(r()*paints.length)];
      targets.push({id:`button-${i+1}`,label,x,y,w:Math.round(w),h:Math.round(h),font,size:['small','medium','large'][size],fill:paint[0],border:paint[1],color:paint[2]});
    }
    return {seed,width,height,count,targets};
  }
  function roundRect(c,x,y,w,h,r=7){c.beginPath();c.roundRect(x,y,w,h,Math.min(r,h/3));}
  function resetRunFeedback(){
    state.requestTimeline=null;renderRequestTimeline();
    state.completedTargetIds.clear();success.clearRect(0,0,state.width,state.height);
    for(const button of document.querySelectorAll('.target-hitbox.completed')){button.classList.remove('completed');button.removeAttribute('aria-description');}
  }
  function showSuccessfulClick(result){
    if(result.hit!==true||result.prediction?.action!=='click'||result.execution?.click_count!==1||result.snapshot.revision!==state.revision)return;
    const target=state.targets.find(t=>t.id===result.execution.target_id&&t.id===result.expected_target?.id);if(!target)return;
    state.completedTargetIds.add(target.id);
    success.save();roundRect(success,target.x,target.y,target.w,target.h);success.fillStyle='#000000';success.fill();
    success.textAlign='center';success.textBaseline='middle';success.font='600 '+target.font+'px Arial, sans-serif';success.fillStyle='#ffffff';
    success.fillText(target.label,target.x+target.w/2,target.y+target.h/2+.5,target.w-10);success.restore();
    for(const button of document.querySelectorAll('.target-hitbox'))if(button.dataset.target===target.id){button.classList.add('completed');button.setAttribute('aria-description','Correctly clicked by the model in this run.');}
  }
  function renderBoard(){
    canvas.width=state.width;canvas.height=state.height;marker.width=state.width;marker.height=state.height;feedback.width=state.width;feedback.height=state.height;
    resetRunFeedback();
    $('board-frame').style.setProperty('--board-ratio',String(state.width/state.height));
    ctx.fillStyle='#f6f8fb';ctx.fillRect(0,0,state.width,state.height);
    ctx.textAlign='center';ctx.textBaseline='middle';
    $('hit-layer').replaceChildren();
    for(const t of state.targets){
      ctx.save();ctx.shadowColor='rgba(38,58,86,.055)';ctx.shadowBlur=3;ctx.shadowOffsetY=2;
      roundRect(ctx,t.x,t.y,t.w,t.h);ctx.fillStyle=t.fill;ctx.fill();ctx.restore();
      roundRect(ctx,t.x+.5,t.y+.5,t.w-1,t.h-1);ctx.strokeStyle=t.border;ctx.lineWidth=1;ctx.stroke();
      ctx.font=`600 ${t.font}px Arial, sans-serif`;ctx.fillStyle=t.color;ctx.fillText(t.label,t.x+t.w/2,t.y+t.h/2+.5,t.w-10);
      const b=document.createElement('button');b.type='button';b.className='target-hitbox';b.dataset.target=t.id;b.setAttribute('aria-label',t.label);
      Object.assign(b.style,{left:`${t.x/state.width*100}%`,top:`${t.y/state.height*100}%`,width:`${t.w/state.width*100}%`,height:`${t.h/state.height*100}%`});
      b.addEventListener('click',()=>{$('board-event').textContent=`${state.dispatch?'Model':'You'} clicked ${t.label}.`;});
      $('hit-layer').append(b);
    }
    $('layout-label').textContent=`${state.count} buttons · seed ${state.seed}`;
    $('seed').value=String(state.seed);
    $('capture-meta').textContent=`Capture ${state.width} × ${state.height} px · fitted preview`;
    updateScreenMeta();
    const old=$('expected-target').value;
    $('expected-target').replaceChildren(new Option('Detect from instruction','auto'),new Option('Do not score','none'));
    for(const t of [...state.targets].sort((a,b)=>a.label.localeCompare(b.label)))$('expected-target').add(new Option(t.label,t.id));
    if([...$('expected-target').options].some(x=>x.value===old))$('expected-target').value=old;
    updateScorePreview();
  }
  function updateScreenMeta(){const dpr=devicePixelRatio||1;$('screen-meta').textContent=`Screen ${screen.width} × ${screen.height} CSS px · DPR ${dpr}`;}
  function setLayout(options={}){
    if(state.inFlight||state.batching)throw new Error('The layout is frozen until the current test finishes.');
    const layout=generateLayout({seed:options.seed??randomSeed(),width:options.width??state.width,height:options.height??state.height,count:options.count??state.count});
    Object.assign(state,layout);state.revision++;
    const size=`${state.width}x${state.height}`;
    if(![...$('resolution').options].some(o=>o.value===size))$('resolution').add(new Option(`${state.width} × ${state.height}`,size));
    $('resolution').value=size;
    if(![...$('button-count').options].some(o=>Number(o.value)===state.count))$('button-count').add(new Option(String(state.count),String(state.count)));
    $('button-count').value=String(state.count);renderBoard();
    $('board-event').textContent='Click a button yourself to check the surface.';
    return getLayout();
  }
  function getLayout(){return copy({seed:state.seed,width:state.width,height:state.height,count:state.count,revision:state.revision,targets:state.targets});}
  function captureSnapshot(){
    return {id:`capture-${Date.now()}-${crypto.getRandomValues(new Uint32Array(1))[0].toString(16)}`,captured_at:new Date().toISOString(),
      screenshot:canvas.toDataURL('image/png'),width:state.width,height:state.height,seed:state.seed,revision:state.revision,targets:copy(state.targets),
      screen:{width:screen.width,height:screen.height,devicePixelRatio:devicePixelRatio||1},
      viewport:{width:innerWidth,height:innerHeight}};
  }
  function capture(){const s=captureSnapshot();return {screenshot:s.screenshot,width:s.width,height:s.height,screen:s.screen,revision:s.revision};}
  function expectedFor(instruction,options={}){
    const targetSetting=options.expectedTargetId??$('expected-target').value;
    let target=null;
    if(targetSetting!=='none'){
      if(targetSetting==='auto'){
        const tokens=String(instruction).toLowerCase().match(/[a-z]+/g)||[];
        const matches=state.targets.filter(t=>tokens.includes(t.label.toLowerCase()));
        if(matches.length===1)target=matches[0];
      }else target=state.targets.find(t=>t.id===targetSetting||t.label===targetSetting)||null;
    }
    const actionSetting=options.expectedAction??$('expected-action').value;
    let action=actionSetting==='auto'?null:actionSetting;
    if(actionSetting==='auto'){
      if(/\b(move|hover|point)\b/i.test(instruction))action='move';
      else if(/\b(click|tap|press)\b/i.test(instruction))action='click';
    }
    return {target:target?copy(target):null,action};
  }
  function updateScorePreview(){
    const e=expectedFor($('instruction').value);
    if(e.action){state.suggestedAction=e.action;$('suggest-click').classList.toggle('active',e.action==='click');$('suggest-move').classList.toggle('active',e.action==='move');}
    $('score-preview').textContent=e.target?`Scoring: ${e.action||'location'} on ${e.target.label}. The expected region is kept local.`:'No unique expected button found. This trial will be unscored unless you select one above.';
  }
  function suggest(action=state.suggestedAction,target){
    state.suggestedAction=action;
    $('suggest-click').classList.toggle('active',action==='click');$('suggest-move').classList.toggle('active',action==='move');
    const t=target||expectedFor($('instruction').value).target||state.targets[Math.floor(Math.random()*state.targets.length)];
    if(t)$('instruction').value=action==='move'?`Move the pointer to the ${t.label} button. Do not click.`:`Click the ${t.label} button.`;
    $('expected-target').value='auto';$('expected-action').value='auto';updateScorePreview();
  }
  function recordEvent(event){
    const rect=canvas.getBoundingClientRect(),target=event.target.closest?.('[data-target]');
    const entry={type:event.type,source:state.dispatch?'model':'manual',request_id:state.dispatch?.requestId||null,
      x:(event.clientX-rect.left)/rect.width*state.width,y:(event.clientY-rect.top)/rect.height*state.height,
      target_id:target?.dataset.target||null,at:Date.now(),performance_ms:performance.now(),event_timestamp_ms:event.timeStamp,button:event.button??null,isTrusted:event.isTrusted};
    if(event.type==='pointermove'&&!state.dispatch){const last=state.events.at(-1);if(last&&last.type==='pointermove'&&entry.at-last.at<60)return;}
    if(state.dispatch)state.dispatch.events.push(entry);
    state.events.push(entry);if(state.events.length>5000)state.events.splice(0,state.events.length-5000);
  }
  for(const type of ['pointermove','mousedown','mouseup','click'])$('board-frame').addEventListener(type,recordEvent);
  function drawResult(point,expected,result){
    mark.clearRect(0,0,state.width,state.height);
    if(expected){mark.save();mark.setLineDash([5,4]);mark.strokeStyle=result==='hit'?'#4c9e76':'#d29b5b';mark.lineWidth=2;roundRect(mark,expected.x-4,expected.y-4,expected.w+8,expected.h+8,10);mark.stroke();mark.restore();}
    if(point&&point.x>=0&&point.x<state.width&&point.y>=0&&point.y<state.height){
      const size=Math.max(18,state.width/70);mark.save();mark.translate(point.x,point.y);mark.scale(size/22,size/22);
      mark.shadowColor='#31496333';mark.shadowBlur=4;mark.beginPath();mark.moveTo(0,0);mark.lineTo(0,22);mark.lineTo(6,16);mark.lineTo(10,24);mark.lineTo(14,22);mark.lineTo(10,14);mark.lineTo(19,14);mark.closePath();
      mark.fillStyle=point.action==='click'?'#357fd0':'#8ac4fa';mark.strokeStyle='#ffffff';mark.lineWidth=1.4;mark.fill();mark.stroke();mark.restore();
    }
  }
  function normalizePrediction(response){
    const r=response.result||response,call=r.arguments||r.point||r;
    let action=r.action||r.tool||r.name||call.action;
    if(['click_screen','mouse_click','click'].includes(action))action='click';
    if(['move_pointer','move_mouse','pointer_move','move','hover'].includes(action))action='move';
    const x=call.x??r.x,y=call.y??r.y;
    const err=r.error||response.error;
    if(err||r.ok===false||response.ok===false)return {error:typeof err==='string'?err:err?.message||JSON.stringify(err||r.message||'Request failed')};
    if(!['click','move'].includes(action))return {error:'The model did not return a valid click or move action.'};
    if(typeof x!=='number'||typeof y!=='number'||!Number.isFinite(x)||!Number.isFinite(y))return {error:'The model did not return finite screenshot-pixel coordinates.'};
    return {action,x,y};
  }
  function executePrediction(prediction,snapshot,requestId='local-check'){
    if(snapshot.revision!==state.revision||snapshot.width!==state.width||snapshot.height!==state.height)return {stale:true,events:[],error:'The surface changed after capture; no action was executed.'};
    const {x,y,action}=prediction;
    if(x<0||y<0||x>=snapshot.width||y>=snapshot.height)return {out_of_bounds:true,events:[],target_id:null,click_count:0,error:'The returned point is outside the captured image.'};
    $('board-frame').scrollIntoView({block:'nearest',inline:'nearest',behavior:'instant'});
    const r=canvas.getBoundingClientRect(),clientX=r.left+x/snapshot.width*r.width,clientY=r.top+y/snapshot.height*r.height;
    const element=document.elementFromPoint(clientX,clientY);
    if(!element||!$('board-frame').contains(element))return {events:[],error:'The test surface is not visible at the returned point; no action was executed.',execution_error:true};
    const dispatchEvents=[];let clickDispatchedPerf=null;state.dispatch={requestId,events:dispatchEvents};
    try{
      element.dispatchEvent(new PointerEvent('pointermove',{bubbles:true,clientX,clientY,pointerId:1,pointerType:'mouse',isPrimary:true}));
      if(action==='click')for(const type of ['mousedown','mouseup','click']){
        element.dispatchEvent(new MouseEvent(type,{bubbles:true,cancelable:true,clientX,clientY,button:0,buttons:type==='mousedown'?1:0}));
        if(type==='click')clickDispatchedPerf=performance.now();
      }
    }finally{state.dispatch=null;}
    const events=dispatchEvents,clicks=events.filter(e=>e.type==='click');
    const executed=events.find(e=>e.type===(action==='click'?'click':'pointermove'));
    if(action==='move')$('board-event').textContent=`Model moved to ${state.targets.find(t=>t.id===executed?.target_id)?.label||'empty space'} · no click.`;
    else if(!executed?.target_id)$('board-event').textContent='Model clicked empty space.';
    return {events,target_id:executed?.target_id||null,click_count:clicks.length,executed:true,
      click_dispatched_perf_ms:clicks.length?clickDispatchedPerf:null,
      click_dispatched_at:clicks.length&&clickDispatchedPerf!==null?new Date(performance.timeOrigin+clickDispatchedPerf).toISOString():null};
  }
  function setStatus(message,kind=''){$('run-status').textContent=message;$('run-status').className=`run-status ${kind}`;}
  function lockControls(){
    const locked=state.inFlight||state.batching||state.switching||state.loadingModels;
    for(const id of ['resolution','button-count','randomize','instruction','suggest-click','suggest-move','another-target','expected-target','expected-action','seed','apply-seed','refresh-models','api-key','save-api-key','clear-api-key'])$(id).disabled=locked;
    for(const el of document.querySelectorAll('input[name=model]'))el.disabled=locked||el.dataset.available==='false';
    for(const el of document.querySelectorAll('input[name=auth-mode],input[name=speed-tier]'))el.disabled=locked;
    for(const el of document.querySelectorAll('.view-capture'))el.disabled=locked;
    $('clear').disabled=locked||(state.results.length===0&&state.buttonRuns.length===0);
    const authUnavailable=state.connectionInfo?.configured===false||state.catalog?.auth?.configured===false;
    $('send').disabled=locked||authUnavailable||!state.selectedModel;
    $('click-all').disabled=locked||authUnavailable||!state.selectedModel||state.targets.length===0;
    $('batch').disabled=locked||authUnavailable||!state.models.some(m=>m.available);
    $('stop').hidden=!state.batching;$('stop').disabled=state.stop;
  }
  async function runTrial(options={}){
    if(state.inFlight)throw new Error('A trial is already running.');
    if(state.switching||state.loadingModels)throw new Error('Wait for the connection and model catalog to finish updating.');
    if(state.connectionInfo?.configured===false||state.catalog?.auth?.configured===false)throw new Error(state.authMode==='api'?'API key required. Enter a key or choose Codex login.':'Codex sign-in required. Sign in to Codex, then refresh.');
    if(state.batching&&options.batchToken!==state.batchToken)throw new Error('A batch is already running.');
    const model=options.model||state.selectedModel,instruction=String(options.instruction??$('instruction').value).trim();
    if(!model)throw new Error('Choose an available model.');if(!instruction)throw new Error('Enter an instruction first.');
    const settings=options.requestSettings?copy(options.requestSettings):selectedSettings();
    if(!Object.hasOwn(tierLabels,settings.speed_tier))throw new Error('Unknown speed tier.');
    if(!state.batching)resetRunFeedback();
    state.inFlight=true;
    try{
      if($('capture-dialog').open)$('capture-dialog').close();lockControls();mark.clearRect(0,0,state.width,state.height);
      const snapshot=captureSnapshot(),expected=expectedFor(instruction,options),requestId=`trial-${Date.now()}-${crypto.getRandomValues(new Uint32Array(1))[0].toString(16)}`;
      const payload={model,instruction,screenshot:snapshot.screenshot,width:snapshot.width,height:snapshot.height,screen:snapshot.screen,request_id:requestId,speed_tier:settings.speed_tier};
      if(settings.connection_revision!==null&&settings.connection_revision!==undefined)payload.connection_revision=settings.connection_revision;
      state.lastRequest=copy(payload);state.lastSnapshot=snapshot;
      const imageBytes=pngBytes(snapshot.screenshot);
      state.requestTimeline=requestMeasurements({request_id:requestId,model,request_image_bytes:imageBytes,pending:true});renderRequestTimeline();
      setStatus(`Testing ${model} · ${backendLabel(settings.auth_mode)} · ${tierLabel(settings.speed_tier)} with a fresh request…`,'busy');let response={};
      const requestOptions={method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(payload),cache:'no-store'};
      let started=null;
      try{
        started=performance.now();
        const http=await fetch('/api/trial',requestOptions);
        const raw=await http.text();try{response=JSON.parse(raw);}catch{throw new Error(`Server returned ${http.status}: ${raw.slice(0,200)||http.statusText}`);}
        if(!response||typeof response!=='object'||Array.isArray(response))throw new Error('The server did not return a JSON response object.');
        if(!http.ok&&!response.error)response.error=response.message||`HTTP ${http.status}`;
        if(!response.error&&(response.request_id!==requestId||(response.model!==undefined&&response.model!==model)||(response.auth_mode!==undefined&&response.auth_mode!==settings.auth_mode)||(response.speed_tier!==undefined&&response.speed_tier!==settings.speed_tier))){
          response={...response,error:'The response does not match this trial; no action was executed.',error_code:'response_mismatch'};
        }
      }catch(error){response={error:error.message,error_code:'request_error'};}
      const elapsed=started===null?null:performance.now()-started,prediction=normalizePrediction(response);
      const apiLatency=typeof response.latency_ms==='number'&&Number.isFinite(response.latency_ms)?response.latency_ms:null;
      const result={request_id:requestId,at:new Date().toISOString(),model,instruction,capture_id:snapshot.id,
        auth_mode:settings.auth_mode,speed_tier:settings.speed_tier,connection_revision:settings.connection_revision,
        requested_service_tier:response.requested_service_tier??null,actual_service_tier:response.actual_service_tier??null,
        tier_status:response.tier_status||'not_reported',tier_note:response.tier_note||null,
        request_image_bytes:imageBytes,request_payload_bytes:measuredNumber(response.request_payload_bytes),timing:response.timing&&typeof response.timing==='object'&&!Array.isArray(response.timing)?copy(response.timing):null,
        snapshot,expected_target:expected.target,expected_action:expected.action,latency_ms:apiLatency,api_latency_ms:apiLatency,wall_ms:elapsed,response_wall_ms:elapsed,
        request_sent_perf_ms:started,request_sent_at:started===null?null:new Date(performance.timeOrigin+started).toISOString(),timing_clock_origin_ms:performance.timeOrigin,
        send_to_click_ms:null,click_dispatched_at:null,click_dispatched_perf_ms:null,run:options.localRun?copy(options.localRun):null,
        usage:response.usage??null,prediction,response,execution:null,outcome:'error',hit:null,coordinate_hit:null,action_match:null,center_error_px:null};
      if(prediction.error){result.error=prediction.error;result.error_code=response.error_code||'invalid_response';}
      else{
        let execution;
        try{execution=executePrediction(prediction,snapshot,requestId);}
        catch(error){execution={events:[],execution_error:true,error:`The local action could not be executed: ${error.message||String(error)}`};}
        result.execution=execution;
        if(started!==null&&execution.click_count>0&&Number.isFinite(execution.click_dispatched_perf_ms)){
          result.send_to_click_ms=execution.click_dispatched_perf_ms-started;result.click_dispatched_at=execution.click_dispatched_at;result.click_dispatched_perf_ms=execution.click_dispatched_perf_ms;
        }
        if(execution.stale){result.outcome='stale';result.error=execution.error;}
        else if(execution.execution_error){result.error=execution.error;result.error_code='execution_error';}
        else if(!expected.target){result.outcome='unscored';result.error=execution.error||null;}
        else{
          const t=expected.target;result.coordinate_hit=prediction.x>=t.x&&prediction.x<t.x+t.w&&prediction.y>=t.y&&prediction.y<t.y+t.h;
          result.action_match=expected.action?prediction.action===expected.action:null;
          result.center_error_px=Math.hypot(prediction.x-t.x-t.w/2,prediction.y-t.y-t.h/2);
          const eventCorrect=execution.target_id===t.id&&((prediction.action==='click'&&execution.click_count===1)||(prediction.action==='move'&&execution.click_count===0));
          result.hit=result.coordinate_hit&&result.action_match!==false&&eventCorrect;result.outcome=result.hit?'hit':'miss';result.error=execution.error||null;
        }
        if(!execution.stale)drawResult(prediction,expected.target,result.outcome);
      }
      state.requestTimeline=requestMeasurements(result);renderRequestTimeline();
      showSuccessfulClick(result);state.results.push(result);renderResults();
      try{
        const saved=await fetch('/api/result',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(copyResult(result)),cache:'no-store',signal:AbortSignal.timeout(10000)});
        result.persisted=saved.ok;if(!saved.ok)result.persistence_error=`Result log returned HTTP ${saved.status}`;
      }catch(error){result.persisted=false;result.persistence_error=error.message;}
      renderResults();
      const message=result.outcome==='hit'?`${model} hit ${expected.target.label}${prediction.action==='move'?' with a pointer move; zero clicks':''}.`:
        result.outcome==='miss'?`${model} missed ${expected.target.label}${result.action_match===false?' (wrong action)':''}.`:
        result.outcome==='unscored'?`${model} returned a point. Select an expected button to score the next trial.`:`${model}: ${result.error}`;
      setStatus(message,result.outcome==='error'?'error':'');return copyResult(result);
    }catch(error){
      setStatus(`The local test could not finish: ${error.message||String(error)}`,'error');throw error;
    }finally{
      state.inFlight=false;state.dispatch=null;lockControls();
    }
  }
  function formatDuration(value){
    if(typeof value!=='number'||!Number.isFinite(value))return '—';
    return value<1000?`${value.toFixed(1)} ms`:`${(value/1000).toFixed(2)} s`;
  }
  function summarizeButtonRun(run){
    const trials=run.trials||[],samples=trials.filter(t=>t.click_count>0&&typeof t.send_to_click_ms==='number'&&Number.isFinite(t.send_to_click_ms)&&t.send_to_click_ms>=0).map(t=>t.send_to_click_ms);
    const hits=trials.filter(t=>t.category==='hit').length,completed=trials.length;
    const elapsed=run.status==='running'?performance.now()-run.started_perf_ms:(run.elapsed_ms??0);
    return {...copy(run),planned_buttons:run.ordered_target_ids.length,completed_attempts:completed,successful_clicks:hits,
      failed_attempts:completed-hits,accuracy:completed?hits/completed:null,
      missed_clicks:trials.filter(t=>t.category==='miss').length,invalid_actions:trials.filter(t=>t.category==='invalid_action').length,
      request_errors:trials.filter(t=>t.category==='request_error').length,local_errors:trials.filter(t=>t.category==='local_error').length,
      latency_sample_count:samples.length,latency_excluded_attempts:completed-samples.length,
      mean_send_to_click_ms:samples.length?samples.reduce((a,b)=>a+b,0)/samples.length:null,
      min_send_to_click_ms:samples.length?Math.min(...samples):null,max_send_to_click_ms:samples.length?Math.max(...samples):null,
      total_wall_ms:Math.max(0,elapsed),timing_definition:'Monotonic time immediately before fetch through completion of an observed local click dispatch. Includes wrong-target clicks; excludes attempts with no click and later result persistence.',
      wall_time_definition:'Run start through completion or stop of the last attempted target, including image capture, all request waits, gaps, and per-trial result persistence. Summary-file persistence happens after the run timer ends.'};
  }
  function renderButtonRun(){
    const run=state.buttonRuns.at(-1);$('button-run').hidden=!run;if(!run)return;
    const r=summarizeButtonRun(run),busy=r.status==='running';
    $('button-run-title').textContent=`Click all buttons · ${r.model}`;
    const tiers=[...new Set((r.trials||[]).map(t=>t.actual_service_tier).filter(Boolean))];
    const config=`${backendLabel(r.auth_mode)} · ${tierLabel(r.speed_tier)} requested · ${tiers.length?tiers.join(', ')+' reported':'provider tier not reported'}`;
    $('button-run-badge').textContent=r.status==='completed'?'Completed':r.status==='stopped'?'Stopped':r.status==='error'?'Error':r.status==='interrupted'?'Interrupted':r.stop_requested?'Stopping':'Running';
    $('button-run-badge').className=`run-badge ${r.status}`;
    $('button-run-status').textContent=busy?(r.stop_requested?'Finishing the current request before stopping.':`Testing ${r.current_target?.label||'the next button'} · request ${Math.min(r.completed_attempts+1,r.planned_buttons)} of ${r.planned_buttons}`):
      `${r.completed_attempts} of ${r.planned_buttons} buttons attempted${r.error?` · ${r.error}`:''}. Layout seed ${r.layout.seed}.`;
    $('button-run-status').textContent+=` · ${config}`;
    $('button-run-progress').max=r.planned_buttons;$('button-run-progress').value=r.completed_attempts;
    $('button-run-score').textContent=`${r.successful_clicks} / ${r.completed_attempts}`;
    $('button-run-completed').textContent=`${r.completed_attempts} / ${r.planned_buttons}`;
    $('button-run-total').textContent=formatDuration(r.total_wall_ms);
    $('button-run-mean').textContent=formatDuration(r.mean_send_to_click_ms);$('button-run-min').textContent=formatDuration(r.min_send_to_click_ms);$('button-run-max').textContent=formatDuration(r.max_send_to_click_ms);
    const parts=[[r.missed_clicks,'missed clicks'],[r.invalid_actions,'invalid / non-click replies'],[r.request_errors,'request errors'],[r.local_errors,'local errors']].filter(([n])=>n>0).map(([n,label])=>`${n} ${label}`);
    $('button-run-failures').textContent=`Failed attempts: ${r.failed_attempts}${parts.length?' · '+parts.join(' · '):''}. Unattempted buttons are excluded from the score.`;
    $('button-run-timing-note').textContent=`Timing samples: ${r.latency_sample_count} executed clicks${r.latency_excluded_attempts?` / ${r.completed_attempts} completed attempts; ${r.latency_excluded_attempts} without a click excluded`:''}. Missed clicks are included. Per-click timing excludes result logging; total wall time includes it.`;
    if(busy&&state.batchKind==='buttons')setStatus(`${r.stop_requested?'Stopping after this request':`Clicking ${r.current_target?.label||'next button'}`} · ${r.completed_attempts}/${r.planned_buttons} complete · ${r.successful_clicks}/${r.completed_attempts} hits · ${formatDuration(r.total_wall_ms)} elapsed`,'busy');
  }
  function clickAttemptCategory(result){
    if(result.hit===true&&result.execution?.click_count>0&&result.prediction?.action==='click')return 'hit';
    if(result.prediction?.action&&result.prediction.action!=='click')return 'invalid_action';
    if(result.execution?.click_count>0)return 'miss';
    if(result.outcome==='stale'||result.execution?.execution_error||['execution_error','capture_error','local_error','response_mismatch'].includes(result.error_code))return 'local_error';
    if(result.execution?.out_of_bounds||/^(invalid_(coordinates|output|action|response|tool)|out_of_bounds|missing_(action|tool)|multiple_|no_(action|tool))/.test(result.error_code||''))return 'invalid_action';
    return 'request_error';
  }
  function clickAttempt(result,target,position){
    return {position,target_id:target.id,target_label:target.label,request_id:result.request_id,category:clickAttemptCategory(result),outcome:result.outcome,
      auth_mode:result.auth_mode,speed_tier:result.speed_tier,requested_service_tier:result.requested_service_tier??null,actual_service_tier:result.actual_service_tier??null,tier_status:result.tier_status||'not_reported',
      hit:result.hit===true,error_code:result.error_code||null,error:result.error||null,returned_action:result.prediction?.action||null,
      returned_x:result.prediction?.x??null,returned_y:result.prediction?.y??null,observed_target_id:result.execution?.target_id||null,
      request_image_bytes:result.request_image_bytes??null,request_payload_bytes:result.request_payload_bytes??null,timing:result.timing?copy(result.timing):null,
      click_count:result.execution?.click_count||0,api_latency_ms:result.api_latency_ms??null,response_wall_ms:result.response_wall_ms??null,
      send_to_click_ms:result.send_to_click_ms??null,request_sent_at:result.request_sent_at||null,click_dispatched_at:result.click_dispatched_at||null,
      request_sent_perf_ms:result.request_sent_perf_ms??null,click_dispatched_perf_ms:result.click_dispatched_perf_ms??null,timing_clock_origin_ms:result.timing_clock_origin_ms??null,
      capture_id:result.capture_id,image_sha256:result.response?.image_sha256||null,events:copy(result.execution?.events||[])};
  }
  async function runClickAll(){
    if(state.inFlight||state.batching)throw new Error('Another test is already running.');
    const model=state.selectedModel,requestSettings=selectedSettings();if(!model)throw new Error('Choose an available model.');
    if(state.switching||state.loadingModels)throw new Error('Wait for the connection update.');
    const layout=getLayout(),targets=copy(layout.targets);if(!targets.length)throw new Error('There are no buttons to test.');
    resetRunFeedback();
    const started=performance.now(),id=`click-all-${Date.now()}-${crypto.getRandomValues(new Uint32Array(1))[0].toString(16)}`;
    const run={id,name:`${model} · ${tierLabel(requestSettings.speed_tier)} · all ${targets.length} buttons · seed ${layout.seed}`,type:'click_all_buttons',model,...requestSettings,status:'running',
      started_at:new Date(performance.timeOrigin+started).toISOString(),started_perf_ms:started,timing_clock_origin_ms:performance.timeOrigin,
      finished_at:null,elapsed_ms:null,layout:{seed:layout.seed,width:layout.width,height:layout.height,revision:layout.revision},
      ordered_target_ids:targets.map(t=>t.id),ordered_target_labels:targets.map(t=>t.label),trials:[],current_target:null,stop_requested:false,error:null};
    state.buttonRuns.push(run);state.activeButtonRun=run;state.batching=true;state.batchKind='buttons';state.batchToken=id;state.stop=false;
    try{
      lockControls();renderResults();state.runTimer=setInterval(renderButtonRun,200);
      for(let i=0;i<targets.length;i++){
        if(state.stop)break;
        const target=targets[i];run.current_target={id:target.id,label:target.label,position:i+1};renderButtonRun();
        try{
          const result=await runTrial({model,instruction:`Click the ${target.label} button.`,expectedTargetId:target.id,expectedAction:'click',batchToken:id,requestSettings,
            localRun:{id,name:run.name,type:'click_all_buttons',model,...requestSettings,position:i+1,planned:targets.length,target_id:target.id}});
          run.trials.push(clickAttempt(result,target,i+1));
          if(result.outcome==='stale'){run.error='The captured layout became stale; the remaining buttons were not attempted.';break;}
        }catch(error){
          run.trials.push({position:i+1,target_id:target.id,target_label:target.label,request_id:null,category:'local_error',outcome:'error',hit:false,
            error_code:'local_error',error:error.message||String(error),click_count:0,send_to_click_ms:null,api_latency_ms:null,events:[]});
          run.error=error.message||String(error);break;
        }
        renderButtonRun();
      }
    }catch(error){run.error=error.message||String(error);}
    finally{
      if(state.runTimer!==null)clearInterval(state.runTimer);state.runTimer=null;
      run.elapsed_ms=performance.now()-started;run.finished_at=new Date(performance.timeOrigin+started+run.elapsed_ms).toISOString();
      run.status=run.error?'error':run.trials.length===targets.length?'completed':'stopped';run.current_target=null;
      state.inFlight=false;state.dispatch=null;state.batching=false;state.batchKind=null;state.batchToken=null;state.stop=false;
      renderResults();lockControls();const summary=summarizeButtonRun(run);
      setStatus(`Click all ${run.status}: ${summary.successful_clicks}/${summary.completed_attempts} hits · ${summary.completed_attempts}/${summary.planned_buttons} attempted · ${formatDuration(summary.total_wall_ms)} total${summary.latency_sample_count?` · ${formatDuration(summary.mean_send_to_click_ms)} average to click`:''}.`,run.error?'error':'');
    }
    try{
      const record={request_id:run.id,record_type:'click_all_summary',run:summarizeButtonRun(run)};
      const saved=await fetch('/api/result',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(record),cache:'no-store',signal:AbortSignal.timeout(10000)});
      run.summary_persisted=saved.ok;if(!saved.ok)run.summary_persistence_error=`HTTP ${saved.status}`;
    }catch(error){run.summary_persisted=false;run.summary_persistence_error=error.message;}
    return summarizeButtonRun(run);
  }
  function stopBatch(){
    if(!state.batching)return;state.stop=true;
    if(state.batchKind==='buttons'&&state.activeButtonRun?.status==='running')state.activeButtonRun.stop_requested=true;
    lockControls();renderButtonRun();setStatus('The current request will finish, then the run will stop.','busy');
  }
  function restoreData(data){
    if(state.inFlight||state.batching)throw new Error('A test is running.');
    if(!data||!Array.isArray(data.results))throw new Error('Expected an exported lab result object.');
    const restored=data.results.map(value=>{
      const r=copy(value),snapshot=copy(data.captures?.[r.capture_id]||r.snapshot);
      if(!snapshot||typeof snapshot.screenshot!=='string'||!snapshot.screenshot.startsWith('data:image/png;base64,'))throw new Error('An exported PNG capture is missing.');
      return {...r,snapshot};
    });
    const runs=(data.click_all_runs||[]).map(value=>{const r=copy(value);if(!Array.isArray(r.trials)||!Array.isArray(r.ordered_target_ids))throw new Error('Invalid click-all run.');r.elapsed_ms=r.total_wall_ms??r.elapsed_ms??0;if(r.status==='running'){r.status='interrupted';r.current_target=null;}return r;});
    resetRunFeedback();state.results=restored;state.buttonRuns=runs;state.activeButtonRun=runs.at(-1)||null;
    state.requestTimeline=restored.length?requestMeasurements(restored.at(-1)):null;renderRequestTimeline();renderResults();lockControls();
    return {results:restored.length,click_all_runs:runs.length};
  }
  function copyResult(r,includeCapture=false){const result={...r,snapshot:{...r.snapshot}};if(!includeCapture)delete result.snapshot.screenshot;return copy(result);}
  function measureResults(results){
    const scored=results.filter(r=>['hit','miss'].includes(r.outcome)),hits=scored.filter(r=>r.hit).length;
    const lat=results.filter(r=>r.outcome!=='error'&&r.outcome!=='stale').map(r=>r.api_latency_ms??r.latency_ms).filter(Number.isFinite).sort((a,b)=>a-b);
    return {trials:results.length,scored:scored.length,hits,hit_rate:scored.length?hits/scored.length:null,errors:results.filter(r=>r.outcome==='error').length,
      unscored:results.filter(r=>r.outcome==='unscored'||r.outcome==='stale').length,median_latency_ms:lat.length?(lat[Math.floor((lat.length-1)/2)]+lat[Math.ceil((lat.length-1)/2)])/2:null};
  }
  function metrics(){
    const buckets=new Map();
    for(const r of state.results){
      const auth_mode=resultBackend(r),speed_tier=resultTier(r),key=JSON.stringify([auth_mode,r.model,speed_tier]);
      if(!buckets.has(key))buckets.set(key,{auth_mode,model:r.model,speed_tier,results:[]});buckets.get(key).results.push(r);
    }
    const groups=[...buckets.values()].map(g=>({auth_mode:g.auth_mode,model:g.model,speed_tier:g.speed_tier,...measureResults(g.results),
      actual_service_tiers:[...new Set(g.results.map(r=>tierEvidence(r).actual).filter(Boolean))],
      unreported_tier_count:g.results.filter(r=>!tierEvidence(r).actual).length}));
    const aggregate=measureResults(state.results);
    return {...aggregate,mixed_configurations:groups.length>1,hit_rate:groups.length>1?null:aggregate.hit_rate,
      median_latency_ms:groups.length>1?null:aggregate.median_latency_ms,groups};
  }
  function textNode(tag,text,className){const el=document.createElement(tag);el.textContent=text;if(className)el.className=className;return el;}
  function renderResults(){
    renderButtonRun();const m=metrics(),has=state.results.length>0,hasRun=state.buttonRuns.length>0;$('results-empty').hidden=has||hasRun;$('results-table').hidden=!has;$('metrics').hidden=!has||hasRun;
    $('last-detail').hidden=!has;$('export').disabled=!has&&!hasRun;$('clear').disabled=(!has&&!hasRun)||state.inFlight||state.batching;
    $('result-count').textContent=has?`${state.results.length} ${state.results.length===1?'trial':'trials'}`:'No trials yet';
    $('metrics').replaceChildren();$('metrics').classList.toggle('mixed',m.mixed_configurations);
    $('comparison-groups').replaceChildren();$('comparison-groups').hidden=!has||!m.mixed_configurations;
    for(const group of m.groups){
      const card=textNode('div','','comparison-group');card.append(textNode('strong',group.model));
      card.append(textNode('p',`${backendLabel(group.auth_mode)} · ${tierLabel(group.speed_tier)} requested`));
      const stats=textNode('p','','comparison-stats');stats.append(textNode('span',`${group.hits}/${group.scored} scored hits`),textNode('span',`${group.errors} errors`),textNode('span',`${formatDuration(group.median_latency_ms)} median API`));card.append(stats);
      card.append(textNode('p',`Provider tier: ${group.actual_service_tiers.join(', ')||'not reported'}${group.unreported_tier_count?` · ${group.unreported_tier_count} unreported`:''}`));$('comparison-groups').append(card);
    }
    for(const [value,label] of [[m.mixed_configurations?`${m.groups.length} groups`:m.hit_rate===null?'—':`${Math.round(m.hit_rate*100)}%`,m.mixed_configurations?'connection / model / tier':'scored hit rate'],[`${m.hits}/${m.scored}`,'scored hits'],[m.errors,'errors'],[m.unscored,'unscored'],[m.median_latency_ms===null?'—':`${(m.median_latency_ms/1000).toFixed(1)}s`,'median API time']]){
      const box=textNode('div','','metric');box.append(textNode('strong',String(value)),textNode('span',label));$('metrics').append(box);
    }
    $('results-body').replaceChildren();
    for(const r of [...state.results].reverse()){
      const tr=document.createElement('tr'),model=textNode('td',r.model);model.append(textNode('div',backendLabel(resultBackend(r)),'table-model-note'));model.append(textNode('div',`${r.snapshot.width} × ${r.snapshot.height} · seed ${r.snapshot.seed}`,'table-model-note'));
      if(r.run)model.append(textNode('div',`Click all buttons · ${r.run.position} / ${r.run.planned}`,'table-run-note'));
      if(r.error)model.append(textNode('div',r.error,'row-error'));tr.append(model);
      const evidence=tierEvidence(r),tier=document.createElement('td');
      tier.append(textNode('div',tierLabel(resultTier(r)),'table-tier-label'));
      tier.append(textNode('div',evidence.requested?`Requested: ${evidence.requested}`:resultTier(r)?'Request tier not reported':'Legacy result · tier not recorded','table-tier-note'));
      tier.append(textNode('div',evidence.actual?`Reported: ${evidence.actual}`:'Provider tier not reported','table-tier-note'));
      if(evidence.note)tier.append(textNode('div',evidence.note,'table-tier-note warning'));
      const status=textNode('span',evidence.status.replaceAll('_',' '),'tier-status');
      if(['confirmed','reported','rejected','different','unsupported'].includes(evidence.status))status.classList.add(evidence.status);tier.append(status);tr.append(tier);
      const outcome=document.createElement('td');outcome.append(textNode('span',r.outcome.toUpperCase(),`outcome ${r.outcome}`));tr.append(outcome);
      const p=r.prediction;tr.append(textNode('td',p.error?'—':`${p.action} · ${Math.round(p.x)}, ${Math.round(p.y)}`));
      tr.append(textNode('td',r.expected_target?`${r.expected_target.label}${r.expected_action?'':' · location'}`:'Unscored'));
      const timingCell=document.createElement('td'),timeline=textNode('div','','request-timeline table-request-timeline');fillTimeline(timeline,requestMeasurements(r));timingCell.append(timeline,textNode('div','API total '+formatDuration(r.api_latency_ms??r.latency_ms),'table-api-note'));tr.append(timingCell);
      tr.append(textNode('td',formatDuration(r.send_to_click_ms)));
      const td=document.createElement('td'),view=textNode('button','View image','view-capture');view.type='button';view.disabled=state.inFlight||state.batching;view.addEventListener('click',()=>showCapture(r));td.append(view);tr.append(td);$('results-body').append(tr);
    }
    const latest=state.results.at(-1);if(latest){const tier=tierEvidence(latest);$('response-tier-detail').textContent=`${backendLabel(resultBackend(latest))} · ${tierLabel(resultTier(latest))} selected · requested: ${tier.requested||'not recorded'} · provider reported: ${tier.actual||'not reported'} · ${tier.status.replaceAll('_',' ')}${tier.note?' · '+tier.note:''}`;$('response-timing-detail').textContent=timingDescription(latest);$('raw-response').textContent=JSON.stringify(copyResult(latest),null,2);$('response-image-detail').textContent=`Image detail: ${latest.response.image_detail||'not reported'} · policy: ${latest.response.image_detail_policy||'not reported'} · protocol: ${latest.response.protocol||'not reported'}`;}
  }
  function showCapture(result){$('capture-title').textContent='Exact image sent';$('capture-description').textContent=`${result.model} · ${backendLabel(resultBackend(result))} · ${tierLabel(resultTier(result))} · ${result.snapshot.width} × ${result.snapshot.height} px · “${result.instruction}”`;$('capture-image').src=result.snapshot.screenshot;$('capture-dialog').showModal();}
  function modelKind(m){const kind=String(m.kind||m.category||m.type||'');return /realtime|audio|live|voice/i.test(`${kind} ${m.id}`)?'audio':'text';}
  function normalizeModel(value){const m=typeof value==='string'?{id:value}:value;return {...m,id:String(m.id||m.model||m.name||''),available:m.available!==false&&m.supported!==false&&m.disabled!==true};}
  function renderModels(){
    const filter=$('model-filter').value.toLowerCase().trim();$('models').replaceChildren();
    for(const kind of ['audio','text']){
      const list=state.models.filter(m=>modelKind(m)===kind&&`${m.id} ${m.name||''}`.toLowerCase().includes(filter));if(!list.length)continue;
      const group=textNode('div','','model-group');group.append(textNode('h3',kind==='audio'?'Audio / realtime · tested with text':'Text / vision'));
      for(const m of list){
        const row=textNode('label','',`model-choice${m.id===state.selectedModel?' selected':''}${m.available?'':' unavailable'}`);
        const radio=document.createElement('input');radio.type='radio';radio.name='model';radio.value=m.id;radio.checked=m.id===state.selectedModel;radio.dataset.available=String(m.available);radio.disabled=!m.available||state.inFlight||state.batching||state.switching||state.loadingModels;
        radio.addEventListener('change',()=>{if(state.inFlight||state.batching||state.switching||state.loadingModels)return;state.selectedModel=m.id;renderModels();renderConfiguration();lockControls();});
        const body=textNode('span','','model-copy');body.append(textNode('div',m.id,'model-name'));
        const reason=m.reason||m.note||m.description;if(reason)body.append(textNode('div',String(reason),'model-note'));
        row.append(radio,body,textNode('span',m.available?(kind==='audio'?'audio':'text'):'unavailable','model-kind'));group.append(row);
      }$('models').append(group);
    }
    if(!$('models').children.length)$('models').append(textNode('div',state.models.length?'No matching models.':'No models were returned. Check the configured login or API key.','empty-models'));
    $('model-count').textContent=`${state.models.filter(m=>m.available).length} testable / ${state.models.length} listed`;
  }
  async function refreshModels(force=false){
    if(state.inFlight||state.batching)throw new Error('The catalog is frozen while a test is running.');
    state.loadingModels=true;lockControls();
    $('refresh-models').disabled=true;$('connection').className='connection';$('connection').lastElementChild.textContent='Loading models…';
    try{
      const response=await fetch(force===true?'/api/models?refresh=1':'/api/models',{cache:'no-store'}),data=await response.json();if(!response.ok||data.error)throw new Error(typeof data.error==='string'?data.error:data.error?.message||`HTTP ${response.status}`);
      state.catalog=data;if(data.connection)adoptConnection(data.connection);else if(data.auth&&typeof data.auth==='object')adoptConnection({...state.connectionInfo,...data.auth,auth_mode:data.auth.mode||state.authMode});state.models=(Array.isArray(data)?data:data.models||data.data||[]).map(normalizeModel).filter(m=>m.id);
      state.modelSource=(Array.isArray(data.source)?data.source.join(', '):String(data.source||'Configured account'));
      if(!state.models.some(m=>m.id===state.selectedModel&&m.available))state.selectedModel=state.models.find(m=>m.id==='gpt-realtime-2.1'&&m.available)?.id||state.models.find(m=>m.available)?.id||null;
      const missing=state.connectionInfo?.configured===false,unavailable=missing||data.auth?.configured===false;
      const configured=state.connectionInfo?.configured===true||data.auth?.configured===true;
      $('connection').className=unavailable?'connection error':configured?'connection ready':'connection';
      $('connection').lastElementChild.textContent=missing?(state.authMode==='api'?'API key required':'Codex sign-in required'):unavailable?'Authentication not ready':(configured?'Configured · ':'Catalog loaded · ')+backendLabel(state.authMode);
      $('catalog-source').textContent=`${state.modelSource}. Audio models use the same text instruction and screenshot. Unavailable entries show the reason.`;
      renderModels();renderConfiguration();
    }catch(error){state.models=[];state.selectedModel=null;$('connection').className='connection error';$('connection').lastElementChild.textContent='Model catalog unavailable';$('models').replaceChildren(textNode('div',error.message,'empty-models'));setStatus(`Unable to load models: ${error.message}`,'error');}
    finally{state.loadingModels=false;lockControls();}return copy(state.models);
  }
  async function runBatch(){
    if(state.inFlight||state.batching||state.switching||state.loadingModels)return;const requestSettings=selectedSettings(),models=state.models.filter(m=>m.available);if(!models.length)return;
    const instruction=$('instruction').value.trim();if(!instruction){setStatus('Enter an instruction first.','error');return;}
    resetRunFeedback();
    state.batching=true;state.batchKind='models';state.batchToken=`models-${Date.now()}-${randomSeed()}`;state.stop=false;lockControls();let done=0,batchError=null;
    try{for(const model of models){if(state.stop)break;await runTrial({model:model.id,instruction,batchToken:state.batchToken,requestSettings});done++;setStatus(`Compared ${done} of ${models.length} models. Each uses a fresh request.`,done<models.length?'busy':'');}}
    catch(error){batchError=error.message||String(error);}
    finally{state.batching=false;state.batchKind=null;state.batchToken=null;state.stop=false;lockControls();setStatus(batchError?`Comparison stopped after a local error: ${batchError}`:`Comparison ${done===models.length?'complete':'stopped'}: ${done} models tested on the same screenshot and instruction.`,batchError?'error':'');}
  }
  function exportData(){const captures={};for(const r of state.results)captures[r.snapshot.id]=copy(r.snapshot);return {schema_version:3,test_configuration:selectedSettings(),generated_at:new Date().toISOString(),scope:'Controlled screenshot grounding; text instructions; fresh sessions; no operating-system input',metrics:metrics(),models:copy(state.models),captures,results:state.results.map(r=>copyResult(r)),click_all_runs:state.buttonRuns.map(summarizeButtonRun)};}
  function exportJSON(){const blob=new Blob([JSON.stringify(exportData(),null,2)],{type:'application/json'}),url=URL.createObjectURL(blob),link=document.createElement('a');link.href=url;link.download=`woi-click-lab-${new Date().toISOString().replace(/[:.]/g,'-')}.json`;link.click();setTimeout(()=>URL.revokeObjectURL(url),1000);}
  for(const input of document.querySelectorAll('input[name=speed-tier]'))input.addEventListener('change',()=>{try{setSpeedTier(input.value);}catch(error){renderConfiguration();setStatus(error.message,'error');}});
  for(const input of document.querySelectorAll('input[name=auth-mode]'))input.addEventListener('change',()=>changeConnection(input.value).catch(()=>{}));
  $('clear-api-key').addEventListener('click',()=>changeConnection('api','').catch(()=>{}));
  $('save-api-key').addEventListener('click',()=>{const key=$('api-key').value.trim();if(!key){$('connection-status').textContent='Paste an API key first.';return;}changeConnection('api',key).catch(()=>{});});
  $('api-key').addEventListener('keydown',event=>{if(event.key==='Enter'){event.preventDefault();$('save-api-key').click();}});
  $('trial-form').addEventListener('submit',event=>{event.preventDefault();runTrial().catch(e=>setStatus(e.message,'error'));});
  $('instruction').addEventListener('input',updateScorePreview);
  $('instruction').addEventListener('keydown',event=>{if(event.key==='Enter'&&(event.ctrlKey||event.metaKey)){event.preventDefault();if(!state.inFlight&&!state.batching)runTrial().catch(e=>setStatus(e.message,'error'));}});
  $('expected-target').addEventListener('change',updateScorePreview);$('expected-action').addEventListener('change',updateScorePreview);
  $('suggest-click').addEventListener('click',()=>suggest('click'));$('suggest-move').addEventListener('click',()=>suggest('move'));
  $('another-target').addEventListener('click',()=>suggest(state.suggestedAction,state.targets[Math.floor(Math.random()*state.targets.length)]));
  $('randomize').addEventListener('click',()=>{setLayout();suggest();});
  $('resolution').addEventListener('change',()=>{const [width,height]=$('resolution').value.split('x').map(Number);setLayout({seed:state.seed,width,height});suggest();});
  $('button-count').addEventListener('change',()=>{setLayout({seed:state.seed,count:Number($('button-count').value)});suggest();});
  $('apply-seed').addEventListener('click',()=>{setLayout({seed:Number($('seed').value)});suggest();});
  $('refresh-models').addEventListener('click',()=>refreshModels(true));$('model-filter').addEventListener('input',renderModels);
  $('batch').addEventListener('click',runBatch);$('click-all').addEventListener('click',()=>runClickAll().catch(e=>setStatus(e.message,'error')));$('stop').addEventListener('click',stopBatch);
  $('export').addEventListener('click',exportJSON);$('clear').addEventListener('click',()=>{state.results=[];state.buttonRuns=[];state.activeButtonRun=null;resetRunFeedback();mark.clearRect(0,0,state.width,state.height);renderResults();setStatus('Results cleared. The next request will also start fresh.');});
  $('close-capture').addEventListener('click',()=>$('capture-dialog').close());
  $('capture-dialog').addEventListener('click',event=>{if(event.target===$('capture-dialog'))$('capture-dialog').close();});
  addEventListener('resize',updateScreenMeta);
  window.ClickLab={version:3,setSpeedTier,selectSpeedTier:setSpeedTier,changeConnection,refreshConnection,generateLayout,setLayout,getLayout,capture,refreshModels,runTrial,runBatch,runClickAll,stopBatch,restoreData,
    getState:()=>({layout:getLayout(),completedTargetIds:[...state.completedTargetIds],requestTimeline:state.requestTimeline?copy(state.requestTimeline):null,models:copy(state.models),selectedModel:state.selectedModel,speedTier:state.speedTier,authMode:state.authMode,connection:state.connectionInfo?copy(state.connectionInfo):null,switching:state.switching,loadingModels:state.loadingModels,inFlight:state.inFlight,batching:state.batching,batchKind:state.batchKind,clickAllRun:state.buttonRuns.length?summarizeButtonRun(state.buttonRuns.at(-1)):null,clickAllRuns:state.buttonRuns.map(summarizeButtonRun),metrics:metrics(),results:state.results.map(r=>copyResult(r))}),
    getEvents:()=>copy(state.events),clearEvents:()=>{state.events=[];},getLastRequest:()=>copy(state.lastRequest),
    selectModel:id=>{if(state.inFlight||state.batching)throw new Error('A test is running.');if(!state.models.some(m=>m.id===id&&m.available))throw new Error('Model is not available.');state.selectedModel=id;renderModels();renderConfiguration();lockControls();},
    setInstruction:(text,options={})=>{if(state.inFlight||state.batching)throw new Error('A test is running.');$('instruction').value=text;if(options.expectedTargetId!==undefined)$('expected-target').value=options.expectedTargetId;if(options.expectedAction!==undefined)$('expected-action').value=options.expectedAction;updateScorePreview();},
    executeForTest:(prediction,snapshot)=>{const shot=snapshot||captureSnapshot(),p=normalizePrediction(prediction);if(p.error)throw new Error(p.error);const result=executePrediction(p,shot,'local-calibration');drawResult(p,null,'unscored');return copy(result);},
    exportData,showLastCapture:()=>{const r=state.results.at(-1);if(r)showCapture(r);}};
  const params=new URLSearchParams(location.search);setLayout({seed:params.has('seed')?Number(params.get('seed')):randomSeed()});suggest();renderResults();renderConfiguration();refreshConnection().finally(()=>refreshModels());
})();
