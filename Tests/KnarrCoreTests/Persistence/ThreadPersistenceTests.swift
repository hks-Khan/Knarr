import Foundation
import Testing
@testable import KnarrCore

/// Frozen v2 wire data, independent of current Codable/schema generation.
func makeThreadV2Fixture(at url: URL) throws {
    let db = try SQLiteConnection(path: url.path, flags: 6)
    defer { try? db.close() }
    for sql in [
        "CREATE TABLE projects(id TEXT PRIMARY KEY NOT NULL,payload TEXT NOT NULL)",
        "CREATE TABLE issues(id TEXT PRIMARY KEY NOT NULL,project_id TEXT NOT NULL REFERENCES projects(id),payload TEXT NOT NULL,UNIQUE(id,project_id))",
        "CREATE TABLE runs(id TEXT PRIMARY KEY NOT NULL,issue_id TEXT NOT NULL,project_id TEXT NOT NULL,payload TEXT NOT NULL,UNIQUE(id,issue_id),UNIQUE(id,issue_id,project_id),FOREIGN KEY(issue_id,project_id) REFERENCES issues(id,project_id))",
        "CREATE TABLE chat(id TEXT PRIMARY KEY NOT NULL,project_id TEXT NOT NULL REFERENCES projects(id),issue_id TEXT,run_id TEXT,payload TEXT NOT NULL,FOREIGN KEY(issue_id,project_id) REFERENCES issues(id,project_id),FOREIGN KEY(run_id,issue_id,project_id) REFERENCES runs(id,issue_id,project_id))",
        "CREATE TABLE activities(id TEXT PRIMARY KEY NOT NULL,issue_id TEXT NOT NULL REFERENCES issues(id),run_id TEXT,payload TEXT NOT NULL,FOREIGN KEY(run_id,issue_id) REFERENCES runs(id,issue_id))",
        "CREATE TABLE questions(id TEXT PRIMARY KEY NOT NULL,run_id TEXT NOT NULL,issue_id TEXT NOT NULL,payload TEXT NOT NULL,FOREIGN KEY(run_id,issue_id) REFERENCES runs(id,issue_id))",
        "CREATE TABLE notifications(id TEXT PRIMARY KEY NOT NULL,run_id TEXT UNIQUE NOT NULL REFERENCES runs(id),payload TEXT NOT NULL)",
        "CREATE TABLE run_events(id TEXT PRIMARY KEY NOT NULL,run_id TEXT NOT NULL REFERENCES runs(id),sequence INTEGER NOT NULL CHECK(sequence>0),payload TEXT NOT NULL,outcome TEXT NOT NULL,UNIQUE(run_id,sequence))",
        "CREATE INDEX runs_issue ON runs(issue_id)", "CREATE INDEX questions_run ON questions(run_id)", "CREATE INDEX activities_run ON activities(run_id)",
        "PRAGMA application_id=1263419730", "PRAGMA user_version=2"
    ] { try db.execute(sql) }
    try db.execute("INSERT INTO projects VALUES(?,?)", ["p", #"{"id":"p","name":"이전 프로젝트","absolutePath":"/tmp/knarr-thread-legacy"}"#])
    try db.execute("INSERT INTO issues VALUES(?,?,?)", ["legacy", "p", #"{"id":{"rawValue":"legacy"},"title":"이전 이슈","projectName":"이전 프로젝트","state":"done","confirmed":true,"headline":"완료","detail":"원문 그대로","acceptance":[],"hirds":[],"events":[],"startedAt":10}"#])
    try db.execute("INSERT INTO chat VALUES(?,?,?,?,?)", ["AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA", "p", "legacy", nil, #"{"link":{"chatID":"AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA","projectID":"p","issueID":{"rawValue":"legacy"}},"at":10,"kind":{"user":{"_0":"원문 · 첨부"}},"attachments":["file:///tmp/legacy.txt"]}"#])
}

@Suite(.serialized) struct ThreadPersistenceTests {
    @Test func additiveOwnershipAndTimingFieldsDecodeLegacyJSON() throws {
        let decoder = JSONDecoder()
        let thread = try decoder.decode(ConversationThread.self, from: Data(#"{"id":"default","name":"기본","createdAt":0}"#.utf8))
        #expect(thread.issueID == nil && thread.originThreadID == nil)
        let issue = try decoder.decode(KnarrCore.Issue.self, from: Data(#"{"id":{"rawValue":"legacy"},"title":"이전","projectName":"P","state":"done","confirmed":true,"headline":"","detail":"","acceptance":[],"hirds":[],"events":[],"startedAt":10}"#.utf8))
        #expect(issue.completedAt == nil)
        let hird = try decoder.decode(HirdRun.self, from: Data(#"{"id":{"rawValue":"r"},"name":"Hird","role":"검사","status":{"done":{"at":11}},"steps":[],"lastActivityAt":11}"#.utf8))
        #expect(hird.startedAt == nil)
    }
    @Test func issueConversationContextAndOwnershipSurviveReopeningWithoutIdleDelivery() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("knarr-owned-thread-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("fixture.db")
        let repository = try await SQLiteKnarrRepository.open(at: url)
        try await repository.saveProject(.init(id: "p", name: "프로젝트", absolutePath: directory.path))
        var issue = KnarrCore.Issue(id: "owned", title: "저장된 제목", projectName: "프로젝트", state: .awaitingApproval,
            headline: "", detail: "", acceptance: [.init(text: "검사", state: .pending, evidence: "")],
            hirds: [], events: [], startedAt: .now)
        issue.threadID = "issue-thread"
        issue.proposal = .init(instruction: "정확한 실행 지시", model: "provider/model")
        try await repository.createIssueConversation(issue, projectID: "p", originThreadID: ConversationThread.defaultID, handoffSummary: "짧은 인계")
        try await repository.createIssueConversation(issue, projectID: "p", originThreadID: ConversationThread.defaultID, handoffSummary: "재호출 요약은 첫 문맥을 바꾸지 않아요")
        let first = try await repository.snapshot()
        #expect(first.pendingDeliveryThreadIDs.isEmpty)
        #expect(first.chat.count == 2)
        #expect(first.chatLinks.allSatisfy { $0.conversationThreadID == issue.conversationThreadID })
        try await repository.close()
        let reopened = try await SQLiteKnarrRepository.open(at: url)
        let snapshot = try await reopened.snapshot()
        let thread = try #require(snapshot.threads.first { $0.issueID == issue.id })
        #expect(thread.name == issue.title && thread.originThreadID == ConversationThread.defaultID)
        #expect(snapshot.chat == first.chat && snapshot.chatLinks == first.chatLinks)
        var forged = thread
        forged.originThreadID = "another"
        await #expect(throws: PersistenceError.self) { try await reopened.saveThread(forged) }
        try await reopened.close()
    }

    @Test func correctionActionPreservesWireNameAndOptionalMemo() throws {
        for note in ["", "기존 이름은 유지해 주세요"] {
            let item = ChatItem(at: .now, kind: .notice(.init(tone: .result, title: "결과", body: "",
                issue: "owned", primary: .init("수정 요청", .requestChanges(note: note)))))
            let stored = StoredChat(item, link: .init(chatID: item.id, projectID: "p", issueID: "owned", runID: nil))
            let data = try JSONEncoder().encode(stored)
            let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            let kind = try #require(object["kind"] as? [String: Any])
            let notice = try #require(kind["notice"] as? [String: Any])
            #expect(notice["action"] as? String == "requestChanges")
            #expect(try JSONDecoder().decode(StoredChat.self, from: data).item().kind == item.kind)
            if note.isEmpty { #expect(object["actionNote"] == nil) }
        }
    }


    @Test func separateOMPSessionDirectoriesNeverImportAnotherThreadsContext() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("knarr-session-threads-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try StallariTools.sessionDirectory(root: root, threadID: ConversationThread.defaultID)
        try "legacy model context".write(to: first.appendingPathComponent("one.jsonl"), atomically: true, encoding: .utf8)
        let other = try StallariTools.sessionDirectory(root: root, threadID: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")
        #expect(first != other)
        #expect(try FileManager.default.contentsOfDirectory(atPath: other.path).isEmpty)
        #expect(try StallariTools.sessionDirectory(root: root, threadID: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB") == other)
        #expect(try String(contentsOf: first.appendingPathComponent("one.jsonl"), encoding: .utf8) == "legacy model context")
    }

    @Test func frozenV2MigratesWithoutChangingMessagesOrIssuePayloads() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("knarr-thread-v2-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("fixture.db")
        try makeThreadV2Fixture(at: url)
        let before = try SQLiteConnection(path: url.path, flags: 1)
        let chat = try before.rows("SELECT id,project_id,issue_id,run_id,payload FROM chat")
        let issues = try before.rows("SELECT id,project_id,payload FROM issues")
        try before.close()
        let repository = try await SQLiteKnarrRepository.open(at: url)
        let snapshot = try await repository.snapshot()
        #expect(snapshot.chat.first?.kind == .user("원문 · 첨부"))
        #expect(snapshot.chat.first?.attachments == [URL(fileURLWithPath: "/tmp/legacy.txt")])
        try await repository.close()
        let after = try SQLiteConnection(path: url.path, flags: 1)
        defer { try? after.close() }
        #expect(try after.rows("SELECT id,project_id,issue_id,run_id,payload FROM chat") == chat)
        #expect(try after.rows("SELECT id,project_id,payload FROM issues") == issues)
        #expect(try after.rows("SELECT thread_id FROM chat") == [["default"]])
        #expect(try after.rows("SELECT thread_id FROM issues") == [["default"]])
        #expect(try after.rows("SELECT id FROM threads") == [["default"]])
        #expect(try after.rows("PRAGMA foreign_key_check").isEmpty)
    }
}
