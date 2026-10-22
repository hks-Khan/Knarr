import Foundation
import Testing
@testable import KnarrCore

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["KNARR_REPORT_LIVE_DB"] != nil))
struct WorkReportLiveTests {
    @Test func selectedStallariModelAnalyzesSavedDayWithoutActionTools() async throws {
        let environment = ProcessInfo.processInfo.environment
        let database = URL(fileURLWithPath: try #require(environment["KNARR_REPORT_LIVE_DB"]))
        let root = database.deletingLastPathComponent()
        let repository = try await SQLiteKnarrRepository.open(at: database)
        do {
            let snapshot = try await repository.snapshot(includeHistory: false)
            let period = WorkReportPeriod(kind: .daily, start: WorkReportTests.date("2026-10-20T00:00:00+09:00"), end: WorkReportTests.date("2026-10-21T00:00:00+09:00"), timeZoneID: "Asia/Seoul")
            var report = WorkReport.build(period: period, snapshot: snapshot, at: .now)
            #expect(report.runCount == 84)
            #expect(abs(report.time.total - 117941.5377) < 1)
            #expect(report.failures["코드 스냅샷 저장"] == 45)
            let installation = try OMPInstallation(executable: URL(fileURLWithPath: try #require(environment["KNARR_OMP_EXECUTABLE"])))
            let model = try #require(environment["KNARR_REPORT_LIVE_MODEL"])
            let configuration = try WorkReportAnalyzer.configuration(installation: installation, directory: root.appendingPathComponent("launch"), model: model, thinking: "high", environment: environment)
            #expect(configuration.arguments.contains("--no-tools"))
            #expect(configuration.arguments.contains("--no-extensions"))
            report.analysis = try await WorkReportAnalyzer.run(report: report, previous: nil, configuration: configuration)
            report.analysisState = .ready; report.analysisModel = model
            #expect(!report.analysis.isEmpty)
            let output = root.deletingLastPathComponent().appendingPathComponent("live-report.json")
            try JSONEncoder().encode(report).write(to: output, options: .atomic)
            try await repository.close()
        } catch { try? await repository.close(); throw error }
    }
}


@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["KNARR_REPORT_LOCAL_DB"] != nil))
struct WorkReportLocalDataTests {
    @Test func savedDayMatchesIndependentlyCalculatedTotals() async throws {
        let url = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["KNARR_REPORT_LOCAL_DB"]))
        let repository = try await SQLiteKnarrRepository.open(at: url)
        do {
            let snapshot = try await repository.snapshot(includeHistory: false)
            let period = WorkReportPeriod(kind: .daily, start: WorkReportTests.date("2026-10-20T00:00:00+09:00"), end: WorkReportTests.date("2026-10-21T00:00:00+09:00"), timeZoneID: "Asia/Seoul")
            let report = WorkReport.build(period: period, snapshot: snapshot, at: .now)
            #expect(report.runCount == 84)
            #expect(report.items.filter { !$0.runs.isEmpty }.count == 14)
            #expect(abs(report.time.total - 117941.5377) < 1)
            #expect(abs(report.time.elapsed - 40509) < 1)
            #expect(report.failures["코드 스냅샷 저장"] == 45)
            try JSONEncoder().encode(report).write(to: url.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("local-report.json"), options: .atomic)
            try await repository.close()
        } catch { try? await repository.close(); throw error }
    }
}
