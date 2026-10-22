import AppKit
import Foundation
import SwiftUI
import Testing
import KnarrCore
@testable import KnarrUI

/// A focused conversation expands inside the transcript and must get real height back from the
/// native chrome around it. These tests open the panel in a real hosted window and measure the
/// browser's own layout, so a CSS number alone cannot satisfy them.
@MainActor @Suite(.serialized, .enabled(if: KnarrUITests.enabled)) struct FocusedConversationLayoutTests {
    init() { TestWindow.prepare() }

    private func expanded(_ h: HomeHarness) async throws {
        await h.waitWeb()
        _ = await h.webJSON("(()=>{const b=document.querySelector('.conversation-card-open');if(!b)return false;b.click();return true;})()")
        for _ in 0..<100 {
            if await h.webJSON("document.querySelector('.conversation-canvas') !== null") as? Bool == true {
                try await Task.sleep(for: .milliseconds(500))
                h.settle(0.2)
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        Issue.record("The focused conversation panel never expanded")
        throw CocoaError(.coderReadCorrupt)
    }

    private func number(_ h: HomeHarness, _ script: String) async -> CGFloat? {
        (await h.webJSON(script) as? NSNumber).map { CGFloat(truncating: $0) }
    }

    private func bodyHeight(_ h: HomeHarness) async -> CGFloat? {
        await number(h, "(()=>{const b=document.querySelector('.conversation-body');return b ? b.clientHeight : 0;})()")
    }

    private func attribute(_ node: NSObject, _ name: String) -> Any? {
        let action = NSSelectorFromString(name)
        if node.responds(to: action), let result = node.perform(action)?.takeUnretainedValue() { return result }
        let key = ["accessibilityChildren": "AXChildren", "accessibilityIdentifier": "AXIdentifier",
                   "accessibilityLabel": "AXDescription"][name]
        return key.flatMap { node.accessibilityAttributeValue(NSAccessibility.Attribute(rawValue: $0)) }
    }

    private func elements(_ node: NSObject) -> [NSObject] {
        [node] + ((attribute(node, "accessibilityChildren") as? [NSObject]) ?? []).flatMap(elements)
    }

    private func control(_ h: HomeHarness, id: String) throws -> NSObject? {
        elements(try #require(h.window.contentView))
            .first { attribute($0, "accessibilityIdentifier") as? String == id }
    }

    private func press(_ node: NSObject) -> Bool {
        let action = NSSelectorFromString("accessibilityPerformPress")
        guard node.responds(to: action) else { return false }
        typealias Press = @convention(c) (AnyObject, Selector) -> Bool
        return unsafeBitCast(node.method(for: action), to: Press.self)(node, action)
    }

    /// SwiftUI buttons do not become AppKit views, so their labels are read from the AX tree.
    private func labels(_ h: HomeHarness) -> [String] {
        guard let host = h.window.contentView else { return [] }
        return elements(host).compactMap { attribute($0, "accessibilityLabel") as? String }
    }

    @Test func tallWindowShowsTheWholeExchangeWithoutACutoffBody() async throws {
        let h = HomeHarness(width: 1440, height: 1180, store: SampleKnarrStore(designScene: .conversationCanvas))
        defer { h.close() }
        try await expanded(h)
        let body = try #require(await bodyHeight(h))
        #expect(body >= 200, "The panel body was only \(body)px tall")
        #expect(await number(h, "document.querySelectorAll('.conversation-body .message').length") == 3)
        let overflow = await number(h, "(()=>{const b=document.querySelector('.conversation-body');return b.scrollHeight-b.clientHeight;})()")
        #expect(overflow == 0, "The whole exchange should fit at this height")
    }

    @Test func shortWindowStillShowsTheOriginalAndPartOfAReply() async throws {
        let h = HomeHarness(width: 780, height: 620, store: SampleKnarrStore(designScene: .conversationCanvas))
        defer { h.close() }
        try await expanded(h)
        let body = try #require(await bodyHeight(h))
        // The original plus the first reply header and a couple of wrapped lines need ~100px.
        #expect(body >= 100, "The panel body collapsed to \(body)px")
        let view = await number(h, "document.querySelector('.viewport').clientHeight")
        #expect((view ?? 0) >= 40, "The main transcript kept only \(view ?? 0)px")
    }

    @Test func composerToolsFoldAndKeepTheEditorAndDraft() async throws {
        let h = HomeHarness(width: 900, height: 700, store: SampleKnarrStore(designScene: .conversationCanvas))
        defer { h.close() }
        h.store.composerDraft.text = "메인 대화 초안"
        h.settle(0.2)
        let editor = try #require(h.composer)
        #expect(editor.string == "메인 대화 초안")
        try await expanded(h)
        // The editor and the draft stay; the project, attach and model controls yield to the panel.
        #expect(h.composer === editor, "The editor was recreated instead of keeping focus and draft")
        #expect(editor.string == "메인 대화 초안")
        #expect(try control(h, id: "composer-tools") != nil, "The folded tools disclosure is missing")
        #expect(!labels(h).contains("파일 첨부"), "The attach button still competes with the panel")
    }

    @Test func reopeningTheToolsRestoresTheProjectAndAttachControls() async throws {
        let h = HomeHarness(width: 900, height: 700, store: SampleKnarrStore(designScene: .conversationCanvas))
        defer { h.close() }
        h.store.composerDraft.text = "도구를 다시 펼칠 초안"
        h.settle(0.2)
        try await expanded(h)
        let tools = try #require(try control(h, id: "composer-tools"))
        #expect(press(tools))
        h.settle(0.4)
        #expect(labels(h).contains("파일 첨부"), "The attach control did not return")
        let editor = try #require(h.composer)
        #expect(editor.string == "도구를 다시 펼칠 초안")
    }

    @Test func closingThePanelRestoresTheToolsAndKeepsTheDraft() async throws {
        let h = HomeHarness(width: 900, height: 700, store: SampleKnarrStore(designScene: .conversationCanvas))
        defer { h.close() }
        h.store.composerDraft.text = "닫은 뒤에도 남는 초안"
        h.settle(0.2)
        try await expanded(h)
        _ = await h.webJSON("(()=>{const b=document.querySelector('.conversation-close');if(!b)return false;b.click();return true;})()")
        for _ in 0..<100 {
            if await h.webJSON("document.querySelector('.conversation-canvas') === null") as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        h.settle(0.4)
        let editor = try #require(h.composer)
        #expect(editor.string == "닫은 뒤에도 남는 초안")
        #expect(labels(h).contains("파일 첨부"), "Closing should restore the composer tools")
    }
}
