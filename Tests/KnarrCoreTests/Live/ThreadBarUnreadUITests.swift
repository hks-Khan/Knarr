import AppKit
import SwiftUI
import Testing
@testable import KnarrCore
@testable import KnarrUI

/// The tab bar shows how many answers each tab has not shown yet: never for zero, capped at 99+
/// on screen, exact in the accessibility label, and without moving the tab or its neighbours.
@MainActor @Suite(.serialized, .enabled(if: KnarrUITests.enabled)) struct ThreadBarUnreadUITests {
    private func value(_ node: NSObject, _ selector: String) -> Any? {
        let action = NSSelectorFromString(selector)
        if node.responds(to: action), let result = node.perform(action)?.takeUnretainedValue() { return result }
        let attribute = ["accessibilityChildren": "AXChildren", "accessibilityLabel": "AXDescription",
                         "accessibilityIdentifier": "AXIdentifier", "accessibilityValue": "AXValue"][selector]
        return attribute.flatMap { node.accessibilityAttributeValue(NSAccessibility.Attribute(rawValue: $0)) }
    }
    private func elements(_ node: NSObject) -> [NSObject] {
        [node] + ((value(node, "accessibilityChildren") as? [NSObject]) ?? []).flatMap(elements)
    }
    private func node(_ root: NSObject, id: String) throws -> NSObject {
        try #require(elements(root).first { value($0, "accessibilityIdentifier") as? String == id }, "Missing tab: \(id)")
    }
    private func label(_ root: NSObject, id: String) throws -> String {
        try #require(value(try node(root, id: id), "accessibilityLabel") as? String)
    }
    /// The badge slot keeps one width whether the count is zero or drawn, so the tab never
    /// reflows when a number appears or is read.
    private func slotWidth(_ count: Int) -> CGFloat {
        let host = NSHostingView(rootView: UnreadBadge(count: count))
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.width
    }
    private func frame(_ root: NSObject, id: String) throws -> NSRect {
        try #require(try node(root, id: id).value(forKey: "accessibilityFrame") as? NSValue).rectValue
    }
    private func settle(_ deadline: TimeInterval = 2, _ done: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(deadline)
        while !done(), Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        return done()
    }
    private func stableFrame(_ root: NSObject, id: String) throws -> NSRect {
        var previous = try frame(root, id: id)
        for _ in 0..<20 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            let next = try frame(root, id: id)
            if next == previous { return next }
            previous = next
        }
        throw CancellationError()
    }
    private func host<V: View>(_ view: V, size: NSSize) -> (NSWindow, NSHostingView<AnyView>) {
        let host = NSHostingView(rootView: AnyView(view.environment(\.colorScheme, .light)))
        let window = TestWindow.make(size: size, styleMask: [.borderless])
        window.contentView = host
        TestWindow.present(window)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        return (window, host)
    }

    /// Two project tabs plus the main one: counts appear beside the titles, and zero stays quiet.
    @Test func projectTabsShowTheirOwnCountsNextToTheTitle() throws {
        let store = SampleKnarrStore(threadBadgeScene: .unread)
        let tabs = store.conversationTabs
        #expect(tabs.count == 3)
        let (window, host) = host(ThreadBar(store: store).frame(width: 1_000, height: 60),
                                  size: NSSize(width: 1_000, height: 60))
        defer { window.contentView = nil; window.close() }
        let main = "thread-" + ConversationThread.defaultID
        let firstProject = try #require(tabs.first { $0.projectID == "gamza" })
        let secondProject = try #require(tabs.first { $0.projectID == "knarr" })
        #expect(try label(host, id: main).contains("읽지 않은 답변 1개"))
        #expect(try label(host, id: "thread-" + firstProject.id).contains("읽지 않은 답변 1개"))
        #expect(try label(host, id: "thread-" + secondProject.id).contains("읽지 않은 답변 2개"))

        // Zero draws nothing; the slot still holds its width so the title does not move.
        #expect(slotWidth(0) == K.tabBadgeWidth)
        #expect(slotWidth(0) == slotWidth(1))
        #expect(slotWidth(1) == slotWidth(100))
        #expect(store.unreadAnswerCount(forThread: secondProject.id) == 2)
    }

    /// Reading one project's answers clears only that tab's badge and never shifts the tab bar.
    @Test func readingClearsCountWithoutMovingTabs() throws {
        let store = SampleKnarrStore(threadBadgeScene: .unread)
        let tabs = store.conversationTabs
        let firstProject = try #require(tabs.first { $0.projectID == "gamza" })
        let main = "thread-" + ConversationThread.defaultID
        let target = "thread-" + firstProject.id
        let (window, host) = host(ThreadBar(store: store).frame(width: 1_000, height: 60),
                                  size: NSSize(width: 1_000, height: 60))
        defer { window.contentView = nil; window.close() }
        let mainBefore = try stableFrame(host, id: main)

        // Reading requires the tab to be selected, and selection itself changes the title weight.
        // Measure the selected tab with its badge, then again after the count clears: only the
        // badge's removal can change the result.
        store.selectThread(firstProject.id)
        let selectedWithBadge = try stableFrame(host, id: target)
        let answers = store.chat.compactMap(UnreadAnswers.answer).map(\.id)
        store.markAnswersRead(answers, threadID: firstProject.id)
        #expect(settle { !(try? self.label(host, id: target))!.contains("읽지 않은 답변") })
        #expect(try stableFrame(host, id: target) == selectedWithBadge, "Clearing a count moved or resized the tab")
        #expect(try stableFrame(host, id: main) == mainBefore, "Clearing a count moved another tab")
        #expect(try label(host, id: main).contains("읽지 않은 답변 1개"), "Another tab's count changed")
    }

    /// The badge sits beside the working mark; a tab can be both working and hold new answers.
    @Test func workingTabKeepsItsCountAndAnimation() throws {
        let store = SampleKnarrStore(threadBadgeScene: .unread)
        store.isResponding = true
        let (window, host) = host(ThreadBar(store: store).frame(width: 1_000, height: 60),
                                  size: NSSize(width: 1_000, height: 60))
        defer { window.contentView = nil; window.close() }
        // The sample response belongs to the selected thread, so that tab carries both states.
        let working = "thread-" + store.selectedThreadID
        #expect(try label(host, id: working).contains("작업 중"))
        #expect(try label(host, id: working).contains("읽지 않은 답변"))
        var pulsing = [CALayer]()
        func walk(_ layer: CALayer?) {
            guard let layer else { return }
            if layer.animationKeys()?.contains("ring") == true { pulsing.append(layer) }
            for sub in layer.sublayers ?? [] { walk(sub) }
        }
        walk(host.layer)
        #expect(!pulsing.isEmpty, "The working mark disappeared when a count was shown")
    }

    /// A long project name truncates inside its title column; the count stays visible.
    @Test func longTabNameKeepsTheCountVisibleAndInsideTheTab() throws {
        let store = SampleKnarrStore(threadBadgeScene: .unread)
        let tabs = store.conversationTabs
        let project = try #require(tabs.first { $0.projectID != nil })
        store.renameThread(project.id, to: String(repeating: "아주 긴 프로젝트 이름 ", count: 6))
        let (window, host) = host(ThreadBar(store: store).frame(width: 1_000, height: 60),
                                  size: NSSize(width: 1_000, height: 60))
        defer { window.contentView = nil; window.close() }
        let id = "thread-" + project.id
        #expect(try label(host, id: id).contains("읽지 않은 답변"))
        let tab = try frame(host, id: id)
        #expect(tab.width <= K.tabTitleWidth + K.tabBadgeWidth + K.s4 * 4 + 1, "The tab grew past its truncated title and badge")
    }
}
