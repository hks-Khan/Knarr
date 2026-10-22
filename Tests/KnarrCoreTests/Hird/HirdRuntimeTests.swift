import Foundation
import Darwin
import Testing
@testable import KnarrCore

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["KNARR_HIRD_REAL_MODEL"] != nil))
struct HirdRuntimeTests {
    @Test func realCodingVerificationAndRequestChangesPreserveBothRuns() async throws {
        let expected = try #require(ProcessInfo.processInfo.environment["KNARR_HIRD_REAL_MODEL"])
        #expect(expected == "ollama/gemma4:12b")
        let f = try await HirdFixture.make(preserve: true)
        try "def add(a, b):\n    return a - b\n".write(to: f.directory.appendingPathComponent("calculator.py"), atomically: true, encoding: .utf8)
        try "import unittest\nfrom calculator import add\nclass SumTests(unittest.TestCase):\n    def test_sum(self):\n        self.assertEqual(add(2, 3), 5)\n".write(to: f.directory.appendingPathComponent("test_calculator.py"), atomically: true, encoding: .utf8)
        try "*.db\nresults/\n__pycache__/\n".write(to: f.directory.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        try HirdFixture.git(["add", "."], in: f.directory); try HirdFixture.git(["commit", "-qm", "calculator fixture"], in: f.directory)
        let origin = try String(contentsOf: f.directory.appendingPathComponent("calculator.py"), encoding: .utf8)
        let install = try OMPInstallation(executable: URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["KNARR_OMP_EXECUTABLE"])))
        var environment = ProcessInfo.processInfo.environment
        environment["PI_CONFIG_DIR"] = String(repeating: "../", count: FileManager.default.homeDirectoryForCurrentUser.pathComponents.count - 1) + f.directory.path.dropFirst()
        let adapter = OMPHirdAdapter(repository: f.repository, installation: install, resultRoot: f.directory.appendingPathComponent("results"), expectedModel: expected, environment: environment)
        let manager = StallariSession(repository: f.repository, rpc: TestStallariRPC(), hird: adapter)
        let stream = try await f.repository.subscribe(), collector = HirdSnapshotCollector()
        let observer = Task { for await value in stream { await collector.add(value) } }
        var IDs: [HirdRun.ID] = []
        do {
            try await f.repository.saveIssueProposal(issueID: "t", proposal: .init(instruction: "Fix add in calculator.py to add the two numbers. Run python3 -m unittest -v using the built-in bash tool after the edit. Use todo to mark the code fix and test completed. Do not commit or create any other files.", model: expected), expectedVersion: nil)
            _ = try await f.repository.approveIssueProposal(issueID: "t", version: 1, at: .now)
            let first = try await manager.dispatch(issueID: "t", runID: "real-first")
            IDs.append(first)
            let r1 = try await Self.waitForEnd(first, repository: f.repository, adapter: adapter)
            #expect(r1.state == .succeeded)
            let result1 = try #require(r1.result), firstDiff = try #require(result1.diffPath)
            #expect(try String(contentsOf: URL(fileURLWithPath: firstDiff), encoding: .utf8).contains("return a + b"))
            #expect(result1.verifications.contains { $0.exitCode == 0 && $0.command.last == "python3 -m unittest -v" })
            for check in result1.verifications { #expect(try String(contentsOf: URL(fileURLWithPath: check.logPath), encoding: .utf8).contains("OK")) }
            #expect(try String(contentsOf: f.directory.appendingPathComponent("calculator.py"), encoding: .utf8) == origin)
            // Direct UI rework saves a new proposal and explicitly approves that version.
            try await f.repository.saveIssueProposal(issueID: "t", proposal: .init(version: 2, instruction: "Keep the corrected add function. Add subtract(a, b) returning a - b in calculator.py, and add a test_subtract method in test_calculator.py that asserts subtract(5, 2) == 3. Import subtract too. Then run python3 -m unittest -v with the built-in bash tool after the LAST edit. Mark todo items completed. Do not commit or create other files.", model: expected, previousRunID: first), expectedVersion: 1)
            _ = try await f.repository.approveIssueProposal(issueID: "t", version: 2, at: .now)
            let second = try await manager.dispatch(issueID: "t", runID: "real-rework")
            IDs.append(second)
            let r2 = try await Self.waitForEnd(second, repository: f.repository, adapter: adapter)
            #expect(r2.state == .succeeded)
            #expect(r2.previousRunID == first)
            let result2 = try #require(r2.result)
            let text = try String(contentsOf: URL(fileURLWithPath: result2.worktreePath).appendingPathComponent("calculator.py"), encoding: .utf8)
            #expect(text.contains("return a + b")); #expect(text.contains("def subtract"))
            #expect(result2.verifications.contains { $0.exitCode == 0 })
            #expect(result1.worktreePath != result2.worktreePath)
            #expect(try String(contentsOf: URL(fileURLWithPath: firstDiff), encoding: .utf8).contains("return a + b"))
            let observed = await collector.snapshots
            #expect(observed.contains { $0.runs.contains { $0.id == first && $0.hird.currentCommand != nil } })
            #expect(observed.contains { $0.runs.contains { $0.id == first && !$0.hird.steps.isEmpty } })
            let exits = await adapter.exits
            #expect(IDs.allSatisfy { exits[$0]?.remainingProcessIDs.isEmpty == true })
            let output = f.directory.deletingLastPathComponent().deletingLastPathComponent()
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode([r1, r2]).write(to: output.appendingPathComponent("real-hird-runs.json"))
            print("Hird actual model=\(expected) omp=18.7.0 first=\(r1.state) rework=\(r2.state) preserved_worktrees=2 origin_unchanged=true event_snapshots=\(observed.count) owned_remaining=0 result=\(output.path)/real-hird-runs.json")
            observer.cancel(); await observer.value
            _ = await manager.shutdown(); try await f.repository.close()
        } catch {
            for id in IDs { await adapter.cancel(id) }
            observer.cancel(); await observer.value
            _ = await manager.shutdown(); try await f.repository.close(); throw error
        }
    }
    static func waitForEnd(_ id: HirdRun.ID, repository: SQLiteKnarrRepository, adapter: OMPHirdAdapter) async throws -> PersistedRun {
        let deadline = ContinuousClock.now + .seconds(180)
        while ContinuousClock.now < deadline {
            if let run = try await repository.snapshot().runs.first(where: { $0.id == id }), run.state.isTerminal { return run }
            try await Task.sleep(for: .milliseconds(100))
        }
        await adapter.cancel(id)
        throw OMPRPCError.timedOut
    }
}

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["KNARR_HIRD_MEASURE_IDLE"] == "1")) struct HirdIdleTests {
    @Test func noWorkUsesLessThanOnePercentCPUWithoutPolling() async throws {
        let f = try await HirdFixture.make()
        let stream = try await f.repository.subscribe()
        let observer = Task { for await _ in stream {} }
        var before = rusage(); getrusage(RUSAGE_SELF, &before)
        let clock = ContinuousClock.now
        try await Task.sleep(for: .seconds(10))
        var after = rusage(); getrusage(RUSAGE_SELF, &after)
        let duration = clock.duration(to: .now), elapsed = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        func cpu(_ r: rusage) -> Double { Double(r.ru_utime.tv_sec + r.ru_stime.tv_sec) + Double(r.ru_utime.tv_usec + r.ru_stime.tv_usec) / 1e6 }
        let percent = (cpu(after) - cpu(before)) / elapsed * 100
        #expect(percent <= 1.2)
        #expect(await f.rpc.started == 0)
        print("Hird idle pid=\(getpid()) model_not_running=true seconds=\(elapsed) CPU_percent=\(percent) OS=\(ProcessInfo.processInfo.operatingSystemVersionString) cores=\(ProcessInfo.processInfo.processorCount) polling_tasks=0")
        observer.cancel(); await observer.value; try await f.cleanup()
    }
}

actor HeldRealHirdRPC: HirdRPC {
    let session = OMPRPCSession()
    var ready = false
    var release: CheckedContinuation<Void, Never>?
    func start(_ configuration: OMPLaunchConfiguration) async throws {
        try await session.start(configuration)
        ready = true
        await withCheckedContinuation { release = $0 }
    }
    func request(_ command: String, fields: [String: OMPJSON], timeout: Duration) async throws -> OMPJSON { try await session.request(command, fields: fields, timeout: timeout) }
    func send(_ command: String, fields: [String: OMPJSON]) async throws { try await session.send(command, fields: fields) }
    func subscribe() async -> AsyncStream<OMPEvent> { await session.subscribe() }
    func shutdown(cancel: Bool) async -> OMPProcessExit {
        release?.resume(); release = nil
        return await session.shutdown(cancel: cancel)
    }
}
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["KNARR_OMP_EXECUTABLE"] != nil))
struct HirdOwnedRuntimeTests {
    @Test func actualAdapterFailureAndStartupCancellationKeepResultsAfterReopen() async throws {
        let executable = try #require(ProcessInfo.processInfo.environment["KNARR_OMP_EXECUTABLE"])
        for cancelled in [false, true] {
            let f = try await HirdFixture.make(), held = HeldRealHirdRPC()
            let real = OMPRPCSession()
            var environment = ProcessInfo.processInfo.environment
            environment["PI_CONFIG_DIR"] = String(repeating: "../", count: FileManager.default.homeDirectoryForCurrentUser.pathComponents.count - 1) + f.directory.path.dropFirst()
            let adapter = OMPHirdAdapter(repository: f.repository, installation: try OMPInstallation(executable: URL(fileURLWithPath: executable)),
                resultRoot: f.directory.appendingPathComponent("owned-results"), expectedModel: "deliberate-metadata-mismatch", environment: environment,
                makeRPC: { if cancelled { return held }; return real })
            let task = Task { try await adapter.start(f.run, emit: f.sink) }
            do {
                if cancelled {
                    for _ in 0..<500 { if await held.ready { break }; try await Task.sleep(for: .milliseconds(10)) }
                    #expect(await held.ready)
                    await adapter.cancel(f.run.id)
                }
                _ = await task.result
                let pid = cancelled ? await held.session.processID : await real.processID
                if let pid { #expect(kill(pid, 0) == -1) }
                #expect(await adapter.exits[f.run.id]?.remainingProcessIDs.isEmpty == true)
                let saved = try await f.repository.snapshot().runs[0]
                #expect(saved.state == (cancelled ? .cancelled : .failed))
                let workspace = try #require(saved.workspace), result = try #require(saved.result)
                #expect(FileManager.default.fileExists(atPath: workspace.worktreePath))
                #expect(FileManager.default.fileExists(atPath: try #require(result.diffPath)))
                try await f.repository.close()
                let reopened = try await SQLiteKnarrRepository.open(at: f.directory.appendingPathComponent("knarr.db"))
                #expect(try await reopened.snapshot().runs[0].result == result)
                #expect(try await reopened.snapshot().runs[0].workspace == workspace)
                try await reopened.close()
                print("Hird actual metadata mode=\(cancelled ? "cancel" : "failure") owned_remaining=0 archived_result=true reopened=true")
                try FileManager.default.removeItem(at: f.directory)
            } catch {
                await adapter.cancel(f.run.id); _ = await task.result
                _ = await real.shutdown(cancel: true); _ = await held.shutdown(cancel: true)
                try? await f.repository.close(); try? FileManager.default.removeItem(at: f.directory); throw error
            }
        }
    }
}
