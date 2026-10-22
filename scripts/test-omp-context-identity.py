#!/usr/bin/env python3
"""Run the offline context regression fixture against an explicit OMP binary."""
import subprocess,pathlib,os,json,time,signal,tempfile,sys
BASE=pathlib.Path(sys.argv[2]).resolve();BASE.mkdir(parents=True,exist_ok=True)
BINARY=str(pathlib.Path(sys.argv[1]).resolve())
(BASE/'wire-result.json').unlink(missing_ok=True)
DRIVER=str(pathlib.Path(__file__).resolve().parents[1]/'Runtime/OMP/context-identity-fixture.ts')
fixture=pathlib.Path(tempfile.mkdtemp(prefix='knarr-cache-repro-',dir='/private/tmp'))
def ps():
 rows={}
 for l in subprocess.check_output(['/bin/ps','-axo','pid=,ppid=,pgid=,lstart=,comm='],text=True).splitlines():
  a=l.strip().split(None,8)
  if len(a)>=9:rows[int(a[0])]={'pid':int(a[0]),'ppid':int(a[1]),'pgid':int(a[2]),'started':' '.join(a[3:8]),'command':a[8]}
 return rows
baseline=ps();owned=[];clean=[]
def run(argv,env=None,timeout=45):
 p=subprocess.Popen(argv,env=env,cwd=fixture,stdin=subprocess.DEVNULL,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,start_new_session=True)
 identity=ps().get(p.pid);owned.append({'pid':p.pid,'identity':identity,'argv':argv})
 try:
  stdout,stderr=p.communicate(timeout=timeout)
  (BASE/('process-'+str(p.pid)+'.stdout')).write_text(stdout)
  (BASE/('process-'+str(p.pid)+'.stderr')).write_text(stderr)
  return {'exitCode':p.returncode,'stdout':stdout[-3000:],'stderr':stderr[-3000:]}
 finally:
  now=ps();members=[x for x in now.values() if x['pgid']==p.pid and x['pid'] not in baseline]
  for x in members:
   fresh=ps().get(x['pid'])
   if fresh==x:
    try:os.kill(x['pid'],signal.SIGTERM)
    except ProcessLookupError:pass
  # A child can outlive an already-reaped parent. Wait and escalate by child
  # identity, independently of whether p.wait() reports the parent as done.
  def remaining_members():
   current=ps()
   return [x for x in members if (fresh:=current.get(x['pid'])) and fresh['started']==x['started'] and fresh['command']==x['command']]
  deadline=time.monotonic()+3
  remaining=remaining_members()
  while remaining and time.monotonic()<deadline:
   p.poll();time.sleep(0.05);remaining=remaining_members()
  for x in remaining:
   fresh=ps().get(x['pid'])
   if fresh and fresh['started']==x['started'] and fresh['command']==x['command']:
    try:os.kill(x['pid'],signal.SIGKILL)
    except ProcessLookupError:pass
  p.wait(timeout=3)
  deadline=time.monotonic()+3
  remaining=remaining_members()
  while remaining and time.monotonic()<deadline:
   time.sleep(0.05);remaining=remaining_members()
  after=ps()
  remaining=[x for x in after.values() if x['pgid']==p.pid and x['pid'] not in baseline]
  clean.append({'pid':p.pid,'membersBeforeCleanup':members,'remaining':remaining})
  if remaining:raise RuntimeError('Owned processes remain')
results={'fixture':str(fixture),'baselineProcessCount':len(baseline)}
try:
 config=fixture/'config.yml';config.write_text('disabledProviders: [native, omp-managed, agent-plugins, agents, agents-md, claude, claude-md, claude-plugins, cline, codex, cursor, gemini, github, mcp-json, omp-plugins, opencode, skillshare, ssh, vscode, windsurf]\ncompaction:\n  enabled: false\nlsp:\n  enabled: false\n')
 env={'PATH':'/usr/bin:/bin:/usr/sbin:/sbin','PI_CODING_AGENT_DIR':str(fixture/'agent'),'PI_CONFIG_DIR':str(fixture/'config'),'KNARR_CACHE_AUDIT_OUTPUT':str(BASE/'wire-result.json'),'TMPDIR':str(fixture)}
 args=[BINARY,'--mode','rpc','--model','cache-audit-fixture/deterministic','--thinking','off','--no-extensions','--no-skills','--no-rules','--no-lsp','--no-session','--config',str(config),'--trusted-extension',DRIVER]
 results['omp']=run(args,env=env)
finally:
 results['owned']=owned;results['cleanup']=clean;(BASE/'execution.json').write_text(json.dumps(results,indent=2))
print(json.dumps({'ompExit':results['omp']['exitCode'],'owned':results['owned'],'cleanup':results['cleanup'],'fixture':results['fixture']},indent=2))
report=json.loads((BASE/'wire-result.json').read_text())
print(json.dumps({k:v for k,v in report.items() if k not in ['wireBefore','wireAfter']},indent=2))
raise SystemExit(1 if report.get('error') or report.get('failed') or not report.get('results') or results['omp']['exitCode'] else 0)
