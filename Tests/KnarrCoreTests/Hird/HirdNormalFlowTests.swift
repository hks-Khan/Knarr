import Foundation
import Testing
@testable import KnarrCore

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["KNARR_HIRD_REAL_MODEL"] != nil))
struct HirdNormalFlowTests {
    @Test func normalCodingRunPreservesActualResultAndReflectsActivityAndTodo() async throws {
        let model = try #require(ProcessInfo.processInfo.environment["KNARR_HIRD_REAL_MODEL"])
        try #require(model.lowercased().contains("gpt") || model.lowercased().contains("claude"), "Current normal verification requires GPT or Claude")
        let executable = try #require(ProcessInfo.processInfo.environment["KNARR_OMP_EXECUTABLE"])
        let f = try await HirdFixture.make(preserve: true)
        let origin = "def add(a, b):\n    return a - b\n"
        try origin.write(to: f.directory.appendingPathComponent("calculator.py"), atomically: true, encoding: .utf8)
        try "import unittest\nfrom calculator import add\nclass SumTests(unittest.TestCase):\n    def test_sum(self):\n        self.assertEqual(add(2, 3), 5)\n".write(to: f.directory.appendingPathComponent("test_calculator.py"), atomically: true, encoding: .utf8)
        try "*.db\nresults/\n__pycache__/\n".write(to: f.directory.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        try HirdFixture.git(["add", "."], in: f.directory); try HirdFixture.git(["commit", "-qm", "normal calculator fixture"], in: f.directory)
        var environment = ProcessInfo.processInfo.environment
        environment["PI_CONFIG_DIR"] = String(repeating: "../", count: FileManager.default.homeDirectoryForCurrentUser.pathComponents.count - 1) + f.directory.path.dropFirst()
        let recorder = HirdModelRecordingRPC()
        let adapter = OMPHirdAdapter(repository: f.repository, installation: try OMPInstallation(executable: URL(fileURLWithPath: executable)), resultRoot: f.directory.appendingPathComponent("results"), expectedModel: model, environment: environment, makeRPC: { recorder })
        let manager = StallariSession(repository: f.repository, rpc: TestStallariRPC(), hird: adapter)
        let stream = try await f.repository.subscribe(), collector = HirdSnapshotCollector()
        let observer = Task { for await value in stream { await collector.add(value) } }
        let id: HirdRun.ID = "normal-hird"
        do {
            try await f.repository.saveIssueProposal(issueID: "t", proposal: .init(instruction: "Fix add in calculator.py to add the two numbers. Use todo to record the code fix and test. After your last edit, run python3 -m unittest -v with the built-in bash tool, inspect the result, and mark todo completed. Do not commit or add other files.", model: model), expectedVersion: nil)
            _ = try await f.repository.approveIssueProposal(issueID: "t", version: 1, at: .now)
            let returned = try await manager.dispatch(issueID: "t", runID: id)
            #expect(returned == id)
            let run = try await HirdRuntimeTests.waitForEnd(id, repository: f.repository, adapter: adapter)
            #expect(run.state == .succeeded)
            #expect(run.hird.lastActivityAt > run.startedAt)
            #expect(!run.hird.steps.isEmpty)
            #expect(run.hird.steps.allSatisfy { $0.state == .done && $0.sourceStatus == "completed" })
            let result = try #require(run.result), patch = URL(fileURLWithPath: try #require(result.diffPath))
            #expect(FileManager.default.fileExists(atPath: result.worktreePath))
            #expect(try !Data(contentsOf: patch).isEmpty)
            #expect(try String(contentsOf: f.directory.appendingPathComponent("calculator.py"), encoding: .utf8) == origin)
            #expect(result.verifications.contains { $0.command == ["python3 -m unittest -v"] && $0.exitCode == 0 })
            for check in result.verifications { #expect(try String(contentsOf: URL(fileURLWithPath: check.logPath), encoding: .utf8).contains("OK")) }
            let snapshots = await collector.snapshots
            #expect(snapshots.contains { $0.runs.contains { $0.id == id && $0.hird.currentCommand != nil } })
            #expect(snapshots.contains { $0.runs.contains { $0.id == id && !$0.hird.steps.isEmpty } })
            #expect(await adapter.exits[id]?.remainingProcessIDs.isEmpty == true)
            let output = f.directory.deletingLastPathComponent().deletingLastPathComponent()
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(run).write(to: output.appendingPathComponent("normal-hird-run.json"))
            let actual = try #require(await recorder.actualModel)
            #expect(actual["provider", default: ""] + "/" + actual["id", default: ""] == model)
            try JSONSerialization.data(withJSONObject: actual, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("actual-model.json"))
            print("Normal Hird actual get_state provider/model=\(actual["provider", default: ""])/\(actual["id", default: ""]) OMP=18.7.0 state=succeeded origin_unchanged=true store_activity_and_todo=true owned_remaining=0 result=\(output.path)/normal-hird-run.json")
            observer.cancel(); await observer.value
            _ = await manager.shutdown(); try await f.repository.close()
        } catch {
            await adapter.cancel(id); observer.cancel(); await observer.value
            _ = await manager.shutdown(); try await f.repository.close(); throw error
        }
    }
}

/// Records only public model identity from actual RPC replies, never raw frames.
actor HirdModelRecordingRPC: HirdRPC {
    private let rpc = OMPRPCSession()
    private(set) var actualModel: [String: String]?
    func start(_ configuration: OMPLaunchConfiguration) async throws { try await rpc.start(configuration) }
    func subscribe() async -> AsyncStream<OMPEvent> { await rpc.subscribe() }
    func request(_ command: String, fields: [String: OMPJSON], timeout: Duration) async throws -> OMPJSON {
        let reply = try await rpc.request(command, fields: fields, timeout: timeout)
        if command == "get_state", actualModel == nil, let model = reply["data"]?["model"],
           let provider = model["provider"]?.string, let id = model["id"]?.string {
            actualModel = ["provider": provider, "id": id, "source": "OMP get_state.model", "ompVersion": "18.7.0"]
        }
        return reply
    }
    func send(_ command: String, fields: [String: OMPJSON]) async throws { try await rpc.send(command, fields: fields) }
    func shutdown(cancel: Bool) async -> OMPProcessExit { await rpc.shutdown(cancel: cancel) }
}
