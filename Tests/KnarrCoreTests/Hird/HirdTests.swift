import Foundation
import Darwin
import Testing
@testable import KnarrCore

@Suite(.serialized) struct HirdTests {
    static func phases(_ rows: [(String, String, String?)]) -> OMPJSON {
        .array([.object(["name": .string("work"), "tasks": .array(rows.map { content, status, blocker in
            var row: [String: OMPJSON] = ["content": .string(content), "status": .string(status)]
            if let blocker { row["blocker"] = .string(blocker) }
            return .object(row)
        })])])
    }
    @Test func allTodoStatesAndReorderNeverMergeDifferentTasks() {
        let rows: [(String, String, String?)] = [("a", "pending", nil), ("b", "in_progress", nil),
            ("c", "completed", nil), ("d", "abandoned", nil), ("e", "blocked", "로그인이 필요해요")]
        let steps = HirdTodoMapper.steps(Self.phases(rows))
        #expect(steps.map(\.state) == [.pending, .active, .done, .pending, .blocked])
        #expect(steps.last?.title.contains("로그인이 필요해요") == true)
        let reordered = HirdTodoMapper.steps(Self.phases([rows[4], rows[0], rows[3]]))
        #expect(reordered.map(\.state) == [.blocked, .pending, .pending])
        #expect(reordered.first?.title.contains("e") == true)
        #expect(reordered.last?.title.contains("d") == true)
    }
}

actor ScriptedHirdRPC: HirdRPC {
    let pair = AsyncStream<OMPEvent>.makeStream()
    var started = 0
    var sends: [[String: OMPJSON]] = []
    var sendCommands: [String] = []
    var shutdownCancellations: [Bool] = []
    var requests: [(String, [String: OMPJSON])] = []
    var state: OMPJSON = .object(["isStreaming": .bool(true), "isSettled": .bool(true), "sessionId": .string("fake-omp"), "model": .object(["provider": .string("ollama"), "id": .string("gemma4:12b")]), "thinkingLevel": .string("off"), "todoPhases": .array([])])
    var arguments: [String] = []
    var overlay = ""
    private var holdNextPrompt = false
    private var heldPrompt: CheckedContinuation<Void, Never>?
    func holdPromptAdmission() { holdNextPrompt = true }
    func start(_ configuration: OMPLaunchConfiguration) throws {
        started += 1; arguments = configuration.arguments
        if let index = arguments.firstIndex(of: "--config") { overlay = try String(contentsOfFile: arguments[index + 1], encoding: .utf8) }
        if let index = arguments.firstIndex(of: "--tools"), case .object(var object) = state {
            object["dumpTools"] = .array(arguments[index + 1].split(separator: ",").map { .object(["name": .string(String($0))]) })
            state = .object(object)
        }
    }
    func subscribe() -> AsyncStream<OMPEvent> { pair.stream }
    func request(_ command: String, fields: [String: OMPJSON], timeout: Duration) async -> OMPJSON {
        requests.append((command, fields))
        if command == "set_model", case .object(var object) = state {
            object["model"] = .object(["provider": fields["provider"] ?? .null, "id": fields["modelId"] ?? .null]); state = .object(object)
        }
        if command == "set_thinking_level", case .object(var object) = state {
            object["thinkingLevel"] = fields["level"]; state = .object(object)
        }
        if command == "prompt" {
            if holdNextPrompt {
                holdNextPrompt = false
                await withCheckedContinuation { heldPrompt = $0 }
            }
            return .object(["success": .bool(true), "id": .string("prompt-\(requests.filter { $0.0 == "prompt" }.count)")])
        }
        return .object(["success": .bool(true), "data": command == "get_state" ? state : .object([:])])
    }
    func send(_ command: String, fields: [String: OMPJSON]) { sendCommands.append(command); sends.append(fields) }
    func frame(_ frame: OMPJSON) { pair.continuation.yield(.frame(frame)) }
    func terminate(status: Int32 = 1) {
        pair.continuation.yield(.terminated(.init(status: status, reason: .failed, remainingProcessIDs: [])))
        pair.continuation.finish()
    }
    func setTodos(_ todos: OMPJSON) {
        if case .object(var object) = state { object["todoPhases"] = todos; state = .object(object) }
    }
    func setSettled(_ settled: Bool) {
        if case .object(var object) = state { object["isSettled"] = .bool(settled); state = .object(object) }
    }
    func shutdown(cancel: Bool) -> OMPProcessExit {
        shutdownCancellations.append(cancel)
        heldPrompt?.resume(); heldPrompt = nil
        pair.continuation.finish()
        return .init(status: 0, reason: cancel ? .cancelled : .normal, remainingProcessIDs: [])
    }
}

struct HirdFixture {
    let directory: URL
    let repository: SQLiteKnarrRepository
    let adapter: OMPHirdAdapter
    let rpc: ScriptedHirdRPC
    let run: PersistedRun
    /// `activityInterval` defaults to zero so frame-order tests write each transition at once;
    /// rate-limit tests pass a positive interval and assert the coalesced writes.
    static func make(preserve: Bool = false, temporary: Bool = false, activityInterval: TimeInterval = 0) async throws -> Self {
        let base = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        // Resolve this checkout's pinned runtime before allocating a fixture.
        let executable = ProcessInfo.processInfo.environment["KNARR_OMP_EXECUTABLE"].map { URL(fileURLWithPath: $0) }
            ?? base.appendingPathComponent(".runtime/omp/\(OMPInstallation.version)/omp")
        let install = try OMPInstallation(executable: executable)
        let dir = temporary
            ? FileManager.default.temporaryDirectory.appendingPathComponent("knarr-hird-" + UUID().uuidString)
            : base.appendingPathComponent((ProcessInfo.processInfo.environment["KNARR_HIRD_EVIDENCE_ROOT"] ?? "outputs/issue-4") + "/" + (preserve ? "live/" : "fixtures/") + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for args in [["init", "-q"], ["config", "user.name", "Hird test"], ["config", "user.email", "hird@example.invalid"]] { try git(args, in: dir) }
        try "original\n".write(to: dir.appendingPathComponent("original.txt"), atomically: true, encoding: .utf8)
        try git(["add", "."], in: dir); try git(["commit", "-qm", "base"], in: dir)
        let repository = try await SQLiteKnarrRepository.open(at: dir.appendingPathComponent("knarr.db"))
        try await repository.saveProject(.init(id: "p", name: "fixture", absolutePath: dir.path))
        try await repository.saveIssue(.init(id: "t", title: "test", projectName: "fixture", state: .running, headline: "", detail: "", acceptance: [], hirds: [], events: [], startedAt: .now), projectID: "p")
        let run = PersistedRun(hird: .init(id: "r", name: "Hird", role: "change", status: .working, steps: [], currentCommand: nil, lastActivityAt: .now), issueID: "t", projectID: "p", ompSessionID: nil, ownershipToken: "owned", startedAt: .now)
        if !preserve { _ = try await repository.createRun(run) }
        let rpc = ScriptedHirdRPC()
        // The fake transport never launches this executable.
        return .init(directory: dir, repository: repository,
            adapter: OMPHirdAdapter(repository: repository, installation: install, resultRoot: dir.appendingPathComponent("results"), expectedModel: "ollama/gemma4:12b", makeRPC: { rpc }, activityInterval: activityInterval), rpc: rpc, run: run)
    }
    static func git(_ arguments: [String], in directory: URL) throws {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/git"); p.arguments = arguments; p.currentDirectoryURL = directory
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try p.run(); p.waitUntilExit(); #expect(p.terminationStatus == 0)
    }
    func sink(_ update: HirdUpdate) async throws -> MutationOutcome {
        try await repository.recordEvent(id: update.id, runID: update.runID, at: update.at, payload: update.payload)
    }
    func cleanup() async throws { await adapter.cancel(run.id); try await repository.close(); try FileManager.default.removeItem(at: directory) }
}

@Suite(.serialized) struct HirdLifecycleTests {
    @Test func cancelBeforeStartTombstoneNeverSpawns() async throws {
        let f = try await HirdFixture.make()
        do {
            await f.adapter.cancel(f.run.id)
            #expect(try await f.repository.snapshot().runs[0].state == .cancelled)
            try await f.adapter.start(f.run, emit: f.sink)
            #expect(await f.rpc.started == 0)
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }
    @Test func toolActivityTodoAndQuestionDeliveryStayOnOriginalRun() async throws {
        let f = try await HirdFixture.make()
        let task = Task { try await f.adapter.start(f.run, emit: f.sink) }
        do {
            for _ in 0..<500 { if await f.rpc.started > 0 { break }; try await Task.sleep(for: .milliseconds(10)) }
            #expect(await f.rpc.started == 1)
            await f.rpc.frame(.object(["type": .string("tool_execution_start"), "toolCallId": .string("cmd"), "toolName": .string("bash"), "args": .object(["command": .string("python3 -m unittest")])]))
            await f.rpc.setTodos(HirdTests.phases([("login", "blocked", "로그인이 필요해요"), ("skip", "abandoned", nil)]))
            await f.rpc.frame(.object(["type": .string("tool_execution_end"), "toolCallId": .string("cmd"), "toolName": .string("bash"), "result": .object(["details": .object(["exitCode": .number(0)]), "content": .array([.object(["type": .string("text"), "text": .string("OK")])])])]))
            await f.rpc.frame(.object(["type": .string("extension_ui_request"), "id": .string("q"), "method": .string("select"), "title": .string("choose"), "options": .array([.string("A"), .string("B")])]))
            var snapshot = try await f.repository.snapshot()
            for _ in 0..<500 {
                snapshot = try await f.repository.snapshot()
                if !snapshot.questions.isEmpty { break }; try await Task.sleep(for: .milliseconds(10))
            }
            #expect(snapshot.runs[0].state == .waitingOnHuman)
            #expect(snapshot.runs[0].hird.steps.map(\.state) == [.blocked, .pending])
            #expect(snapshot.issues[0].events.contains { $0.text.contains("python3 -m unittest") })
            let q = try #require(snapshot.questions.first)
            // The receiver continues accepting tool activity while the human is pending.
            await f.rpc.frame(.object(["type": .string("tool_execution_start"), "toolCallId": .string("during-question"), "toolName": .string("read"), "args": .object([:])]))
            for _ in 0..<500 {
                if try await f.repository.snapshot().runs[0].hird.currentCommand == "read" { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(try await f.repository.snapshot().runs[0].hird.currentCommand == "read")
            let wrong = QuestionResolution(questionID: q.id, runID: "other-run", issueID: f.run.issueID, answer: .init(selectedOptions: ["B"], text: nil), cancelled: false)
            await #expect(throws: (any Error).self) { try await f.adapter.deliver(wrong) }
            let answer = QuestionAnswer(selectedOptions: ["B"], text: nil)
            _ = try await f.repository.answerQuestion(q.id, runID: f.run.id, answer: answer, at: .now)
            let resolution = QuestionResolution(questionID: q.id, runID: f.run.id, issueID: f.run.issueID, answer: answer, cancelled: false)
            // A recorded answer releases human wait; unfinished todo remains the worker's responsibility.
            #expect(try await f.repository.snapshot().runs[0].state == .working)
            try await f.adapter.deliver(resolution); try await f.adapter.deliver(resolution)
            #expect(await f.rpc.sends.count == 1)
            await f.rpc.frame(.object(["type": .string("extension_ui_request"), "id": .string("q2"), "method": .string("input"), "title": .string("second question")]))
            for _ in 0..<500 { if try await f.repository.snapshot().questions.count == 2 { break }; try await Task.sleep(for: .milliseconds(10)) }
            let second = try #require(try await f.repository.snapshot().questions.last)
            _ = try await f.repository.cancelQuestion(second.id, runID: f.run.id, at: .now)
            try await f.adapter.deliver(.init(questionID: second.id, runID: f.run.id, issueID: f.run.issueID, answer: nil, cancelled: true))
            #expect(await f.rpc.sends.last?["cancelled"]?.bool == true)
            await f.adapter.cancel(f.run.id)
            await #expect(throws: (any Error).self) { try await f.adapter.deliver(resolution) }
            _ = await task.result
            #expect(try await f.repository.snapshot().runs[0].workspace != nil)
            try await f.cleanup()
        } catch { await f.adapter.cancel(f.run.id); _ = await task.result; try await f.cleanup(); throw error }
    }
}

actor HirdSnapshotCollector {
    var snapshots: [PersistenceSnapshot] = []
    func add(_ update: PersistenceUpdate) { snapshots.append(update.snapshot) }
}
@Suite(.serialized) struct HirdRepositoryTests {
    @Test func subscriptionReflectsBlockedAndTerminalArchivesWithoutRevivingCancelledRun() async throws {
        let f = try await HirdFixture.make()
        let stream = try await f.repository.subscribe(), collector = HirdSnapshotCollector()
        let observer = Task { for await snapshot in stream { await collector.add(snapshot) } }
        do {
            let steps = HirdTodoMapper.steps(HirdTests.phases([("login", "blocked", "계정 확인"), ("drop", "abandoned", nil)]))
            _ = try await f.sink(.init(id: "steps", runID: f.run.id, at: .now, payload: .activity(.init(at: .now, actor: "Hird", text: "todo"), currentCommand: "test", steps: steps)))
            // A blocked todo without an actual pending question must keep the worker active.
            #expect(try await f.repository.snapshot().runs[0].state == .working)
            for _ in 0..<100 { if await collector.snapshots.count > 1 { break }; try await Task.sleep(for: .milliseconds(5)) }
            #expect(await collector.snapshots.last?.runs.first?.hird.steps == steps)
            _ = try await f.repository.cancelRun(f.run.id, at: .now, reason: "cancel")
            let result = RunResult(worktreePath: f.directory.path, branch: "preserved", commit: nil, diffPath: f.directory.appendingPathComponent("diff.patch").path, summary: "cancelled result", verifications: [])
            _ = try await f.sink(.init(id: "archive", runID: f.run.id, at: .now, payload: .saveResult(result)))
            _ = try await f.sink(.init(id: "late-complete", runID: f.run.id, at: .now, payload: .complete(result, notificationID: "late")))
            let saved = try await f.repository.snapshot().runs[0]
            #expect(saved.result == result)
            #expect(saved.state == .cancelled)
            observer.cancel(); await observer.value; try await f.cleanup()
        } catch { observer.cancel(); await observer.value; try await f.cleanup(); throw error }
    }
}

@Suite(.serialized) struct HirdSafetyTests {
    @Test func cancelledSessionBeforeLaunchNeverCreatesProcess() async throws {
        // /usr/bin/true exits immediately, including the RED path; it cannot leak a session.
        let session = OMPRPCSession()
        _ = await session.shutdown(cancel: true)
        await #expect(throws: OMPRPCError.self) { try await session.start(.init(executable: URL(fileURLWithPath: "/usr/bin/true"), workingDirectory: URL(fileURLWithPath: "/tmp"))) }
        #expect(await session.processID == nil)
        _ = await session.shutdown(cancel: true)
    }
}

@Suite(.serialized) struct HirdResultTests {
    static func end(_ code: Int, call: String) -> OMPJSON {
        .object(["type": .string("tool_execution_end"), "toolCallId": .string(call), "toolName": .string("bash"),
            "isError": .bool(code != 0), "result": .object(["details": .object(["exitCode": .number(Double(code))]),
            "content": .array([.object(["type": .string("text"), "text": .string(code == 0 ? "OK" : "FAILED")])])])])
    }
    static func start(_ call: String) -> OMPJSON {
        .object(["type": .string("tool_execution_start"), "toolCallId": .string(call), "toolName": .string("bash"),
            "args": .object(["command": .string("python3 -m unittest -v")])])
    }
    @Test func failedCheckThenSuccessfulCheckRetainsBothAndCanFinish() async throws {
        let f = try await HirdFixture.make()
        let task = Task { try await f.adapter.start(f.run, emit: f.sink) }
        do {
            var workspace: RunWorkspace?
            for _ in 0..<500 {
                workspace = try await f.repository.snapshot().runs[0].workspace
                if await f.rpc.started > 0 { break }; try await Task.sleep(for: .milliseconds(10))
            }
            let tree = URL(fileURLWithPath: try #require(workspace).worktreePath)
            try "changed\n".write(to: tree.appendingPathComponent("original.txt"), atomically: true, encoding: .utf8)
            await f.rpc.frame(Self.start("failed")); await f.rpc.frame(Self.end(1, call: "failed"))
            await f.rpc.frame(Self.start("passed")); await f.rpc.frame(Self.end(0, call: "passed"))
            await f.rpc.frame(.object(["type": .string("prompt_result"), "status": .string("completed"), "sessionSettled": .bool(true)]))
            _ = await task.result
            let saved = try await f.repository.snapshot().runs[0]
            #expect(saved.state == .succeeded)
            #expect(saved.result?.verifications.map(\.exitCode) == [1, 0])
            #expect(saved.resultHistory.count >= 2)
            try await f.cleanup()
        } catch { await f.adapter.cancel(f.run.id); _ = await task.result; try await f.cleanup(); throw error }
    }
}

@Suite(.serialized) struct HirdSpawnSignalTests {
    @Test func ownedExecutorsDoNotInheritCallingThreadsBlockedChildSignal() async throws {
        var blocked = sigset_t(), original = sigset_t()
        sigemptyset(&blocked); sigaddset(&blocked, SIGCHLD)
        #expect(pthread_sigmask(SIG_BLOCK, &blocked, &original) == 0)
        let process: OwnedOMPProcess
        do {
            process = try OwnedOMPProcess(.init(executable: URL(fileURLWithPath: "/usr/bin/python3"), workingDirectory: URL(fileURLWithPath: "/tmp"),
                arguments: ["-c", "import signal;print(signal.SIGCHLD in signal.pthread_sigmask(signal.SIG_BLOCK, []))"]))
        } catch { pthread_sigmask(SIG_SETMASK, &original, nil); throw error }
        // Restore the exact test thread before suspension or any assertion.
        pthread_sigmask(SIG_SETMASK, &original, nil)
        process.closeInput()
        var output = Data()
        for await event in process.output {
            switch event {
            case .bytes(let bytes): output.append(bytes)
            case .exit(let code, let remaining): #expect(code == 0); #expect(remaining.isEmpty)
            case .failure: Testing.Issue.record("owned signal probe failed")
            }
        }
        #expect(String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == "False")
    }
}

@Suite(.serialized) struct HirdEdgeTests {
    @Test func abandonedVerifiedPlanDoesNotBecomeCompletedAndParallelToolKeepsCurrentCommand() async throws {
        let f = try await HirdFixture.make()
        let task = Task { try await f.adapter.start(f.run, emit: f.sink) }
        do {
            var workspace: RunWorkspace?
            for _ in 0..<500 {
                workspace = try await f.repository.snapshot().runs[0].workspace
                if await f.rpc.started > 0 { break }; try await Task.sleep(for: .milliseconds(10))
            }
            let file = URL(fileURLWithPath: try #require(workspace).worktreePath).appendingPathComponent("original.txt")
            try "changed\n".write(to: file, atomically: true, encoding: .utf8)
            await f.rpc.frame(HirdResultTests.start("a"))
            await f.rpc.frame(.object(["type": .string("tool_execution_start"), "toolCallId": .string("b"), "toolName": .string("read"), "args": .object(["command": .string("second actual command")])]))
            await f.rpc.frame(HirdResultTests.end(0, call: "a"))
            await f.rpc.frame(.object(["type": .string("extension_ui_request"), "id": .string("barrier"), "method": .string("input"), "title": .string("barrier")]))
            for _ in 0..<500 { if try await f.repository.snapshot().questions.count > 0 { break }; try await Task.sleep(for: .milliseconds(10)) }
            #expect(try await f.repository.snapshot().runs[0].hird.currentCommand == "second actual command")
            let q = try #require(try await f.repository.snapshot().questions.first)
            _ = try await f.repository.answerQuestion(q.id, runID: f.run.id, answer: .init(selectedOptions: [], text: "continue"), at: .now)
            await f.rpc.setTodos(HirdTests.phases([("abandoned task", "abandoned", nil)]))
            await f.rpc.frame(.object(["type": .string("prompt_result"), "status": .string("completed"), "sessionSettled": .bool(true)]))
            try await Task.sleep(for: .milliseconds(250))
            let saved = try await f.repository.snapshot().runs[0]
            #expect(saved.state != .succeeded); #expect(saved.hird.progress.done == 0)
            await f.adapter.cancel(f.run.id); _ = await task.result
            try await f.cleanup()
        } catch { await f.adapter.cancel(f.run.id); _ = await task.result; try await f.cleanup(); throw error }
    }
    @Test func legacyStepDecodingPreservesPreviewContract() throws {
        let old = Data(#"{"title":"old","state":{"pending":{}}}"#.utf8)
        let step = try JSONDecoder().decode(HirdStep.self, from: old)
        #expect(step.title == "old"); #expect(step.sourceStatus == nil); #expect(step.blocker == nil)
    }
}

@Suite(.serialized) struct HirdNativeResultTests {
    @Test func pinnedForegroundSuccessOmitsExitCodeButBackgroundAndTimeoutNeverPass() async throws {
        // "failing": a finished check that exited 1 still hands the result to Stallari for judgement.
        for kind in ["completed", "failing", "background", "timeout"] {
            let f = try await HirdFixture.make()
            let task = Task { try await f.adapter.start(f.run, emit: f.sink) }
            do {
                var workspace: RunWorkspace?
                for _ in 0..<500 {
                    workspace = try await f.repository.snapshot().runs[0].workspace
                    if await f.rpc.started > 0 { break }; try await Task.sleep(for: .milliseconds(10))
                }
                let file = URL(fileURLWithPath: try #require(workspace).worktreePath).appendingPathComponent("original.txt")
                try "changed\n".write(to: file, atomically: true, encoding: .utf8)
                await f.rpc.frame(HirdResultTests.start("native"))
                var details: [String: OMPJSON] = ["timeoutSeconds": .number(300), "wallTimeMs": .number(1.5)]
                if kind == "background" { details["async"] = .object(["state": .string("running"), "jobId": .string("job")]) }
                if kind == "timeout" { details["timedOut"] = .bool(true) }
                if kind == "failing" { details["exitCode"] = .number(1) }
                await f.rpc.frame(.object(["type": .string("tool_execution_end"), "toolCallId": .string("native"), "toolName": .string("bash"),
                    "isError": .bool(kind == "timeout" || kind == "failing"), "result": .object(["details": .object(details), "content": .array([.object(["type": .string("text"), "text": .string("known test output")])])])]))
                await f.rpc.frame(.object(["type": .string("prompt_result"), "status": .string("completed"), "sessionSettled": .bool(true)]))
                if kind == "background" || kind == "timeout" {
                    try await HirdVerificationRetryTests.awaitPrompts(2, f)
                    await f.rpc.frame(HirdVerificationRetryTests.end(2))
                    try await HirdVerificationRetryTests.awaitPrompts(3, f)
                    await f.rpc.frame(HirdVerificationRetryTests.end(3))
                }
                _ = await task.result
                let saved = try await f.repository.snapshot().runs[0]
                let finished = kind == "completed" || kind == "failing"
                #expect(saved.state == (finished ? .succeeded : .failed))
                #expect(saved.result?.verifications.first?.exitCode == ["completed": 0, "failing": 1][kind])
                try await f.cleanup()
            } catch { await f.adapter.cancel(f.run.id); _ = await task.result; try await f.cleanup(); throw error }
        }
    }
}
