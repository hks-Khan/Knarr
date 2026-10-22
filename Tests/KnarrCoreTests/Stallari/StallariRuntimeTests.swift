import Foundation
import Testing
@testable import KnarrCore

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["KNARR_OMP_EXECUTABLE"] != nil))
struct StallariRuntimeTests {
    @Test func pinnedRuntimeBlocksBuiltinAndProjectDiscoveryMetadataOnly() async throws {
        let executable = try #require(ProcessInfo.processInfo.environment["KNARR_OMP_EXECUTABLE"])
        let install = try OMPInstallation(executable: URL(fileURLWithPath: executable))
        let f = try await StallariFixture.make()
        let rpc = OMPRPCSession()
        let session = StallariSession(repository: f.repository, rpc: rpc, hird: f.hird)
        var environment = ProcessInfo.processInfo.environment
        environment["PI_CODING_AGENT_DIR"] = f.directory.appendingPathComponent("official-metadata-only-agent").path
        environment["PI_CONFIG_DIR"] = String(repeating: "../", count: FileManager.default.homeDirectoryForCurrentUser.pathComponents.count - 1) + f.directory.path.dropFirst()
        environment.removeValue(forKey: "OMP_PROFILE"); environment.removeValue(forKey: "PI_PROFILE")
        // A valid project custom tool loads and executes its factory if discovery is enabled.
        let tools = f.directory.appendingPathComponent(".omp/tools")
        try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
        let sentinel = """
        import { writeFileSync } from 'node:fs';
        export default function () {
            writeFileSync('PROJECT-TOOL-LOADED', 'unsafe discovery');
            return { name: 'coding_sentinel', label: 'Coding sentinel', description: 'Project tool isolation sentinel',
                parameters: { type: 'object', properties: {} }, execute: async () => ({ content: [{ type: 'text', text: 'sentinel' }] }) };
        }
        """
        try sentinel.write(to: tools.appendingPathComponent("sentinel.ts"), atomically: true, encoding: .utf8)
        // Negative control: --no-tools alone still loads the project custom-tool factory.
        let unprotected = OMPRPCSession()
        do {
            try await unprotected.start(.init(installation: install, workingDirectory: f.directory,
                arguments: ["--mode", "rpc", "--no-session", "--no-tools", "--no-lsp", "--no-pty", "--no-extensions", "--no-skills", "--no-rules", "--no-title"], environment: environment))
            #expect(FileManager.default.fileExists(atPath: f.directory.appendingPathComponent("PROJECT-TOOL-LOADED").path))
            let exit = await unprotected.shutdown()
            #expect(exit.remainingProcessIDs.isEmpty)
            try FileManager.default.removeItem(at: f.directory.appendingPathComponent("PROJECT-TOOL-LOADED"))
        } catch { _ = await unprotected.shutdown(cancel: true); try await f.cleanup(); throw error }
        do {
            let config = try StallariTools.configuration(installation: install, workingDirectory: f.directory,
                configurationFile: f.directory.appendingPathComponent("stallari.yml"), sessionDirectory: f.directory.appendingPathComponent("sessions"), environment: environment)
            try await rpc.start(config)
            try await session.connect()
            let names = try await session.checkToolExposure()
            #expect(!FileManager.default.fileExists(atPath: f.directory.appendingPathComponent("PROJECT-TOOL-LOADED").path))
            let state = try await session.getState()
            let evidence: OMPJSON = .object(["kind": .string("metadata-only-no-model-prompt"), "version": .string(OMPInstallation.version),
                "toolNames": .array(names.map(OMPJSON.string)), "sessionID": state["data"]?["sessionId"] ?? .null,
                "selectedProvider": state["data"]?["model"]?["provider"] ?? .null, "selectedModel": state["data"]?["model"]?["id"] ?? .null,
                "projectToolFactoryLoaded": .bool(false)])
            let output = f.directory.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("runtime-exposure.json")
            try JSONEncoder().encode(evidence).write(to: output)
            let exit = await session.shutdown()
            #expect(exit.remainingProcessIDs.isEmpty)
            print("Stallari OMP 18.7.0 metadata: tools=\(names.joined(separator: ",")) project_tool_factory_loaded=false model_prompt=not_run owned_remaining=\(exit.remainingProcessIDs.count)")
            try await f.cleanup()
        } catch { _ = await session.shutdown(); try await f.cleanup(); throw error }
    }
}

private actor LiveStallariTrace {
    var tools: [String] = []
    var eventTypes: [String] = []
    var promptStatus: String?
    var errorProvider: String?
    var errorModel: String?
    var httpStatus: Int?
    var observedMarker = false
    func add(_ event: OMPEvent) {
        guard case .frame(let frame) = event, let type = frame["type"]?.string else { return }
        if ["host_tool_call", "agent_start", "agent_end", "prompt_result", "session_settled"].contains(type) { eventTypes.append(type) }
        if type == "message_end", frame["message"]?["role"]?.string == "assistant",
           frame["message"]?["content"]?.array?.contains(where: { $0["text"]?.string?.contains("KNARR-LIVE-TOOLS-OK") == true }) == true { observedMarker = true }
        if type == "host_tool_call", let name = frame["toolName"]?.string { tools.append(name) }
        if type == "prompt_result" {
            promptStatus = frame["status"]?.string
            errorProvider = frame["error"]?["provider"]?.string
            errorModel = frame["error"]?["model"]?.string
            httpStatus = frame["error"]?["httpStatus"]?.integer
        }
    }
    func evidence() -> OMPJSON {
        .object(["toolCalls": .array(tools.map(OMPJSON.string)), "events": .array(eventTypes.map(OMPJSON.string)),
            "promptStatus": promptStatus.map(OMPJSON.string) ?? .null, "observedMarker": .bool(observedMarker),
            "errorProvider": errorProvider.map(OMPJSON.string) ?? .null, "errorModel": errorModel.map(OMPJSON.string) ?? .null,
            "httpStatus": httpStatus.map { .number(Double($0)) } ?? .null])
    }
}
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["KNARR_STALLARI_MODEL"] != nil))
struct StallariRealModelTests {
    @Test func configuredLocalModelCallsToolsWithoutBypassingApprovalAndReopensSavedConversation() async throws {
        let model = try #require(ProcessInfo.processInfo.environment["KNARR_STALLARI_MODEL"])
        let executable = try #require(ProcessInfo.processInfo.environment["KNARR_OMP_EXECUTABLE"])
        let install = try OMPInstallation(executable: URL(fileURLWithPath: executable))
        let f = try await StallariFixture.make()
        // A declared internal adapter result, never described as actual Hird code work.
        let verified = try await f.issue("verified"), verifiedRun = try await f.dispatch("verified-run", issue: verified)
        _ = try await f.session.receive(.init(id: "verified-complete", runID: verifiedRun, at: .now, payload: .complete(f.result(), notificationID: "internal-notice")))
        let rpc = OMPRPCSession(), trace = LiveStallariTrace()
        let session = StallariSession(repository: f.repository, rpc: rpc, hird: f.hird)
        let stream = await rpc.subscribe()
        let observer = Task { for await event in stream { await trace.add(event) } }
        var environment = ProcessInfo.processInfo.environment
        // Local Ollama requires no copied credential. Preserve official auth environment
        // when explicitly supplied; redirect only the otherwise absent default store.
        if environment["PI_CODING_AGENT_DIR"] == nil && !FileManager.default.fileExists(atPath: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".omp/agent/agent.db").path) {
            environment["PI_CODING_AGENT_DIR"] = f.directory.appendingPathComponent("official-agent").path
        }
        environment["PI_CONFIG_DIR"] = String(repeating: "../", count: FileManager.default.homeDirectoryForCurrentUser.pathComponents.count - 1) + f.directory.path.dropFirst()
        let output = f.directory.deletingLastPathComponent().deletingLastPathComponent()
        var config = try StallariTools.configuration(installation: install, workingDirectory: f.directory,
            configurationFile: f.directory.appendingPathComponent("stallari.yml"), sessionDirectory: f.directory.appendingPathComponent("sessions"), environment: environment)
        // The pinned CLI cannot resolve this dynamic local model before startup.
        // Use the existing selection and verify the exact provider/model before any prompt.
        config.arguments += ["--thinking", "off"]
        do {
            try await rpc.start(config)
            try await session.connect()
            let state = try await session.getState()
            let selected = (state["data"]?["model"]?["provider"]?.string ?? "") + "/" + (state["data"]?["model"]?["id"]?.string ?? "")
            guard selected == model else { throw StallariError.conflictingID }
            let names = try await session.checkToolExposure()
            let available = try await rpc.request("get_available_models")
            let proposalModel = try #require(available["data"]?["models"]?.array?.compactMap { candidate -> String? in
                guard let provider = candidate["provider"]?.string, ["openai-codex", "openai", "anthropic"].contains(provider),
                      let id = candidate["id"]?.string else { return nil }
                return provider + "/" + id
            }.first)
            // This existing real-model suite judges/questions legacy bindings without a store.
            let approved = try await f.legacyIssue(id: "live-authorized", title: "Approved internal fixture", criteria: ["Internal check"], instruction: "Internal adapter only; do not edit files", model: proposalModel)
            let approvedRun = try await session.approveIssue(issueID: approved, version: 1)
            _ = try await rpc.request("prompt", fields: ["message": .string("""
                This is Knarr issue 3's internal adapter validation. No real code changes are requested. Execute these five calls in order, once each, using the directly available tools:
                1. create_issue with issueID='live-created', title='Internal adapter check', criteria=['Internal sum verification passes'], instruction='Internal adapter only; do not edit files', model='\(proposalModel)'.
                2. dispatch_hird with issueID='live-created', runID='live-run'. This must return an approval-required error; do not retry or seek approval.
                3. get_issue with issueID='verified'. Its result is a declared internal fixture and contains verification ID 'v'.
                4. ask_user with questionID='live-question', issueID='live-authorized', runID='\(approvedRun.rawValue)', prompt='Which internal fixture?', options=['A','B']. This existing run was explicitly approved by the user fixture. Do not wait for an answer.
                5. judge_issue with issueID='verified', runID='verified-run', evidence=[{'criterionIndex':0,'verificationIDs':['v'],'explanation':'The saved internal adapter verification passed'}]. This is only an internal fixture judgment.
                Finish with the marker KNARR-LIVE-TOOLS-OK. Do not dispatch anything else.
                """
            )], timeout: .seconds(10))
            let deadline = ContinuousClock.now + .seconds(180)
            while await trace.promptStatus == nil && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(100)) }
            let traceEvidence = await trace.evidence()
            let saved = try await f.repository.snapshot()
            let judged = try #require(saved.issues.first { $0.id == "verified" })
            try JSONEncoder().encode(OMPJSON.object(["kind": .string("actual-model-internal-hird-adapter"), "selectedModel": .string(selected),
                "ompVersion": .string(OMPInstallation.version), "modelTools": .array(names.map(OMPJSON.string)), "trace": traceEvidence,
                "savedJudgement": .object(["issueID": .string(judged.id.rawValue), "state": .string(judged.state.rawValue), "confirmed": .bool(judged.confirmed),
                    "metCriteria": .number(Double(judged.metCriteria))]),
                "savedQuestions": .array(saved.questions.map { .object(["questionID": .string($0.id), "runID": .string($0.runID.rawValue),
                    "issueID": .string($0.issueID.rawValue), "state": .string($0.state.rawValue)]) })])).write(to: output.appendingPathComponent("real-model-tools.json"))
            #expect(await trace.promptStatus == "completed")
            #expect(await trace.observedMarker)
            #expect(Set(await trace.tools).isSuperset(of: ["create_issue", "dispatch_hird", "get_issue", "ask_user", "judge_issue"]))
            #expect(saved.issues.first { $0.id == "live-created" }?.state == .awaitingApproval)
            #expect(!saved.runs.contains { $0.id == "live-run" })
            #expect(try await f.repository.snapshot().issues.first(where: { $0.id == "verified" })?.state == .done)
            #expect(try await f.repository.snapshot().issues.first(where: { $0.id == "verified" })?.confirmed == false)
            let oldID = try #require(state["data"]?["sessionId"]?.string)
            let sessionFile = try #require(try await session.getState()["data"]?["sessionFile"]?.string)
            let firstExit = await session.shutdown()
            #expect(firstExit.remainingProcessIDs.isEmpty)
            await observer.value
            // Reopening saved model conversation is separate from durable Hird resumption.
            let reopened = OMPRPCSession()
            var resumeConfig = config
            resumeConfig.arguments += ["--resume", sessionFile]
            do {
                try await reopened.start(resumeConfig)
                let restored = try await reopened.request("get_state")
                guard restored["data"]?["model"]?["provider"]?.string == state["data"]?["model"]?["provider"]?.string,
                      restored["data"]?["model"]?["id"]?.string == state["data"]?["model"]?["id"]?.string else { throw StallariError.conflictingID }
                #expect(restored["data"]?["sessionId"]?.string == oldID)
                #expect((restored["data"]?["messageCount"]?.integer ?? 0) > 0)
                let resumed = StallariSession(repository: f.repository, rpc: reopened, hird: TestHird())
                try await resumed.connect()
                let resumeStream = await reopened.subscribe(), resumeTrace = LiveStallariTrace()
                let resumeObserver = Task { for await event in resumeStream { await resumeTrace.add(event) } }
                _ = try await reopened.request("prompt", fields: ["message": .string("What marker did you end the previous internal check with? Reply only with that marker. Do not use tools and do not recreate tasks.")])
                let resumeDeadline = ContinuousClock.now + .seconds(120)
                while await resumeTrace.promptStatus == nil && ContinuousClock.now < resumeDeadline { try await Task.sleep(for: .milliseconds(100)) }
                #expect(await resumeTrace.promptStatus == "completed")
                #expect(await resumeTrace.observedMarker)
                let exit = await resumed.shutdown()
                await resumeObserver.value
                #expect(exit.remainingProcessIDs.isEmpty)
                try JSONEncoder().encode(OMPJSON.object(["kind": .string("actual-model-saved-conversation-reopen"), "selectedModel": .string(selected),
                    "sameSessionID": .bool(restored["data"]?["sessionId"]?.string == oldID), "messageCount": restored["data"]?["messageCount"] ?? .null,
                    "trace": await resumeTrace.evidence(), "ownedRemaining": .number(Double(exit.remainingProcessIDs.count))])).write(to: output.appendingPathComponent("real-model-resume.json"))
            } catch { _ = await reopened.shutdown(cancel: true); throw error }
            print("Stallari actual model=\(selected) five_tool_calls=\(Set(await trace.tools).count) saved_conversation_reopen=true internal_hird_only=true owned_remaining=0")
            try await f.cleanup()
        } catch {
            _ = await session.shutdown(); await observer.value
            try await f.cleanup(); throw error
        }
    }
}
