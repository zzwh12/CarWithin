import Foundation

/// LAN browser receiver, one page with two decoders.
///
/// - **WebCodecs** (HTTPS secure context): each access unit is decoded as it arrives and drawn to
///   the canvas as soon as it is decoded. When the oldest undecoded frame has waited longer than
///   the performance mode allows, the page drops to the next keyframe and asks the iPhone for one.
///   (A fixed "queue over 2 frames" rule fired constantly on head-unit hardware decoders, which
///   normally hold 3–5 frames, and made HTTPS stutter more than HTTP.) In automatic mode, repeated
///   skips switch this page to MSE for the rest of the browser session. Binary packets: 1 byte (1 = keyframe),
///   8 bytes big-endian arrival time in CarWithin' monotonic µs, then the AVCC/HVCC sample.
/// - **MSE** (HTTP fallback): fMP4 over WebSocket. Binary messages start with one byte:
///   2 = init segment, 1 = keyframe fragment, 0 = dependent fragment. The SourceBuffer is only
///   trimmed up to a keyframe it still holds (removing the only IDR froze H.264), latency is kept
///   down with playbackRate, and stalls or decode errors request a keyframe.
///
/// Touch is sent as the full list of held fingers (`touches`), so pinch and rotate work.
/// Errors and, with `?debug=1`, stats are reported back to the iPhone log.
/// The page reports its pixel size, refresh rate and H.265 support (`display`) so CarWithin can
/// follow the head unit's screen, and `struggling` when playback keeps hitching.
enum BrowserReceiverPage {
    /// Sent with hello/format. An open page from an older app build reloads itself,
    /// because its in-page reconnect would otherwise keep running the old script.
    static var version: String { "1.0.2-" + (CarWithinLanguage.isEnglish ? "en" : "zh") }
    static var html: Data {
        if CarWithinLanguage.isEnglish,
           let url = Bundle.main.url(forResource: "Receiver.en", withExtension: "html"),
           let page = try? String(contentsOf: url, encoding: .utf8) {
            return Data(page.replacingOccurrences(of: "\\#(version)", with: version).utf8)
        }
        return chineseHTML
    }
    private static let chineseHTML = Data(#"""
<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<link rel="icon" href="data:,">
<title>CarWithin</title>
<style>
:root{color-scheme:dark}*{box-sizing:border-box}html,body{margin:0;width:100%;height:100%;overflow:hidden;background:#05070b;color:#fff;font-family:-apple-system,BlinkMacSystemFont,"PingFang SC",sans-serif}
main{position:relative;width:100%;height:100%}video,canvas{position:absolute;inset:0;width:100%;height:100%;object-fit:contain;background:#000;pointer-events:none}
#touch{position:absolute;inset:0;touch-action:none;user-select:none;-webkit-user-select:none;-webkit-touch-callout:none}
#startPlayback{position:fixed;z-index:5;top:50%;left:50%;transform:translate(-50%,-50%);background:#0a84ff;font-size:17px;padding:12px 20px}
#top{position:fixed;z-index:3;left:16px;right:16px;top:14px;left:max(16px,env(safe-area-inset-left));right:max(16px,env(safe-area-inset-right));top:max(14px,env(safe-area-inset-top));display:flex;justify-content:space-between;align-items:flex-start;gap:10px;pointer-events:none}
.badge{padding:9px 13px;border-radius:14px;background:rgba(18,24,36,.82);backdrop-filter:blur(16px);-webkit-backdrop-filter:blur(16px);font-size:14px}.dot{display:inline-block;width:8px;height:8px;border-radius:50%;background:#ff9f0a;margin-right:8px}.ok .dot{background:#30d158}.bad .dot{background:#ff453a}
.toolbar{display:flex;flex-direction:column;align-items:flex-end;gap:8px}.actions{display:flex;gap:8px;align-items:center;justify-content:flex-end;flex-wrap:wrap}.actions>*{white-space:nowrap}button,a.chip{pointer-events:auto;border:0;border-radius:13px;padding:9px 13px;background:rgba(18,24,36,.82);color:#fff;font:inherit;font-size:14px;backdrop-filter:blur(16px);-webkit-backdrop-filter:blur(16px);cursor:pointer;text-decoration:none}
#stats{position:fixed;z-index:3;left:max(16px,env(safe-area-inset-left));top:calc(max(14px,env(safe-area-inset-top)) + 46px);font:12px/1.5 ui-monospace,Menlo,monospace;color:#d1d1d6;white-space:pre}
.tp{position:fixed;z-index:4;width:44px;height:44px;margin:-22px 0 0 -22px;border-radius:50%;border:3px solid rgba(255,255,255,.9);background:rgba(10,132,255,.35);pointer-events:none}
#status,#fast,#statsButton,#full{transition:opacity .3s,visibility .3s}
.idle #top:not(:focus-within) :is(#status,#fast,#statsButton,#full){opacity:0;visibility:hidden}
.fullscreen :is(#status,.actions,#stats,#startPlayback){display:none}
.fullscreen #top{justify-content:flex-end}
[hidden]{display:none!important}
</style>
</head>
<body><main><video id="video" muted autoplay playsinline disablepictureinpicture disableremoteplayback></video><canvas id="view" hidden></canvas><canvas id="hold" hidden></canvas><div id="touch"></div></main>
<div id="top"><div id="status" class="badge"><span class="dot"></span><span>正在连接 CarWithin…</span></div><div class="toolbar">
  <div class="actions"><a id="fast" class="chip" hidden>配置 HTTPS</a><button id="statsButton">统计</button><button id="full">全屏</button></div>
  <button id="enableAudio" hidden>开启声音</button>
</div></div>
<div id="stats" class="badge" hidden></div>
<button id="startPlayback" hidden>开始播放</button>
<script>
/* This early check uses ES5 so even a restricted WebView can explain why playback cannot start. */
(function () {
  var label = document.getElementById('status').getElementsByTagName('span')[1];
  window.setTimeout(function () {
    if (!window.carWithinPlayerBooted) {
      label.textContent = '播放器未能启动。请更新车机浏览器或 Android System WebView，再打开本页。';
      document.getElementById('status').className = 'badge bad';
    }
  }, 1500);
}());
</script>
<script>
'use strict';
const PAGE_VERSION='\#(version)';
const connectionProtocol=location.protocol==='https:'?'HTTPS':'HTTP';
const $=s=>document.querySelector(s);
const video=$('#video'),view=$('#view'),hold=$('#hold'),touchLayer=$('#touch'),statusEl=$('#status'),label=statusEl.querySelector('span:last-child'),statsEl=$('#stats'),fastLink=$('#fast');
const MS=(/iPhone|iPad|iPod/.test(navigator.userAgent)&&window.ManagedMediaSource)||window.MediaSource||window.ManagedMediaSource;
const managedMSE=!!MS&&MS===window.ManagedMediaSource;
const startPlayback=$('#startPlayback'),enableAudio=$('#enableAudio');
function preference(storage,key,value){
 try{const store=window[storage];if(value===undefined)return store.getItem(key);store.setItem(key,value)}catch(e){}
 return null
}
const canMSE=!!MS&&typeof MS.isTypeSupported==='function';
const canWebCodecs=window.isSecureContext&&typeof VideoDecoder==='function'&&typeof VideoDecoder.isConfigSupported==='function'&&typeof EncodedVideoChunk==='function';
// ?mse=1 forces the compatibility decoder (troubleshooting).
// Automatic mode remembers, for this browser session, that WebCodecs kept hitching here.
let useWebCodecs=canWebCodecs&&!/[?&]mse=1/.test(location.search)&&preference('sessionStorage','carwithin.mse')!=='1';
// Performance modes (set on the iPhone): how long a frame may wait for the decoder before the page
// skips to the next keyframe, and how far MSE may lag before it speeds up or jumps.
const PERF={
 auto:{lagMs:250,queue:12,fast:0.3,faster:0.8,jump:2},
 quality:{lagMs:700,queue:40,fast:0.8,faster:1.6,jump:4},
 speed:{lagMs:100,queue:5,fast:0.15,faster:0.4,jump:1}
};
let perfMode='auto',P=PERF.auto,showTouches=false;
// Hitches: skips to a keyframe or stall recoveries, newest last (ms timestamps).
let hitches=[],lastStruggle=0;
function hitch(reason){
 const now=performance.now();hitches.push(now);hitches=hitches.filter(t=>now-t<30000);
 if(useWebCodecs&&fmt&&perfMode==='auto'&&hitches.filter(t=>now-t<10000).length>=4&&
    tryMSE(fmt,'低延迟播放反复跳帧（'+reason+'）')){
  preference('sessionStorage','carwithin.mse','1');hitches=[];return}
 if(hitches.length>=5&&now-lastStruggle>60000){lastStruggle=now;send({type:'struggling',reason,count:hitches.length,decoder:useWebCodecs?'webcodecs':'mse'})}
}
const debug=/[?&]debug=1/.test(location.search);let debugTick=0,received=0;
let ws=null,fmt=null,shown=false,receiverReady=false,attempt=0,retryTimer=0,firstFrameTimer=0,lastKeyRequest=0,idleTimer=0,bytesIn=0;
// Clock sync with CarWithin (µs): offset = server − client, best of the lowest-RTT samples.
let clockOffset=null,bestRtt=Infinity,bestAt=0,latencies=[];
const nowUs=()=>performance.now()*1000;
function setStatus(text,state=''){label.textContent=text;statusEl.classList.toggle('ok',state==='ok');statusEl.classList.toggle('bad',state==='bad')}
function send(o){if(ws&&ws.readyState===1)ws.send(JSON.stringify(o))}
function report(type,text){send({type,text:String(text).slice(0,300)})}
// At most one request a second: every forced IDR is ~10× a normal frame, so asking faster than
// the decoder recovers floods it with keyframes. CarWithin itself resends until one arrives.
function askKey(reason){const now=performance.now();if(now-lastKeyRequest<1000)return;lastKeyRequest=now;send({type:'keyframe',reason})}
function wake(){document.body.classList.remove('idle');clearTimeout(idleTimer);idleTimer=setTimeout(()=>{if(shown)document.body.classList.add('idle')},3000)}
function holdFrame(){try{if(!useWebCodecs&&video.readyState>=2&&video.videoWidth){hold.width=video.videoWidth;hold.height=video.videoHeight;hold.getContext('2d').drawImage(video,0,0);hold.hidden=false}}catch(e){}}

// ---------- optional CarPlay audio ----------
const AudioContextClass=window.AudioContext||window.webkitAudioContext;
const mseAudioClock=new Map(),activeAudio=new Set(),audioSchedule=new Map();
let audioContext=null,audioOffered=false,audioPackets=[],videoStamp=null,videoStampAt=0;
let audioGestureTimer=0;
function audioPlaying(){return audioOffered&&audioContext&&audioContext.state==='running'}
function canStartAudio(){return audioOffered&&shown&&(useWebCodecs||!video.paused)&&!document.hidden}
let audioDropped=0;
function requestAudio(){if(receiverReady)send({type:'audio',enabled:canStartAudio()&&audioPlaying()})}
function clearAudio(){
 audioPackets=[];audioSchedule.clear();audioDropped=0;videoStamp=null;mseAudioClock.clear();
 for(const source of activeAudio){try{source.stop()}catch(e){}}
 activeAudio.clear();
}
function audioStateChanged(){
 clearTimeout(audioGestureTimer);audioGestureTimer=0;
 requestAudio();
 if(!canStartAudio()||!audioContext||audioPlaying()){
  enableAudio.hidden=true;
 }else if(enableAudio.hidden){
  // resume() can stay pending until the browser receives a user gesture.
  audioGestureTimer=setTimeout(()=>{enableAudio.hidden=!canStartAudio()||audioPlaying()},300);
 }
}
function ensureAudioPlayback(fromGesture=false){
 if(!canStartAudio()||!AudioContextClass){audioStateChanged();return}
 try{
  if(!audioContext){
   audioContext=new AudioContextClass();
   audioContext.addEventListener('statechange',audioStateChanged);
  }
  if(!audioPlaying())audioContext.resume().then(audioStateChanged).catch(e=>{
   if(fromGesture)report('error','无法开始伴音：'+e.message);
   audioStateChanged();
  });
  audioStateChanged();
 }catch(e){
  report('error','无法建立伴音播放器：'+e.message);
  audioOffered=false;audioStateChanged();
 }
}
enableAudio.onclick=()=>ensureAudioPlayback(true);
function packetTimestamp(u){
 const time=new DataView(u.buffer,u.byteOffset+1,8);
 return time.getUint32(0)*4294967296+time.getUint32(4);
}
function onAudioPacket(u){
 if(!audioPlaying()||u.length<17||document.hidden)return;
 audioPackets.push({u,stamp:packetTimestamp(u),arrival:performance.now()/1000});
 if(audioPackets.length>180){audioPackets.shift();audioDropped++}
}
function videoClock(){
 if(useWebCodecs)return videoStamp!==null&&performance.now()-videoStampAt<400?videoStamp:null;
 if(video.paused||!shown||video.readyState<2)return null;
 const index=Math.round(video.currentTime/frameSeconds);
 for(let offset=0;offset<4;offset++){
  const stamp=mseAudioClock.get(index-offset);
  if(stamp!==undefined)return stamp+offset*frameSeconds*1e6;
 }
 return null;
}
// Use video as a starting alignment hint. CarPlay often sends no new picture while its
// dashboard is static, so continuous audio must run on its own RTP/sample clock.
const audioBaseBuffer=0.18,audioMaxTarget=0.42,audioScheduleLimit=0.55,audioBacklogLimit=0.95;
function newAudioStream(rate,channels){
 return {rate,channels,target:audioBaseBuffer,lastAdjustment:0,underruns:0,gaps:0,last:null};
}
function adjustAudioBuffer(state,packet,previous,underrun){
 if(!previous)return;
 const sourceDelta=(packet.stamp-previous.stamp)/1e6;
 const jitter=packet.arrival-previous.arrival-sourceDelta;
 if(sourceDelta>0&&sourceDelta<0.65&&(underrun||jitter>0.06)){
  const extra=underrun?0.05:0.02;
  state.target=Math.min(audioMaxTarget,Math.max(state.target+extra,audioBaseBuffer+Math.min(0.24,Math.max(0,jitter))));
  state.lastAdjustment=packet.arrival;
 }else if(Math.abs(jitter)<0.025&&packet.arrival-state.lastAdjustment>8){
  state.target=Math.max(audioBaseBuffer,state.target-0.015);state.lastAdjustment=packet.arrival;
 }
}
function drainAudio(){
 if(!audioPlaying()||document.hidden)return;
 const clock=videoClock(),current=audioContext.currentTime;
 const pending=audioPackets;audioPackets=[];
 const deferred=new Set(),newest=new Map();
 for(const packet of pending)newest.set(packet.u[14],packet.stamp);
 for(const packet of pending){
  const u=packet.u,wire=new DataView(u.buffer,u.byteOffset,u.byteLength);
  const rate=wire.getUint32(9),channels=u[13],stream=u[14],frames=(u.length-15)/(2*channels);
  if(rate<8000||rate>48000||channels<1||channels>2||!Number.isInteger(frames)||frames<1||frames>4096){audioDropped++;continue}
  if(newest.get(stream)-packet.stamp>audioBacklogLimit*1e6){audioDropped++;continue}
  if(deferred.has(stream)){audioPackets.push(packet);continue}
  const duration=frames/rate;
  let state=audioSchedule.get(stream);
  if(!state){state=newAudioStream(rate,channels);audioSchedule.set(stream,state)}
  const previous=state.last,formatChanged=state.rate!==rate||state.channels!==channels;
  const elapsed=previous?(packet.stamp-previous.stamp)/1e6:0;
  if(previous&&!formatChanged&&elapsed<=0&&elapsed> -0.25){audioDropped++;continue}
  let gap=previous?elapsed-previous.duration:0;
  if(Math.abs(gap)<0.012)gap=0;
  const follows=!!previous&&!formatChanged&&elapsed>0&&gap<0.25;
  // Do not turn a burst of missing packets into a growing queue of silence.
  const continuous=follows?previous.end+Math.min(0.025,Math.max(0,gap)):0;
  const queued=!!previous&&previous.end>current;
  const underrun=follows&&continuous<current+0.004;
  // Defer excess future packets rather than dropping a valid burst just because a
  // frame is too far ahead to submit to Web Audio right now.
  if(continuous>current+audioScheduleLimit||(queued&&previous.end>current+audioScheduleLimit)){
   deferred.add(stream);audioPackets.push(packet);continue;
  }

  adjustAudioBuffer(state,packet,formatChanged?null:previous,underrun);
  if(underrun)state.underruns++;
  if(previous&&!formatChanged&&gap>0)state.gaps++;
  const lead=clock===null?0:(packet.stamp-clock)/1e6;
  const delay=Math.min(audioMaxTarget,Math.max(state.target,lead+0.08));
  const at=follows&&!underrun?continuous:Math.max(current+delay,previous?previous.end:0);
  // Keep the sender and output sample clocks aligned over long playback.
  const speed=Math.max(0.995,Math.min(1.005,1+(at-current-state.target)*0.04));
  const fadeFrames=!follows||underrun||gap>0?Math.min(frames,Math.ceil(rate*0.006)):0;
  const audio=audioContext.createBuffer(channels,frames,rate);
  for(let ch=0;ch<channels;ch++){
   const plane=audio.getChannelData(ch);
   for(let i=0;i<frames;i++){
    const gain=i<fadeFrames?i/fadeFrames:1;
    plane[i]=wire.getInt16(15+2*(i*channels+ch),true)/32768*gain;
   }
  }
  const source=audioContext.createBufferSource();
  source.buffer=audio;source.playbackRate.value=speed;
  source.connect(audioContext.destination);activeAudio.add(source);
  source.onended=()=>{activeAudio.delete(source);source.disconnect()};
  source.start(at);
  state.rate=rate;state.channels=channels;
  state.last={stamp:packet.stamp,arrival:packet.arrival,end:at+duration/speed,duration};
 }
}
function audioStats(){
 if(!audioPlaying())return [];
 const stats=[];
 for(const [id,state] of audioSchedule){
  if(!state.last)continue;
  const queued=Math.max(0,(state.last.end-audioContext.currentTime)*1000).toFixed(0);
  stats.push(`音频 ${id} PCM16 · ${state.rate/1000} kHz / ${state.channels} 声道 · 输出 ${audioContext.sampleRate/1000} kHz`,
   `缓冲 ${queued} / 目标 ${Math.round(state.target*1000)} ms · 欠载 ${state.underruns} · 缺口 ${state.gaps}`);
 }
 if(audioDropped)stats.push(`音频丢弃 ${audioDropped} 包`);
 return stats;
}
setInterval(drainAudio,20);

// ---------- connection ----------
function teardown(){
 clearTimeout(firstFrameTimer);
 if(ws){ws.onopen=ws.onmessage=ws.onclose=ws.onerror=null;try{ws.close()}catch(e){}ws=null}
 fmt=null;shown=false;receiverReady=false;clockOffset=null;bestRtt=Infinity;
 audioOffered=false;clearAudio();audioStateChanged();
 teardownMSE();teardownWC();
}
function restart(reason,notify=true){
 if(retryTimer)return;
 if(notify)report('error',reason);
 holdFrame();teardown();
 // Exponential backoff with ±20% jitter so several viewers do not reconnect in lockstep.
 const delay=Math.min(10000,500*2**attempt)*(0.8+Math.random()*0.4);attempt=Math.min(attempt+1,6);
 setStatus(`${reason}，${(delay/1000).toFixed(1)} 秒后重连…`,'bad');
 retryTimer=setTimeout(()=>{retryTimer=0;boot()},delay);
}
function boot(){
 video.hidden=useWebCodecs;view.hidden=!useWebCodecs;
 window.carWithinPlayerBooted=true;
 if(typeof WebSocket!=='function'){setStatus('此浏览器缺少 WebSocket。请更新车机浏览器或 Android System WebView。','bad');return}
 if(!useWebCodecs&&!canMSE){setStatus('此浏览器缺少兼容播放器（MediaSource）。请更新浏览器，或在支持 WebCodecs 的浏览器中使用 HTTPS。','bad');return}
 connect();
}
// Keep the same identity across socket reconnects, with a separate identity for each page.
const viewerBytes=new Uint8Array(16);
if(window.crypto&&typeof window.crypto.getRandomValues==='function'){window.crypto.getRandomValues(viewerBytes)}
else{for(let i=0;i<16;i++)viewerBytes[i]=Math.floor(Math.random()*256)}
viewerBytes[6]=(viewerBytes[6]&15)|64;viewerBytes[8]=(viewerBytes[8]&63)|128;
const viewerHex=Array.from(viewerBytes,b=>b.toString(16).padStart(2,'0')).join('');
const viewerID=viewerHex.replace(/^(........)(....)(....)(....)(............)$/,'$1-$2-$3-$4-$5');
function connect(){
 setStatus('正在连接 CarWithin…');
 ws=new WebSocket(`${location.protocol==='https:'?'wss':'ws'}://${location.host}/stream`);ws.binaryType='arraybuffer';
 ws.onopen=()=>{
  ping();
  const ready=()=>{
   receiverReady=true;setStatus('已连接，正在等待画面');
   send({type:'ready',decoder:useWebCodecs?'webcodecs':'mse',viewer:viewerID,audioClock:!!AudioContextClass});sendDisplay();requestAudio()
  };
  if(useWebCodecs){ready();return}
  setStatus('已连接，正在启动播放器…');bootMSE(ready)
 };
 ws.onmessage=e=>{if(typeof e.data==='string')onText(JSON.parse(e.data));else{const u=new Uint8Array(e.data);if(u[0]===3){onAudioPacket(u);return}received++;useWebCodecs?onPacketWC(u):onBinaryMSE(u)}};
 ws.onclose=()=>restart('连接已断开',false);ws.onerror=()=>{};
}
function onText(m){
 if(m.type==='hello'){
  if(m.page!==PAGE_VERSION){location.reload();return}
  if(PERF[m.perf]){perfMode=m.perf;P=PERF[m.perf]}
  showTouches=!!m.showTouches;audioOffered=!!m.audio;ensureAudioPlayback();
  // Plain HTTP cannot run WebCodecs; offer the HTTPS page when CarWithin serves one.
  if(!canWebCodecs&&location.protocol==='http:'&&m.securePort>0){fastLink.href='/https-setup';fastLink.hidden=false}
  return}
 if(m.type==='pong'){
  if(typeof m.t0!=='number')return;
  const t3=nowUs(),rtt=t3-m.t0;
  if(rtt<=bestRtt*1.5||performance.now()-bestAt>30000){clockOffset=m.s-(m.t0+t3)/2;bestRtt=Math.min(rtt,bestRtt);bestAt=performance.now()}
  return}
 if(m.type==='status'){if(!shown)setStatus(m.text);return}
 if(m.type!=='format')return;
 if(m.page!==PAGE_VERSION){location.reload();return}
 fmt=m;
 if(m.decoder==='webcodecs')configureWC(m);else formatMSE(m);
}
function ping(){if(ws&&ws.readyState===1)send({type:'ping',t0:nowUs()})}
setInterval(ping,1000);
function firstFrame(){
 if(shown)return;shown=true;attempt=0;hold.hidden=true;clearTimeout(firstFrameTimer);
 if(fmt)setStatus(`CarPlay ${fmt.width}×${fmt.height} · ${fmt.fps} · ${fmt.name} · ${connectionProtocol}`,'ok');wake();
 if(useWebCodecs)ensureAudioPlayback();
}
function tryMSE(m,reason){
 if(!useWebCodecs||!canMSE||!MS.isTypeSupported('video/mp4; codecs="'+m.codec+'"'))return false;
 report('info',reason+'，切换兼容播放器');
 useWebCodecs=false;h265Ok=null;teardown();boot();
 probeH265().then(v=>{h265Ok=v;sendDisplay()});
 return true
}
function armFirstFrameTimer(m){
 clearTimeout(firstFrameTimer);
 firstFrameTimer=setTimeout(()=>{if(!shown){if(tryMSE(m,'低延迟首帧超时'))return;const hint=m.name==='H.265'?'，此浏览器可能不支持硬件 H.265，请改用 H.264':'';report('error',`首帧超时（${useWebCodecs?'WebCodecs':'MSE'}）`);restart('长时间没有画面'+hint,false)}},m.name==='H.265'?5000:8000);
}

// ---------- WebCodecs ----------
let decoder=null,wcConfig=null,wcWaiting=true,wcConfiguring=false,wcPending=[],ctx=null,wcDropped=0,framesDrawn=0,lastDrawAt=0,lastPacketAt=0;
let drawMs=0,drawCount=0,maxQueue=0;
// performance.now() of every chunk handed to the decoder and not yet output, oldest first.
let submitted=[],wcGeneration=0;
function b64(s){return Uint8Array.from(atob(s),c=>c.charCodeAt(0))}
function configureWC(m){
 const config={codec:m.codec,description:b64(m.description),hardwareAcceleration:'prefer-hardware',optimizeForLatency:true};
 teardownWC();const generation=wcGeneration;wcConfiguring=true;armFirstFrameTimer(m);setStatus(`正在解码 ${m.name}…`);
 VideoDecoder.isConfigSupported(config).then(r=>{
  if(generation!==wcGeneration)return;
  if(!r.supported)throw new Error(`不支持 ${m.codec}`);
  report('info',`${navigator.userAgent.slice(0,140)}；WebCodecs ${m.codec} 支持=true`);
  wcConfig=r.config||config;startDecoder();wcConfiguring=false;
  // Start from the newest keyframe that arrived while configuring; older frames are stale.
  let start=-1;wcPending.forEach((u,i)=>{if(u[0]===1)start=i});
  const queued=start<0?[]:wcPending.slice(start);wcPending=[];queued.forEach(onPacketWC);
 }).catch(e=>{
  if(generation!==wcGeneration)return;
  wcConfiguring=false;wcPending=[];
  if(tryMSE(m,'低延迟解码不可用'))return;
  report('error','WebCodecs 不可用：'+e.message);teardown();
  setStatus(m.name==='H.265'?'此浏览器无法播放 H.265。请在 CarWithin 改用 H.264 后重启 CarPlay。':'此浏览器无法解码当前 H.264。请试用 720P、30 FPS，或更新车机浏览器。','bad');
  retryTimer=setTimeout(()=>{retryTimer=0;boot()},15000);
 });
}
function startDecoder(){
 ctx=ctx||view.getContext('2d',{alpha:false});
 decoder=new VideoDecoder({
  output(frame){
   submitted.shift();
   // Draw at once: the compositor shows the newest canvas content at each refresh. Waiting for
   // requestAnimationFrame added a frame of latency and Safari throttles it, dropping frames.
   if(document.hidden){frame.close();wcDropped++;return}
   const t=performance.now();draw(frame);drawMs+=performance.now()-t;drawCount++;
  },
  error(e){report('error','WebCodecs 解码错误：'+e.message);recoverWC()}
 });
 decoder.configure(wcConfig);wcWaiting=true;submitted=[];
}
function draw(f){
 if(view.width!==f.displayWidth||view.height!==f.displayHeight){view.width=f.displayWidth;view.height=f.displayHeight}
 ctx.drawImage(f,0,0);videoStamp=f.timestamp;videoStampAt=performance.now();
 if(clockOffset!==null){const l=(nowUs()+clockOffset-f.timestamp)/1000;if(l>-50&&l<5000)latencies.push(l)}
 f.close();framesDrawn++;lastDrawAt=performance.now();firstFrame();
}
function onPacketWC(u){
 if(u.length<10)return;
 if(wcConfiguring){if(wcPending.length<180)wcPending.push(u);return}
 if(!decoder||decoder.state!=='configured')return;
 const key=u[0]===1,ts=packetTimestamp(u),data=u.subarray(9);
 lastPacketAt=performance.now();
 // A hidden page shows nothing: skip decoding and resume at a keyframe when it is visible again.
 if(document.hidden){wcWaiting=true;wcDropped++;return}
 maxQueue=Math.max(maxQueue,decoder.decodeQueueSize);
 if(wcWaiting){if(!key){wcDropped++;askKey('等待关键帧');return}wcWaiting=false}
 // A real backlog means this device decodes slower than it receives: skip to the next keyframe.
 // Judge by how long the oldest frame has waited, not by queue length: hardware decoders on
 // head units normally keep several frames in flight.
 const waited=submitted.length?performance.now()-submitted[0]:0;
 if(!key&&(waited>P.lagMs||submitted.length>P.queue)){wcWaiting=true;wcDropped++;submitted=[];askKey('解码积压');hitch('解码积压');return}
 try{decoder.decode(new EncodedVideoChunk({type:key?'key':'delta',timestamp:ts,data}));submitted.push(performance.now());bytesIn+=data.byteLength}
 catch(e){report('error','提交解码失败：'+e.message);recoverWC()}
}
function recoverWC(){
 if(!wcConfig)return;
 try{if(decoder&&decoder.state!=='closed')decoder.close()}catch(e){}
 startDecoder();askKey('解码器恢复');
}
function teardownWC(){
 wcGeneration++;
 try{if(decoder&&decoder.state!=='closed')decoder.close()}catch(e){}
 decoder=null;wcConfig=null;wcPending=[];wcConfiguring=false;
 // The canvas keeps the last picture while reconnecting.
}
// Packets keep arriving but nothing is drawn: the decoder is wedged.
setInterval(()=>{
 if(!useWebCodecs||!decoder||document.hidden||!shown)return;
 const now=performance.now();
 if(now-lastPacketAt<1000&&now-lastDrawAt>2000){report('info','WebCodecs 无输出，重建解码器');lastDrawAt=now;recoverWC()}
},500);

// ---------- MSE ----------
let media=null,source=null,objectURL='',mediaTag=null,mediaOpenTimer=0,queue=[],keyTimes=[],nextPts=0,frameSeconds=1/60;
let dropUntilKey=false,jumpOnKey=false,pendingJump=null,lastKeyAt=0,stallSince=0,lastTime=-1,lastQuality=null;
function bootMSE(then){
 try{
  const candidate=media=new MS();
  candidate.addEventListener('sourceopen',()=>{
   if(media!==candidate)return;
   clearTimeout(mediaOpenTimer);then()
  },{once:true});
  if(managedMSE){
   video.disableRemotePlayback=true;
   try{video.srcObject=candidate}catch(e){
    objectURL=URL.createObjectURL(candidate);
    mediaTag=document.createElement('source');mediaTag.type='video/mp4';mediaTag.src=objectURL;
    video.appendChild(mediaTag);video.load()
   }
   video.play().catch(e=>{
    if(media===candidate&&e.name==='NotAllowedError'&&video.paused)startPlayback.hidden=false
   });
   mediaOpenTimer=setTimeout(()=>{
    if(media===candidate&&video.paused)startPlayback.hidden=false
   },1500)
  }else{
   mediaOpenTimer=setTimeout(()=>restart('浏览器未能打开视频播放器'),5000);
   objectURL=URL.createObjectURL(candidate);video.src=objectURL
  }
 }catch(e){restart('无法启动视频播放器：'+e.message)}
}
startPlayback.onclick=()=>{
 if(!media||!video.paused)return;
 video.play().catch(e=>{
  if(!media||e.name==='AbortError')return;
  report('error','无法播放：'+e.message);
  setStatus('无法播放，请点「开始播放」重试','bad')
 })
};
function teardownMSE(){
 clearTimeout(mediaOpenTimer);
 startPlayback.hidden=true;
 source=null;queue=[];keyTimes=[];nextPts=0;dropUntilKey=false;jumpOnKey=false;pendingJump=null;stallSince=0;lastTime=-1;
 if(media){try{if(media.readyState==='open')media.endOfStream()}catch(e){}media=null}
 if(video.srcObject)video.srcObject=null;
 if(mediaTag){mediaTag.remove();mediaTag=null}
 if(objectURL){video.removeAttribute('src');try{video.load()}catch(e){}URL.revokeObjectURL(objectURL);objectURL=''}
}
function formatMSE(m){
 const mime=`video/mp4; codecs="${m.codec}"`,ok=MS.isTypeSupported(mime);
 report('info',`${navigator.userAgent.slice(0,140)}；MSE ${m.codec} 支持=${ok}`);
 if(!ok){
  report('error',`不支持 ${mime}`);holdFrame();teardown();
  setStatus(m.name==='H.265'?'此浏览器不支持 H.265。请在 CarWithin 改用 H.264 后重启 CarPlay。':'此浏览器不支持当前 H.264。请试用 720P、30 FPS，或更新车机浏览器。','bad');
  // Retry slowly: once the iPhone switches codec this page recovers by itself.
  if(!retryTimer)retryTimer=setTimeout(()=>{retryTimer=0;boot()},15000);return}
 try{source=media.addSourceBuffer(mime)}catch(e){restart('无法创建解码器：'+e.message);return}
 source.mode='sequence';frameSeconds=(m.duration||1500)/(m.timescale||90000);
 source.addEventListener('updateend',afterUpdate);
 source.addEventListener('error',()=>restart('解码缓冲区错误'));
 setStatus(`正在解码 ${m.name}…`);armFirstFrameTimer(m);
}
function onBinaryMSE(u){
 if(u.length<2)return;
 const timed=u[0]===4||u[0]===5;
 if(timed&&u.length<10)return;
 const kind=timed?u[0]-4:u[0],stamp=timed?packetTimestamp(u):null;
 if(dropUntilKey){if(kind===0)return;dropUntilKey=false}
 queue.push({kind,stamp,body:u.subarray(timed?9:1)});pump()}
function trim(force){
 const b=source.buffered;if(!b.length)return false;
 const start=b.start(0),now=video.currentTime;let cut=null;
 // Only cut up to a keyframe that stays in the buffer; everything after it decodes on its own.
 for(const k of keyTimes)if(k<=now-(force?0.05:1))cut=k;
 if(cut===null||cut-start<(force?0.1:4))return false;
 // Half a frame of margin: cut is a float sum and must never land past the IDR's own timestamp.
 source.remove(start,cut-frameSeconds/2);keyTimes=keyTimes.filter(k=>k>=cut);return true;
}
function pump(){
 if(!source||source.updating||!media||media.readyState!=='open')return;
 if(trim(false))return;
 const item=queue.shift();if(!item)return;
 try{
  source.appendBuffer(item.body);bytesIn+=item.body.byteLength;
  if(item.kind===1){keyTimes.push(nextPts);if(keyTimes.length>12)keyTimes.shift();lastKeyAt=performance.now();if(jumpOnKey){pendingJump=nextPts;jumpOnKey=false}}
  if(item.kind!==2){
   if(item.stamp!==null){
    mseAudioClock.set(Math.round(nextPts/frameSeconds),item.stamp);
    if(mseAudioClock.size>2400)mseAudioClock.delete(mseAudioClock.keys().next().value);
   }
   nextPts+=frameSeconds;
  }
 }catch(e){
  if(e.name==='QuotaExceededError'){
   queue.unshift(item);
   // Nothing safe to trim: drop to the next keyframe rather than append frames with missing references.
   if(!trim(true)){const i=queue.findIndex((x,n)=>n>0&&x.kind!==0);queue=i<0?[]:queue.slice(i);if(!queue.length)dropUntilKey=true;askKey('浏览器缓冲区已满');jumpOnKey=true}}
  else restart('写入解码器失败：'+e.message);
 }
}
function afterUpdate(){
 if(pendingJump!==null&&source&&source.buffered.length){const t=pendingJump;pendingJump=null;if(t>video.currentTime+0.1)video.currentTime=t+frameSeconds/2}
 if(video.paused)video.play().catch(e=>{if(managedMSE&&media&&e.name==='NotAllowedError')startPlayback.hidden=false});
 pump();
}
video.addEventListener('loadeddata',firstFrame);
video.addEventListener('playing',()=>{startPlayback.hidden=true;firstFrame();ensureAudioPlayback()});
video.addEventListener('error',()=>{
 if(useWebCodecs||!media)return;
 const e=video.error,codec=fmt?fmt.name:'视频';
 report('error',`${codec} 解码失败（${e?e.code:'?'} ${e&&e.message?e.message:''}）`);
 const hint=codec==='H.265'?'，可换浏览器或在 App 中改用 H.264':'，可换浏览器或调低分辨率和帧率';
 restart(`${codec} 解码失败${hint}`,false);
});
// Latency and stall control, 4 times per second.
setInterval(()=>{
 if(useWebCodecs||!source||!source.buffered.length)return;
 const b=source.buffered,end=b.end(b.length-1),now=video.currentTime,lag=end-now;
 if(now<b.start(0)-0.01){video.currentTime=b.start(0);return}
 const latest=keyTimes.length?keyTimes[keyTimes.length-1]:null;
 if(lag>P.jump){hitch('延迟过高');if(latest!==null&&latest>now+0.5)video.currentTime=latest+frameSeconds/2;else if(!jumpOnKey){jumpOnKey=true;askKey('延迟过高')}}
 video.playbackRate=lag>P.faster?1.5:lag>P.fast?1.15:1;
 // Playhead stuck although newer frames are buffered: the decoder is wedged.
 if(Math.abs(now-lastTime)<0.001&&lag>0.3&&!document.hidden){
  if(!stallSince)stallSince=performance.now();
  const stuck=performance.now()-stallSince;
  if(stuck>1500&&!jumpOnKey){video.play().catch(()=>{});jumpOnKey=true;askKey('播放停滞');hitch('播放停滞')}
  if(stuck>6000){stallSince=0;restart('播放停滞')}
 }else stallSince=0;
 lastTime=now;
 // CarPlay sends one IDR per session: ask for a fresh one now and then so old data can be trimmed.
 if(performance.now()-lastKeyAt>20000&&end-b.start(0)>25){lastKeyAt=performance.now();askKey('定期刷新缓冲')}
},250);

// ---------- stats ----------
let lastStatsAt=performance.now(),lastDrawn=0;
setInterval(()=>{
 const t=performance.now(),dt=(t-lastStatsAt)/1000;lastStatsAt=t;
 if(statsEl.hidden&&!debug){bytesIn=0;latencies=[];return}
 let lines;
 if(useWebCodecs){
  const sorted=latencies.slice().sort((a,b)=>a-b),p=q=>sorted.length?sorted[Math.min(sorted.length-1,Math.floor(q*sorted.length))].toFixed(0):'-';
  lines=[`${connectionProtocol} · ${fmt?fmt.name+' '+fmt.codec:'-'} · 性能 ${perfMode}`,`显示 ${((framesDrawn-lastDrawn)/dt).toFixed(0)} fps · 跳过 ${wcDropped} · 解码队列最大 ${maxQueue} · 卡顿 ${hitches.length}/30s`,
   `画面延迟 中位 ${p(0.5)} ms · P95 ${p(0.95)} ms · 绘制 ${drawCount?(drawMs/drawCount).toFixed(1):'-'} ms · RTT ${bestRtt<Infinity?(bestRtt/1000).toFixed(0):'-'} ms`,`码率 ${(bytesIn*8/dt/1e6).toFixed(1)} Mbps`];
  lastDrawn=framesDrawn;wcDropped=0;drawMs=0;drawCount=0;maxQueue=0;
 }else{
  const q=video.getVideoPlaybackQuality?video.getVideoPlaybackQuality():null;
  let fps='-',drop='-';if(q&&lastQuality){fps=((q.totalVideoFrames-lastQuality.totalVideoFrames)/dt).toFixed(0);drop=q.droppedVideoFrames-lastQuality.droppedVideoFrames}lastQuality=q;
  const b=source&&source.buffered.length?source.buffered:null,lag=b?Math.max(0,b.end(b.length-1)-video.currentTime):0,span=b?b.end(b.length-1)-b.start(0):0;
  lines=[`${connectionProtocol} · ${fmt?fmt.name+' '+fmt.codec:'-'} · 性能 ${perfMode}`,`显示 ${fps} fps · 丢帧 ${drop}`,`缓冲延迟 ${(lag*1000).toFixed(0)} ms · 倍速 ${video.playbackRate}`,`码率 ${(bytesIn*8/dt/1e6).toFixed(1)} Mbps · 缓存 ${span.toFixed(1)} s`];
 }
 const audio=audioStats();
 statsEl.textContent=lines.concat(audio).join('\n');bytesIn=0;latencies=[];
 // ?debug=1 mirrors the stats into the iPhone log every 5 s.
 if(debug&&++debugTick%5===0){
  report('info',lines.join(' | ')+` | 收=${received} 隐藏=${document.hidden}`);
  if(audio.length)report('info',audio.join(' | '));
 }
},1000);

// ---------- input ----------
const fingers=new Map();let nextFingerId=0;
function picture(){
 const el=useWebCodecs?view:video,r=el.getBoundingClientRect();
 const vw=(useWebCodecs?view.width:video.videoWidth)||16,vh=(useWebCodecs?view.height:video.videoHeight)||9;
 const s=Math.min(r.width/vw,r.height/vh),w=vw*s,h=vh*s;return{x0:r.left+(r.width-w)/2,y0:r.top+(r.height-h)/2,w,h}
}
function sendFingers(){
 const p=picture(),points=[];
 for(const f of fingers.values())points.push({id:f.id,x:Math.max(0,Math.min(1,(f.cx-p.x0)/p.w)),y:Math.max(0,Math.min(1,(f.cy-p.y0)/p.h))});
 send({type:'touches',points});
}
touchLayer.addEventListener('pointerdown',e=>{
 if(fingers.size>=10)return;
 try{touchLayer.setPointerCapture(e.pointerId)}catch(_){}
 const f={id:nextFingerId,cx:e.clientX,cy:e.clientY,dot:null};nextFingerId=(nextFingerId+1)&255;
 if(showTouches){f.dot=document.createElement('div');f.dot.className='tp';document.body.appendChild(f.dot);moveDot(f)}
 fingers.set(e.pointerId,f);
 sendFingers();e.preventDefault();wake();
});
function moveDot(f){if(f.dot){f.dot.style.left=f.cx+'px';f.dot.style.top=f.cy+'px'}}
touchLayer.addEventListener('pointermove',e=>{const f=fingers.get(e.pointerId);if(!f)return;f.cx=e.clientX;f.cy=e.clientY;moveDot(f);sendFingers()});
function lift(e){const f=fingers.get(e.pointerId);if(!f)return;if(f.dot)f.dot.remove();fingers.delete(e.pointerId);sendFingers()}
['pointerup','pointercancel','lostpointercapture'].forEach(n=>touchLayer.addEventListener(n,lift));
touchLayer.addEventListener('contextmenu',e=>e.preventDefault());
document.addEventListener('mousemove',wake);
document.addEventListener('visibilitychange',()=>{
 if(document.hidden)clearAudio();
 ensureAudioPlayback();
 if(document.hidden&&fingers.size){fingers.forEach(f=>{if(f.dot)f.dot.remove()});fingers.clear();send({type:'touches',points:[]})}
 if(!document.hidden&&useWebCodecs&&decoder){wcWaiting=true;askKey('页面回到前台')}
});
$('#full').onclick=()=>{const d=document.documentElement;(d.requestFullscreen||d.webkitRequestFullscreen||(()=>{})).call(d)};
function isFullscreen(){return !!(document.fullscreenElement||document.webkitFullscreenElement)}
function fullscreenChanged(){document.body.classList.toggle('fullscreen',isFullscreen());wake()}
document.addEventListener('fullscreenchange',fullscreenChanged);
document.addEventListener('webkitfullscreenchange',fullscreenChanged);
$('#statsButton').onclick=()=>{statsEl.hidden=!statsEl.hidden;preference('localStorage','carplays.stats',statsEl.hidden?'0':'1')};
if(preference('localStorage','carplays.stats')==='1'||debug)statsEl.hidden=false;
if(!canWebCodecs&&location.protocol==='https:')report('info','HTTPS 页面但浏览器没有 WebCodecs，使用 MSE');

// ---------- screen report ----------
// Pixel size, refresh rate and hardware H.265 support, so CarWithin can size CarPlay to this
// screen. Sent on connect and again when the window settles after a resize (fullscreen, split).
let refreshHz=0,h265Ok=null,resizeTimer=0;
function measureRefresh(){
 if(document.hidden)return;let n=0,t0=0;
 const step=t=>{if(!t0)t0=t;n++;if(t-t0<1000){requestAnimationFrame(step);return}
  refreshHz=Math.round((n-1)*1000/(t-t0));sendDisplay()};
 requestAnimationFrame(step);
}
async function probeH265(){
 const c='hvc1.1.6.L123.B0';
 try{if(useWebCodecs&&typeof VideoDecoder.isConfigSupported==='function'){const r=await VideoDecoder.isConfigSupported({codec:c,hardwareAcceleration:'prefer-hardware'});if(r.supported)return true}}catch(e){}
 try{return !!(MS&&MS.isTypeSupported(`video/mp4; codecs="${c}"`))}catch(e){return false}
}
function sendDisplay(){
 if(!receiverReady||!ws||ws.readyState!==1||h265Ok===null)return;
 const dpr=window.devicePixelRatio||1;
 send({type:'display',w:Math.round(innerWidth*dpr),h:Math.round(innerHeight*dpr),dpr,
  sw:Math.round(screen.width*dpr),sh:Math.round(screen.height*dpr),hz:refreshHz,h265:h265Ok,
  fullscreen:isFullscreen(),ua:navigator.userAgent.slice(0,160)});
}
probeH265().then(v=>{h265Ok=v;sendDisplay()});
measureRefresh();
window.addEventListener('resize',()=>{clearTimeout(resizeTimer);resizeTimer=setTimeout(sendDisplay,1500)});
boot();
</script></body></html>
"""#.utf8)
}
