import AppKit
import SwiftUI
import Testing
import KnarrCore
@testable import KnarrUI

/// The card/drawer activity line is only visible in a hosted window, so these checks are opt-in.
@MainActor @Suite(.serialized, .enabled(if: KnarrUITests.enabled)) struct HirdActivityRenderTests {
    /// Captures are written only when a review run asks for them, so ordinary UI runs leave the tree clean.
    private var evidence: URL? {
        ProcessInfo.processInfo.environment["KNARR_REVIEW_SCREENSHOTS"].map {
            URL(fileURLWithPath: $0)
        }
    }

    private func value(_ node: NSObject, _ selector: String) -> Any? {
        let action = NSSelectorFromString(selector)
        if node.responds(to: action), let result = node.perform(action)?.takeUnretainedValue() { return result }
        return nil
    }
    private func labels(_ node: NSObject) -> [String] {
        let own = ["accessibilityLabel", "accessibilityValue"].compactMap { value(node, $0) as? String }
        let children = (value(node, "accessibilityChildren") as? [NSObject]) ?? []
        return own + children.flatMap(labels)
    }
    private func nodes(_ node: NSObject) -> [NSObject] {
        [node] + ((value(node, "accessibilityChildren") as? [NSObject]) ?? []).flatMap(nodes)
    }
    private func press(_ node: NSObject) -> Bool {
        let action = NSSelectorFromString("accessibilityPerformPress")
        guard node.responds(to: action) else { return false }
        typealias Getter = @convention(c) (AnyObject, Selector) -> Bool
        return unsafeBitCast(node.method(for: action), to: Getter.self)(node, action)
    }
    private func capture(_ host: NSView, _ name: String) throws {
        guard let root = evidence else { return }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        try rep.representation(using: .png, properties: [:])?
            .write(to: root.appendingPathComponent(name + ".png"))
    }
    private func settle(_ host: NSView) {
        host.layoutSubtreeIfNeeded()
        for _ in 0..<6 { RunLoop.main.run(until: Date().addingTimeInterval(0.2)); host.layoutSubtreeIfNeeded() }
    }

    @Test func drawerShowsCurrentAndRecentActivityInsteadOfInstruction() throws {
        let store = SampleKnarrStore(designScene: .issues)
        var issue = try #require(store.issue(SampleKnarrStore.designDrawerIssue))
        // The approval path stores the whole instruction in `role`; the drawer must not print it.
        let instruction = "지시 전문 첫 줄입니다.\n둘째 줄은 Hird 행에 나오면 안 됩니다."
        issue.hirds[0].role = instruction
        issue.proposal?.instruction = "저장된 제안 본문"
        let host = NSHostingView(rootView: IssueDrawer(issue: issue, store: store, close: {}).frame(width: 560, height: 1200))
        let window = TestWindow.make(size: NSSize(width: 560, height: 1200))
        window.contentView = host
        TestWindow.present(window)
        settle(host)
        let before = labels(host)
        #expect(before.contains { $0.contains("생각 중") })
        // The recent states sit in the folded Hird row; expand it so the capture shows them.
        let records = try #require(nodes(host).first { value($0, "accessibilityIdentifier") as? String == "issue-detail-records" })
        #expect(press(records))
        settle(host)
        let all = labels(host)
        try capture(host, "drawer-activity-light")
        #expect(all.contains { $0.contains("읽는 중 · RepeatTests.swift") })
        #expect(all.contains { $0.contains("편집 중 · LinePicker.swift") })
        #expect(all.contains { $0.contains("명령 실행 · git diff -- Sources/Dialogue") })
        // The saved proposal instruction still belongs to its own section; the Hird row is activity only.
        #expect(!all.contains { $0.contains("둘째 줄은 Hird 행에 나오면 안 됩니다") })
        window.contentView = nil
        window.close()
    }

    @Test func cardsShowActivityLineInsteadOfRawCommand() throws {
        let store = SampleKnarrStore(issueSessionScene: .multipleHirds)
        let host = NSHostingView(rootView: IssueCardsView(store: store, maximumHeight: 900, open: { _ in },
                                                          collapsed: .constant(false)).frame(width: 740, height: 900))
        let window = TestWindow.make(size: NSSize(width: 740, height: 900))
        window.contentView = host
        TestWindow.present(window)
        settle(host)
        let all = labels(host)
        try capture(host, "cards-activity-light")
        #expect(all.contains { $0.contains("명령 실행 · swift test --filter DialogueTests") })
        #expect(all.contains { $0.contains("명령 실행 · swift test --filter SaveCompatibilityTests") })
        window.contentView = nil
        window.close()
    }
}
