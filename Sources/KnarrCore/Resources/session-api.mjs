// Read-only adapters. No prompt, resume, rename, archive, delete, or raw transcript parsing.
import {spawn} from 'node:child_process';
import {pathToFileURL} from 'node:url';
import {readFile} from 'node:fs/promises';
import path from 'node:path';
const SDK_VERSION='0.3.284';
const fail=code=>{throw new Error(code);};
const clip=(v,n=800)=>typeof v==='string'?v.slice(0,n):'';
const uuid=/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
export function validateRequest(input) {
 if(!input || !['codex','claude'].includes(input.provider) || !['list','search','read','usage'].includes(input.operation))fail('invalid_request');
 const r={...input,limit:input.limit??20};
 if(!Number.isInteger(r.limit)||r.limit<1||r.limit>50)fail('invalid_request');
 for(const key of ['cwd','cursor','query'])if(r[key]!==undefined && (typeof r[key]!=='string'||r[key].length>4096))fail('invalid_request');
 if(r.cwd!==undefined&&!path.isAbsolute(r.cwd))fail('invalid_request');
 if(r.operation==='read' && !uuid.test(r.sessionID??''))fail('invalid_request');
 if(r.operation==='search' && (!r.query?.trim()||r.query.length>200))fail('invalid_request');
 if(r.provider==='claude'&&r.cursor!==undefined&&!/^\d{1,9}$/.test(r.cursor))fail('invalid_cursor');
 return r;
}
function textContent(content) {
 if(typeof content==='string')return content;
 if(!Array.isArray(content))return '';
 return content.filter(x=>x?.type==='text'||x?.type==='input_text'||x?.type==='output_text').map(x=>x.text??'').join('\n');
}
function message(id,role,text,turnID) {
 if(!text)return null;
 let excerpt=text;
 if(Buffer.byteLength(JSON.stringify(excerpt))>12000){
  let low=0,high=Math.min(text.length,12000);
  while(low<high){const mid=Math.ceil((low+high)/2);if(Buffer.byteLength(JSON.stringify(text.slice(0,mid)))<=12000)low=mid;else high=mid-1;}
  if(low>0 && /[\uD800-\uDBFF]/.test(text[low-1]))low--;
  excerpt=text.slice(0,low);
 }
 return {id,role,text:excerpt,truncated:excerpt.length<text.length,...(turnID?{turnID}:{})};
}
function codexInfo(t) {
 if(typeof t?.id!=='string')fail('invalid_response');
 return {provider:'codex',id:t.id,title:clip(t.name||t.preview||t.id),preview:clip(t.preview),cwd:t.cwd??null,updatedAt:t.updatedAt??null};
}
function claudeInfo(t) {
 if(typeof t?.sessionId!=='string')fail('invalid_response');
 return {provider:'claude',id:t.sessionId,title:clip(t.customTitle||t.summary||t.firstPrompt||t.sessionId),preview:clip(t.firstPrompt),cwd:t.cwd??null,updatedAt:t.lastModified?Math.floor(t.lastModified/1000):null};
}
export async function execute(input, {codex,claude,claudeUsage}) {
 const r=validateRequest(input);
 if(r.operation==='usage'){
  if(r.provider==='codex')return await codex('account/rateLimits/read',{});
  const root=await claudeUsage();
  if(!Array.isArray(root?.reports))fail('invalid_response');
  // OMP owns authentication. Only quota facts cross the bridge; identities and raw payloads do not.
  return {reports:root.reports.filter(x=>x?.provider==='anthropic').map(x=>({
   provider:'anthropic',fetchedAt:x.fetchedAt,limits:(Array.isArray(x.limits)?x.limits:[])
    .filter(y=>['anthropic:5h','anthropic:7d'].includes(y?.id))
    .map(y=>({id:y.id,amount:{usedFraction:y.amount?.usedFraction},window:{resetsAt:y.window?.resetsAt}}))
  }))};
 }
 if(r.provider==='codex') {
  if(r.operation!=='read') {
   const page=await codex('thread/list',{limit:r.limit,cursor:r.cursor??null,cwd:r.cwd??null,archived:r.archived??false,
    useStateDbOnly:true,sortKey:'updated_at',sortDirection:'desc',...(r.operation==='search'?{searchTerm:r.query}:{})});
   if(!Array.isArray(page?.data))fail('invalid_response');
   return {provider:r.provider,sessions:page.data.map(codexInfo),nextCursor:page.nextCursor??null,...(r.operation==='search'?{searchedFields:'title'}:{})};
  }
  const meta=await codex('thread/read',{threadId:r.sessionID,includeTurns:false});
  const session=codexInfo(meta?.thread);
  if(r.cwd && session.cwd!==r.cwd)fail('scope_mismatch');
  const page=await codex('thread/items/list',{threadId:r.sessionID,limit:r.limit,cursor:r.cursor??null,sortDirection:'asc'});
  if(!Array.isArray(page?.data))fail('invalid_response');
  const messages=page.data.flatMap(({item,turnId})=>{
   if(item?.type==='userMessage')return [message(item.id,'user',textContent(item.content),turnId)].filter(Boolean);
   if(item?.type==='agentMessage')return [message(item.id,'assistant',item.text??'',turnId)].filter(Boolean);
   return [];
  });
  return {session,messages,nextCursor:page.nextCursor??null,scanned:page.data.length,contentKind:'user and assistant text only'};
 }
 const offset=Number(r.cursor??0);
 if(r.archived)fail('unsupported_archive_filter');
 if(r.operation!=='read') {
  const rows=await claude.listSessions({...(r.cwd?{dir:r.cwd,includeWorktrees:false}:{}),limit:r.limit+1,offset});
  if(!Array.isArray(rows))fail('invalid_response');
  const scanned=rows.slice(0,r.limit);
  let sessions=scanned.map(claudeInfo);
  if(r.operation==='search')sessions=sessions.filter(s=>(s.title+'\n'+s.preview).toLocaleLowerCase().includes(r.query.toLocaleLowerCase()));
  return {provider:r.provider,sessions,nextCursor:rows.length>r.limit?String(offset+r.limit):null,scanned:scanned.length,
   ...(r.operation==='search'?{searchedFields:'title, preview',searchScope:'this page; follow nextCursor to continue'}:{})};
 }
 const opts=r.cwd?{dir:r.cwd}:{};
 const info=await claude.getSessionInfo(r.sessionID,opts);
 if(!info)fail('session_not_found');
 if(r.cwd && info.cwd!==r.cwd)fail('scope_mismatch');
 const rows=await claude.getSessionMessages(r.sessionID,{...opts,offset,limit:r.limit+1,includeSystemMessages:false});
 if(!Array.isArray(rows))fail('invalid_response');
 const messages=rows.slice(0,r.limit).flatMap(m=>['user','assistant'].includes(m.type)?[message(m.uuid,m.type,textContent(m.message?.content))].filter(Boolean):[]);
 return {session:claudeInfo(info),messages,nextCursor:rows.length>r.limit?String(offset+r.limit):null,scanned:Math.min(rows.length,r.limit),contentKind:'user and assistant text only'};
}
export class CodexReadConnection {
 constructor(executable) {
  this.sequence=0;this.pending=new Map();this.buffer='';this.closed=false;
  this.child=spawn(executable,['app-server'],{stdio:['pipe','pipe','pipe']});
  this.exited=new Promise(resolve=>{this.child.once('close',()=>{this.closed=true;this.rejectAll('connection_closed');resolve();});});
  this.child.on('error',()=>this.rejectAll('codex_unavailable'));
  this.child.stdin.on('error',()=>this.rejectAll('connection_closed'));
  this.child.stderr.resume();
  this.child.stdout.setEncoding('utf8');
  this.child.stdout.on('data',chunk=>{
   this.buffer+=chunk;
   if(Buffer.byteLength(this.buffer)>8*1024*1024){this.rejectAll('response_too_large');this.child.kill('SIGTERM');return;}
   let end;
   while((end=this.buffer.indexOf('\n'))>=0){const line=this.buffer.slice(0,end);this.buffer=this.buffer.slice(end+1);
    try {const frame=JSON.parse(line); const pending=this.pending.get(frame.id);if(!pending)continue;
     this.pending.delete(frame.id);clearTimeout(pending.timer);
     if(frame.error)pending.reject(new Error(frame.error.code===-32601?'api_version_unsupported':'api_request_failed'));
     else pending.resolve(frame.result);
    } catch {this.rejectAll('invalid_response');}
   }
  });
 }
 rejectAll(code){for(const p of this.pending.values()){clearTimeout(p.timer);p.reject(new Error(code));}this.pending.clear();}
 request(method,params){
  if(!['initialize','thread/list','thread/read','thread/items/list','account/rateLimits/read'].includes(method))return Promise.reject(new Error('method_not_allowed'));
  if(this.closed)return Promise.reject(new Error('connection_closed'));
  return new Promise((resolve,reject)=>{const id=++this.sequence;
   const timer=setTimeout(()=>{this.pending.delete(id);reject(new Error('api_timeout'));},20000);
   this.pending.set(id,{resolve,reject,timer});this.child.stdin.write(JSON.stringify({id,method,params})+'\n');});
 }
 async initialize(){await this.request('initialize',{clientInfo:{name:'knarr-session-reader',version:'1.0.0'},capabilities:{experimentalApi:true}});this.child.stdin.write(JSON.stringify({method:'initialized',params:{}})+'\n');}
 async close(){
  this.child.stdin.end();
  let timer;await Promise.race([this.exited,new Promise(r=>{timer=setTimeout(r,300);})]);clearTimeout(timer);
  if(!this.closed){this.child.kill('SIGTERM');await Promise.race([this.exited,new Promise(r=>{timer=setTimeout(r,500);})]);clearTimeout(timer);}
  if(!this.closed){this.child.kill('SIGKILL');await this.exited;}
 }
}
// Uses OMP's official usage API, not session transcripts or direct credential access.
// The enclosing OwnedOMPProcess group reclaims descendants on host timeout/cancellation.
export function readClaudeUsage(executable){
 return new Promise((resolve,reject)=>{
  const child=spawn(executable,['usage','--json','--provider','anthropic','--redact','--no-extensions'],{stdio:['ignore','pipe','pipe']});
  let output='',failure;
  let escalation;
  const stop=code=>{
   if(failure)return;failure=code;child.kill('SIGTERM');
   escalation=setTimeout(()=>child.kill('SIGKILL'),500);
  };
  const timer=setTimeout(()=>stop('api_timeout'),20000);
  child.stderr.resume();child.stdout.setEncoding('utf8');
  child.stdout.on('data',chunk=>{output+=chunk;if(Buffer.byteLength(output)>1048576)stop('response_too_large');});
  child.on('error',()=>{failure='usage_unavailable';});
  child.on('close',code=>{
   clearTimeout(timer);clearTimeout(escalation);
   if(failure||code!==0){reject(new Error(failure||'usage_unavailable'));return;}
   try{resolve(JSON.parse(output));}catch{reject(new Error('invalid_response'));}
  });
 });
}
async function main(){
 let connection;
 try {
  let line='';for await(const piece of process.stdin){line+=piece;if(Buffer.byteLength(line)>16384)fail('invalid_request');if(line.includes('\n'))break;}
  const request=validateRequest(JSON.parse(line));
  const dependencies={};
  if(request.provider==='codex'){
   connection=new CodexReadConnection(process.env.KNARR_CODEX_EXECUTABLE||'codex');await connection.initialize();
   dependencies.codex=(method,params)=>connection.request(method,params);
  }else if(request.operation==='usage'){
   const executable=process.env.KNARR_OMP_EXECUTABLE;if(!executable)fail('usage_unavailable');
   dependencies.claudeUsage=()=>readClaudeUsage(executable);
  }else{
   const root=process.env.KNARR_CLAUDE_SDK_PATH;if(!root)fail('claude_sdk_unavailable');
   const pkg=JSON.parse(await readFile(path.join(root,'package.json'),'utf8'));
   if(pkg.version!==SDK_VERSION||pkg.name!=='@anthropic-ai/claude-agent-sdk')fail('sdk_version_mismatch');
   dependencies.claude=await import(pathToFileURL(path.join(root,'sdk.mjs')).href);
  }
  const result=await execute(request,dependencies);
  process.stdout.write(JSON.stringify({ok:true,result})+'\n');
 }catch(error){
  const allowed=['invalid_request','invalid_cursor','invalid_response','session_not_found','scope_mismatch','unsupported_archive_filter','codex_unavailable','claude_sdk_unavailable','sdk_version_mismatch','usage_unavailable','api_timeout','api_version_unsupported','api_request_failed','connection_closed','response_too_large'];
  process.stdout.write(JSON.stringify({ok:false,error:allowed.includes(error.message)?error.message:'session_api_failed'})+'\n');process.exitCode=1;
 }finally{await connection?.close();}
}
if(process.argv[1]&&import.meta.url===pathToFileURL(path.resolve(process.argv[1])).href)await main();
