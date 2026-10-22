import Foundation
import Testing
@testable import KnarrCore

private struct MilestoneFixture: Sendable {
    let directory: URL
    let repository: SQLiteKnarrRepository
    var url: URL { directory.appendingPathComponent("milestones.sqlite") }
    static func make() async throws -> Self {
        let base = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let root = ProcessInfo.processInfo.environment["KNARR_TEST_FIXTURE_ROOT"] ?? base.appendingPathComponent("outputs/milestone-fixtures").path
        let directory = URL(fileURLWithPath: root).appendingPathComponent("knarr-milestones-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let repository = try await SQLiteKnarrRepository.open(at: directory.appendingPathComponent("milestones.sqlite"))
        try await repository.saveProject(.init(id: "p", name: "프로젝트", absolutePath: directory.path))
        try await repository.saveProject(.init(id: "other", name: "다른 프로젝트", absolutePath: directory.appendingPathComponent("other").path))
        return .init(directory: directory, repository: repository)
    }
    func storeIssue(_ issue: KnarrCore.Issue, projectID: String) async throws {
        try await repository.saveThread(.init(id: issue.conversationThreadID, name: issue.title, createdAt: issue.startedAt))
        try await repository.saveIssue(issue, projectID: projectID)
    }
    func milestone(_ id: String, order: Int, title: String? = nil, project: String = "p",
                   prerequisites: [Milestone.ID] = []) -> Milestone {
        Milestone(id: .init(id), projectID: project, order: order, title: title ?? id, prerequisites: prerequisites)
    }
}

@Suite(.serialized) struct MilestonePersistenceTests {
    @Test func milestonesRoundTripPerProjectAndKeepWeeklyHistoryAcrossTargetDateEdits() async throws {
        let f = try await MilestoneFixture.make()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        var first = f.milestone("m1", order: 1, title: "기반 정리")
        let thisWeek = Milestone.weekStart(containing: .now)
        let previousWeek = thisWeek.addingTimeInterval(-7 * 86400)
        try first.setWeek(scope: ["스키마 정리"], result: "완료", at: previousWeek)
        try first.setWeek(scope: ["이번 주 계획"], result: "", at: thisWeek)
        first.targetDate = Date(timeIntervalSince1970: 1_800_000_000)
        try await f.repository.saveMilestone(first)
        var second = f.milestone("m2", order: 2, title: "계획 화면", prerequisites: ["m1"])
        second.status = .active
        try await f.repository.saveMilestone(second)
        try await f.repository.saveMilestone(f.milestone("o1", order: 1, title: "다른 프로젝트 단계", project: "other"))

        #expect(try await f.repository.milestones(projectID: "p").map(\.id) == ["m1", "m2"])
        #expect(try await f.repository.milestones(projectID: "other").map(\.id) == ["o1"])
        let before = try #require(try await f.repository.milestones(projectID: "p").first)
        var edited = before
        edited.targetDate = Date(timeIntervalSince1970: 1_900_000_000)
        try await f.repository.saveMilestone(edited)
        let after = try #require(try await f.repository.milestones(projectID: "p").first)
        #expect(after.weeks == before.weeks)
        #expect(after.targetDate == Date(timeIntervalSince1970: 1_900_000_000))
        #expect(after.targetDateHistory.map(\.previous) == [before.targetDate])
        #expect(after.targetDateHistory.map(\.updated) == [edited.targetDate])

        var rewritten = after
        rewritten.weeks[0].scope = ["지난 기록 바꿈"]
        await #expect(throws: PersistenceError.self) { try await f.repository.saveMilestone(rewritten) }
        var revised = after
        revised.weeks[1].scope = ["이번 주 계획 수정"]
        try await f.repository.saveMilestone(revised)
        let stored = try #require(try await f.repository.milestones(projectID: "p").first)
        #expect(stored.weeks[1].scope == ["이번 주 계획 수정"])
        #expect(stored.weeks[0] == after.weeks[0])
        var dropped = revised
        dropped.weeks = []
        await #expect(throws: PersistenceError.self) { try await f.repository.saveMilestone(dropped) }

        try await f.repository.close()
        let reopened = try await SQLiteKnarrRepository.open(at: f.url)
        let reloaded = try await reopened.milestones(projectID: "p")
        #expect(reloaded.map(\.id) == ["m1", "m2"])
        #expect(reloaded.first == stored)
        #expect(reloaded.last?.title == "계획 화면")
        try await reopened.close()
    }

    @Test func targetDateHistoryAppendsOnlyRealEditsAndPersistsAcrossReopen() async throws {
        let f = try await MilestoneFixture.make()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let start = Date(timeIntervalSince1970: 1_780_000_000)
        var milestone = f.milestone("m", order: 0)
        milestone.targetDate = start
        try await f.repository.saveMilestone(milestone)
        var stored = try #require(try await f.repository.milestones(projectID: "p").first)
        #expect(stored.targetDateHistory.isEmpty, "creating with a date is not an edit")

        // Saving unrelated text keeps the history unchanged.
        var untouched = stored
        untouched.detail = "설명만 고침"
        try await f.repository.saveMilestone(untouched)
        stored = try #require(try await f.repository.milestones(projectID: "p").first)
        #expect(stored.targetDateHistory.isEmpty)
        #expect(stored.detail == "설명만 고침")

        // Two real edits, then clearing the date, append in order.
        var moved = stored
        moved.targetDate = start.addingTimeInterval(86400)
        try await f.repository.saveMilestone(moved)
        moved = try #require(try await f.repository.milestones(projectID: "p").first)
        moved.targetDate = start.addingTimeInterval(2 * 86400)
        try await f.repository.saveMilestone(moved)
        moved = try #require(try await f.repository.milestones(projectID: "p").first)
        moved.targetDate = nil
        try await f.repository.saveMilestone(moved)

        let history = try #require(try await f.repository.milestones(projectID: "p").first).targetDateHistory
        #expect(history.count == 3)
        #expect(history.map(\.previous) == [start, start.addingTimeInterval(86400), start.addingTimeInterval(2 * 86400)])
        #expect(history.map(\.updated) == [start.addingTimeInterval(86400), start.addingTimeInterval(2 * 86400), nil])
        #expect(history.map(\.changedAt) == history.map(\.changedAt).sorted())

        try await f.repository.close()
        let reopened = try await SQLiteKnarrRepository.open(at: f.url)
        #expect(try await reopened.milestones(projectID: "p").first?.targetDateHistory == history)
        #expect(try await reopened.milestones(projectID: "p").first?.targetDate == nil)
        try await reopened.close()
    }

    @Test func clientSuppliedHistoryAndStaleWeeksAreOverwrittenOrRejected() async throws {
        let f = try await MilestoneFixture.make()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let original = Date(timeIntervalSince1970: 1_770_000_000)
        var milestone = f.milestone("m", order: 0)
        milestone.targetDate = original
        try await f.repository.saveMilestone(milestone)
        var stored = try #require(try await f.repository.milestones(projectID: "p").first)
        stored.targetDate = original.addingTimeInterval(86400)
        try await f.repository.saveMilestone(stored)
        stored = try #require(try await f.repository.milestones(projectID: "p").first)
        let genuine = stored.targetDateHistory

        // A forged extra entry plus an unedited date must still store only the server's history.
        var forged = stored
        forged.targetDate = stored.targetDate
        forged.targetDateHistory = genuine + [.init(previous: nil, updated: original, changedAt: .distantPast)]
        try await f.repository.saveMilestone(forged)
        #expect(try await f.repository.milestones(projectID: "p").first?.targetDateHistory == genuine)

        // Existing weekly entries are anchored to the server's clock: a back-dated payload that
        // rewrites a previous week is rejected even with its own `updatedAt`.
        let lastWeek = Milestone.weekStart(containing: .now).addingTimeInterval(-7 * 86400)
        var withPastWeek = try #require(try await f.repository.milestones(projectID: "p").first)
        withPastWeek.weeks = [.init(weekStart: lastWeek, scope: ["지난주 계획"], result: "완료", recordedAt: lastWeek)]
        try await f.repository.saveMilestone(withPastWeek)
        var tampered = try #require(try await f.repository.milestones(projectID: "p").first)
        tampered.weeks[0].scope = ["지난주 계획 수정"]
        tampered.updatedAt = lastWeek
        await #expect(throws: PersistenceError.self) { try await f.repository.saveMilestone(tampered) }
        let unchanged = try #require(try await f.repository.milestones(projectID: "p").first)
        #expect(unchanged.weeks == withPastWeek.weeks)

        // The current week may still be revised, and the following week may be appended.
        var thisWeek = unchanged
        var revised = unchanged.weeks[0]
        revised.weekStart = Milestone.weekStart(containing: .now)
        revised.scope = ["이번 주 계획"]
        thisWeek.weeks.append(revised)
        try await f.repository.saveMilestone(thisWeek)
        var revisedAgain = try #require(try await f.repository.milestones(projectID: "p").first)
        revisedAgain.weeks[1].scope = ["이번 주 계획 수정"]
        try await f.repository.saveMilestone(revisedAgain)
        let final = try #require(try await f.repository.milestones(projectID: "p").first)
        #expect(final.weeks.count == 2)
        #expect(final.weeks[1].scope == ["이번 주 계획 수정"])
        #expect(final.weeks[0] == unchanged.weeks[0])
        try await f.repository.close()
    }

    @Test func writesRejectCrossProjectPrerequisitesCyclesAndDuplicateOrder() async throws {
        let f = try await MilestoneFixture.make()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        try await f.repository.saveMilestone(f.milestone("other", order: 1, project: "other"))
        try await f.repository.saveMilestone(f.milestone("a", order: 1))
        await #expect(throws: PersistenceError.self) {
            try await f.repository.saveMilestone(f.milestone("b", order: 2, prerequisites: ["other"]))
        }
        await #expect(throws: PersistenceError.self) {
            try await f.repository.saveMilestone(f.milestone("c", order: 1))
        }
        await #expect(throws: PersistenceError.self) {
            try await f.repository.saveMilestone(f.milestone("missing", order: 2, project: "missing"))
        }
        try await f.repository.saveMilestone(f.milestone("b", order: 2, prerequisites: ["a"]))
        var cycle = f.milestone("a", order: 1, prerequisites: ["b"])
        cycle.status = .active
        await #expect(throws: PersistenceError.self) { try await f.repository.saveMilestone(cycle) }
        #expect(try await f.repository.milestones(projectID: "p").count == 2)
        // Reordering into another milestone's slot is rejected too.
        var moved = try #require(try await f.repository.milestones(projectID: "p").first { $0.id == "b" })
        moved.order = 1
        await #expect(throws: PersistenceError.self) { try await f.repository.saveMilestone(moved) }
        try await f.repository.close()
    }

    @Test func reachedStateRequiresVerifiedCriteriaAndIsNotDerivedFromIssues() async throws {
        let f = try await MilestoneFixture.make()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        var milestone = f.milestone("m", order: 1)
        try await f.repository.saveMilestone(milestone)
        var issue = KnarrCore.Issue(id: "i", title: "일부 작업", projectName: "프로젝트", state: .awaitingApproval, headline: "", detail: "",
                          acceptance: [], hirds: [], events: [], startedAt: .now)
        issue.milestoneID = "m"
        issue.threadID = "issue-thread"
        issue.proposal = .init(instruction: "이슈", model: "provider/model")
        try await f.storeIssue(issue, projectID: "p")
        let stored = try #require(try await f.repository.milestones(projectID: "p").first)
        #expect(stored.status == .planned)
        #expect(!stored.isReached)
        milestone = stored
        milestone.status = .reached
        milestone.reachedAt = .now
        await #expect(throws: PersistenceError.self) { try await f.repository.saveMilestone(milestone) }
        milestone.criteria = [.init(text: "통합 테스트 통과", state: .met, evidence: "swift test")]
        milestone.reachedAt = .now
        try await f.repository.saveMilestone(milestone)
        #expect(try await f.repository.milestones(projectID: "p").first?.isReached == true)
        try await f.repository.close()
    }

    @Test func issueMilestoneCannotMoveAfterCreationOrCrossProjects() async throws {
        let f = try await MilestoneFixture.make()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        try await f.repository.saveMilestone(f.milestone("m", order: 1))
        try await f.repository.saveMilestone(f.milestone("o", order: 1, project: "other"))
        var issue = KnarrCore.Issue(id: "i", title: "작업", projectName: "프로젝트", state: .awaitingApproval, headline: "", detail: "",
                          acceptance: [], hirds: [], events: [], startedAt: .now)
        issue.threadID = "issue-thread"
        issue.proposal = .init(instruction: "이슈", model: "provider/model")
        issue.milestoneID = "o"
        await #expect(throws: PersistenceError.self) { try await f.storeIssue(issue, projectID: "p") }
        issue.milestoneID = "missing"
        await #expect(throws: PersistenceError.self) { try await f.storeIssue(issue, projectID: "p") }
        issue.milestoneID = "m"
        try await f.storeIssue(issue, projectID: "p")
        var moved = try #require(try await f.repository.snapshot().issues.first)
        moved.milestoneID = nil
        await #expect(throws: PersistenceError.self) { try await f.repository.saveIssue(moved, projectID: "p") }
        try await f.repository.saveMilestone(f.milestone("legacy", order: 2, title: "기존"))
        try await f.repository.close()
    }

    @Test func deletingAReferencedMilestoneIsRejected() async throws {
        let f = try await MilestoneFixture.make()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        try await f.repository.saveMilestone(f.milestone("m", order: 1))
        var issue = KnarrCore.Issue(id: "i", title: "작업", projectName: "프로젝트", state: .awaitingApproval, headline: "", detail: "",
                          acceptance: [], hirds: [], events: [], startedAt: .now)
        issue.threadID = "issue-thread"
        issue.proposal = .init(instruction: "이슈", model: "provider/model")
        issue.milestoneID = "m"
        try await f.storeIssue(issue, projectID: "p")
        await #expect(throws: PersistenceError.self) { try await f.repository.deleteMilestone("m") }
        #expect(try await f.repository.milestones(projectID: "p").count == 1)
        try await f.repository.saveMilestone(f.milestone("n", order: 2))
        try await f.repository.deleteMilestone("n")
        #expect(try await f.repository.milestones(projectID: "p").map(\.id) == ["m"])
        try await f.repository.close()
    }

    /// Reordering is one transaction: a swap must never collide on the unique position.
    @Test func reorderAppliesAWholeOrderAtOnce() async throws {
        let f = try await MilestoneFixture.make()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        try await f.repository.saveMilestone(f.milestone("a", order: 0, title: "가"))
        try await f.repository.saveMilestone(f.milestone("b", order: 1, title: "나"))
        try await f.repository.saveMilestone(f.milestone("c", order: 2, title: "다"))
        try await f.repository.reorderMilestones(projectID: "p", orderedIDs: ["c", "a", "b"])
        #expect(try await f.repository.milestones(projectID: "p").map(\.id) == ["c", "a", "b"])
        #expect(try await f.repository.milestones(projectID: "p").map(\.order) == [0, 1, 2])
        // A partial list is rejected and changes nothing.
        await #expect(throws: PersistenceError.self) {
            try await f.repository.reorderMilestones(projectID: "p", orderedIDs: ["c", "a"])
        }
        #expect(try await f.repository.milestones(projectID: "p").map(\.id) == ["c", "a", "b"])
        try await f.repository.close()
    }

    @Test func v5StoreMigratesToMilestoneSchemaWithoutTouchingExistingWork() async throws {
        let base = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let root = ProcessInfo.processInfo.environment["KNARR_TEST_FIXTURE_ROOT"] ?? base.appendingPathComponent("outputs/milestone-fixtures").path
        let directory = URL(fileURLWithPath: root).appendingPathComponent("knarr-milestone-migration-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("legacy.sqlite")
        try makeTransferLegacyFixture(at: url, version: 4)
        let writer = try SQLiteConnection(path: url.path, flags: 2)
        try writer.execute("CREATE TABLE project_transfers (id TEXT PRIMARY KEY NOT NULL, project_id TEXT NOT NULL REFERENCES projects(id), thread_id TEXT NOT NULL REFERENCES threads(id), request_message_id TEXT UNIQUE NOT NULL REFERENCES chat(id), payload TEXT NOT NULL)")
        try writer.execute("CREATE TABLE project_transfer_messages (transfer_id TEXT NOT NULL REFERENCES project_transfers(id), message_id TEXT NOT NULL REFERENCES chat(id), ordinal INTEGER NOT NULL CHECK(ordinal>=0), PRIMARY KEY(transfer_id,message_id), UNIQUE(transfer_id,ordinal))")
        try writer.execute("PRAGMA user_version=5")
        let originalIssues = try writer.rows("SELECT id,project_id,payload FROM issues")
        let originalChat = try writer.rows("SELECT id,project_id,payload FROM chat")
        try writer.close()
        let db = try await SQLiteKnarrRepository.open(at: url)
        let snapshot = try await db.snapshot()
        #expect(snapshot.milestones.isEmpty)
        #expect(snapshot.issues.map(\.milestoneID) == [nil])
        #expect(snapshot.chat.first?.kind == .user("원문 · 첨부"))
        var milestone = Milestone(id: "m", projectID: "p", order: 1, title: "이전에서 이어짐")
        milestone.status = .active
        try await db.saveMilestone(milestone)
        try await db.close()
        let migrated = try SQLiteConnection(path: url.path, flags: 1)
        #expect(try migrated.rows("PRAGMA user_version") == [["8"]])
        #expect(try migrated.rows("PRAGMA foreign_key_check").isEmpty)
        #expect(try migrated.rows("SELECT id,project_id,payload FROM issues") == originalIssues)
        #expect(try migrated.rows("SELECT id,project_id,payload FROM chat") == originalChat)
        try migrated.close()
        let reopened = try await SQLiteKnarrRepository.open(at: url)
        let reloaded = try #require(try await reopened.milestones(projectID: "p").first)
        #expect(reloaded.id == milestone.id && reloaded.title == milestone.title)
        #expect(reloaded.updatedAt >= milestone.updatedAt)
        #expect(reloaded.targetDateHistory.isEmpty)
        // v7 adds project weekly plans without touching stored milestones or their weeks.
        #expect(try await reopened.snapshot().weekPlans.isEmpty)
        #expect(try await reopened.milestone("m")?.weeks == milestone.weeks)
        #expect(try await reopened.snapshot().chat == snapshot.chat)
        try await reopened.close()
    }
}
