import AppKit
import Foundation
import Testing
import KnarrCore
import KnarrSync
@testable import KnarrMirror

/// The phone mirror runs while Hird is working. Its projection reads report text and screenshot
/// files, so it must not need the main thread, and a repeated snapshot must not re-read the disk.
@Suite(.serialized) struct MobileProjectionThreadTests {
    private func root() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("knarr-mirror-thread-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func picture(at url: URL) throws {
        let pixels = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: pixels)
        NSColor.systemTeal.setFill(); NSRect(x: 0, y: 0, width: 64, height: 64).fill()
        NSGraphicsContext.restoreGraphicsState()
        try #require(pixels.representation(using: .png, properties: [:])).write(to: url)
    }

    /// A run whose result names a report and one screenshot, the two files the projection reads.
    private func issue(report: URL, shot: URL, at date: Date) -> KnarrCore.Issue {
        var issue = KnarrCore.Issue(id: "mirror", title: "미러", projectName: "Calc", state: .done,
            headline: "Hird 1명", detail: "", acceptance: [Criterion(text: "통과", state: .met, evidence: "swift test → 0")],
            hirds: [HirdRun(id: "r", name: "Hird-1", role: "고치기", status: .done(at: date),
                            steps: [HirdStep(title: "고치기", state: .done)], currentCommand: nil, lastActivityAt: date)],
            events: [ActivityEvent(at: date, actor: "Hird", text: "완료")], startedAt: date)
        issue.latestResult = RunResult(worktreePath: report.deletingLastPathComponent().path, branch: "b", commit: "c",
            diffPath: nil, summary: "요약", verifications: [VerificationRecord(id: "v", command: ["swift", "test"],
                workingDirectory: report.deletingLastPathComponent().path, startedAt: date, finishedAt: date,
                exitCode: 0, logPath: report.path, summary: "통과", attachmentPaths: [shot.path])],
            reportPath: report.path)
        return issue
    }

    @Test func projectionRunsOffTheMainThreadAndKeepsFilesOutOfIt() async throws {
        let dir = try root(); defer { try? FileManager.default.removeItem(at: dir) }
        let report = dir.appendingPathComponent("report.md")
        try Data("# 보고\n\n검증했습니다.".utf8).write(to: report)
        let shot = dir.appendingPathComponent("shot.png")
        try picture(at: shot)
        MobileIssueFiles.cache.clear()
        let source = MobileProjectionSource(issues: [issue(report: report, shot: shot, at: Date(timeIntervalSince1970: 1_800_000_000))],
            questions: [], chat: [], projects: [], stallari: .init(engine: "OMP", scope: ""), isResponding: true,
            threads: [.default], chatByThread: [:])
        // Not `@MainActor`: a background task builds every record, including the file reads.
        let records = await Task.detached(priority: .userInitiated) { source.records(now: Date(timeIntervalSince1970: 1_800_000_100)) }.value
        let mobile = try #require(records.compactMap { if case .issue(let value) = $0 { value } else { nil } }.first)
        #expect(mobile.report?.contains("검증했습니다") == true)
        #expect(mobile.captures?.count == 1)
        #expect(mobile.captures?.first?.data?.isEmpty == false)
        #expect(records.contains { if case .status(let s) = $0 { s.macRunning == true } else { false } })
    }

    @Test func unchangedFilesAreNotReadTwiceOnEachSnapshot() throws {
        let dir = try root(); defer { try? FileManager.default.removeItem(at: dir) }
        let report = dir.appendingPathComponent("report.md")
        try Data("보고 본문".utf8).write(to: report)
        let shot = dir.appendingPathComponent("shot.png")
        try picture(at: shot)
        MobileIssueFiles.cache.clear()
        let issue = issue(report: report, shot: shot, at: Date(timeIntervalSince1970: 1_800_000_000))
        let first = MobileIssueFiles.read(issue)
        #expect(first.report == "보고 본문")
        #expect(first.captures?.count == 1)
        let readsAfterFirst = MobileIssueFiles.cache.diskReads
        #expect(readsAfterFirst == 2, "report and thumbnail are read once each")
        // A second snapshot for an unchanged Issue asks the disk for nothing.
        let second = MobileIssueFiles.read(issue)
        #expect(second.report == first.report)
        #expect(second.captures?.first?.data == first.captures?.first?.data)
        #expect(MobileIssueFiles.cache.diskReads == readsAfterFirst)
        // A rewritten report (new modification time) is read again instead of the stale text.
        try Data("새 보고".utf8).write(to: report)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: report.path)
        #expect(MobileIssueFiles.readReport(report.path) == "새 보고")
        #expect(MobileIssueFiles.cache.diskReads == readsAfterFirst + 1)
    }

    @Test func missingFilesStayMissingRatherThanBeingCachedAsEmpty() throws {
        let dir = try root(); defer { try? FileManager.default.removeItem(at: dir) }
        MobileIssueFiles.cache.clear()
        let report = dir.appendingPathComponent("missing.md")
        #expect(MobileIssueFiles.readReport(report.path) == nil)
        try Data("나중에 생김".utf8).write(to: report)
        #expect(MobileIssueFiles.readReport(report.path) == "나중에 생김")
    }
}
