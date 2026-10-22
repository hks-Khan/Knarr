import Foundation
import Testing
@testable import KnarrCore

/// The presentation mapping the cards, panel, filters, counts and phone all share.
struct IssueStatusTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func issue(_ id: String, state: IssueState, criteria: [Criterion] = []) -> KnarrCore.Issue {
        .init(id: .init(id), title: id, projectName: "P", state: state, headline: "swift test 3개 실패",
              detail: "판정 기록", acceptance: criteria, hirds: [], events: [], startedAt: now)
    }

    func run(_ id: String, _ status: HirdRun.Status) -> HirdRun {
        .init(id: .init(id), name: id, role: "", status: status, steps: [], currentCommand: nil, lastActivityAt: now)
    }

    @Test func appliedUnconfirmedResultHasNoUserWork() {
        var value = issue("applied", state: .done)
        value.application = .applied(branch: "main", commit: "abc")
        #expect(!value.confirmed)
        #expect(value.statusLine == "완료")
        #expect(!value.needsAttention)
        #expect(Panel.sections(for: [value]).isEmpty)
        #expect(IssueCards(issues: [value], scope: .allProjects).issues.isEmpty)
        #expect(IssueCards.history(issues: [value]).map(\.id) == [value.id])
    }

    @Test func awaitedProposalShowsApprovalAndNotPersonReview() {
        var value = issue("approval", state: .awaitingApproval)
        value.proposal = .init(instruction: "고치기", model: "provider/model")
        #expect(value.displayStatus == .awaitingApproval)
        #expect(value.statusLine == "승인 대기")
        #expect(value.userActionLine() == "저장된 제안 승인 대기")
        #expect(!value.userActionLine().contains("합쳐"))
    }

    @Test func runningWithoutAnActiveHirdIsApprovalWhenNoProposalExists() {
        let value = issue("needsProposal", state: .running)
        #expect(value.needsNewProposal)
        #expect(value.displayStatus == .awaitingApproval)
        #expect(value.userActionLine() == "실행할 제안 없음")
    }

    @Test func workingHirdIsInProgress() {
        var value = issue("working", state: .running)
        value.hirds = [run("r", .working)]
        #expect(value.displayStatus == .inProgress)
        #expect(value.userActionLine() == "Hird 실행 중")
    }

    @Test func pendingQuestionOrWaitingHirdIsNeedsAnswer() {
        var asking = issue("asking", state: .running)
        asking.hirds = [run("r", .working)]
        #expect(asking.presentationStatus(hasPendingQuestion: true) == .needsAnswer)
        #expect(asking.needsAnswer(hasPendingQuestion: true))
        #expect(asking.userActionLine(hasPendingQuestion: true) == "Stallari 또는 Hird의 질문에 답변 대기")

        var waiting = issue("waiting", state: .needsInput)
        waiting.hirds = [run("r", .waitingOnHuman(since: now))]
        #expect(waiting.displayStatus == .needsAnswer)
        #expect(waiting.statusLine == "답변 필요")
    }

    @Test func finishedRunWithoutJudgementIsJudging() {
        var value = issue("judging", state: .running)
        value.hirds = [run("r", .done(at: now))]
        #expect(value.displayStatus == .judging)
        #expect(value.userActionLine() == "실행 종료 · Stallari 판정 대기")
    }

    @Test func metJudgementIsAwaitingIntegration() {
        var value = issue("integrated", state: .done,
                          criteria: [.init(text: "설치", state: .met, evidence: "xcodebuild exit 0")])
        value.completedAt = now
        #expect(value.displayStatus == .awaitingIntegration)
        #expect(value.userActionLine() == "완료 조건 충족 · 원본 프로젝트 미반영")
    }

    @Test func unmetJudgementShowsTheRecordedCountAndStoppedRunIsFailure() {
        let unmet = issue("unmet", state: .failed, criteria: [
            .init(text: "설치", state: .unmet, evidence: "exit 1"),
            .init(text: "테스트", state: .unmet, evidence: "3 failures"),
            .init(text: "문서", state: .met, evidence: "read")
        ])
        #expect(unmet.displayStatus == .unmet)
        #expect(unmet.statusLine == "미충족 2개")
        #expect(unmet.userActionLine() == "Stallari가 완료 조건 미충족을 기록함")

        let stopped = issue("stopped", state: .running)
        var value = stopped
        value.hirds = [run("r", .failed(at: now))]
        #expect(value.displayStatus == .failed)
        #expect(value.statusLine == "실행 실패")
        #expect(value.userActionLine() == "판정 전에 실행이 멈춤")
    }

    @Test func closureDoesNotEraseApplicationPrecedence() {
        var applied = issue("applied-closed", state: .failed)
        applied.application = .applied(branch: "main", commit: "abc")
        applied.archivedAt = now
        applied.archiveReason = IssueCloseReason.applied.rawValue
        var cancelled = issue("cancelled", state: .failed)
        cancelled.archivedAt = now
        cancelled.archiveReason = IssueCloseReason.cancelled.rawValue
        #expect(applied.statusLine == "완료")
        #expect(cancelled.statusLine == "취소")
        #expect(Panel.sections(for: [applied, cancelled]).isEmpty)
        #expect(!applied.needsAttention && !cancelled.needsAttention)
    }

    @Test func openCountsUseTheSameStatesAsTheCards() {
        var applied = issue("applied", state: .failed)
        applied.application = .applied(branch: "main", commit: "abc")
        applied.completedAt = now.addingTimeInterval(-60)
        applied.startedAt = now.addingTimeInterval(-30 * 86400)
        var closed = issue("closed", state: .failed)
        closed.archivedAt = now
        var closedApplied = applied
        closedApplied.id = "closed-applied"; closedApplied.archivedAt = now
        var working = issue("working", state: .running)
        working.hirds = [run("r", .working)]
        let values = [issue("todo", state: .awaitingApproval), issue("waiting", state: .needsInput),
                      issue("failed", state: .failed), issue("success", state: .done), working,
                      applied, closed, closedApplied]
        let counts = IssueCounts(issues: values, now: now)
        #expect(counts.count(.awaitingApproval) == 1)
        #expect(counts.count(.needsAnswer) == 1)
        #expect(counts.count(.failed) == 1)
        #expect(counts.count(.awaitingIntegration) == 1)
        #expect(counts.count(.inProgress) == 1)
        #expect(counts.count(.judging) == 0 && counts.count(.unmet) == 0)
        #expect(counts.completedThisWeek == 1)
        #expect(counts.summary == "승인 대기 1 · 답변 필요 1 · 진행 중 1 · 통합 대기 1 · 실행 실패 1 · 이번 주 완료 1")
        #expect(values.filter(\.needsAttention).map(\.id) == ["todo", "waiting", "failed", "success", "working"])
    }

    @Test func currentWeekUsesResultTimeAndExcludesFutureOrPreviousWeek() throws {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let week = try #require(calendar.dateInterval(of: .weekOfYear, for: now))
        func applied(_ id: String, completed: Date) -> KnarrCore.Issue {
            var value = issue(id, state: .failed)
            value.application = .applied(branch: "main", commit: id)
            value.completedAt = completed
            value.startedAt = now.addingTimeInterval(-90 * 86400)
            return value
        }
        let values = [applied("boundary", completed: week.start),
                      applied("previous", completed: week.start.addingTimeInterval(-1)),
                      applied("future", completed: now.addingTimeInterval(1))]
        #expect(IssueCounts(issues: values, now: now, calendar: calendar).completedThisWeek == 1)
    }

    @Test func pendingQuestionCountsAsAnAnswerAndCompletedQuestionsDoNotResurface() {
        let asking = issue("asking", state: .running)
        let question = Question(id: "q", issue: asking.id, run: "r", asker: "Hird",
                                prompt: "선택", options: [], askedAt: now)
        #expect(asking.presentationStatus(hasPendingQuestion: true) == .needsAnswer)
        #expect(asking.needsAnswer(hasPendingQuestion: true))
        #expect(IssueCounts(issues: [asking], questions: [question], now: now).count(.needsAnswer) == 1)
        #expect(IssueCards(issues: [asking], questions: [question], scope: .allProjects).answerCount == 1)
        var applied = asking
        applied.application = .applied(branch: "main", commit: "abc")
        #expect(!applied.needsAnswer(hasPendingQuestion: true))
        #expect(IssueCards(issues: [applied], questions: [question], scope: .allProjects).answerCount == 0)
    }

    @Test func terminalRunsWithoutJudgementAreJudgingButAnActiveRerunIsInProgress() {
        var value = issue("stopped", state: .running)
        value.hirds = [.init(id: "r", name: "Hird", role: "", status: .failed(at: now),
                            steps: [], currentCommand: nil, lastActivityAt: now)]
        #expect(value.displayStatus == .failed)
        #expect(IssueCards.completion(of: value) == now)
        var done = value
        done.hirds = [run("done", .done(at: now))]
        #expect(done.displayStatus == .judging)
        value.hirds.append(.init(id: "rerun", name: "Hird", role: "", status: .working,
                                steps: [], currentCommand: nil, lastActivityAt: now))
        #expect(value.displayStatus == .inProgress)
        #expect(IssueCards.completion(of: value) == nil)
    }

    @Test func noOpenStateAsksThePersonToReviewOrMerge() {
        let states: [IssueState] = [.awaitingApproval, .needsInput, .running, .failed, .done]
        for state in states {
            let line = issue("x", state: state).userActionLine()
            #expect(!line.contains("합쳐"), Comment(rawValue: line))
            #expect(!line.contains("검토해"), Comment(rawValue: line))
            #expect(!line.contains("검토하고"), Comment(rawValue: line))
        }
    }
}
