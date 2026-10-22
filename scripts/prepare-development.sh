#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

usage() {
  echo "Usage: bash scripts/prepare-development.sh --check | /absolute/path/to/verified/omp"
}
[[ $# -eq 1 ]] || { usage >&2; exit 2; }
[[ "$1" != --help ]] || { usage; exit 0; }
[[ "$(uname -s)" == Darwin ]] || { echo "macOS가 필요합니다." >&2; exit 1; }
for tool in swift node npm python3 git curl codesign; do
  command -v "$tool" >/dev/null || { echo "필요한 도구가 없습니다: $tool" >&2; exit 1; }
done
if [[ "$1" == --check ]]; then
  swift --version
  node --version
  npm --version
  python3 --version
  echo "기본 도구 확인 완료. 실제 실행에는 검증된 OMP 바이너리가 필요합니다."
  exit 0
fi
[[ "$1" == /* && -f "$1" ]] || { echo "검증된 OMP 바이너리의 절대 경로를 전달하세요." >&2; exit 2; }
bash scripts/install-omp.sh "$root/.runtime/omp" "$1"
bash scripts/install-session-api.sh
bash scripts/build-chat-ui.sh
echo "개발 의존성 준비 완료. docs/GETTING_STARTED.md의 전용 데이터 실행 방법을 확인하세요."
