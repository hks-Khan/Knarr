import Foundation
import Testing
@testable import KnarrCore

private actor ReportAnalysisCounter {
    var calls = 0
    var fails = false
    func setFailure(_ value: Bool) { fails = value }
    func analyze() throws -> String { calls += 1; if fails { throw WorkReportAnalyzer.Failure.incomplete }; return "작업 근거를 확인했어요. 다음 보고에서 재시도 비율을 비교하세요." }
}
actor WorkReportFakeRPC: HirdRPC {
    let stream: AsyncStream<OMPEvent>
    let continuation: AsyncStream<OMPEvent>.Continuation
    var shutdowns = 0
    var tool = false
    var hang = false
    var stopReason = "stop"
    init(tool: Bool = false, hang: Bool = false, stopReason: String = "stop") { let pair = AsyncStream<OMPEvent>.makeStream(); stream = pair.stream; continuation = pair.continuation; self.tool = tool; self.hang = hang; self.stopReason = stopReason }
    func start(_ configuration: OMPLaunchConfiguration) async throws {}
    func subscribe() -> AsyncStream<OMPEvent> { stream }
    func send(_ command: String, fields: [String: OMPJSON]) async throws {}
    func request(_ command: String, fields: [String: OMPJSON], timeout: Duration) async throws -> OMPJSON {
        if command == "prompt", !hang {
            if tool { continuation.yield(.frame(.object(["type": .string("host_tool_call")]))) }
            let block: OMPJSON = .object(["type": .string("text"), "text": .string("근거 있는 보고")])
            let message: OMPJSON = .object(["role": .string("assistant"), "stopReason": .string(stopReason), "content": .array([block])])
            continuation.yield(.frame(.object(["type": .string("message_end"), "message": message])))
            continuation.yield(.frame(.object(["type": .string("prompt_result"), "id": .string("report-prompt"), "status": .string("completed"), "sessionSettled": .bool(true)])))
        }
        return .object(["id": .string("report-prompt")])
    }
    func shutdown(cancel: Bool) -> OMPProcessExit { shutdowns += 1; continuation.finish(); return .init(status: 0, reason: .normal, remainingProcessIDs: []) }
}
@Suite(.serialized) struct WorkReportRuntimeTests {
    static var now: Date { WorkReportTests.date("2026-10-21T09:00:00+09:00") }
    static var source: PersistenceSnapshot {
        let issue = Issue(id: "report-i", title: "보고 검증", projectName: "Knarr", state: .failed, headline: "검사 미충족", detail: "", acceptance: [.init(text: "검사 통과", state: .unmet, evidence: "실패 원문")], hirds: [], events: [], startedAt: now.addingTimeInterval(-12 * 3600))
        return .init(projects: [], threads: [], issues: [issue], issueProjects: [:], chat: [], chatLinks: [], runs: [], questions: [], notifications: [])
    }
    static func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("knarr-report-runtime-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true); return url
    }
    @MainActor @Test func repeatedWakeAndReopenDoNotRegenerateReports() async throws {
        let directory = try Self.directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("reports.json"), counter = ReportAnalysisCounter()
        let controller = WorkReportController(url: url, snapshot: { Self.source }, analyze: { _, _ in try await counter.analyze() }, now: { Self.now })
        await controller.start(); await controller.whenIdle(); controller.wake(); await controller.whenIdle()
        #expect(controller.reports.count == 2)
        #expect(await counter.calls == 1)
        #expect(controller.reports.first { $0.period.kind == .daily }?.analysisState == .ready)
        await controller.shutdown()
        let reopened = WorkReportController(url: url, snapshot: { Self.source }, analyze: { _, _ in try await counter.analyze() }, now: { Self.now })
        await reopened.start(); await reopened.whenIdle()
        #expect(await counter.calls == 1)
        #expect(reopened.reports.count == 2)
        await reopened.shutdown()
    }
    @MainActor @Test func failedAnalysisKeepsEvidenceAndRetriesOnlyOnRequest() async throws {
        let directory = try Self.directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let counter = ReportAnalysisCounter(); await counter.setFailure(true)
        let controller = WorkReportController(url: directory.appendingPathComponent("reports.json"), snapshot: { Self.source }, analyze: { _, _ in try await counter.analyze() }, now: { Self.now })
        await controller.start(); await controller.whenIdle()
        let report = try #require(controller.reports.first { $0.period.kind == .daily })
        #expect(report.items.count == 1); #expect(report.analysisState == .failed)
        controller.wake(); await controller.whenIdle(); #expect(await counter.calls == 1)
        await counter.setFailure(false); controller.retry(report.id); await controller.whenIdle()
        #expect(await counter.calls == 2)
        #expect(controller.reports.first { $0.id == report.id }?.analysisState == .ready)
        await controller.shutdown()
    }
    @Test func interruptedAnalysisAndCorruptArchiveAreNotSilentlyDiscarded() throws {
        let directory = try Self.directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("reports.json")
        var archive = WorkReportArchive(now: Self.now, calendar: WorkReportTests.calendar)
        let period = WorkReportPeriod(kind: .daily, start: Self.now.addingTimeInterval(-86400), end: Self.now, timeZoneID: "Asia/Seoul")
        var report = WorkReport.build(period: period, snapshot: Self.source, at: Self.now); report.analysisState = .generating
        archive.record(report); try archive.save(to: url)
        let reopened = try WorkReportArchive.load(from: url, now: Self.now, calendar: WorkReportTests.calendar)
        #expect(reopened.reports.first?.analysisState == .failed)
        #expect(reopened.reports.first?.items == report.items)
        try Data("broken".utf8).write(to: url)
        #expect(throws: (any Error).self) { try WorkReportArchive.load(from: url, now: Self.now, calendar: WorkReportTests.calendar) }
        #expect(try Data(contentsOf: url) == Data("broken".utf8))
    }
    @Test func rpcCompletionAndRejectedToolsAlwaysCleanUp() async throws {
        let configuration = OMPLaunchConfiguration(executable: URL(fileURLWithPath: "/usr/bin/true"), workingDirectory: .temporaryDirectory)
        let period = WorkReportPeriod(kind: .daily, start: Self.now.addingTimeInterval(-86400), end: Self.now, timeZoneID: "Asia/Seoul")
        let report = WorkReport.build(period: period, snapshot: Self.source, at: Self.now)
        let good = WorkReportFakeRPC()
        #expect(try await WorkReportAnalyzer.run(report: report, previous: nil, configuration: configuration, rpc: good) == "근거 있는 보고")
        #expect(await good.shutdowns == 1)
        let bad = WorkReportFakeRPC(tool: true)
        await #expect(throws: (any Error).self) { try await WorkReportAnalyzer.run(report: report, previous: nil, configuration: configuration, rpc: bad) }
        #expect(await bad.shutdowns == 1)
        let timed = WorkReportFakeRPC(hang: true)
        await #expect(throws: (any Error).self) { try await WorkReportAnalyzer.run(report: report, previous: nil, configuration: configuration, rpc: timed, timeout: .milliseconds(20)) }
        #expect(await timed.shutdowns == 1)
    }
    @MainActor @Test func failedGeneratingWriteCanResumeWithoutRestartingTheApp() async throws {
        let directory = try Self.directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("reports.json"), backup = directory.appendingPathComponent("saved.json")
        let counter = ReportAnalysisCounter()
        var injected = false
        let controller = WorkReportController(url: url, snapshot: { Self.source }, analyze: { _, _ in try await counter.analyze() }, model: {
            if !injected {
                injected = true
                try? FileManager.default.moveItem(at: url, to: backup)
                try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            }
            return "fixture"
        }, now: { Self.now })
        await controller.start(); await controller.whenIdle()
        #expect(controller.error != nil)
        #expect(await counter.calls == 0)
        try FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: backup, to: url)
        controller.retry(); await controller.whenIdle()
        #expect(await counter.calls == 1)
        #expect(controller.reports.first { $0.period.kind == .daily }?.analysisState == .ready)
        await controller.shutdown()
    }
    @Test func lengthLimitedAnalysisCannotBecomeACompletedReport() async throws {
        let configuration = OMPLaunchConfiguration(executable: URL(fileURLWithPath: "/usr/bin/true"), workingDirectory: .temporaryDirectory)
        let period = WorkReportPeriod(kind: .daily, start: Self.now.addingTimeInterval(-86400), end: Self.now, timeZoneID: "Asia/Seoul")
        let report = WorkReport.build(period: period, snapshot: Self.source, at: Self.now)
        let rpc = WorkReportFakeRPC(stopReason: "length")
        await #expect(throws: (any Error).self) { try await WorkReportAnalyzer.run(report: report, previous: nil, configuration: configuration, rpc: rpc) }
        #expect(await rpc.shutdowns == 1)
    }

}
