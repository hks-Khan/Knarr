#!/usr/bin/env python3
"""Build this worktree's candidate with a read-only runtime link, then remove that link."""
import argparse
import os
from pathlib import Path
import signal
import subprocess
import tempfile

parser = argparse.ArgumentParser()
parser.add_argument('--runtime', required=True)
parser.add_argument('--ad-hoc', action='store_true', help='Build a QA-only candidate without reading signing profiles or the keychain')
args = parser.parse_args()
root = Path.cwd().resolve()
runtime = Path(args.runtime).resolve()
link = root / '.runtime'
if link.exists() or link.is_symlink():
    raise SystemExit('기존 .runtime을 보존합니다. QA 빌드는 빈 경로에서 실행하세요.')
if not (runtime / 'omp/18.7.0/omp').is_file() or not (runtime / 'session-api/node_modules/@anthropic-ai/claude-agent-sdk/package.json').is_file():
    raise SystemExit('고정 OMP/세션 SDK 런타임이 없습니다: ' + str(runtime))


def interrupted(signum, frame):
    raise KeyboardInterrupt

signal.signal(signal.SIGTERM, interrupted)
signal.signal(signal.SIGINT, interrupted)
staging = None
if args.ad_hoc:
    # The build script sees only OMP and the session SDK, never the production signing directory.
    staging = tempfile.TemporaryDirectory(prefix='knarr-qa-runtime-', dir=root / 'outputs')
    source = runtime
    runtime = Path(staging.name)
    for name in ('omp', 'session-api'):
        (runtime / name).symlink_to(source / name, target_is_directory=True)
os.symlink(runtime, link, target_is_directory=True)
print('QA temporary runtime link: ' + str(link) + ' -> ' + str(runtime), flush=True)
try:
    environment = os.environ.copy()
    environment['KNARR_BUILD_ROOT'] = str(root / 'outputs/qa-candidate/build')
    if args.ad_hoc:
        environment['KNARR_SIGN_IDENTITY'] = '-'
    result = subprocess.run([str(root / 'scripts/build-app.sh')], env=environment)
finally:
    if link.is_symlink() and Path(os.readlink(link)) == runtime:
        link.unlink()
        print('QA temporary runtime link removed', flush=True)
    if staging is not None:
        staging.cleanup()
raise SystemExit(result.returncode)
