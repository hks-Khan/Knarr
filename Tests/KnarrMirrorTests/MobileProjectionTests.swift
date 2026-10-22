import Foundation
import Testing
import KnarrCore
import KnarrSync
@testable import KnarrMirror

func makeIssue(_ id: String, _ state: IssueState, confirmed: Bool = false, title: String? = nil, detail: String = "",
               at: Date = Date(timeIntervalSince1970: 1_800_000_000)) -> KnarrCore.Issue {
    KnarrCore.Issue(id: .init(id), title: title ?? id, projectName: "Calc", state: state, confirmed: confirmed,
          headline: "Hird 1명", detail: detail,
          acceptance: [Criterion(text: "테스트 통과", state: .met, evidence: "swift test → 0")],
          hirds: [HirdRun(id: "r", name: "Hird-1", role: "고치기", status: .working,
                          steps: [HirdStep(title: "읽기", state: .done), HirdStep(title: "고치기", state: .active)],
                          currentCommand: "swift test", lastActivityAt: at)],
          events: [], startedAt: at)
}

func makeQuestion(_ id: String, issue: String, state: Question.State = .pending) -> Question {
    Question(id: .init(id), issue: .init(issue), run: "r", asker: "Hird-1", prompt: "어느 쪽?", options: ["A", "B"],
             askedAt: Date(timeIntervalSince1970: 1_800_000_000), state: state)
}

@MainActor @Suite struct MobileProjectionTests {
    let now = Date(timeIntervalSince1970: 1_800_000_100)

    func issues(_ records: [MobileRecord]) -> [MobileIssue] {
        records.compactMap { if case .issue(let t) = $0 { t } else { nil } }
    }

    @Test func groupsFollowThePanel() {
        let records = MobileProjection.records(
            issues: [makeIssue("ask", .running), makeIssue("work", .running), makeIssue("done", .done),
                     makeIssue("fail", .failed), makeIssue("old", .done, confirmed: true)],
            questions: [makeQuestion("q", issue: "ask")], chat: [], projects: [],
            stallari: StallariInfo(engine: "OMP", scope: ""), isResponding: false, now: now)
        let byID = Dictionary(uniqueKeysWithValues: issues(records).map { ($0.id, $0.group) })
        #expect(byID == ["ask": .mine, "work": .working, "done": .mine, "fail": .stopped, "old": .mine])
    }

    @Test func legacyRunningWithoutHirdDoesNotClaimWorkAndOldWireStillDecodes() throws {
        var legacy = makeIssue("knarr-chat-threads-20261012", .running)
        legacy.hirds = []
        let records = MobileProjection.records(issues: [legacy], questions: [], chat: [], projects: [],
            stallari: .init(engine: "OMP", scope: ""), isResponding: false, now: now)
        let projected = try #require(issues(records).first)
        #expect(projected.group == .mine)
        #expect(projected.state != .running)
        var oldWire = projected
        oldWire.state = .running; oldWire.group = .working; oldWire.headline = "실행 중"
        let decoded = try JSONDecoder().decode(MobileIssue.self, from: JSONEncoder().encode(oldWire))
        #expect(decoded.group == .stopped)
        #expect(decoded.state != .running)
    }

    @Test func archivedIssuesAreLeftOut() {
        var archived = makeIssue("gone", .done, confirmed: true)
        archived.archivedAt = now
        let records = MobileProjection.records(issues: [archived], questions: [], chat: [], projects: [],
                                               stallari: StallariInfo(engine: "OMP", scope: ""), isResponding: false, now: now)
        #expect(issues(records).isEmpty)
    }

    @Test func issueCarriesCriteriaAndCurrentStep() throws {
        let records = MobileProjection.records(issues: [makeIssue("a", .running)], questions: [], chat: [], projects: [],
                                               stallari: StallariInfo(engine: "OMP", scope: ""), isResponding: false, now: now)
        let issue = try #require(issues(records).first)
        #expect(issue.criteria == [.init(text: "테스트 통과", state: .met, evidence: "swift test → 0")])
        #expect(issue.progress == "1/2 · 고치기")
    }

    @Test func answeredQuestionsOfHiddenIssuesAreLeftOut() {
        let q = makeQuestion("q", issue: "gone", state: .cancelled)
        let records = MobileProjection.records(issues: [], questions: [q, makeQuestion("p", issue: "gone")], chat: [], projects: [],
                                               stallari: StallariInfo(engine: "OMP", scope: ""), isResponding: false, now: now)
        let ids = records.compactMap { if case .question(let m) = $0 { m.id } else { nil } }
        #expect(ids == ["p"])
    }

    @Test func onlyTheLatestConversationIsSent() {
        let total = MobileProjection.messageLimit + 20
        let chat = (0..<total).map { ChatItem(at: now.addingTimeInterval(Double($0)), kind: .user("메시지 \($0)")) }
            + [ChatItem(at: now, kind: .day("오늘"))]
        let records = MobileProjection.records(issues: [], questions: [], chat: chat, projects: [],
                                               stallari: StallariInfo(engine: "OMP", scope: ""), isResponding: false, now: now)
        let texts = records.compactMap { if case .message(let m) = $0 { m.text } else { nil } }
        #expect(texts.count == MobileProjection.messageLimit)
        #expect(texts.contains("메시지 \(total - 1)"))
        #expect(!texts.contains("메시지 0"))
    }

    @Test func answeredQuestionsShowTheChoice() throws {
        let q = makeQuestion("q", issue: "a", state: .answered(QuestionAnswer(selectedOptions: ["A"], text: "빨리")))
        let records = MobileProjection.records(issues: [makeIssue("a", .running)], questions: [q], chat: [], projects: [],
                                               stallari: StallariInfo(engine: "OMP", scope: ""), isResponding: false, now: now)
        let mq = try #require(records.compactMap { if case .question(let m) = $0 { m } else { nil } }.first)
        #expect(mq.state == .answered)
        #expect(mq.answer == "A · 빨리")
    }
}

@MainActor @Suite struct MobileAlertDetectorTests {
    let now = Date(timeIntervalSince1970: 1_800_000_100)

    @Test func theFirstLookOnlySetsTheBaseline() {
        var detector = MobileAlertDetector()
        #expect(detector.alerts(issues: [makeIssue("a", .done)], questions: [makeQuestion("q", issue: "a")], chat: [], now: now).isEmpty)
    }

    @Test func finishingStoppingAndWaitingAreAnnounced() {
        var detector = MobileAlertDetector()
        _ = detector.alerts(issues: [makeIssue("a", .running), makeIssue("b", .running), makeIssue("c", .running)], questions: [], chat: [], now: now)
        let alerts = detector.alerts(issues: [makeIssue("a", .done, title: "합계"), makeIssue("b", .failed),
                                              makeIssue("c", .needsInput, detail: "로그인이 필요해요\n자세히")],
                                     questions: [], chat: [], now: now)
        #expect(alerts.map(\.title) == ["결과가 나왔어요", "이슈가 멈췄어요", "Hird가 기다려요"])
        #expect(alerts[0].body == "합계")
        #expect(alerts[2].body.contains("로그인이 필요해요"))
        #expect(alerts.allSatisfy { $0.issue != nil })
        #expect(detector.alerts(issues: [makeIssue("a", .done, title: "합계"), makeIssue("b", .failed), makeIssue("c", .needsInput)],
                                questions: [], chat: [], now: now).isEmpty)
    }

    @Test func whatLoadsAfterLaunchIsNotAnnounced() {
        var detector = MobileAlertDetector()
        _ = detector.alerts(issues: [], questions: [], chat: [], now: now)
        let loaded = detector.alerts(issues: [makeIssue("old", .failed), makeIssue("done", .done)],
                                     questions: [makeQuestion("q", issue: "old")], chat: [], now: now.addingTimeInterval(1))
        #expect(loaded.isEmpty)
    }

    @Test func aNewQuestionIsAnnouncedOnce() {
        var detector = MobileAlertDetector()
        _ = detector.alerts(issues: [makeIssue("a", .running)], questions: [], chat: [], now: Date(timeIntervalSince1970: 1_700_000_000))
        let first = detector.alerts(issues: [makeIssue("a", .running)], questions: [makeQuestion("q", issue: "a")], chat: [], now: now)
        #expect(first.map(\.title) == ["질문이 왔어요"])
        #expect(first.first?.body == "어느 쪽?")
        #expect(detector.alerts(issues: [makeIssue("a", .running)], questions: [makeQuestion("q", issue: "a")], chat: [], now: now).isEmpty)
    }

    @Test func stallariRepliesAreAnnouncedOnlyAfterAMessageFromThePhone() {
        var detector = MobileAlertDetector()
        let asked = ChatItem(at: now, kind: .user("상태 어때?"))
        _ = detector.alerts(issues: [], questions: [], chat: [asked], now: now)
        let reply = ChatItem(at: now, kind: .stallari("다 끝났어요", project: nil))
        #expect(detector.alerts(issues: [], questions: [], chat: [asked, reply], now: now).isEmpty)
        detector.expectReply()
        let second = ChatItem(at: now, kind: .stallari("하나 더 끝났어요", project: nil))
        let alerts = detector.alerts(issues: [], questions: [], chat: [asked, reply, second], now: now)
        #expect(alerts.map(\.title) == ["Stallari 답변"])
        #expect(alerts.first?.body == "하나 더 끝났어요")
    }
}

@MainActor @Suite struct MobileRequestApplierTests {
    @Test func aMessageGoesToStallari() async throws {
        let store = SampleKnarrStore()
        let before = store.chat.count
        try await MobileRequestApplier.apply(.message(text: "폰에서 보냄", project: nil), to: store)
        #expect(store.chat.count > before)
        #expect(store.chat.contains { if case .user(let t) = $0.kind { t == "폰에서 보냄" } else { false } })
    }

    @Test func anAnswerResolvesTheQuestion() async throws {
        let store = SampleKnarrStore()
        let pending = try #require(store.questions.first { $0.isPending })
        try await MobileRequestApplier.apply(.answer(question: pending.id.rawValue, options: Array(pending.options.prefix(1)), text: nil), to: store)
        #expect(store.question(pending.id)?.isPending == false)
    }

}

@MainActor @Suite struct MobileProjectionDetailTests {
    let now = Date(timeIntervalSince1970: 1_800_000_100)
    let info = StallariInfo(engine: "OMP", scope: "")

    @Test func issueCarriesRunsStepsEventsEvidenceAndApplication() throws {
        var issue = makeIssue("a", .done, confirmed: true)
        issue.events = (0..<30).map { ActivityEvent(at: now.addingTimeInterval(Double($0)), actor: "Hird-1", text: "일 \($0)") }
        issue.application = .applied(branch: "main", commit: "abcdef1234")
        let records = MobileProjection.records(issues: [issue], questions: [], chat: [], projects: [], stallari: info, isResponding: false, now: now)
        let t = try #require(records.compactMap { if case .issue(let v) = $0 { v } else { nil } }.first)
        #expect(t.criteria.first?.evidence == "swift test → 0")
        #expect(t.runs.map(\.name) == ["Hird-1"])
        #expect(t.runs.first?.steps.map(\.title) == ["읽기", "고치기"])
        #expect(t.events.count == MobileProjection.eventLimit)
        #expect(t.events.first?.text == "일 29")
        #expect(t.application == "원본 main에 반영했어요 · abcdef1")
    }

    @Test func chatCardsBecomeMessages() {
        let issueID = KnarrCore.Issue.ID("a")
        let chat = [ChatItem(at: now, kind: .issue(issueID)),
                    ChatItem(at: now, kind: .question("q")),
                    ChatItem(at: now, kind: .autoCheck(summary: "확인 2개", lines: ["빌드 통과", "테스트 통과"]))]
        let records = MobileProjection.records(issues: [makeIssue("a", .running, title: "합계")], questions: [makeQuestion("q", issue: "a")],
                                               chat: chat, projects: [], stallari: info, isResponding: false, now: now)
        let messages = records.compactMap { if case .message(let m) = $0 { m } else { nil } }
        #expect(messages.map(\.role) == [.issue, .question, .autoCheck])
        #expect(messages[0].issue == "a")
        #expect(messages[0].text == "합계")
        #expect(messages[1].issue == "a")
        #expect(messages[1].question == "q")
        #expect(messages[1].text == "어느 쪽?")
        #expect(messages[2].text == "확인 2개\n빌드 통과\n테스트 통과")
    }

    @Test func progressRowsCarryTheMacActivityAndOrdinaryAnswersDoNot() {
        var thought = ChatItem(at: now, kind: .stallari("영어 추론 문장", project: nil))
        thought.activity = .init(kind: .reasoning, title: "추론 요약", state: .completed, updatedAt: now.addingTimeInterval(3))
        var command = ChatItem(at: now.addingTimeInterval(4), kind: .stallari("swift", project: nil))
        command.activity = .init(kind: .tool, title: "명령 실행", state: .running, updatedAt: now.addingTimeInterval(5))
        let answer = ChatItem(at: now.addingTimeInterval(6), kind: .stallari("최종 답변", project: nil))
        let records = MobileProjection.records(issues: [], questions: [], chat: [thought, command, answer], projects: [],
                                               stallari: info, isResponding: true, now: now)
        let messages = Dictionary(uniqueKeysWithValues: records.compactMap { record -> (String, MobileMessage)? in
            guard case .message(let m) = record else { return nil }
            return (m.id, m)
        })
        let thinking = messages[thought.id.uuidString]?.activity
        #expect(thinking?.kind == "reasoning")
        #expect(thinking?.title == "추론 요약")
        #expect(thinking?.state == "completed")
        #expect(thinking?.label == "완료")
        #expect(thinking?.startedAt == thought.at)
        #expect(thinking?.updatedAt == now.addingTimeInterval(3))
        let running = messages[command.id.uuidString]?.activity
        #expect(running?.kind == "tool")
        #expect(running?.label == "진행 중")
        #expect(messages[command.id.uuidString]?.text == "swift")
        #expect(messages[answer.id.uuidString]?.activity == nil)
        #expect(messages[answer.id.uuidString]?.role == .stallari)
    }

    @Test func statusSaysTheMacIsRunning() {
        let records = MobileProjection.records(issues: [], questions: [], chat: [], projects: [], stallari: info, isResponding: false, now: now)
        #expect(records.contains(.status(MobileStatus(isResponding: false, engine: "OMP", macRunning: true))))
    }
}
