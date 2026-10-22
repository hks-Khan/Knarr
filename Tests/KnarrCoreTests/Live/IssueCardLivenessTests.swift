import AppKit
import SwiftUI
import Testing
import KnarrCore
@testable import KnarrUI

private typealias Issue = KnarrCore.Issue

/// A card in the panel or the chat has to say whether its Hird is alive: "활동 4초 전", "12분째 조용함".
/// The silence is what a person scanning the panel is looking for.
@MainActor @Suite(.serialized, .enabled(if: KnarrUITests.enabled)) struct IssueCardLivenessTests {
    private func running(lastActivity secondsAgo: TimeInterval, now: Date = .now) -> Issue {
        Issue(id: "card", title: "카드 검사", projectName: "Knarr", state: .running, headline: "Hird 1명",
              detail: "", acceptance: [Criterion(text: "조건", state: .pending, evidence: "")],
              hirds: [HirdRun(id: "h", name: "Hird-1", role: "검사", status: .working,
                              steps: [.init(title: "확인", state: .active)], currentCommand: nil,
                              lastActivityAt: now.addingTimeInterval(-secondsAgo))],
              events: [], startedAt: now.addingTimeInterval(-3600))
    }

    /// Every text the hosted view puts on screen, AppKit-backed labels included.
    private func texts<V: View>(_ view: V) -> [String] {
        let host = NSHostingView(rootView: view.frame(width: 360))
        let window = TestWindow.make(size: NSSize(width: 360, height: 400), styleMask: [.borderless])
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        func walk(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(walk) }
        return walk(host).compactMap { ($0 as? NSTextField)?.stringValue }.filter { !$0.isEmpty }
    }

    @Test func panelCardShowsAnActiveHird() {
        let shown = texts(PanelCard(issue: running(lastActivity: 4), selected: false) {})
        #expect(shown.contains { $0.hasPrefix("활동 ") && $0.hasSuffix("초 전") }, "texts: \(shown)")
    }

    @Test func panelCardShowsHowLongAHirdHasBeenQuiet() {
        let shown = texts(PanelCard(issue: running(lastActivity: 12 * 60 + 5), selected: false) {})
        #expect(shown.contains("12분째 조용함"), "texts: \(shown)")
    }

    @Test(arguments: [4.0, 725.0]) func chatIssueCardShowsLiveActivity(seconds: Double) async throws {
        let store = ChangingCardsStore(); let issue = running(lastActivity: seconds)
        store.issues = [issue]; store.chat = [.init(at: .now, kind: .issue(issue.id))]
        let h = HomeHarness(width: 1000, height: 740, store: store); defer { h.close() }
        await h.waitWeb()
        let text = try #require(await h.webJSON("document.querySelector('.live-label')?.textContent") as? String)
        if seconds < 90 { #expect(text.contains("활동 ") && text.hasSuffix("초 전")) }
        else { #expect(text.contains("12분째 조용함")) }
    }

    @Test func anIssueWithoutAHirdShowsNoLivenessAtAll() {
        var waiting = running(lastActivity: 4)
        waiting.state = .awaitingApproval
        waiting.hirds = []
        let shown = texts(PanelCard(issue: waiting, selected: false) {})
        #expect(!shown.contains { $0.hasPrefix("활동") || $0.hasSuffix("조용함") }, "texts: \(shown)")
    }
}
