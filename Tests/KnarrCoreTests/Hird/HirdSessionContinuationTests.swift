import CryptoKit
import Foundation
import Testing
@testable import KnarrCore

private let continuationSessionID = "01a1340b-0000-7000-8000-000000000001"

private struct ContinuationFixture {
    enum Session: String, CaseIterable { case valid, missing, unreadable, wrongID, malformed, empty }
    let base: HirdFixture
    let run: PersistedRun
    let source: URL
    let original: Data
    let previousTree: URL

    static func make(session: Session = .valid, previousMode: HirdRunMode = .change,
                     mode: HirdRunMode = .change, model: String = "ollama/gemma4:12b", committed: Bool = false,
                     temporary: Bool = false) async throws -> Self {
        let f = try await HirdFixture.make(preserve: true, temporary: temporary)
        do {
            var previous = f.run; previous.mode = previousMode
            let branch: String? = committed ? "previous-attempt" : nil
            _ = try await f.repository.createRun(previous)
            let tree = f.directory.appendingPathComponent("previous-worktree")
            let sessions = f.directory.appendingPathComponent("previous/sessions")
            try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
            let source = sessions.appendingPathComponent("2026-10-13T00-00-00-000Z_\(continuationSessionID).jsonl")
            let records: [[String: Any]] = [
                ["type": "title", "v": 1, "title": "Prior attempt", "updatedAt": "2026-10-13T00:00:00.000Z", "pad": ""],
                ["type": "session", "version": 3, "id": continuationSessionID, "timestamp": "2026-10-13T00:00:00.000Z", "cwd": tree.path,
                 "additionalDirectories": [tree.appendingPathComponent("obsolete").path]],
                ["type": "message", "id": "user0001", "parentId": NSNull(), "timestamp": "2026-10-13T00:00:01.000Z",
                 "message": ["role": "user", "content": [["type": "text", "text": "previous-attempt-marker"]], "timestamp": 1791849601000]],
                ["type": "message", "id": "assist01", "parentId": "user0001", "timestamp": "2026-10-13T00:00:02.000Z",
                 "message": ["role": "assistant", "content": [["type": "text", "text": "previous-error-marker: tried the wrong path"]],
                             "api": "anthropic-messages", "provider": "anthropic", "model": "claude-sonnet-4-5",
                             "usage": ["input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0, "totalTokens": 0,
                                       "cost": ["input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0, "total": 0]],
                             "stopReason": "stop", "timestamp": 1791849602000]]
            ]
            var bytes = Data()
            for var record in records {
                if record["type"] as? String == "title" {
                    let size = try JSONSerialization.data(withJSONObject: record).count + 1
                    record["pad"] = String(repeating: " ", count: 256 - size)
                }
                bytes.append(try JSONSerialization.data(withJSONObject: record)); bytes.append(10)
            }
            if session == .malformed { bytes = Data("not a session\n".utf8) }
            if session == .empty { bytes = Data() }
            if session != .missing { try bytes.write(to: source) }
            if session == .unreadable { try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: source.path) }
            // A newer unrelated journal must not win over the run's bound ID.
            let unrelated = sessions.appendingPathComponent("2099-unrelated.jsonl")
            try "{\"type\":\"session\",\"version\":3,\"id\":\"unrelated\",\"cwd\":\"\(tree.path)\"}\n".write(to: unrelated, atomically: true, encoding: .utf8)
            _ = try await f.repository.recordEvent(id: "old-workspace", runID: previous.id, at: .now,
                payload: .recordWorkspace(.init(worktreePath: tree.path, branch: branch, ompSessionPath: sessions.path)))
            _ = try await f.repository.recordEvent(id: "old-session", runID: previous.id, at: .now,
                payload: .bindSession(session == .wrongID ? "missing-bound-id" : continuationSessionID))
            let report = f.directory.appendingPathComponent("previous/report.md")
            try "Prior report: parser rejected the old format; retain the fix.\n".write(to: report, atomically: true, encoding: .utf8)
            let patch = f.directory.appendingPathComponent("previous/changes.patch")
            try """
            diff --git a/original.txt b/original.txt
            --- a/original.txt
            +++ b/original.txt
            @@ -1 +1 @@
            -original
            +preserved attempt

            """.write(to: patch, atomically: true, encoding: .utf8)
            if committed {
                try HirdFixture.git(["switch", "-c", "previous-attempt"], in: f.directory)
                try "preserved attempt\n".write(to: f.directory.appendingPathComponent("original.txt"), atomically: true, encoding: .utf8)
                try "committed fix\n".write(to: f.directory.appendingPathComponent("committed-only.txt"), atomically: true, encoding: .utf8)
                try HirdFixture.git(["add", "original.txt", "committed-only.txt"], in: f.directory)
                try HirdFixture.git(["commit", "-qm", "previous committed fix"], in: f.directory)
                try "".write(to: patch, atomically: true, encoding: .utf8)
            }
            let checks: [VerificationRecord] = [
                .init(id: "old-check", command: ["swift test --filter Prior"], workingDirectory: tree.path,
                      startedAt: .now, finishedAt: .now, exitCode: 1, logPath: f.directory.appendingPathComponent("previous/test.log").path, summary: "parser failed"),
                .init(id: "unfinished", command: ["swift test --filter Interrupted"], workingDirectory: tree.path,
                      startedAt: .now, finishedAt: .now, exitCode: nil, logPath: f.directory.appendingPathComponent("previous/interrupted.log").path, summary: "cancelled")
            ]
            let commit = try await HirdWorkspace.git(["rev-parse", "HEAD"], at: f.directory)
            _ = try await f.repository.recordEvent(id: "old-result", runID: previous.id, at: .now,
                payload: .saveResult(.init(worktreePath: tree.path, branch: branch, commit: commit, diffPath: patch.path,
                                          summary: "Prior result summary", verifications: checks, reportPath: report.path)))
            _ = try await f.repository.recordEvent(id: "old-failure", runID: previous.id, at: .now, payload: .fail("prior-failure-reason"))
            var issue = try #require(try await f.repository.snapshot().issues.first)
            issue.hirds = []; issue.events = []
            issue.acceptance = [.init(text: "Preserve the parser fix", state: .met, evidence: "already-met-marker"),
                                .init(text: "Resume prior conversation", state: .unmet, evidence: "missing-history-marker [old-check]")]
            try await f.repository.saveIssue(issue, projectID: "p")
            let run = PersistedRun(hird: .init(id: "continuation", name: "Hird", role: "Current instruction marker", status: .working,
                steps: [], currentCommand: nil, lastActivityAt: .now), issueID: previous.issueID, projectID: previous.projectID,
                ompSessionID: nil, ownershipToken: "continuation-owned", startedAt: .now, previousRunID: previous.id,
                mode: mode, requestedModel: model, requestedThinking: "off")
            _ = try await f.repository.createRun(run)
            return .init(base: f, run: run, source: source, original: bytes, previousTree: tree)
        } catch { try await f.cleanup(); throw error }
    }

    func adapter(rpc: any HirdRPC, environment: [String: String] = [:]) throws -> OMPHirdAdapter {
        OMPHirdAdapter(repository: base.repository,
            installation: try OMPInstallation(executable: URL(fileURLWithPath: ProcessInfo.processInfo.environment["KNARR_OMP_EXECUTABLE"] ??
                URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".runtime/omp/\(OMPInstallation.version)/omp").path)),
            resultRoot: base.directory.appendingPathComponent("continuations"), expectedModel: "ollama/gemma4:12b",
            environment: environment, makeRPC: { rpc })
    }
}

@Suite(.serialized) struct HirdSessionContinuationTests {
    private func prompt(from rpc: ScriptedHirdRPC) async throws -> String {
        for _ in 0..<500 {
            if let text = await rpc.requests.first(where: { $0.0 == "prompt" })?.1["message"]?.string { return text }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw HirdError.noReport
    }

    @Test func copiesBoundSessionAndHandsOffAfterCriteriaReset() async throws {
        let f = try await ContinuationFixture.make(), rpc = ScriptedHirdRPC()
        let adapter = try f.adapter(rpc: rpc)
        let task = Task { try await adapter.start(f.run, emit: f.base.sink) }
        do {
            let text = try await prompt(from: rpc)
            let arguments = await rpc.arguments
            let resume = try #require(arguments.firstIndex(of: "--resume"))
            let copy = URL(fileURLWithPath: arguments[resume + 1])
            let directory = try #require(arguments.firstIndex(of: "--session-dir"))
            #expect(copy.deletingLastPathComponent().path == arguments[directory + 1])
            #expect(copy != f.source)
            let bytes = try Data(contentsOf: copy)
            let records = try bytes.split(separator: 10).map { try JSONSerialization.jsonObject(with: Data($0)) as! [String: Any] }
            let header = try #require(records.first { $0["type"] as? String == "session" })
            let saved = try #require(try await f.base.repository.snapshot().runs.first { $0.id == f.run.id })
            #expect(header["cwd"] as? String == saved.workspace?.worktreePath)
            #expect(header["additionalDirectories"] == nil)
            #expect(records.last?["id"] as? String == "assist01")
            #expect(SHA256.hash(data: try Data(contentsOf: f.source)) == SHA256.hash(data: f.original))
            #expect(text.contains(f.previousTree.path))
            #expect(text.contains(try #require(saved.workspace?.worktreePath)))
            #expect(text.contains("missing-history-marker [old-check]"))
            #expect(!text.contains("already-met-marker"))
            let evidenceRange = try #require(text.range(of: "missing-history-marker"))
            let instructionRange = try #require(text.range(of: "Current instruction marker"))
            #expect(evidenceRange.lowerBound < instructionRange.lowerBound)
            #expect(try await f.base.repository.snapshot().issues[0].acceptance.allSatisfy { $0.state == .pending && $0.evidence.isEmpty })
            // Writing to the fork must never change the prior journal.
            try Data("\n".utf8).appendToFile(copy)
            #expect(SHA256.hash(data: try Data(contentsOf: f.source)) == SHA256.hash(data: f.original))
            await adapter.cancel(f.run.id); _ = await task.result
            #expect(await adapter.exits[f.run.id]?.remainingProcessIDs == [])
            try await f.base.cleanup()
        } catch { await adapter.cancel(f.run.id); _ = await task.result; try await f.base.cleanup(); throw error }
    }

    @Test func numericToolPayloadSymlinkCannotEscapeTheSessionStore() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hird-session-symlink-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceJournal = root.appendingPathComponent("source/synthetic.jsonl")
        let destinationJournal = root.appendingPathComponent("destination/synthetic.jsonl")
        try FileManager.default.createDirectory(at: sourceJournal.deletingPathExtension(), withIntermediateDirectories: true)
        let outside = root.appendingPathComponent("outside.bin"), bytes = Data("outside the session store".utf8)
        try bytes.write(to: outside)
        try FileManager.default.createSymbolicLink(at: sourceJournal.deletingPathExtension().appendingPathComponent("7.bash.log"),
            withDestinationURL: outside)
        #expect(throws: HirdError.self) {
            try HirdWorkspace.copySessionArtifacts(sourceJournal: sourceJournal, destinationJournal: destinationJournal,
                policy: HirdCapturePolicy.bundled())
        }
        #expect(!FileManager.default.fileExists(atPath: destinationJournal.deletingPathExtension().appendingPathComponent("7.bash.log").path))
        #expect(try Data(contentsOf: outside) == bytes)
    }

    @Test func resumesNumericToolArtifactsWithoutCopyingChildJournals() async throws {
        let f = try await ContinuationFixture.make(temporary: true), rpc = ScriptedHirdRPC()
        let artifacts = f.source.deletingPathExtension()
        try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)
        let payload = Data("actual tool output; original exit code: 1".utf8)
        try payload.write(to: artifacts.appendingPathComponent("42.bash.log"))
        try Data("synthetic child journal: must remain only at source".utf8)
            .write(to: artifacts.appendingPathComponent("worker.jsonl"))
        try Data("not a numeric payload".utf8).write(to: artifacts.appendingPathComponent("worker.md"))
        let adapter = try f.adapter(rpc: rpc)
        let task = Task { try await adapter.start(f.run, emit: f.base.sink) }
        do {
            _ = try await prompt(from: rpc)
            let arguments = await rpc.arguments
            let resume = try #require(arguments.firstIndex(of: "--resume"))
            let destination = URL(fileURLWithPath: arguments[resume + 1]).deletingPathExtension()
            #expect(try Data(contentsOf: destination.appendingPathComponent("42.bash.log")) == payload)
            #expect(!FileManager.default.fileExists(atPath: destination.appendingPathComponent("worker.jsonl").path))
            #expect(!FileManager.default.fileExists(atPath: destination.appendingPathComponent("worker.md").path))
            await rpc.frame(.object(["type": .string("tool_execution_end"), "toolName": .string("write"), "toolCallId": .string("payload-checkpoint")]))
            for _ in 0..<500 {
                if try await f.base.repository.snapshot().runs.first(where: { $0.id == f.run.id })?.result != nil { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            var saved = try #require(try await f.base.repository.snapshot().runs.first { $0.id == f.run.id })
            let captured = try #require(saved.result)
            let manifest = try HirdWorkspace.loadManifest(for: captured)
            let firstPayload = try #require(manifest.artifacts.first { $0.sourcePath.hasSuffix("/42.bash.log") })
            #expect(firstPayload.captureKind == .observedPrefix)
            #expect(!manifest.artifacts.contains { $0.sourcePath.hasSuffix("/worker.jsonl") })
            #expect(try Data(contentsOf: artifacts.appendingPathComponent("42.bash.log")) == payload)
            let firstManifest = URL(fileURLWithPath: try #require(captured.artifactManifestPath))
            let firstFingerprint = try HirdWorkspace.fingerprint(firstManifest)
            let suffix = Data("\nfinal output still has no inferred exit code".utf8)
            let handle = try FileHandle(forWritingTo: destination.appendingPathComponent("42.bash.log"))
            _ = try handle.seekToEnd()
            try handle.write(contentsOf: suffix)
            try handle.close()
            await rpc.frame(.object(["type": .string("tool_execution_end"), "toolName": .string("write"), "toolCallId": .string("payload-upgrade")]))
            for _ in 0..<500 {
                saved = try #require(try await f.base.repository.snapshot().runs.first { $0.id == f.run.id })
                if saved.result?.artifactManifestPath != captured.artifactManifestPath { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            let upgraded = try HirdWorkspace.loadManifest(for: #require(saved.result))
            let finalPayload = try #require(upgraded.artifacts.first { $0.sourcePath == firstPayload.sourcePath })
            #expect(finalPayload.byteCount == Int64(payload.count + suffix.count))
            #expect(finalPayload.sha256 != firstPayload.sha256)
            #expect(finalPayload.captureKind == .observedPrefix)
            #expect(try HirdWorkspace.fingerprint(firstManifest) == firstFingerprint)
            #expect(try Data(contentsOf: firstManifest.deletingLastPathComponent().appendingPathComponent(firstPayload.blobPath)) == payload)
            #expect(try Data(contentsOf: artifacts.appendingPathComponent("42.bash.log")) == payload)
            let (restored, _) = try await HirdWorkspace.prepare(project: f.base.directory,
                root: f.base.directory.appendingPathComponent("payload-restore"), previous: saved)
            let restoredPayload = URL(fileURLWithPath: try #require(restored.ompSessionPath))
                .appendingPathComponent(f.source.deletingPathExtension().lastPathComponent).appendingPathComponent("42.bash.log")
            #expect(try Data(contentsOf: restoredPayload) == payload + suffix)
            await adapter.cancel(f.run.id); _ = await task.result
            try await f.base.cleanup()
        } catch { await adapter.cancel(f.run.id); _ = await task.result; try await f.base.cleanup(); throw error }
    }

    @Test(arguments: ContinuationFixture.Session.allCases.filter { $0 != .valid })
    fileprivate func unavailableSessionStartsFreshWithResultEvidence(session: ContinuationFixture.Session) async throws {
        let f = try await ContinuationFixture.make(session: session), rpc = ScriptedHirdRPC()
        let adapter = try f.adapter(rpc: rpc)
        let task = Task { try await adapter.start(f.run, emit: f.base.sink) }
        do {
            let text = try await prompt(from: rpc)
            #expect(!(await rpc.arguments).contains("--resume"))
            #expect(text.contains("Prior result summary"))
            #expect(text.contains("Prior report: parser rejected the old format"))
            #expect(text.contains("prior-failure-reason"))
            #expect(text.contains("missing-history-marker [old-check]"))
            #expect(text.contains("original.txt"))
            #expect(text.contains("swift test --filter Prior"))
            #expect(text.contains("exit code: 1"))
            #expect(text.contains("swift test --filter Interrupted"))
            #expect(text.contains("exit code: unknown"))
            #expect(text.contains("Current instruction marker"))
            await adapter.cancel(f.run.id); _ = await task.result
            if session == .unreadable { try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: f.source.path) }
            if session != .missing { #expect(try Data(contentsOf: f.source) == f.original) }
            try await f.base.cleanup()
        } catch {
            await adapter.cancel(f.run.id); _ = await task.result
            if session == .unreadable { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: f.source.path) }
            try await f.base.cleanup(); throw error
        }
    }

    @Test func fallbackIncludesCommittedFilesWhenSavedPatchIsEmpty() async throws {
        let f = try await ContinuationFixture.make(session: .missing, committed: true), rpc = ScriptedHirdRPC()
        let adapter = try f.adapter(rpc: rpc)
        let task = Task { try await adapter.start(f.run, emit: f.base.sink) }
        do {
            let text = try await prompt(from: rpc)
            #expect(text.contains("committed-only.txt"))
            #expect(text.contains("original.txt"))
            await adapter.cancel(f.run.id); _ = await task.result
            try await f.base.cleanup()
        } catch { await adapter.cancel(f.run.id); _ = await task.result; try await f.base.cleanup(); throw error }
    }

    @Test func judgementRemainsBoundToItsRunAfterResetAndReopen() async throws {
        let f = try await ContinuationFixture.make()
        do {
            _ = try await f.base.repository.recordEvent(id: "new-failure", runID: f.run.id, at: .now, payload: .fail("later-failure"))
            var issue = try #require(try await f.base.repository.snapshot().issues.first)
            issue.hirds = []; issue.events = []
            issue.acceptance = [.init(text: "Later condition", state: .unmet, evidence: "later-attempt-evidence")]
            try await f.base.repository.saveIssue(issue, projectID: "p")
            try await f.base.repository.close()
            let reopened = try await SQLiteKnarrRepository.open(at: f.base.directory.appendingPathComponent("knarr.db"))
            do {
                let old = try await reopened.readRun(f.base.run.id, includeHistory: false)
                let current = try await reopened.readRun(f.run.id, includeHistory: false)
                #expect(old.acceptanceEvidence?.first(where: { $0.state == .unmet })?.evidence == "missing-history-marker [old-check]")
                #expect(current.acceptanceEvidence?.first?.evidence == "later-attempt-evidence")
                try await reopened.close()
            } catch { try await reopened.close(); throw error }
            try await f.base.cleanup()
        } catch { try await f.base.cleanup(); throw error }
    }

    @Test func firstRunHasNoContinuationHeaderOrResumeArgument() async throws {
        let f = try await HirdFixture.make()
        let task = Task { try await f.adapter.start(f.run, emit: f.sink) }
        do {
            _ = try await prompt(from: f.rpc)
            #expect(!(await f.rpc.arguments).contains("--resume"))
            await f.adapter.cancel(f.run.id); _ = await task.result
            try await f.cleanup()
        } catch { await f.adapter.cancel(f.run.id); _ = await task.result; try await f.cleanup(); throw error }
    }
}

private extension Data {
    func appendToFile(_ file: URL) throws {
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd(); try handle.write(contentsOf: self)
    }
}

/// Uses the actual launch configuration, but intercepts prompt admission so no model is called.
private actor ContinuationRuntimeRPC: HirdRPC {
    let rpc = OMPRPCSession()
    var state: OMPJSON?
    var history: OMPJSON?
    var directory: OMPJSON?
    var prompt: String?
    func start(_ configuration: OMPLaunchConfiguration) async throws {
        try await rpc.start(configuration)
        state = try await rpc.request("get_state")["data"]
        history = try await rpc.request("get_messages")["data"]
        directory = try await rpc.request("bash", fields: ["command": .string("/bin/pwd")], timeout: .seconds(10))["data"]
    }
    func subscribe() async -> AsyncStream<OMPEvent> { await rpc.subscribe() }
    func request(_ command: String, fields: [String: OMPJSON], timeout: Duration) async throws -> OMPJSON {
        if command == "prompt" {
            state = try await rpc.request("get_state")["data"]
            prompt = fields["message"]?.string
            return .object(["success": .bool(true), "id": .string("intercepted-no-model")])
        }
        return try await rpc.request(command, fields: fields, timeout: timeout)
    }
    func send(_ command: String, fields: [String: OMPJSON]) async throws { try await rpc.send(command, fields: fields) }
    func shutdown(cancel: Bool) async -> OMPProcessExit { await rpc.shutdown(cancel: cancel) }
}

extension HirdSessionContinuationTests {
    @Test(arguments: [HirdRunMode.change, .inspect])
    func copiedSessionResumesHistoryWithoutModelCalls(mode: HirdRunMode) async throws {
        let f = try await ContinuationFixture.make(previousMode: mode == .change ? .inspect : .change, mode: mode, model: "openai/gpt-5.2")
        let rpc = ContinuationRuntimeRPC()
        let policies = HirdPolicyFiles(directory: f.base.directory.appendingPathComponent("hird"))
        _ = try policies.load()
        try "Current policy marker.\n".write(to: policies.directory.appendingPathComponent("instructions.md"), atomically: true, encoding: .utf8)
        let environment = ["PATH": "/usr/bin:/bin:/opt/homebrew/bin", "HOME": f.base.directory.appendingPathComponent("home").path,
                           "PI_CODING_AGENT_DIR": f.base.directory.appendingPathComponent("agent").path]
        let adapter = try f.adapter(rpc: rpc, environment: environment)
        let task = Task { try await adapter.start(f.run, emit: f.base.sink) }
        do {
            for _ in 0..<1000 {
                if await rpc.prompt != nil { break }
                if await adapter.exits[f.run.id] != nil { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            if await adapter.exits[f.run.id] != nil {
                if case .failure(let error) = await task.result { throw error }
            }
            let resumedPrompt = try #require(await rpc.prompt)
            #expect(resumedPrompt.contains("Current policy marker."))
            #expect(resumedPrompt.contains("Current instruction marker"))
            let state = try #require(await rpc.state)
            let history = try #require(await rpc.history?["messages"]?.array)
            let texts = history.flatMap { $0["content"]?.array?.compactMap { $0["text"]?.string } ?? [] }
            #expect(texts.contains("previous-attempt-marker"))
            #expect(texts.contains("previous-error-marker: tried the wrong path"))
            #expect(state["sessionId"]?.string == continuationSessionID)
            let saved = try #require(try await f.base.repository.snapshot().runs.first { $0.id == f.run.id })
            let copy = URL(fileURLWithPath: try #require(state["sessionFile"]?.string))
            #expect(copy.deletingLastPathComponent().path == saved.workspace?.ompSessionPath)
            #expect(copy != f.source)
            let directory = try #require(await rpc.directory)
            #expect(directory["exitCode"]?.integer == 0)
            #expect(directory["output"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) == saved.workspace?.worktreePath)
            #expect(state["model"]?["provider"]?.string == "openai")
            #expect(state["model"]?["id"]?.string == "gpt-5.2")
            #expect(state["thinkingLevel"]?.string == "off")
            let tools = state["dumpTools"]?.array?.compactMap { $0["name"]?.string } ?? []
            #expect(tools.contains("lsp") == (mode == .change))
            #expect(tools.contains("ask"))
            // The native inspect boundary is checked before Knarr adds its progress-only host tool.
            if mode == .inspect { #expect(Set(tools) == Set(HirdInspectionPolicy.tools + ["report_stage"])) }
            #expect(try String(contentsOfFile: try #require(saved.workspace?.worktreePath) + "/original.txt", encoding: .utf8) == "preserved attempt\n")
            #expect(SHA256.hash(data: try Data(contentsOf: f.source)) == SHA256.hash(data: f.original))
            await adapter.cancel(f.run.id); _ = await task.result
            #expect(await adapter.exits[f.run.id]?.remainingProcessIDs == [])
            print("Hird continuation mode=\(mode.rawValue) history=preserved source_bytes=unchanged model=openai/gpt-5.2 thinking=off latest_policy=true provider_calls=0 owned_remaining=0")
            try await f.base.cleanup()
        } catch { await adapter.cancel(f.run.id); _ = await task.result; try await f.base.cleanup(); throw error }
    }
}
