import Foundation
import Testing
@testable import KnarrCore

/// A local slash command invokes OMP's exported native AskTool: no model/provider request.
/// Extension UI is enabled only in this fixture to supply the shared RpcExtensionUIContext.
/// The separate production-launch test and one-shot model comparison cover --no-ui tool UI.
actor NativeQuestionRPC: HirdRPC {
    let rpc = OMPRPCSession()
    let results: URL
    init(results: URL) { self.results = results }
    func start(_ configuration: OMPLaunchConfiguration) async throws {
        var config = configuration
        config.arguments.removeAll { $0 == "--no-ui" }
        config.arguments += ["--model", "anthropic/claude-sonnet-4-5"]
        if let index = config.arguments.firstIndex(of: "--trusted-extension") {
            let policy = URL(fileURLWithPath: config.arguments[index + 1])
            let native = try String(contentsOf: policy, encoding: .utf8).replacingOccurrences(of: "export default function(pi)", with: "function deadline(pi)")
            try (native + "\n" + Self.probe).write(to: policy, atomically: true, encoding: .utf8)
        }
        config.environment["KNARR_PROBE_RESULTS"] = results.path
        try await rpc.start(config)
    }
    func subscribe() async -> AsyncStream<OMPEvent> { await rpc.subscribe() }
    func request(_ command: String, fields: [String: OMPJSON], timeout: Duration) async throws -> OMPJSON {
        if command == "prompt" {
            return try await rpc.request(command, fields: ["message": .string("/knarr-native-questions")], timeout: timeout)
        }
        return try await rpc.request(command, fields: fields, timeout: timeout)
    }
    func send(_ command: String, fields: [String: OMPJSON]) async throws { try await rpc.send(command, fields: fields) }
    func shutdown(cancel: Bool) async -> OMPProcessExit { await rpc.shutdown(cancel: cancel) }
    static let probe = """
    export default function(pi) {
      deadline(pi);
      pi.registerCommand("knarr-native-questions", {
        handler: async (_, ctx) => {
          const fs = await import("node:fs");
          const settings = pi.pi.Settings.isolated({ "ask.notify": "off", "ask.timeout": 0 });
          const tool = new pi.pi.AskTool({ cwd: ctx.cwd, hasUI: true, settings });
          let aborted = false;
          const context = { hasUI: true, ui: ctx.ui, abort: () => { aborted = true; } };
          const results = [];
          for (const id of ["selection", "free", "cancel", "stop"]) {
            try {
              results.push(await tool.execute(id, { questions: [{ id, question: id, options: [{label:"A"}, {label:"B"}] }] }, undefined, undefined, context));
            } catch (error) {
              results.push({ error: error.name, aborted });
              if (id !== "cancel") throw error;
            }
            fs.writeFileSync(process.env.KNARR_PROBE_RESULTS, JSON.stringify(results));
          }
        }
      });
    }
    """
}

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["KNARR_OMP_EXECUTABLE"] != nil))
struct HirdQuestionRuntimeTests {
    @Test func nativeAskSelectionEditorCancelDuplicateAndRunCancellation() async throws {
        let f = try await HirdFixture.make()
        try "# Fixture public rules\nNever read credentials.\n".write(to: f.directory.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)
        let skill = f.directory.appendingPathComponent(".omp/skills/hird-fixture/SKILL.md")
        try FileManager.default.createDirectory(at: skill.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "---\nname: hird-fixture\ndescription: Public fixture skill for runtime inventory.\n---\nUse the approved isolated workspace.\n".write(to: skill, atomically: true, encoding: .utf8)
        let unsafe = f.directory.appendingPathComponent(".omp/extensions/unsafe.ts")
        let unsafeMarker = f.directory.appendingPathComponent("unsafe-extension-loaded")
        try FileManager.default.createDirectory(at: unsafe.deletingLastPathComponent(), withIntermediateDirectories: true)
        let markerPath = String(decoding: try JSONEncoder().encode(unsafeMarker.path), as: UTF8.self)
        try "export default async function(pi) { const fs = await import('node:fs'); fs.writeFileSync(\(markerPath), 'violated'); }\n".write(to: unsafe, atomically: true, encoding: .utf8)
        try HirdFixture.git(["add", "AGENTS.md", ".omp"], in: f.directory)
        try HirdFixture.git(["commit", "-qm", "public runtime fixture"], in: f.directory)
        let results = f.directory.appendingPathComponent("native-answers.json"), rpc = NativeQuestionRPC(results: results)
        let env = ["HOME": f.directory.path, "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin",
                   "PI_CODING_AGENT_DIR": f.directory.appendingPathComponent("agent").path]
        let adapter = OMPHirdAdapter(repository: f.repository,
            installation: try OMPInstallation(executable: URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["KNARR_OMP_EXECUTABLE"]))),
            resultRoot: f.directory.appendingPathComponent("actual-questions"), expectedModel: "anthropic/claude-sonnet-4-5", environment: env, makeRPC: { rpc })
        let manager = StallariSession(repository: f.repository, rpc: TestStallariRPC(), hird: adapter)
        let task = Task { try await adapter.start(f.run, emit: f.sink) }
        do {
            let selection = try await pending(f.repository, count: 1)
            let answer = QuestionAnswer(selectedOptions: ["B"], text: nil)
            #expect(try await manager.answer(questionID: selection.id, runID: f.run.id, issueID: f.run.issueID, answer: answer) == .applied)
            #expect(try await manager.answer(questionID: selection.id, runID: f.run.id, issueID: f.run.issueID, answer: answer) == .duplicate)
            let free = try await pending(f.repository, count: 2)
            _ = try await manager.answer(questionID: free.id, runID: f.run.id, issueID: f.run.issueID,
                                         answer: .init(selectedOptions: ["Other (type your own)"], text: nil))
            let editor = try await pending(f.repository, count: 3)
            #expect(editor.options.isEmpty)
            _ = try await manager.answer(questionID: editor.id, runID: f.run.id, issueID: f.run.issueID,
                                         answer: .init(selectedOptions: [], text: "자유 입력 43"))
            let cancel = try await pending(f.repository, count: 4)
            _ = try await manager.cancelQuestion(questionID: cancel.id, runID: f.run.id, issueID: f.run.issueID)
            let stop = try await pending(f.repository, count: 5)
            let native = try JSONDecoder().decode(OMPJSON.self, from: Data(contentsOf: results))
            let answers = try #require(native.array)
            try #require(answers.count == 3)
            #expect(answers[0]["details"]?["selectedOptions"]?.array == [.string("B")])
            #expect(answers[1]["details"]?["customInput"]?.string == "자유 입력 43")
            #expect(answers[2]["error"]?.string == "ToolAbortError")
            #expect(answers[2]["aborted"]?.bool == true)
            await adapter.cancel(f.run.id); _ = await task.result
            let snapshot = try await f.repository.snapshot()
            #expect(snapshot.runs[0].state == .cancelled)
            #expect(snapshot.questions.first { $0.id == stop.id }?.state == .cancelled)
            #expect(await adapter.exits[f.run.id]?.remainingProcessIDs == [])
            #expect(snapshot.questions.filter { $0.state == .answered }.allSatisfy { $0.deliveredAt != nil })
            let resources = try #require(snapshot.runs[0].hird.runtimeResources)
            #expect(resources.extensionCommands.contains("autoresearch"))
            #expect(resources.contextFiles.contains { $0.hasSuffix("/AGENTS.md") })
            // User-home native config (OMP skills) never joins a Hird run, even though the
            // fixture skill exists; the repo's own context still does.
            #expect(!resources.skills.contains("hird-fixture"))
            #expect(!FileManager.default.fileExists(atPath: unsafeMarker.path))
            try await f.repository.close()
            let reopened = try await SQLiteKnarrRepository.open(at: f.directory.appendingPathComponent("knarr.db"))
            #expect(try await reopened.snapshot().runs[0].hird.runtimeResources == resources)
            #expect(try await reopened.snapshot().questions.allSatisfy { $0.state != .pending })
            try await reopened.close()
            _ = await manager.shutdown()
            try FileManager.default.removeItem(at: f.directory)
            print("OMP native AskTool -> durable Knarr questions -> same RPC: select=B editor=자유입력 cancel=true duplicate=once stop=cancelled reopened=true owned_remaining=0 provider_calls=0")
        } catch {
            await adapter.cancel(f.run.id); _ = await task.result
            _ = await manager.shutdown(); try? await f.cleanup(); throw error
        }
    }
    @MainActor @Test func restartWhileNativeAskIsWaitingRetainsOnlyOriginalQuestion() async throws {
        let f = try await HirdFixture.make()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let rpc = NativeQuestionRPC(results: f.directory.appendingPathComponent("native-answers.json"))
        let adapter = OMPHirdAdapter(repository: f.repository,
            installation: try OMPInstallation(executable: URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["KNARR_OMP_EXECUTABLE"]))),
            resultRoot: f.directory.appendingPathComponent("restart-questions"), expectedModel: "anthropic/claude-sonnet-4-5",
            environment: ["HOME": f.directory.path, "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin",
                          "PI_CODING_AGENT_DIR": f.directory.appendingPathComponent("agent").path], makeRPC: { rpc })
        let task = Task { try await adapter.start(f.run, emit: f.sink) }
        do {
            let question = try await pending(f.repository, count: 1)
            let saved = try await f.repository.snapshot()
            try await f.repository.close() // App disappeared before a shutdown/answer could be persisted.
            let exit = await rpc.shutdown(cancel: true)
            _ = await task.result
            #expect(exit.remainingProcessIDs == [])
            let reopened = try await SQLiteKnarrRepository.open(at: f.directory.appendingPathComponent("knarr.db"))
            let recovered = try await reopened.snapshot()
            #expect(recovered.runs[0].state == .interrupted)
            #expect(recovered.runs[0].ompSessionID == saved.runs[0].ompSessionID)
            #expect(recovered.questions == [question])
            #expect(try await reopened.answerQuestion(question.id, runID: f.run.id, answer: .init(selectedOptions: ["B"], text: nil), at: .now) == .ignoredTerminal)
            #expect(try await reopened.snapshot().questions[0].deliveredAt == nil)
            let appRPC = LiveTestRPC(), appHird = LiveTestHird()
            let appSession = StallariSession(repository: reopened, rpc: appRPC, hird: appHird)
            let suite = "knarr-restart-\(UUID())"
            let preferences = UserDefaults(suiteName: suite)!
            let app = LiveKnarrStore(repository: reopened, session: appSession, rpc: appRPC, hird: appHird, preferences: preferences)
            try await app.connect()
            #expect(app.questions.count == 1)
            #expect(app.questions[0].isPending == false)
            #expect(app.pendingQuestions(for: f.run.issueID).isEmpty)
            _ = await app.shutdown()
            preferences.removePersistentDomain(forName: suite)
            try await reopened.close()
            print("OMP waiting AskTool restart: original_pending=true old_run=interrupted late_answer=ignored provider_calls=0 owned_remaining=\(exit.remainingProcessIDs.count)")
        } catch {
            await adapter.cancel(f.run.id); _ = await task.result
            try? await f.repository.close(); throw error
        }
    }
    func pending(_ repository: SQLiteKnarrRepository, count: Int) async throws -> PersistedQuestion {
        for _ in 0..<1000 {
            let questions = try await repository.snapshot().questions
            if questions.count == count, let q = questions.first(where: { $0.state == .pending }) { return q }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw OMPRPCError.timedOut
    }
}
