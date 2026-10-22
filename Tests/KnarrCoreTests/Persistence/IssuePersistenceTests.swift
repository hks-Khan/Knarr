import Foundation
import Testing
@testable import KnarrCore

private struct IssueFixture {
    let directory: URL
    var url: URL { directory.appendingPathComponent("knarr.sqlite") }
    init() throws {
        let root = ProcessInfo.processInfo.environment["KNARR_TEST_FIXTURE_ROOT"] ?? NSTemporaryDirectory()
        directory = URL(fileURLWithPath: root).appendingPathComponent("knarr-issue-persistence-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    func cleanup() { try? FileManager.default.removeItem(at: directory) }
}

// Independent, frozen v1 schema and wire payloads: never derived from current Codable models.
private func makeV1(_ url: URL, failMigration: Bool = false) throws {
    let db = try SQLiteConnection(path: url.path, flags: 6)
    defer { try? db.close() }
    try db.execute("PRAGMA foreign_keys=ON")
    try db.transaction {
        for sql in [
            "CREATE TABLE projects(id TEXT PRIMARY KEY NOT NULL,payload TEXT NOT NULL)",
            "CREATE TABLE things(id TEXT PRIMARY KEY NOT NULL,project_id TEXT NOT NULL REFERENCES projects(id),payload TEXT NOT NULL,UNIQUE(id,project_id))",
            "CREATE TABLE runs(id TEXT PRIMARY KEY NOT NULL,thing_id TEXT NOT NULL,project_id TEXT NOT NULL,payload TEXT NOT NULL,UNIQUE(id,thing_id),UNIQUE(id,thing_id,project_id),FOREIGN KEY(thing_id,project_id) REFERENCES things(id,project_id))",
            "CREATE TABLE chat(id TEXT PRIMARY KEY NOT NULL,project_id TEXT NOT NULL REFERENCES projects(id),thing_id TEXT,run_id TEXT,payload TEXT NOT NULL,FOREIGN KEY(thing_id,project_id) REFERENCES things(id,project_id),FOREIGN KEY(run_id,thing_id,project_id) REFERENCES runs(id,thing_id,project_id))",
            "CREATE TABLE activities(id TEXT PRIMARY KEY NOT NULL,thing_id TEXT NOT NULL REFERENCES things(id),run_id TEXT,payload TEXT NOT NULL,FOREIGN KEY(run_id,thing_id) REFERENCES runs(id,thing_id))",
            "CREATE TABLE questions(id TEXT PRIMARY KEY NOT NULL,run_id TEXT NOT NULL,thing_id TEXT NOT NULL,payload TEXT NOT NULL,FOREIGN KEY(run_id,thing_id) REFERENCES runs(id,thing_id))",
            "CREATE TABLE notifications(id TEXT PRIMARY KEY NOT NULL,run_id TEXT UNIQUE NOT NULL REFERENCES runs(id),payload TEXT NOT NULL)",
            "CREATE TABLE run_events(id TEXT PRIMARY KEY NOT NULL,run_id TEXT NOT NULL REFERENCES runs(id),sequence INTEGER NOT NULL CHECK(sequence>0),payload TEXT NOT NULL,outcome TEXT NOT NULL,UNIQUE(run_id,sequence))",
            "CREATE INDEX runs_thing ON runs(thing_id)", "CREATE INDEX questions_run ON questions(run_id)", "CREATE INDEX activities_run ON activities(run_id)",
            "PRAGMA application_id=1263419730", "PRAGMA user_version=1"
        ] { try db.execute(sql) }
        try db.execute("INSERT INTO projects VALUES(?,?)", ["project", #"{"id":"project","name":"Thing project","absolutePath":"/tmp/thing-project"}"#])
        try db.execute("INSERT INTO things VALUES(?,?,?)", ["thing-id", "project", #"{"id":{"rawValue":"thing-id"},"title":"Thing thing THING","projectName":"Thing project","state":"done","confirmed":true,"headline":"thing","detail":"thingID and thing are literal text","acceptance":[{"text":"thing criteria","state":{"met":{}},"evidence":"thing evidence"}],"hirds":[],"events":[],"startedAt":10}"#])
        let result = #"{"worktreePath":"/tmp/thing-worktree","branch":"thing-branch","commit":"thing-commit","diffPath":"/tmp/thing.diff","summary":"thing result","verifications":[{"id":"thing-check","command":["/bin/echo","thingID"],"workingDirectory":"/tmp/thing-worktree","startedAt":10,"finishedAt":11,"exitCode":0,"logPath":"/tmp/thing.log","summary":"thing verified"}]}"#
        let run = #"{"hird":{"id":{"rawValue":"thing-run"},"name":"Hird","role":"thing instruction","status":{"done":{"at":11}},"steps":[],"lastActivityAt":11},"thingID":{"rawValue":"thing-id"},"projectID":"project","ompSessionID":"thing-session","ownershipToken":"thing-owner","startedAt":10,"state":"succeeded","endedAt":11,"lastSequence":2,"workspace":{"worktreePath":"/tmp/thing-worktree","branch":"thing-branch","ompSessionPath":"/tmp/thing-session.jsonl"},"result":RESULT,"resultHistory":[RESULT]}"#.replacingOccurrences(of: "RESULT", with: result)
        try db.execute("INSERT INTO runs VALUES(?,?,?,?)", ["thing-run", "thing-id", "project", run])
        let question = #"{"id":"thing-question","runID":{"rawValue":"thing-run"},"thingID":{"rawValue":"thing-id"},"prompt":"thing prompt","options":["thing"],"createdAt":10,"state":"answered","answer":{"selectedOptions":["thing"],"text":"thing answer"},"resolvedAt":11,"deliveredAt":11}"#
        try db.execute("INSERT INTO questions VALUES(?,?,?,?)", ["thing-question", "thing-run", "thing-id", question])
        let activity = #"{"id":"AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA","at":10,"actor":"thing actor","text":"thing activity","detail":"thing detail"}"#
        try db.execute("INSERT INTO activities VALUES(?,?,?,?)", ["AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA", "thing-id", "thing-run", activity])
        try db.execute("INSERT INTO notifications VALUES(?,?,?)", ["hird-completion:thing-run", "thing-run", #"{"id":"hird-completion:thing-run","runID":{"rawValue":"thing-run"},"createdAt":11,"deliveredAt":11}"#])
        let chatIDs = ["BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB", "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC", "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD", "EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE"]
        let kinds = [#"{"thing":{"_0":{"rawValue":"thing-id"}}}"#, #"{"notice":{"tone":"result","title":"thing notice","body":"thing body","thing":{"rawValue":"thing-id"},"label":"thing confirm","action":"confirmResult"}}"#, #"{"user":{"_0":"literal thingID thing Thing THING"}}"#, #"{"notice":{"tone":"needsInput","title":"thing proposal","body":"thing proposal body","thing":{"rawValue":"thing-id"},"label":"old launch","action":"acceptProposal"}}"#]
        for (id, kind) in zip(chatIDs, kinds) {
            let payload = "{\"link\":{\"chatID\":\"\(id)\",\"projectID\":\"project\",\"thingID\":{\"rawValue\":\"thing-id\"},\"runID\":{\"rawValue\":\"thing-run\"}},\"at\":10,\"kind\":\(kind)}"
            try db.execute("INSERT INTO chat VALUES(?,?,?,?,?)", [id, "project", "thing-id", "thing-run", payload])
        }
        try db.execute("INSERT INTO run_events VALUES(?,?,?,?,?)", ["thing-ask", "thing-run", "1", "{\"id\":\"thing-ask\",\"runID\":{\"rawValue\":\"thing-run\"},\"sequence\":1,\"at\":10,\"payload\":{\"ask\":{\"_0\":\(question)}}}", "applied"])
        try db.execute("INSERT INTO run_events VALUES(?,?,?,?,?)", ["thing-complete", "thing-run", "2", "{\"id\":\"thing-complete\",\"runID\":{\"rawValue\":\"thing-run\"},\"sequence\":2,\"at\":11,\"payload\":{\"complete\":{\"_0\":\(result),\"notificationID\":\"hird-completion:thing-run\"}}}", "applied"])
        if failMigration {
            try db.execute("CREATE TRIGGER migration_failure BEFORE UPDATE OF payload ON chat BEGIN SELECT RAISE(ABORT,'fixture failure'); END")
        }
    }
}

// Compare every SQL value and every JSON field, independent of the production converter.
private func normalizedRows(_ db: SQLiteConnection, table: String, legacy: Bool) throws -> [[String]] {
    let columns = try db.rows("PRAGMA table_info(\(table))").filter { $0[1] != "thread_id" }
    let payloadColumn = try #require(columns.firstIndex { $0[1] == "payload" })
    func expected(_ value: Any) -> Any {
        if let array = value as? [Any] { return array.map(expected) }
        guard let object = value as? [String: Any] else { return value }
        var output: [String: Any] = [:]
        for (key, value) in object {
            let renamed = legacy && key == "thingID" ? "issueID" : legacy && key == "thing" ? "issue" : key
            output[renamed] = expected(value)
        }
        if legacy && output["action"] as? String == "acceptProposal" {
            output.removeValue(forKey: "action"); output.removeValue(forKey: "label")
        }
        return output
    }
    let selected = columns.map { $0[1] }.joined(separator: ",")
    return try db.rows("SELECT \(selected) FROM \(table) ORDER BY rowid").map { row in
        var output = row
        let json = try JSONSerialization.jsonObject(with: Data(row[payloadColumn].utf8))
        output[payloadColumn] = String(decoding: try JSONSerialization.data(withJSONObject: expected(json), options: [.sortedKeys]), as: UTF8.self)
        return output
    }
}

@Suite(.serialized) struct IssuePersistenceTests {
    @Test func independentV1FixturePreservesEveryRelationshipAndLiteral() async throws {
        let f = try IssueFixture(); defer { f.cleanup() }
        try makeV1(f.url)
        let original = try SQLiteConnection(path: f.url.path, flags: 1)
        var preserved: [String: [[String]]] = [:]
        for table in ["projects", "things", "runs", "questions", "activities", "notifications", "chat", "run_events"] {
            preserved[table == "things" ? "issues" : table] = try normalizedRows(original, table: table, legacy: true)
        }
        try original.close()
        let db = try await SQLiteKnarrRepository.open(at: f.url)
        let s = try await db.snapshot()
        #expect(s.projects.first?.name == "Thing project")
        #expect(s.issues.first?.id == "thing-id")
        #expect(s.issues.first?.title == "Thing thing THING")
        #expect(s.issues.first?.confirmed == true)
        #expect(s.issues.first?.acceptance.first?.evidence == "thing evidence")
        #expect(s.issues.first?.completedAt == Date(timeIntervalSinceReferenceDate: 11))
        #expect(s.issues.first?.integratedInto == nil)
        #expect(s.issues.first?.hirds.first?.startedAt == Date(timeIntervalSinceReferenceDate: 10))
        #expect(s.issues.first?.events.first?.text == "thing activity")
        #expect(s.runs.first?.issueID == "thing-id")
        #expect(s.runs.first?.ompSessionID == "thing-session")
        #expect(s.runs.first?.workspace?.worktreePath == "/tmp/thing-worktree")
        #expect(s.runs.first?.result?.summary == "thing result")
        #expect(s.runs.first?.resultHistory == s.runs.first?.result.map { [$0] })
        #expect(s.runs.first?.result?.verifications.first?.command == ["/bin/echo", "thingID"])
        #expect(s.questions.first?.issueID == "thing-id")
        #expect(s.questions.first?.answer?.text == "thing answer")
        #expect(s.questions.first?.deliveredAt == Date(timeIntervalSinceReferenceDate: 11))
        #expect(s.notifications.first?.id == "hird-completion:thing-run")
        #expect(s.notifications.first?.deliveredAt == Date(timeIntervalSinceReferenceDate: 11))
        #expect(s.chat.map(\.id.uuidString) == ["BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB", "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC", "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD", "EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE"])
        #expect(s.chat[0].kind == .issue("thing-id"))
        #expect(s.chat[2].kind == .user("literal thingID thing Thing THING"))
        guard case .notice(let oldProposal) = s.chat[3].kind else { throw FixtureError.expectedNotice }
        #expect(oldProposal.primary == nil)
        #expect(s.chatLinks.allSatisfy { $0.issueID == "thing-id" && $0.runID == "thing-run" })
        #expect(try await db.projectID(forIssue: "thing-id") == "project")
        #expect(try await db.pendingNotifications().isEmpty)
        try await db.close()
        let raw = try SQLiteConnection(path: f.url.path, flags: 1)
        for (table, rows) in preserved {
            if table == "runs" {
                let expected = try rows.map { row in
                    var value = try JSONDecoder().decode(PersistedRun.self, from: Data(row[3].utf8))
                    value.savedResultCount = value.resultHistory.count
                    return value
                }
                #expect(s.runs == expected) // v4 reconstructs every metadata/result/history field.
                #expect(try raw.rows("SELECT id,issue_id,project_id FROM runs ORDER BY rowid") == rows.map { Array($0.prefix(3)) })
            } else {
                #expect(try normalizedRows(raw, table: table, legacy: false) == rows)
            }
        }
        #expect(s.threads == [.default])
        #expect(s.issues.allSatisfy { $0.conversationThreadID == ConversationThread.defaultID })
        #expect(try raw.rows("SELECT name FROM sqlite_master WHERE name IN ('things','runs_thing')").isEmpty)
        #expect(try raw.rows("SELECT name FROM sqlite_master WHERE name='runs_issue'") == [["runs_issue"]])
        let event = try #require(raw.rows("SELECT payload FROM run_events WHERE id='thing-ask'").first?.first)
        let json = try #require(JSONSerialization.jsonObject(with: Data(event.utf8)) as? [String: Any])
        let ask = try #require((json["payload"] as? [String: Any])?["ask"] as? [String: Any])
        #expect((ask["_0"] as? [String: Any])?["issueID"] != nil)
        try raw.close()
        let reopened = try await SQLiteKnarrRepository.open(at: f.url)
        #expect(try await reopened.snapshot() == s)
        try await reopened.close()
    }

    @Test func failedV1MigrationRollsBackSchemaPayloadAndVersion() async throws {
        let f = try IssueFixture(); defer { f.cleanup() }
        try makeV1(f.url, failMigration: true)
        let before = try Data(contentsOf: f.url)
        await #expect(throws: PersistenceError.self) { try await SQLiteKnarrRepository.open(at: f.url) }
        #expect(try Data(contentsOf: f.url) == before)
        let raw = try SQLiteConnection(path: f.url.path, flags: 1)
        #expect(try raw.rows("PRAGMA user_version") == [["1"]])
        #expect(try raw.rows("SELECT COUNT(*) FROM things") == [["1"]])
        #expect(try raw.rows("SELECT name FROM sqlite_master WHERE name='issues'").isEmpty)
        try raw.close()
    }

    @Test func corruptV1IsRejectedWithoutMutation() async throws {
        let f = try IssueFixture(); defer { f.cleanup() }
        try makeV1(f.url)
        let raw = try SQLiteConnection(path: f.url.path, flags: 2)
        try raw.execute("UPDATE chat SET payload='not json'")
        try raw.close()
        let before = try Data(contentsOf: f.url)
        await #expect(throws: PersistenceError.self) { try await SQLiteKnarrRepository.open(at: f.url) }
        #expect(try Data(contentsOf: f.url) == before)
    }

    private func setup(_ db: SQLiteKnarrRepository) async throws {
        try await db.saveProject(.init(id: "p", name: "project", absolutePath: "/tmp/project"))
        let issue = KnarrCore.Issue(id: "i", title: "approval", projectName: "project", state: .awaitingApproval, headline: "review", detail: "review", acceptance: [], hirds: [], events: [], startedAt: Date(timeIntervalSinceReferenceDate: 10))
        try await db.saveIssue(issue, projectID: "p")
        try await db.saveIssueProposal(issueID: "i", proposal: .init(instruction: "exact instruction", model: "provider/model"), expectedVersion: nil)
    }
    private func proposedRun(_ id: HirdRun.ID = "r") -> PersistedRun {
        PersistedRun(hird: .init(id: id, name: "Hird", role: "exact instruction", status: .working, steps: [], currentCommand: nil, lastActivityAt: Date(timeIntervalSinceReferenceDate: 10)), issueID: "i", projectID: "p", ompSessionID: nil, ownershipToken: "owner-\(id.rawValue)", startedAt: Date(timeIntervalSinceReferenceDate: 10), mode: .change, requestedModel: "provider/model")
    }

    @Test func approvalConsumptionIsAtomicIdempotentAndSurvivesRestart() async throws {
        let f = try IssueFixture(); defer { f.cleanup() }
        let db = try await SQLiteKnarrRepository.open(at: f.url)
        try await setup(db)
        await #expect(throws: PersistenceError.self) { try await db.createApprovedRun(proposedRun(), proposalVersion: 1) }
        let at = Date(timeIntervalSinceReferenceDate: 11)
        let proposal = try await db.approveIssueProposal(issueID: "i", version: 1, at: at)
        #expect(try await db.approveIssueProposal(issueID: "i", version: 1, at: at.addingTimeInterval(1)) == proposal)
        var wrong = proposedRun(); wrong.requestedModel = "provider/other"
        await #expect(throws: PersistenceError.self) { try await db.createApprovedRun(wrong, proposalVersion: 1) }
        wrong = proposedRun(); wrong.hird.role = "different instruction"
        await #expect(throws: PersistenceError.self) { try await db.createApprovedRun(wrong, proposalVersion: 1) }
        wrong = proposedRun(); wrong.mode = .inspect
        await #expect(throws: PersistenceError.self) { try await db.createApprovedRun(wrong, proposalVersion: 1) }
        let wrongLineage = PersistedRun(hird: proposedRun().hird, issueID: "i", projectID: "p", ompSessionID: nil, ownershipToken: "owner-r", startedAt: Date(timeIntervalSinceReferenceDate: 10), previousRunID: "other", mode: .change, requestedModel: "provider/model")
        await #expect(throws: PersistenceError.self) { try await db.createApprovedRun(wrongLineage, proposalVersion: 1) }
        #expect(try await db.snapshot().issues[0].approval?.runID == nil)
        #expect(try await db.createApprovedRun(proposedRun(), proposalVersion: 1) == .applied)
        #expect(try await db.createApprovedRun(proposedRun(), proposalVersion: 1) == .duplicate)
        await #expect(throws: PersistenceError.self) { try await db.createApprovedRun(proposedRun("r2"), proposalVersion: 1) }
        #expect(try await db.snapshot().issues[0].approvalHistory?.count == 1)
        try await db.close()
        let reopened = try await SQLiteKnarrRepository.open(at: f.url)
        #expect(try await reopened.snapshot().issues[0].approval?.runID == "r")
        #expect(try await reopened.snapshot().issues[0].approvalHistory?.first?.runID == "r")
        #expect(try await reopened.createApprovedRun(proposedRun(), proposalVersion: 1) == .duplicate)
        await #expect(throws: PersistenceError.self) { try await reopened.createApprovedRun(proposedRun("r2"), proposalVersion: 1) }
        try await reopened.close()
    }

    @Test func reviewVersionsInvalidateApprovalAndPreserveRejectedAndAwaitingStates() async throws {
        let f = try IssueFixture(); defer { f.cleanup() }
        let db = try await SQLiteKnarrRepository.open(at: f.url)
        try await setup(db)
        _ = try await db.approveIssueProposal(issueID: "i", version: 1, at: .now)
        try await db.requestIssueProposalChanges(issueID: "i", version: 1, note: "change this")
        #expect(try await db.snapshot().issues[0].approval == nil)
        #expect(try await db.snapshot().issues[0].proposalReviewNote == "change this")
        try await db.saveIssueProposal(issueID: "i", proposal: .init(version: 2, instruction: "new", model: "provider/model"), expectedVersion: 1)
        await #expect(throws: PersistenceError.self) { try await db.approveIssueProposal(issueID: "i", version: 1, at: .now) }
        await #expect(throws: PersistenceError.self) { try await db.saveIssueProposal(issueID: "i", proposal: .init(version: 2, instruction: "stale", model: "provider/model"), expectedVersion: 1) }
        try await db.rejectIssueProposal(issueID: "i", version: 2, note: "not wanted")
        try await db.close()
        let rejected = try await SQLiteKnarrRepository.open(at: f.url)
        #expect(try await rejected.snapshot().issues[0].state == .rejected)
        try await rejected.saveIssueProposal(issueID: "i", proposal: .init(version: 3, instruction: "revised", model: "provider/model"), expectedVersion: 2)
        try await rejected.close()
        let waiting = try await SQLiteKnarrRepository.open(at: f.url)
        #expect(try await waiting.snapshot().issues[0].state == .awaitingApproval)
        #expect(try await waiting.snapshot().issues[0].approvalHistory?.count == 1)
        try await waiting.close()
    }

    @Test func activeRunsBlockProposalMutationAndCompetingApprovalConsumption() async throws {
        let f = try IssueFixture(); defer { f.cleanup() }
        let first = try await SQLiteKnarrRepository.open(at: f.url)
        try await setup(first)
        let second = try await SQLiteKnarrRepository.open(at: f.url)
        _ = try await first.approveIssueProposal(issueID: "i", version: 1, at: .now)
        async let a = first.createApprovedRun(proposedRun(), proposalVersion: 1)
        async let b = second.createApprovedRun(proposedRun(), proposalVersion: 1)
        let outcomes = try await [a, b]
        #expect(outcomes.filter { $0 == .applied }.count == 1)
        #expect(outcomes.filter { $0 == .duplicate }.count == 1)
        await #expect(throws: PersistenceError.self) { try await first.saveIssueProposal(issueID: "i", proposal: .init(version: 2, instruction: "new", model: "provider/model"), expectedVersion: 1) }
        await #expect(throws: PersistenceError.self) { try await first.requestIssueProposalChanges(issueID: "i", version: 1, note: "change") }
        #expect(try await first.snapshot().runs.count == 1)
        try await first.close(); try await second.close()
    }

    @Test func capacityAndArchivedProjectAreRecheckedBeforeConsumption() async throws {
        let f = try IssueFixture(); defer { f.cleanup() }
        let db = try await SQLiteKnarrRepository.open(at: f.url)
        try await setup(db)
        _ = try await db.approveIssueProposal(issueID: "i", version: 1, at: .now)
        var other = KnarrCore.Issue(id: "other", title: "other", projectName: "project", state: .running, headline: "", detail: "", acceptance: [], hirds: [], events: [], startedAt: .now)
        try await db.saveIssue(other, projectID: "p")
        let occupying = PersistedRun(hird: .init(id: "occupied", name: "Hird", role: "busy", status: .working, steps: [], currentCommand: nil, lastActivityAt: .now), issueID: "other", projectID: "p", ompSessionID: nil, ownershipToken: "occupied-owner", startedAt: .now)
        _ = try await db.createRun(occupying)
        try await db.saveProject(.init(id: "p", name: "project", absolutePath: "/tmp/project", settings: .init(maxHirds: 1)))
        let before = try await db.snapshot()
        await #expect(throws: PersistenceError.self) { try await db.createApprovedRun(proposedRun(), proposalVersion: 1) }
        #expect(try await db.snapshot() == before)
        try await db.saveProject(.init(id: "p", name: "project", absolutePath: "/tmp/project", archivedAt: .now, settings: .init(maxHirds: 2)))
        await #expect(throws: PersistenceError.self) { try await db.createApprovedRun(proposedRun(), proposalVersion: 1) }
        #expect(try await db.snapshot().issues[0].approval?.runID == nil)
        other.id = "new"
        other.proposal = .init(instruction: "new", model: "provider/model", previousRunID: "occupied")
        other.state = .awaitingApproval
        await #expect(throws: PersistenceError.self) { try await db.saveIssue(other, projectID: "p") }
        #expect(try await db.snapshot().issues.count == 2)
        try await db.close()
    }

    @Test func runInsertFailureDoesNotConsumeApprovalOrChangeIssueState() async throws {
        let f = try IssueFixture(); defer { f.cleanup() }
        let db = try await SQLiteKnarrRepository.open(at: f.url)
        try await setup(db)
        _ = try await db.approveIssueProposal(issueID: "i", version: 1, at: .now)
        let raw = try SQLiteConnection(path: f.url.path, flags: 2)
        try raw.execute("CREATE TRIGGER fail_run BEFORE INSERT ON runs BEGIN SELECT RAISE(ABORT,'fixture failure'); END")
        try raw.close()
        let before = try await db.snapshot()
        await #expect(throws: PersistenceError.self) { try await db.createApprovedRun(proposedRun(), proposalVersion: 1) }
        #expect(try await db.snapshot() == before)
        try await db.close()
    }

    @Test func metadataCannotReplaceProposalOrStaleApproval() async throws {
        let f = try IssueFixture(); defer { f.cleanup() }
        let db = try await SQLiteKnarrRepository.open(at: f.url)
        try await setup(db)
        var stale = try await db.snapshot().issues[0]
        _ = try await db.approveIssueProposal(issueID: "i", version: 1, at: .now)
        stale.title = "stale metadata"
        await #expect(throws: PersistenceError.self) { try await db.saveIssue(stale, projectID: "p") }
        var changed = try await db.snapshot().issues[0]
        changed.proposal?.instruction = "bypassed review"
        await #expect(throws: PersistenceError.self) { try await db.saveIssue(changed, projectID: "p") }
        #expect(try await db.snapshot().issues[0].proposal?.instruction == "exact instruction")
        #expect(try await db.snapshot().issues[0].title == "approval")
        try await db.close()
    }

    @Test func proposalRevisionKeepsConsumedApprovalHistoryAcrossRestart() async throws {
        let f = try IssueFixture(); defer { f.cleanup() }
        let db = try await SQLiteKnarrRepository.open(at: f.url)
        try await setup(db)
        _ = try await db.approveIssueProposal(issueID: "i", version: 1, at: Date(timeIntervalSinceReferenceDate: 11))
        _ = try await db.createApprovedRun(proposedRun(), proposalVersion: 1)
        _ = try await db.recordEvent(id: "failed-r", runID: "r", at: Date(timeIntervalSinceReferenceDate: 12), payload: .fail("finished"))
        try await db.saveIssueProposal(issueID: "i", proposal: .init(version: 2, instruction: "exact instruction", model: "provider/model", previousRunID: "r"), expectedVersion: 1)
        _ = try await db.approveIssueProposal(issueID: "i", version: 2, at: Date(timeIntervalSinceReferenceDate: 13))
        let next = PersistedRun(hird: proposedRun("r2").hird, issueID: "i", projectID: "p", ompSessionID: nil, ownershipToken: "owner-r2", startedAt: Date(timeIntervalSinceReferenceDate: 14), previousRunID: "r", mode: .change, requestedModel: "provider/model")
        _ = try await db.createApprovedRun(next, proposalVersion: 2)
        try await db.close()
        let reopened = try await SQLiteKnarrRepository.open(at: f.url)
        #expect(try await reopened.snapshot().issues[0].approvalHistory == [
            .init(version: 1, approvedAt: Date(timeIntervalSinceReferenceDate: 11), runID: "r"),
            .init(version: 2, approvedAt: Date(timeIntervalSinceReferenceDate: 13), runID: "r2")
        ])
        #expect(try await reopened.snapshot().runs[1].previousRunID == "r")
        await #expect(throws: PersistenceError.self) { try await reopened.createApprovedRun(proposedRun("r3"), proposalVersion: 1) }
        try await reopened.close()
    }

    @Test func versionedReviewActionsRoundTripWithoutLosingVersionOrNote() async throws {
        let f = try IssueFixture(); defer { f.cleanup() }
        let db = try await SQLiteKnarrRepository.open(at: f.url)
        try await setup(db)
        let actions: [IssueAction] = [
            .approveProposal(version: 1),
            .requestProposalChanges(version: 1, note: "specific changes"),
            .rejectProposal(version: 1, note: "specific rejection")
        ]
        let items = actions.map { action in
            ChatItem(at: Date(timeIntervalSinceReferenceDate: 10), kind: .notice(.init(tone: .needsInput, title: "proposal", body: "review", issue: "i", primary: .init("review", action))))
        }
        for item in items { try await db.appendChat(item, projectID: "p", issueID: "i") }
        try await db.close()
        let reopened = try await SQLiteKnarrRepository.open(at: f.url)
        let restored = try await reopened.snapshot().chat
        #expect(restored.filter { item in items.contains { $0.id == item.id } } == items)
        #expect(restored.contains { $0.kind == .proposal("i", version: 1) })
        try await reopened.close()
    }
}

private enum FixtureError: Error { case expectedNotice }
