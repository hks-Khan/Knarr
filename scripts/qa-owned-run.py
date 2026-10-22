#!/usr/bin/env python3
"""Run isolated QA commands with a deadline and reclaim only their process group/descendants."""
import argparse
import json
import os
import re
from pathlib import Path
import signal
import subprocess
import threading
import time


def processes():
    output = subprocess.check_output(['/bin/ps', '-axo', 'pid=,ppid=,pgid=,lstart='], text=True)
    return {int(p): (int(parent), int(group), birth) for p, parent, group, birth in (line.split(maxsplit=3) for line in output.splitlines())}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--timeout', type=float, required=True)
    parser.add_argument('--name', required=True)
    parser.add_argument('command', nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ['--'] else args.command
    evidence = Path('outputs/qa-candidate/evidence')
    evidence.mkdir(parents=True, exist_ok=True)
    baseline = processes()
    started = time.monotonic()
    owned = {}
    child = subprocess.Popen(command, start_new_session=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    owned[child.pid] = processes().get(child.pid, (0, 0, None))[2]
    print(f'QA start name={args.name} PID={child.pid} group={child.pid} baseline={len(baseline)} command={command}', flush=True)

    def capture():
        with (evidence / (args.name + '.log')).open('wb') as log:
            for line in iter(child.stdout.readline, b''):
                log.write(line)
                log.flush()
                os.write(1, line)

    reader = threading.Thread(target=capture, daemon=True)
    reader.start()
    timed_out = False
    interrupted = False

    def interrupt(signum, frame):
        nonlocal interrupted
        interrupted = True

    signal.signal(signal.SIGTERM, interrupt)
    signal.signal(signal.SIGINT, interrupt)

    def discover():
        current = processes()
        changed = True
        while changed:
            changed = False
            for pid, (parent, group, birth) in current.items():
                if pid not in baseline and pid not in owned and ((parent in owned and parent in current and current[parent][2] == owned[parent]) or group == child.pid):
                    owned[pid] = birth
                    changed = True
        return current

    try:
        while child.poll() is None and not interrupted:
            discover()
            if time.monotonic() - started >= args.timeout:
                timed_out = True
                break
            time.sleep(0.2)
    finally:
        current = discover()
        for sig, grace in [(signal.SIGTERM, 2), (signal.SIGKILL, 5)]:
            # The new session's group belongs to this command, never the calling terminal/app.
            try:
                if any(pid in current and current[pid][2] == birth and current[pid][1] == child.pid for pid, birth in owned.items()):
                    os.killpg(child.pid, sig)
            except ProcessLookupError:
                pass
            for pid in owned.keys() - {child.pid}:
                if pid in current and pid not in baseline and current[pid][2] == owned[pid]:
                    try:
                        os.kill(pid, sig)
                    except ProcessLookupError:
                        pass
            deadline = time.monotonic() + grace
            while time.monotonic() < deadline:
                child.poll()
                current = discover()
                if not any(pid in current and current[pid][2] == birth for pid, birth in owned.items()):
                    break
                time.sleep(0.1)
        code = child.wait(timeout=1)
        reader.join(timeout=2)
        current = processes()
        remaining = sorted(pid for pid, birth in owned.items() if pid in current and current[pid][2] == birth)
        result = dict(name=args.name, command=command, pid=child.pid, baseline=sorted(baseline), owned=sorted(owned),
                      duration=round(time.monotonic() - started, 3), exit=124 if timed_out else 130 if interrupted else code,
                      remaining=remaining)
        log_text = (evidence / (args.name + '.log')).read_text(errors='replace')
        summary = re.search(r'Test run with (\d+) tests? in (\d+) suites? (passed|failed) after ([\d.]+) seconds', log_text)
        if summary:
            result['tests'] = int(summary[1])
            result['suites'] = int(summary[2])
            result['test_status'] = summary[3]
            result['test_duration'] = float(summary[4])
        (evidence / (args.name + '.json')).write_text(json.dumps(result, indent=2) + '\n')
        rows = ['# 격리 QA 검사 결과', '', '| 검사 | 개수 | 검사 시간(s) | 전체 시간(s) | exit | 잔여 PID |', '|---|---:|---:|---:|---:|---:|']
        for path in sorted(evidence.glob('*.json')):
            item = json.loads(path.read_text())
            rows.append(f"| {item['name']} | {item.get('tests', '—')} | {item.get('test_duration', '—')} | {item['duration']} | {item['exit']} | {len(item['remaining'])} |")
        (evidence / 'verification-results.md').write_text('\n'.join(rows) + '\n')
        print('QA result ' + json.dumps({k: v for k, v in result.items() if k != 'baseline'}), flush=True)
    return result['exit'] or (1 if remaining else 0)


if __name__ == '__main__':
    raise SystemExit(main())
