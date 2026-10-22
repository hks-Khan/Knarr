import Foundation
import Testing
@testable import KnarrCore

private actor TransferRuntimeTrace {
    private var frames: [OMPJSON] = []
    private let started = ContinuousClock.now
    private var timeline: [String] = []
    private var bridgeTimeline: [String] = []
    private var rpcTimeline: [String] = []
    private var latestGeneration: String?
    func add(_ event: OMPEvent) {
        guard case .frame(let frame) = event else { return }
        frames.append(frame)
        let elapsed = started.duration(to: .now).components
        let milliseconds = elapsed.seconds * 1000 + elapsed.attoseconds / 1_000_000_000_000_000
        let type = frame["type"]?.string ?? "unknown"
        let safeType = type.count <= 64 && type.allSatisfy { ("a"..."z").contains($0) || $0 == "_" } ? type : "unknown"
        timeline.append("\(milliseconds)ms:\(safeType)")
        if timeline.count > 64 { timeline.removeFirst() }
        if type == "knarr_rpc_ready" { latestGeneration = frame["generation"]?.string }
        if type == "prompt_result" {
            let status = frame["status"]?.string ?? "unknown"
            let safeStatus = ["completed", "error", "aborted"].contains(status) ? status : "unknown"
            rpcTimeline.append("\(milliseconds)ms:event:prompt_result,id=\(safeIdentifier(frame["id"]?.string)),status=\(safeStatus)")
            if rpcTimeline.count > 64 { rpcTimeline.removeFirst() }
        }
        if ProjectTransferProtocol.isBridgeFrame(frame) {
            let id = frame["id"]?.string ?? ""
            let safeID = safeIdentifier(id)
            let sameGeneration = latestGeneration.map { frame["knarrRPCGeneration"]?.string == $0 ? "true" : "false" } ?? "unknown"
            let arguments = frame["placeholder"]?.string.flatMap { try? JSONDecoder().decode(OMPJSON.self, from: Data($0.utf8)) }
            let operation = arguments?["operation"]?.string ?? "unknown"
            let safeOperation = ["context", "enqueue", "retry", "admission"].contains(operation) ? operation : "unknown"
            bridgeTimeline.append("\(milliseconds)ms:id=\(safeID),operation=\(safeOperation),generationEqual=\(sameGeneration)")
            if bridgeTimeline.count > 16 { bridgeTimeline.removeFirst() }
        }
    }
    private func safeIdentifier(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "none" }
        return value.count <= 96 && value.allSatisfy {
            ("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0) || "-_.:".contains($0)
        } ? value : "invalid-id"
    }
    func recordRPC(_ phase: String, command: String, id: String? = nil, receiptCount: Int? = nil,
                   success: Bool? = nil, generation: String? = nil) {
        let elapsed = started.duration(to: .now).components
        let milliseconds = elapsed.seconds * 1000 + elapsed.attoseconds / 1_000_000_000_000_000
        let safeCommand = ["get_state", "get_entries", "get_available_commands", "prompt", "set_host_tools",
                           "set_event_filter", "extension_ui_response", "host_tool_result"].contains(command) ? command : "other"
        let generationEqual = generation.flatMap { actual in latestGeneration.map { String(actual == $0) } } ?? "unknown"
        rpcTimeline.append("\(milliseconds)ms:\(phase):\(safeCommand),id=\(safeIdentifier(id)),success=\(success.map(String.init) ?? "unknown"),receipts=\(receiptCount.map(String.init) ?? "-"),generationEqual=\(generationEqual)")
        if rpcTimeline.count > 64 { rpcTimeline.removeFirst() }
    }
    func mark(_ fixtureStage: String) {
        let elapsed = started.duration(to: .now).components
        let milliseconds = elapsed.seconds * 1000 + elapsed.attoseconds / 1_000_000_000_000_000
        timeline.append("\(milliseconds)ms:fixture:\(fixtureStage)")
        if timeline.count > 64 { timeline.removeFirst() }
    }
    func toolResults(_ name: String = "transfer_to_main") -> [OMPJSON] {
        frames.filter { $0["type"]?.string == "tool_execution_end" && $0["toolName"]?.string == name }.compactMap { $0["result"] }
    }
    func nativeReadFailure() -> String? {
        guard let frame = frames.last(where: { $0["type"]?.string == "tool_execution_end" && $0["toolName"]?.string == "read" }),
              frame["isError"]?.bool == true || frame["result"]?["isError"]?.bool == true else { return nil }
        let text = frame["result"]?["content"]?.array?.compactMap { $0["text"]?.string }.joined(separator: "\n").lowercased() ?? ""
        if text.contains("denied") || text.contains("permission") || text.contains("not allowed") { return "permission-denied" }
        if text.contains("enoent") || text.contains("no such file") || text.contains("not found") { return "file-not-found" }
        if text.contains("unavailable") || text.contains("unknown tool") { return "native-read-unavailable" }
        return "native-read-error"
    }
    func bridgeOperations() -> [String] {
        frames.compactMap { frame in
            guard ProjectTransferProtocol.isBridgeFrame(frame), let raw = frame["placeholder"]?.string,
                  let json = try? JSONDecoder().decode(OMPJSON.self, from: Data(raw.utf8)) else { return nil }
            return json["operation"]?.string
        }
    }
    func assistantContains(_ text: String) -> Bool {
        frames.contains { $0["type"]?.string == "message_end" && $0["message"]?["role"]?.string == "assistant" &&
            $0["message"]?["content"]?.array?.contains(where: { $0["text"]?.string?.contains(text) == true }) == true }
    }
    func agentStarts() -> Int { frames.filter { $0["type"]?.string == "agent_start" }.count }
    func admissionErrors() -> [String] {
        frames.filter { $0["type"]?.string == "extension_error" && $0["extensionPath"]?.string == "command:knarr-project-transfer-admit" }
            .compactMap { $0["error"]?.string }
    }
    func diagnostics() -> String {
        let eventTypes = frames.suffix(16).compactMap { $0["type"]?.string }.joined(separator: ",")
        let assistant = frames.last { $0["type"]?.string == "message_end" && $0["message"]?["role"]?.string == "assistant" }?["message"]
        let content = assistant?["content"]?.array?.compactMap { $0["text"]?.string }.joined(separator: "\n") ?? ""
        let marker = ["TRANSFER_ATTACHMENT_READ_UNAVAILABLE", "TRANSFER_ATTACHMENT_REFERENCE_MISSING",
                      "TRANSFER_ATTACHMENT_READ_RESULT", "TRANSFER_CONTINUES", "TRANSFER_RESULT"].first { content.contains($0) } ?? "none"
        let stop = assistant?["stopReason"]?.string ?? "none"
        let safeStop = ["stop", "toolUse", "error", "aborted", "length"].contains(stop) ? stop : "other"
        let errorPresent = assistant?["errorMessage"]?.string != nil
        var driver = "none"
        if let notice = frames.last(where: { $0["type"]?.string == "extension_ui_request" && $0["method"]?.string == "notify" &&
            $0["message"]?.string?.hasPrefix("knarr-transfer-fixture:") == true })?["message"]?.string,
           let metadata = try? JSONDecoder().decode(OMPJSON.self, from: Data(notice.dropFirst("knarr-transfer-fixture:".count).utf8)) {
            let role = metadata["role"]?.string ?? "other"
            let safeRole = ["user", "assistant", "toolResult"].contains(role) ? role : "other"
            let tool = metadata["selectedTool"]?.string ?? "none"
            let safeTool = ["transfer_to_main", "knarr_transfer_fixture_wait", "read", "none"].contains(tool) ? tool : "other"
            driver = "role=\(safeRole),marker=\(metadata["markerPresent"]?.bool == true),end=\(metadata["markerEndPresent"]?.bool == true),tool=\(safeTool)"
        }
        return "events=[\(eventTypes)] bridge=\(bridgeOperations().count) results=\(toolResults().count) assistantMarker=\(marker) stop=\(safeStop) assistantError=\(errorPresent) driver={\(driver)} readFailure=\(nativeReadFailure() ?? "none") timeline=[\(timeline.suffix(32).joined(separator: ";"))] bridgeTimeline=[\(bridgeTimeline.joined(separator: ";"))] rpcTimeline=[\(rpcTimeline.joined(separator: ";"))]"
    }
}

/// Records the real transport and models bounded app dispatch latency, not a larger deadline.
private actor TransferMainTracingRPC: StallariRPC {
    let base: any StallariRPC
    let trace: TransferRuntimeTrace
    private var lostReceiptRequestID: String?
    private(set) var didLoseReceiptAcknowledgement = false

    init(base: any StallariRPC, trace: TransferRuntimeTrace) { self.base = base; self.trace = trace }

    func loseReceiptAcknowledgement(for requestID: UUID) { lostReceiptRequestID = requestID.uuidString }

    func request(_ command: String, fields: [String: OMPJSON], timeout: Duration) async throws -> OMPJSON {
        await trace.recordRPC("request", command: command)
        do {
            let response = try await base.request(command, fields: fields, timeout: timeout)
            let receiptCount = command == "get_entries" ? response["data"]?["entries"]?.array?.filter {
                $0["type"]?.string == "custom_message" && $0["customType"]?.string == ProjectTransferProtocol.messageType
            }.count : nil
            await trace.recordRPC("response", command: response["command"]?.string ?? "", id: response["id"]?.string,
                                  receiptCount: receiptCount, success: response["success"]?.bool)
            if command == "get_entries", let lostReceiptRequestID,
               response["data"]?["entries"]?.array?.contains(where: {
                   $0["type"]?.string == "custom_message" && $0["customType"]?.string == ProjectTransferProtocol.messageType &&
                   $0["details"]?["requestMessageID"]?.string == lostReceiptRequestID
               }) == true {
                self.lostReceiptRequestID = nil
                didLoseReceiptAcknowledgement = true
                // The real recipient persisted the receipt, but the app loses this readback.
                throw OMPRPCError.notRunning
            }
            return response
        } catch {
            await trace.recordRPC("request-failed", command: command)
            throw error
        }
    }
    func send(_ command: String, fields: [String: OMPJSON]) async throws {
        if command == "extension_ui_response" {
            await trace.recordRPC("send", command: command, id: fields["id"]?.string, generation: fields["knarrRPCGeneration"]?.string)
            // Admission is acknowledged before the slash handler finishes its bridge call.
            // Keep that gap observable even on fast hosts; all replies still go to real OMP.
            try await Task.sleep(for: .milliseconds(50))
        }
        do {
            try await base.send(command, fields: fields)
            if command == "extension_ui_response" {
                await trace.recordRPC("sent", command: command, id: fields["id"]?.string, generation: fields["knarrRPCGeneration"]?.string)
            }
        } catch {
            await trace.recordRPC("send-failed", command: command, id: command == "extension_ui_response" ? fields["id"]?.string : nil)
            throw error
        }
    }
    func subscribe() async -> AsyncStream<OMPEvent> { await base.subscribe() }
    func shutdown(cancel: Bool) async -> OMPProcessExit { await base.shutdown(cancel: cancel) }
}

private struct TransferRuntimeTimeout: Error, CustomStringConvertible {
    let phase: String
    let sourceLocation: SourceLocation
    let diagnostics: String
    var description: String { "Project transfer timeout phase=\(phase) at \(sourceLocation): \(diagnostics)" }
}

/// Opt-in only: a checksum-pinned standalone runtime, local deterministic provider,
/// owned HOME/config/database/session roots, and no inherited authentication environment.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["KNARR_TRANSFER_OMP"] != nil))
@MainActor struct ProjectTransferRuntimeTests {
    private func safeDeliveryError(_ error: String?) -> String {
        switch error {
        case nil: "none"
        case ProjectTransfer.deliveryFailureMessage: "delivery-unconfirmed"
        case ProjectTransfer.unsupportedFailureMessage: "unsupported-bridge-or-extension"
        case "메인 전달 요청은 원본과 함께 보존돼요. 전달 상태에서 다시 시도할 수 있어요.": "connected-transfer-drain-failed"
        case "저장된 메인 전달이 미완료예요. 원본과 요청은 보존돼요.": "scheduled-transfer-drain-failed"
        case "전달 요청 응답을 보내지 못했어요. 저장된 전달 상태를 확인하고 같은 ID로 다시 시도해 주세요.": "bridge-input-response-send-failed"
        case "저장된 후속 전달이 미완료예요": "settled-followup-drain-failed"
        default: "other-redacted"
        }
    }
    private func until(phase: String = "condition", trace: TransferRuntimeTrace? = nil,
                       sourceLocation: SourceLocation = #_sourceLocation,
                       _ predicate: @MainActor () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(20)
        while try await !predicate() {
            guard ContinuousClock.now < deadline else {
                throw TransferRuntimeTimeout(phase: phase, sourceLocation: sourceLocation,
                    diagnostics: await trace?.diagnostics() ?? "no trace")
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
    private func idle(_ rpc: any StallariRPC, trace: TransferRuntimeTrace? = nil, phase: String = "idle",
                      sourceLocation: SourceLocation = #_sourceLocation) async throws {
        try await until(phase: phase, trace: trace, sourceLocation: sourceLocation) {
            let state = try await rpc.request("get_state", fields: [:], timeout: .seconds(5))["data"]
            return state?["isStreaming"]?.bool == false && state?["isSettled"]?.bool != false
        }
    }
    private func call(_ args: OMPJSON, rpc: any StallariRPC, trace: TransferRuntimeTrace,
                      sourceLocation: SourceLocation = #_sourceLocation) async throws -> OMPJSON {
        let count = await trace.toolResults().count
        let action = args["action"]?.string ?? "unknown"
        let phase = ["context", "enqueue", "retry"].contains(action) ? action : "unknown"
        let json = String(decoding: try JSONEncoder().encode(args), as: UTF8.self)
        _ = try await rpc.request("prompt", fields: ["message": .string("TRANSFER_TOOL " + json + "\nTRANSFER_TOOL_END")], timeout: .seconds(10))
        try await until(phase: "tool-result.\(phase)", trace: trace, sourceLocation: sourceLocation) { await trace.toolResults().count > count }
        try await idle(rpc, trace: trace, phase: "tool-settled.\(phase)", sourceLocation: sourceLocation)
        return try #require(await trace.toolResults().last)
    }
    private func admit(_ payload: OMPJSON, rpc: any StallariRPC) async throws {
        let encoded = try JSONEncoder().encode(payload).base64EncodedString()
        _ = try await rpc.request("prompt", fields: ["message": .string("/knarr-project-transfer-admit " + encoded)], timeout: .seconds(20))
    }
    private func receipts(_ rpc: any StallariRPC) async throws -> [OMPJSON] {
        let response = try await rpc.request("get_entries", fields: [:], timeout: .seconds(5))
        return try #require(response["data"]?["entries"]?.array).filter {
            $0["type"]?.string == "custom_message" && $0["customType"]?.string == ProjectTransferProtocol.messageType
        }
    }

    @Test func realToolBridgeDurableAdmissionRestartAndIdempotency() async throws {
        let base = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let root = base.appendingPathComponent("outputs/project-transfer-runtime").appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try await SQLiteKnarrRepository.open(at: root.appendingPathComponent("fixture.db"))
        let executable = try #require(ProcessInfo.processInfo.environment["KNARR_TRANSFER_OMP"])
        let installation = try OMPInstallation(executable: URL(fileURLWithPath: executable))
        let extensions = KnarrExtensions(root: root)
        let driver = base.appendingPathComponent("Tests/Fixtures/ProjectTransfer/driver.ts")
        let source = try String(contentsOf: base.appendingPathComponent("Sources/KnarrCore/Resources/stallari/project-transfer.ts"), encoding: .utf8)
        let environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": root.appendingPathComponent("home").path,
                           "PI_CODING_AGENT_DIR": root.appendingPathComponent("agent").path, "PI_CONFIG_DIR": root.appendingPathComponent("config").path]
        try await repository.saveProject(.init(id: "fixture-project", name: "전달 fixture", absolutePath: root.path))
        let thread = try await repository.createProjectConversation(projectID: "fixture-project")
        // Avoid unrelated startup handoff model turns; this fixture owns its source context.
        try await repository.markProjectHandoffDelivered(threadID: thread.id, at: .now)
        let launch: @Sendable (String) throws -> OMPLaunchConfiguration = { id in
            let folder = root.appendingPathComponent(id)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var config = try StallariTools.configuration(installation: installation, workingDirectory: folder,
                configurationFile: folder.appendingPathComponent("stallari.yml"), sessionDirectory: folder.appendingPathComponent("sessions"),
                environment: environment, extensions: extensions, projectID: id == thread.id ? "fixture-project" : nil, threadID: id)
            config.arguments += ["--trusted-extension", driver.path, "--model", "knarr-transfer-fixture/deterministic", "--thinking", "off"]
            return config
        }
        let sourceRPC = StallariRPCProcess(launch: { _ in try launch(thread.id) })
        let sourceSession = StallariSession(repository: repository, rpc: sourceRPC, hird: TestHird(), threadID: thread.id, extensions: extensions)
        let mainRPC = StallariRPCProcess(launch: { _ in try launch(ConversationThread.defaultID) })
        let mainTrace = TransferRuntimeTrace()
        let mainTransport = TransferMainTracingRPC(base: mainRPC, trace: mainTrace)
        let mainSession = StallariSession(repository: repository, rpc: mainTransport, hird: TestHird())
        let defaultsName = "knarr-transfer-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        let conversation = LiveConversation(repository: repository, session: sourceSession, rpc: sourceRPC, hird: TestHird(), threadID: thread.id, preferences: defaults)
        let sourceTrace = TransferRuntimeTrace()
        let sourceStream = await sourceRPC.subscribe(), mainStream = await mainRPC.subscribe()
        let sourceObserver = Task { for await event in sourceStream { await sourceTrace.add(event) } }
        let mainObserver = Task { for await event in mainStream { await mainTrace.add(event) } }
        var reopenedRPC: StallariRPCProcess?
        var reopenedSession: StallariSession?
        var reopenedObserver: Task<Void, Never>?
        var reopenedRepository: SQLiteKnarrRepository?
        do {
            _ = try await sourceSession.performTool("write_extension", arguments: .object(["name": .string("project-transfer.ts"), "source": .string(source)]))
            try await mainRPC.start(); try await mainSession.connect()
            try await sourceRPC.start(); try await conversation.connect()
            try await idle(sourceRPC, trace: sourceTrace, phase: "source-startup")
            try await idle(mainRPC, trace: mainTrace, phase: "main-startup")
            _ = try await mainRPC.request("prompt", fields: ["message": .string("/knarr-transfer-fixture-tools")], timeout: .seconds(5))
            _ = try await sourceRPC.request("prompt", fields: ["message": .string("/knarr-transfer-fixture-tools")], timeout: .seconds(5))
            let tools = try await sourceSession.checkToolExposure()
            #expect(tools.contains("transfer_to_main") && tools.contains(ProjectTransferProtocol.bridgeTool))
            let commands = try await mainRPC.request("get_available_commands", fields: [:], timeout: .seconds(5))
            #expect(commands["data"]?["commands"]?.array?.contains { $0["name"]?.string == ProjectTransferProtocol.admissionCommand } == true)
            let attachment = root.appendingPathComponent("saved-readable-attachment.txt")
            let attachmentContent = "KNARR_TRANSFER_NATIVE_READ_FIXTURE_47E6888F\nPersisted source attachment, not execution approval.\n"
            try Data(attachmentContent.utf8).write(to: attachment)
            var request = ChatItem(at: .now, kind: .user("PERSISTED_REQUEST_NOT_APPROVAL"))
            request.attachments = [attachment]
            let answer = ChatItem(at: .now, kind: .stallari("SAVED_ASSISTANT_CONTEXT", project: "fixture-project"))
            try await repository.appendChat(request, projectID: "fixture-project", threadID: thread.id)
            try await repository.appendChat(answer, projectID: "fixture-project", threadID: thread.id)
            // Replay the populated optional fields from the failed real conversation.
            let context = try await call(.object(["action": .string("context"), "summary": .string(""),
                "requestMessageID": .string(request.id.uuidString), "messageIDs": .array([]), "transferID": .string("")]),
                rpc: sourceRPC, trace: sourceTrace)
            #expect(context["details"]?["ok"]?.bool == true)
            #expect(context["details"]?["result"]?["originThreadID"]?.string == thread.id)
            #expect(context["details"]?["result"]?["messages"]?.array?.contains { $0["id"]?.string == request.id.uuidString && $0["text"]?.string == "PERSISTED_REQUEST_NOT_APPROVAL" } == true)
            // Within the 12000-character app policy, but deliberately beyond 16 KiB.
            let summary = "ASSISTANT_SUMMARY_NOT_APPROVAL\n" + String(repeating: "한", count: 7000)
            let queued = try await call(.object(["action": .string("enqueue"), "summary": .string(summary),
                "requestMessageID": .null, "messageIDs": .null, "transferID": .null]), rpc: sourceRPC, trace: sourceTrace)
            #expect(queued["details"]?["ok"]?.bool == true)
            let transfer = try #require(try await repository.projectTransfers().first)
            #expect(transfer.requestMessageID == request.id && transfer.requestText == "PERSISTED_REQUEST_NOT_APPROVAL")
            #expect(transfer.summary == summary)
            #expect(Set([request.id, answer.id]).isSubset(of: Set(transfer.messageIDs)))
            #expect(transfer.attachments == [.init(messageID: request.id, url: attachment)])
            #expect(transfer.deliveredAt == nil && transfer.lastError == nil)
            #expect(try await receipts(mainRPC).isEmpty)
            #expect(FileManager.default.fileExists(atPath: attachment.path))
            #expect(conversation.extensionQuestions.isEmpty)
            #expect(await sourceTrace.bridgeOperations() == ["context", "enqueue"])
            let explicit = try await call(.object(["action": .string("enqueue"), "summary": .string(transfer.summary),
                "requestMessageID": .string(request.id.uuidString),
                "messageIDs": .array(transfer.messageIDs.map { .string($0.uuidString) })]), rpc: sourceRPC, trace: sourceTrace)
            #expect(explicit["details"]?["ok"]?.bool == true)
            #expect(explicit["details"]?["result"]?["id"]?.string == transfer.id)
            let invalid = try await call(.object(["action": .string("enqueue")]), rpc: sourceRPC, trace: sourceTrace)
            #expect(invalid["details"]?["ok"]?.bool == false)
            let retried = try await call(.object(["action": .string("retry"), "transferID": .string(transfer.id),
                "summary": .null, "requestMessageID": .null, "messageIDs": .null]), rpc: sourceRPC, trace: sourceTrace)
            #expect(retried["details"]?["ok"]?.bool == true)
            #expect(try await repository.projectTransfers().count == 1)
            let rejected = try await call(.object(["action": .string("retry"), "transferID": .string("not-a-stored-transfer")]), rpc: sourceRPC, trace: sourceTrace)
            #expect(rejected["details"]?["ok"]?.bool == false)
            #expect(rejected["isError"]?.bool == true || rejected["details"]?["error"]?.string != nil)
            let payload = try ProjectTransferProtocol.payload(transfer, policy: .current)
            guard case .object(var forged) = payload, case .object(var details) = payload["details"] ?? .null else { throw StallariError.invalidArguments }
            details["originProjectID"] = .string("forged-project"); forged["details"] = .object(details)
            let priorErrors = await mainTrace.admissionErrors().count
            try await admit(.object(forged), rpc: mainRPC)
            try await until(phase: "forged-admission-error", trace: mainTrace) { await mainTrace.admissionErrors().count > priorErrors }
            #expect(await mainTrace.admissionErrors().last?.contains("provenance") == true)
            #expect(try await receipts(mainRPC).isEmpty)
            // Main busy is a pending state, not a delivery or approval. The fixture wait is bounded.
            let startsBeforeBusy = await mainTrace.agentStarts()
            _ = try await mainRPC.request("prompt", fields: ["message": .string("TRANSFER_HOLD")], timeout: .seconds(5))
            try await until(phase: "main-busy", trace: mainTrace) { try await mainRPC.request("get_state", fields: [:], timeout: .seconds(5))["data"]?["isStreaming"]?.bool == true }
            try await mainSession.deliverProjectTransfers()
            #expect(try await repository.projectTransfers().first?.deliveredAt == nil)
            try await idle(mainRPC, trace: mainTrace, phase: "main-busy-settled")
            // Exercise the app-owned recipient path: command admission -> get_entries -> delivered marker.
            try await mainSession.deliverProjectTransfers(retryFailed: true)
            try await until(phase: "main-receipt", trace: mainTrace) { try await receipts(mainRPC).count == 1 }
            // session_settled can own the concurrent drain; a receipt precedes the app marker.
            try await until(phase: "app-durable-delivery-marker", trace: mainTrace) {
                try await repository.projectTransfers().first?.deliveredAt != nil
            }
            #expect(try await repository.projectTransfers().first?.deliveredAt != nil)
            let firstReceipt = try #require(try await receipts(mainRPC).first)
            #expect(firstReceipt["details"] == payload["details"] && firstReceipt["content"] == payload["content"])
            #expect(firstReceipt["details"]?["attachments"]?.array?.first?["url"]?.string == attachment.absoluteString)
            #expect(firstReceipt["details"]?["attachments"]?.array?.first?["messageID"]?.string == request.id.uuidString)
            let starts = await mainTrace.agentStarts()
            #expect(starts == startsBeforeBusy + 1)
            try await admit(payload, rpc: mainRPC); try await admit(payload, rpc: mainRPC)
            #expect(try await receipts(mainRPC).count == 1)
            #expect(await mainTrace.agentStarts() == starts)
            // This explicit fixture model turn uses the existing native read tool, not the transfer bridge.
            // Its only selector is the durable receipt ID; the driver resolves the path from that receipt.
            try #require(try await mainSession.checkToolExposure().contains("read"), "Existing native read tool unavailable; no capability or approval bypass is permitted")
            let readCount = await mainTrace.toolResults("read").count
            _ = try await mainRPC.request("prompt", fields: ["message": .string("TRANSFER_READ_RECEIPT " + transfer.id + "\nTRANSFER_READ_RECEIPT_END")], timeout: .seconds(10))
            try await until(phase: "attachment-native-read", trace: mainTrace) {
                let observed = await mainTrace.toolResults("read").count > readCount
                let unavailable = await mainTrace.assistantContains("TRANSFER_ATTACHMENT_READ_UNAVAILABLE")
                let missing = await mainTrace.assistantContains("TRANSFER_ATTACHMENT_REFERENCE_MISSING")
                return observed || unavailable || missing
            }
            let readResult = try #require(await mainTrace.toolResults("read").last, "Native read unavailable or durable attachment reference missing; no fallback was attempted")
            let readFailure = await mainTrace.nativeReadFailure()
            try #require(readFailure == nil, "Existing native read failed; safe reason is captured by readFailure. No permission or approval was changed")
            #expect(readResult["content"]?.array?.contains { $0["text"]?.string?.contains("KNARR_TRANSFER_NATIVE_READ_FIXTURE_47E6888F") == true } == true)
            try await until(phase: "attachment-consumer-visible", trace: mainTrace) {
                let resultVisible = await mainTrace.assistantContains("TRANSFER_ATTACHMENT_READ_RESULT")
                let contentVisible = await mainTrace.assistantContains("KNARR_TRANSFER_NATIVE_READ_FIXTURE_47E6888F")
                return resultVisible && contentVisible
            }
            try await idle(mainRPC, trace: mainTrace, phase: "attachment-read-settled")
            #expect(try String(contentsOf: attachment, encoding: .utf8) == attachmentContent)
            #expect(try await repository.projectTransfers().first?.attachments == transfer.attachments)
            #expect(try await receipts(mainRPC).first?["details"] == firstReceipt["details"])
            let snapshot = try await repository.snapshot()
            #expect(snapshot.issues.isEmpty && snapshot.runs.isEmpty)
            // Lose the app acknowledgement only after a second real OMP receipt exists.
            // Its queue row must survive as pending and reconcile after both stores reopen.
            let secondRequest = ChatItem(at: .now, kind: .user("SECOND_PERSISTED_REQUEST_NOT_APPROVAL"))
            await mainTransport.loseReceiptAcknowledgement(for: secondRequest.id)
            try await repository.appendChat(secondRequest, projectID: "fixture-project", threadID: thread.id)
            let secondQueued = try await call(.object(["action": .string("enqueue"), "summary": .string("SECOND_SUMMARY_NOT_APPROVAL"),
                "requestMessageID": .string(secondRequest.id.uuidString), "messageIDs": .array([.string(secondRequest.id.uuidString)])]),
                rpc: sourceRPC, trace: sourceTrace)
            #expect(secondQueued["details"]?["ok"]?.bool == true)
            let secondTransfer = try #require(try await repository.projectTransfers().first { $0.requestMessageID == secondRequest.id })
            do { try await mainSession.deliverProjectTransfers() }
            catch { #expect(error as? OMPRPCError == .notRunning) }
            try await until(phase: "receipt-before-interrupted-app-ack", trace: mainTrace) {
                let lost = await mainTransport.didLoseReceiptAcknowledgement
                let count = try await receipts(mainRPC).count
                return lost && count == 2
            }
            let interrupted = try #require(try await repository.projectTransfers().first { $0.id == secondTransfer.id })
            #expect(interrupted.state == .pending && interrupted.deliveredAt == nil && interrupted.lastError == nil)
            #expect(try await repository.projectTransfers().first { $0.id == transfer.id }?.state == .delivered)
            let before = try await mainRPC.request("get_state", fields: [:], timeout: .seconds(5))["data"]?["sessionId"]
            let exit = await mainSession.shutdown()
            #expect(exit.remainingProcessIDs.isEmpty)
            let resumedRPC = StallariRPCProcess(launch: { _ in try launch(ConversationThread.defaultID) })
            let resumedRepository = try await SQLiteKnarrRepository.open(at: root.appendingPathComponent("fixture.db"))
            reopenedRepository = resumedRepository
            #expect(try await resumedRepository.projectTransfers().first { $0.id == secondTransfer.id }?.state == .pending)
            let resumedSession = StallariSession(repository: resumedRepository, rpc: resumedRPC, hird: TestHird())
            reopenedRPC = resumedRPC; reopenedSession = resumedSession
            let resumedTrace = TransferRuntimeTrace(), resumedStream = await resumedRPC.subscribe()
            reopenedObserver = Task { for await event in resumedStream { await resumedTrace.add(event) } }
            try await resumedRPC.start(); try await resumedSession.connect()
            #expect(try await resumedRPC.request("get_state", fields: [:], timeout: .seconds(5))["data"]?["sessionId"] == before)
            #expect(try await resumedRepository.projectTransfers().first { $0.id == secondTransfer.id }?.state == .delivered)
            #expect(try await receipts(resumedRPC).count == 2)
            try await admit(payload, rpc: resumedRPC)
            try await admit(ProjectTransferProtocol.payload(secondTransfer, policy: .current), rpc: resumedRPC)
            #expect(try await receipts(resumedRPC).count == 2)
            #expect(await resumedTrace.agentStarts() == 0)
            _ = try await resumedRPC.request("prompt", fields: ["message": .string("CONTINUE_TRANSFER_CONTEXT")], timeout: .seconds(10))
            try await until(phase: "restart-continuation", trace: resumedTrace) { await resumedTrace.assistantContains("TRANSFER_CONTINUES receipt=true") }
            try await idle(resumedRPC, trace: resumedTrace, phase: "restart-settled")
            #expect(try await receipts(resumedRPC).count == 2)
            let finalSnapshot = try await resumedRepository.snapshot()
            #expect(finalSnapshot.issues.isEmpty && finalSnapshot.runs.isEmpty)
            #expect((await resumedTrace.bridgeOperations()).contains("admission"))
            #expect((await sourceRPC.exits).allSatisfy { $0.remainingProcessIDs.isEmpty })
            print("Project transfer OMP 18.7.0: real tool/input/app bridge; saved refs; forged provenance rejected; pending while busy; durable receipt; lost app ack after real receipt; database/RPC restart reconciliation; idempotent; no approval/forced turn")
        } catch {
            await mainTrace.mark("failure.repository.sample")
            let transfers = try? await repository.projectTransfers()
            let savedTransfer = transfers?.first(where: { $0.deliveredAt == nil }) ?? transfers?.first
            let savedState = savedTransfer?.state.rawValue ?? (transfers == nil ? "repository-read-failed" : "no-record")
            let savedError = safeDeliveryError(savedTransfer?.lastError)
            let sessionError = safeDeliveryError(await mainSession.lastDeliveryError)
            let sessionEvents = await mainSession.observedEventTypes.suffix(32).joined(separator: ",")
            await mainTrace.mark("failure.get-state.send")
            let currentState = try? await mainRPC.request("get_state", fields: [:], timeout: .seconds(2))["data"]
            await mainTrace.mark("failure.get-state.finished")
            let streaming = currentState?["isStreaming"]?.bool.map(String.init) ?? "unknown"
            let compacting = currentState?["isCompacting"]?.bool.map(String.init) ?? "unknown"
            let settled = currentState?["isSettled"]?.bool.map(String.init) ?? "unknown"
            let pending = currentState?["pendingMessageCount"]?.integer.map(String.init) ?? "unknown"
            await mainTrace.mark("failure.get-entries.send")
            let entriesResponse = try? await mainRPC.request("get_entries", fields: [:], timeout: .seconds(2))
            await mainTrace.mark("failure.get-entries.finished")
            var receiptMatches = "unknown", receiptCount = 0
            if let savedTransfer, let expected = try? ProjectTransferProtocol.payload(savedTransfer, policy: .current),
               let entries = entriesResponse?["data"]?["entries"]?.array {
                let sameID = entries.filter { $0["type"]?.string == "custom_message" &&
                    $0["customType"]?.string == ProjectTransferProtocol.messageType && $0["details"]?["transferID"] == expected["transferID"] }
                receiptCount = sameID.count
                receiptMatches = String(!sameID.isEmpty && sameID.allSatisfy {
                    $0["details"] == expected["details"] && $0["content"] == expected["content"]
                })
            }
            print("Transfer failure persistence state=\(savedState) lastError=\(savedError) sessionError=\(sessionError) sessionEvents=[\(sessionEvents)]")
            print("Transfer failure live stateAvailable=\(currentState != nil) streaming=\(streaming) compacting=\(compacting) settled=\(settled) pending=\(pending) entriesAvailable=\(entriesResponse != nil) sameIDReceipts=\(receiptCount) receiptMatchesCanonical=\(receiptMatches)")
            print("Transfer failure source \(await sourceTrace.diagnostics())")
            print("Transfer failure main \(await mainTrace.diagnostics())")
            let sourceExit = await conversation.shutdown(), mainExit = await mainSession.shutdown()
            print("Transfer cleanup source status=\(sourceExit.status) reason=\(sourceExit.reason) remaining=\(sourceExit.remainingProcessIDs.count)")
            print("Transfer cleanup main status=\(mainExit.status) reason=\(mainExit.reason) remaining=\(mainExit.remainingProcessIDs.count)")
            #expect(sourceExit.remainingProcessIDs.isEmpty && mainExit.remainingProcessIDs.isEmpty)
            if let reopenedSession {
                let exit = await reopenedSession.shutdown()
                print("Transfer cleanup reopened-session status=\(exit.status) reason=\(exit.reason) remaining=\(exit.remainingProcessIDs.count)")
                #expect(exit.remainingProcessIDs.isEmpty)
            }
            if let reopenedRPC {
                let exit = await reopenedRPC.shutdown(cancel: true)
                print("Transfer cleanup reopened-rpc status=\(exit.status) reason=\(exit.reason) remaining=\(exit.remainingProcessIDs.count)")
                #expect(exit.remainingProcessIDs.isEmpty)
            }
            sourceObserver.cancel(); mainObserver.cancel(); reopenedObserver?.cancel()
            await sourceObserver.value; await mainObserver.value; await reopenedObserver?.value
            try? await reopenedRepository?.close()
            try? await repository.close(); defaults.removePersistentDomain(forName: defaultsName)
            try? FileManager.default.removeItem(at: root)
            throw error
        }
        let sourceExit = await conversation.shutdown(), mainExit = await mainSession.shutdown()
        #expect(sourceExit.remainingProcessIDs.isEmpty && mainExit.remainingProcessIDs.isEmpty)
        if let reopenedSession { #expect(await reopenedSession.shutdown().remainingProcessIDs.isEmpty) }
        sourceObserver.cancel(); mainObserver.cancel(); reopenedObserver?.cancel()
        await sourceObserver.value; await mainObserver.value; await reopenedObserver?.value
        try await reopenedRepository?.close()
        try await repository.close(); defaults.removePersistentDomain(forName: defaultsName)
        try FileManager.default.removeItem(at: root)
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test(arguments: [false, true]) func oldAppContractIsExplicitlyUnsupported(hostBridgePresent: Bool) async throws {
        let base = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let root = base.appendingPathComponent("outputs/project-transfer-runtime").appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let rpc = OMPRPCSession(), trace = TransferRuntimeTrace()
        let stream = await rpc.subscribe()
        let observer = Task { for await event in stream { await trace.add(event) } }
        do {
            let installation = try OMPInstallation(executable: URL(fileURLWithPath: #require(ProcessInfo.processInfo.environment["KNARR_TRANSFER_OMP"])))
            let environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": root.path,
                               "PI_CODING_AGENT_DIR": root.appendingPathComponent("agent").path, "PI_CONFIG_DIR": root.appendingPathComponent("config").path]
            var config = try StallariTools.configuration(installation: installation, workingDirectory: root,
                configurationFile: root.appendingPathComponent("stallari.yml"), sessionDirectory: root.appendingPathComponent("sessions"), environment: environment, threadID: UUID().uuidString)
            config.arguments += ["--trusted-extension", base.appendingPathComponent("Sources/KnarrCore/Resources/stallari/project-transfer.ts").path,
                                 "--trusted-extension", base.appendingPathComponent("Tests/Fixtures/ProjectTransfer/driver.ts").path,
                                 "--model", "knarr-transfer-fixture/deterministic", "--thinking", "off"]
            // Independent controls: absent actual tool despite advertised v1, or absent env despite actual tool.
            if hostBridgePresent { config.environment.removeValue(forKey: "KNARR_PROJECT_TRANSFER_BRIDGE") }
            try await rpc.start(config)
            _ = try await rpc.request("set_host_tools", fields: ["tools": .array(hostBridgePresent ? StallariTools.definitions : [])], timeout: .seconds(5))
            _ = try await rpc.request("prompt", fields: ["message": .string("/knarr-transfer-fixture-tools")], timeout: .seconds(5))
            let result = try await call(.object(["action": .string("context")]), rpc: rpc, trace: trace)
            #expect(result["details"]?["ok"]?.bool == false)
            #expect(result["details"]?["error"]?.string?.contains("unsupported:") == true)
            #expect(await trace.bridgeOperations().isEmpty)
            #expect(try await receipts(rpc).isEmpty)
            let exit = await rpc.shutdown()
            #expect(exit.remainingProcessIDs.isEmpty)
            observer.cancel(); await observer.value
            try FileManager.default.removeItem(at: root)
        } catch {
            print("Transfer failure unsupported \(await trace.diagnostics())")
            let exit = await rpc.shutdown(cancel: true)
            print("Transfer cleanup unsupported status=\(exit.status) reason=\(exit.reason) remaining=\(exit.remainingProcessIDs.count)")
            #expect(exit.remainingProcessIDs.isEmpty)
            observer.cancel(); await observer.value
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }
}
