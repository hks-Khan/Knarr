import Foundation
import Testing
@testable import KnarrCore

/// The five-stage progress of one Hird run, derived only from what the run already recorded:
/// its saved checks (command, exit code, finish time), the command running now, the last file edit,
/// whether a report exists, and whether a question waits for the person.
struct HirdProgressTests {
    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    static func check(_ command: String, _ exit: Int32?, _ seconds: TimeInterval) -> HirdProgress.Check {
        .init(command: command, exitCode: exit, finishedAt: t0.addingTimeInterval(seconds))
    }

    static func progress(_ checks: [HirdProgress.Check] = [], current: String? = nil, edit: TimeInterval? = nil,
                         report: Bool = false, waiting: Bool = false,
                         outcome: HirdProgress.Outcome = .active) -> HirdProgress {
        .init(.init(checks: checks, currentCommand: current, lastEditAt: edit.map { t0.addingTimeInterval($0) },
                    hasReport: report, waitingOnQuestion: waiting, outcome: outcome))
    }

    private static let red = check("swift test --filter HirdProgress", 1, 10)
    private static let green = check("swift test --filter HirdProgress", 0, 30)
    private static let finalPass = check("swift test --no-parallel", 0, 50)

    @Test func startsAtPrepareBeforeAnyEvidence() {
        let p = Self.progress()
        #expect(p.stage == .prepare)
        #expect(p.stages == [.active, .pending, .pending, .pending, .pending])
        #expect(p.condition == .running)
        #expect(p.stageIndex == 1 && HirdProgress.stageCount == 5)
        #expect(p.basis == nil)
        #expect(p == .initial)
    }

    @Test func branchAndStatusCommandsAreStillPrepare() {
        let p = Self.progress([Self.check("git switch -c codex/hird-progress-board", 0, 1), Self.check("git status --short", 0, 2)])
        #expect(p.stage == .prepare)
        #expect(p.basis == "git status --short")
    }

    @Test func firstFailingFilterRunIsTheFailingTestStage() {
        let p = Self.progress([Self.check("git switch -c codex/x", 0, 1), Self.red])
        #expect(p.stage == .failingTest)
        #expect(p.stages == [.done, .active, .pending, .pending, .pending])
        #expect(p.basis == "swift test --filter HirdProgress")
    }

    @Test func aPassingFilterRunBeforeAnyFailureProvesNothing() {
        #expect(Self.progress([Self.check("swift test --filter HirdProgress", 0, 5)]).stage == .prepare)
    }

    @Test func aFileChangeAfterTheFirstFailureStartsImplementation() {
        let p = Self.progress([Self.red], edit: 20)
        #expect(p.stage == .implement)
        #expect(p.stages == [.done, .done, .active, .pending, .pending])
        #expect(p.basis == nil)
    }

    @Test func aFileChangeBeforeTheFailureDoesNotCount() {
        #expect(Self.progress([Self.red], edit: 5).stage == .failingTest)
    }

    @Test func aChangeInFlightAfterTheFailureCountsButNotBeforeIt() {
        #expect(Self.progress([Self.red], current: "edit").stage == .implement)
        #expect(Self.progress([], current: "edit").stage == .prepare)
        #expect(Self.progress([Self.red], current: "read").stage == .failingTest)
    }

    @Test func rerunningTheFilterAfterTheFailureIsImplementation() {
        let rerun = Self.progress([Self.red, Self.green])
        #expect(rerun.stage == .implement)
        #expect(rerun.basis == "swift test --filter HirdProgress")
        // A second failure is also implementation work, never a new "first failure".
        #expect(Self.progress([Self.red, Self.check("swift test --filter HirdProgress", 1, 40)]).stage == .implement)
    }

    @Test(arguments: [
        "swift test --no-parallel",
        "cd /tmp/work && swift test --no-parallel",
        "scripts/build-app.sh",
        "scripts/qa-build-app.sh",
    ])
    func finalCheckCommandsMarkTheFinalCheckStage(command: String) {
        let p = Self.progress([Self.red, Self.green, Self.check(command, 0, 60)])
        #expect(p.stage == .finalCheck)
        #expect(p.stages == [.done, .done, .done, .active, .pending])
        #expect(p.basis == command)
    }

    @Test func aFilteredRunStaysAFilterEvenWithNoParallel() {
        #expect(Self.progress([Self.check("swift test --no-parallel --filter HirdProgress", 1, 10)]).stage == .failingTest)
    }

    @Test func otherCommandsNeverMoveTheStage() {
        let p = Self.progress([Self.check("swift build", 0, 1), Self.check("swift test", 1, 2), Self.check("ls -la", 0, 3),
                               Self.check("swift run knarr-snapshot outputs/x", 0, 4)])
        #expect(p.stage == .prepare)
    }

    @Test func aMissingExitCodeCountsAsRunningNotAsFailureOrPass() {
        let running = Self.progress([Self.check("swift test --filter HirdProgress", nil, 10)])
        #expect(running.stage == .failingTest)
        #expect(running.checks == .init(passed: 0, failed: 0, running: 1))
        // It is not the "first failure", so a later edit starts nothing.
        #expect(Self.progress([Self.check("swift test --filter HirdProgress", nil, 10)], edit: 20).stage == .failingTest)
        let unfinishedFinal = Self.progress([Self.red, Self.check("swift test --no-parallel", nil, 60)])
        #expect(unfinishedFinal.stage == .finalCheck)
        #expect(unfinishedFinal.checks.running == 1 && unfinishedFinal.checks.failed == 1)
    }

    @Test func aCheckRunningNowCountsAsRunning() {
        let p = Self.progress([Self.red], current: "swift test --no-parallel")
        #expect(p.stage == .finalCheck)
        #expect(p.checks == .init(passed: 0, failed: 1, running: 1))
        #expect(p.basis == "swift test --no-parallel")
        #expect(Self.progress([Self.red], current: "edit").checks.running == 0)
    }

    @Test func checksAreTalliedByExitCode() {
        let p = Self.progress([Self.red, Self.green, Self.finalPass, Self.check("swift test --no-parallel", 2, 70)])
        #expect(p.checks == .init(passed: 2, failed: 2, running: 0))
    }

    @Test func reportNeedsAPassedFinalCheck() {
        // Chat between tool calls is saved as a report too, so a report alone says nothing yet.
        #expect(Self.progress([Self.red], report: true).stage == .failingTest)
        #expect(Self.progress([Self.red, Self.check("swift test --no-parallel", 1, 50)], report: true).stage == .finalCheck)
        let p = Self.progress([Self.red, Self.green, Self.finalPass], report: true)
        #expect(p.stage == .report)
        #expect(p.stages == [.done, .done, .done, .done, .active])
        #expect(Self.progress([Self.red, Self.green, Self.finalPass]).stage == .finalCheck)
    }

    @Test func aStageNeverGoesBack() {
        let p = Self.progress([Self.finalPass, Self.check("swift test --filter HirdProgress", 1, 60)])
        #expect(p.stage == .finalCheck)
    }

    @Test func theOrderChecksArrivedInDoesNotMatter() {
        let chronological = Self.progress([Self.red, Self.green, Self.finalPass], report: true)
        #expect(Self.progress([Self.finalPass, Self.green, Self.red], report: true) == chronological)
    }

    @Test func aWaitingQuestionKeepsTheStageAndChangesTheCondition() {
        let p = Self.progress([Self.red], edit: 20, waiting: true)
        #expect(p.stage == .implement)
        #expect(p.condition == .waitingQuestion)
        #expect(p.steps.map(\.state) == [.done, .done, .blocked, .pending, .pending])
    }

    @Test func aFinishedRunDoesNotCompleteStagesWithoutEvidence() {
        let p = Self.progress([Self.red], outcome: .done)
        #expect(p.condition == .done)
        #expect(p.stage == .failingTest)
        #expect(p.stages == [.done, .pending, .pending, .pending, .pending])
        #expect(!p.steps.allSatisfy { $0.state == .done })
    }

    @Test func aStoppedRunKeepsWhereItStopped() {
        let p = Self.progress([Self.red], edit: 20, outcome: .stopped)
        #expect(p.condition == .stopped)
        #expect(p.stage == .implement)
        #expect(p.stages == [.done, .done, .active, .pending, .pending])
        #expect(p.steps.map(\.state) == [.done, .done, .failed, .pending, .pending])
    }

    @Test func onlyEditWriteAndAstEditChangeFiles() {
        for tool in ["edit", "write", "ast_edit"] { #expect(HirdProgress.isFileChange(tool), Comment(rawValue: tool)) }
        for other in ["bash", "read", "grep", "swift test --filter A", "lsp", "git status"] {
            #expect(!HirdProgress.isFileChange(other), Comment(rawValue: other))
        }
    }
}
