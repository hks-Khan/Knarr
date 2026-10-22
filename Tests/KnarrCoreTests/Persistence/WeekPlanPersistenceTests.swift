import Foundation
import Testing
@testable import KnarrCore

private struct WeekPlanFixture: Sendable {
    let directory: URL
    let repository: SQLiteKnarrRepository
    var url: URL { directory.appendingPathComponent("weekly.sqlite") }
    static func make() async throws -> Self {
        let base = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let root = ProcessInfo.processInfo.environment["KNARR_TEST_FIXTURE_ROOT"] ?? base.appendingPathComponent("outputs/milestone-fixtures").path
        let directory = URL(fileURLWithPath: root).appendingPathComponent("knarr-weekly-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let repository = try await SQLiteKnarrRepository.open(at: directory.appendingPathComponent("weekly.sqlite"))
        try await repository.saveProject(.init(id: "p", name: "프로젝트", absolutePath: directory.path))
        try await repository.saveProject(.init(id: "other", name: "다른 프로젝트", absolutePath: directory.appendingPathComponent("other").path))
        try await repository.saveProject(.init(id: "archived", name: "보관", absolutePath: directory.appendingPathComponent("archived").path,
                                               archivedAt: .now))
        return .init(directory: directory, repository: repository)
    }
    func plan(_ lines: [String], at date: Date, project: String = "p") -> ProjectWeekPlan {
        .init(projectID: project, weekStart: ProjectWeek.start(containing: date), plan: lines, recordedAt: date)
    }
}

@Suite(.serialized) struct WeekPlanPersistenceTests {
    @Test func onlyTheCurrentWeekIsWritableAndEarlierPlansStayAsHistory() async throws {
        let f = try await WeekPlanFixture.make()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let now = Date.now
        let thisWeek = ProjectWeek.start(containing: now)
        let lastWeek = ProjectWeek.start(containing: now.addingTimeInterval(-7 * 86400))

        // A past or future week is rejected even when the payload claims to be current.
        await #expect(throws: PersistenceError.self) {
            try await f.repository.saveWeekPlan(f.plan(["지난주 소급"], at: lastWeek))
        }
        await #expect(throws: PersistenceError.self) {
            try await f.repository.saveWeekPlan(f.plan(["다음 주"], at: thisWeek.addingTimeInterval(7 * 86400)))
        }
        await #expect(throws: PersistenceError.self) {
            try await f.repository.saveWeekPlan(f.plan(["보관 프로젝트"], at: now, project: "archived"))
        }
        #expect(try await f.repository.weekPlans(projectID: "p").isEmpty)

        try await f.repository.saveWeekPlan(f.plan([" 첫 계획 ", "", "둘째 계획", "첫 계획"], at: now))
        var stored = try #require(try await f.repository.weekPlans(projectID: "p").first)
        #expect(stored.weekStart == thisWeek)
        #expect(stored.plan == ["첫 계획", "둘째 계획"])
        #expect(stored.recordedAt >= now.addingTimeInterval(-60))

        // The same week is revised in place, the client's recordedAt is replaced by the server clock.
        var revision = f.plan(["고친 계획"], at: now)
        revision.recordedAt = .distantPast
        try await f.repository.saveWeekPlan(revision, at: now.addingTimeInterval(5))
        stored = try #require(try await f.repository.weekPlans(projectID: "p").first)
        #expect(stored.plan == ["고친 계획"])
        #expect(stored.recordedAt >= now)

        // A forged history row from an earlier week cannot be inserted.
        var backfill = f.plan(["소급"], at: now)
        backfill.weekStart = lastWeek
        await #expect(throws: PersistenceError.self) { try await f.repository.saveWeekPlan(backfill) }
        #expect(try await f.repository.weekPlans(projectID: "p").map(\.weekStart) == [thisWeek])

        try await f.repository.close()
        let reopened = try await SQLiteKnarrRepository.open(at: f.url)
        #expect(try await reopened.weekPlans(projectID: "p").first?.plan == ["고친 계획"])
        try await reopened.close()
    }

    @Test func v6StoreMigratesToWeeklyPlansAndKeepsMilestoneWeeks() async throws {
        let f = try await WeekPlanFixture.make()
        let url = f.url
        try await f.repository.saveMilestone(.init(id: "m", projectID: "p", order: 0, title: "단계",
            weeks: [.init(weekStart: ProjectWeek.start(containing: .now), scope: ["마일스톤 기록"],
                          result: "유지", recordedAt: .now)]))
        try await f.repository.close()
        // Drop back to the v6 shape: no project_weeks table.
        let raw = try SQLiteConnection(path: url.path, flags: 2)
        try raw.execute("DROP TABLE project_preparations")
        try raw.execute("DROP TABLE project_weeks")
        try raw.execute("PRAGMA user_version=6")
        let before = try raw.rows("SELECT id,project_id,payload FROM milestones")
        try raw.close()

        let migrated = try await SQLiteKnarrRepository.open(at: url)
        #expect(try await migrated.snapshot().weekPlans.isEmpty)
        let milestone = try #require(try await migrated.milestone("m"))
        #expect(milestone.weeks.map(\.scope) == [["마일스톤 기록"]])
        try await migrated.saveWeekPlan(f.plan(["이번 주"], at: .now))
        try await migrated.close()

        let check = try SQLiteConnection(path: url.path, flags: 1)
        #expect(try check.rows("PRAGMA user_version") == [["8"]])
        #expect(try check.rows("SELECT id,project_id,payload FROM milestones") == before)
        #expect(try check.rows("PRAGMA foreign_key_check").isEmpty)
        try check.close()
        try? FileManager.default.removeItem(at: f.directory)
    }

    @Test func weeklyResultsComeFromJudgedIssuesAndLeaveMilestonesUnreached() {
        let now = Date.now
        let thisWeek = ProjectWeek.start(containing: now)
        let daily = Calendar.current
        let inside = daily.date(byAdding: .hour, value: 2, to: thisWeek) ?? thisWeek
        func record(_ id: String, _ state: IssueState, completed: Date?, milestone: Milestone.ID? = nil,
                    archived: Bool = false) -> KnarrCore.Issue {
            var value = KnarrCore.Issue(id: .init(id), title: "이슈 " + id, projectName: "프로젝트", state: state,
                              headline: "", detail: "", acceptance: [], hirds: [], events: [],
                              startedAt: thisWeek, completedAt: completed)
            value.milestoneID = milestone
            value.archivedAt = archived ? now : nil
            return value
        }
        let milestones = [Milestone(id: "m1", projectID: "p", order: 0, title: "1단계")]
        let priorWeek = ProjectWeek.start(containing: now.addingTimeInterval(-8 * 86400))
        let results = ProjectWeek.results(issues: [
            record("done", .done, completed: inside, milestone: "m1"),
            record("pending", .running, completed: nil),
            record("approval", .awaitingApproval, completed: nil),
            record("closed", .done, completed: inside, archived: true),
            record("old", .done, completed: priorWeek),
            record("plain", .done, completed: inside)
        ], milestones: milestones, weekStart: thisWeek)
        #expect(results.map(\.id) == ["done", "plain"])
        #expect(results.first?.milestoneTitle == "1단계")
        #expect(results.last?.milestoneTitle == nil)
        #expect(milestones[0].status == .planned)
        #expect(!milestones[0].isReached)
    }
}
