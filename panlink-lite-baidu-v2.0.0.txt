// ==UserScript==
// @name         网盘直链下载助手 · 自用精简版
// @namespace    https://github.com/syhyz1990/baiduyun
// @version      2.0.0
// @description  百度本地下载管理器：持久队列、任务接管、动态并行、错误恢复
// @author       Based on PanLink Lite by limousine-tony / YouXiaoHou; local adaptation
// @license      AGPL-3.0-or-later
// @match        https://pan.baidu.com/disk/main*
// @match        https://pan.baidu.com/disk/home*
// @match        https://yun.baidu.com/disk/main*
// @match        https://yun.baidu.com/disk/home*
// @match        https://openapi.baidu.com/*
// @noframes
// @connect      pan.baidu.com
// @connect      openapi.baidu.com
// @connect      localhost
// @connect      127.0.0.1
// @grant        GM_xmlhttpRequest
// @grant        GM_getValue
// @grant        GM_setValue
// @grant        GM_setClipboard
// @grant        GM_registerMenuCommand
// @grant        GM_cookie
// @grant        unsafeWindow
// @run-at       document-idle
// ==/UserScript==
/*
 * Build: hardened-20261125; version intentionally remains 2.0.0.
 * Modified 2026-11-25, Baidu-only replacement; not an upstream release.
 * Based on https://github.com/limousine-tony/panlink-lite (v1.8.1), AGPL-3.0-or-later.
 * License: https://www.gnu.org/licenses/agpl-3.0.html
 * Retains upstream script identity, configuration keys, selected-file adapter and
 * OAuth client ID. Does not send credentials to any external relay.
 * Do not use on files you are not authorized to download.
 */
(() => {
  'use strict';
  if (window.top !== window.self) return;
  const UA = 'pan.baidu.com';
  const AUTH = 'https://openapi.baidu.com/oauth/2.0/authorize?client_id=cFjj1cCYQwIr7Sk1v6EA0rYDpI9qk6fx&response_type=token&redirect_uri=oob&confirm_login=0&scope=basic,netdisk';
  const TOKEN_KEY = 'baidu_access_token', OAUTH_PENDING='local_oauth_pending', TOKEN_EXPIRY='local_oauth_expiry', DONE_KEY = 'local_batch_completed';
  const defaults = {rpcDomain:'http://localhost',rpcPort:'16800',rpcPath:'/jsonrpc',rpcToken:'',rpcDir:'',bduss:'',local_parallel:'3',local_connections:'4',local_adaptive:'false',local_max_parallel:'5',local_speed_limit:'0',local_auto_resume:'false',local_verify_source:'false'};
  const cfg = k => GM_getValue(k, defaults[k]);
  const sleep = ms => new Promise(r => setTimeout(r, ms));
  const msg = e => e instanceof Error ? e.message : '请求异常，请检查 RPC 或百度授权';
  const err = (s,kind='') => Object.assign(new Error(s),{kind});
  const transient=e=>e?.kind==='transport'||e?.kind==='temporary';
  const copy = s => GM_setClipboard(s, 'text');
  const isHome = () => /^\/disk\/(main|home)(?:\/|$)/.test(location.pathname);
  const isBaidu = () => ['pan.baidu.com','yun.baidu.com'].includes(location.hostname);
  let running=false, stop=false, last='尚未开始', view=null, logBox=null;

  // OAuth callback is intentionally restricted to the official host.
  if (location.hostname === 'openapi.baidu.com') {
    const hash=new URLSearchParams(location.hash.slice(1)),query=new URLSearchParams(location.search);
    const access=hash.get('access_token')||query.get('access_token');
    const returned=hash.get('state')||query.get('state'),pending=GM_getValue(OAUTH_PENDING,null);
    if(access){if(!pending||returned!==pending.nonce||Date.now()-pending.at>900000){alert('授权回调不匹配或超时，旧授权保留。请从管理器重新授权。');return;}const seconds=Number(hash.get('expires_in')||query.get('expires_in')||0);GM_setValue(TOKEN_KEY,access);GM_setValue(TOKEN_EXPIRY,Number.isFinite(seconds)&&seconds>0?Date.now()+seconds*1000:0);GM_setValue(OAUTH_PENDING,null);alert('百度授权已保存。请返回网盘页面。');}
    return;
  }
  if (!isBaidu() || !isHome()) return;
  // Web Locks are origin-scoped. All queue mutations use the canonical origin.
  if(location.hostname !== 'pan.baidu.com') { GM_registerMenuCommand('打开百度下载管理器',()=>window.open('https://pan.baidu.com/disk/main','_blank','noopener')); return; }

  function request(url, method='GET', data, headers={}) {
    return new Promise((resolve, reject) => {
      GM_xmlhttpRequest({url, method, headers, ...(method==='POST'?{redirect:'error'}:{}), data: data === undefined ? undefined : JSON.stringify(data), responseType:'json', timeout:30000,
        onload:r=>{
          if(method==='POST'&&r.finalUrl&&new URL(r.finalUrl).origin!==new URL(url).origin)return reject(err('RPC 重定向已拒绝'));
          if (r.status<200 || r.status>=300) return reject(err(`HTTP ${r.status}（请求失败）`,[408,500,502,503,504].includes(r.status)?'temporary':'http'));
          try { resolve(typeof r.response==='string' ? JSON.parse(r.response) : r.response ?? JSON.parse(r.responseText)); }
          catch { reject(err('响应不是有效 JSON')); }
        },onerror:()=>reject(err('无法连接服务，请检查网络与 RPC 端口','transport')),ontimeout:()=>reject(err('请求超时','transport')),
        onabort:()=>reject(err('请求已取消'))});
    });
  }
  function rpcEndpoint() {
    const url = new URL(`${cfg('rpcDomain')}:${cfg('rpcPort')}${cfg('rpcPath')}`);
    if (url.protocol!=='http:' || !['localhost','127.0.0.1'].includes(url.hostname) || url.username || url.password || url.search || url.hash) throw err('RPC 仅允许本机 HTTP 服务');
    if (!cfg('rpcToken')) throw err('请先设置 RPC 密钥');
    return url.href;
  }
  async function rpc(method, params=[]) {
    const r = await request(rpcEndpoint(),'POST',{jsonrpc:'2.0',id:Date.now(),method,params:[`token:${cfg('rpcToken')}`,...params]},{'Content-Type':'application/json'});
    if (!r || r.error || !Object.prototype.hasOwnProperty.call(r,'result')) { const missing=method==='aria2.tellStatus'&&/not found|no such gid/i.test(String(r?.error?.message||'')); throw err(`RPC ${method} 失败（${r?.error?.code ?? '无有效响应'}）；检查密钥、路径或任务状态`,missing?'missing':'rpc'); }
    return r.result;
  }
  function authorize() { const nonce=Array.from(crypto.getRandomValues(new Uint8Array(16)),b=>b.toString(16).padStart(2,'0')).join('');GM_setValue(OAUTH_PENDING,{nonce,at:Date.now()});window.open(AUTH+'&state='+nonce,'_blank','noopener,noreferrer'); }
  function token() {
    const t=GM_getValue(TOKEN_KEY,'');
    if (!t) throw err('尚未授权；请从菜单打开百度授权，然后重新开始','auth');const expires=Number(GM_getValue(TOKEN_EXPIRY,0));if(expires&&Date.now()>=expires)throw err('百度授权已过期，请重新授权','auth');
    return t;
  }
  async function api(path, params) {
    const activeToken=token();
    if(boundToken&&activeToken!==boundToken)throw err('授权已变更，请停止并重新确认帐号','auth');
    const q=new URLSearchParams({...params,access_token:activeToken});
    const res=await request(`https://pan.baidu.com/rest/2.0/xpan/${path}?${q}`,'GET',undefined,{'User-Agent':UA});
    if ([-6,110,111,9019].includes(Number(res?.errno))) throw err(`百度授权失效（${res.errno}），请重新授权`,'auth');
    if (Number(res?.errno)!==0) throw err(`百度 API 错误：${res?.errno ?? '无有效响应'}`);
    if(token()!==activeToken)throw err('授权已变更，请重新确认帐号','auth');
    return res;
  }
  let boundToken=null;
  async function bindAccount(){
    const t=token();if(boundToken){if(t!==boundToken)throw err('授权已变更，请重新确认帐号','auth');return state.account;}const info=await api('nas',{method:'uinfo'});
    const account=String(info.uk??'');if(!/^\d+$/.test(account))throw err('无法验证百度帐号','auth');
    let page='';try{page=String(unsafeWindow.locals?.uk??unsafeWindow.userInfo?.uk??'');}catch{}
    if(/^\d+$/.test(page)&&page!==account)throw err('网页帐号与 OAuth 帐号不一致，请重新授权','auth');
    if(state.account&&state.account!==account)throw err('当前授权帐号与原队列不一致；不会提交任务','auth');
    if(!state.account&&state.jobs.length&&!confirm('旧队列没有帐号绑定。确认这些文件属于当前百度帐号？'))throw err('未确认旧队列帐号','auth');
    if(token()!==t)throw err('授权已变更，请重新确认帐号','auth');state.account=account;boundToken=t;save();return account;
  }
  function bduss() {
    if(cfg('bduss')) return Promise.resolve(cfg('bduss'));
    return new Promise(resolve=>{
      let ended=false; const end=v=>{if(!ended){ended=true;resolve(v||'');}};
      setTimeout(()=>end(''),3000);
      try { GM_cookie('list',{name:'BDUSS'},(cookies,error)=>end(!error&&cookies?.[0]?.value)); } catch { end(''); }
    });
  }
  function selected() {
    try {const req=unsafeWindow.require || window.require;return req('system-core:context/context.js').instanceForSystem.list.getSelected() || [];}
    catch {try {return document.querySelector('.wp-s-core-pan').__vue__.selectedList || [];}catch{return [];}}
  }
  function safeName(value) {
    // Same filename transformation as upstream, plus Windows safety checks.
    const s=String(value??'').replace(/[!?&|`"'*/:<>\\\x00-\x1f]/g,'_').replace(/[. ]+$/g,'');
    if(!s || s==='.' || s==='..' || /^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)/i.test(s)) throw err('不支持的 Windows 文件名');
    return s;
  }
  function rootPath() {
    const root=String(cfg('rpcDir')||'').trim().replace(/\\/g,'/').replace(/\/+$/,'');
    if(!/^[A-Za-z]:\/.+/.test(root) || root.slice(3).split('/').some(p=>!p||p!==safeName(p))) throw err('请设置 Windows 绝对保存目录，例如 C:/AI-Shared/BaiduDownload');
    return root;
  }
  async function fetchLink(raw) {
    const id=String(raw.fs_id??'');
    if(!/^\d+$/.test(id)) throw err('文件 ID 无效');
    const res=await api('multimedia',{method:'filemetas',dlink:'1',fsids:`[${id}]`});
    const v=res.list?.find(v=>String(v.fs_id)===id);
    if(!v?.dlink) throw err('未取得下载链接');
    if(v.size!=null&&raw.size!=null&&String(v.size)!==String(raw.size))throw err('来源文件大小已变更','source');
    if(v.server_mtime!=null&&raw.server_mtime&&String(v.server_mtime)!==String(raw.server_mtime))throw err('来源文件版本已变更','source');if(v.path&&raw.path&&String(v.path)!==String(raw.path))throw err('来源文件路径已变更','source');
    const url=new URL(v.dlink);
    if(url.protocol!=='https:' || !/(^|\.)(baidu\.com|baidupcs\.com)$/.test(url.hostname)) throw err('下载地址不是受信任的百度 HTTPS 域名');
    // Preserve the exact signed URL; URLSearchParams serialization can change its encoding.
    const link = url.searchParams.has('access_token') ? v.dlink : v.dlink + (v.dlink.includes('?')?'&':'?') + 'access_token=' + encodeURIComponent(token());
    const b=await bduss();if(boundToken&&token()!==boundToken)throw err('授权已变更，请重新确认帐号','auth');if(/[\r\n]/.test(b))throw err('BDUSS 格式无效');
    return {link,md5:/^[a-f0-9]{32}$/i.test(String(v.md5||''))?String(v.md5).toLowerCase():null,headers:[`User-Agent: ${UA}`,...(b?[`Cookie: BDUSS=${b}`]:[])]};
  }
  async function scan(items, relative='',depth=0,seen=new Set()) {
    if(depth>50) throw err('目录层级超过 50');
    const out=[];
    for(const raw of items){
      if(stop) break;
      const name=safeName(raw.server_filename||raw.filename);
      if(+raw.isdir!==1){out.push({raw,name,relative});if(out.length>LIMIT)throw err('扫描超过 20000 个文件');continue;}
      const path=String(raw.path||'');
      if(!path.startsWith('/')) throw err('无法取得目录路径；请进入目录并选择文件');
      if(seen.has(path)) throw err('目录重复，请勿重复选择父目录与子目录');
      seen.add(path);
      const rel=relative?`${relative}/${name}`:name;
      let start=0; const limit=100; let lastPage='';
      while(!stop){
        const res=await api('file',{method:'list',dir:path,start:String(start),limit:String(limit),order:'name',desc:'0'});
        if(!Array.isArray(res.list)) throw err('目录列表无效');
        if(!res.list.length) break;
        const page=res.list.map(x=>String(x.fs_id)).join(',');
        if(page===lastPage) throw err('目录分页重复，已停止以避免重复任务');
        lastPage=page;
        out.push(...await scan(res.list,rel,depth+1,seen));if(out.length>LIMIT)throw err('扫描超过 20000 个文件');
        start+=res.list.length;
        if(res.list.length<limit) break;
        await sleep(800);
      }
    }
    return out;
  }
  function num(k,min,max){const n=Number(cfg(k));return Number.isInteger(n)?Math.max(min,Math.min(max,n)):min;}
  const QUEUE='local_batch_queue_v2', LOCK='panlink-baidu-v2-manager', LIMIT=20000;
  const FIELDS=['gid','status','totalLength','completedLength','downloadSpeed','errorCode','errorMessage','files','dir'];
  const MiB=1048576, size=n=>`${(Number(n||0)/MiB).toFixed(2)} MiB`;
  const actions=[];
  function queueAction(fn){return new Promise((resolve,reject)=>actions.push({fn,resolve,reject}));}
  async function drainActions(){while(actions.length){const a=actions.shift();try{a.resolve(await a.fn());}catch(e){a.reject(e);}}}
  let state=null, controls=null, currentParallel=3, rate=0, samples=[], sampleAt=0, speedIntegral=0, speedSeconds=0, started=0, baselineBytes=0, scanning=false, locked=false, adaptiveState=null;
  const fresh=()=>({version:2,root:String(cfg('rpcDir')||'').trim().replace(/\\/g,'/').replace(/\/+$/,''),jobs:[],account:null,runIntent:false,hold:false,reason:'',rpcLease:null,updated:Date.now()});
  function readQueue(){const q=GM_getValue(QUEUE,null);if(!q)return fresh();if(q.version!==2||!Array.isArray(q.jobs)||q.jobs.length>LIMIT)throw err('队列格式无效；请勿覆盖，先导出备份');const paths=new Set();for(const j of q.jobs){if(!j||!j.raw||!['pending','active','waiting','paused','submitting','uncertain','done','legacy','error','cancelled'].includes(j.status)||j.name!==safeName(j.name)||j.relative&&j.relative.split('/').some(p=>p!==safeName(p))||j.path!==target(q.root,j)||!/^\d+$/.test(String(j.raw.fs_id))||!/^\d+$/.test(String(j.raw.size))||!Number.isSafeInteger(Number(j.raw.size))||paths.has(pathKey(j.path)))throw err('队列任务格式或路径无效');paths.add(pathKey(j.path));}return q;}
  function save(){state.updated=Date.now();GM_setValue(QUEUE,state);}
  const pathKey=p=>String(p||'').replace(/\\/g,'/').replace(/\/+$/,'').toLowerCase();
  const target=(root,f)=>`${root}/${f.relative?f.relative+'/':''}${f.name}`;
  const keyFor=(root,f)=>JSON.stringify([root,f.relative,f.name,String(f.raw.fs_id),String(f.raw.size),String(f.raw.server_mtime||'')]);
  const live=j=>['active','submitting','waiting','paused','uncertain'].includes(j.status);
  const occupied=j=>['active','waiting','submitting'].includes(j.status);
  const doneKey=j=>JSON.stringify([state.account,j.key]);
  function newJob(f,root){if(f.name!==safeName(f.name)||f.relative&&f.relative.split('/').some(p=>p!==safeName(p)))throw err('不安全的相对路径');const raw={fs_id:String(f.raw.fs_id??''),size:String(f.raw.size??''),server_mtime:String(f.raw.server_mtime||''),path:String(f.raw.path||'')};if(!/^\d+$/.test(raw.fs_id)||!/^\d+$/.test(raw.size)||!Number.isSafeInteger(Number(raw.size)))throw err('文件元数据无效');const j={raw,name:f.name,relative:f.relative,key:keyFor(root,{...f,raw}),path:target(root,f),status:'pending',gid:null,bytes:0,speed:0,attempts:0,retryAt:0,note:''};return j;}
  function makeGid(){return Array.from(crypto.getRandomValues(new Uint8Array(8)),b=>b.toString(16).padStart(2,'0')).join('');}
  function opts(j,l){const n=String(num('local_connections',1,4));const hash=cfg('local_verify_source')==='true'&&/^[a-f0-9]{32}$/i.test(l.md5||'')?{'checksum':`md5=${l.md5}`,'check-integrity':'true'}:{};return {...hash,gid:j.gid,out:j.name,dir:j.relative?`${state.root}/${j.relative}`:state.root,header:l.headers,continue:'true','auto-file-renaming':'false','allow-overwrite':'false','max-connection-per-server':n,split:n,'min-split-size':'1M','max-tries':'2','retry-wait':'15'};}
  function linkExpires(url,now=Date.now()){const q=new URL(url).searchParams,ex=q.get('expires'),stamp=q.get('dstime');if(!ex)return 0;if(/^\d+[hms]$/.test(ex)&&/^\d{10}$/.test(stamp||'')){const m={h:3600,m:60,s:1}[ex.slice(-1)];return Number(stamp)*1000+Number(ex.slice(0,-1))*m*1000;}if(/^\d{10}$/.test(ex))return Number(ex)*1000;return 0;}
  function statusNote(s){const m=String(s.errorMessage||'');const http=m.match(/(?:status\s*[=:]\s*|HTTP\s+)([1-5]\d\d)/i);return http?`HTTP ${http[1]} (aria2 ${s.errorCode||'?'})`:`aria2 ${s.errorCode||s.status||'未知'}`;}
  function failureType(s){const m=statusNote(s);if(/HTTP (403|429|401)/.test(m))return 'hold';if(/HTTP (404|410)/.test(m)||['3','4'].includes(String(s.errorCode)))return 'missing';if(/HTTP (408|500|502|503|504)/.test(m)||['2','5','6','19','29'].includes(String(s.errorCode)))return 'retry';return 'hold';}
  function matches(j,s){const files=s.files||[];return files.length===1&&pathKey(files[0].path)===pathKey(j.path)&&Number(s.totalLength)===Number(j.raw.size);}
  function matchesKnown(j,s){return (s.files||[]).length===1&&pathKey(s.files[0].path)===pathKey(j.path)&&(Number(s.totalLength)===0||Number(s.totalLength)===Number(j.raw.size));}
  function markHold(note){state.hold=true;state.runIntent=false;state.reason=note;save();}
  function settle(j,s){j.bytes=Number(s.completedLength||0);j.speed=Number(s.downloadSpeed||0);if(s.status==='complete'){
      if(!matches(j,s)||j.bytes!==Number(j.raw.size)){j.status='error';j.note='完成大小或目标路径不一致';markHold(j.note);return;}
      j.status='done';j.note='大小已核对，尚未校验本地内容';j.speed=0;const done=GM_getValue(DONE_KEY,{})||{};done[doneKey(j)]=Date.now();GM_setValue(DONE_KEY,done);return;
    }
    if(['active','waiting','paused'].includes(s.status)){if(!matchesKnown(j,s)){j.status='uncertain';j.note='GID 目标不符，暂停以防覆盖';markHold(j.note);return;}j.status=s.status;if(s.status!=='active')j.speed=0;j.note=s.status==='paused'?'Aria2 已暂停，可在恢复时继续':'';return;}
    if(['error','removed'].includes(s.status)){j.speed=0;j.note=statusNote(s);j.gid=null;if(j.cancelRequested&&s.status==='removed'){j.status='cancelled';j.cancelRequested=false;return;}if(s.status==='error'&&/HTTP 410/.test(j.note)&&j.linkDeadline&&Date.now()>=j.linkDeadline&&j.attempts<3&&!state.hold){j.status='pending';j.retryAt=Date.now()+30000;j.note+='；已知直链过期，稍后重新取链';return;}if(s.status==='error'&&failureType(s)==='missing'){j.status='error';j.note+='；来源不可用，继续其他文件';return;}if(s.status==='error'&&failureType(s)==='retry'&&j.attempts<3&&!state.hold){j.status='pending';j.retryAt=Date.now()+30000*Math.max(1,j.attempts);j.note+='；稍后重新取链';}else{j.status='error';markHold(`${j.name}：${j.note}；请检查后手动恢复`);}return;}
    j.status='uncertain';j.note='未知任务状态';markHold(j.note);
  }
  async function allRPC(){const a=await rpc('aria2.tellActive',[FIELDS]);const w=[];for(let off=0;;off+=100){const p=await rpc('aria2.tellWaiting',[off,100,FIELDS]);w.push(...p);if(p.length<100)break;if(off>=LIMIT)throw err('RPC 排队任务过多');}return [...a,...w];}
  async function reconcile(){const tasks=await allRPC();const map=new Map(tasks.map(s=>[s.gid,s]));const owned=new Set();
    for(const j of state.jobs.filter(live)){
      let s=map.get(j.gid);if(!s&&j.gid){try{s=await rpc('aria2.tellStatus',[j.gid,FIELDS]);}catch(e){ // Only treat the explicit GID-not-found RPC response as unresolved; network errors propagate via global stat.
          if(e.kind!=='missing')throw e;j.status='uncertain';j.speed=0;j.note='任务记录不可查询；检查本地文件及 Aria2 后手动重试';markHold(j.note);continue;}}
      if(s){owned.add(s.gid);settle(j,s);}else{j.status='uncertain';j.note='提交状态不明';markHold(j.note);}
    }
    const external=tasks.filter(s=>!owned.has(s.gid));save();return external;
  }
  async function submit(j){j.gid=makeGid();j.status='submitting';j.attempts++;j.note='正在取得授权链接';save();
    let l;try{l=await fetchLink(j.raw);j.sourceMd5=l.md5||null;j.linkDeadline=linkExpires(l.link);if(j.linkDeadline&&j.linkDeadline<=Date.now())throw err('新取得的直链已过期','temporary');}catch(e){j.gid=null;j.note=msg(e);if(transient(e)&&j.attempts<3){j.status='pending';j.retryAt=Date.now()+30000*j.attempts;save();}else{j.status='error';markHold(j.note);}return;}
    if(stop||state.hold){j.status='pending';j.gid=null;j.attempts--;save();return;}
    try{const gid=await rpc('aria2.addUri',[[l.link],opts(j,l)]);if(gid!==j.gid)throw err('RPC 返回的 GID 与预期不同');j.status='active';j.note='';save();}
    catch(e){j.status='uncertain';j.note='提交结果不确定；保留 GID，禁止盲目重复提交';markHold(j.note);}
    await sleep(500);
  }
  async function withLock(fn){if(!navigator.locks?.request){alert('浏览器不支持 Web Locks，无法安全管理跨分頁队列');return;}if(locked){alert('本分頁已有管理操作');return;}
    try{await navigator.locks.request(LOCK,{mode:'exclusive',ifAvailable:true},async lock=>{if(!lock){alert('其他百度分頁正在管理下载，请到该分頁操作');return;}locked=true;try{state=readQueue();await fn();}finally{locked=false;boundToken=null;}});}catch(e){last=msg(e);render();alert(last);}}
  function addFiles(files){const seen=new Map(state.jobs.map(j=>[pathKey(j.path),j]));const done=GM_getValue(DONE_KEY,{})||{};let added=0;const incoming=[];const hasOld=!!state.account&&files.some(f=>done[keyFor(state.root,f)]&&!done[JSON.stringify([state.account,keyFor(state.root,f)])]);const acceptOld=hasOld&&confirm('发现旧版未绑定帐号的完成记录。确认属于当前帐号，且本地文件仍存在？不确认将不自动跳过。');
    for(const f of files){const j=newJob(f,state.root),prev=seen.get(pathKey(j.path));if(prev){if(prev.key!==j.key)throw err('目标路径冲突：'+j.name);continue;}if(done[doneKey(j)]||(acceptOld&&done[j.key])){j.status='legacy';j.note='旧完成记录；本地存在性未验证';j.bytes=Number(j.raw.size);}seen.set(pathKey(j.path),j);incoming.push(j);added++;}
    if(state.jobs.length+incoming.length>LIMIT)throw err('队列超过 20000 个文件');state.jobs.push(...incoming);save();return added;}
  async function appendSelection(){if(scanning)return;const picked=selected();if(!picked.length){alert('请先勾选文件或文件夹');return;}scanning=true;try{await bindAccount();const root=rootPath();if(state.jobs.length&&pathKey(root)!==pathKey(state.root))throw err('保存目录已改变，请先完成或清空旧队列');state.root=root;if(running&&stop)throw err('正在停止，请等当前批次结束');if(!running)stop=false;const files=await scan(picked);if(stop)throw err('扫描已停止，未加入部分清单');if(!files.length)throw err('没有可加入的文件');if(!confirm(`扫描到 ${files.length} 个文件，加入持久队列？`))return;const n=addFiles(files);last=`新增 ${n} 个文件；重复选择已跳过`;render();return true;}catch(e){last=msg(e);render();alert(last);}finally{scanning=false;}}
  async function adoptExternal(){
    const ext=await reconcile();const candidates=[];
    for(const s of ext){const matchesJobs=state.jobs.filter(j=>['pending','error','uncertain'].includes(j.status)&&matches(j,s));
      if(matchesJobs.length!==1)continue;const j=matchesJobs[0];
      if(ext.filter(t=>t.files?.some(f=>pathKey(f.path)===pathKey(j.path))).length!==1)continue;
      candidates.push([j,s]);}
    if(candidates.length&&confirm(`找到 ${candidates.length} 个目标路径及大小一致的既有任务。确认这些是同一来源文件，接管它们？`)){for(const [j,s] of candidates){j.gid=s.gid;settle(j,s);}save();}
    return ext.filter(s=>!candidates.some(([j,t])=>j.gid===t.gid&&t.gid===s.gid)).length;
  }
  function limitValue(){const n=Number(cfg('local_speed_limit'));if(!Number.isFinite(n)||n<0||n>1024)throw err('总速度上限范围 0–1024 MiB/s');return String(Math.round(n*1048576));}
  async function restoreLease(){const lease=state.rpcLease;if(!lease)return;if(lease.endpoint&&lease.endpoint!==rpcEndpoint())throw err('RPC 端点不一致，无法恢复旧设置');const now=await rpc('aria2.getGlobalOption');const patch={};for(const k of Object.keys(lease.old)){const a=String(now[k]??'0'),b=String(lease.applied[k]??'0');if(a===b)patch[k]=lease.old[k];}if(Object.keys(patch).length)await rpc('aria2.changeGlobalOption',[patch]);state.rpcLease=null;save();}
  async function configure(n){const options={'max-concurrent-downloads':String(n),'max-overall-download-limit':limitValue()};if(!state.rpcLease){const old=await rpc('aria2.getGlobalOption');state.rpcLease={endpoint:rpcEndpoint(),old:Object.fromEntries(Object.keys(options).map(k=>[k,String(old[k]??'0')])),applied:{}};}Object.assign(state.rpcLease.applied,options);save();await rpc('aria2.changeGlobalOption',[options]);currentParallel=n;}

  function recordRate(v,now=Date.now()){if(sampleAt){const dt=Math.max(0,Math.min(10,(now-sampleAt)/1000));speedIntegral+=v*dt;speedSeconds+=dt;}sampleAt=now;samples.push(v);if(samples.length>100)samples.shift();}
  function metric(){return state.jobs.reduce((a,j)=>a+Math.min(Number(j.raw.size),Number(j.bytes||0)),0);}
  async function adapt(external){if(cfg('local_adaptive')!=='true'||state.hold||stop||external.length)return;const cap=num('local_max_parallel',3,5),now=Date.now();const activeCount=state.jobs.filter(j=>j.status==='active').length;if(activeCount<currentParallel||!state.jobs.some(j=>j.status==='pending')){return;}
    if(!adaptiveState)adaptiveState={at:now,rates:[],prior:0,priorN:currentParallel};if(adaptiveState.finished)return;if(adaptiveState.prior===0&&currentParallel>=cap)return;adaptiveState.rates.push(rate);if(adaptiveState.rates.length>120)adaptiveState.rates.shift();if(adaptiveState.rates.length<40||now-adaptiveState.at<120000)return;const measured=adaptiveState.rates.reduce((a,b)=>a+b,0)/adaptiveState.rates.length;const a=adaptiveState;if(a.prior>0&&measured<a.prior*1.10){await configure(a.priorN);adaptiveState={at:now,rates:[],prior:0,priorN:currentParallel,finished:true};return;}if(a.finished||currentParallel>=cap)return;const old=currentParallel;await configure(old+1);adaptiveState={at:now,rates:[],prior:measured,priorN:old};}
  async function runQueue(){if(running)return;running=true;stop=false;started=Date.now();baselineBytes=metric();samples=[];sampleAt=0;speedIntegral=0;speedSeconds=0;adaptiveState=null;let retries=0;render();try{
    if(pathKey(rootPath())!==pathKey(state.root))throw err('队列目录与设置不一致');await bindAccount();await rpc('aria2.getVersion');await restoreLease();const ext=await adoptExternal();if(ext){markHold(`还有 ${ext} 个未接管的 Aria2 任务；请等它们完成或确认接管`);return;}
    if(state.hold)return;state.runIntent=true;save();await configure(num('local_parallel',1,5));
    while(true){try{
      await drainActions();
      const external=await reconcile();if(retries&&state.rpcLease&&!external.length){const actual=await rpc('aria2.getGlobalOption');const desired=state.rpcLease.applied;for(const k of Object.keys(desired)){const value=String(actual[k]??'0');if(value!==String(desired[k])&&value!==String(state.rpcLease.old[k]))throw err('RPC 设置已被外部修改，暂停以避免冲突');}if(Object.keys(desired).some(k=>String(actual[k]??'0')!==String(desired[k])))await rpc('aria2.changeGlobalOption',[desired]);}if(external.length&&!state.hold)markHold('发现其他 Aria2 任务，停止新增以防冲突');retries=0;
      rate=state.jobs.reduce((a,j)=>a+(j.status==='active'?Number(j.speed||0):0),0);recordRate(rate);render();
      const owned=state.jobs.filter(occupied);
      if(stop||state.hold){if(!owned.length&&!scanning)break;await sleep(3000);continue;}
      await adapt(external);
      let slots=Math.max(0,currentParallel-owned.length);
      while(slots-->0&&!stop&&!state.hold){const j=state.jobs.find(j=>j.status==='pending'&&j.retryAt<=Date.now());if(!j)break;await submit(j);render();}
      if(!state.jobs.some(j=>['pending','active','waiting','submitting'].includes(j.status))&&!scanning)break;
      await sleep(3000);
    }catch(e){if(!transient(e)||++retries>5||stop)throw e;rate=0;last=`RPC 暂时断开，重连 ${retries}/5`;render();await sleep(Math.min(60000,5000*2**(retries-1)));}}
  }catch(e){markHold(msg(e));last='管理器暂停：'+msg(e);}finally{if(state.rpcLease){try{await restoreLease();}catch{last='RPC 已断开；已保存原配置，恢复时重试';}}state.runIntent=false;save();running=false;while(actions.length)actions.shift().reject(err('管理器已结束，请重新操作'));rate=0;if(!state.hold)last=state.jobs.some(j=>j.status==='pending')?'尚有待下载任务':'本次运行已结束';render();}}

  async function startBatch(){showProgress();if(locked){if(running){await appendSelection();return;}return;}await withLock(async()=>{const added=await appendSelection();if(added&&!state.hold&&state.jobs.some(j=>j.status==='pending'||live(j)))await runQueue();});}
  async function resumeQueue(){showProgress();if(locked){alert('管理器仍在运行或等待当前任务完成');return;}await withLock(async()=>{await bindAccount();const ext=await adoptExternal();if(ext){markHold(`仍有 ${ext} 个未接管任务；不会恢复或新增`);render();return;}if(state.jobs.some(j=>j.status==='uncertain')){last='有状态不明的任务，请先使用检查/重试功能';render();return;}if(state.jobs.some(j=>j.status==='error'&&j.verified&& !['HashMatch','SizeMatch'].includes(j.verified))){if(!confirm('有本地校验失败的文件。确认已备份或移走有问题的本地文件（如需续传则保留正确的 .aria2），并已排除磁盘/权限问题？'))return;}if(state.jobs.some(j=>j.status==='error')){if(!confirm('确认已检查错误、授权与服务器限制？将失败项重新取得直链并续传。'))return;for(const j of state.jobs.filter(j=>j.status==='error')){j.status='pending';j.attempts=0;j.retryAt=0;j.note='';j.verified=null;}}for(const j of state.jobs.filter(j=>j.status==='paused')){const status=await rpc('aria2.tellStatus',[j.gid,FIELDS]);if(!matchesKnown(j,status))throw err('暂停任务目标不一致');await rpc('aria2.unpause',[j.gid]);j.status='waiting';}state.hold=false;state.reason='';save();await runQueue();});}
  async function resolveUncertain(){await withLock(async()=>{await bindAccount();await reconcile();const bad=state.jobs.filter(j=>j.status==='uncertain');if(!bad.length){render();return;}const ext=await allRPC();if(bad.some(j=>ext.some(s=>s.gid===j.gid||s.files?.some(f=>pathKey(f.path)===pathKey(j.path)))))throw err('状态不明任务仍在 Aria2，请先检查，不会重复提交');if(!confirm(`有 ${bad.length} 个任务无法查询。请确认本地文件与 .aria2 控制文件仍在，且未完成文件不被其他程序写入。将它们标为待重试？已完整文件不会自动覆盖。`))return;for(const j of bad){j.gid=null;j.status='pending';j.attempts=0;j.retryAt=0;j.note='待人工确认后重试';}save();render();});}
  async function jobAction(key,action){const work=async()=>{await bindAccount();const j=state.jobs.find(x=>x.key===key);if(!j||!j.gid||!['active','waiting','paused'].includes(j.status))throw err('任务状态已变化');const s=await rpc('aria2.tellStatus',[j.gid,FIELDS]);if(!matchesKnown(j,s))throw err('GID 目标不一致');if(action==='cancel'){if(!confirm('取消任务但保留已下载文件？'))return;j.cancelRequested=true;save();try{await rpc('aria2.remove',[j.gid]);}catch(e){j.cancelRequested=false;save();throw e;}}else if(action==='pause'){await rpc('aria2.pause',[j.gid]);}else if(action==='resume'){await rpc('aria2.unpause',[j.gid]);}await reconcile();render();};if(locked&&running)await queueAction(work);else await withLock(work);}
  async function pauseAll(){const work=async()=>{await bindAccount();stop=true;state.hold=true;state.runIntent=false;state.reason='用户暂停全部管理任务';save();const active=await allRPC();for(const j of state.jobs.filter(j=>['active','waiting'].includes(j.status))){const s=active.find(t=>t.gid===j.gid);if(s&&matchesKnown(j,s))await rpc('aria2.pause',[j.gid]);}await reconcile();render();};if(locked&&running)await queueAction(work);else await withLock(work);}
  function stopNew(){if(!locked||(!running&&!scanning)){last='当前分頁没有运行中的批次';render();return;}stop=true;state.hold=true;state.runIntent=false;state.reason='用户停止新增；已提交任务继续';save();render();}
  function el(tag,text,style){const x=document.createElement(tag);if(text!==undefined)x.textContent=text;if(style)Object.assign(x.style,style);return x;}
  function btn(text,fn){const b=el('button',text,{padding:'7px 12px',margin:'3px',border:'1px solid #bed4e6',borderRadius:'6px',background:'#fff',color:'#0878cb',cursor:'pointer'});b.onclick=()=>Promise.resolve().then(fn).catch(e=>alert(msg(e)));return b;}
  function modal(title){if(view)view.remove();logBox=null;controls=null;view=el('div',undefined,{position:'fixed',inset:'0',background:'rgba(0,0,0,.38)',zIndex:'2147483646',display:'flex',alignItems:'flex-start',justifyContent:'center',paddingTop:'6vh'});const p=el('div',undefined,{background:'#fff',color:'#222',width:'min(920px,95vw)',maxHeight:'85vh',overflow:'auto',padding:'18px',borderRadius:'12px',fontSize:'14px',boxShadow:'0 5px 25px #5555'});p.append(btn('关闭',()=>{view.remove();view=null;logBox=null;controls=null;}),el('h2',title,{fontSize:'20px',margin:'8px 0'}));view.append(p);document.body.append(view);return p;}
  function render(){if(!logBox)return;let q;try{q=locked&&state?state:readQueue();}catch(e){logBox.textContent=msg(e);return;}const count=k=>q.jobs.filter(j=>j.status===k).length;const total=q.jobs.reduce((a,j)=>a+Number(j.raw.size),0), bytes=q.jobs.reduce((a,j)=>a+Math.min(Number(j.raw.size),Number(j.bytes||0)),0), avg=speedSeconds?speedIntegral/speedSeconds:0;
    logBox.textContent=`${running?'运行中':q.hold?'已暂停':'空闲'} · ${q.reason||last}\n完成 ${count('done')} / ${q.jobs.length} · 旧记录 ${count('legacy')} · 运行 ${count('active')} · 排队 ${count('waiting')+count('pending')} · 暂停 ${count('paused')} · 异常 ${count('error')+count('uncertain')} · 已取消 ${count('cancelled')}\n总速度 ${size(running?rate:0)}/s · 本次平均 ${size(avg)}/s · 近期峰值 ${size(Math.max(0,...samples))}/s\n进度 ${size(bytes)} / ${size(total)} · ETA ${rate?Math.ceil(Math.max(0,total-bytes)/rate/60)+' 分钟':'—'}\n目录 ${q.root} · 帐号 ${q.account?'已绑定':'未绑定'}`;
    if(!controls)return;controls.bar.style.width=(total?Math.min(100,100*bytes/total):0)+'%';controls.rows.replaceChildren();if(controls.chart){const c=controls.chart,ctx=c.getContext('2d');ctx.clearRect(0,0,c.width,c.height);const peak=Math.max(1,...samples);ctx.strokeStyle='#168b69';ctx.lineWidth=2;ctx.beginPath();samples.forEach((v,i)=>{const x=i*c.width/Math.max(1,samples.length-1),y=c.height-5-v*(c.height-10)/peak;i?ctx.lineTo(x,y):ctx.moveTo(x,y);});ctx.stroke();}const order={active:0,waiting:1,paused:2,uncertain:3,error:4,pending:5,done:6,legacy:7,cancelled:8};const filter=controls.filter.value;const rows=[...q.jobs].sort((a,b)=>(order[a.status]??9)-(order[b.status]??9)).filter(j=>filter==='all'||filter===j.status);const maxPage=Math.max(0,Math.ceil(rows.length/100)-1);controls.page=Math.min(maxPage,controls.page);controls.pageLabel.textContent=`第 ${controls.page+1}/${maxPage+1} 页 · ${rows.length} 项`;for(const j of rows.slice(controls.page*100,controls.page*100+100)){const row=el('div',undefined,{padding:'8px 4px',borderBottom:'1px solid #e2e8f0'});row.append(el('div',`${j.status} · ${j.relative?j.relative+'/':''}${j.name}`,{fontWeight:'600',overflowWrap:'anywhere'}),el('div',`${size(j.bytes)} / ${size(j.raw.size)} · ${size(j.speed)}/s ${j.note||''}`,{fontSize:'12px',color:'#475569'}));if(locked&&running&&j.status==='pending')row.append(btn('优先',()=>{const i=state.jobs.indexOf(j);if(i>=0&&j.status==='pending'){state.jobs.splice(i,1);state.jobs.unshift(j);save();render();}}),btn('移出等待队列',()=>{if(j.status==='pending'&&confirm('仅移出尚未提交的任务？不会删除文件。')){state.jobs=state.jobs.filter(x=>x!==j);save();render();}}));if(['active','waiting'].includes(j.status))row.append(btn('暂停此项',()=>jobAction(j.key,'pause')));if(j.status==='paused')row.append(btn('继续此项',()=>jobAction(j.key,'resume')));if(['active','waiting','paused'].includes(j.status))row.append(btn('取消此项（保留文件）',()=>jobAction(j.key,'cancel')));controls.rows.append(row);}}
  function showProgress(){const p=modal('百度下载管理器 · 本地版 2.0.0 · 完整修订');logBox=el('pre','',{whiteSpace:'pre-wrap',overflowWrap:'anywhere',background:'#f1f6fb',padding:'12px',borderRadius:'8px'});const bar=el('div',undefined,{height:'7px',background:'#168b69',width:'0%',borderRadius:'8px'});const track=el('div',undefined,{background:'#e2e8f0',borderRadius:'8px'});track.append(bar);const rows=el('div');const filter=el('select');for(const k of ['all','active','waiting','pending','paused','error','uncertain','done','legacy','cancelled']){const o=el('option',k);o.value=k;filter.append(o);}filter.onchange=()=>{controls.page=0;render();};const chart=el('canvas');chart.width=600;chart.height=75;chart.style.width='100%';const pageLabel=el('span','');controls={rows,bar,filter,chart,page:0,pageLabel};p.append(logBox,track,chart,btn('加入所选并开始',startBatch),btn('恢复队列',resumeQueue),btn('停止新增',stopNew),btn('暂停全部管理任务',pauseAll),btn('检查不明任务',resolveUncertain),btn('导出校验清单',exportManifest),btn('导入校验报告',importReport),btn('设置',settings),btn('清空队列记录',clearQueue));const adjust=el('input');adjust.type='number';adjust.min=1;adjust.max=5;adjust.value=String(currentParallel);adjust.style.width='60px';p.append(el('span',' 并行数：'),adjust,btn('运行中应用',async()=>{if(!running||!locked)throw err('请在运行中的管理分頁调整');const n=Number(adjust.value);if(!Number.isInteger(n)||n<1||n>5)throw err('并行数范围 1–5');await queueAction(async()=>{GM_setValue('local_adaptive','false');adaptiveState=null;await configure(n);render();});}),filter,btn('上一页',()=>{controls.page=Math.max(0,controls.page-1);render();}),pageLabel,btn('下一页',()=>{controls.page++;render();}),rows,el('p','关闭弹窗不会停止下载。关闭或刷新分頁只保留队列与 Aria2 已提交任务；回来点击恢复队列。仅在当前管理分頁操作。'));render();}
  function exportManifest(){const q=locked&&state?state:readQueue();const data={version:2,root:q.root,account:q.account,files:q.jobs.map(j=>({key:j.key,relative:(j.relative?j.relative+'/':'')+j.name,bytes:Number(j.raw.size),status:j.status,sourceMd5:j.sourceMd5||null}))};const u=URL.createObjectURL(new Blob([JSON.stringify(data,null,2)],{type:'application/json'}));const a=el('a');a.href=u;a.download='baidu-download-manifest.json';document.body.append(a);a.click();a.remove();setTimeout(()=>URL.revokeObjectURL(u),1000);}
  function applyReport(report){
    if(report.version!==2||String(report.account)!==String(state.account)||pathKey(report.root)!==pathKey(state.root)||!Array.isArray(report.files)||report.files.length>LIMIT)throw err('报告帐号或目录与队列不符');
    const byKey=new Map();for(const v of report.files){if(byKey.has(v.key))throw err('校验报告包含重复键');byKey.set(v.key,v);}
    let count=0;const accepted=['HashMatch','SizeMatch','HashMismatch','SizeMismatch','Missing','IncompleteControlFile','UnsafeOrUnreadable'];
    for(const j of state.jobs){const v=byKey.get(j.key);if(!v||v.relative!==(j.relative?j.relative+'/':'')+j.name||Number(v.expectedBytes)!==Number(j.raw.size)||!['done','legacy'].includes(j.status)||!accepted.includes(v.result))continue;
      if(v.result==='HashMatch'||v.result==='SizeMatch'){if(Number(v.actualBytes)!==Number(j.raw.size))continue;if(v.result==='HashMatch'&&(!j.sourceMd5||String(v.localMD5).toLowerCase()!==j.sourceMd5))continue;j.verified=v.result;j.note=v.result==='HashMatch'?'本地 MD5 与来源一致（报告时点）':'本地大小已核对（报告时点）';}
      else{j.verified=v.result;j.note='本地校验异常：'+v.result;j.status='error';state.hold=true;state.runIntent=false;state.reason='本地校验异常；检查本地文件后重试';const done=GM_getValue(DONE_KEY,{})||{};delete done[doneKey(j)];delete done[j.key];GM_setValue(DONE_KEY,done);}
      count++;
    }save();return count;
  }
  async function importReport(){const input=el('input');input.type='file';input.accept='.json,application/json';input.onchange=async()=>{try{const f=input.files[0];if(!f||f.size>20000000)throw err('校验报告无效或太大');const report=JSON.parse(await f.text());await withLock(async()=>{await bindAccount();const count=applyReport(report);last=`已导入 ${count} 项本地校验结果`;render();});}catch(e){alert(msg(e));}};input.click();}
  async function clearQueue(){await withLock(async()=>{const ext=await allRPC();if(ext.length||state.jobs.some(live))throw err('仍有任务未处理，不能清空');if(state.rpcLease)await restoreLease();if(confirm('只清空队列记录，不删除文件及旧版完成记录，继续？')){state=fresh();save();render();}});}

  function settings(){if(locked){alert('请等管理器停止后修改设置；运行中可直接调整并行数');return;}const p=modal('下载管理器设置');const fields=[['rpcDomain','RPC 域名'],['rpcPort','RPC 端口'],['rpcPath','RPC 路径'],['rpcToken','RPC 密钥'],['rpcDir','保存目录'],['local_parallel','初始并行数（1–5）'],['local_connections','单文件连接数（1–4）'],['local_adaptive','自适应（true/false）'],['local_max_parallel','自适应上限（3–5）'],['local_speed_limit','总速度上限 MiB/s（0=不限）'],['local_auto_resume','重新打开网页自动恢复（true/false）'],['local_verify_source','来源 MD5 严格校验（true/false，建议先验证来源）'],['bduss','BDUSS（可选，留空优先）']];const inputs={};for(const [k,label] of fields){const row=el('label',undefined,{display:'flex',alignItems:'center',gap:'8px',margin:'10px 0'});row.append(el('span',label,{width:'180px'}));const i=el('input',undefined,{flex:'1',padding:'7px',minWidth:'0'});i.value=String(cfg(k)??'');i.type=['rpcToken','bduss'].includes(k)?'password':'text';inputs[k]=i;row.append(i);p.append(row);}p.append(btn('保存',async()=>{await withLock(async()=>{if(!/^[A-Za-z]:[\\/].+/.test(inputs.rpcDir.value.trim()))throw err('请填写 Windows 绝对保存目录');const endpoint=new URL(`${inputs.rpcDomain.value.trim()}:${inputs.rpcPort.value.trim()}${inputs.rpcPath.value.trim()}`);if(endpoint.protocol!=='http:'||!['localhost','127.0.0.1'].includes(endpoint.hostname)||endpoint.username||endpoint.password||endpoint.search||endpoint.hash||!inputs.rpcToken.value.trim())throw err('RPC 仅允许本机 HTTP 且须设置密钥');if(state.jobs.length&&pathKey(inputs.rpcDir.value.trim())!==pathKey(state.root))throw err('已有队列，不能更改保存目录');if(state.jobs.some(live)||state.rpcLease){for(const k of ['rpcDomain','rpcPort','rpcPath'])if(inputs[k].value.trim()!==String(cfg(k)))throw err('已有任务，不能更改 RPC 端点');}for(const k of ['local_parallel','local_connections','local_max_parallel']){const n=Number(inputs[k].value);if(!Number.isInteger(n)||n<(k==='local_max_parallel'?3:1)||n>(k==='local_connections'?4:5))throw err('并行/连接数无效');}if(!Number.isFinite(Number(inputs.local_speed_limit.value))||Number(inputs.local_speed_limit.value)<0||Number(inputs.local_speed_limit.value)>1024)throw err('总速度上限无效');for(const k of ['local_adaptive','local_auto_resume','local_verify_source'])if(!['true','false'].includes(inputs[k].value))throw err('开关请输入 true 或 false');for(const k of Object.keys(inputs))GM_setValue(k,inputs[k].value.trim());alert('已保存');});}),btn('测试 RPC',async()=>{const r=await rpc('aria2.getVersion');alert(`RPC 正常：aria2 ${r.version}`);}),btn('返回管理器',showProgress));}
  async function single(){const files=selected().filter(v=>+v.isdir!==1);if(!files.length){alert('请勾选文件；目录使用批量下载');return;}const p=modal('单文件直链 · 仅复制命令');for(const raw of files){const name=safeName(raw.server_filename||raw.filename);p.append(el('p',`${name} (${size(raw.size)})`),btn('复制 PowerShell 命令',async()=>{if(running)throw err('批次运行中，避免同时下载相同文件');const l=await fetchLink(raw);const quote=s=>"'"+String(s).replace(/'/g,"''")+"'";copy(`aria2c -c -x${num('local_connections',1,4)} -s${num('local_connections',1,4)} ${quote(l.link)} --out ${quote(name)} ${l.headers.map(h=>'--header '+quote(h)).join(' ')}`);alert('命令含授权信息，请勿分享；确认目标文件无其他写入任务。');}));}}
  function diagnostics(){const q=locked&&state?state:readQueue();copy(`panlink-lite local 2.0.0 (hardened-20261125)\n页面：${location.origin}${location.pathname}\nRPC 密钥：${cfg('rpcToken')?'已设置':'空'}\n授权：${GM_getValue(TOKEN_KEY,'')?'已保存':'无'}\n队列：${q.jobs.length} 项；暂停=${q.hold}\n${q.reason||last}`);alert('诊断已复制（不含 Token、下载网址或密钥）');}
  function mount(){if(!isHome()||document.getElementById('pl-local-batch'))return;const box=el('div',undefined,{position:'fixed',right:'20px',bottom:'90px',zIndex:'2147483645',background:'#f5fbff',border:'1px solid #bfdbef',borderRadius:'9px',padding:'5px'});box.id='pl-local-batch';box.append(btn('加入批量下载',startBatch),btn('下载管理器',showProgress));document.body.append(box);}
  GM_registerMenuCommand('直链下载（复制命令）',single);GM_registerMenuCommand('⚙️ 设置',settings);GM_registerMenuCommand('批量下载：文件及文件夹',startBatch);GM_registerMenuCommand('查看批次进度 / 下载管理器',showProgress);GM_registerMenuCommand('恢复持久队列',resumeQueue);GM_registerMenuCommand('停止批量下载（当前文件完成后）',stopNew);GM_registerMenuCommand('重新百度授权',()=>{if(locked)return alert('请先停止管理器');if(confirm('打开百度授权？现有 Token 保留至新授权成功。'))authorize();});GM_registerMenuCommand('📋 复制诊断信息',diagnostics);GM_registerMenuCommand('导出校验清单',exportManifest);
  mount();setInterval(()=>{mount();if(!running&&logBox)render();},3000);
  // Opt-in only; do not revive intentionally stopped or failed queues.
  if(cfg('local_auto_resume')==='true')setTimeout(()=>{withLock(async()=>{if(!state.runIntent||state.hold||!state.account||!state.jobs.some(j=>j.status==='pending'||live(j)))return;await runQueue();});},1500);
})();
