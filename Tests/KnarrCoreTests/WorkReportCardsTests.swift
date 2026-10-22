import Foundation
import Testing
@testable import KnarrCore

/// The saved archive already covers the fixed period, so these launches never need a storage read.
private enum UnusedSnapshot: Error { case noCallRequired }

/// The main conversation shows one card per generated report, derived from the saved report rather
/// than appended chat. A restart, a regenerated analysis and a retry must all land on that same row.
@MainActor @Suite struct WorkReportCardsTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private func period(_ kind: WorkReportPeriod.Kind, days: Double = 1) -> WorkReportPeriod {
        .init(kind: kind, start: now.addingTimeInterval(-days * 86_400), end: now, timeZoneID: "Asia/Seoul")
    }
    private func report(_ kind: WorkReportPeriod.Kind = .daily, state: WorkReport.AnalysisState = .ready,
                        items: [WorkReportItem] = []) -> WorkReport {
        var report = WorkReport(period: period(kind), generatedAt: now, items: items,
                                time: WorkReportTime(total: 7_200, elapsed: 6_000), failures: [:], plans: [])
        report.analysisState = state
        return report
    }
    private func item(_ id: String, _ outcome: String) -> WorkReportItem {
        .init(id: id, project: "Knarr", title: "합성 작업 " + id, reason: "이유", outcome: outcome,
              applicationRecord: "기록 없음", criteria: [], runs: [], time: .init(total: 3_600, elapsed: 3_000))
    }

    @Test func oneStableRowPerReportAcrossRestartsAndRegeneration() {
        let first = report()
        let id = WorkReportCards.messageID(for: first)
        // The same saved report yields the same row after a relaunch.
        #expect(WorkReportCards.messageID(for: first) == id)
        #expect(WorkReportCards.messageID(reportID: first.id) == id)
        var regenerated = first
        regenerated.analysis = "새 분석"
        #expect(WorkReportCards.item(for: regenerated)?.id == id)
        // Two different periods never share a row.
        #expect(WorkReportCards.messageID(for: report(.weekly)) != id)
    }

    @Test func transcriptAddsEachVisibleReportOnceAndKeepsOrder() {
        let chat = [ChatItem(at: now.addingTimeInterval(-3_600), kind: .user("메인 요청")),
                    ChatItem(at: now.addingTimeInterval(-1_800), kind: .stallari("답변", project: nil))]
        let daily = report()
        let weekly = report(.weekly)
        let once = WorkReportCards.transcript(chat, reports: [daily, weekly], threadID: ConversationThread.defaultID)
        #expect(once.count == 4)
        // Calling it again with its own output adds nothing: the identity already exists.
        let twice = WorkReportCards.transcript(once, reports: [daily, weekly], threadID: ConversationThread.defaultID)
        #expect(twice.count == 4)
        #expect(twice.map(\.id) == once.map(\.id))
        // Reports belong to the main conversation only.
        #expect(WorkReportCards.transcript(chat, reports: [daily], threadID: "issue-1").count == 2)
    }

    @Test func pendingReportsStayHiddenAndRetryUpdatesTheSameRow() {
        var failed = report(state: .failed, items: [item("a", "완료 조건 충족")])
        #expect(WorkReportCards.item(for: report(state: .pending)) == nil)
        // Posting happens when the analysis ends, so an unfinished analysis adds no message.
        #expect(WorkReportCards.item(for: report(state: .generating)) == nil)
        let failedRow = WorkReportCards.item(for: failed)
        #expect(failedRow?.id == WorkReportCards.messageID(for: failed))
        // A retry changes only the saved analysis; the row identity and position do not move.
        failed.analysisState = .ready
        failed.analysis = "분석 완료"
        failed.analysisError = nil
        let retried = WorkReportCards.item(for: failed)
        #expect(retried?.id == failedRow?.id)
        #expect(retried?.at == failedRow?.at)
        // While the retry is pending or generating the row stays, so the card never disappears.
        var retrying = failed
        for state in [WorkReport.AnalysisState.pending, .generating] {
            retrying.analysisState = state
            let rows = WorkReportCards.transcript([], reports: [retrying], threadID: ConversationThread.defaultID,
                                                  including: [retrying.id])
            #expect(rows.map(\.id) == [WorkReportCards.messageID(for: failed)])
        }
        #expect(WorkReportCards.lines(for: failed).count >= 2)
        #expect(WorkReportCards.lines(for: failed).contains { $0.contains("완료 1") })
    }

    @Test func linesReportRealCountsAndAttentionOnlyWhenPresent() {
        let quiet = report(items: [item("a", "완료 조건 충족"), item("b", "실행 중")])
        let lines = WorkReportCards.lines(for: quiet)
        #expect(lines[0].contains("작업 2개"))
        #expect(lines[0].contains("누적 2시간"))
        #expect(lines[1].contains("완료 1") && lines[1].contains("진행 중 1") && lines[1].contains("답변 필요 0"))
        #expect(lines.count == 2)
        var busy = quiet
        busy.failures = ["코드 스냅샷 저장": 2]
        busy = WorkReport(period: busy.period, generatedAt: busy.generatedAt,
                          items: [item("a", "완료 조건 충족"), item("c", "답변 필요")],
                          time: busy.time, failures: busy.failures, plans: busy.plans)
        #expect(WorkReportCards.lines(for: busy).contains { $0.hasPrefix("주의") && $0.contains("실패 원인") })
    }

    @Test func analysisCompletionPublishesTheCardAndRelaunchDoesNotDuplicateIt() async throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("outputs/report-cards/\(UUID())/work-reports.json")
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: directory.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fixedNow = Date(timeIntervalSince1970: 1_790_000_000)
        let calendar = Calendar(identifier: .gregorian)
        var state = WorkReportArchive(now: fixedNow, calendar: calendar)
        state.record(report())
        // The first launch persists nothing new; an existing archive is read back as the same row.
        try state.save(to: directory)
        let controller = WorkReportController(url: directory, snapshot: { throw UnusedSnapshot.noCallRequired },
                                              analyze: { report, _ in "합성 분석 " + report.id }, now: { fixedNow })
        await controller.start()
        #expect(controller.reports.count == 1)
        let firstCard: [ChatItem] = WorkReportCards.transcript([], reports: controller.reports, threadID: ConversationThread.defaultID)
        #expect(firstCard.count == 1)
        // A second launch over the same file produces the identical card.
        let relaunched = WorkReportController(url: directory, snapshot: { throw UnusedSnapshot.noCallRequired },
                                              analyze: { report, _ in "다른 분석 " + report.id }, now: { fixedNow })
        await relaunched.start()
        let secondCard: [ChatItem] = WorkReportCards.transcript([], reports: relaunched.reports, threadID: ConversationThread.defaultID)
        #expect(secondCard.map(\.id) == firstCard.map(\.id))
        await controller.shutdown(); await relaunched.shutdown()
    }
}
