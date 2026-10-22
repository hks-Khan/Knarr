import * as path from 'node:path';
import { streamAnthropic } from '@oh-my-pi/pi-ai/providers/anthropic';
import { buildModel } from '@oh-my-pi/pi-catalog/build';
import { convertToLlm } from '@oh-my-pi/pi-coding-agent/session/messages';
import { SessionManager } from '@oh-my-pi/pi-coding-agent/session/session-manager';

// Trusted test extension. It registers only an offline model and never sends a prompt.
export default function(pi) {
  pi.registerProvider('knarr-offline', {
    baseUrl:'http://127.0.0.1:1', apiKey:'fixture', api:'knarr-offline',
    models:[{id:'fixture',name:'Offline fixture',reasoning:false,input:['text'],cost:{input:0,output:0,cacheRead:0,cacheWrite:0},contextWindow:200000,maxTokens:1000}],
    streamSimple(){throw new Error('External model calls forbidden');}
  });
  return (async () => {
    const dir = process.env.KNARR_REPLAY_DIR!;
    const phase = process.env.KNARR_REPLAY_PHASE!;
    let manager;
    try {
      const model=buildModel({id:'claude-opus-5-5',name:'Offline replay',provider:'anthropic',api:'anthropic-messages',baseUrl:'https://api.anthropic.com',reasoning:true,input:['text'],cost:{input:0,output:0,cacheRead:0,cacheWrite:0},contextWindow:1000000,maxTokens:4096});
      const roster = await Bun.file(process.env.KNARR_ROSTER_CAPTURE!).json();
      let wire;
      const drop = {type:'thinking_dropped',reason:'prefix_binding_mismatch',path:'messages.1.content.1'};
      const client = {messages:{create(params) {
        wire=params;
        return {async withResponse() {return {data:(async function* () {
          yield {type:'message_start',message:{id:'fixture',usage:{input_tokens:1,output_tokens:0},...(phase==='write'?{input_transformations:[drop,drop]}:{})}};
          yield {type:'content_block_start',index:0,content_block:{type:'text',text:''}};
          yield {type:'content_block_delta',index:0,delta:{type:'text_delta',text:'ok'}};
          yield {type:'content_block_stop',index:0};
          yield {type:'message_delta',delta:{stop_reason:'end_turn'},usage:{output_tokens:1}};
          yield {type:'message_stop'};
        })(),response:new Response(null,{status:200})};}};
      }}};
      if (phase==='write') {
        manager=SessionManager.create(dir,path.join(dir,'sessions'));
        manager.appendMessage({role:'user',content:'inspect',timestamp:0});
        manager.appendMessage({role:'assistant',api:'anthropic-messages',provider:'anthropic',model:model.id,content:[
          {type:'thinking',thinking:'valid',thinkingSignature:'sig_valid'},
          {type:'thinking',thinking:'dropped',thinkingSignature:'sig_bound'},
          {type:'text',text:'inspected'}],usage:{input:0,output:0,cacheRead:0,cacheWrite:0,totalTokens:0,cost:{input:0,output:0,cacheRead:0,cacheWrite:0,total:0}},stopReason:'stop',timestamp:0});
        manager.appendMessage({role:'user',content:'continue',timestamp:1});
      } else {
        manager=await SessionManager.open(await Bun.file(path.join(dir,'session-path.txt')).text(),dir);
      }
      const messages=convertToLlm(manager.buildSessionContext().messages);
      const before=JSON.stringify(messages);
      const result=await streamAnthropic(model,{systemPrompt:['Fixed offline system'],messages,tools:roster.tools},{client,apiKey:'fixture',credentialId:42,providerSessionState:new Map()}).result();
      if(result.stopReason!=='stop') throw new Error(result.errorMessage ?? result.stopReason);
      if(JSON.stringify(messages)!==before) throw new Error('History was mutated');
      const signatures=wire.messages.filter(m=>m.role==='assistant').flatMap(m=>Array.isArray(m.content)?m.content:[]).filter(b=>b.type==='thinking').map(b=>b.signature);
      const expected=phase==='write'?['sig_valid','sig_bound']:['sig_valid'];
      if(JSON.stringify(signatures)!==JSON.stringify(expected)) throw new Error('Unexpected replay '+JSON.stringify(signatures));
      manager.appendMessage(result);
      await manager.close();
      await Bun.write(path.join(dir,'session-path.txt'),manager.getSessionFile());
      const sha=value=>new Bun.CryptoHasher('sha256').update(JSON.stringify(value)).digest('hex');
      await Bun.write(path.join(dir,phase+'.json'),JSON.stringify({phase,pid:process.pid,actualModelAPIRequests:0,signatures,toolsHash:sha(wire.tools),systemHash:sha(wire.system),metadata:result.anthropicThinkingReplay,toolCount:wire.tools.length},null,2));
    } catch(error) {
      await Bun.write(path.join(dir,phase+'.json'),JSON.stringify({error:String(error),stack:error?.stack},null,2));
    } finally { if(manager) await manager.close(); }
  })();
}
