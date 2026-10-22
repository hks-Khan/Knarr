#!/bin/bash
set -euo pipefail
# Install the reviewed local patch artifact; never silently substitute the unpatched upstream binary.
knarr_root="$(cd "$(dirname "$0")/.." && pwd)"
knarr_destination="${1:-$knarr_root/.runtime/omp}/18.7.0"
case "$(uname -m)" in
  arm64) knarr_arch=arm64 ;;
  x86_64) knarr_arch=x64 ;;
  *) echo 'Unsupported macOS architecture' >&2; exit 1 ;;
esac
[[ "$(uname -s)" == Darwin ]] || { echo 'macOS is required' >&2; exit 1; }
knarr_binary="${2:-$knarr_root/.runtime/omp-source/packages/coding-agent/binaries/omp-darwin-$knarr_arch}"
[[ -f "$knarr_binary" ]] || { echo '패치 후보가 없어요. scripts/build-patched-omp.py로 빌드하거나 검증된 바이너리 경로를 두 번째 인수로 지정하세요.' >&2; exit 1; }
knarr_sha="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["binarySHA256"][sys.argv[2]])' "$knarr_root/Runtime/OMP/manifest.json" "$knarr_arch")"
knarr_actual="$(shasum -a 256 "$knarr_binary" | cut -d ' ' -f 1)"
[[ "$knarr_actual" == "$knarr_sha" ]] || { echo 'OMP patch checksum mismatch; review this rebuilt artifact before changing the pin.' >&2; exit 1; }
[[ "$("$knarr_binary" --version)" == omp/18.7.0 ]] || { echo 'OMP version mismatch' >&2; exit 1; }
codesign --verify --strict "$knarr_binary"
mkdir -p "$knarr_destination"
knarr_staging="$(mktemp -d "$knarr_destination/.install.XXXXXX")"
trap 'rm -rf "$knarr_staging"' EXIT
for knarr_notice in LICENSE THIRD-PARTY-NOTICES.txt; do
  curl --fail --location --silent --show-error --max-time 60 "https://github.com/can1357/oh-my-pi/releases/download/v18.7.0/$knarr_notice" -o "$knarr_staging/$knarr_notice"
done
cp "$knarr_binary" "$knarr_staging/omp"
chmod 755 "$knarr_staging/omp"
cp "$knarr_root/Runtime/OMP/manifest.json" "$knarr_staging/manifest.json"
for knarr_file in LICENSE THIRD-PARTY-NOTICES.txt manifest.json omp; do mv "$knarr_staging/$knarr_file" "$knarr_destination/$knarr_file"; done
printf 'Installed omp/18.7.0 + Knarr patch 2: %s\nSHA256: %s\n' "$knarr_destination/omp" "$knarr_sha"
