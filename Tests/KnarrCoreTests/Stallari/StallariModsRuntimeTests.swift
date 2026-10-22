import Foundation
import Testing
@testable import KnarrCore

private actor ModsTrace {
    var frames: [OMPJSON] = []
    var settled = 0
    func add(_ event: OMPEvent) {
        guard case .frame(let frame) = event else { return }
        frames.append(frame)
        if frame["type"]?.string == "session_settled" { settled += 1 }
    }
    func confirmedResult() -> Bool {
        frames.contains { $0["type"]?.string == "tool_execution_end" && $0["toolName"]?.string == "knarr_probe" && $0["result"]?["details"]?["confirmed"]?.bool == true }
    }
    func confirmedCount() -> Int {
        frames.reduce(0) { count, frame in
            count + (frame["type"]?.string == "tool_execution_end" && frame["toolName"]?.string == "knarr_probe" && frame["result"]?["details"]?["confirmed"]?.bool == true ? 1 : 0)
        }
    }
    func hasToast(_ message: String) -> Bool {
        frames.contains { $0["type"]?.string == "extension_ui_request" && $0["method"]?.string == "notify" && $0["message"]?.string == message }
    }
    func uiAnswers() -> OMPJSON? {
        for frame in frames.reversed() {
            guard frame["type"]?.string == "extension_ui_request", frame["method"]?.string == "notify",
                  let text = frame["message"]?.string, text.hasPrefix("{"),
                  let value = try? JSONDecoder().decode(OMPJSON.self, from: Data(text.utf8)), value["edited"] != nil else { continue }
            return value
        }
        return nil
    }
}

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["KNARR_MODS_OMP"] != nil))
@MainActor struct StallariModsRuntimeTests {
    private func until(_ predicate: @MainActor () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(20)
        while try await !predicate() {
            guard ContinuousClock.now < deadline else { throw OMPRPCError.timedOut }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
    @Test func mainExecutesOperationalCommandWithoutCreatingHird() async throws {
        let f = try await StallariFixture.make()
        let root = f.directory
        let base = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let driver = base.appendingPathComponent("Tests/Fixtures/StallariMods/driver.ts")
        let installation = try OMPInstallation(executable: URL(fileURLWithPath: #require(ProcessInfo.processInfo.environment["KNARR_MODS_OMP"])))
        let environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": root.path,
            "PI_CODING_AGENT_DIR": root.appendingPathComponent("agent").path, "PI_CONFIG_DIR": root.appendingPathComponent("config").path]
        let rpc = StallariRPCProcess(launch: { _ in
            var config = try StallariTools.configuration(installation: installation, workingDirectory: root,
                configurationFile: root.appendingPathComponent("stallari.yml"), sessionDirectory: root.appendingPathComponent("sessions"), environment: environment)
            config.arguments += ["--trusted-extension", driver.path, "--model", "knarr-fixture/deterministic", "--thinking", "off"]
            return config
        })
        let session = StallariSession(repository: f.repository, rpc: rpc, hird: f.hird)
        let trace = ModsTrace(), stream = await rpc.subscribe()
        let observer = Task { for await event in stream { await trace.add(event) } }
        do {
            try await rpc.start()
            try await session.connect()
            #expect(try await session.checkToolExposure().contains("bash"))
            _ = try await session.send("CALL_DIRECT_COMMAND", about: nil)
            try await until { await trace.settled > 0 }
            let result = try #require(await trace.frames.last { $0["type"]?.string == "tool_execution_end" && $0["toolName"]?.string == "bash" })
            #expect(result["isError"]?.bool != true)
            #expect(String(decoding: try result.jsonLine(), as: UTF8.self).contains("KNARR_DIRECT_COMMAND_OK"))
            #expect(try await f.repository.snapshot().issues.isEmpty)
            #expect(await f.hird.runs.isEmpty)
            let exit = await session.shutdown()
            observer.cancel(); await observer.value
            #expect(exit.remainingProcessIDs.isEmpty)
            try await f.cleanup()
            print("Stallari direct bash: output=KNARR_DIRECT_COMMAND_OK, issues=0, hirds=0, remaining=0")
        } catch {
            _ = await session.shutdown()
            observer.cancel(); await observer.value
            try? await f.cleanup()
            throw error
        }
    }

    @Test func actualToolsUIRestartContinuationAndSyntaxFailure() async throws {
        let base = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let root = base.appendingPathComponent("outputs/stallari-mods/runtime-\(UUID())")
        let extensions = KnarrExtensions(root: root)
        try extensions.prepare()
        for (folder, name, description) in [("skills", "knarr-only-skill", "KNARR_ONLY_SKILL"), (".omp/skills", "ambient-skill", "KNARR_AMBIENT_RESOURCE")] {
            let directory = root.appendingPathComponent(folder + "/" + name)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try "---\nname: \(name)\ndescription: \(description)\n---\nUse this skill.\n".write(to: directory.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        }
        try "KNARR_ONLY_RULE: Preserve the user's intent.".write(to: root.appendingPathComponent("rules/owned.md"), atomically: true, encoding: .utf8)
        let ambientRules = root.appendingPathComponent(".omp/rules")
        try FileManager.default.createDirectory(at: ambientRules, withIntermediateDirectories: true)
        try "KNARR_AMBIENT_RESOURCE".write(to: ambientRules.appendingPathComponent("ambient.md"), atomically: true, encoding: .utf8)
        let fixture = base.appendingPathComponent("Tests/Fixtures/StallariMods/example.ts")
        let source = try String(contentsOf: fixture, encoding: .utf8)
        let driver = base.appendingPathComponent("Tests/Fixtures/StallariMods/driver.ts")
        let installation = try OMPInstallation(executable: URL(fileURLWithPath: #require(ProcessInfo.processInfo.environment["KNARR_MODS_OMP"])))
        let environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": root.path,
            "PI_CODING_AGENT_DIR": root.appendingPathComponent("agent").path, "PI_CONFIG_DIR": root.appendingPathComponent("config").path]
        let launch: @Sendable (Bool) throws -> OMPLaunchConfiguration = { include in
            var config = try StallariTools.configuration(installation: installation, workingDirectory: root,
                configurationFile: root.appendingPathComponent("stallari.yml"), sessionDirectory: root.appendingPathComponent("sessions"),
                environment: environment, extensions: extensions, loadingExtensions: include)
            config.arguments += ["--trusted-extension", driver.path, "--model", "knarr-fixture/deterministic", "--thinking", "off"]
            return config
        }
        let rpc = StallariRPCProcess(launch: launch)
        let repository = try await SQLiteKnarrRepository.open(at: root.appendingPathComponent("test.db"))
        let hird = TestHird()
        let session = StallariSession(repository: repository, rpc: rpc, hird: hird, extensions: extensions, restartRPC: { try await rpc.restart() })
        let suite = "knarr-mods-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let conversation = LiveConversation(repository: repository, session: session, rpc: rpc, hird: hird, preferences: defaults)
        let trace = ModsTrace(), stream = await rpc.subscribe()
        let observer = Task { for await event in stream { await trace.add(event) } }
        var reopened: LiveConversation?
        do {
            _ = try await session.performTool("write_extension", arguments: .object(["name": .string("example.ts"), "source": .string(source)]))
            try await rpc.start()
            try await conversation.connect()
            let before = try await session.getState()["data"] ?? .null
            let sessionID = try #require(before["sessionId"]?.string)
            #expect(before["dumpTools"]?.array?.first(where: { $0["name"]?.string == "knarr_probe" })?["description"]?.string == "VERSION_ONE")
            #expect(conversation.models.contains("knarr-fixture/deterministic"))
            try await until { conversation.extensionPresentation.statuses["driver-startup"] == "connected" }
            #expect(conversation.extensionPresentation.widgets["driver-startup"] == ["connected"])
            try await conversation.submit(.init(text: "CHECK_OWNED_RESOURCES", attachments: [], project: nil))
            try await until { conversation.chat.contains { if case .stallari(let text, _) = $0.kind { text.contains("OWNED_RULE=true OWNED_SKILL=true AMBIENT_BLOCKED=true") } else { false } } }
            try await until { await trace.settled >= 1 }
            let beforeProbeSettled = await trace.settled
            print("OMP owned resources: root skills/rules visible; ambient resources blocked=true")
            try await conversation.submit(.init(text: "CALL_PROBE", attachments: [], project: nil))
            try await until { conversation.extensionQuestions.contains(where: { $0.replyStyle == .confirm && $0.isPending }) }
            #expect(conversation.extensionPresentation.statuses["probe"] == "ready")
            let confirm = try #require(conversation.extensionQuestions.first { $0.isPending })
            #expect(confirm.issue == nil && confirm.run == nil)
            #expect(confirm.extensionIdentity?.sessionID == sessionID)
            await conversation.resolveExtensionQuestion(confirm.id, answer: .init(selectedOptions: ["예"], text: nil))
            try await until { await trace.confirmedResult() }
            try await until { await trace.settled > beforeProbeSettled }
            #expect(try await repository.snapshot().runs.isEmpty)
            print("OMP roundtrip: actual knarr_probe handler confirmed=true; setStatus=ready; synthetic_hird_runs=0")

            // Exercise the remaining UI methods on the real command path, using the same card router.
            let command = Task { try await rpc.request("prompt", fields: ["message": .string("/knarr-ui-probe")], timeout: .seconds(60)) }
            for (method, answer) in [(Question.ReplyStyle.confirm, QuestionAnswer(selectedOptions: ["아니요"], text: nil)),
                                     (.select, .init(selectedOptions: ["second"], text: nil)),
                                     (.input, .init(selectedOptions: [], text: "typed")),
                                     (.editor, .init(selectedOptions: [], text: "edited\nline"))] {
                try await until { conversation.extensionQuestions.contains { $0.replyStyle == method && $0.isPending } }
                if method == .confirm {
                    #expect(conversation.extensionPresentation.widgets["probe"] == ["widget line"])
                    #expect(conversation.extensionPresentation.toast?.message == "probe toast")
                }
                let question = try #require(conversation.extensionQuestions.last { $0.replyStyle == method && $0.isPending })
                await conversation.resolveExtensionQuestion(question.id, answer: answer)
            }
            _ = try await command.value
            try await until { await trace.hasToast("probe complete") }
            try #require(conversation.extensionPresentation.statuses["probe"] == nil)
            try #require(conversation.extensionPresentation.widgets["probe"] == nil)
            let values = try #require(await trace.uiAnswers())
            try #require(values["selected"]?.string == "second")
            try #require(values["input"]?.string == "typed")
            try #require(values["edited"]?.string == "edited\nline")
            try #require(await trace.hasToast("declined"))
            print("OMP UI: notify/select/confirm/input/editor roundtrip; status/widget removal=true")

            _ = try await session.performTool("write_extension", arguments: .object(["name": .string("example.ts"), "source": .string(source.replacingOccurrences(of: "VERSION_ONE", with: "VERSION_TWO"))]))
            try await conversation.submit(.init(text: "RELOAD_EXTENSIONS", attachments: [], project: nil))
            try await until { await session.lastExtensionReload != nil }
            let reloaded = try #require(await session.lastExtensionReload)
            #expect(reloaded["errors"]?.array == [])
            #expect(reloaded["sessionID"]?.string == sessionID)
            #expect(reloaded["tools"]?.array?.first(where: { $0["name"]?.string == "knarr_probe" })?["description"]?.string == "VERSION_TWO")
            let messages = try await rpc.request("get_messages", fields: [:], timeout: .seconds(10))
            let history = String(decoding: try JSONEncoder().encode(messages), as: UTF8.self)
            #expect(history.contains("CALL_PROBE") && history.contains("confirmed"))
            #expect(history.contains("queued_until_session_settled"))
            try await conversation.submit(.init(text: "CONTINUE_CONVERSATION", attachments: [], project: nil))
            try await until { conversation.chat.contains { if case .stallari(let text, _) = $0.kind { text.contains("CONVERSATION_CONTINUES") } else { false } } }
            print("OMP reload: turn settled before restart; same_session=true; description=VERSION_TWO; next_turn_continues=true")
            let settledBeforeLateReply = await trace.settled
            try await conversation.submit(.init(text: "CALL_PROBE", attachments: [], project: nil))
            try await until { conversation.extensionQuestions.contains { $0.isPending && $0.replyStyle == .confirm } }
            let currentQuestion = try #require(conversation.extensionQuestions.last { $0.isPending })
            let currentIdentity = try #require(currentQuestion.extensionIdentity)
            let oldIdentity = try #require(confirm.extensionIdentity)
            try await rpc.send("extension_ui_response", fields: ["id": .string(currentIdentity.rpcID), "value": .bool(false), "knarrRPCGeneration": .string(oldIdentity.rpcGeneration)])
            await conversation.resolveExtensionQuestion(confirm.id, answer: .init(selectedOptions: ["아니요"], text: nil))
            #expect(try await rpc.request("get_state", fields: [:], timeout: .seconds(10))["data"]?["isStreaming"]?.bool == true)
            #expect(conversation.extensionQuestions.first { $0.id == currentQuestion.id }?.isPending == true)
            #expect(await trace.confirmedCount() == 1)
            await conversation.resolveExtensionQuestion(currentQuestion.id, answer: .init(selectedOptions: ["예"], text: nil))
            try await until {
                let count = await trace.confirmedCount(), settled = await trace.settled
                return count == 2 && settled > settledBeforeLateReply
            }
            print("OMP generation fence: old-generation response ignored; new dialog remains pending until its own answer")

            _ = try await session.performTool("write_extension", arguments: .object(["name": .string("example.ts"), "source": .string("export default function (")]))
            let priorGeneration = reloaded["generation"]?.string
            try await conversation.submit(.init(text: "RELOAD_EXTENSIONS", attachments: [], project: nil))
            try await until { await session.lastExtensionReload?["generation"]?.string != priorGeneration }
            let failed = try #require(await session.lastExtensionReload)
            #expect(failed["errors"]?.array?.first?["exitCode"]?.integer == 1)
            #expect(failed["errors"]?.array?.first?["requestedExtensions"]?.array?.contains(.string(extensions.directory(.stallari).appendingPathComponent("example.ts").path)) == true)
            #expect(failed["tools"]?.array?.contains(where: { $0["name"]?.string == "knarr_probe" }) == false)
            #expect(failed["sessionID"]?.string == sessionID)
            // A real policy-only process accepts a repair, then reloads the corrected module.
            _ = try await session.performTool("write_extension", arguments: .object(["name": .string("example.ts"), "source": .string(source)]))
            let repaired = try await session.performTool("reload_extensions", arguments: .object([:]))
            #expect(repaired["errors"]?.array == [])
            #expect(repaired["tools"]?.array?.contains(where: { $0["name"]?.string == "knarr_probe" }) == true)
            print("OMP syntax failure: actual startup exit=1 returned; missing extension not reported loaded; repair/reload=true")
            let exit = await conversation.shutdown()
            observer.cancel(); await observer.value
            #expect(exit.remainingProcessIDs.isEmpty)
            #expect(await rpc.exits.allSatisfy { $0.remainingProcessIDs.isEmpty })
            print("OMP owned_remaining=\(exit.remainingProcessIDs.count)")
            _ = try extensions.writeStallari(name: "example.ts", source: "export default function (")
            let secondRPC = StallariRPCProcess(launch: launch)
            let secondHird = TestHird()
            let secondSession = StallariSession(repository: repository, rpc: secondRPC, hird: secondHird, extensions: extensions, restartRPC: { try await secondRPC.restart() })
            let secondConversation = LiveConversation(repository: repository, session: secondSession, rpc: secondRPC, hird: secondHird, preferences: defaults)
            reopened = secondConversation
            try await secondRPC.start()
            // Subscribe after startup: both the error and startup UI must survive.
            try await secondConversation.connect()
            let initialFailure = try #require(await secondSession.lastExtensionReload)
            #expect(initialFailure["errors"]?.array?.first?["exitCode"]?.integer == 1)
            #expect(initialFailure["status"]?.string == "startup_failed_policy_only")
            try await until { secondConversation.extensionPresentation.statuses["driver-startup"] == "connected" }
            try await secondConversation.submit(.init(text: "CONTINUE_CONVERSATION", attachments: [], project: nil))
            try await until { !secondConversation.isResponding }
            let initialHistory = String(decoding: try JSONEncoder().encode(try await secondRPC.request("get_messages", fields: [:], timeout: .seconds(10))), as: UTF8.self)
            #expect(initialHistory.contains("startup_failed_policy_only"))
            #expect(initialHistory.contains("CONTINUE_CONVERSATION"))
            _ = try await secondSession.performTool("write_extension", arguments: .object(["name": .string("example.ts"), "source": .string(source)]))
            let startupRepair = try await secondSession.performTool("reload_extensions", arguments: .object([:]))
            #expect(startupRepair["errors"]?.array == [])
            #expect(startupRepair["tools"]?.array?.contains(where: { $0["name"]?.string == "knarr_probe" }) == true)
            let secondExit = await secondConversation.shutdown()
            #expect(secondExit.remainingProcessIDs.isEmpty)
            #expect(await secondRPC.exits.allSatisfy { $0.remainingProcessIDs.isEmpty })
            reopened = nil
            print("OMP startup failure: late subscriber receives load error/status; next-turn notification=true; repair=true; owned_remaining=0")
            try await repository.close()
            defaults.removePersistentDomain(forName: suite)
            try FileManager.default.removeItem(at: root)
            print("OMP temporary_remaining=0")
        } catch {
            if let state = try? await rpc.request("get_state", fields: [:], timeout: .seconds(10)) {
                print("OMP failed stage actual_tools=" + (state["data"]?["dumpTools"]?.array?.compactMap { $0["name"]?.string } ?? []).joined(separator: ","))
            }
            for frame in await trace.frames.suffix(18) {
                print("OMP failure frame=" + (frame["type"]?.string ?? "?") + " method=" + (frame["method"]?.string ?? "")
                    + " tool=" + (frame["toolName"]?.string ?? "") + " error=" + (frame["error"]?.string ?? ""))
            }
            if let message = await trace.frames.last(where: { $0["type"]?.string == "message_end" && $0["message"]?["role"]?.string == "assistant" })?["message"] {
                print("OMP fixture reply=" + (message["content"]?.array?.compactMap { $0["text"]?.string.map { String($0.prefix(150)) } } ?? []).joined(separator: "\n"))
            }
            _ = await conversation.shutdown(); observer.cancel(); await observer.value
            if let reopened { _ = await reopened.shutdown() }
            try? await repository.close(); defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }
}
