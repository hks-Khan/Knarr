import AppKit
import Foundation
import SwiftUI
import Testing
import KnarrCore
@testable import KnarrUI

/// While Hird runs, the screen still has to receive clicks in one try: the detail must open and
/// close, the close menu must say why a row is blocked, and the composer must not steal the caret
/// back after the person clicked something else.
@MainActor @Suite(.serialized, .enabled(if: KnarrUITests.enabled)) struct FocusAndCloseResponsivenessTests {
    init() { _ = NSApplication.shared }

    private func value(_ node: NSObject, _ selector: String) -> Any? {
        let action = NSSelectorFromString(selector)
        if node.responds(to: action), let result = node.perform(action)?.takeUnretainedValue() { return result }
        let attribute = ["accessibilityChildren": "AXChildren", "accessibilityLabel": "AXDescription",
                         "accessibilityIdentifier": "AXIdentifier", "accessibilityRole": "AXRole",
                         "accessibilityValue": "AXValue"][selector]
        guard let attribute else { return nil }
        return node.accessibilityAttributeValue(NSAccessibility.Attribute(rawValue: attribute))
    }
    private func elements(_ node: NSObject) -> [NSObject] {
        [node] + ((value(node, "accessibilityChildren") as? [NSObject]) ?? []).flatMap(elements)
    }
    private func press(_ node: NSObject) -> Bool {
        let action = NSSelectorFromString("accessibilityPerformPress")
        guard node.responds(to: action) else { return false }
        typealias Press = @convention(c) (AnyObject, Selector) -> Bool
        return unsafeBitCast(node.method(for: action), to: Press.self)(node, action)
    }
    private func control(_ h: HomeHarness, id: String) throws -> NSObject {
        let host = try #require(h.window.contentView)
        return try #require(elements(host).first { value($0, "accessibilityIdentifier") as? String == id }, "Missing control: \(id)")
    }
    /// A real AppKit field that takes the caret, standing in for any other control a person clicks.
    private func field(in h: HomeHarness) -> NSTextField {
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 120, height: 22))
        h.window.contentView?.addSubview(field)
        return field
    }
    private func click(_ h: HomeHarness, _ node: NSObject) throws {
        let screen = try #require(node.value(forKey: "accessibilityFrame") as? NSValue).rectValue
        let point = h.window.convertPoint(fromScreen: NSPoint(x: screen.midX, y: screen.midY))
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: h.window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
            h.window.sendEvent(event)
        }
        h.settle(0.1)
    }

    @Test func composerTextViewKeepsAClickedControlAsFirstResponder() throws {
        // Isolated from SwiftUI: the text view is asked for focus while another control owns the caret.
        let window = TestWindow.make(size: NSSize(width: 600, height: 400), styleMask: [.borderless])
        defer { window.close() }
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 60))
        let composer = ComposerTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 60))
        composer.isEditable = true
        scroll.documentView = composer
        container.addSubview(scroll)
        let other = NSTextField(frame: NSRect(x: 0, y: 200, width: 120, height: 22))
        container.addSubview(other)
        window.contentView = container
        TestWindow.present(window)
        #expect(window.makeFirstResponder(other))
        let fieldEditor = try #require(other.currentEditor())
        composer.requestFocus(UUID())
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        #expect(window.firstResponder === fieldEditor, "the composer pulled the caret out of the clicked field")
        // The request stays spent: a later layout pass does not revive it.
        composer.frame = NSRect(x: 0, y: 0, width: 320, height: 60)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        #expect(window.firstResponder === fieldEditor)
    }

    @Test func composerDoesNotTakeTheCaretBackAfterAUserClicksElsewhere() async throws {
        let store = SampleKnarrStore()
        let h = HomeHarness(width: 1300, height: 900, store: store)
        defer { h.close() }
        let editor = try #require(h.composer)
        let other = field(in: h)
        #expect(h.window.makeFirstResponder(other))
        // A focused NSTextField uses its field editor as first responder.
        let otherEditor = try #require(other.currentEditor())
        #expect(h.window.firstResponder === otherEditor)
        // A focus request issued while another control owns the caret is spent, not queued.
        editor.requestFocus(UUID())
        h.settle(0.1)
        #expect(h.window.firstResponder === otherEditor, "a new focus request pulled the caret out of the clicked field")
        // A layout pass from a store change must not move it either.
        store.reloadInstructionSources()
        h.settle(0.2)
        #expect(h.window.firstResponder === otherEditor)
        // When the composer itself has the caret, its own request still applies.
        #expect(h.window.makeFirstResponder(editor))
        editor.requestFocus(UUID())
        h.settle(0.1)
        #expect(h.window.firstResponder === editor)
    }

    @Test func cardDetailOpensAndClosesInOneActionWhileHirdRuns() throws {
        let store = SampleKnarrStore(issueSessionScene: .singleHird)
        let issue = try #require(store.issues.first { $0.hasActiveHird })
        let h = HomeHarness(width: 1300, height: 900, store: store)
        defer { h.close() }
        TestWindow.present(h.window); h.settle()
        let card = try control(h, id: "integrated-issue-" + issue.id.rawValue)
        try click(h, card)
        let host = try #require(h.window.contentView)
        let drawer = try #require(elements(host)
            .first { value($0, "accessibilityIdentifier") as? String == "issue-drawer" }, "the card click did not open the detail")
        let close = try #require(elements(drawer).first { value($0, "accessibilityIdentifier") as? String == "issue-drawer-close" })
        #expect(press(close))
        h.settle()
        #expect(!elements(host).contains { value($0, "accessibilityIdentifier") as? String == "issue-drawer" })
    }

    @Test func refusedCloseShowsTheReasonInsteadOfSilence() async throws {
        let f = try await LiveFixture.make()
        do {
            try await f.create(); try await f.dispatch()
            #expect(f.store.lastError == nil)
            f.store.perform(.closeIssue(reason: .cancelled), on: "t")
            try await f.store.whenIdle()
            let message = try #require(f.store.lastError)
            #expect(message.contains("진행 중인 Hird 실행이 있어"))
            #expect(f.store.issue("t")?.archivedAt == nil)
            // The reason reaches the transcript too, so nothing is silently ignored.
            #expect(f.store.chat.contains { if case .stallari(let text, _) = $0.kind { text == message } else { false } })
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }

    @Test func closeMenuNamesTheRunningHirdInsteadOfBeingDead() throws {
        let store = SampleKnarrStore(issueSessionScene: .singleHird)
        let issue = try #require(store.issues.first { $0.hasActiveHird })
        let items = IssueDrawer.closeItems(issue: issue, store: store)
        #expect(items.map(\.title) == IssueCloseReason.allCases.map(\.title))
        #expect(items.allSatisfy { !$0.enabled })
        #expect(items.allSatisfy { $0.menuTitle.contains("실행 중에는 닫을 수 없어요") })
    }

    @Test func closeFailureShowsItsReasonThroughTheStoreError() throws {
        // The drawer's close rows go through store.perform; a refusal must surface its own text.
        let store = SampleKnarrStore(issueSessionScene: .singleHird)
        let issue = try #require(store.issues.first { $0.hasActiveHird })
        let item = try #require(IssueDrawer.closeItems(issue: issue, store: store).first)
        #expect(!item.enabled)
        item.perform()
        #expect(store.issue(issue.id)?.archivedAt == nil)
    }
}
