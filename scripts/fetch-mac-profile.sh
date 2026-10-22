#!/bin/bash
set -euo pipefail
# Let Xcode's automatic signing issue the Mac app's provisioning profile (iCloud CloudKit + push for
# com.kyen.knarr) by building the stub target in Mobile/, then keep a copy for scripts/build-app.sh.
# Needs Xcode signed in to the developer team (Xcode > Settings > Accounts). Run again when the profile expires.
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root/Mobile"
command -v xcodegen >/dev/null || { echo "xcodegen이 필요해요: brew install xcodegen" >&2; exit 1; }
xcodegen generate --quiet
derived="$root/.build/mac-profile"
profile="$derived/Build/Products/Debug/KnarrMacProfile.app/Contents/embedded.provisionprofile"
if ! xcodebuild -project KnarrMobile.xcodeproj -scheme KnarrMacProfile -configuration Debug \
  -derivedDataPath "$derived" -allowProvisioningUpdates build >"$derived.log" 2>&1; then
  # Command-line xcodebuild may not see the account Xcode itself is signed in with ("No Accounts").
  # Building the KnarrMacProfile scheme once in the Xcode app issues the same profile; use that one.
  profile="$(ls -t "$HOME"/Library/Developer/Xcode/DerivedData/KnarrMobile-*/Build/Products/Debug/KnarrMacProfile.app/Contents/embedded.provisionprofile 2>/dev/null | head -1)"
  if [[ -z "$profile" ]]; then
    grep -E 'error:' "$derived.log" >&2 || tail -20 "$derived.log" >&2
    echo "Xcode에서 Mobile/KnarrMobile.xcodeproj를 열고 KnarrMacProfile 스킴을 한 번 빌드(⌘B)한 뒤 다시 실행하세요" >&2
    exit 1
  fi
  echo "Xcode 앱이 만든 프로필을 써요: $profile"
fi
[[ -f "$profile" ]] || { echo "프로필이 만들어지지 않았어요. $derived.log를 확인하세요" >&2; exit 1; }
mkdir -p "$root/.runtime/signing"
cp "$profile" "$root/.runtime/signing/Knarr.provisionprofile"
security cms -D -i "$profile" | plutil -extract Name raw -o - -
security cms -D -i "$profile" | plutil -extract ExpirationDate raw -o - -
echo "저장: .runtime/signing/Knarr.provisionprofile"
