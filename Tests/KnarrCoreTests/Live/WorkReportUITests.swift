import AppKit
import SwiftUI
import WebKit
import Testing
@testable import KnarrCore
@testable import KnarrUI

@MainActor @Suite(.serialized, .enabled(if: KnarrUITests.enabled)) struct WorkReportUITests {
    private func value(_ node: NSObject, _ name: String) -> Any? {
        let selector = NSSelectorFromString(name)
        if node.responds(to: selector) { return node.perform(selector)?.takeUnretainedValue() }
        return nil
    }
    private func elements(_ node: NSObject) -> [NSObject] {
        [node] + ((value(node, "accessibilityChildren") as? [NSObject]) ?? []).flatMap(elements)
    }
    private func find(_ host: NSView, _ id: String) -> NSObject? {
        elements(host).first { value($0, "accessibilityIdentifier") as? String == id }
    }
    private func capture(_ host: NSView, name: String) throws {
        guard let path = ProcessInfo.processInfo.environment["KNARR_REPORT_SCREENSHOTS"] else { return }
        host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        let root = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try png.write(to: root.appendingPathComponent(name + ".png"))
    }
    /// Runs one expression in the transcript's web view and waits for a boolean result.
    private func web(_ harness: HomeHarness, _ expression: String) throws -> Bool {
        let web = try #require(harness.conversation)
        var result = false, replied = false
        web.evaluateJavaScript("(()=>{return (" + expression + ");})()") { value, _ in
            result = value as? Bool == true; replied = true
        }
        let deadline = Date().addingTimeInterval(10)
        while !replied && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        return result
    }
    private func waitWeb(_ harness: HomeHarness, _ expression: String, seconds: Double = 10) throws {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if try web(harness, expression) { return }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        Testing.Issue.record("web condition timed out: \(expression)")
        throw CocoaError(.coderReadCorrupt)
    }

    private func readyReport(issue: KnarrCore.Issue, now: Date) -> WorkReport {
        let period = WorkReportPeriod(kind: .daily, start: now.addingTimeInterval(-86400), end: now, timeZoneID: "Asia/Seoul")
        let item = WorkReportItem(id: issue.id.rawValue, project: issue.projectName, title: "이슈 카드와 상세 패널 개선", reason: "카드 클릭과 패널 너비 조절이 불편해 개선을 요청했어요.", outcome: "완료 조건 충족", applicationRecord: "본체 반영·설치 확인 기록 없음", criteria: [.init(text: "패널 너비 변경·재열기", state: .met, evidence: "UI 검사 통과, 화면 검증 완료")], runs: [.init(id: "sample-run", startedAt: now.addingTimeInterval(-19582), endedAt: now, state: "failed", stopReason: "코드 스냅샷 저장 실패", previousRunID: nil, model: nil)], time: .init(total: 19582, elapsed: 19582))
        var report = WorkReport(period: period, generatedAt: now, items: [item], time: item.time, failures: ["코드 스냅샷 저장": 1], plans: ["Knarr: 사용성 개선"])
        report.analysisState = .ready
        report.analysis = "**주요 결과**\n\n카드와 상세 패널의 동작 검증을 마쳤어요. 본체 반영은 확인이 필요해요.\n\n**개선 후보**\n\n중간 스냅샷 실패가 반복됐어요. 다음 기간에 같은 오류의 발생률을 비교하세요. 실패 실행 전체를 낭비로 계산하지 않았어요."
        return report
    }

    @Test func mainConversationShowsTheReportCardOnceAndTheRecordPageOpensItsDetail() async throws {
        let store = SampleKnarrStore()
        let now = Date()
        let issue = try #require(store.issues.first)
        let report = readyReport(issue: issue, now: now)
        store.workReports = [report]
        let h = HomeHarness(width: 1100, height: 850, store: store)
        defer { h.close() }
        await h.waitWeb(); h.settle()
        let host = try #require(h.window.contentView)
        // The report is a card in the main conversation, and the old always-on header summary is gone.
        try waitWeb(h, "document.querySelector('.report-card') !== null")
        #expect(try web(h, "document.querySelectorAll('.report-card').length === 1"))
        #expect(try web(h, "document.querySelector('.report-card').textContent.includes('일일 작업 보고')"))
        #expect(try web(h, "document.querySelector('.report-card').textContent.includes('완료 1')"))
        #expect(find(host, "work-report-card-daily") == nil)
        try capture(host, name: "main-report-card")

        // Opening the card's report lands on the same saved report in the record page.
        var opened = false
        _ = try web(h, "(()=>{const b=[...document.querySelectorAll('.report-card button')].find(e=>e.textContent==='보고서 열기');if(!b)return false;b.click();return true;})()")
        for _ in 0..<100 where !opened {
            h.settle(0.05)
            opened = find(host, "work-report-detail") != nil
        }
        #expect(opened)
        let open = try #require(find(host, "report-issue-" + issue.id.rawValue) ?? elements(host).first { value($0, "accessibilityLabel") as? String == "이슈 열기" })
        _ = open.perform(NSSelectorFromString("accessibilityPerformPress"))
        h.settle()
        #expect(find(host, "issue-drawer") != nil)
    }

    @Test func failedAnalysisCardRetriesInPlaceWithoutAddingACard() async throws {
        let store = ChangingCardsStore()
        let now = Date()
        var report = readyReport(issue: ChangingCardsStore.card("report-target"), now: now)
        report.analysisState = .failed
        report.analysisError = "Stallari 분석을 완료하지 못했어요. 연결 상태를 확인한 뒤 다시 시도해 주세요."
        store.workReports = [report]
        let h = HomeHarness(width: 1100, height: 850, store: store)
        defer { h.close() }
        await h.waitWeb(); h.settle()
        try waitWeb(h, "document.querySelector('.report-card .report-error') !== null")
        #expect(try web(h, "document.querySelectorAll('.report-card').length === 1"))
        _ = try web(h, "(()=>{const b=[...document.querySelectorAll('.report-card button')].find(e=>e.textContent==='다시 시도');if(!b)return false;b.click();return true;})()")
        // The card asks the store to retry the same report; that store flips it back to ready.
        for _ in 0..<100 where store.retriedReports.isEmpty { h.settle(0.05) }
        #expect(store.retriedReports == [report.id])
        try waitWeb(h, "document.querySelector('.report-card .report-error') === null && document.querySelectorAll('.report-card').length === 1")
        #expect(try web(h, "document.querySelector('.report-card button').textContent === '보고서 열기'"))
    }

    @Test func historyPageStillListsEverySavedReport() async throws {
        let store = SampleKnarrStore()
        let now = Date()
        let issue = try #require(store.issues.first)
        var weekly = readyReport(issue: issue, now: now)
        weekly.period = WorkReportPeriod(kind: .weekly, start: now.addingTimeInterval(-6 * 86400), end: now, timeZoneID: "Asia/Seoul")
        store.workReports = [readyReport(issue: issue, now: now), weekly]
        let h = HomeHarness(width: 1100, height: 850, page: .history, store: store)
        defer { h.close() }
        h.settle()
        let host = try #require(h.window.contentView)
        #expect(find(host, "work-report-row-" + weekly.id) != nil)
        #expect(find(host, "work-report-row-daily:" + String(Int(now.timeIntervalSince1970)) + ":Asia/Seoul") != nil || find(host, "work-report-row-" + store.workReports[0].id) != nil)
    }
}
