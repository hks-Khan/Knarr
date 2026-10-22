#!/bin/bash
set -euo pipefail
# One-shot external helper. Never signals the app or accesses auth files.
parent="$1"; source="$2"; target="$3"; database="$4"; job="$5"; launcher="$6"; limit="${7:-120}"
exec >> "$job/install.log" 2>&1
stage="${target}.knarr-stage-$(basename "$job")"
old="${target}.knarr-old-$(basename "$job")"
installed=false
cleanup() {
  status=$?
  if [[ "$installed" == false && -d "$old" && ! -e "$target" ]]; then mv "$old" "$target"; fi
  [[ ! -e "$stage" ]] || rm -rf "$stage"
  printf 'exit=%s\n' "$status"
}
trap cleanup EXIT
printf 'waiting parent=%s\n' "$parent"
start=$SECONDS
while kill -0 "$parent" 2>/dev/null; do
  if (( SECONDS - start >= limit )); then echo '정상 종료 대기 상한 초과 · 설치하지 않음'; exit 1; fi
  sleep 0.1
done
[[ -f "$job/shutdown-ready" ]] || { echo '정상 종료 확인 기록 없음 · 설치하지 않음'; exit 1; }
[[ -d "$source" && -d "$target" && -f "$database" ]] || { echo '후보 앱·설치 대상·DB 경로 없음'; exit 1; }
/usr/bin/codesign --verify --strict "$source"
source_id=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$source/Contents/Info.plist")
target_id=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$target/Contents/Info.plist")
[[ "$source_id" == com.kyen.knarr && "$source_id" == "$target_id" ]] || { echo '앱 식별자가 다름'; exit 1; }
# Backup after the app closed its database. Fixed relative destination avoids dot-command quoting.
cd "$job"
/usr/bin/sqlite3 "$database" ".backup 'knarr.db.backup'"
[[ "$(/usr/bin/sqlite3 "$job/knarr.db.backup" 'PRAGMA quick_check')" == ok ]]
echo 'database backup complete'
/usr/bin/ditto "$source" "$stage"
/usr/bin/codesign --verify --strict "$stage"
mv "$target" "$old"
mv "$stage" "$target"
installed=true
rm -rf "$old"
echo 'installation complete'
"$launcher" -n "$target"
echo 'relaunch requested'
rm -rf "$source"
rm -f "$job/shutdown-ready" "$job/install-restart.sh"
