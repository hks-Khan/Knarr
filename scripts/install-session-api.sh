#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
mkdir -p .runtime/session-api
cp Runtime/SessionAPI/package.json Runtime/SessionAPI/package-lock.json .runtime/session-api/
npm ci --prefix .runtime/session-api --ignore-scripts --omit=optional --legacy-peer-deps --no-audit --no-fund
node --input-type=module -e 'import {readFileSync} from "node:fs"; const p=JSON.parse(readFileSync(".runtime/session-api/node_modules/@anthropic-ai/claude-agent-sdk/package.json")); if(p.version!=="0.3.284") process.exit(1); console.log("Claude session SDK "+p.version);'
