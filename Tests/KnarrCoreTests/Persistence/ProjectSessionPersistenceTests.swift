import Foundation
import Testing
@testable import KnarrCore

private struct ProjectSessionFixture {
    let directory: URL
    var url: URL { directory.appendingPathComponent("session.sqlite") }
    init() throws {
        let root = ProcessInfo.processInfo.environment["KNARR_TEST_FIXTURE_ROOT"] ?? NSTemporaryDirectory()
        directory = URL(fileURLWithPath: root).appendingPathComponent("knarr-project-session-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    func cleanup() { try? FileManager.default.removeItem(at: directory) }
    func seedProjectThread(id: String = "project-thread", projectID: String = "p") throws {
        let db = try SQLiteConnection(path: url.path, flags: 2)
        defer { try? db.close() }
        let payload = try JSONSerialization.data(withJSONObject: ["id": id, "name": "프로젝트", "createdAt": 0, "projectID": projectID])
        try db.execute("INSERT INTO threads(id,payload) VALUES(?,?)", [id, String(decoding: payload, as: UTF8.self)])
    }
}

@Suite(.serialized) struct ProjectSessionPersistenceTests {
    private let at = Date(timeIntervalSinceReferenceDate: 10)
    private func proposedIssue(_ id: KnarrCore.Issue.ID = "i", threadID: String = "issue-thread") -> KnarrCore.Issue {
        var issue = KnarrCore.Issue(id: id, title: "이슈", projectName: "프로젝트", state: .awaitingApproval,
            headline: "", detail: "", acceptance: [.init(text: "검사", state: .pending, evidence: "")], hirds: [], events: [], startedAt: at)
        issue.threadID = threadID
        issue.proposal = .init(instruction: "정확한 지시", model: "provider/model")
        return issue
    }
    private func seed(_ fixture: ProjectSessionFixture) async throws -> SQLiteKnarrRepository {
        let db = try await SQLiteKnarrRepository.open(at: fixture.url)
        try await db.saveProject(.init(id: "p", name: "프로젝트", absolutePath: fixture.directory.path))
        try await db.saveProject(.init(id: "other", name: "다른 프로젝트", absolutePath: fixture.directory.appendingPathComponent("other").path))
        try await db.close()
        try fixture.seedProjectThread()
        return try await SQLiteKnarrRepository.open(at: fixture.url)
    }
    private func ownedRun(_ db: SQLiteKnarrRepository) async throws -> PersistedRun {
        _ = try await db.approveIssueProposal(issueID: "i", version: 1, at: at)
        let run = PersistedRun(hird: .init(id: "r", name: "Hird", role: "정확한 지시", status: .working,
            steps: [], currentCommand: nil, lastActivityAt: at), issueID: "i", projectID: "p", ompSessionID: nil,
            ownershipToken: "owner-r", startedAt: at, mode: .change, requestedModel: "provider/model")
        _ = try await db.createApprovedRun(run, proposalVersion: 1)
        return run
    }

    @Test func missingProjectFieldDecodesLegacyAndProjectOwnershipRoundTrips() throws {
        let old = try JSONDecoder().decode(ConversationThread.self, from: Data(#"{"id":"default","name":"기본","createdAt":0}"#.utf8))
        #expect(old.issueID == nil && old.originThreadID == nil)
        #expect(old.projectID == nil && old.projectHandoffDeliveredAt == nil)
        let owned = try JSONDecoder().decode(ConversationThread.self, from: Data(#"{"id":"project-thread","name":"프로젝트","createdAt":0,"projectID":"p"}"#.utf8))
        let wire = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(owned)) as? [String: Any])
        #expect(wire["projectID"] as? String == "p")
    }

    @Test func concurrentCreationAcrossRepositoriesReturnsOnePersistentConversation() async throws {
        let fixture = try ProjectSessionFixture(); defer { fixture.cleanup() }
        let first = try await SQLiteKnarrRepository.open(at: fixture.url)
        try await first.saveProject(.init(id: "p", name: "프로젝트", absolutePath: fixture.directory.path))
        let second = try await SQLiteKnarrRepository.open(at: fixture.url)
        let threads = try await withThrowingTaskGroup(of: ConversationThread.self) { group in
            for index in 0..<24 {
                let repository = index.isMultiple(of: 2) ? first : second
                group.addTask { try await repository.createProjectConversation(projectID: "p", threadID: "candidate-\(index)") }
            }
            var result: [ConversationThread] = []
            for try await thread in group { result.append(thread) }
            return result
        }
        let thread = try #require(threads.first)
        #expect(threads.allSatisfy { $0 == thread })
        #expect(thread.projectID == "p" && thread.issueID == nil && thread.originThreadID == nil)
        #expect(try await first.snapshot().threads.filter { $0.projectID == "p" }.count == 1)
        #expect(try await first.createProjectConversation(projectID: "p", threadID: "different") == thread)
        await #expect(throws: PersistenceError.self) { try await first.createProjectConversation(projectID: "missing") }
        try await first.close(); try await second.close()
        let reopened = try await SQLiteKnarrRepository.open(at: fixture.url)
        #expect(try await reopened.createProjectConversation(projectID: "p") == thread)
        #expect(try await reopened.snapshot().threads.count == 2)
        try await reopened.close()
    }

    @Test func projectHandoffMarkerIsDurableIdempotentAndOnlyWritableThroughAdmissionAPI() async throws {
        let fixture = try ProjectSessionFixture(); defer { fixture.cleanup() }
        let db = try await seed(fixture)
        await #expect(throws: PersistenceError.self) { try await db.markProjectHandoffDelivered(threadID: "missing", at: at) }
        await #expect(throws: PersistenceError.self) { try await db.markProjectHandoffDelivered(threadID: "default", at: at) }
        try await db.markProjectHandoffDelivered(threadID: "project-thread", at: at)
        try await db.markProjectHandoffDelivered(threadID: "project-thread", at: at.addingTimeInterval(20))
        var thread = try #require(try await db.snapshot().threads.first { $0.id == "project-thread" })
        #expect(thread.projectHandoffDeliveredAt == at)
        thread.projectHandoffDeliveredAt = nil
        await #expect(throws: PersistenceError.self) { try await db.saveThread(thread) }
        thread.projectHandoffDeliveredAt = at
        thread.projectID = "other"
        await #expect(throws: PersistenceError.self) { try await db.saveThread(thread) }
        try await db.close()
        let reopened = try await SQLiteKnarrRepository.open(at: fixture.url)
        #expect(try await reopened.createProjectConversation(projectID: "p").projectHandoffDeliveredAt == at)
        try await reopened.close()
    }

    @Test func saveThreadCannotStripProjectOwnership() async throws {
        let fixture = try ProjectSessionFixture(); defer { fixture.cleanup() }
        let db = try await seed(fixture)
        let owned = try #require(try await db.snapshot().threads.first { $0.id == "project-thread" })
        let unowned = ConversationThread(id: owned.id, name: owned.name, createdAt: owned.createdAt)
        await #expect(throws: PersistenceError.self) { try await db.saveThread(unowned) }
        try await db.close()
    }

    @Test func saveThreadCannotCreateOrPromoteProjectOwnership() async throws {
        let fixture = try ProjectSessionFixture(); defer { fixture.cleanup() }
        let db = try await seed(fixture)
        try await db.saveThread(.init(id: "custom", name: "사용자 대화", createdAt: Date(timeIntervalSinceReferenceDate: 0)))
        for id in ["custom", "new-project-thread"] {
            let payload = try JSONSerialization.data(withJSONObject: ["id": id, "name": "사용자 대화", "createdAt": 0, "projectID": "p"])
            let forged = try JSONDecoder().decode(ConversationThread.self, from: payload)
            await #expect(throws: PersistenceError.self) { try await db.saveThread(forged) }
        }
        #expect(try await db.snapshot().threads.count == 3)
        try await db.close()
    }

    @Test func saveThreadCannotForgeProjectHandoffDeliveryMarker() async throws {
        let fixture = try ProjectSessionFixture(); defer { fixture.cleanup() }
        let db = try await seed(fixture)
        let payload = Data(#"{"id":"project-thread","name":"프로젝트","createdAt":0,"projectID":"p","projectHandoffDeliveredAt":10}"#.utf8)
        let forged = try JSONDecoder().decode(ConversationThread.self, from: payload)
        await #expect(throws: PersistenceError.self) { try await db.saveThread(forged) }
        try await db.close()
    }

    @Test func rejectsMissingForeignSelfAndNestedOriginsButKeepsLegacyCustomOrigins() async throws {
        let fixture = try ProjectSessionFixture(); defer { fixture.cleanup() }
        let db = try await seed(fixture)
        await #expect(throws: PersistenceError.self) {
            try await db.createIssueConversation(proposedIssue(), projectID: "other", originThreadID: "project-thread", handoffSummary: "인계")
        }
        await #expect(throws: PersistenceError.self) {
            try await db.createIssueConversation(proposedIssue(), projectID: "p", originThreadID: "missing", handoffSummary: "인계")
        }
        try await db.saveThread(.init(id: "custom", name: "이전 사용자 대화"))
        try await db.createIssueConversation(proposedIssue(), projectID: "p", originThreadID: "custom", handoffSummary: "인계")
        await #expect(throws: PersistenceError.self) {
            try await db.createIssueConversation(proposedIssue("nested", threadID: "nested-thread"), projectID: "p", originThreadID: "issue-thread", handoffSummary: "인계")
        }
        await #expect(throws: PersistenceError.self) {
            try await db.createIssueConversation(proposedIssue("self", threadID: "custom"), projectID: "p", originThreadID: "custom", handoffSummary: "인계")
        }
        #expect(try await db.snapshot().issues.count == 1)
        try await db.close()
    }

    @Test func projectConversationRejectsCrossProjectChatAndDirectIssueBinding() async throws {
        let fixture = try ProjectSessionFixture(); defer { fixture.cleanup() }
        let db = try await seed(fixture)
        await #expect(throws: PersistenceError.self) {
            try await db.appendChat(.init(at: at, kind: .user("다른 프로젝트")), projectID: "other", threadID: "project-thread")
        }
        await #expect(throws: PersistenceError.self) {
            try await db.saveIssue(proposedIssue(threadID: "project-thread"), projectID: "p")
        }
        #expect(try await db.snapshot().issues.isEmpty)
        #expect(try await db.snapshot().chat.isEmpty)
        try await db.close()
    }

    @Test func assistantAppendResolvesDurableMainProjectIssueAndLegacyOwners() async throws {
        let fixture = try ProjectSessionFixture(); defer { fixture.cleanup() }
        let db = try await seed(fixture)
        try await db.saveProject(.init(id: StoredProject.hubID, name: "Stallari", absolutePath: fixture.directory.path))
        try await db.saveThread(.init(id: "custom", name: "이전 사용자 대화"))
        try await db.createIssueConversation(proposedIssue(), projectID: "p", originThreadID: "project-thread", handoffSummary: "인계")
        var replies: [ChatItem] = []
        for threadID in ["default", "custom", "project-thread", "issue-thread"] {
            let item = ChatItem(at: at, kind: .stallari(threadID + " 답변", project: nil))
            replies.append(item)
            try await db.appendAssistantChat(item, threadID: threadID)
            try await db.appendAssistantChat(item, threadID: threadID)
            let snapshot = try await db.snapshot()
            #expect(snapshot.chat.filter { $0.id == item.id } == [item])
            let link = try #require(snapshot.chatLinks.first { $0.chatID == item.id })
            #expect(link.conversationThreadID == threadID)
            #expect(link.projectID == (["default", "custom"].contains(threadID) ? StoredProject.hubID : "p"))
            #expect(link.issueID == (threadID == "issue-thread" ? "i" : nil))
        }
        let missing = ChatItem(at: at, kind: .stallari("없는 대화에 저장하면 안 돼요", project: nil))
        await #expect(throws: PersistenceError.self) { try await db.appendAssistantChat(missing, threadID: "missing") }
        let first = try #require(replies.first)
        let collision = ChatItem(id: first.id, at: first.at, kind: .stallari("같은 UUID의 다른 본문", project: nil))
        await #expect(throws: PersistenceError.self) { try await db.appendAssistantChat(collision, threadID: "default") }
        try await db.close()
        let reopened = try await SQLiteKnarrRepository.open(at: fixture.url)
        let restored = try await reopened.snapshot()
        for item in replies { #expect(restored.chat.filter { $0.id == item.id } == [item]) }
        #expect(!restored.chat.contains { $0.id == missing.id })
        try await reopened.close()
    }

    @Test func handoffAndProposalRevisionRemainIssueOnly() async throws {
        let fixture = try ProjectSessionFixture(); defer { fixture.cleanup() }
        let db = try await seed(fixture)
        try await db.createIssueConversation(proposedIssue(), projectID: "p", originThreadID: "project-thread", handoffSummary: "인계")
        try await db.prepareIssueHandoff(threadID: "issue-thread")
        try await db.requestIssueProposalChanges(issueID: "i", version: 1, note: "이슈 대화에서만 수정")
        let deliveries = try await db.pendingThreadDeliveries(threadID: "issue-thread")
        #expect(deliveries.count == 2)
        #expect(deliveries.contains { if case .handoff = $0.kind { return true }; return false })
        #expect(deliveries.contains { if case .proposalRevision = $0.kind { return true }; return false })
        #expect(try await db.pendingThreadDeliveries(threadID: "project-thread").isEmpty)
        #expect(try await db.pendingThreadDeliveries(threadID: "default").isEmpty)
        try await db.close()
        let reopened = try await SQLiteKnarrRepository.open(at: fixture.url)
        #expect(try await reopened.pendingThreadDeliveries(threadID: "issue-thread").count == 2)
        try await reopened.close()
    }

    @Test func questionsAndStopsStayWithIssueWhileCardsUsePersistedState() async throws {
        let fixture = try ProjectSessionFixture(); defer { fixture.cleanup() }
        let db = try await seed(fixture)
        try await db.createIssueConversation(proposedIssue(), projectID: "p", originThreadID: "project-thread", handoffSummary: "인계")
        try await db.prepareIssueHandoff(threadID: "issue-thread")
        #expect(try await db.pendingThreadDeliveries(threadID: "project-thread").isEmpty)
        #expect(try await db.pendingThreadDeliveries(threadID: "default").isEmpty)
        let run = try await ownedRun(db)
        let question = PersistedQuestion(id: "q", runID: run.id, issueID: "i", prompt: "질문 전체", options: ["선택"], createdAt: at)
        let event = RunEvent(id: "ask", runID: run.id, sequence: 1, at: at, payload: .ask(question))
        #expect(try await db.apply(event) == .applied)
        #expect(try await db.apply(event) == .duplicate)
        #expect(try await db.pendingThreadDeliveries(threadID: "issue-thread").contains { $0.kind == .question("q") })
        #expect(try await db.snapshot().questions.first?.prompt == "질문 전체")
        #expect(try await db.pendingThreadDeliveries(threadID: "project-thread").isEmpty)
        #expect(try await db.pendingThreadDeliveries(threadID: "default").isEmpty)
        _ = try await db.cancelRun(run.id, at: at, reason: "중단 전체")
        _ = try await db.cancelRun(run.id, at: at, reason: "재시도")
        #expect(try await db.pendingThreadDeliveries(threadID: "project-thread").isEmpty)
        #expect(try await db.pendingThreadDeliveries(threadID: "default").isEmpty)
        try await db.close()
        let reopened = try await SQLiteKnarrRepository.open(at: fixture.url)
        #expect(try await reopened.pendingThreadDeliveries(threadID: "project-thread").isEmpty)
        #expect(try await reopened.pendingThreadDeliveries(threadID: "default").isEmpty)
        try await reopened.close()
    }

    private func accept(_ db: SQLiteKnarrRepository) async throws {
        let snapshot = try await db.snapshot(includeHistory: false)
        var issue = try #require(snapshot.issues.first)
        let run = try #require(snapshot.runs.last)
        issue.hirds = []; issue.events = []; issue.state = .done
        for index in issue.acceptance.indices {
            issue.acceptance[index].state = .met; issue.acceptance[index].evidence = "검사 근거"
        }
        try await db.saveIssue(issue, projectID: "p", expectedJudgementRun: run)
    }

    @Test func acceptedCompletionDeliversToProjectExactlyOnce() async throws {
        let fixture = try ProjectSessionFixture(); defer { fixture.cleanup() }
        let db = try await seed(fixture)
        try await db.createIssueConversation(proposedIssue(), projectID: "p", originThreadID: "project-thread", handoffSummary: "인계")
        let run = try await ownedRun(db)
        let summary = String(repeating: "완료 전체 ", count: 150)
        let result = RunResult(worktreePath: fixture.directory.path, branch: "hird/result", commit: "abc", diffPath: nil, summary: summary, verifications: [])
        let event = RunEvent(id: "complete", runID: run.id, sequence: 1, at: at, payload: .complete(result, notificationID: "notice"))
        #expect(try await db.apply(event) == .applied)
        #expect(try await db.apply(event) == .duplicate)
        #expect(try await db.pendingThreadDeliveries(threadID: "project-thread").isEmpty)
        try await accept(db); try await accept(db)
        #expect(try await db.pendingThreadDeliveries(threadID: "project-thread").map(\.id) == ["owner:hird-complete:notice"])
        #expect(try await db.pendingThreadDeliveries(threadID: "default").isEmpty)
        #expect(try await db.pendingThreadDeliveries(threadID: "project-thread").first?.kind == .completion(notificationID: "notice", summary: summary))
        #expect(try await db.pendingThreadDeliveries(threadID: "default").isEmpty)
        try await db.close()
        let reopened = try await SQLiteKnarrRepository.open(at: fixture.url)
        #expect(try await reopened.pendingThreadDeliveries(threadID: "project-thread").count == 1)
        #expect(try await reopened.pendingThreadDeliveries(threadID: "default").isEmpty)
        try await reopened.close()
    }

    @Test func runtimeMirrorLimitDoesNotTruncateProjectCompletion() async throws {
        let fixture = try ProjectSessionFixture(); defer { fixture.cleanup() }
        let db = try await seed(fixture)
        var object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(ProjectSessionPolicy.current)) as? [String: Any])
        object["mirrorMaximumCharacters"] = 7
        let policy = try ProjectSessionPolicy.decode(JSONSerialization.data(withJSONObject: object))
        await db.setProjectSessionPolicy(policy)
        try await db.createIssueConversation(proposedIssue(), projectID: "p", originThreadID: "project-thread", handoffSummary: "인계")
        let run = try await ownedRun(db)
        let summary = "완료 결과의 전체 내용은 프로젝트에 전달해요"
        let result = RunResult(worktreePath: fixture.directory.path, branch: "hird/result", commit: "abc", diffPath: nil, summary: summary, verifications: [])
        _ = try await db.apply(.init(id: "complete", runID: run.id, sequence: 1, at: at, payload: .complete(result, notificationID: "notice")))
        try await accept(db)
        #expect(try await db.pendingThreadDeliveries(threadID: "project-thread").first?.kind == .completion(notificationID: "notice", summary: summary))
        #expect(try await db.pendingThreadDeliveries(threadID: "default").isEmpty)
        try await db.close()
    }

    @Test func mainOwnedConversationDoesNotCreateModelMirrors() async throws {
        let fixture = try ProjectSessionFixture(); defer { fixture.cleanup() }
        let db = try await seed(fixture)
        try await db.createIssueConversation(proposedIssue(), projectID: "p", originThreadID: "default", handoffSummary: "인계")
        let run = try await ownedRun(db)
        let question = PersistedQuestion(id: "q", runID: run.id, issueID: "i", prompt: "질문", options: [], createdAt: at)
        _ = try await db.apply(.init(id: "ask", runID: run.id, sequence: 1, at: at, payload: .ask(question)))
        _ = try await db.cancelRun(run.id, at: at, reason: "중단")
        #expect(try await db.pendingThreadDeliveries(threadID: "default").isEmpty)
        #expect(try await db.pendingThreadDeliveries(threadID: "issue-thread").map(\.id) == ["hird-question:q", "hird-stopped:r"])
        #expect(try await db.pendingThreadDeliveries(threadID: "project-thread").isEmpty)
        try await db.close()
        let reopened = try await SQLiteKnarrRepository.open(at: fixture.url)
        #expect(try await reopened.pendingThreadDeliveries(threadID: "default").isEmpty)
        try await reopened.close()
    }

    @Test func reopeningRejectsForeignOwnerDeliveriesAndProjectChatLinks() async throws {
        for corruption in ["delivery", "chat"] {
            let fixture = try ProjectSessionFixture(); defer { fixture.cleanup() }
            let db = try await seed(fixture)
            try await db.createIssueConversation(proposedIssue(), projectID: "p", originThreadID: "project-thread", handoffSummary: "인계")
            try await db.appendChat(.init(at: at, kind: .user("프로젝트 문맥")), projectID: "p", threadID: "project-thread")
            try await db.close()
            let raw = try SQLiteConnection(path: fixture.url.path, flags: 2)
            if corruption == "delivery" {
                try fixture.seedProjectThread(id: "foreign-thread", projectID: "other")
                let delivery = ThreadDelivery(id: "owner:hird-stopped:forged", threadID: "foreign-thread", issueID: "i",
                    runID: nil, createdAt: at, kind: .stopped("잘못된 소유자"))
                let payload = String(decoding: try JSONEncoder().encode(delivery), as: UTF8.self)
                try raw.execute("INSERT INTO thread_deliveries(id,thread_id,issue_id,run_id,payload) VALUES(?,?,?,?,?)",
                    [delivery.id, delivery.threadID, "i", nil, payload])
            } else {
                try raw.execute("UPDATE chat SET project_id='other',payload=json_set(payload,'$.link.projectID','other') WHERE thread_id='project-thread'")
            }
            try raw.close()
            let before = try Data(contentsOf: fixture.url)
            await #expect(throws: PersistenceError.self) { try await SQLiteKnarrRepository.open(at: fixture.url) }
            #expect(try Data(contentsOf: fixture.url) == before)
        }
    }

    @Test func reopeningRejectsDuplicateMissingAndMixedProjectOwnership() async throws {
        for corruption in ["duplicate", "missing", "mixed", "default"] {
            let fixture = try ProjectSessionFixture(); defer { fixture.cleanup() }
            let db = try await seed(fixture)
            try await db.close()
            let raw = try SQLiteConnection(path: fixture.url.path, flags: 2)
            switch corruption {
            case "duplicate": try fixture.seedProjectThread(id: "second")
            case "missing": try raw.execute("UPDATE threads SET payload=json_set(payload,'$.projectID','missing') WHERE id='project-thread'")
            case "mixed": try raw.execute("UPDATE threads SET payload=json_set(payload,'$.issueID',json('{\"rawValue\":\"i\"}')) WHERE id='project-thread'")
            default: try raw.execute("UPDATE threads SET payload=json_set(payload,'$.projectID','p') WHERE id='default'")
            }
            try raw.close()
            let before = try Data(contentsOf: fixture.url)
            await #expect(throws: PersistenceError.self) { try await SQLiteKnarrRepository.open(at: fixture.url) }
            #expect(try Data(contentsOf: fixture.url) == before)
        }
    }
}
