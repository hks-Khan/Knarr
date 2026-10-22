import AppKit
import SwiftUI
import Testing
import KnarrCore
@testable import KnarrUI

@MainActor @Suite(.serialized, .enabled(if: KnarrUITests.enabled)) struct IssueCardsLayoutTests {
    init() { _ = NSApplication.shared }

    private func value(_ node: NSObject, _ selector: String) -> Any? {
        let action = NSSelectorFromString(selector)
        if node.responds(to: action), let result = node.perform(action)?.takeUnretainedValue() { return result }
        let attribute = ["accessibilityChildren": "AXChildren", "accessibilityIdentifier": "AXIdentifier"][selector]
        return attribute.flatMap { node.accessibilityAttributeValue(NSAccessibility.Attribute(rawValue: $0)) }
    }
    private func elements(_ node: NSObject) -> [NSObject] {
        [node] + ((value(node, "accessibilityChildren") as? [NSObject]) ?? []).flatMap(elements)
    }
    private func cardScroll(_ h: HomeHarness) throws -> NSScrollView {
        let transcript = h.frameInWindow(try #require(h.conversation))
        return try #require(h.sideScrolls.first {
            let frame = h.frameInWindow($0)
            return $0.hasVerticalScroller && abs(frame.width - transcript.width) < 2 && frame.maxY > transcript.maxY
        })
    }

    @Test func singleRunningHirdFitsTwoLinesWithoutRepeatedStatusOrWorkerRow() throws {
        let h = HomeHarness(width: 1100, height: 800, store: SampleKnarrStore(issueSessionScene: .singleHird))
        defer { h.close() }
        TestWindow.present(h.window); h.settle()
        let host = try #require(h.window.contentView)
        let card = try #require(elements(host).first {
            (value($0, "accessibilityIdentifier") as? String)?.hasPrefix("integrated-issue-") == true
        })
        let frame = try #require(card.value(forKey: "accessibilityFrame") as? NSValue).rectValue
        #expect(frame.height <= K.controlHeight * 2 + K.s2 * 2)
        let labels = elements(card).flatMap { node -> [String] in
            ["accessibilityLabel", "accessibilityValue"].compactMap { key in
                let selector = NSSelectorFromString(key)
                return node.responds(to: selector) ? node.perform(selector)?.takeUnretainedValue() as? String : nil
            }
        }
        #expect(!labels.contains("Hird 실행"))
        #expect(!labels.contains("Hird 1"))
        #expect(labels.contains("명령 실행 · swift test --filter DialogueTests"))
    }
    @Test(arguments: [IssueSessionScene.completed, .conversation])
    func singleCardUsesItsContentHeightAndReturnsRemainingSpaceToTranscript(scene: IssueSessionScene) throws {
        let store = SampleKnarrStore(issueSessionScene: scene)
        let h = HomeHarness(width: 1440, height: 900, store: store)
        defer { h.close() }
        TestWindow.present(h.window); h.settle()
        let issue = try #require(store.issues.first)
        let host = try #require(h.window.contentView)
        let node = try #require(elements(host).first {
            value($0, "accessibilityIdentifier") as? String == "integrated-issue-" + issue.id.rawValue
        })
        try #require(node.responds(to: NSSelectorFromString("accessibilityFrame")))
        let card = try #require(node.value(forKey: "accessibilityFrame") as? NSValue).rectValue
        let scroll = try cardScroll(h)
        #expect(abs(scroll.frame.height - card.height - K.s3) < 2)
        #expect(scroll.frame.height < 900 / 2)
        let transcript = h.frameInWindow(try #require(h.conversation))
        #expect(abs(h.frameInWindow(scroll).minY - transcript.maxY) < 2)
    }

    @Test func multipleCardsStopAtHalfHeightAndScrollWithinTheirOwnArea() throws {
        let h = HomeHarness(width: 1440, height: 900, store: SampleKnarrStore(issueSessionScene: .main))
        defer { h.close() }
        let scroll = try cardScroll(h)
        // The disclosure row moved into the conversation header, so the list itself gets the half-height budget.
        #expect(scroll.frame.height <= h.window.contentLayoutRect.height / 2)
        let document = try #require(scroll.documentView)
        let before = scroll.documentVisibleRect
        #expect(document.bounds.height > before.height)
        let targetY = before.minY < document.bounds.midY ? document.bounds.maxY - before.height : document.bounds.minY
        scroll.contentView.scroll(to: NSPoint(x: before.minX, y: targetY))
        scroll.reflectScrolledClipView(scroll.contentView)
        #expect(abs(scroll.documentVisibleRect.minY - before.minY) > 2)
    }
    @Test func cardsLeaveTranscriptAndComposerVisibleAtMinimumHeight() throws {
        let h = HomeHarness(width: 720, height: 540)
        defer { h.close() }
        let transcript = h.frameInWindow(try #require(h.conversation))
        let composer = h.frameInWindow(try #require(h.composer?.enclosingScrollView))
        #expect(transcript.height > 0)
        #expect(composer.minX >= transcript.minX && composer.maxX <= transcript.maxX)
        let topLists = h.sideScrolls.filter {
            let frame = h.frameInWindow($0)
            return frame.width > 500 && frame.maxY > transcript.maxY
        }
        for list in topLists { #expect(h.frameInWindow(list).height <= 540 / 2) }
        #expect(h.panel == nil)
    }

    @Test func collapsedCardsStayCollapsedAcrossWindowResize() throws {
        let h = HomeHarness(width: 1200, height: 700) { $0.set(true, forKey: "knarr.issueCardsCollapsed") }
        defer { h.close() }
        let before = h.frameInWindow(try #require(h.conversation)).height
        h.resize(width: 720, height: 700)
        #expect(h.defaults.bool(forKey: "knarr.issueCardsCollapsed"))
        #expect(abs(h.frameInWindow(try #require(h.conversation)).height - before) < 80)
        #expect(h.panel == nil)
    }
}
