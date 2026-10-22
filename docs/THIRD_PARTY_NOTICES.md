# Third-party software

Knarr의 Swift 코드는 Apple 시스템 프레임워크(SwiftUI, AppKit, Foundation, Observation, QuartzCore, CryptoKit, Darwin/libproc)를 사용합니다. 실행 엔진으로 다음 고정 외부 실행 파일을 설치합니다.

| 이름 | 버전 | 라이선스 | 용도 |
|---|---|---|---|
| SQLite3 (Apple 시스템 라이브러리) | OS 제공 버전; 이 검증 환경은 3.51.0 / macOS 26.4 | Public domain | 로컬 SQLite 저장·트랜잭션 |
| Oh My Pi (OMP) | 18.7.0 + Knarr patch 2 / upstream v18.7.0 | MIT; 바이너리의 포함 구성요소는 공식 THIRD-PARTY-NOTICES.txt 참조 | OMP의 RPC 실행 엔진 |

공식 출처: <https://github.com/can1357/oh-my-pi/releases/tag/v18.7.0>. 설치·발견·지원 범위와 고정 체크섬은 [OMP_RUNTIME.md](OMP_RUNTIME.md)에 기록했습니다. SwiftPM 외부 패키지는 추가하지 않았습니다.

OMP의 MIT 고지와 허가문 전문은 [licenses/OMP-18.7.0-MIT.txt](licenses/OMP-18.7.0-MIT.txt)에 보존합니다.

- Copyright (c) 2025 Mario Zechner
- Copyright (c) 2025-2026 Can Bölük
- Copyright (c) 2026 Stencil Labs, Inc.

설치 스크립트는 공식 릴리스의 `LICENSE`와 `THIRD-PARTY-NOTICES.txt`를 실행 파일 옆에 설치합니다. 바이너리를 앱 번들에 포함하는 통합 단계에서도 두 파일을 함께 배포해야 합니다. 포함된 의존성의 라이선스를 모두 MIT로 간주하지 않습니다.

SQLite3는 외부 패키지를 내려받지 않고 SDK의 `sqlite3.h`와 시스템 `libsqlite3`를 CSQLite module map으로 연결합니다. OS/SDK 버전에 따르며, 별도 바이너리 버전을 고정한 의존성이 아닙니다. SQLite 저작권·라이선스 원문: <https://sqlite.org/copyright.html>.

## 로컬 대화 조회

- `@anthropic-ai/claude-agent-sdk` **0.3.284**, 공식 배포 패키지. 라이선스는 패키지 `LICENSE.md` 및 `README.md`의 Anthropic 조건을 따릅니다. `Runtime/SessionAPI/package-lock.json`에 버전과 integrity를 고정합니다. 앱에 패키지와 라이선스 원문을 함께 포함합니다.
- 사용하는 SDK 함수는 `listSessions`, `getSessionInfo`, `getSessionMessages`입니다. 모델 질의·인증정보 복사·세션 변경은 호출하지 않습니다.
- Codex CLI와 Node.js는 사용자가 설치한 실행 파일을 사용합니다. Codex의 `initialize`, `thread/list`, `thread/read`, `thread/items/list`만 호출하며 모델 실행을 시작하지 않습니다.

## 모션 값 참고

- **transitions.dev** `skills/transitions-dev`, commit `2773886681b6bb8effe0d7b5c66306430d18e000` (2026-10-10). Transitions.dev License: 제품 안에서 사용·수정 허용, 라이브러리 자체의 재배포 금지. 출처: <https://github.com/Jakubantalik/transitions.dev>.
- 코드나 패키지는 가져오지 않았습니다. 모션 토큰 값(시간·이징·거리·흐림)과 전환 패턴만 SwiftUI로 옮겨 `Sources/KnarrUI/Motion.swift`에 반영했습니다.


## FastList의 호스팅 셀 부분 재사용

- 고정 출처: https://github.com/adamtheturtle/FastList/blob/a78ebeb4c9df7293aa36ee8baafbb91c10f1158d/Sources/FastList/AppKitSupport.swift
- 버전: `a78ebeb4c9df7293aa36ee8baafbb91c10f1158d`.
- 라이선스: MIT, Copyright (c) 2026 Adam Dangoor. 원문은 `docs/licenses/FastList-MIT.txt`에 보존합니다.
- 적용 파일: `Sources/KnarrUI/TranscriptList.swift`의 `TranscriptHostingCell`. `NSHostingView` 생성·재사용 및 셀 가장자리 제약 부분을 재사용했습니다. 전체 FastList 패키지는 연결하지 않습니다.
- Knarr는 방문한 호스트를 메시지 ID로 보존해 펼침과 작성 중 검토 메모가 재사용 과정에서 사라지지 않게 합니다. 행 높이는 `fittingSize` 대신 실제 너비에서 배치된 SwiftUI geometry로 측정합니다.

## KiroCrew 대화 가상화 참고

- 고정 버전: `9c33de89de77febd36e7e6ca3bc3558f2bbb5da2`, Apache-2.0.
- 원문: https://github.com/kirodotdev/KiroCrew/blob/9c33de89de77febd36e7e6ca3bc3558f2bbb5da2/website/src/chat-core/transcript/VirtualTranscript.tsx 및 `website/src/hooks/virtualizer/{useVirtualChat,HeightCache,inPlaceResize}.ts`, `website/src/pages/chat/TranscriptScrollShell.tsx`.
- 화면 범위만 배치, 안정된 메시지 ID, 크기 변경 시 읽던 위치 보존, 맨 아래에서 답변 성장 따라가기 원리를 참고했습니다. 이전 AppKit `NSTableView` 구현의 참고 기록입니다. 현재 React 채팅이 사용하는 패키지는 아래에 별도로 기재합니다.
- KiroCrew의 폭 bucket/settle은 캐시 쓰기를 조절합니다. Knarr도 실제 화면 너비 변경을 지연시키지 않습니다.

## Markdown 블록 재사용 참고

- MarkdownUI (MIT), 고정 버전 `8371aeb32f35795a9e559029fb08613355733626`: https://github.com/gonzalezreal/swift-markdown-ui/blob/8371aeb32f35795a9e559029fb08613355733626/Sources/MarkdownUI/Views/Blocks/BlockSequence.swift 및 `DSL/Blocks/MarkdownContent.swift`.
- Streamdown 블록별 메모이제이션 문서: https://streamdown.ai/docs/memoization .
- `MarkdownText.swift`에서 동일한 완료 블록의 SwiftUI 렌더링을 `Equatable`로 재사용합니다. 두 프로젝트의 구현 소스나 패키지는 추가하지 않았으며, 본문 변경 시 전체 블록 파싱은 여전히 수행합니다.
- Microsoft SwiftStreamingMarkdown (MIT), `95bb755a9b23a1aea8682b9ebc912cb72b176c95`의 `StreamedMarkdownView.swift`, `UI/Paragraph/ParagraphViewCache.swift`도 검토했습니다. 전체 snapshot을 다시 파싱하며 문단 캐시만으로 전체 대화가 가상화되지 않아 도입하지 않았습니다.

## React 채팅 렌더러

앱에 번들한 웹 채팅은 React/React DOM 19.2.3, OpenUI react-lang/lang-core 1.0.0, TanStack React Virtual 3.13.12, react-markdown 10.1.0, remark-gfm 4.0.1, rehype-highlight 7.0.2, Zod 4.4.3을 사용합니다. 정확한 전이 의존성은 `Runtime/ChatUI/package-lock.json`에 고정됩니다.

실제 번들에 포함된 패키지의 이름·버전·라이선스 원문은 `Sources/KnarrUI/Resources/ChatWeb/THIRD_PARTY_NOTICES.txt`에 빌드 시 생성되며, 코드 저작권 주석 `app.js.LEGAL.txt`와 함께 앱 리소스에 포함됩니다.
