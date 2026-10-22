#!/usr/bin/env python3
"""Rebuild the pinned OMP dependency under .runtime; installation still requires the reviewed binary hash."""
import hashlib
import json
import os
from pathlib import Path
import platform
import subprocess

root = Path(__file__).resolve().parent.parent
manifest = json.loads((root / 'Runtime/OMP/manifest.json').read_text())
source = root / '.runtime/omp-source'
cache = root / '.runtime/omp-build-inputs'
if platform.system() != 'Darwin' or platform.machine() != 'arm64':
    raise SystemExit('Build on macOS arm64; the output contains both arm64 and x64 artifacts.')
if source.exists():
    raise SystemExit('Existing .runtime/omp-source is preserved. Use a fresh worktree to rebuild.')
cache.mkdir(parents=True, exist_ok=True)

def fetch(url, name, digest):
    dest = cache / name
    if not dest.exists():
        subprocess.run(['curl', '--fail', '--location', '--silent', '--show-error', '--max-time', '120', url, '-o', str(dest)], check=True)
    if hashlib.sha256(dest.read_bytes()).hexdigest() != digest:
        raise SystemExit('Input checksum mismatch: ' + str(dest))
    return dest

archive = fetch(manifest['sourceURL'], 'source.tar.gz', manifest['sourceSHA256'])
bun_archive = fetch('https://github.com/oven-sh/bun/releases/download/bun-v1.4.0/bun-darwin-aarch64.zip', 'bun.zip', manifest['bunArm64SHA256'])
subprocess.run(['unzip', '-q', '-o', str(bun_archive), '-d', str(cache)], check=True)
bun = cache / 'bun-darwin-aarch64/bun'
source.mkdir()
subprocess.run(['tar', '-xzf', str(archive), '-C', str(source), '--strip-components=1'], check=True)
patch = root / 'Runtime/OMP/prefix-replay.patch'
if hashlib.sha256(patch.read_bytes()).hexdigest() != manifest['patchSHA256']:
    raise SystemExit('Patch checksum mismatch')
subprocess.run(['patch', '--batch', '-p1', '-i', str(patch)], cwd=source, check=True)
env = dict(os.environ, PATH=str(bun.parent) + os.pathsep + os.environ['PATH'])
subprocess.run([str(bun), 'install', '--frozen-lockfile', '--ignore-scripts'], cwd=source, env=env, check=True)
for arch in ['arm64', 'x64']:
    archive = fetch(f'https://registry.npmjs.org/@oh-my-pi/pi-natives-darwin-{arch}/-/pi-natives-darwin-{arch}-18.7.0.tgz', f'native-{arch}.tgz', manifest['nativeSHA256'][arch])
    filename = 'pi_natives.darwin-arm64.node' if arch == 'arm64' else 'pi_natives.darwin-x64-baseline.node'
    subprocess.run(['tar', '-xzf', str(archive), '--strip-components=1', '-C', str(source / 'packages/natives/native'), 'package/' + filename], check=True)
subprocess.run([str(bun), 'scripts/ci-release-build-binaries.ts', '--targets', 'darwin-arm64,darwin-x64'], cwd=source, env=env, check=True)
for arch in ['arm64', 'x64']:
    binary = source / f'packages/coding-agent/binaries/omp-darwin-{arch}'
    digest = hashlib.sha256(binary.read_bytes()).hexdigest()
    print(f'{binary}: {digest}; matches reviewed artifact: {digest == manifest["binarySHA256"][arch]}')
# Compiler paths/bytecode/signatures may differ between rebuilds. Never update the trusted pin automatically.
