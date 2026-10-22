#!/bin/bash
set -euo pipefail
# Install outputs/Knarr.app into ~/Applications. A previous install is kept as Knarr.app.previous.
root="$(cd "$(dirname "$0")/.." && pwd)"
source_app="$root/outputs/Knarr.app"
target="$HOME/Applications/Knarr.app"
[[ -d "$source_app" ]] || { echo "먼저 scripts/build-app.sh로 앱을 만드세요" >&2; exit 1; }
codesign --verify --strict "$source_app"
if pgrep -f "$target/Contents/MacOS/Knarr" >/dev/null; then echo "설치된 Knarr가 실행 중이에요. 종료한 뒤 다시 설치하세요" >&2; exit 1; fi
mkdir -p "$HOME/Applications"
if [[ -d "$target" ]]; then rm -rf "$target.previous"; mv "$target" "$target.previous"; fi
ditto "$source_app" "$target"
codesign --verify --strict "$target"
printf 'Installed %s (%s)\n' "$target" "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$target/Contents/Info.plist")"
