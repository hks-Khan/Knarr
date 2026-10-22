# 구조와 코드 읽기

## 책임 구분

```text
사용자
  → SwiftUI 앱 + React 대화 화면
  → KnarrCore: 대화·프로젝트·이슈·승인·저장
  → OMP RPC: 모델 호출과 도구 실행
  → 작업본의 변경 및 결과

Mac의 작업 정보 ↔ CloudKit 개인 DB ↔ iPhone / iPad
```

OMP는 외부 실행 엔진입니다. Knarr가 구현하는 부분은 사용자의 요청을 프로젝트와 이슈로 관리하고, 승인·실행·질문·결과를 저장하고 보여주는 제품 흐름입니다. Knarr의 OMP 패치는 [별도 문서](OMP_RUNTIME.md)에 설명합니다.

## 모듈

| 위치 | 역할 |
| --- | --- |
| `Sources/KnarrCore` | 모델, SQLite 저장, 프로젝트와 이슈, Stallari/Hird, OMP 연결 |
| `Sources/KnarrUI` | SwiftUI 화면과 WKWebView 브리지 |
| `Runtime/ChatUI` | React/TypeScript 기반 대화 렌더러 |
| `Sources/KnarrApp` | Mac 앱 진입점과 시스템 연동 |
| `Sources/KnarrSync` | Mac과 모바일이 공유하는 레코드·CloudKit 표현 |
| `Sources/KnarrMirror` | Mac 상태를 모바일 레코드로 투영하고 요청을 적용 |
| `Sources/KnarrMCP`, `Sources/KnarrMCPBridge` | 로컬 MCP 연결과 실행 파일 |
| `Mobile` | iPhone·iPad 앱 및 Live Activity |
| `Sources/KnarrSnapshot` | 예시 데이터 기반 화면 렌더링 |
| `Tests` | 저장, 상태, 실행, 화면 연결과 런타임 검증 |

## 대화에서 작업까지

Stallari는 대화를 통해 프로젝트 정보를 읽고 이슈·제안·완료 조건을 관리합니다. Hird는 승인된 실행 지시에 따라 분리된 작업본에서 코딩 작업을 수행합니다. 저장된 제안과 승인 버전을 연결해 사용자가 본 내용과 실행하는 내용의 대응을 유지합니다.

OMP의 요청 접수 응답과 실제 모델 작업 종료 이벤트는 구분됩니다. Knarr는 실행 상태, 질문, 결과 자료, 검증과 통합 여부를 각각 다룹니다.

읽기 시작점: `KnarrStore.swift`, `Live/LiveKnarrStore.swift`, `Stallari/`, `Hird/`, `OMP/OMPRPCSession.swift`.

## 기록과 복구

SQLite 계층은 대화·프로젝트·이슈와 실행 상태를 저장합니다. 앱 재시작과 저장 실패, 스키마 이전, 취소·재개를 다루는 검사가 `Tests/KnarrCoreTests/Persistence`와 관련 기능 테스트에 있습니다.

작업 결과는 실행 종료 상태만으로 완료 처리하지 않고 검증 자료와 반영 상태를 함께 다룹니다. 작업본과 결과 자료의 보존 경로는 `Hird` 구현 및 테스트에서 확인할 수 있습니다.

## 화면

SwiftUI는 앱의 화면과 패널을 구성하고, React 대화 렌더러는 스트리밍 메시지·코드·표·이미지를 표시합니다. 웹 렌더러는 브리지를 통해 상태를 받고 동작을 전달합니다. UI는 `KnarrStore` 계약을 통해 동작하며 실행 엔진 구현을 직접 소유하지 않습니다.

## 모바일

작업 실행은 Mac에서 이루어집니다. 모바일 앱은 CloudKit 개인 DB로 상태를 읽고 요청을 전달합니다. 모바일 앱만 실행한 상태에서 Mac 작업을 대신 수행하지 않습니다. 계정과 컨테이너 준비는 [개발 환경 준비](GETTING_STARTED.md)에 있습니다.
