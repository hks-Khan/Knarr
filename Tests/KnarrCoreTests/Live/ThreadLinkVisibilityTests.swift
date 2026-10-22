import AppKit
import Testing
import KnarrCore
@testable import KnarrUI

private typealias Issue = KnarrCore.Issue

/// "스레드로 이동" only helps when it leads somewhere: another thread exists and the issue lives in it.
@MainActor @Suite(.serialized, .enabled(if: KnarrUITests.enabled)) struct ThreadLinkVisibilityTests {
    private func value(_ node: NSObject, _ selector: String) -> Any? {
        let action = NSSelectorFromString(selector)
        guard node.responds(to: action) else { return nil }
        return node.perform(action)?.takeUnretainedValue()
    }
    private func elements(_ node: NSObject) -> [NSObject] {
        [node] + ((value(node, "accessibilityChildren") as? [NSObject]) ?? []).flatMap(elements)
    }

    /// The drawer's thread link, if the open drawer shows one.
    private func threadLinkLabel(_ store: SampleKnarrStore, opened: Issue.ID) throws -> String? {
        let h = HomeHarness(width: 1300, height: 900, opened: opened, store: store)
        defer { h.close() }
        TestWindow.present(h.window); h.settle()
        let host = try #require(h.window.contentView)
        let drawer = elements(host).first { value($0, "accessibilityIdentifier") as? String == "issue-drawer" }
        #expect(drawer != nil, "the drawer for \(opened.rawValue) did not open")
        let link = elements(host).first { value($0, "accessibilityIdentifier") as? String == "issue-thread-link" }
        return link.map { (value($0, "accessibilityLabel") as? String) ?? "" }
    }

    @Test func aSingleThreadHasNowhereToGo() throws {
        let store = SampleKnarrStore()
        #expect(store.threads.count == 1)
        #expect(try threadLinkLabel(store, opened: "npc-repeat") == nil)
    }

    @Test func anIssueInTheCurrentThreadHidesTheLink() throws {
        let store = SampleKnarrStore()
        store.createThread(name: "빌드 검사")
        store.selectThread(ConversationThread.defaultID)
        #expect(store.threads.count == 2)
        // npc-repeat belongs to 기본, which is the selected thread.
        #expect(try threadLinkLabel(store, opened: "npc-repeat") == nil)
    }

    @Test func anIssueInAnotherThreadOffersTheLinkWithThatThreadsName() throws {
        let store = SampleKnarrStore()
        store.createThread(name: "빌드 검사")
        #expect(store.selectedThreadID != ConversationThread.defaultID)
        let label = try #require(try threadLinkLabel(store, opened: "npc-repeat"))
        #expect(label.contains("기본"))
    }
}
