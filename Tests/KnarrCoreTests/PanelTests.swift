import Foundation
import Testing
@testable import KnarrCore

private let t0 = Date(timeIntervalSince1970: 1_791_300_000)

private func issue(_ title: String, _ state: IssueState, confirmed: Bool = false, hirds: [HirdRun] = []) -> KnarrCore.Issue {
    KnarrCore.Issue(id: KnarrCore.Issue.ID(title), title: title, projectName: "P", state: state, confirmed: confirmed,
          headline: "", detail: "", acceptance: [], hirds: hirds, events: [], startedAt: t0)
}

private func hird(_ name: String, _ status: HirdRun.Status, last: Date, steps: [HirdStep] = []) -> HirdRun {
    HirdRun(id: HirdRun.ID(name), name: name, role: "", status: status, steps: steps, currentCommand: nil, lastActivityAt: last)
}

@Suite struct PanelGroupingTests {
    @Test func groupsByTheStateTheRecordsProve() {
        let issues = [
            issue("todo", .awaitingApproval),
            issue("running", .running, hirds: [hird("h", .working, last: t0)]),
            issue("input", .needsInput),
            issue("failed", .failed),
            issue("done-unconfirmed", .done),
            issue("done-confirmed", .done, confirmed: true),
        ]
        let sections = Panel.sections(for: issues)
        #expect(sections.map(\.kind) == [.needsAnswer, .awaitingApproval, .failed, .awaitingIntegration, .inProgress])
        #expect(sections.map { $0.issues.map(\.title) } == [
            ["input"], ["todo"], ["failed"], ["done-unconfirmed", "done-confirmed"], ["running"]
        ])
    }

    @Test func proposalReviewStatesStayVisibleWithoutRunning() {
        let sections = Panel.sections(for: [
            issue("approval", .awaitingApproval),
            issue("rejected", .rejected),
        ])
        #expect(sections.map(\.kind) == [.awaitingApproval])
        #expect(sections[0].issues.map(\.title) == ["approval"])
        #expect(IssueCards.history(issues: [issue("rejected", .rejected)]).map(\.title) == ["rejected"])
    }

    @Test func issueWithoutExecutionNeverClaimsHirdIsWorking() {
        let sections = Panel.sections(for: [issue("not-dispatched", .running)])
        #expect(!sections.contains { $0.kind == .inProgress })
        #expect(sections.flatMap(\.issues).map(\.id) == ["not-dispatched"])
        #expect(sections.first?.kind == .awaitingApproval)
    }

    @Test func visualAndOtherUnmetCriteriaBothRemainUnmet() {
        var value = issue("visual", .failed)
        value.acceptance = [
            .init(text: "검사", state: .met, evidence: "exit 0"),
            .init(text: "실제 앱 확인", state: .unmet, evidence: "실제 앱 확인 필요: 설치한 앱에서 움직임을 확인해 주세요")
        ]
        #expect(value.needsAppConfirmation)
        #expect(Panel.sections(for: [value]).map(\.kind) == [.unmet])
        value.acceptance.append(.init(text: "빌드", state: .unmet, evidence: "exit 1"))
        #expect(!value.needsAppConfirmation)
        #expect(Panel.sections(for: [value]).map(\.kind) == [.unmet])
    }

    @Test func omitsEmptySections() {
        let sections = Panel.sections(for: [issue("running", .running, hirds: [hird("h", .working, last: t0)])])
        #expect(sections.map(\.kind) == [.inProgress])
    }
}

@Suite struct LivenessTests {
    @Test func recentActivityIsActiveWithSeconds() {
        let h = hird("H1", .working, last: t0)
        #expect(h.liveness(now: t0.addingTimeInterval(12)) == .active(seconds: 12))
    }

    @Test func silenceAfterNinetySecondsIsQuietInMinutes() {
        let h = hird("H1", .working, last: t0)
        #expect(h.liveness(now: t0.addingTimeInterval(89)) == .active(seconds: 89))
        #expect(h.liveness(now: t0.addingTimeInterval(4 * 60 + 5)) == .quiet(minutes: 4))
    }

    @Test func nonWorkingStatusesIgnoreTheClock() {
        let since = t0.addingTimeInterval(-180)
        #expect(hird("H", .waitingOnHuman(since: since), last: t0).liveness(now: t0) == .waitingOnHuman(minutes: 3))
        #expect(hird("H", .failed(at: t0), last: t0).liveness(now: t0.addingTimeInterval(999)) == .stopped(at: t0))
        #expect(hird("H", .done(at: t0), last: t0).liveness(now: t0.addingTimeInterval(999)) == .finished(at: t0))
    }

    @Test func runningIssueTakesItsLiveliestHird() {
        let busy = hird("H1", .working, last: t0.addingTimeInterval(-5))
        let idle = hird("H2", .working, last: t0.addingTimeInterval(-300))
        #expect(issue("t", .running, hirds: [idle, busy]).liveness(now: t0) == .active(seconds: 5))
    }
}

@Suite struct StepProgressTests {
    @Test func countsDoneStepsAndFindsTheCurrentOne() {
        let h = hird("H1", .working, last: t0, steps: [
            HirdStep(title: "원인 찾기", state: .done),
            HirdStep(title: "수정", state: .done),
            HirdStep(title: "테스트", state: .active),
            HirdStep(title: "정리", state: .pending),
        ])
        #expect(h.progress.done == 2)
        #expect(h.progress.total == 4)
        #expect(h.progress.current?.title == "테스트")
    }

    @Test func blockedStepIsCurrentWhenNothingIsActive() {
        let h = hird("H1", .waitingOnHuman(since: t0), last: t0, steps: [
            HirdStep(title: "빌드", state: .done),
            HirdStep(title: "업로드", state: .blocked),
            HirdStep(title: "확인", state: .pending),
        ])
        #expect(h.progress.current?.title == "업로드")
    }
}

@Suite struct QuestionGroupingTests {
    private func question(_ issue: KnarrCore.Issue.ID, _ state: Question.State) -> Question {
        Question(id: Question.ID("q-\(issue.rawValue)"), issue: issue, run: "h1", asker: "Hird-2",
                 prompt: "?", options: ["a", "b"], askedAt: t0, state: state)
    }

    @Test func aPendingQuestionGetsItsOwnAnswerSection() {
        let issues = [issue("asking", .running), issue("busy", .running, hirds: [hird("h", .working, last: t0)])]
        let sections = Panel.sections(for: issues, questions: [question(KnarrCore.Issue.ID("asking"), .pending)])
        #expect(sections.map(\.kind) == [.needsAnswer, .inProgress])
        #expect(sections[0].issues.map(\.title) == ["asking"])
        #expect(sections[1].issues.map(\.title) == ["busy"])
        #expect(issues[0].needsAnswer(hasPendingQuestion: true))
        #expect(!issues[1].needsAnswer())
    }

    @Test func answeredQuestionDoesNotPullTheIssue() {
        let answered = question(KnarrCore.Issue.ID("asking"), .answered(QuestionAnswer(selectedOptions: ["a"], text: nil)))
        let sections = Panel.sections(for: [issue("asking", .running, hirds: [hird("h", .working, last: t0)])], questions: [answered])
        #expect(sections.map(\.kind) == [.inProgress])
    }
}

@MainActor @Suite struct SampleQuestionFlowTests {
    @Test func answeringResumesTheAskingHirdOnce() {
        let store = SampleKnarrStore(now: t0)
        let id = Question.ID("q-v1-saves")
        #expect(Panel.sections(for: store.issues, questions: store.questions).first?.issues.contains { $0.id == "npc-repeat" } == true)

        store.answer(id, with: QuestionAnswer(selectedOptions: ["v1도 넣어줘"], text: nil))
        #expect(store.question(id)?.state == .answered(QuestionAnswer(selectedOptions: ["v1도 넣어줘"], text: nil)))
        #expect(store.issue("npc-repeat")?.hirds.first { $0.id == "h2" }?.status == .working)
        #expect(Panel.sections(for: store.issues, questions: store.questions).first { $0.kind == .inProgress }?.issues.contains { $0.id == "npc-repeat" } == true)

        // A second answer or a late cancel does not change the decision.
        store.answer(id, with: QuestionAnswer(selectedOptions: ["v2, v3만 확인해"], text: nil))
        store.cancel(id)
        #expect(store.question(id)?.state == .answered(QuestionAnswer(selectedOptions: ["v1도 넣어줘"], text: nil)))
    }
}

@Suite struct HirdRoleSummaryTests {
    @Test func longInstructionShowsItsFirstLineOnly() {
        let h = hird("H", .working, last: t0)
        var long = h
        long.role = "\n  Task: fix the bug in `add` in calc.py (project root). The user reports add returns wrong results.\n\nSteps:\n1. Inspect"
        #expect(long.roleSummary == "Task: fix the bug in `add` in calc.py (project root). The user r…")
        var short = h
        short.role = "원인 찾고 고치기"
        #expect(short.roleSummary == "원인 찾고 고치기")
    }
}

@Suite struct ResultApplicationPanelTests {
    @Test func appliedResultLeavesPanelAndBlockedResultRemainsAwaitingIntegration() {
        var applied = issue("applied", .done, confirmed: true)
        applied.application = .applied(branch: "main", commit: "abc1234")
        var blocked = issue("blocked", .done, confirmed: true)
        blocked.application = .blocked("원본에 커밋하지 않은 변경이 있어요")
        let sections = Panel.sections(for: [applied, blocked])
        #expect(sections.map(\.kind) == [.awaitingIntegration])
        #expect(sections[0].issues.map(\.title) == ["blocked"])
    }
}

@Suite struct StoppedRunDisplayTests {
    @Test func aStoppedRunHasNoStepInProgress() {
        let steps = [HirdStep(title: "a", state: .done), HirdStep(title: "b", state: .active), HirdStep(title: "c", state: .pending)]
        let stopped = hird("H", .failed(at: t0), last: t0, steps: steps)
        #expect(stopped.displaySteps.map(\.state) == [.done, .pending, .pending])
        #expect(stopped.progress.current == nil)
        let working = hird("H", .working, last: t0, steps: steps)
        #expect(working.displaySteps.map(\.state) == [.done, .active, .pending])
        #expect(working.progress.current?.title == "b")
    }

    @Test func aFinishedIssueShowsItsLatestRun() {
        let first = hird("H1", .failed(at: t0), last: t0)
        let second = hird("H2", .done(at: t0.addingTimeInterval(120)), last: t0.addingTimeInterval(120))
        #expect(issue("t", .done, hirds: [first, second]).liveness(now: t0.addingTimeInterval(200)) == .finished(at: t0.addingTimeInterval(120)))
    }
}
