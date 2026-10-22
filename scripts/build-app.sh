#!/bin/bash
set -euo pipefail
# Build outputs/Knarr.app: the release binary plus the pinned OMP, signed with the Mac's
# Apple Development certificate (never ad-hoc). Install with scripts/install-app.sh.
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
bash scripts/build-chat-ui.sh
omp_dir=.runtime/omp/18.7.0
[[ -x "$omp_dir/omp" ]] || { echo "OMP 18.7.0이 없어요. 먼저 scripts/install-omp.sh를 실행하세요" >&2; exit 1; }

sdk_dir=.runtime/session-api
[[ -f "$sdk_dir/node_modules/@anthropic-ai/claude-agent-sdk/package.json" ]] || { echo "세션 API SDK가 없어요. 먼저 scripts/install-session-api.sh를 실행하세요" >&2; exit 1; }
node -e 'const p=require("./.runtime/session-api/node_modules/@anthropic-ai/claude-agent-sdk/package.json");if(p.version!=="0.3.284")process.exit(1)'

identity="${KNARR_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ {print $2; exit}')}"
[[ -n "$identity" ]] || { echo "Apple Development 서명 인증서를 찾지 못했어요. KNARR_SIGN_IDENTITY로 지정하세요" >&2; exit 1; }

build_root="${KNARR_BUILD_ROOT:-.build}"
swift build --scratch-path "$build_root" -j "${KNARR_BUILD_JOBS:-2}" -c release --product Knarr
swift build --scratch-path "$build_root" -j "${KNARR_BUILD_JOBS:-2}" -c release --product knarr-mcp

app=outputs/Knarr.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$build_root/release/Knarr" "$app/Contents/MacOS/Knarr"
cp "$build_root/release/knarr-mcp" "$app/Contents/MacOS/knarr-mcp"
codesign --force --sign "$identity" --timestamp=none "$app/Contents/MacOS/knarr-mcp"
cp Assets/Knarr.icns "$app/Contents/Resources/Knarr.icns"
# Package UI artwork under Resources so the application remains sealed for signing.
cp -R "$build_root/release/Knarr_KnarrUI.bundle" "$app/Contents/Resources/Knarr_KnarrUI.bundle"
mkdir -p "$app/Contents/Resources/Licenses"
cp docs/licenses/FastList-MIT.txt "$app/Contents/Resources/Licenses/FastList-MIT.txt"
cp docs/THIRD_PARTY_NOTICES.md "$app/Contents/Resources/THIRD_PARTY_NOTICES.md"
cp Sources/KnarrCore/Resources/session-api.mjs "$app/Contents/Resources/session-api.mjs"
cp Sources/KnarrCore/Resources/install-restart.sh "$app/Contents/Resources/install-restart.sh"
cp -R Sources/KnarrCore/Resources/hird "$app/Contents/Resources/hird"
cp -R Sources/KnarrCore/Resources/stallari "$app/Contents/Resources/stallari"
cp -R Sources/KnarrCore/Resources/instructions "$app/Contents/Resources/instructions"
cp -R Sources/KnarrCore/Resources/hive "$app/Contents/Resources/hive"
mkdir -p "$app/Contents/Resources/SessionAPI"
cp -R "$sdk_dir/node_modules" "$app/Contents/Resources/SessionAPI/"
cp "$sdk_dir/package.json" "$sdk_dir/package-lock.json" "$app/Contents/Resources/SessionAPI/"
# The reviewed patched OMP is copied byte for byte; its pinned checksum is checked at launch.
cp "$omp_dir/omp" "$app/Contents/Resources/omp"
cp "$omp_dir/manifest.json" "$app/Contents/Resources/OMP-manifest.json"
cp "$omp_dir/LICENSE" "$app/Contents/Resources/OMP-LICENSE"
cp "$omp_dir/THIRD-PARTY-NOTICES.txt" "$app/Contents/Resources/OMP-THIRD-PARTY-NOTICES.txt"

commit="$(git rev-parse --short HEAD)"
dirty="$(git status --porcelain --untracked-files=no | head -1)"
build="$commit${dirty:+-dirty}"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>com.kyen.knarr</string>
  <key>CFBundleDevelopmentRegion</key><string>ko</string>
  <key>CFBundleLocalizations</key><array><string>ko</string></array>
  <key>CFBundleName</key><string>Knarr</string>
  <key>CFBundleDisplayName</key><string>Knarr</string>
  <key>CFBundleExecutable</key><string>Knarr</string>
  <key>CFBundleIconFile</key><string>Knarr.icns</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>$build</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

# The phone link needs the iCloud container and push. With a profile from scripts/fetch-mac-profile.sh the app is
# signed with those entitlements; without one it still builds and the phone link stays off.
profile=.runtime/signing/Knarr.provisionprofile
if [[ -f "$profile" ]]; then
  team="$(security cms -D -i "$profile" | plutil -extract TeamIdentifier.0 raw -o - -)"
  cp "$profile" "$app/Contents/embedded.provisionprofile"
  entitlements="$build_root/Knarr.entitlements"
  # The TestFlight iPhone app always talks to CloudKit Production, so the Mac does too unless told otherwise.
  cloud_env="${KNARR_CLOUD_ENVIRONMENT:-Production}"
  [[ "$cloud_env" == Production || "$cloud_env" == Development ]] || { echo "KNARR_CLOUD_ENVIRONMENT는 Production 또는 Development예요" >&2; exit 1; }
  sed -e "s/TEAM_ID/$team/g" -e "s/CLOUD_ENVIRONMENT/$cloud_env/g" Assets/Knarr.entitlements > "$entitlements"
  codesign --force --sign "$identity" --timestamp=none --entitlements "$entitlements" "$app"
else
  echo "프로필이 없어 폰 연결 없이 서명해요. 폰 연결을 쓰려면 scripts/fetch-mac-profile.sh를 먼저 실행하세요" >&2
  codesign --force --sign "$identity" --timestamp=none "$app"
fi
codesign --verify --strict "$app"
printf 'Built %s (%s), signed by %s\n' "$app" "$build" "$identity"
