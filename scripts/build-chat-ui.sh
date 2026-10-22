#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root/Runtime/ChatUI"
if [[ ! -d node_modules ]]; then npm ci --ignore-scripts --no-audit --no-fund; fi
npm run typecheck
npm run build
