import Foundation
import Testing
@testable import KnarrCore

/// Recipient storage survives transport replacement, like OMP's continued session.
private actor TransferRecipient {
    var entries: [OMPJSON] = []
    var admissions = 0
    func admit(_ payload: OMPJSON) {
        guard !entries.contains(where: { $0["details"]?["transferID"] == payload["transferID"] }) else { return }
        admissions += 1
        entries.append(.object(["type": .string("custom_message"), "customType": .string("knarr.project-transfer.v1"),
            "content": payload["content"] ?? .null, "details": payload["details"] ?? .null]))
    }
}
private actor TransferRPC: StallariRPC {
    let recipient: TransferRecipient
    var busy = false
    var offline = false
    var supported = true
    var loseAcknowledgement = false
    var busyAtAdmission = false
    private var buffers: [UUID: OMPEventBuffer] = [:]
    init(recipient: TransferRecipient = TransferRecipient()) { self.recipient = recipient }
    func configure(busy: Bool = false, offline: Bool = false, supported: Bool = true, loseAcknowledgement: Bool = false, busyAtAdmission: Bool = false) {
        self.busy = busy; self.offline = offline; self.supported = supported; self.loseAcknowledgement = loseAcknowledgement
        self.busyAtAdmission = busyAtAdmission
    }
    func request(_ command: String, fields: [String: OMPJSON], timeout: Duration) async throws -> OMPJSON {
        if offline { throw OMPRPCError.notRunning }
        if command == "get_state" {
            return .object(["data": .object(["isStreaming": .bool(busy), "isCompacting": .bool(false), "isSettled": .bool(!busy)])])
        }
        if command == "get_available_commands" {
            return .object(["data": .object(["commands": .array(supported ? [.object(["name": .string("knarr-project-transfer-admit")])] : [])])])
        }
        if command == "get_entries" { return .object(["data": .object(["entries": .array(await recipient.entries)])]) }
        if command == "prompt", let message = fields["message"]?.string,
           let encoded = message.split(separator: " ", maxSplits: 1).last,
           let bytes = Data(base64Encoded: String(encoded)) {
            if busyAtAdmission { busy = true; throw OMPRPCError.remoteFailure }
            let payload = try JSONDecoder().decode(OMPJSON.self, from: bytes)
            await recipient.admit(payload)
            if loseAcknowledgement { throw OMPRPCError.timedOut }
            let id = UUID().uuidString
            for buffer in buffers.values {
                buffer.offer(.frame(.object(["type": .string("prompt_result"), "id": .string(id), "status": .string("completed")])))
            }
            return .object(["id": .string(id), "success": .bool(true)])
        }
        throw StallariError.invalidArguments
    }
    func send(_ command: String, fields: [String: OMPJSON]) async throws {}
    func subscribe() -> AsyncStream<OMPEvent> {
        let id = UUID(), buffer = OMPEventBuffer()
        buffers[id] = buffer
        return AsyncStream(unfolding: { await buffer.next() }, onCancel: {
            buffer.cancel()
            Task { await self.removeSubscriber(id) }
        })
    }
    private func removeSubscriber(_ id: UUID) { buffers.removeValue(forKey: id)?.cancel() }
    func shutdown(cancel: Bool) async -> OMPProcessExit {
        buffers.values.forEach { $0.finish() }; buffers.removeAll()
        return .init(status: 0, reason: .normal, remainingProcessIDs: [])
    }
}

/// The RPC admission reply precedes the custom command's work. Advancing its
/// controlled event stream completes that work; no sleeps or model calls are used.
private actor DeferredTransferRPC: StallariRPC {
    let recipient: TransferRecipient
    let restartBeforeAcknowledgement: Bool
    private let events = OMPEventBuffer()
    private let promptID = "deferred-transfer-prompt"
    private var payload: OMPJSON?
    init(recipient: TransferRecipient, restartBeforeAcknowledgement: Bool = false) {
        self.recipient = recipient; self.restartBeforeAcknowledgement = restartBeforeAcknowledgement
    }
    func request(_ command: String, fields: [String: OMPJSON], timeout: Duration) async throws -> OMPJSON {
        switch command {
        case "get_state":
            return .object(["data": .object(["isStreaming": .bool(false), "isSettled": .bool(true)])])
        case "get_available_commands":
            return .object(["data": .object(["commands": .array([.object(["name": .string(ProjectTransferProtocol.admissionCommand)])])])])
        case "get_entries":
            return .object(["data": .object(["entries": .array(await recipient.entries)])])
        case "prompt":
            guard let message = fields["message"]?.string,
                  let encoded = message.split(separator: " ", maxSplits: 1).last,
                  let bytes = Data(base64Encoded: String(encoded)) else { throw StallariError.invalidArguments }
            payload = try JSONDecoder().decode(OMPJSON.self, from: bytes)
            // Both events can arrive before the caller resumes from request().
            events.offer(.frame(.object(["type": .string("prompt_result"), "id": .string("unrelated-prompt"), "status": .string("completed")])))
            events.offer(.frame(.object(restartBeforeAcknowledgement
                ? ["type": .string("knarr_rpc_restarting")]
                : ["type": .string("prompt_result"), "id": .string(promptID), "status": .string("completed")])))
            return .object(["id": .string(promptID), "success": .bool(true), "data": .object(["accepted": .bool(true)])])
        default: throw StallariError.invalidArguments
        }
    }
    private func nextEvent() async -> OMPEvent? {
        guard let event = await events.next() else { return nil }
        if case .frame(let frame) = event,
           frame["id"]?.string == promptID || frame["type"]?.string == "knarr_rpc_restarting",
           let payload {
            await recipient.admit(payload)
            self.payload = nil
        }
        return event
    }
    func subscribe() -> AsyncStream<OMPEvent> {
        AsyncStream(unfolding: { await self.nextEvent() }, onCancel: { [events] in events.cancel() })
    }
    func send(_ command: String, fields: [String: OMPJSON]) async throws {}
    func shutdown(cancel: Bool) async -> OMPProcessExit {
        events.finish()
        return .init(status: 0, reason: .normal, remainingProcessIDs: [])
    }
}

@Suite(.serialized) struct ProjectTransferSessionTests {
    private func queued(_ f: StallariFixture) async throws -> ProjectTransfer {
        let source = try await f.repository.createProjectConversation(projectID: "p")
        let request = ChatItem(at: .now, kind: .user("이 내용 메인으로 넘겨줘. 기존 승인 범위만 설명해 줘."))
        try await f.repository.appendChat(request, projectID: "p", threadID: source.id)
        return try await f.repository.enqueueProjectTransfer(id: "transfer-one", originThreadID: source.id,
            requestMessageID: request.id, summary: "프로젝트 진행사항 인계", messageIDs: [request.id])
    }
    @Test func promptAdmissionWaitsForMatchingCompletionBeforeReceiptReadback() async throws {
        let f = try await StallariFixture.make()
        let transfer = try await queued(f)
        let recipient = TransferRecipient()
        let main = StallariSession(repository: f.repository, rpc: DeferredTransferRPC(recipient: recipient), hird: f.hird)
        do {
            try await main.deliverProjectTransfers()
            let saved = try #require(try await f.repository.projectTransfers().first)
            #expect(saved.id == transfer.id && saved.state == .delivered && saved.lastError == nil)
            #expect(await recipient.admissions == 1)
            #expect(try await f.repository.snapshot().issues.isEmpty)
            #expect(try await f.repository.snapshot().runs.isEmpty)
            _ = await main.shutdown(); try await f.cleanup()
        } catch { _ = await main.shutdown(); try await f.cleanup(); throw error }
    }
    @Test func restartAfterDurableAdmissionBeforeCompletionKeepsPendingAndReconcilesOnce() async throws {
        let f = try await StallariFixture.make()
        let transfer = try await queued(f)
        let recipient = TransferRecipient()
        let first = StallariSession(repository: f.repository,
            rpc: DeferredTransferRPC(recipient: recipient, restartBeforeAcknowledgement: true), hird: f.hird)
        do {
            await #expect(throws: OMPRPCError.notRunning) { try await first.deliverProjectTransfers() }
            #expect(try await f.repository.projectTransfers().first?.state == .pending)
            #expect(await recipient.admissions == 1)
            _ = await first.shutdown()
            let reopened = try await SQLiteKnarrRepository.open(at: f.directory.appendingPathComponent("knarr.db"))
            let second = StallariSession(repository: reopened, rpc: TransferRPC(recipient: recipient), hird: f.hird)
            do {
                try await second.deliverProjectTransfers()
                #expect(try await reopened.projectTransfers().first?.id == transfer.id)
                #expect(try await reopened.projectTransfers().first?.state == .delivered)
                #expect(await recipient.admissions == 1)
                _ = await second.shutdown(); try await reopened.close()
            } catch { _ = await second.shutdown(); try await reopened.close(); throw error }
            try await f.cleanup()
        } catch { _ = await first.shutdown(); try await f.cleanup(); throw error }
    }
    @Test func busyAndOfflineMainKeepQueueUntilSupportedAdmission() async throws {
        let f = try await StallariFixture.make()
        let transfer = try await queued(f)
        let rpc = TransferRPC()
        let main = StallariSession(repository: f.repository, rpc: rpc, hird: f.hird)
        do {
            await rpc.configure(busy: true)
            try await main.deliverProjectTransfers()
            #expect(try await f.repository.projectTransfers().first?.state == .pending)
            #expect(await rpc.recipient.admissions == 0)
            await rpc.configure(offline: true)
            await #expect(throws: (any Error).self) { try await main.deliverProjectTransfers() }
            #expect(try await f.repository.projectTransfers().first?.deliveredAt == nil)
            #expect(try await f.repository.projectTransfers().first?.state == .pending)
            await rpc.configure(busyAtAdmission: true)
            try await main.deliverProjectTransfers()
            #expect(try await f.repository.projectTransfers().first?.state == .pending)
            #expect(await rpc.recipient.admissions == 0)
            await rpc.configure()
            try await main.deliverProjectTransfers()
            #expect(try await f.repository.projectTransfers().first?.id == transfer.id)
            #expect(try await f.repository.projectTransfers().first?.state == .delivered)
            #expect(await rpc.recipient.admissions == 1)
            #expect(try await f.repository.snapshot().runs.isEmpty)
            _ = await main.shutdown(); try await f.cleanup()
        } catch { _ = await main.shutdown(); try await f.cleanup(); throw error }
    }
    @Test func admissionAcknowledgementLossAndRestartDoNotDuplicateRecipientEffect() async throws {
        let f = try await StallariFixture.make()
        let transfer = try await queued(f)
        let recipient = TransferRecipient()
        let rpc = TransferRPC(recipient: recipient)
        let main = StallariSession(repository: f.repository, rpc: rpc, hird: f.hird)
        do {
            await rpc.configure(loseAcknowledgement: true)
            await #expect(throws: (any Error).self) { try await main.deliverProjectTransfers() }
            #expect(await recipient.admissions == 1)
            #expect(try await f.repository.projectTransfers().first?.deliveredAt == nil)
            #expect(try await f.repository.projectTransfers().first?.state == .pending)
            _ = await main.shutdown()
            let reopened = try await SQLiteKnarrRepository.open(at: f.directory.appendingPathComponent("knarr.db"))
            let second = StallariSession(repository: reopened, rpc: TransferRPC(recipient: recipient), hird: f.hird)
            do {
                try await second.deliverProjectTransfers()
                try await second.deliverProjectTransfers()
                #expect(try await reopened.projectTransfers().first?.id == transfer.id)
                #expect(try await reopened.projectTransfers().first?.state == .delivered)
                #expect(await recipient.admissions == 1)
                _ = await second.shutdown(); try await reopened.close()
            } catch { _ = await second.shutdown(); try await reopened.close(); throw error }
            try await f.cleanup()
        } catch { _ = await main.shutdown(); try await f.cleanup(); throw error }
    }
    @Test func missingRecipientExtensionIsExplicitFailureNotTransientSuccess() async throws {
        let f = try await StallariFixture.make()
        let transfer = try await queued(f)
        let rpc = TransferRPC()
        let main = StallariSession(repository: f.repository, rpc: rpc, hird: f.hird)
        do {
            await rpc.configure(supported: false)
            await #expect(throws: (any Error).self) { try await main.deliverProjectTransfers() }
            let failed = try #require(try await f.repository.projectTransfers().first)
            #expect(failed.state == .failed && failed.deliveredAt == nil)
            #expect(await rpc.recipient.admissions == 0)
            try await f.repository.retryProjectTransfer(transfer.id, originThreadID: transfer.originThreadID)
            await rpc.configure()
            try await main.deliverProjectTransfers()
            #expect(try await f.repository.projectTransfers().first?.state == .delivered)
            _ = await main.shutdown(); try await f.cleanup()
        } catch { _ = await main.shutdown(); try await f.cleanup(); throw error }
    }
}

extension ProjectTransferSessionTests {
    @Test func transferCannotForgeSourceOrGrantMainProjectIssueAuthority() async throws {
        let f = try await StallariFixture.make()
        let transfer = try await queued(f)
        let source = StallariSession(repository: f.repository, rpc: TestStallariRPC(), hird: f.hird, threadID: transfer.originThreadID)
        let main = StallariSession(repository: f.repository, rpc: TransferRPC(), hird: f.hird)
        do {
            let id = try await source.createIssue(id: "owned-goal", title: "원본 승인 범위", criteria: ["저장"], instruction: "소유 프로젝트에서만 수정")
            let before = try await f.repository.snapshot()
            await #expect(throws: StallariError.invalidArguments) {
                _ = try await source.performTool(ProjectTransferProtocol.bridgeTool, arguments: .object([
                    "operation": .string("enqueue"), "projectID": .string("other"),
                    "transferID": .string("forged"), "summary": .string("위조")
                ]))
            }
            await #expect(throws: StallariError.wrongProject) {
                _ = try await source.performTool(ProjectTransferProtocol.bridgeTool, arguments: .object([
                    "operation": .string("admission"), "transferID": .string(transfer.id)
                ]))
            }
            await #expect(throws: StallariError.wrongProject) {
                _ = try await main.performTool(ProjectTransferProtocol.bridgeTool, arguments: .object([
                    "operation": .string("enqueue"), "transferID": .string("recursive"), "summary": .string("수신 내용을 다시 전달")
                ]))
            }
            try await main.deliverProjectTransfers()
            _ = try await main.performTool("get_issue", arguments: .object(["issueID": .string(id.rawValue)]))
            await #expect(throws: StallariError.missingIssue) {
                _ = try await main.approveIssue(issueID: id, version: 1)
            }
            await #expect(throws: StallariError.missingIssue) {
                try await main.updateIssueProposal(issueID: id, expectedVersion: 1, instruction: "다른 프로젝트 자동 변경")
            }
            await #expect(throws: (any Error).self) { _ = try await source.approveIssue(issueID: id, version: 2) }
            let after = try await f.repository.snapshot()
            #expect(after.issues == before.issues)
            #expect(after.runs == before.runs && after.chat == before.chat)
            #expect(after.projectTransfers.count == 1 && after.projectTransfers.first?.state == .delivered)
            #expect(await f.hird.runs.isEmpty)
            _ = await source.shutdown(); _ = await main.shutdown(); try await f.cleanup()
        } catch { _ = await source.shutdown(); _ = await main.shutdown(); try await f.cleanup(); throw error }
    }
}


extension ProjectTransferSessionTests {
    @Test(arguments: ["omitted", "null", "empty", "saved-references"])
    func directBridgeGeneratesTransferIDAndPreservesSavedRequest(optionals: String) async throws {
        let f = try await StallariFixture.make()
        let thread = try await f.repository.createProjectConversation(projectID: "p")
        var context = ChatItem(at: .now, kind: .stallari("원본 시안과 요구사항", project: "p"))
        let attachment = f.directory.appendingPathComponent("reference.txt")
        try Data("saved attachment".utf8).write(to: attachment)
        context.attachments = [attachment]
        let request = ChatItem(at: .now, kind: .user("이 내용 메인으로 넘겨"))
        try await f.repository.appendChat(context, projectID: "p", threadID: thread.id)
        try await f.repository.appendChat(request, projectID: "p", threadID: thread.id)
        let source = StallariSession(repository: f.repository, rpc: TestStallariRPC(), hird: f.hird, threadID: thread.id)
        let recipient = TransferRecipient()
        let main = StallariSession(repository: f.repository, rpc: TransferRPC(recipient: recipient), hird: f.hird)
        var arguments: [String: OMPJSON] = ["operation": .string("enqueue"), "summary": .string("이슈 작성 요청과 시안")]
        if optionals == "null" || optionals == "saved-references" {
            arguments["transferID"] = .null
            arguments["requestMessageID"] = .null
            arguments["messageIDs"] = .null
        } else if optionals == "empty" {
            arguments["transferID"] = .string("")
            arguments["requestMessageID"] = .string("")
            arguments["messageIDs"] = .array([])
        }
        if optionals == "saved-references" {
            arguments["requestMessageID"] = .string(request.id.uuidString)
            arguments["messageIDs"] = .array([.string(context.id.uuidString), .string(request.id.uuidString)])
        }
        do {
            let saved = try await source.performTool(ProjectTransferProtocol.bridgeTool, arguments: .object(arguments))
            let transferID = try #require(saved["id"]?.string)
            #expect(UUID(uuidString: transferID) != nil)
            let repeated = try await source.performTool(ProjectTransferProtocol.bridgeTool, arguments: .object(arguments))
            #expect(repeated["id"] == saved["id"])
            let rows = try await f.repository.projectTransfers()
            let transfer = try #require(rows.first)
            #expect(rows.count == 1 && transfer.state == .pending)
            #expect(transfer.requestMessageID == request.id && transfer.requestText == "이 내용 메인으로 넘겨")
            #expect(Set(transfer.messageIDs) == Set([context.id, request.id]))
            #expect(transfer.attachments == [.init(messageID: context.id, url: attachment)])
            await #expect(throws: StallariError.invalidArguments) {
                _ = try await source.performTool(ProjectTransferProtocol.bridgeTool,
                    arguments: .object(["operation": .string("retry"), "transferID": .null]))
            }
            try await main.deliverProjectTransfers()
            try await main.deliverProjectTransfers()
            #expect(try await f.repository.projectTransfers().first?.state == .delivered)
            #expect(await recipient.admissions == 1)
            #expect(try await f.repository.snapshot().issues.isEmpty)
            #expect(try await f.repository.snapshot().runs.isEmpty)
            #expect(await f.hird.runs.isEmpty)
            _ = await source.shutdown(); _ = await main.shutdown(); try await f.cleanup()
        } catch { _ = await source.shutdown(); _ = await main.shutdown(); try await f.cleanup(); throw error }
    }

    @Test(arguments: ["transferID", "requestMessageID", "messageIDs"])
    func malformedOptionalBridgeFieldsStillFail(field: String) async throws {
        let f = try await StallariFixture.make()
        let thread = try await f.repository.createProjectConversation(projectID: "p")
        let request = ChatItem(at: .now, kind: .user("메인으로 전달"))
        try await f.repository.appendChat(request, projectID: "p", threadID: thread.id)
        let source = StallariSession(repository: f.repository, rpc: TestStallariRPC(), hird: f.hird, threadID: thread.id)
        var arguments: [String: OMPJSON] = ["operation": .string("enqueue"), "summary": .string("저장 내용")]
        arguments[field] = .number(42)
        do {
            await #expect(throws: StallariError.invalidArguments) {
                _ = try await source.performTool(ProjectTransferProtocol.bridgeTool, arguments: .object(arguments))
            }
            #expect(try await f.repository.projectTransfers().isEmpty)
            _ = await source.shutdown(); try await f.cleanup()
        } catch { _ = await source.shutdown(); try await f.cleanup(); throw error }
    }
}
