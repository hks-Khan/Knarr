import Foundation
import KnarrSync
import UIKit

/// Illustrative records for `-sample` launches (simulator screenshots, design review). Not real work.
enum SampleRecords {
    static var all: [MobileRecord] {
        let now = Date.now
        func ago(_ s: TimeInterval) -> Date { now.addingTimeInterval(-s) }
        let stages: [MobileIssue.Run.Step] = [
            .init(title: "준비", state: .done), .init(title: "실패 테스트 작성", state: .done),
            .init(title: "구현", state: .active), .init(title: "최종 검사", state: .pending),
            .init(title: "보고", state: .pending),
        ]
        let runs = [MobileIssue.Run(name: "Hird-1", role: "로그인 오류 문구 정리", status: .working, steps: [
            .init(title: "관련 코드 읽기", state: .done), .init(title: "문구 바꾸기", state: .done),
            .init(title: "테스트 고치기", state: .active), .init(title: "전체 테스트", state: .pending)],
            activity: "swift test --filter LoginViewTests", stages: stages, stage: 3, startedAt: ago(730),
            checksPassed: 2, checksFailed: 0)]
        let events = [MobileIssue.Event(at: ago(30), actor: "Hird-1", text: "swift test 실행"),
                      MobileIssue.Event(at: ago(200), actor: "Hird-1", text: "LoginView.swift 수정"),
                      MobileIssue.Event(at: ago(700), actor: "Stallari", text: "이슈를 만들고 Hird-1에게 맡김")]
        let capture = SampleImage.jpeg(width: 420, height: 300, accent: true)
        var records: [MobileRecord] = [
            .issue(MobileIssue(id: "s1", title: "로그인 화면 오류 메시지 정리", project: "Soomcha", state: .running, group: .mine,
                               headline: "Hird 1명 · 12분째", detail: "입력 검증 문구를 바꾸고 **테스트**를 고치는 중이에요.",
                               criteria: [.init(text: "빈 이메일에 안내 문구", state: .met, evidence: "LoginViewTests.testEmptyEmail → 통과"),
                                          .init(text: "swift test 통과", state: .pending)],
                               progress: "2/4 · 테스트 고치기", startedAt: ago(720), updatedAt: ago(30), runs: runs, events: events,
                               verifications: [.init(id: "v1", command: "swift test --filter LoginViewTests", exitCode: 1, at: ago(420), summary: "실패 1개"),
                                               .init(id: "v2", command: "swift test", exitCode: 0, at: ago(60), summary: "통과 42개")],
                               captures: [.init(id: "login.png", caption: "로그인 화면", width: 420, height: 300, data: capture)],
                               thread: "thread-s1")),
            .issue(MobileIssue(id: "s2", title: "합계 함수 반올림 수정", project: "Calc", state: .done, group: .mine,
                               headline: "결과 확인 대기", detail: "반올림을 일반 반올림으로 바꿨어요. 테스트 12개 통과.",
                               criteria: [.init(text: "테스트 통과", state: .met, evidence: "swift test → 0 (12 tests)"), .init(text: "기존 동작 유지", state: .met)],
                               progress: "4/4", startedAt: ago(3600), updatedAt: ago(300),
                               report: "## 바뀐 것\n`total`을 일반 반올림으로 바꿨어요.\n\n- 단위 테스트 12개 통과\n- 기존 동작 유지",
                               thread: "thread-s2")),
            .issue(MobileIssue(id: "s3", title: "설정 화면 다크 모드 색", project: "Knarr", state: .running, group: .working,
                               headline: "Hird 1명 · 3분째", detail: "색 토큰을 정리하는 중이에요.", criteria: [],
                               progress: "1/3 · 토큰 읽기", startedAt: ago(180), updatedAt: ago(10),
                               runs: [.init(name: "Hird-2", role: "색 토큰 정리", status: .working, steps: [], activity: "read Theme.swift",
                                            stages: [.init(title: "준비", state: .active), .init(title: "실패 테스트 작성", state: .pending)],
                                            stage: 1, startedAt: ago(175))],
                               thread: "thread-s3")),
            .issue(MobileIssue(id: "s4", title: "빌드 스크립트 서명 확인", project: "Knarr", state: .failed, group: .stopped,
                               headline: "멈춤 · Stallari 제안 있음", detail: "서명 인증서를 찾지 못했어요. 인증서를 지정하고 다시 시작하자고 제안했어요.",
                               criteria: [.init(text: "codesign --verify 통과", state: .unmet, evidence: "codesign → 종료 1")],
                               progress: nil, startedAt: ago(7200), updatedAt: ago(5400))),
            .issue(MobileIssue(id: "s5", title: "모바일 이슈 승인", project: "Knarr", state: .awaitingApproval, group: .mine,
                               headline: "제안 v2 · 승인 대기", detail: "지시와 완료 조건을 확인한 뒤 승인해 주세요.",
                               criteria: [.init(text: "구형 레코드 호환 유지", state: .pending), .init(text: "iPhone 빌드 통과", state: .pending)],
                               progress: nil, startedAt: ago(90), updatedAt: ago(5),
                               proposal: .init(version: 2, title: "모바일 이슈 승인", criteria: ["구형 레코드 호환 유지", "iPhone 빌드 통과"],
                                               instruction: "기존 CloudKit wire를 유지하면서 모바일 승인 화면을 구현합니다.\n\n1. 승인 대기 상태를 그대로 표시합니다.\n2. 표시된 제안 버전만 승인합니다.\n3. 수정 요청과 거절은 실행하지 않습니다.\n4. 전체 테스트와 iOS 빌드를 확인합니다.",
                                               model: "openai-codex/gpt-6.1-sol", thinking: "high", mode: "change"))),
            .issue(MobileIssue(id: "s6", title: "거절한 제안 예시", project: "Knarr", state: .rejected, group: .stopped,
                               headline: "실행하지 않음", detail: "사용자가 제안을 거절했어요.", criteria: [], progress: nil,
                               startedAt: ago(100), updatedAt: ago(6),
                               proposal: .init(version: 1, title: "거절한 제안 예시", criteria: ["검사 통과"], instruction: "실행하지 않는 예시 지시",
                                               model: "openai-codex/gpt-6.1-sol", thinking: "high", mode: "inspect"),
                               proposalReviewNote: "지금은 실행하지 마세요")),
            .question(MobileQuestion(id: "sq1", issue: "s1", asker: "Hird-1", prompt: "오류 문구를 존댓말로 할까요, 반말로 할까요?",
                                     options: ["존댓말", "반말"], allowsMultiple: false, state: .pending, answer: nil, askedAt: ago(60))),
            .question(MobileQuestion(id: "sq0", issue: "s1", asker: "Hird-1", prompt: "테스트 파일을 새로 만들어도 될까요?",
                                     options: ["예", "아니요"], allowsMultiple: false, state: .answered, answer: "예", askedAt: ago(500))),
            .project(MobileProject(id: "Soomcha", name: "Soomcha", openIssues: 1)),
            .project(MobileProject(id: "Knarr", name: "Knarr", openIssues: 2)),
            .project(MobileProject(id: "Calc", name: "Calc", openIssues: 1)),
            .status(MobileStatus(isResponding: false, engine: "OMP · opus", macRunning: true)),
            .alert(MobileAlert(id: "a1", createdAt: ago(60), title: "질문이 왔어요", body: "오류 문구를 존댓말로 할까요, 반말로 할까요?", issue: "s1")),
            .alert(MobileAlert(id: "a2", createdAt: ago(300), title: "결과가 나왔어요", body: "합계 함수 반올림 수정", issue: "s2")),
            .alert(MobileAlert(id: "a3", createdAt: ago(4200), title: "이슈가 멈췄어요", body: "빌드 스크립트 서명 확인", issue: "s4")),
            .thread(MobileThread(id: ConversationID.main, name: "메인", kind: .main, lastMessageAt: ago(40), working: false, messageCount: 8)),
            .thread(MobileThread(id: "thread-s1", name: "로그인 화면 오류 메시지 정리", kind: .issue, project: "Soomcha", issue: "s1",
                                 lastMessageAt: ago(60), working: true, messageCount: 8)),
            .thread(MobileThread(id: "thread-p-soomcha", name: "Soomcha", kind: .project, project: "Soomcha",
                                 lastMessageAt: ago(900), working: false, messageCount: 2)),
            .thread(MobileThread(id: "thread-s3", name: "설정 화면 다크 모드 색", kind: .issue, project: "Knarr", issue: "s3",
                                 lastMessageAt: ago(170), working: true, messageCount: 1)),
        ]
        // Yesterday's back-and-forth, long enough to page through.
        for i in 0..<70 {
            records.append(.message(MobileMessage(id: "old\(i)", at: ago(95_000 - Double(i) * 60), role: i.isMultiple(of: 2) ? .user : .stallari,
                                                  text: i.isMultiple(of: 2) ? "어제 질문 \(i / 2 + 1)" : "어제 답변 \(i / 2 + 1)이에요. 확인한 내용을 정리했어요.",
                                                  project: nil, thread: ConversationID.main)))
        }
        records += [
            .message(MobileMessage(id: "sm1", at: ago(900), role: .user, text: "Soomcha 로그인 오류 문구 좀 정리해줘", project: nil, thread: ConversationID.main)),
            .message(MobileMessage(id: "sm2", at: ago(880), role: .stallari,
                                   text: "Soomcha에 이슈를 만들고 Hird-1에게 맡겼어요. 완료 조건은 **빈 이메일 안내 문구**와 `swift test` 통과예요.",
                                   project: "Soomcha", thread: ConversationID.main)),
            .message(MobileMessage(id: "sm3", at: ago(870), role: .issue, text: "로그인 화면 오류 메시지 정리", project: nil, issue: "s1", thread: ConversationID.main)),
            .message(MobileMessage(id: "sm4", at: ago(600), role: .autoCheck, text: "확인 2개 · 문제 없음\n빌드 통과\n린트 통과", project: nil, thread: ConversationID.main)),
            // Same progress rows the Mac records: reasoning, then tools, then the answer below.
            .message(MobileMessage(id: "sm-think", at: ago(590), role: .stallari,
                                   text: "로그인 화면에서 오류 문구가 만들어지는 위치를 먼저 확인해야겠습니다. 화면과 검증 문구를 같이 봅니다.",
                                   project: "Soomcha", thread: ConversationID.main,
                                   activity: .init(kind: "reasoning", title: "추론 요약", state: "completed", label: "완료",
                                                   startedAt: ago(592), updatedAt: ago(588)))),
            .message(MobileMessage(id: "sm-tool1", at: ago(585), role: .stallari, text: "Sources/Login/LoginView.swift",
                                   project: "Soomcha", thread: ConversationID.main,
                                   activity: .init(kind: "tool", title: "파일 읽기", state: "completed", label: "완료",
                                                   startedAt: ago(586), updatedAt: ago(584)))),
            .message(MobileMessage(id: "sm-tool2", at: ago(580), role: .stallari, text: "swift",
                                   project: "Soomcha", thread: ConversationID.main,
                                   activity: .init(kind: "tool", title: "명령 실행", state: "completed", label: "완료",
                                                   startedAt: ago(582), updatedAt: ago(578)))),
            .message(MobileMessage(id: "t1", at: ago(880), role: .stallari, text: "이 이슈는 Soomcha의 로그인 화면 안내 문구를 고칩니다. 진행 상황은 오른쪽에 있어요.", project: "Soomcha", issue: "s1", thread: "thread-s1")),
            .message(MobileMessage(id: "t2", at: ago(400), role: .user, text: "문구는 존댓말로 해줘.", project: nil, issue: "s1", thread: "thread-s1")),
            .message(MobileMessage(id: "t3", at: ago(360), role: .stallari, text: "존댓말로 바꾸고 테스트를 다시 돌릴게요.", project: "Soomcha", issue: "s1", thread: "thread-s1")),
            .message(MobileMessage(id: "t4", at: ago(60), role: .question, text: "오류 문구를 존댓말로 할까요, 반말로 할까요?", project: nil,
                                   issue: "s1", question: "sq1", thread: "thread-s1")),
            .message(MobileMessage(id: "p1", at: ago(1200), role: .stallari, text: "Soomcha에서 할 일을 정리했어요.", project: "Soomcha", thread: "thread-p-soomcha")),
            .message(MobileMessage(id: "p2", at: ago(900), role: .user, text: "로그인 화면부터 봐줘.", project: nil, thread: "thread-p-soomcha")),
            .message(MobileMessage(id: "c1", at: ago(170), role: .stallari, text: "색 토큰을 읽고 있어요.", project: "Knarr", issue: "s3", thread: "thread-s3")),
            .message(MobileMessage(id: "s1-reply", at: ago(40), role: .stallari, text: """
            > [!RESULT] 합계 함수를 고쳤어요
            > 원본에는 아직 반영하지 않았어요.

            ## 바뀐 것
            ```swift
            func total(_ xs: [Double]) -> Double {
                xs.reduce(0, +).rounded(.toNearestOrAwayFromZero)
            }
            ```

            | 확인 | 결과 |
            |---|:---:|
            | 단위 테스트 12개 | ✓ 통과 |
            | 기존 동작 | ✓ 유지 |

            - [x] 반올림 수정
            - [ ] 원본 반영
            """, project: "Calc", thread: ConversationID.main)),
            .message(MobileMessage(id: "photo-user", at: ago(45), role: .user, text: "이 화면 캡처대로 해줘", project: nil,
                                   thread: ConversationID.main,
                                   attachments: [.init(id: "shot1", name: "shot1.jpg", type: "image/jpeg", byteCount: 0)])),
        ]
        records.append(.message(MobileMessage(id: "openui-sample", at: now.addingTimeInterval(1), role: .stallari,
            text: """
            작업 시간에 따른 주간 계획입니다.

            ```openui
            root = Stack([Heading("주간 작업 시간"), Slider($hours, "하루 작업 시간", 1, 12, 1), Metric("주간 합계", $hours * 5, "시간"), Button("이 계획으로 진행", @ToAssistant("주간 작업 계획"))])
            $hours = 4
            ```
            """, project: "Knarr", thread: ConversationID.main)))
        return records
    }
}

/// A small JPEG for sample screenshots, so the sample app shows a real image without bundled assets.
enum SampleImage {
    static func jpeg(width: CGFloat, height: CGFloat, accent: Bool) -> Data? {
        #if canImport(UIKit)
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height))
        return renderer.image { context in
            let cg = context.cgContext
            UIColor(red: 0.98, green: 0.97, blue: 0.95, alpha: 1).setFill()
            cg.fill(CGRect(x: 0, y: 0, width: width, height: height))
            UIColor(red: 0.71, green: 0.33, blue: 0.23, alpha: 1).setFill()
            cg.fill(CGRect(x: 16, y: 16, width: 90, height: 12))
            UIColor(red: 0.16, green: 0.15, blue: 0.14, alpha: 0.7).setFill()
            for row in 0..<5 {
                cg.fill(CGRect(x: 16, y: 48 + CGFloat(row) * 26, width: width - 32 - CGFloat(row % 3) * 40, height: 8))
            }
            if accent {
                UIColor(red: 0.71, green: 0.33, blue: 0.23, alpha: 1).setFill()
                cg.fill(CGRect(x: 16, y: height - 54, width: 120, height: 30))
            }
        }.jpegData(compressionQuality: 0.7)
        #else
        return nil
        #endif
    }
}
