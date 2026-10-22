import Foundation
import Testing
@testable import KnarrCore

@Suite(.serialized) struct HirdStageRuntimeTests {
    static let plan = [IssueStage(id: "stage-1", title: "문서 확인", evidence: "실제 읽기 근거", criterion: 1)]

    static func prepare(_ run: PersistedRun, fixture f: HirdFixture) async throws {
        var issue = try #require(try await f.repository.snapshot().issues.first)
        issue.acceptance = [.init(text: "원문 확인", state: .pending, evidence: "")]
        try await f.repository.saveIssue(issue, projectID: run.projectID)
        _ = try await f.repository.createRun(run)
    }

    static func call(_ arguments: OMPJSON, fixture f: HirdFixture, id: String = UUID().uuidString) async throws -> OMPJSON {
        await f.rpc.frame(.object(["type": .string("host_tool_call"), "id": .string(id),
            "toolName": .string("report_stage"), "arguments": arguments]))
        for _ in 0..<500 {
            if let reply = await f.rpc.sends.first(where: { $0["id"]?.string == id }) { return .object(reply) }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw OMPRPCError.timedOut
    }

    static func report(_ action: String, stageID: String = "stage-1") -> OMPJSON {
        .object(["action": .string(action), "stageID": .string(stageID)])
    }

    @Test(arguments: [HirdRunMode.change, .inspect])
    func stageReportsSaveInBothRunModes(mode: HirdRunMode) async throws {
        let f = try await HirdFixture.make(preserve: true)
        var run = f.run; run.stagePlan = Self.plan; run.mode = mode
        try await HirdStageRuntimeTests.prepare(run, fixture: f)
        let task = Task { [run] in try await f.adapter.start(run, emit: f.sink) }
        do {
            try await HirdVerificationRetryTests.awaitPrompts(1, f)
            let requests = await f.rpc.requests
            let registration = try #require(requests.first { $0.0 == "set_host_tools" })
            let tool = try #require(registration.1["tools"]?.array?.first)
            #expect(tool["name"]?.string == "report_stage")
            #expect(tool["parameters"]?["additionalProperties"]?.bool == false)
            #expect(tool["parameters"]?["properties"]?["runID"] == nil)
            #expect(tool["parameters"]?["properties"]?["verified"] == nil)
            #expect(try #require(requests.firstIndex { $0.0 == "set_host_tools" }) < #require(requests.firstIndex { $0.0 == "prompt" }))
            if mode == .inspect {
                let arguments = await f.rpc.arguments
                let index = try #require(arguments.firstIndex(of: "--tools"))
                #expect(!arguments[index + 1].contains("report_stage"))
                #expect(Set(arguments[index + 1].split(separator: ",").map(String.init)).isSubset(of: Set(HirdInspectionPolicy.tools)))
            }
            let reply = try await Self.call(Self.report("started"), fixture: f)
            #expect(reply["isError"]?.bool != true)
            let saved = try await f.repository.snapshot().runs[0]
            #expect(saved.stageReports?.count == 1)
            #expect(reply["result"]?["details"] == StallariReadback.progress(saved.stageProgress))
            await f.adapter.cancel(run.id); _ = await task.result; try await f.cleanup()
        } catch { await f.adapter.cancel(run.id); _ = await task.result; try await f.cleanup(); throw error }
    }

    @Test func malformedForeignAndUnknownEvidenceAreToolErrorsWithoutStoppingRun() async throws {
        let f = try await HirdFixture.make(preserve: true)
        var run = f.run; run.stagePlan = Self.plan
        try await HirdStageRuntimeTests.prepare(run, fixture: f)
        let task = Task { [run] in try await f.adapter.start(run, emit: f.sink) }
        do {
            try await HirdVerificationRetryTests.awaitPrompts(1, f)
            let invalid: [OMPJSON] = [
                .null,
                .object(["action": .string("unknown")]),
                .object(["action": .string("started"), "stageID": .string("stage-1"), "runID": .string("another-run")]),
                .object(["action": .string("started"), "stageID": .string("stage-1"), "issueID": .string("another-issue")]),
                .object(["action": .string("completed"), "stageID": .string("stage-1"), "verified": .bool(true)]),
                Self.report("started", stageID: "missing"),
                .object(["action": .string("completed"), "stageID": .string("stage-1"), "verificationIDs": .array([.string("inspection:other-run:read")])]),
                .object(["action": .string("replanned"), "plan": .array([]), "reason": .string("empty")])
            ]
            for arguments in invalid {
                let reply = try await Self.call(arguments, fixture: f)
                #expect(reply["isError"]?.bool == true)
            }
            #expect(try await f.repository.snapshot().runs[0].stageReports?.isEmpty != false)
            let reply = try await Self.call(Self.report("started"), fixture: f, id: "deduplicated")
            #expect(reply["isError"]?.bool != true)
            #expect(try await Self.call(Self.report("started"), fixture: f, id: "deduplicated") == reply)
            #expect(try await f.repository.snapshot().runs[0].stageReports?.count == 1)
            #expect(try await f.repository.snapshot().runs[0].state == .working)
            await f.adapter.cancel(run.id); _ = await task.result; try await f.cleanup()
        } catch { await f.adapter.cancel(run.id); _ = await task.result; try await f.cleanup(); throw error }
    }

    @Test func readEvidenceIsSavedBeforeReportAndReplanKeepsFrozenPlan() async throws {
        let f = try await HirdFixture.make(preserve: true)
        var run = f.run; run.stagePlan = Self.plan
        try await HirdStageRuntimeTests.prepare(run, fixture: f)
        let task = Task { [run] in try await f.adapter.start(run, emit: f.sink) }
        do {
            try await HirdVerificationRetryTests.awaitPrompts(1, f)
            _ = try await Self.call(Self.report("started"), fixture: f)
            await f.rpc.frame(.object(["type": .string("tool_execution_start"), "toolCallId": .string("source-read"),
                "toolName": .string("read"), "args": .object(["path": .string("original.txt")])]))
            await f.rpc.frame(.object(["type": .string("tool_execution_end"), "toolCallId": .string("source-read"),
                "toolName": .string("read"), "isError": .bool(false), "result": .object([
                    "content": .array([.object(["type": .string("text"), "text": .string("original")])])])]))
            let evidenceID = "inspection:" + run.id.rawValue + ":source-read"
            let completed = try await Self.call(.object(["action": .string("completed"), "stageID": .string("stage-1"),
                "note": .string("원문을 확인했어요"), "verificationIDs": .array([.string(evidenceID)])]), fixture: f)
            #expect(completed["isError"]?.bool != true)
            var saved = try await f.repository.snapshot().runs[0]
            #expect(saved.result?.verifications.contains { $0.id == evidenceID && $0.isInspection } == true)
            #expect(saved.stageReports?.last?.verified == true)
            #expect(saved.lastFileChangeAt == nil)
            #expect(saved.stageReports?.last?.note == "원문을 확인했어요")
            let revised = [IssueStage(id: "stage-1", title: "원문 확인 완료", evidence: "읽은 원문", criterion: 1),
                           IssueStage(id: "stage-2", title: "정리", evidence: "최종 보고")]
            let plan = try JSONDecoder().decode(OMPJSON.self, from: JSONEncoder().encode(revised))
            let replanned = try await Self.call(.object(["action": .string("replanned"), "plan": plan,
                "reason": .string("읽은 내용에 맞춰 정리를 분리했어요")]), fixture: f)
            #expect(replanned["isError"]?.bool != true)
            saved = try await f.repository.snapshot().runs[0]
            #expect(saved.stagePlan == Self.plan)
            #expect(saved.stageReports?.last?.plan == revised)
            #expect(replanned["result"]?["details"] == StallariReadback.progress(saved.stageProgress))
            await f.adapter.cancel(run.id); _ = await task.result; try await f.cleanup()
        } catch { await f.adapter.cancel(run.id); _ = await task.result; try await f.cleanup(); throw error }
    }

    @Test(arguments: ["failed-edit", "failed-noop", "noop", "edited", "bash"])
    func actualFileChangesConfirmRegardlessOfToolExitButNoOpsDoNot(outcome: String) async throws {
        let f = try await HirdFixture.make(preserve: true)
        var run = f.run; run.stagePlan = Self.plan
        try await HirdStageRuntimeTests.prepare(run, fixture: f)
        let task = Task { [run] in try await f.adapter.start(run, emit: f.sink) }
        do {
            try await HirdVerificationRetryTests.awaitPrompts(1, f)
            _ = try await Self.call(Self.report("started"), fixture: f)
            let tool = outcome == "bash" ? "bash" : "edit"
            await f.rpc.frame(.object(["type": .string("tool_execution_start"), "toolCallId": .string("mutation"),
                "toolName": .string(tool), "args": .object(["command": .string("printf changed > original.txt"), "path": .string("original.txt")])]))
            // A rejected host call is a stream barrier, not a stored stage report.
            _ = try await Self.call(.object(["action": .string("invalid")]), fixture: f)
            #expect(try await f.repository.snapshot().runs[0].lastFileChangeAt == nil)
            if !["noop", "failed-noop"].contains(outcome) {
                let workspace = try #require(try await f.repository.snapshot().runs[0].workspace)
                try "changed\n".write(to: URL(fileURLWithPath: workspace.worktreePath).appendingPathComponent("original.txt"), atomically: true, encoding: .utf8)
            }
            await f.rpc.frame(.object(["type": .string("tool_execution_end"), "toolCallId": .string("mutation"),
                "toolName": .string(tool), "isError": .bool(outcome.hasPrefix("failed")),
                "result": .object(["details": .object(["exitCode": .number(outcome.hasPrefix("failed") ? 1 : 0)]),
                    "content": .array([.object(["type": .string("text"), "text": .string(outcome)])])])]))
            if outcome == "failed-edit" {
                // A later no-op does not erase the actual partial edit left by the failed tool.
                await f.rpc.frame(.object(["type": .string("tool_execution_start"), "toolCallId": .string("noop-after-failure"),
                    "toolName": .string("edit"), "args": .object(["path": .string("original.txt")])]))
                await f.rpc.frame(.object(["type": .string("tool_execution_end"), "toolCallId": .string("noop-after-failure"),
                    "toolName": .string("edit"), "isError": .bool(false), "result": .object([:])]))
            }
            let completed = try await Self.call(Self.report("completed"), fixture: f)
            #expect(completed["isError"]?.bool != true)
            let saved = try await f.repository.snapshot().runs[0]
            let changed = ["failed-edit", "edited", "bash"].contains(outcome)
            #expect((saved.lastFileChangeAt != nil) == changed)
            #expect(saved.stageReports?.last?.verified == changed)
            await f.adapter.cancel(run.id); _ = await task.result; try await f.cleanup()
        } catch { await f.adapter.cancel(run.id); _ = await task.result; try await f.cleanup(); throw error }
    }

    @Test func lateParallelToolCompletionsCannotReuseAnEarlierReportedFileChange() async throws {
        let f = try await HirdFixture.make(preserve: true)
        var run = f.run; run.stagePlan = Self.plan
        try await Self.prepare(run, fixture: f)
        let task = Task { [run] in try await f.adapter.start(run, emit: f.sink) }
        do {
            try await HirdVerificationRetryTests.awaitPrompts(1, f)
            _ = try await Self.call(Self.report("started"), fixture: f)
            for id in ["first", "second"] {
                await f.rpc.frame(.object(["type": .string("tool_execution_start"), "toolCallId": .string(id),
                    "toolName": .string("edit"), "args": .object(["path": .string("original.txt")])]))
            }
            _ = try await Self.call(.object(["action": .string("invalid")]), fixture: f)
            let workspace = try #require(try await f.repository.snapshot().runs[0].workspace)
            try "changed\n".write(to: URL(fileURLWithPath: workspace.worktreePath)
                .appendingPathComponent("original.txt"), atomically: true, encoding: .utf8)
            _ = try await Self.call(Self.report("completed"), fixture: f)
            #expect(try await f.repository.snapshot().runs[0].stageReports?.last?.verified == true)
            _ = try await Self.call(Self.report("started"), fixture: f)
            for id in ["first", "second"] {
                await f.rpc.frame(.object(["type": .string("tool_execution_end"), "toolCallId": .string(id),
                    "toolName": .string("edit"), "isError": .bool(false), "result": .object([:])]))
            }
            _ = try await Self.call(Self.report("completed"), fixture: f)
            #expect(try await f.repository.snapshot().runs[0].stageReports?.map(\.verified) == [nil, true, nil, false])
            await f.adapter.cancel(run.id); _ = await task.result; try await f.cleanup()
        } catch { await f.adapter.cancel(run.id); _ = await task.result; try await f.cleanup(); throw error }
    }

    @Test func captureFailureKeepsVerificationPathsAvailableToStageReport() async throws {
        let f = try await HirdFixture.make(preserve: true)
        var run = f.run; run.stagePlan = Self.plan
        try await HirdStageRuntimeTests.prepare(run, fixture: f)
        let task = Task { [run] in try await f.adapter.start(run, emit: f.sink) }
        do {
            try await HirdVerificationRetryTests.awaitPrompts(1, f)
            _ = try await Self.call(Self.report("started"), fixture: f)
            let workspace = try #require(try await f.repository.snapshot().runs[0].workspace)
            let marker = URL(fileURLWithPath: workspace.worktreePath).appendingPathComponent(".git")
            let original = try Data(contentsOf: marker)
            defer { try? original.write(to: marker) }
            try Data("gitdir: /nonexistent-knarr-stage-fixture\n".utf8).write(to: marker)
            await f.rpc.frame(HirdResultTests.start("capture-failed-check"))
            await f.rpc.frame(HirdResultTests.end(0, call: "capture-failed-check"))
            let evidenceID = "verification:" + run.id.rawValue + ":capture-failed-check"
            let completed = try await Self.call(.object(["action": .string("completed"), "stageID": .string("stage-1"),
                "verificationIDs": .array([.string(evidenceID)])]), fixture: f)
            #expect(completed["isError"]?.bool != true)
            let saved = try await f.repository.snapshot().runs[0]
            let record = try #require(saved.result?.verifications.first { $0.id == evidenceID })
            #expect(FileManager.default.fileExists(atPath: record.logPath))
            #expect(try String(contentsOfFile: record.logPath, encoding: .utf8).contains("OK"))
            #expect(saved.stageReports?.last?.verified == true)
            #expect(saved.lastFileChangeAt == nil)
            try original.write(to: marker)
            await f.adapter.cancel(run.id); _ = await task.result; try await f.cleanup()
        } catch { await f.adapter.cancel(run.id); _ = await task.result; try await f.cleanup(); throw error }
    }

    @Test func noPlanRetainsLegacyProgressAndRejectsInventedStage() async throws {
        let f = try await HirdFixture.make()
        let task = Task { try await f.adapter.start(f.run, emit: f.sink) }
        do {
            try await HirdVerificationRetryTests.awaitPrompts(1, f)
            let reply = try await Self.call(Self.report("started"), fixture: f)
            #expect(reply["isError"]?.bool == true)
            let saved = try await f.repository.snapshot().runs[0]
            #expect(saved.stageProgress.plannedStages.isEmpty)
            #expect(saved.stageReports?.isEmpty != false)
            #expect(saved.state == .working)
            await f.adapter.cancel(f.run.id); _ = await task.result; try await f.cleanup()
        } catch { await f.adapter.cancel(f.run.id); _ = await task.result; try await f.cleanup(); throw error }
    }
}
