#!/usr/bin/env bash
# Renders the chat inline-image scenes from real WKWebViews and saves the light/dark PNGs.
# Kept as a file so the plain `swift test --filter ChatWebIntegrationTests` run stays clean.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
export KNARR_WEB_SCREENSHOTS="$root/docs/evidence/chat-inline-images"
mkdir -p "$KNARR_WEB_SCREENSHOTS"
cd "$root"
swift test --filter ChatWebIntegrationTests
