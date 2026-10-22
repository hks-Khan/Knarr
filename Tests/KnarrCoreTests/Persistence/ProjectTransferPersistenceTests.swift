import Foundation
import Testing
@testable import KnarrCore

private struct TransferFixture: Sendable {
    let directory: URL
    let repository: SQLiteKnarrRepository
    let thread: ConversationThread
    let request: ChatItem
    let context: ChatItem
    var url: URL { directory.appendingPathComponent("transfer.sqlite") }
    static func make() async throws -> Self {
        let base = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let root = ProcessInfo.processInfo.environment["KNARR_TEST_FIXTURE_ROOT"] ?? base.appendingPathComponent("outputs/project-transfer-fixtures").path
        let directory = URL(fileURLWithPath: root).appendingPathComponent("knarr-transfer-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let repository = try await SQLiteKnarrRepository.open(at: directory.appendingPathComponent("transfer.sqlite"))
        try await repository.saveProject(.init(id: "p", name: "프로젝트 원래 이름", absolutePath: directory.path))
        try await repository.saveProject(.init(id: "other", name: "다른 프로젝트", absolutePath: directory.appendingPathComponent("other").path))
        try await repository.saveProject(.init(id: StoredProject.hubID, name: "Stallari", absolutePath: directory.path))
        let thread = try await repository.createProjectConversation(projectID: "p")
        let request = ChatItem(at: Date(timeIntervalSinceReferenceDate: 10), kind: .user("  메인에 이 내용을 전달해 주세요\n원문 보존  "))
        var context = ChatItem(at: Date(timeIntervalSinceReferenceDate: 11), kind: .stallari("함께 선택한 원본 문맥", project: "프로젝트 원래 이름"))
        let attachment = directory.appendingPathComponent("attachment.txt")
        try Data("원본 첨부".utf8).write(to: attachment)
        context.attachments = [attachment]
        try await repository.appendChat(request, projectID: "p", threadID: thread.id)
        try await repository.appendChat(context, projectID: "p", threadID: thread.id)
        return .init(directory: directory, repository: repository, thread: thread, request: request, context: context)
    }
    func enqueue(id: String = "transfer-1", summary: String = "사용자가 선택한 내용") async throws -> ProjectTransfer {
        try await repository.enqueueProjectTransfer(id: id, originThreadID: thread.id, requestMessageID: request.id,
            summary: summary, messageIDs: [request.id, context.id])
    }
    func issue() -> KnarrCore.Issue {
        var issue = KnarrCore.Issue(id: "issue", title: "이슈", projectName: "프로젝트 원래 이름", state: .awaitingApproval,
            headline: "", detail: "", acceptance: [], hirds: [], events: [], startedAt: Date(timeIntervalSinceReferenceDate: 12))
        issue.threadID = "issue-thread"
        issue.proposal = .init(instruction: "원본 목표", model: "provider/model")
        return issue
    }
}

@Suite(.serialized) struct ProjectTransferPersistenceTests {
    @Test func projectTransferBridgePersistsValidRequest() async throws {
        let f = try await StallariFixture.make()
        let thread = try await f.repository.createProjectConversation(projectID: "p")
        let request = ChatItem(at: Date(timeIntervalSinceReferenceDate: 10), kind: .user("이 내용을 메인으로 전달해 주세요"))
        try await f.repository.appendChat(request, projectID: "p", threadID: thread.id)
        let session = StallariSession(repository: f.repository, rpc: TestStallariRPC(), hird: f.hird, threadID: thread.id)
        do {
            _ = try await session.performTool("knarr_project_transfer_bridge_v1", arguments: .object([
                "operation": .string("enqueue"), "transferID": .string("transfer-1"),
                "requestMessageID": .string(request.id.uuidString), "summary": .string("사용자가 요청한 프로젝트 내용"),
                "messageIDs": .array([.string(request.id.uuidString)])
            ]))
            let snapshot = try await f.repository.snapshot()
            let transfers = try await f.repository.projectTransfers()
            #expect(transfers == snapshot.projectTransfers)
            #expect(transfers.count == 1)
            let transfer = try #require(transfers.first)
            #expect(transfer.id == "transfer-1")
            #expect(transfer.originThreadID == thread.id)
            #expect(transfer.requestMessageID == request.id)
            #expect(transfer.requestText == "이 내용을 메인으로 전달해 주세요")
            #expect(snapshot.issues.isEmpty)
            #expect(snapshot.chat == [request])
            _ = await session.shutdown(); try await f.cleanup()
        } catch {
            _ = await session.shutdown(); try await f.cleanup(); throw error
        }
    }

    @Test func roundTripPreservesSourceAndAttachmentsWithoutIssueOrMainMirror() async throws {
        let f = try await TransferFixture.make()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let before = try await f.repository.snapshot()
        let transfer = try await f.enqueue()
        #expect(transfer.originProjectID == "p" && transfer.originThreadID == f.thread.id)
        #expect(transfer.projectName == "프로젝트 원래 이름")
        #expect(transfer.requestText == "  메인에 이 내용을 전달해 주세요\n원문 보존  ")
        #expect(transfer.attachments == [.init(messageID: f.context.id, url: f.context.attachments[0])])
        #expect(transfer.state == .pending && transfer.recipientThreadID == ConversationThread.defaultID)
        let after = try await f.repository.snapshot()
        #expect(after.projectTransfers == [transfer])
        #expect(after.pendingDeliveryThreadIDs == [ConversationThread.defaultID])
        #expect(after.chat == before.chat && after.chatLinks == before.chatLinks)
        #expect(after.issues == before.issues && after.issues.isEmpty)
        #expect(try await f.repository.pendingThreadDeliveries(threadID: ConversationThread.defaultID).isEmpty)
        #expect(try Data(contentsOf: f.context.attachments[0]) == Data("원본 첨부".utf8))
        try await f.repository.close()
        let reopened = try await SQLiteKnarrRepository.open(at: f.url)
        #expect(try await reopened.projectTransfers() == [transfer])
        #expect(try await reopened.snapshot().projectTransfers == [transfer])
        #expect(try await reopened.snapshot().chat == before.chat)
        try await reopened.close()
    }

    @Test func duplicateIDsAndLogicalRequestsAreIdempotentButChangesConflict() async throws {
        let f = try await TransferFixture.make()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let first = try await f.enqueue()
        #expect(try await f.enqueue() == first)
        #expect(try await f.enqueue(id: "other-transfer-id") == first)
        #expect(try await f.repository.enqueueProjectTransfer(id: first.id, originThreadID: f.thread.id,
            requestMessageID: f.request.id, summary: first.summary, messageIDs: [f.context.id, f.request.id]) == first)
        await #expect(throws: PersistenceError.self) { _ = try await f.enqueue(summary: "같은 ID 다른 요약") }
        await #expect(throws: PersistenceError.self) { _ = try await f.enqueue(id: "different", summary: "같은 요청 다른 요약") }
        await #expect(throws: PersistenceError.self) {
            _ = try await f.repository.enqueueProjectTransfer(id: "different", originThreadID: f.thread.id,
                requestMessageID: f.request.id, summary: first.summary, messageIDs: [f.request.id])
        }
        let another = ChatItem(at: .now, kind: .user("별도의 명시 요청"))
        try await f.repository.appendChat(another, projectID: "p", threadID: f.thread.id)
        await #expect(throws: PersistenceError.self) {
            _ = try await f.repository.enqueueProjectTransfer(id: first.id, originThreadID: f.thread.id,
                requestMessageID: another.id, summary: first.summary, messageIDs: [another.id])
        }
        #expect(try await f.repository.projectTransfers() == [first])
        try await f.repository.close()
        let reopened = try await SQLiteKnarrRepository.open(at: f.url)
        #expect(try await reopened.enqueueProjectTransfer(id: "restart-id", originThreadID: f.thread.id,
            requestMessageID: f.request.id, summary: first.summary, messageIDs: [f.request.id, f.context.id]) == first)
        try await reopened.close()
    }

    @Test func failureRetryAndDeliveryAreDurableAndOnlyPendingWakesMain() async throws {
        let f = try await TransferFixture.make()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let first = try await f.enqueue()
        try await f.repository.failProjectTransfer(first.id, unsupported: true)
        var snapshot = try await f.repository.snapshot()
        #expect(snapshot.projectTransfers.first?.state == .failed)
        #expect(snapshot.projectTransfers.first?.lastError == ProjectTransfer.unsupportedFailureMessage)
        #expect(snapshot.pendingDeliveryThreadIDs.isEmpty)
        try await f.repository.close()
        let reopened = try await SQLiteKnarrRepository.open(at: f.url)
        #expect(try await reopened.projectTransfers().first?.state == .failed)
        await #expect(throws: PersistenceError.self) {
            try await reopened.retryProjectTransfer(first.id, originThreadID: ConversationThread.defaultID)
        }
        try await reopened.retryProjectTransfer(first.id, originThreadID: f.thread.id)
        snapshot = try await reopened.snapshot()
        #expect(snapshot.projectTransfers.first?.state == .pending)
        #expect(snapshot.pendingDeliveryThreadIDs == [ConversationThread.defaultID])
        try await reopened.failProjectTransfer(first.id)
        #expect(try await reopened.projectTransfers().first?.lastError == ProjectTransfer.deliveryFailureMessage)
        try await reopened.retryProjectTransfer(first.id, originThreadID: f.thread.id)
        let deliveredAt = Date(timeIntervalSinceReferenceDate: 100)
        try await reopened.markProjectTransferDelivered(first.id, at: deliveredAt)
        try await reopened.markProjectTransferDelivered(first.id, at: deliveredAt.addingTimeInterval(1))
        try await reopened.failProjectTransfer(first.id)
        try await reopened.retryProjectTransfer(first.id, originThreadID: f.thread.id)
        snapshot = try await reopened.snapshot()
        #expect(snapshot.projectTransfers.first?.state == .delivered)
        #expect(snapshot.projectTransfers.first?.deliveredAt == deliveredAt)
        #expect(snapshot.projectTransfers.first?.lastError == nil)
        #expect(snapshot.pendingDeliveryThreadIDs.isEmpty)
        try await reopened.close()
        let final = try await SQLiteKnarrRepository.open(at: f.url)
        #expect(try await final.snapshot().projectTransfers == snapshot.projectTransfers)
        try await final.close()
    }

    @Test func rejectsUnownedIssueForeignAndArchivedSourcesAndInvalidReferences() async throws {
        let f = try await TransferFixture.make()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let db = f.repository
        let other = try await db.createProjectConversation(projectID: "other")
        let hub = try await db.createProjectConversation(projectID: StoredProject.hubID)
        try await db.saveThread(.init(id: "custom", name: "사용자 대화"))
        try await db.createIssueConversation(f.issue(), projectID: "p", originThreadID: f.thread.id, handoffSummary: "이슈 인계")
        for source in [ConversationThread.defaultID, "custom", "missing", "issue-thread", other.id, hub.id] {
            await #expect(throws: PersistenceError.self) {
                _ = try await db.enqueueProjectTransfer(id: "bad", originThreadID: source, requestMessageID: f.request.id,
                    summary: "전달", messageIDs: [f.request.id])
            }
        }
        for refs in [[], [f.context.id], [f.request.id, f.request.id], [f.request.id, UUID()]] {
            await #expect(throws: PersistenceError.self) {
                _ = try await db.enqueueProjectTransfer(id: "bad", originThreadID: f.thread.id, requestMessageID: f.request.id,
                    summary: "전달", messageIDs: refs)
            }
        }
        await #expect(throws: PersistenceError.self) {
            _ = try await db.enqueueProjectTransfer(id: "bad", originThreadID: f.thread.id, requestMessageID: f.context.id,
                summary: "전달", messageIDs: [f.context.id])
        }
        let foreign = ChatItem(at: .now, kind: .user("다른 프로젝트 요청"))
        try await db.appendChat(foreign, projectID: "other", threadID: other.id)
        await #expect(throws: PersistenceError.self) {
            _ = try await db.enqueueProjectTransfer(id: "bad", originThreadID: f.thread.id, requestMessageID: f.request.id,
                summary: "전달", messageIDs: [f.request.id, foreign.id])
        }
        var remote = ChatItem(at: .now, kind: .user("웹 첨부"))
        remote.attachments = [try #require(URL(string: "https://example.invalid/not-a-file"))]
        try await db.appendChat(remote, projectID: "p", threadID: f.thread.id)
        await #expect(throws: PersistenceError.self) {
            _ = try await db.enqueueProjectTransfer(id: "bad", originThreadID: f.thread.id, requestMessageID: remote.id,
                summary: "전달", messageIDs: [remote.id])
        }
        for summary in [" \n", String(repeating: "가", count: ProjectSessionPolicy.current.handoffMaximumCharacters + 1)] {
            await #expect(throws: PersistenceError.self) { _ = try await f.enqueue(summary: summary) }
        }
        #expect(try await db.projectTransfers().isEmpty)
        try await db.saveProject(.init(id: "p", name: "프로젝트 원래 이름", absolutePath: f.directory.path, archivedAt: .now))
        await #expect(throws: PersistenceError.self) { _ = try await f.enqueue() }
        try await db.close()
    }
    @Test(arguments: ["origin-project", "origin-thread", "request-text", "attachment-path", "attachment-message", "reference-list", "reference-index", "unsafe-error", "source-link"])
    func forgedStoredProvenanceIsRejectedWithoutChangingOriginal(kind: String) async throws {
        let f = try await TransferFixture.make()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let transfer = try await f.enqueue()
        try await f.repository.close()
        let raw = try SQLiteConnection(path: f.url.path, flags: 2)
        let encoded = try JSONEncoder().encode(transfer)
        var wire = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        switch kind {
        case "origin-project":
            wire["originProjectID"] = "other"
            try raw.execute("UPDATE project_transfers SET project_id='other'")
        case "origin-thread":
            wire["originThreadID"] = ConversationThread.defaultID
            try raw.execute("UPDATE project_transfers SET thread_id='default'")
        case "request-text": wire["requestText"] = "위조한 사용자 요청"
        case "attachment-path":
            var references = try #require(wire["attachments"] as? [[String: Any]])
            references[0]["url"] = f.directory.appendingPathComponent("not-selected-secret.txt").absoluteString
            wire["attachments"] = references
        case "attachment-message":
            var references = try #require(wire["attachments"] as? [[String: Any]])
            references[0]["messageID"] = f.request.id.uuidString
            wire["attachments"] = references
        case "reference-list": wire["messageIDs"] = [f.request.id.uuidString, UUID().uuidString]
        case "reference-index": try raw.execute("DELETE FROM project_transfer_messages WHERE message_id=?", [f.context.id.uuidString])
        case "unsafe-error": wire["lastError"] = "raw NSError with credential-like private detail"
        default:
            try raw.execute("UPDATE chat SET payload=json_set(payload,'$.link.projectID','other') WHERE id=?", [f.request.id.uuidString])
        }
        let payload = String(decoding: try JSONSerialization.data(withJSONObject: wire), as: UTF8.self)
        try raw.execute("UPDATE project_transfers SET payload=?", [payload])
        try raw.close()
        let original = try Data(contentsOf: f.url)
        await #expect(throws: PersistenceError.self) { _ = try await SQLiteKnarrRepository.open(at: f.url) }
        #expect(try Data(contentsOf: f.url) == original)
    }

    @Test func foreignKeysProtectRequestSelectedMessagesAndSourceOwnership() async throws {
        let f = try await TransferFixture.make()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let transfer = try await f.enqueue()
        let raw = try SQLiteConnection(path: f.url.path, flags: 2)
        try raw.execute("PRAGMA foreign_keys=ON")
        #expect(throws: PersistenceError.self) { try raw.execute("DELETE FROM chat WHERE id=?", [f.request.id.uuidString]) }
        #expect(throws: PersistenceError.self) { try raw.execute("DELETE FROM chat WHERE id=?", [f.context.id.uuidString]) }
        #expect(throws: PersistenceError.self) { try raw.execute("DELETE FROM threads WHERE id=?", [f.thread.id]) }
        #expect(throws: PersistenceError.self) { try raw.execute("UPDATE project_transfers SET project_id='missing' WHERE id=?", [transfer.id]) }
        #expect(throws: PersistenceError.self) {
            try raw.execute("INSERT INTO project_transfer_messages(transfer_id,message_id,ordinal) VALUES(?,?,?)",
                [transfer.id, UUID().uuidString, "10"])
        }
        #expect(try raw.rows("PRAGMA foreign_key_check").isEmpty)
        try raw.close()
        try await f.repository.close()
    }

    @Test func concurrentRepositoriesDeduplicateTheSameLogicalRequest() async throws {
        let f = try await TransferFixture.make()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let second = try await SQLiteKnarrRepository.open(at: f.url)
        let records = try await withThrowingTaskGroup(of: ProjectTransfer.self) { group in
            for index in 0..<8 {
                let repository = index.isMultiple(of: 2) ? f.repository : second
                group.addTask {
                    try await repository.enqueueProjectTransfer(id: "candidate-\(index)", originThreadID: f.thread.id,
                        requestMessageID: f.request.id, summary: "같은 명시 요청", messageIDs: [f.request.id, f.context.id])
                }
            }
            var values: [ProjectTransfer] = []
            for try await value in group { values.append(value) }
            return values
        }
        #expect(Set(records).count == 1)
        #expect(try await f.repository.projectTransfers().count == 1)
        try await f.repository.close(); try await second.close()
    }

    @Test func historicalNamesAndPolicyLimitsDoNotInvalidateStoredRequests() async throws {
        let f = try await TransferFixture.make()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let transfer = try await f.enqueue()
        var policyWire = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(ProjectSessionPolicy.current)) as? [String: Any])
        policyWire["handoffMaximumCharacters"] = 2
        let policy = try ProjectSessionPolicy.decode(JSONSerialization.data(withJSONObject: policyWire))
        await f.repository.setProjectSessionPolicy(policy)
        await #expect(throws: PersistenceError.self) { _ = try await f.enqueue(summary: "세글자") }
        #expect(try await f.repository.snapshot().projectTransfers == [transfer])
        try await f.repository.saveProject(.init(id: "p", name: "나중에 바꾼 이름", absolutePath: f.directory.path, archivedAt: .now))
        try await f.repository.close()
        let reopened = try await SQLiteKnarrRepository.open(at: f.url)
        #expect(try await reopened.projectTransfers() == [transfer])
        await #expect(throws: PersistenceError.self) { try await reopened.retryProjectTransfer(transfer.id, originThreadID: f.thread.id) }
        try await reopened.close()
    }

    @Test(arguments: [1, 2, 3, 4])
    func oldSchemasMigrateToTransferOutboxWithoutChangingSourcePayloads(version: Int) async throws {
        let base = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let root = ProcessInfo.processInfo.environment["KNARR_TEST_FIXTURE_ROOT"] ?? base.appendingPathComponent("outputs/project-transfer-fixtures").path
        let directory = URL(fileURLWithPath: root).appendingPathComponent("knarr-transfer-migration-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("legacy.sqlite")
        try makeTransferLegacyFixture(at: url, version: version)
        let raw = try SQLiteConnection(path: url.path, flags: 1)
        let originalChat = try raw.rows("SELECT id,project_id,payload FROM chat")
        try raw.close()
        let db = try await SQLiteKnarrRepository.open(at: url)
        let snapshot = try await db.snapshot()
        #expect(snapshot.projectTransfers.isEmpty)
        #expect(snapshot.chat.first?.kind == .user("원문 · 첨부"))
        #expect(snapshot.chat.first?.attachments == [URL(fileURLWithPath: "/tmp/legacy.txt")])
        try await db.close()
        let migrated = try SQLiteConnection(path: url.path, flags: 1)
        #expect(try migrated.rows("PRAGMA user_version") == [["8"]])
        #expect(try migrated.rows("PRAGMA foreign_key_check").isEmpty)
        #expect(try migrated.rows("SELECT COUNT(*) FROM project_transfers") == [["0"]])
        #expect(try migrated.rows("SELECT COUNT(*) FROM milestones") == [["0"]])
        #expect(try migrated.rows("SELECT COUNT(*) FROM project_weeks") == [["0"]])
        if version != 1 { #expect(try migrated.rows("SELECT id,project_id,payload FROM chat") == originalChat) }
        try migrated.close()
        let reopened = try await SQLiteKnarrRepository.open(at: url)
        #expect(try await reopened.snapshot() == snapshot)
        try await reopened.close()
    }

    @Test func recipientBoundsRejectOversizedIdentifiersReferencesAndAttachments() async throws {
        let f = try await TransferFixture.make()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        for id in [String(repeating: "a", count: 257), String(repeating: "가", count: 86)] {
            await #expect(throws: PersistenceError.self) { _ = try await f.enqueue(id: id) }
        }
        var references = [f.request.id]
        for index in 0..<100 {
            let message = ChatItem(at: .now, kind: .stallari("참조 \(index)", project: nil))
            try await f.repository.appendChat(message, projectID: "p", threadID: f.thread.id)
            references.append(message.id)
        }
        await #expect(throws: PersistenceError.self) {
            _ = try await f.repository.enqueueProjectTransfer(id: "too-many-references", originThreadID: f.thread.id,
                requestMessageID: f.request.id, summary: "전달", messageIDs: references)
        }
        var attached = ChatItem(at: .now, kind: .user("첨부 전달 요청"))
        attached.attachments = Array(repeating: f.context.attachments[0], count: 101)
        try await f.repository.appendChat(attached, projectID: "p", threadID: f.thread.id)
        await #expect(throws: PersistenceError.self) {
            _ = try await f.repository.enqueueProjectTransfer(id: "too-many-attachments", originThreadID: f.thread.id,
                requestMessageID: attached.id, summary: "전달", messageIDs: [attached.id])
        }
        let accepted = try await f.repository.enqueueProjectTransfer(id: String(repeating: "a", count: 256),
            originThreadID: f.thread.id, requestMessageID: f.request.id, summary: "전달",
            messageIDs: Array(references.prefix(100)))
        #expect(accepted.id.utf8.count == 256 && accepted.messageIDs.count == 100)
        var boundedAttachment = ChatItem(at: .now, kind: .user("100개 첨부 전달 요청"))
        boundedAttachment.attachments = Array(repeating: f.context.attachments[0], count: 100)
        try await f.repository.appendChat(boundedAttachment, projectID: "p", threadID: f.thread.id)
        let attachmentTransfer = try await f.repository.enqueueProjectTransfer(id: "bounded-attachments", originThreadID: f.thread.id,
            requestMessageID: boundedAttachment.id, summary: "전달", messageIDs: [boundedAttachment.id])
        #expect(attachmentTransfer.attachments.count == 100)
        #expect(try await f.repository.projectTransfers() == [accepted, attachmentTransfer])
        try await f.repository.close()
    }

    @Test func transferMigrationFailureRollsBackSchemaAndVersion() async throws {
        let base = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let root = ProcessInfo.processInfo.environment["KNARR_TEST_FIXTURE_ROOT"] ?? base.appendingPathComponent("outputs/project-transfer-fixtures").path
        let directory = URL(fileURLWithPath: root).appendingPathComponent("knarr-transfer-rollback-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("legacy.sqlite")
        try makeTransferLegacyFixture(at: url, version: 4)
        let writer = try SQLiteConnection(path: url.path, flags: 2)
        try writer.execute("CREATE TABLE project_transfer_messages (fixture TEXT)")
        let originalChat = try writer.rows("SELECT payload FROM chat")
        try writer.close()
        await #expect(throws: PersistenceError.self) { _ = try await SQLiteKnarrRepository.open(at: url) }
        let after = try SQLiteConnection(path: url.path, flags: 1)
        #expect(try after.rows("PRAGMA user_version") == [["4"]])
        #expect(try after.rows("SELECT name FROM sqlite_master WHERE name='project_transfers'").isEmpty)
        #expect(try after.rows("SELECT payload FROM chat") == originalChat)
        try after.close()
    }
}

/// Frozen v2 wire fixture with explicit historical schema changes, not current schema generation.
func makeTransferLegacyFixture(at url: URL, version: Int) throws {
    try makeThreadV2Fixture(at: url)
    let raw = try SQLiteConnection(path: url.path, flags: 2)
    defer { try? raw.close() }
    if version == 1 {
        // Match production migration: native SQLite's legacy ALTER mode otherwise leaves
        // child REFERENCES clauses pointing to the now-missing `issues` table.
        try raw.execute("PRAGMA legacy_alter_table=OFF")
        try raw.execute("ALTER TABLE issues RENAME TO things")
        for table in ["runs", "chat", "activities", "questions"] {
            try raw.execute("ALTER TABLE \(table) RENAME COLUMN issue_id TO thing_id")
        }
        try raw.execute("DROP INDEX runs_issue")
        try raw.execute("CREATE INDEX runs_thing ON runs(thing_id)")
        let payload = try #require(try raw.rows("SELECT payload FROM chat").first?.first)
        try raw.execute("UPDATE chat SET payload=?", [payload.replacingOccurrences(of: "\"issueID\"", with: "\"thingID\"")])
        try raw.execute("PRAGMA user_version=1")
    } else if version >= 3 {
        try raw.execute("CREATE TABLE threads (id TEXT PRIMARY KEY NOT NULL,payload TEXT NOT NULL)")
        try raw.execute("INSERT INTO threads VALUES('default',?)", [#"{"id":"default","name":"기본","createdAt":-978307200}"#])
        for table in ["issues", "chat"] {
            try raw.execute("ALTER TABLE \(table) ADD COLUMN thread_id TEXT NOT NULL DEFAULT 'default' REFERENCES threads(id)")
        }
        try raw.execute("CREATE TABLE thread_deliveries (id TEXT PRIMARY KEY NOT NULL,thread_id TEXT NOT NULL REFERENCES threads(id),issue_id TEXT NOT NULL REFERENCES issues(id),run_id TEXT REFERENCES runs(id),payload TEXT NOT NULL)")
        try raw.execute("PRAGMA user_version=3")
        if version == 4 {
            try raw.execute("CREATE TABLE run_verifications (id TEXT PRIMARY KEY NOT NULL,payload TEXT NOT NULL)")
            try raw.execute("CREATE TABLE run_results (id TEXT PRIMARY KEY NOT NULL,payload TEXT NOT NULL)")
            try raw.execute("CREATE TABLE run_result_history (run_id TEXT NOT NULL REFERENCES runs(id),ordinal INTEGER NOT NULL CHECK(ordinal>=0),result_id TEXT NOT NULL REFERENCES run_results(id),PRIMARY KEY(run_id,ordinal))")
            try raw.execute("PRAGMA user_version=4")
        }
    }
}
