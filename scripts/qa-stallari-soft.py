#!/usr/bin/env python3
"""Opt-in actual OMP soft-compaction/restart check in a private transcript copy.
Uses the user's existing OMP login; never copies credentials or touches live history.
Run under qa-owned-run.py so exceptional exits reclaim this run's children.
"""
import argparse, hashlib, json, os, queue, re, shutil, subprocess, threading, time
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument('--session', required=True)
parser.add_argument('--tool-request', required=True)
parser.add_argument('--omp', required=True)
parser.add_argument('--output', required=True)
parser.add_argument('--prepared', help='Reuse an already generated soft summary; do not pay for another compaction')
args = parser.parse_args()
out = Path(args.output).resolve(); out.mkdir(parents=True, exist_ok=False)
sessions = out / 'sessions'; sessions.mkdir()
source = Path(args.session); transcript = sessions / source.name
shutil.copy2(Path(args.prepared) if args.prepared else source, transcript); os.chmod(transcript, 0o600)
original = source.read_bytes()
(out / 'source-snapshot.sha256').write_text(hashlib.sha256(original).hexdigest()+'\n')
code = Path('Sources/KnarrCore/Stallari/StallariTools.swift').read_text()
extract = lambda label: code.split('public static let '+label+' = """',1)[1].split('"""',1)[0].strip('\n')
fixed = '\n'.join(line.removeprefix('    ') for line in extract('fixedInstructions').splitlines())
overlay = '\n'.join(line.removeprefix('    ') for line in extract('discoveryOverlay').splitlines())
overlay = re.sub(r'\ncompaction:\n(?:  .*\n?)*', '', '\n'+overlay).strip()+'\n'
config = out/'test.yml'
config.write_text(overlay+'compaction:\n  enabled: false\n  thresholdTokens: 150000\n  methodOrder: [soft]\n  asyncEnabled: false\n')
wire = json.loads(Path(args.tool_request).read_text())['body']['tools']
by_name = {t['name'].removeprefix('_'):t for t in wire}
names = re.findall(r'"([a-z_]+)"',code.split('public static let names = [',1)[1].split(']',1)[0])
tools = [{'name':n,'description':by_name[n]['description'],'parameters':by_name[n]['input_schema'],'loadMode':'essential'} for n in names]

class RPC:
    def __init__(self):
        env = os.environ.copy()
        for key in ['ANTHROPIC_BASE_URL','ANTHROPIC_AUTH_TOKEN','ANTHROPIC_API_KEY']: env.pop(key,None)
        command=[args.omp,'--mode','rpc','--tools','read,grep,glob,task','--smol','openai-codex/gpt-6-luna','--model','anthropic/claude-opus-5-5','--thinking','high','--resume',str(transcript),'--session-dir',str(sessions),'--config',str(config),'--system-prompt',fixed,'--no-lsp','--no-pty','--no-extensions','--no-skills','--no-rules','--no-title','--no-ui']
        self.p=subprocess.Popen(command,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,text=True,bufsize=1,env=env)
        self.q=queue.Queue(); self.sequence=0;self.events=[]
        def read():
            for line in self.p.stdout:
                try:self.q.put(json.loads(line))
                except json.JSONDecodeError:pass
            self.q.put({'type':'process_exit'})
        self.reader=threading.Thread(target=read,daemon=True); self.reader.start()
        self.until(lambda e:e.get('type')=='ready',30)
        self.request('set_host_tools',{'tools':tools})
        state=self.request('get_state').get('data',{})
        assert state['model']['provider']=='anthropic' and state['model']['id']=='claude-opus-5-5',state.get('model')
        assert state.get('thinkingLevel')=='high',state.get('thinkingLevel')
        print('started Opus high PID',self.p.pid,flush=True)
    def send(self,data):
        self.p.stdin.write(json.dumps(data)+'\n');self.p.stdin.flush()
    def until(self,predicate,timeout):
        end=time.monotonic()+timeout
        while time.monotonic()<end:
            e=self.q.get(timeout=max(0.1,end-time.monotonic()));self.events.append(e)
            if e.get('type')=='process_exit':raise RuntimeError('OMP exited')
            if e.get('type')=='host_tool_call':raise RuntimeError('Unexpected host tool call during text-only validation')
            if predicate(e):return e
        raise TimeoutError('RPC timeout')
    def request(self,kind,fields=None,timeout=30):
        self.sequence+=1;ident='soft-check-'+str(self.sequence)
        self.send({'id':ident,'type':kind,**(fields or {})})
        r=self.until(lambda e:e.get('type')=='response' and e.get('id')==ident,timeout)
        if not r.get('success'):raise RuntimeError(json.dumps(r,ensure_ascii=False)[:1000])
        return r
    def prompt(self,marker):
        start=len(self.events)
        r=self.request('prompt',{'message':'격리된 전송 검증입니다. 도구를 사용하거나 실제 작업을 수행하지 마세요. 다른 설명 없이 '+marker+' 한 줄만 답하세요.'},60)
        result=self.until(lambda e:e.get('type')=='prompt_result' and e.get('id')==r['id'],180)
        assert result.get('status') in ['completed','success'],result
        recent=self.events[start:]
        ended=[e['message'] for e in recent if e.get('type')=='message_end' and e.get('message',{}).get('role')=='assistant']
        assert ended and ended[-1].get('stopReason')=='stop',[(m.get('stopReason'),m.get('errorMessage')) for m in ended]
        answer=''.join(x.get('text','') for x in ended[-1].get('content',[]) if x.get('type')=='text')
        assert marker in answer,answer
        return {'marker':marker,'status':result['status'],'model':ended[-1].get('model'),'usage':ended[-1].get('usage')}
    def close(self):
        if self.p.poll() is None:
            self.p.stdin.close()
            try:self.p.wait(timeout=15)
            except subprocess.TimeoutExpired:
                self.p.terminate()
                try:self.p.wait(timeout=5)
                except subprocess.TimeoutExpired:self.p.kill();self.p.wait(timeout=5)
        self.reader.join(timeout=2)
        assert self.p.poll() is not None

rpc=None; report={'source':str(source),'source_snapshot_hash':hashlib.sha256(original).hexdigest(),'paid_model_validation':True}
try:
    rpc=RPC()
    if not args.prepared:
        print('soft compaction starting',flush=True)
        response=rpc.request('compact',{'customInstructions':'Preserve the user decisions, Korean response preferences, pending issues and run IDs, approval requirements, project paths and latest requests. Keep recent context useful. Do not perform any work.'},420)
    state=rpc.request('get_state')['data']
    transcript=Path(state['sessionFile'])
    assert transcript.resolve().is_relative_to(sessions), transcript
    entries=[json.loads(x) for x in transcript.read_text().splitlines() if x.strip()]
    compactions=[e for e in entries if e.get('type')=='compaction']; assert compactions
    compact=compactions[-1]; assert compact.get('method')=='soft',compact.get('method')
    assert not compact.get('preserveData',{}).get('anthropicCompaction')
    report['compaction']={k:compact.get(k) for k in ['id','timestamp','method','tokensBefore','tokensAfter']}
    shutil.copy2(transcript,out/'compacted-base.jsonl')
    print('soft compaction recorded',json.dumps(report['compaction']),flush=True)
    report['after_compaction']=rpc.prompt('KNARR_SOFT_AFTER_OK'); print('after-compaction prompt passed',flush=True)
    rpc.close();rpc=None
    rpc=RPC()
    report['after_restart']=rpc.prompt('KNARR_SOFT_RESTART_OK');print('after-restart prompt passed',flush=True)
    report['success']=True
finally:
    if rpc:rpc.close()
    report['source_unchanged_since_snapshot']=source.read_bytes()==original
    (out/'result.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
