import Foundation
import Testing
@testable import KnarrCore

/// Stallari reads the same progress the issue cards show, through `get_run`.
@Suite(.serialized) struct HirdProgressGetRunTests {
    private func invoke(_ name: String, _ args: OMPJSON, fixture f: StallariFixture) async throws -> OMPJSON {
        let id = UUID().uuidString
        await f.rpc.emit(.frame(.object(["type": .string("host_tool_call"), "id": .string(id), "toolName": .string(name), "arguments": args])))
        for _ in 0..<300 {
            if let reply = await f.rpc.sent.first(where: { $0["id"]?.string == id }) { return .object(reply) }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw OMPRPCError.timedOut
    }

    private func progress(_ f: StallariFixture, run: String = "r") async throws -> OMPJSON {
        let reply = try await invoke("get_run", .object(["runID": .string(run)]), fixture: f)
        #expect(reply["isError"]?.bool != true)
        return try #require(reply["result"]?["details"]?["run"]?["progress"])
    }

    private func result(_ f: StallariFixture, _ checks: [(String, Int32?)], report: Bool = false) throws -> RunResult {
        let start = Date.now.addingTimeInterval(-600)
        let log = f.directory.appendingPathComponent("check.log")
        try "ok".write(to: log, atomically: true, encoding: .utf8)
        let records = checks.enumerated().map { index, check in
            VerificationRecord(id: "verification-\(index)", command: [check.0], workingDirectory: f.directory.path,
                               startedAt: start.addingTimeInterval(Double(index) * 10), finishedAt: start.addingTimeInterval(Double(index) * 10 + 5),
                               exitCode: check.1, logPath: log.path, summary: "check")
        }
        return .init(worktreePath: f.directory.path, branch: "b", commit: "c", diffPath: nil, summary: "저장", verifications: records,
                     reportPath: report ? log.path : nil)
    }

    private func save(_ f: StallariFixture, _ result: RunResult, id: String) async throws {
        _ = try await f.session.receive(.init(id: id, runID: "r", at: .now, payload: .saveResult(result)))
    }

    @Test func unplannedRunsExposeChecksWithoutInventingAPlan() async throws {
        let f = try await StallariFixture.make()
        do {
            try await f.session.connect()
            let issue = try await f.issue("t")
            _ = try await f.dispatch("r", issue: issue)
            var p = try await progress(f)
            #expect(p["stageCount"]?.integer == 0)
            #expect(p["stageIndex"] == .null && p["stage"] == .null && p["stageTitle"] == .null)
            #expect(p["state"]?.string == "running")
            #expect(p["stages"]?.array?.isEmpty == true)
            try await save(f, result(f, [("git switch -c codex/x", 0), ("swift test --filter HirdProgress", 1)]), id: "red")
            p = try await progress(f)
            #expect(p["stage"] == .null && p["stageIndex"] == .null)
            #expect(p["basis"]?.string == "swift test --filter HirdProgress")
            #expect(p["checks"]?["failed"]?.integer == 1 && p["checks"]?["passed"]?.integer == 1)
            try await save(f, result(f, [("swift test --no-parallel", 0)], report: true), id: "final")
            p = try await progress(f)
            #expect(p["stageCount"]?.integer == 0 && p["stages"]?.array?.isEmpty == true)
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }

    @Test func aPendingQuestionShowsAsWaitingAndCompletionPreservesUnknownStages() async throws {
        let f = try await StallariFixture.make()
        do {
            try await f.session.connect()
            let issue = try await f.issue("t")
            _ = try await f.dispatch("r", issue: issue)
            try await save(f, result(f, [("swift test --filter HirdProgress", 1)]), id: "red")
            _ = try await f.session.receive(.init(id: "ask", runID: "r", at: .now, payload: .ask(.init(
                id: "q1", runID: "r", issueID: issue, prompt: "계속할까요?", options: ["예", "아니요"], createdAt: .now, source: .hird))))
            var p = try await progress(f)
            #expect(p["state"]?.string == "waitingQuestion")
            #expect(p["stage"] == .null)

            let finished = try result(f, [("swift test --filter HirdProgress", 1), ("swift test --no-parallel", 0)], report: true)
            _ = try await f.session.receive(.init(id: "done", runID: "r", at: .now, payload: .complete(finished, notificationID: "n1")))
            p = try await progress(f)
            #expect(p["state"]?.string == "done")
            #expect(p["stageIndex"] == .null)
            #expect(p["stages"]?.array?.isEmpty == true)
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }

    @Test func aStoppedRunKeepsItsStageAndReadsAsStopped() async throws {
        let f = try await StallariFixture.make()
        do {
            try await f.session.connect()
            let issue = try await f.issue("t")
            _ = try await f.dispatch("r", issue: issue)
            try await save(f, result(f, [("swift test --filter HirdProgress", 1)]), id: "red")
            _ = try await f.session.receive(.init(id: "fail", runID: "r", at: .now, payload: .fail("중단")))
            let p = try await progress(f)
            #expect(p["state"]?.string == "stopped")
            #expect(p["stage"] == .null)
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }

    @Test func getRuntimeListsProgressForEveryActiveRun() async throws {
        let f = try await StallariFixture.make()
        do {
            try await f.session.connect()
            let issue = try await f.issue("t")
            _ = try await f.dispatch("r", issue: issue)
            try await save(f, result(f, [("swift test --filter HirdProgress", 1)]), id: "red")
            let reply = try await invoke("get_runtime", .object([:]), fixture: f)
            let runs = try #require(reply["result"]?["details"]?["activeRuns"]?.array)
            #expect(runs.first?["progress"]?["stage"] == .null)
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }

    /// The board reads `store.issues`, which come from the repository snapshot: the same event stream, no second source.
    @Test func theSnapshotHandsTheBoardProgressForRunsStillGoing() async throws {
        let f = try await StallariFixture.make()
        do {
            try await f.session.connect()
            let issue = try await f.issue("t")
            _ = try await f.dispatch("r", issue: issue)
            try await save(f, result(f, [("swift test --filter HirdProgress", 1)]), id: "red")
            let working = try #require(try await f.repository.snapshot().issues.first { $0.id == issue }?.hirds.first)
            #expect(working.stageProgress?.stage == .failingTest)
            #expect(working.stageProgress?.condition == .running)

            _ = try await f.session.receive(.init(id: "fail", runID: "r", at: .now, payload: .fail("중단")))
            let stopped = try #require(try await f.repository.snapshot().issues.first { $0.id == issue }?.hirds.first)
            #expect(stopped.stageProgress == nil)
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }

    @Test func customStagesAndEvidenceProjectIdenticallyAcrossAllReadAPIsAndCards() async throws {
        let f = try await StallariFixture.make()
        do {
            try await f.session.connect()
            let plan: [IssueStage] = [
                .init(id: "a", title: "저장 자료 확인", evidence: "구형 자료 읽기", criterion: 1),
                .init(id: "b", title: "실행 확인", evidence: "실제 실행 기록")
            ]
            let issue = try await f.session.createIssue(id: "planned", title: "실행 단계",
                criteria: ["단계 진행을 기록해요"], instruction: "단계별 작업", stages: plan)
            _ = try await f.dispatch("r", issue: issue)
            #expect(try await progress(f)["stageCount"]?.integer == 2)
            let at = Date.now
            _ = try await f.session.receive(.init(id: "stage-start", runID: "r", at: at,
                payload: .stage(.init(at: at, action: .started, stageID: "a"))))
            let doneAt = at.addingTimeInterval(1)
            _ = try await f.session.receive(.init(id: "stage-done", runID: "r", at: doneAt,
                payload: .stage(.init(at: doneAt, action: .completed, stageID: "a", note: "추가 근거 대기"))))
            let changedAt = at.addingTimeInterval(2)
            let changed = [plan[0], IssueStage(id: "b", title: "실행 경계 검사", evidence: "소유 실행 검사")]
            _ = try await f.session.receive(.init(id: "stage-replan", runID: "r", at: changedAt,
                payload: .stage(.init(at: changedAt, action: .replanned, stageID: "", plan: changed, reason: "실행 검사의 대상을 구체화"))))

            let runProgress = try await progress(f)
            #expect(runProgress["stageCount"]?.integer == 2)
            #expect(runProgress["stageTitle"] == .null)
            #expect(runProgress["stages"]?.array?.first?["verified"]?.bool == false)
            #expect(runProgress["stages"]?.array?.first?["state"]?.string == "done")
            #expect(runProgress["planChanges"]?.array?.first?["reason"]?.string == "실행 검사의 대상을 구체화")
            let issueReply = try await invoke("get_issue", .object(["issueID": .string(issue.rawValue)]), fixture: f)
            let runtimeReply = try await invoke("get_runtime", .object([:]), fixture: f)
            #expect(issueReply["result"]?["details"]?["issue"]?["progress"] == runProgress)
            #expect(runtimeReply["result"]?["details"]?["activeRuns"]?.array?.first?["progress"] == runProgress)
            let snapshotIssue = try #require(try await f.repository.snapshot().issues.first { $0.id == issue })
            #expect(StallariReadback.progress(IssueCards.progress(for: snapshotIssue)) == runProgress)
            #expect(snapshotIssue.acceptance.allSatisfy { $0.state == .pending })

            // Stopping a custom-plan run preserves its own stage states and evidence marks on cards.
            _ = try await f.session.receive(.init(id: "stage-stop", runID: "r", at: changedAt.addingTimeInterval(1), payload: .fail("중단")))
            let stoppedIssue = try #require(try await f.repository.snapshot().issues.first { $0.id == issue })
            let stoppedProgress = IssueCards.progress(for: stoppedIssue)
            #expect(stoppedProgress.condition == .stopped)
            #expect(stoppedProgress.plannedStages.map(\.state) == [.done, .pending])
            #expect(stoppedProgress.plannedStages.first?.verified == false)
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }

    @Test func snapshotKeepsAnUnreportedPlanAfterRunCompletionAndJudgement() async throws {
        let f = try await StallariFixture.make()
        do {
            try await f.session.connect()
            let plan: [IssueStage] = [
                .init(id: "a", title: "자료 확인", evidence: "원문"),
                .init(id: "b", title: "구현 확인", evidence: "검사")
            ]
            let issue = try await f.session.createIssue(id: "unreported", title: "보고 없는 실행",
                criteria: ["검사 통과"], instruction: "작업", stages: plan)
            _ = try await f.dispatch("r", issue: issue)
            let at = Date.now
            _ = try await f.session.receive(.init(id: "activity", runID: "r", at: at,
                payload: .activityState(.init(kind: .edit, target: "Panel.swift", at: at), currentCommand: "edit")))
            let finished = try result(f, [("swift test --no-parallel", 0)], report: true)
            _ = try await f.session.receive(.init(id: "done", runID: "r", at: .now,
                payload: .complete(finished, notificationID: "finished")))
            let judging = try #require(try await f.repository.snapshot().issues.first { $0.id == issue })
            #expect(judging.presentationStatus() == .judging)
            #expect(judging.hirds.first?.stageProgress?.plannedStages.map(\.state) == [.pending, .pending])
            #expect(judging.hirds.first?.recentActivities?.last?.target == "Panel.swift")
            try await f.session.judge(issueID: issue, runID: "r", evidence: [
                .init(criterionIndex: 0, verificationIDs: ["verification-0"], explanation: "검사 통과")])
            let judged = try #require(try await f.repository.snapshot().issues.first { $0.id == issue })
            #expect(judged.presentationStatus() == .awaitingIntegration)
            #expect(IssueCards.progress(for: judged).plannedStages.map(\.state) == [.pending, .pending])
            #expect(judged.acceptance.first?.state == .met)
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }

    @Test func onlyTheLastEditTimeIsSavedWithARunNotTheDerivedProgress() throws {
        var run = HirdRun(id: "r", name: "Hird", role: "역할", status: .working, steps: [], currentCommand: nil, lastActivityAt: .now)
        run.stageProgress = .initial
        run.lastEditAt = Date(timeIntervalSince1970: 1_800_000_000)
        let saved = String(decoding: try JSONEncoder().encode(run), as: UTF8.self)
        #expect(saved.contains("lastEditAt") && !saved.contains("stageProgress"))
        let reloaded = try JSONDecoder().decode(HirdRun.self, from: Data(saved.utf8))
        #expect(reloaded.lastEditAt == run.lastEditAt && reloaded.stageProgress == nil)
        // A run saved before progress existed has neither key.
        var legacy = try #require(try JSONSerialization.jsonObject(with: Data(saved.utf8)) as? [String: Any])
        legacy.removeValue(forKey: "lastEditAt")
        let old = try JSONDecoder().decode(HirdRun.self, from: try JSONSerialization.data(withJSONObject: legacy))
        #expect(old.lastEditAt == nil)
    }
}
