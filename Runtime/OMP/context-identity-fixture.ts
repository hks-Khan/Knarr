import { writeFileSync } from "node:fs";
import { ExtensionRunner } from "@oh-my-pi/pi-coding-agent/extensibility/extensions/runner";
import { DateCwdReminderInjector } from "@oh-my-pi/pi-coding-agent/session/date-cwd-reminder";
import { convertToLlm } from "@oh-my-pi/pi-coding-agent/session/messages";
import { streamAnthropic } from "@oh-my-pi/pi-ai/providers/anthropic";
import { buildModel } from "@oh-my-pi/pi-catalog/build";

// Loaded only in an isolated runtime. Captures requests before transmission.
export default function (pi) {
  pi.registerProvider("cache-audit-fixture", {
    baseUrl: "http://127.0.0.1:1", apiKey: "fixture", api: "cache-audit-fixture",
    models: [{id: "deterministic", name: "Offline", reasoning: false, input: ["text"], cost: {input:0,output:0,cacheRead:0,cacheWrite:0}, contextWindow:200000,maxTokens:1000}],
    streamSimple() { throw Error("Model calls forbidden"); }
  });
  return (async () => {
    const results = [];
    let networkCalls = 0;
    const check = (name, ok) => results.push({name, passed: !!ok});
    const runner = handlers => {
      const extensions = handlers.map(handler => ({path:"/fixture/context.ts", handlers:new Map([["context",[handler]]]),tools:new Map(),commands:new Map(),flags:new Map(),shortcuts:new Map()}));
      const r = new ExtensionRunner(extensions, {}, "/fixture", {getCwd:()=>"/fixture"}, {});
      return r;
    };
    const user = (content, timestamp=1) => ({role:"user",content:[{type:"text",text:content}],timestamp});
    const noop = event => ({messages:event.messages});
    try {
      const first = user("Stable history");
      const second = user("Later history",2);
      const history = [first,second];
      const noHandlers = await runner([]).emitContext(history);
      check("no-handler identity remains stable", noHandlers[0] === first);
      const unchanged = await runner([noop]).emitContext(history);
      check("unchanged context restores original identity", unchanged[0] === first && unchanged[1] === second);
      const equivalent = await runner([e=>({messages:e.messages.map(m=>structuredClone(m))})]).emitContext(history);
      check("equal replacement restores original identity", equivalent[0] === first);
      const reordered = await runner([e=>({messages:[e.messages[1],e.messages[0]]})]).emitContext(history);
      check("reordering preserves each history identity", reordered[0] === second && reordered[1] === first);
      const filtered = await runner([e=>({messages:e.messages.slice(1)})]).emitContext(history);
      check("filtering preserves retained history identity", filtered.length===1 && filtered[0]===second);
      let retained;
      let retainedArray;
      const altered = await runner([e=>{retained=e.messages[0];e.messages[0].content[0].text="Edited";return {messages:e.messages};}]).emitContext(history);
      check("extension edits are preserved", altered[0].content[0].text==="Edited");
      check("in-place extension edits cannot mutate source", first.content[0].text==="Stable history" && altered[0]!==first);
      const shared = runner([e=>{retained=e.messages[0];retainedArray=e.messages;return {messages:e.messages};}, e=>{check("later handler still receives isolated copy",e.messages[0]!==first);return {messages:e.messages};}]);
      const isolated = await shared.emitContext(history);
      retained.content[0].text="Late edit";
      check("retained extension copy cannot mutate restored history",first.content[0].text==="Stable history" && isolated[0]===first);

      retainedArray[0].content[0].text="Late array edit";
      check("retained extension array cannot mutate source",first.content[0].text==="Stable history");

      const model=buildModel({id:"claude-opus-5-5",name:"Fixture",provider:"anthropic",api:"anthropic-messages",baseUrl:"https://api.anthropic.com",reasoning:true,input:["text"],cost:{input:0,output:0,cacheRead:0,cacheWrite:0},contextWindow:1000000,maxTokens:4096});
      const answer={role:"assistant",api:"anthropic-messages",provider:"anthropic",model:model.id,content:[{type:"thinking",thinking:"",thinkingSignature:"fixture-signature"},{type:"toolCall",id:"tool_fixture",name:"read",arguments:{path:"fixture"}}],usage:{input:1,output:1,cacheRead:0,cacheWrite:0,totalTokens:2,cost:{input:0,output:0,cacheRead:0,cacheWrite:0,total:0}},stopReason:"toolUse",timestamp:3};
      const result={role:"toolResult",toolCallId:"tool_fixture",toolName:"read",content:[{type:"text",text:"fixture result"}],isError:false,timestamp:4};
      const tools=[{name:"read",description:"Read fixture",parameters:{type:"object",properties:{path:{type:"string"}},required:["path"]}}];
      const contextRunner=runner([noop,noop]);
      const context=async messages=>({systemPrompt:["Stable fixture system"],messages:convertToLlm(await contextRunner.emitContext(messages)),tools});
      const injector=new DateCwdReminderInjector();
      const original=[first,answer,result];
      const before=injector.transform(await context(original),"2026-10-16","/fixture");
      const sameDay=injector.transform(await context(original),"2026-10-16","/fixture");
      const midnight=injector.transform(await context(original),"2026-10-17","/fixture");
      check("same-day request stays identical",JSON.stringify(before)===JSON.stringify(sameDay));
      check("midnight preserves existing message prefix",JSON.stringify(midnight.messages.slice(0,before.messages.length))===JSON.stringify(before.messages));
      check("midnight appends one reminder",midnight.messages.length===before.messages.length+1 && midnight.messages.at(-1).role==="developer");
      const repeat=injector.transform(await context(original),"2026-10-17","/fixture");
      check("new-day reminder persists without duplication",JSON.stringify(repeat.messages)===JSON.stringify(midnight.messages));
      const next=injector.transform(await context([...original,user("Continue",5)]),"2026-10-17","/fixture");
      check("next user turn retains earlier reminder and prefix",JSON.stringify(next.messages.slice(0,midnight.messages.length))===JSON.stringify(midnight.messages));
      const moved=injector.transform(await context([...original,user("Move",6)]),"2026-10-17","/new-fixture");
      check("cwd change leaves original prefix intact",JSON.stringify(moved.messages.slice(0,before.messages.length))===JSON.stringify(before.messages));
      async function capture(ctx) {
        let payload; const controller=new AbortController();
        await streamAnthropic(model,ctx,{apiKey:"sk-ant-api-fixture-not-real",credentialId:42,isOAuth:true,cacheRetention:"long",sessionId:"identity-audit",signal:controller.signal,onPayload:p=>{payload=p;controller.abort();},fetch:async()=>{networkCalls++;throw Error("Network forbidden");}}).result();
        if(!payload)throw Error("No provider payload");return payload;
      }
      const clean = x => JSON.parse(JSON.stringify(x,(key,value)=>key==="cache_control"?undefined:value));
      const wireBefore=clean(await capture(before)), wireAfter=clean(await capture(midnight));
      check("provider system and tools stay fixed",JSON.stringify(wireBefore.system)===JSON.stringify(wireAfter.system) && JSON.stringify(wireBefore.tools)===JSON.stringify(wireAfter.tools));
      check("provider message prefix survives midnight",JSON.stringify(wireAfter.messages.slice(0,wireBefore.messages.length))===JSON.stringify(wireBefore.messages));
      check("zero network calls",networkCalls===0);
      writeFileSync(process.env.KNARR_CACHE_AUDIT_OUTPUT,JSON.stringify({passed:results.filter(x=>x.passed).length,failed:results.filter(x=>!x.passed).length,networkCalls,results,wireBefore,wireAfter},null,2));
    } catch(error) {
      writeFileSync(process.env.KNARR_CACHE_AUDIT_OUTPUT,JSON.stringify({error:String(error),stack:error.stack,results,networkCalls},null,2));
    }
  })();
}
