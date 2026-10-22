import test from 'node:test';
import assert from 'node:assert/strict';
import {execute, validateRequest} from '../../Sources/KnarrCore/Resources/session-api.mjs';
const sid='019f4714-ad94-7882-bb65-2766cacec1a2';

test('invalid providers, operations, IDs and oversized limits are rejected',()=>{
 for(const value of [{provider:'x',operation:'list'},{provider:'codex',operation:'prompt'},
 {provider:'claude',operation:'read',sessionID:'../../auth.json'},
 {provider:'codex',operation:'list',limit:1000}]) assert.throws(()=>validateRequest(value));
});
test('Codex lists the API page and preserves cursor and source',async()=>{
 const calls=[];
 const request=async(method,params)=>{calls.push({method,params});return {data:[{id:sid,name:'Knarr 기록',cwd:'/work',updatedAt:10}],nextCursor:'next'};};
 const r=await execute({provider:'codex',operation:'list',limit:2,cwd:'/work'}, {codex:request});
 assert.equal(r.sessions[0].provider,'codex');assert.equal(r.sessions[0].id,sid);assert.equal(r.nextCursor,'next');
 assert.deepEqual(calls.map(x=>x.method),['thread/list']);assert.equal(calls[0].params.useStateDbOnly,true);
});
test('Codex read uses paginated items, omits tool payloads and marks clipped text',async()=>{
 const calls=[];
 const codex=async(method,params)=>{calls.push({method,params});
 if(method==='thread/read')return {thread:{id:sid,name:'title',cwd:'/work'}};
 return {data:[{turnId:'t',item:{type:'userMessage',id:'u',content:[{type:'text',text:'질문'}]}},
 {turnId:'t',item:{type:'commandExecution',id:'tool',aggregatedOutput:'secret'}},
 {turnId:'t',item:{type:'agentMessage',id:'a',text:'a'.repeat(15000)}}],nextCursor:'p2'};};
 const r=await execute({provider:'codex',operation:'read',sessionID:sid}, {codex});
 assert.equal(r.messages.length,2);assert.equal(r.messages[0].role,'user');assert.equal(r.messages[1].truncated,true);
 assert.equal(r.nextCursor,'p2');assert.equal(calls[0].params.includeTurns,false);
 assert.deepEqual(calls.map(x=>x.method),['thread/read','thread/items/list']);
 assert.ok(!JSON.stringify(r).includes('secret'));
});
test('Claude uses only read SDK APIs and paginates without losing messages',async()=>{
 const calls=[]; const claude={
 getSessionInfo:async(id,options)=>{calls.push('info');return {sessionId:id,summary:'대화',cwd:'/work'};},
 getSessionMessages:async(id,options)=>{calls.push(options);return [
 {uuid:'u',type:'user',message:{content:[{type:'text',text:'안녕하세요'},{type:'tool_result',content:'omit'}]}},
 {uuid:'a',type:'assistant',message:{content:[{type:'text',text:'반가워요'}]}},
 {uuid:'b',type:'assistant',message:{content:'다음'}}];}};
 const r=await execute({provider:'claude',operation:'read',sessionID:sid,limit:2}, {claude});
 assert.equal(r.messages.length,2);assert.equal(r.messages[0].text,'안녕하세요');assert.equal(r.nextCursor,'2');
 assert.equal(calls[1].limit,3);assert.equal(calls[1].includeSystemMessages,false);
});
test('Claude search reports exactly the inspected page and a continuation',async()=>{
 const claude={listSessions:async()=>[{sessionId:sid,summary:'다른 대화'},{sessionId:'two',summary:'Knarr 조사'},{sessionId:'three',summary:'더 있음'}]};
 const r=await execute({provider:'claude',operation:'search',query:'Knarr',limit:2},{claude});
 assert.equal(r.sessions.length,1);assert.equal(r.nextCursor,'2');assert.equal(r.searchedFields,'title, preview');assert.equal(r.scanned,2);
});
test('not found and malformed API responses fail instead of claiming an empty history',async()=>{
 await assert.rejects(execute({provider:'claude',operation:'read',sessionID:sid},{claude:{getSessionInfo:async()=>undefined}}),/session_not_found/);
 await assert.rejects(execute({provider:'codex',operation:'list'},{codex:async()=>({})}),/invalid_response/);
});
test('Codex transport rejects mutation methods before writing to the child',async()=>{
 const {CodexReadConnection}=await import('../../Sources/KnarrCore/Resources/session-api.mjs');
 const connection=new CodexReadConnection('/usr/bin/false');
 try {await assert.rejects(connection.request('turn/start',{}),/method_not_allowed/);} finally {await connection.close();}
 assert.equal(connection.closed,true);
});
test('Codex scope mismatch never reads the other project transcript',async()=>{
 const calls=[];
 await assert.rejects(execute({provider:'codex',operation:'read',sessionID:sid,cwd:'/allowed'}, {codex:async m=>{
  calls.push(m);return {thread:{id:sid,cwd:'/different'}};
 }}),/scope_mismatch/);
 assert.deepEqual(calls,['thread/read']);
});
test('each excerpt has a byte bound even for Korean, emoji and escaped text',async()=>{
 const text=('한글😀\u0000').repeat(9000);
 const codex=async method=>method==='thread/read'?{thread:{id:sid}}:{data:[{item:{type:'agentMessage',id:'a',text}}]};
 const r=await execute({provider:'codex',operation:'read',sessionID:sid},{codex});
 assert.ok(Buffer.byteLength(JSON.stringify(r.messages[0].text))<=12000);
 assert.equal(r.messages[0].truncated,true);
});

test('usage reads only the account limit endpoint, never a thread or model',async()=>{
 const calls=[];
 const result=await execute({provider:'codex',operation:'usage'}, {codex:async(method,params)=>{
  calls.push({method,params});return {rateLimits:{primary:{usedPercent:12}}};
 }});
 assert.equal(result.rateLimits.primary.usedPercent,12);
 assert.deepEqual(calls,[{method:'account/rateLimits/read',params:{}}]);
});
test('Claude usage excludes identity, raw payloads and other providers',async()=>{
 const result=await execute({provider:'claude',operation:'usage'}, {claudeUsage:async()=>({
  generatedAt:1234,reports:[{provider:'anthropic',fetchedAt:1000,metadata:{email:'private'},raw:{secret:'private'},
   limits:[{id:'anthropic:5h',scope:{accountId:'private',windowId:'5h'},amount:{usedFraction:0.25},window:{resetsAt:9000}}]},
   {provider:'openai-codex',metadata:{email:'private'},limits:[]}]
 })});
 assert.deepEqual(result,{reports:[{provider:'anthropic',fetchedAt:1000,limits:[{
  id:'anthropic:5h',amount:{usedFraction:0.25},window:{resetsAt:9000}
 }]}]});
});

test('actual Codex quota read closes its owned app-server', {skip:process.env.KNARR_TEST_USAGE_LIVE!=='1'}, async()=>{
 const {CodexReadConnection}=await import('../../Sources/KnarrCore/Resources/session-api.mjs');
 const connection=new CodexReadConnection(process.env.KNARR_CODEX_EXECUTABLE||'codex');
 const pid=connection.child.pid;
 try{
  await connection.initialize();
  const result=await connection.request('account/rateLimits/read',{});
  assert.ok(result.rateLimits || result.rateLimitsByLimitId);
 }finally{await connection.close();}
 assert.equal(connection.closed,true);
 assert.throws(()=>process.kill(pid,0),{code:'ESRCH'});
 console.log(`LIVE codex owned_pid=${pid} method=account/rateLimits/read owned_remaining=0`);
});
