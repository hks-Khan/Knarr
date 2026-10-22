# Knarr 개발 안내

## 제품과 구조

- Knarr는 OMP RPC를 연결하는 macOS 앱입니다. 모델 호출·코딩 도구 실행은 OMP가 담당합니다.
- Stallari는 프로젝트 관리 역할, Hird는 승인된 코딩 작업 역할입니다. 제안·승인 버전과 실행 지시의 대응을 유지합니다.
- `KnarrCore`: 모델·SQLite 저장·프로젝트·이슈·OMP 연결.
- `KnarrUI`: SwiftUI 화면과 WKWebView 브리지. `KnarrStore` 계약을 사용합니다.
- `Runtime/ChatUI`: React/TypeScript 대화 렌더러. 번들은 `scripts/build-chat-ui.sh`로 갱신합니다.
- `KnarrSync`·`KnarrMirror`·`Mobile`: Mac과 모바일의 CloudKit 연결.
- `KnarrSnapshot`: 예시 데이터를 사용하는 화면 렌더러.

## 작업 기준

- 먼저 README와 `docs/ARCHITECTURE.md`, `docs/GETTING_STARTED.md`, `docs/DEVELOPMENT.md`를 읽습니다.
- 요청 범위와 기존 구조를 유지하고, 관련 없는 기능·추상화·리팩터링을 추가하지 않습니다.
- 데이터 저장·승인·실행·취소·복구 변경은 실패 경로를 포함해 관련 테스트로 검증합니다.
- 화면 변경은 실제 실행 화면 또는 `knarr-snapshot` 출력으로 확인합니다.
- 외부 의존성의 버전과 고지를 `docs/THIRD_PARTY_NOTICES.md`에 기록합니다.
- OMP 체크섬 검증과 인증 저장 경계를 유지합니다. 토큰·로그인 URL·운영 대화를 공개 기록에 넣지 않습니다.
- 테스트와 앱 실행에는 전용 데이터·빌드 경로를 사용합니다. 생성한 프로세스와 임시 경로만 정리하고 다른 실행은 건드리지 않습니다.
- `.agent`, `outputs`, `.runtime`과 내부 검증 자료는 공개 소스에 포함하지 않습니다.

## 빠른 확인

```sh
swift build -j 2 --product Knarr
swift test -j 2 --filter OMPInstallationTests
swift run -j 2 knarr-snapshot outputs/preview home-light
```

실제 OMP가 필요한 테스트와 모바일 설정은 개발 문서의 전제조건을 확인합니다.
