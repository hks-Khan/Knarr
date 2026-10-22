import Foundation
import Testing
@testable import KnarrSync

@Suite struct LiveActivityTests {
    let at = Date(timeIntervalSince1970: 1_800_000_000)
    func issue(_ id: String = "t1", state: MobileIssue.State = .running, group: MobileIssue.Group = .working, start: TimeInterval = 0) -> MobileIssue {
        MobileIssue(id: id, title: "로그인 오류 수정", project: "Knarr", state: state, group: group,
                    headline: "진행 중", detail: "전체 로그는 노출하지 않아요", criteria: [], progress: "2/4 · 테스트 실행",
                    startedAt: at.addingTimeInterval(start), updatedAt: at,
                    runs: state == .running ? [.init(name: "Hird", role: "검사", status: .working, steps: [])] : [])
    }
    func question(_ issue: String = "t1", state: MobileQuestion.State = .pending) -> MobileQuestion {
        .init(id: "q1", issue: issue, asker: "Hird", prompt: "개인 정보가 있는 질문 본문", options: [], allowsMultiple: false,
              state: state, answer: nil, askedAt: at)
    }
    @Test func idleAndFinishedHistoryDoNotStartAnActivity() {
        #expect(LiveActivitySummary.make(issues: [], questions: []) == nil)
        #expect(LiveActivitySummary.make(issues: [issue(state: .done, group: .finished)], questions: []) == nil)
    }
    @Test func oneIssueAutomaticallyCarriesItsStageAndDestination() throws {
        let value = try #require(LiveActivitySummary.make(issues: [issue()], questions: []))
        #expect(value.title == "로그인 오류 수정")
        #expect(value.detail == "2/4 · 테스트 실행")
        #expect(value.runningCount == 1)
        #expect(value.issueID == "t1")
        #expect(value.status == .running)
    }
    @Test func multipleIssuesBecomeOneStableSummary() throws {
        let issues = [issue("b", start: 30), issue("a")]
        let value = try #require(LiveActivitySummary.make(issues: issues, questions: []))
        #expect(value.title == "이슈 2개 진행 중")
        #expect(value.runningCount == 2)
        #expect(value.issueID == nil)
        #expect(value.startedAt == at)
        #expect(value == LiveActivitySummary.make(issues: issues.reversed(), questions: []))
    }
    @Test func pendingQuestionTakesPriorityWithoutShowingQuestionBody() throws {
        let value = try #require(LiveActivitySummary.make(issues: [issue(), issue("t2")], questions: [question()]))
        #expect(value.status == .needsInput)
        #expect(value.title == "답변이 필요해요")
        #expect(value.detail == "로그인 오류 수정")
        #expect(value.issueID == "t1")
        #expect(value.attentionCount == 1)
        #expect(!value.detail.contains("개인 정보"))
    }
    @Test func answeredQuestionsDoNotKeepAttentionState() throws {
        #expect(try #require(LiveActivitySummary.make(issues: [issue()], questions: [question(state: .answered)])).status == .running)
    }
    @Test func reviewAndFailureRemainVisibleWithoutClaimingCompletion() throws {
        let done = try #require(LiveActivitySummary.make(issues: [issue(state: .done, group: .mine)], questions: []))
        #expect(done.status == .review)
        // The person is not asked to review the result; it waits for Stallari's integration.
        #expect(done.title == "통합 대기 중인 결과가 있어요")
        #expect(!done.title.contains("확인해"))
        #expect(try #require(LiveActivitySummary.make(issues: [issue(state: .failed, group: .stopped)], questions: [])).status == .stopped)
    }

    @Test func endingStatesShowTheOutcomeWithoutAskingForReview() throws {
        let value = try #require(LiveActivitySummary.make(issues: [issue()], questions: []))
        #expect(value.ending(completed: true, at: at).detail == "완료")
        #expect(value.ending(completed: false, at: at).detail == "종료")
        #expect(!value.ending(completed: true, at: at).detail.contains("확인"))
    }
    @Test func approvalAndRejectionNeverClaimRunning() throws {
        let approval = try #require(LiveActivitySummary.make(issues: [issue(state: .awaitingApproval, group: .mine)], questions: []))
        #expect(approval.status == .review)
        #expect(approval.title == "제안을 승인해 주세요")
        #expect(approval.runningCount == 0)
        #expect(approval.attentionCount == 1)
        let rejected = try #require(LiveActivitySummary.make(issues: [issue(state: .rejected, group: .stopped)], questions: []))
        #expect(rejected.status == .stopped)
        #expect(rejected.runningCount == 0)
    }
    @Test func serializedSummaryFitsTheActivityPayloadBudget() throws {
        var valueIssue = issue(); valueIssue.title = String(repeating: "긴제목👩‍💻", count: 1000); valueIssue.progress = valueIssue.title
        let value = try #require(LiveActivitySummary.make(issues: [valueIssue], questions: []))
        #expect(try JSONEncoder().encode(value).count < 3000)
        #expect(try JSONDecoder().decode(LiveActivitySummary.self, from: JSONEncoder().encode(value)) == value)
    }
    @Test func lifecycleStartsOnlyInForegroundAndRespectsDismissalAndRemoteOwner() throws {
        let value = try #require(LiveActivitySummary.make(issues: [issue()], questions: []))
        let policy = LiveActivityPolicy()
        #expect(policy.decision(summary: value, hasActivity: false, foreground: true, remote: false, authorized: true) == .start)
        #expect(policy.decision(summary: value, hasActivity: false, foreground: false, remote: false, authorized: true) == .none)
        #expect(policy.decision(summary: value, hasActivity: false, foreground: true, remote: true, authorized: true) == .none)
        #expect(policy.decision(summary: value, hasActivity: false, foreground: true, remote: false, authorized: false) == .none)
        #expect(policy.decision(summary: value, hasActivity: true, foreground: false, remote: false, authorized: true) == .update)
        #expect(policy.decision(summary: nil, hasActivity: true, foreground: false, remote: false, authorized: true) == .end)
        #expect(LiveActivityPolicy(dismissedAt: at).decision(summary: value, hasActivity: false, foreground: true, remote: false, authorized: true) == .none)
        let newer = try #require(LiveActivitySummary.make(issues: [issue("new", start: 10)], questions: []))
        #expect(LiveActivityPolicy(dismissedAt: at).decision(summary: newer, hasActivity: false, foreground: true, remote: false, authorized: true) == .start)
    }
    @Test func deepLinkSafelyEncodesAnIdentifier() throws {
        let value = try #require(LiveActivitySummary.make(issues: [issue("abc&x=1")], questions: []))
        #expect(URLComponents(url: value.url, resolvingAgainstBaseURL: false)?.queryItems == [URLQueryItem(name: "thing", value: "abc&x=1")])
    }
}
