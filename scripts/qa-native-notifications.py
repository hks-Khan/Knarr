#!/usr/bin/env python3
"""Run only our synthetic .app, collect its own stack on timeout, and reap its process."""
import argparse
import json
from pathlib import Path
import subprocess
import sys

root = Path.cwd().resolve()
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--status-only', action='store_true', help='Query public authorization once; never request or post.')
options = parser.parse_args()
data = root / 'outputs/native-notifications-qa'
binary = root / 'outputs/Knarr Notification QA.app/Contents/MacOS/knarr-notification-qa'
if not binary.is_file():
    raise SystemExit('먼저 scripts/package-notification-qa.py를 실행하세요.')
data.mkdir(parents=True, exist_ok=True)
command = [str(binary)] + (['--status-only'] if options.status_only else [])
with (data / 'probe-stdout.log').open('w') as log:
    process = subprocess.Popen(command, cwd=root, stdout=log, stderr=subprocess.STDOUT)
    print('Owned synthetic QA PID: ' + str(process.pid), flush=True)
    try:
        code = process.wait(timeout=30)
    except subprocess.TimeoutExpired:
        stack = data / 'timeout-stack.txt'
        sample = subprocess.run(['/usr/bin/sample', str(process.pid), '1', '1', '-file', str(stack)],
                                timeout=10, capture_output=True, text=True)
        print('Owned process stack: ' + str(stack) + ' sample exit=' + str(sample.returncode), flush=True)
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=5)
        code = 124
    finally:
        if process.poll() is None:
            process.kill()
            process.wait(timeout=5)
    print('Owned synthetic QA process reaped: ' + str(process.pid), flush=True)
result = dict(command=command, exitCode=code, ownedPID=process.pid, processReaped=process.poll() is not None)
events = data / 'events.jsonl'
if events.is_file():
    rows = [json.loads(line) for line in events.read_text().splitlines() if line]
    result['lastEvent'] = rows[-1] if rows else None
(data / 'probe-result.json').write_text(json.dumps(result, indent=2) + '\n')
print(json.dumps(result, ensure_ascii=False))
sys.exit(code)
