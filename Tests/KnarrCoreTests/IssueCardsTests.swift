import Foundation
import Testing
@testable import KnarrCore

struct IssueCardsTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func issue(_ id: String, state: IssueState = .running, thread: String? = nil, project: String = "P") -> KnarrCore.Issue {
        var value = KnarrCore.Issue(id: .init(id), title: id, projectName: project, state: state,
                                  headline: "최근 진행", detail: "", acceptance: [], hirds: [], events: [], startedAt: now)
        value.threadID = thread
        return value
    }

    @Test func summaryOmitsStatusOnlyHeadlinesButPreservesActualFailureAndResult() {
        var value = issue("summary")
        value.headline = "실행 중"
        #expect(IssueCards.latestLine(for: value).isEmpty)
        value.hirds = [.init(id: "worker", name: "Hird", role: "검사", status: .working, steps: [], currentCommand: nil, lastActivityAt: now)]
        value.headline = "Hird 실행"
        #expect(IssueCards.latestLine(for: value).isEmpty)
        value.headline = ""
        #expect(IssueCards.latestLine(for: value).isEmpty)
        value.headline = "최근 문장 기억 수정"
        #expect(IssueCards.latestLine(for: value) == "최근 문장 기억 수정")
        value.state = .failed; value.headline = "실행 실패"; value.detail = "swift test: 누락된 저장 샘플"
        #expect(IssueCards.latestLine(for: value) == "swift test: 누락된 저장 샘플")
        value.state = .done; value.headline = "완료 조건 충족"; value.detail = "저장 데이터 호환성 확인"
        #expect(IssueCards.latestLine(for: value) == "저장 데이터 호환성 확인")
    }

    @Test func attentionOrderingAndClosedExclusion() {
        var archived = issue("archived"); archived.archivedAt = now
        var applied = issue("applied", state: .done); applied.application = .applied(branch: "main", commit: "abc")
        let question = Question(id: "q", issue: "question", run: "r", asker: "Hird", prompt: "선택", options: [], askedAt: now)
        let values = [issue("done", state: .done), issue("running"), issue("stopped", state: .failed),
                      issue("approval", state: .awaitingApproval), issue("question"), issue("input", state: .needsInput), archived, applied]
        #expect(IssueCards(issues: values, questions: [question], scope: .allProjects).issues.map(\.id.rawValue) ==
                ["input", "question", "approval", "running", "done", "stopped"])
    }

    @Test func projectAndCustomThreadScopeDoNotLeak() {
        let values = [issue("main"), issue("custom", thread: "custom"), issue("other", project: "Q")]
        #expect(IssueCards(issues: values, scope: .project("P")).issues.map(\.id.rawValue) == ["custom", "main"])
        #expect(IssueCards(issues: values, scope: .thread("custom", project: "P")).issues.map(\.id.rawValue) == ["custom"])
    }

    @Test func elapsedBoundaryAndCompletionFormatting() {
        #expect(IssueCards.elapsed(from: now, to: now.addingTimeInterval(3599)) == "59분째")
        #expect(IssueCards.elapsed(from: now, to: now.addingTimeInterval(3600)) == "1시간 0분째")
        #expect(IssueCards.elapsed(from: now, to: now.addingTimeInterval(3660), completed: true) == "걸린 시간 1시간 1분")
        #expect(IssueCards.elapsed(from: now, to: now.addingTimeInterval(1440), completed: true) == "걸린 시간 24분")
        #expect(IssueCards.elapsed(from: now, to: now.addingTimeInterval(3599), completed: true) == "걸린 시간 59분")
        #expect(IssueCards.elapsed(from: now, to: now.addingTimeInterval(3600), completed: true) == "걸린 시간 1시간 0분")
        #expect(IssueCards.elapsed(from: now, to: now.addingTimeInterval(-1)) == "0분째")
    }

    @Test func quietUsesExistingLivenessBoundaryAndEveryActiveHirdSurvives() {
        var value = issue("many")
        value.hirds = (1...8).map { HirdRun(id: .init("r\($0)"), name: "Hird", role: "구현", status: .working,
                                         steps: [], currentCommand: "swift test", lastActivityAt: now) }
        #expect(IssueCards.activeHirds(for: value).count == 8)
        #expect(IssueCards.quietLabel(for: value.hirds[0], now: now.addingTimeInterval(89)) == nil)
        #expect(IssueCards.quietLabel(for: value.hirds[0], now: now.addingTimeInterval(90)) == "1분째 조용함")
    }

    @Test func firstApprovalSurvivesRerunsAndJudgedCompletionFreezesTime() {
        var value = issue("done", state: .done)
        value.approvalHistory = [.init(version: 1, approvedAt: now)]
        value.approval = .init(version: 2, approvedAt: now.addingTimeInterval(3000))
        value.completedAt = now.addingTimeInterval(3660)
        #expect(IssueCards.elapsed(for: value, now: now.addingTimeInterval(9000)) == "걸린 시간 1시간 1분")
        value.state = .running; value.completedAt = nil
        #expect(IssueCards.elapsed(for: value, now: now.addingTimeInterval(7200)) == "2시간 0분째")
    }

    @Test func legacyCompletionUsesLatestFinishedHirdNotActivity() {
        var value = issue("legacy", state: .done)
        value.approval = .init(version: 1, approvedAt: now)
        value.hirds = [HirdRun(id: "r", name: "Hird", role: "", status: .done(at: now.addingTimeInterval(120)),
                              steps: [], currentCommand: nil, lastActivityAt: now.addingTimeInterval(90))]
        #expect(IssueCards.completion(of: value) == now.addingTimeInterval(120))
    }

    @Test func dedicatedCustomIssuesFollowTheirOriginAndMainProjectIncludesThem() {
        var dedicated = ConversationThread(id: "issue-thread", name: "전용")
        dedicated.issueID = "dedicated"; dedicated.originThreadID = "custom"
        let values = [issue("dedicated", thread: dedicated.id), issue("legacy", thread: "custom"), issue("other", thread: "other")]
        #expect(IssueCards(issues: values, threads: [dedicated], scope: .thread("custom", project: "P")).issues.map(\.id.rawValue) == ["dedicated", "legacy"])
        #expect(IssueCards(issues: values, threads: [dedicated], scope: .project("P")).issues.count == 3)
    }

    @Test func projectOwnedTodoReviewRunningAndAnswerNeededStayVisible() {
        func owned(_ id: String, state: IssueState, hirds: [HirdRun] = []) -> KnarrCore.Issue {
            var value = issue(id, state: state, thread: "issue-" + id, project: "Linked")
            value.hirds = hirds
            return value
        }
        let working = HirdRun(id: "run", name: "Hird", role: "", status: .working, steps: [],
                              currentCommand: nil, lastActivityAt: now)
        let waiting = HirdRun(id: "run", name: "Hird", role: "", status: .waitingOnHuman(since: now), steps: [],
                              currentCommand: nil, lastActivityAt: now)
        let projectThread = ConversationThread(id: "project-thread", name: "Project", projectID: "linked")
        let mainThread = ConversationThread.default
        func ownerThread(_ issueID: String, origin: String) -> ConversationThread {
            .init(id: "issue-" + issueID, name: issueID, issueID: .init(issueID), originThreadID: origin)
        }
        var legacy = issue("legacy") // no threadID, no origin
        legacy.state = .awaitingApproval
        var mainOwned = issue("main-owned", thread: "issue-main-owned")
        mainOwned.state = .awaitingApproval
        var archived = issue("project-archived", thread: "issue-project-archived", project: "Linked")
        archived.state = .awaitingApproval; archived.archivedAt = now
        var applied = issue("project-applied", state: .done, thread: "issue-project-applied", project: "Linked")
        applied.application = .applied(branch: "main", commit: "abc")
        let values = [
            owned("project-todo", state: .awaitingApproval),
            owned("project-review", state: .failed),
            owned("project-running", state: .running, hirds: [working]),
            owned("project-question", state: .running, hirds: [waiting]),
            legacy, mainOwned, archived, applied
        ]
        let threads = [projectThread, mainThread,
                       ownerThread("project-todo", origin: "project-thread"),
                       ownerThread("project-review", origin: "project-thread"),
                       ownerThread("project-running", origin: "project-thread"),
                       ownerThread("project-question", origin: "project-thread"),
                       ownerThread("main-owned", origin: ConversationThread.defaultID)]
        let open = ["project-question", "legacy", "main-owned", "project-todo", "project-review", "project-running"]
        let cards = IssueCards(issues: values, threads: threads, scope: .allProjects)
        #expect(cards.issues.map(\.id.rawValue) == open)
        #expect(cards.answerCount == 1)
        #expect(IssueCards(issues: values, threads: threads, scope: .project("Linked"))
            .issues.map(\.id.rawValue) == ["project-question", "project-todo", "project-review", "project-running"])
    }

    @Test func historyContainsAppliedAndCancelledButNotUnmergedReview() {
        var closed = issue("closed", state: .failed); closed.archivedAt = now.addingTimeInterval(10)
        var applied = issue("applied", state: .failed); applied.application = .applied(branch: "main", commit: "abc")
        #expect(IssueCards.history(issues: [issue("running"), issue("done", state: .done), applied, closed]).map(\.id.rawValue) == ["closed", "applied"])
    }

    @Test(arguments: [false, true])
    func issueStageUsesFurthestActiveEvidenceRegardlessOfRunOrder(reversed: Bool) {
        var value = issue("parallel")
        let red = HirdProgress.Check(command: "swift test --filter Feature", exitCode: 1, finishedAt: now)
        var implementing = HirdRun(id: "implementing", name: "Hird-1", role: "", status: .working,
            steps: [], currentCommand: nil, lastActivityAt: now)
        implementing.stageProgress = HirdProgress(.init(checks: [red], lastEditAt: now.addingTimeInterval(1)))
        let preparing = HirdRun(id: "preparing", name: "Hird-2", role: "", status: .working,
            steps: [], currentCommand: nil, lastActivityAt: now)
        var finished = HirdRun(id: "finished", name: "Hird-3", role: "", status: .done(at: now),
            steps: [], currentCommand: nil, lastActivityAt: now)
        finished.stageProgress = HirdProgress(.init(outcome: .done))
        value.hirds = reversed ? [preparing, implementing, finished] : [implementing, preparing, finished]
        let progress = IssueCards.progress(for: value)
        #expect(progress.stage == .implement)
        #expect(progress.stages == [.done, .done, .active, .pending, .pending])
        #expect(progress.condition == .running)
    }

    @Test func earlierWaitingRunBlocksTheFurthestIssueStageWithoutMovingItBack() {
        var value = issue("waiting", state: .needsInput)
        var advanced = HirdRun(id: "advanced", name: "Hird-1", role: "", status: .working,
            steps: [], currentCommand: "swift test --no-parallel", lastActivityAt: now)
        advanced.stageProgress = HirdProgress(.init(currentCommand: advanced.currentCommand))
        var waiting = HirdRun(id: "waiting", name: "Hird-2", role: "", status: .waitingOnHuman(since: now),
            steps: [], currentCommand: nil, lastActivityAt: now)
        waiting.stageProgress = HirdProgress(.init(waitingOnQuestion: true))
        value.hirds = [advanced, waiting]
        let progress = IssueCards.progress(for: value)
        #expect(progress.stage == .finalCheck)
        #expect(progress.condition == .waitingQuestion)
        #expect(progress.steps[HirdProgress.Stage.finalCheck.rawValue].state == .blocked)
    }

    @Test(arguments: [false, true])
    func customPlansSelectLatestActiveRunInsteadOfComparingStageCounts(reversed: Bool) {
        let olderPlan = (1...6).map { IssueStage(id: "old-\($0)", title: "이전 단계 \($0)", evidence: "해당 단계 기록") }
        let newerPlan = [IssueStage(id: "new", title: "새 작업 확인", evidence: "화면 확인")]
        var older = HirdRun(id: "older", name: "Hird-1", role: "", status: .working,
                            steps: [], currentCommand: nil, lastActivityAt: now)
        older.startedAt = now.addingTimeInterval(-120)
        older.stageProgress = HirdProgress(.init(plan: olderPlan, reports: [
            .init(at: now.addingTimeInterval(-60), action: .started, stageID: "old-6")
        ]))
        var newer = HirdRun(id: "newer", name: "Hird-2", role: "", status: .working,
                            steps: [], currentCommand: nil, lastActivityAt: now)
        newer.startedAt = now.addingTimeInterval(-30)
        newer.stageProgress = HirdProgress(.init(plan: newerPlan, reports: [
            .init(at: now, action: .started, stageID: "new")
        ]))
        var terminal = older
        terminal.id = "terminal"
        terminal.status = .done(at: now)
        terminal.startedAt = now
        var value = issue("custom")
        value.hirds = reversed ? [terminal, newer, older] : [older, newer, terminal]
        let progress = IssueCards.progress(for: value)
        #expect(progress.currentStageKey == "new")
        #expect(progress.stageCount == 1)
    }

    @Test(arguments: [false, true])
    func mixedCustomAndLegacyPlansSelectLatestWithoutOrderDependentRanking(reversed: Bool) {
        var older = HirdRun(id: "advanced", name: "Hird-1", role: "", status: .working,
                            steps: [], currentCommand: nil, lastActivityAt: now)
        older.startedAt = now.addingTimeInterval(-120)
        older.stageProgress = HirdProgress(.init(currentCommand: "swift test --no-parallel"))
        var custom = HirdRun(id: "custom", name: "Hird-2", role: "", status: .waitingOnHuman(since: now),
                             steps: [], currentCommand: nil, lastActivityAt: now)
        custom.startedAt = now.addingTimeInterval(-60)
        custom.stageProgress = HirdProgress(.init(plan: [
            .init(id: "custom", title: "사용자 선택 확인", evidence: "답변")
        ], reports: [.init(at: now, action: .started, stageID: "custom")]))
        var latest = HirdRun(id: "latest", name: "Hird-3", role: "", status: .working,
                             steps: [], currentCommand: nil, lastActivityAt: now)
        latest.startedAt = now.addingTimeInterval(-30)
        latest.stageProgress = .initial
        var value = issue("mixed")
        value.hirds = reversed ? [latest, custom, older] : [older, custom, latest]
        let progress = IssueCards.progress(for: value)
        #expect(progress.stage == .prepare)
        #expect(progress.plannedStages.isEmpty)
        #expect(progress.condition == .waitingQuestion)
    }

    @Test func terminalCustomReportsRemainAvailableOnIssueCards() {
        let plan = [IssueStage(id: "inspect", title: "결과 확인", evidence: "저장된 검사")]
        let report = StageReport(at: now, action: .completed, stageID: "inspect", verified: false)
        var run = HirdRun(id: "terminal", name: "Hird", role: "", status: .done(at: now),
                          steps: [], currentCommand: nil, lastActivityAt: now)
        run.stageProgress = HirdProgress(.init(outcome: .done, plan: plan, reports: [report]))
        var value = issue("terminal", state: .done)
        value.hirds = [run]
        let progress = IssueCards.progress(for: value)
        #expect(progress.stageCount == 1)
        #expect(progress.currentStageTitle == "결과 확인")
        #expect(progress.plannedStages.first?.state == .done)
        #expect(progress.plannedStages.first?.verified == false)
        #expect(progress.condition == .done)
    }


    @Test func failedJudgementTakesPrecedenceOverSuccessfulWorkerSummary() {
        var value = issue("unmet", state: .failed)
        let judgement = "설치 검증 실패"
        value.headline = "시도 2번"
        value.detail = judgement + "\n완료 조건 4/5"
        value.latestResult = .init(worktreePath: "/fixture", branch: "fixture", commit: "fixture",
                                  diffPath: nil, summary: "코드 검사 통과", verifications: [])
        #expect(IssueCards.latestLine(for: value) == judgement)
    }
}
