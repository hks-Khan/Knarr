import Foundation
import Testing
@testable import KnarrCore

@Suite struct WorkReportTests {
    static func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }
    static var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Asia/Seoul")!; c.firstWeekday = 2; return c }
    @Test func waitsUntilNineAndCatchesUpEveryMissingDayAndWeek() {
        let d = Self.date
        let daily = d("2026-10-19T00:00:00+09:00"), weekly = daily
        #expect(WorkReportPeriod.due(now: d("2026-10-19T08:59:59+09:00"), dailyEnd: daily, weeklyEnd: weekly, calendar: Self.calendar).isEmpty)
        let due = WorkReportPeriod.due(now: d("2026-10-21T09:00:00+09:00"), dailyEnd: daily, weeklyEnd: weekly, calendar: Self.calendar)
        #expect(due.filter { $0.kind == .daily }.count == 3)
        #expect(due.filter { $0.kind == .weekly }.count == 1)
        #expect(due.first { $0.kind == .weekly }?.start == d("2026-10-12T00:00:00+09:00"))
        #expect(Set(due.map(\.id)).count == 4)
    }
    @Test func clipsMidnightAndCountsOverlappingRunsOnlyOnceForElapsedTime() {
        let d = Self.date
        let bounds = DateInterval(start: d("2026-10-20T00:00:00+09:00"), end: d("2026-10-21T00:00:00+09:00"))
        let result = WorkReportTime.measure([
            .init(start: d("2026-10-19T23:00:00+09:00"), end: d("2026-10-20T02:00:00+09:00")),
            .init(start: d("2026-10-20T01:00:00+09:00"), end: d("2026-10-20T03:00:00+09:00")),
            .init(start: d("2026-10-20T23:00:00+09:00"), end: d("2026-10-21T02:00:00+09:00"))
        ], within: bounds)
        #expect(result.total == 5 * 3600)
        #expect(result.elapsed == 4 * 3600)
    }
    @Test func calendarBoundariesSurviveDaylightSavingChange() throws {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!; calendar.firstWeekday = 2
        let end = Self.date("2026-11-02T00:00:00-08:00")
        let result = WorkReportPeriod.due(now: Self.date("2026-11-02T09:00:00-08:00"), dailyEnd: end, weeklyEnd: end, calendar: calendar)
        let daily = try #require(result.first { $0.kind == .daily }); #expect(daily.end.timeIntervalSince(daily.start) == 25 * 3600)
    }
    @Test func archivedAndFailedWorkRemainsInReportAndSuccessIsNotJudgement() async throws {
        let f = try await StallariFixture.make()
        do {
            let id = try await f.issue("report-issue")
            let run = try await f.dispatch("report-run", issue: id)
            _ = try await f.session.receive(.init(id: "report-result", runID: run, at: .now,
                payload: .complete(f.result(), notificationID: "report-notice")))
            try await f.session.judge(issueID: id, runID: run, evidence: [.init(criterionIndex: 0, verificationIDs: ["v"], explanation: "검증 미충족", met: false)])
            let snapshot = try await f.repository.snapshot(includeHistory: false)
            let period = WorkReportPeriod(kind: .daily, start: .now.addingTimeInterval(-86400), end: .now.addingTimeInterval(1), timeZoneID: "Asia/Seoul")
            let report = WorkReport.build(period: period, snapshot: snapshot, at: .now)
            #expect(report.items.count == 1)
            #expect(report.items.first?.outcome == "완료 조건 미충족")
            #expect(report.items.first?.runs.first?.state == "succeeded")
            #expect(report.time.total > 0)
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }
    @Test func archiveReopensWithoutDuplicatesAndDoesNotAdvanceOnFailedWrite() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("knarr-report-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Self.date("2026-10-21T09:00:00+09:00")
        var archive = WorkReportArchive(now: now, calendar: Self.calendar)
        let period = WorkReportPeriod(kind: .daily, start: now.addingTimeInterval(-86400), end: Self.calendar.startOfDay(for: now), timeZoneID: "Asia/Seoul")
        let report = WorkReport(period: period, generatedAt: now, items: [], time: .init(total: 0, elapsed: 0), failures: [:], plans: [])
        archive.record(report); archive.record(report)
        let url = directory.appendingPathComponent("reports.json")
        try archive.save(to: url)
        let loaded = try WorkReportArchive.load(from: url, now: now, calendar: Self.calendar)
        #expect(loaded.reports.count == 1)
        #expect(loaded.dailyEnd > period.end)
        #expect(throws: (any Error).self) { try archive.save(to: directory) }
        #expect(try WorkReportArchive.load(from: url, now: now, calendar: Self.calendar) == loaded)
    }

}
