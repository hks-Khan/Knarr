#!/usr/bin/env python3
"""Exercise the packaged app's real startup/store/MCP, isolated from user data and focus.
The outer qa-owned-run wrapper is the independent descendant reaper for every exit path.
"""
import asyncio
import json
import os
from pathlib import Path
import plistlib
import shutil
import sqlite3
import subprocess
import time
import uuid
from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client

root = Path.cwd().resolve()
run = root / 'outputs/qa-candidate/live-mcp' / str(uuid.uuid4())
run.mkdir(parents=True)
app = run / 'Knarr MCP QA.app'
shutil.copytree(root / 'outputs/Knarr.app', app)
info_path = app / 'Contents/Info.plist'
info = plistlib.loads(info_path.read_bytes())
qa_bundle = 'com.kyen.knarr.qa.mcp.' + run.name
info.update(CFBundleIdentifier=qa_bundle, CFBundleName='Knarr MCP QA', LSUIElement=True)
info_path.write_bytes(plistlib.dumps(info))
profile = app / 'Contents/embedded.provisionprofile'
if profile.exists(): profile.unlink()
subprocess.run(['codesign', '--force', '--deep', '--sign', '-', '--timestamp=none', str(app)], check=True)
subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
data = run / 'data'; data.mkdir()
project_path = run / 'project'; project_path.mkdir()
(project_path / 'README.md').write_text('Isolated MCP integration fixture. No user project data.\n')
socket_dir = Path('/tmp') / ('knarr-app-' + uuid.uuid4().hex[:10]); socket_dir.mkdir(mode=0o700)
sock = socket_dir / 'knarr.sock'
bridge = app / 'Contents/MacOS/knarr-mcp'
env = dict(os.environ, KNARR_DATA_DIRECTORY=str(data), KNARR_MCP_SOCKET=str(sock), KNARR_MOBILE='0',
           KNARR_PROJECT_PATH=str(project_path), KNARR_SKIP_JITDECK_IMPORT='1', KNARR_QA_BACKGROUND='1')
process = None
receipt = {'root':str(run), 'candidateVersion':info['CFBundleVersion'], 'steps':[], 'appPIDs':[]}
app_log = (run / 'app.log').open('wb')

def launch():
    global process
    process = subprocess.Popen([str(app / 'Contents/MacOS/Knarr')], env=env, stdout=app_log, stderr=app_log)
    receipt['appPIDs'].append(process.pid)
    print('Real QA app PID=' + str(process.pid), flush=True)

async def ready():
    deadline = time.monotonic()+40
    while not sock.exists():
        assert process.poll() is None, 'app exited before socket'
        assert time.monotonic() < deadline, 'socket startup timeout'
        await asyncio.sleep(.1)
    async with stdio_client(StdioServerParameters(command=str(bridge), args=[], env=env)) as (read, write):
        async with ClientSession(read, write) as session:
            await session.initialize()
            while time.monotonic() < deadline:
                result = await session.call_tool('list_projects', {})
                if not result.isError:
                    projects = result.structuredContent['projects']
                    assert len(projects) == 1 and projects[0]['path'] == str(project_path), projects
                    return projects[0]['projectID']
                await asyncio.sleep(.2)
    raise AssertionError('real app service startup timeout')

def sdk(phase, project):
    with (run / ('sdk-'+phase+'.log')).open('wb') as log:
        subprocess.run(['python3', str(root/'Tests/Runtime/mcp-sdk-roundtrip.py'), phase, str(bridge), str(sock), project],
                       env=env, stdout=log, stderr=subprocess.STDOUT, check=True, timeout=45)
    receipt['steps'].append('sdk:'+phase)
    print('Packaged app SDK '+phase+': passed', flush=True)

def inspect(phase):
    with (run / ('ui-'+phase+'.json')).open('wb') as log:
        subprocess.run(['swift', str(root/'scripts/qa-mcp-inspect.swift'), str(process.pid), phase],
                       stdout=log, stderr=subprocess.STDOUT, check=True, timeout=30)
    receipt['steps'].append('nativeUI:'+phase)
    print('Packaged app native UI '+phase+': passed', flush=True)

def quit():
    subprocess.run(['swift', str(root/'scripts/qa-mcp-inspect.swift'), str(process.pid), 'quit'], check=True, timeout=25)
    assert process.wait(timeout=5) == 0
    assert not sock.exists(), 'normal shutdown left its socket'
    receipt['steps'].append('normalShutdown')

try:
    launch(); project = asyncio.run(ready()); receipt['projectID'] = project
    sdk('create', project); inspect('create')
    sdk('update', project); inspect('update')
    sdk('close', project); inspect('close')
    sdk('lost', project)
    quit()
    launch(); assert asyncio.run(ready()) == project
    sdk('reopen', project)
    connection = sqlite3.connect('file:'+str(data/'knarr.db')+'?mode=ro', uri=True)
    connection.execute('pragma query_only=on')
    issues = [json.loads(p) for (p,) in connection.execute('select payload from issues')]
    runs = connection.execute('select count(*) from runs').fetchone()[0]
    connection.close()
    assert len(issues) == 2 and runs == 0
    archived = next(i for i in issues if i['title'] == 'MCP 화면 연결 확인')
    assert archived['proposal']['version'] == 2 and archived['archivedAt'] is not None
    receipt['database'] = {'issues':len(issues), 'runs':runs, 'archivedVersion':2}
    quit(); receipt['passed'] = True
finally:
    if process is not None and process.poll() is None:
        process.terminate()
        try: process.wait(timeout=5)
        except subprocess.TimeoutExpired: process.kill(); process.wait(timeout=5)
    receipt['appExited'] = process is None or process.poll() is not None
    app_log.close()
    # This execution's unique preference domain is disposable; logs and the QA database stay.
    existing = subprocess.run(['defaults', 'read', qa_bundle], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if existing.returncode == 0:
        cleared = subprocess.run(['defaults', 'delete', qa_bundle], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        receipt['preferencesCleared'] = cleared.returncode == 0
    else:
        receipt['preferencesCleared'] = True
    (run/'receipt.json').write_text(json.dumps(receipt, ensure_ascii=False, indent=2)+'\n')
    # Only this run's unique empty socket directory is removed. All logs and app artifacts stay.
    if sock.exists(): sock.unlink()
    socket_dir.rmdir()
    print('Real app evidence: '+str(run), flush=True)
