# 테스트와 개발

## Swift 빌드

```sh
swift build -j 2 --product Knarr
swift build -j 2 --product knarr-mcp
```

현재 앱의 UI·데이터·실행 코드는 `Sources`, 테스트는 `Tests`에 있습니다. 변경한 영역에 맞는 테스트부터 실행합니다.

```sh
swift test -j 2 --filter OMPInstallationTests
```

테스트 이름은 `swift test list`로 확인할 수 있습니다. 일부 검사는 실제 OMP 설치, macOS 화면 환경 또는 별도 실행 설정이 필요합니다. 테스트 출력의 skip과 failure를 구분해야 합니다.

실제 OMP RPC를 다루는 검사는 검증된 엔진을 설치한 뒤 `KNARR_OMP_EXECUTABLE`을 지정합니다. 네트워크·모델 계정이 필요한 실험은 일반 단위 테스트와 실행 조건을 구분합니다.

## 웹 채팅

```sh
cd Runtime/ChatUI
npm ci --ignore-scripts --no-audit --no-fund
npm run typecheck
npm test
npm run build
```

번들과 외부 패키지 고지는 `Sources/KnarrUI/Resources/ChatWeb`에 생성됩니다. 소스를 수정한 뒤에는 해당 번들을 함께 갱신합니다.

## 화면 검토

```sh
swift run -j 2 knarr-snapshot outputs/preview home-light home-dark
```

예시 데이터로 렌더한 PNG를 확인합니다. 실제 모델의 응답·권한·계정 연결은 별도 검증 범위입니다.

## 개발 데이터와 산출물

개발 실행에는 [전용 데이터 경로](GETTING_STARTED.md#개발-데이터로-실행)를 사용합니다. `.runtime`, `.build`, `outputs`, 개인 서명 파일과 내부 작업 기록은 Git 추적에서 제외합니다.

실행·테스트가 만든 프로세스와 임시 경로는 작업 종료 시 정리하고, 다른 실행의 데이터와 프로세스는 건드리지 않습니다. 검증 결과를 공유할 때에는 명령, 기준 커밋, 성공·실패·생략 범위와 재현 조건을 함께 기록합니다.

## 변경 제안

문제의 재현 조건과 기대 동작을 먼저 설명하고, 변경 범위를 작게 유지합니다. 데이터 저장·실행 상태·취소·복구를 바꾸면 관련 실패 경로도 검증합니다. 외부 라이브러리를 추가할 때는 버전과 고지를 [외부 소프트웨어 문서](THIRD_PARTY_NOTICES.md)에 반영합니다.
