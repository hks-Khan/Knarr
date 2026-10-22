import AppKit
import Testing
import KnarrCore
@testable import KnarrUI

@MainActor @Suite(.serialized, .enabled(if: KnarrUITests.enabled)) struct ProjectTransferUITests {
    init() { _ = NSApplication.shared }

    private func value(_ node: NSObject, _ selector: String) -> Any? {
        let action = NSSelectorFromString(selector)
        if node.responds(to: action), let result = node.perform(action)?.takeUnretainedValue() { return result }
        let attribute = ["accessibilityChildren": "AXChildren", "accessibilityIdentifier": "AXIdentifier"][selector]
        return attribute.flatMap { node.accessibilityAttributeValue(NSAccessibility.Attribute(rawValue: $0)) }
    }

    private func identifiers(_ node: NSObject) -> [String] {
        let own = (value(node, "accessibilityIdentifier") as? String).map { [$0] } ?? []
        return own + ((value(node, "accessibilityChildren") as? [NSObject]) ?? []).flatMap(identifiers)
    }

    @Test func projectTransferMenuFollowsSourceAndMainRouting() throws {
        let store = SampleKnarrStore()
        let h = HomeHarness(width: 1440, height: 900, store: store) {
            $0.set(false, forKey: "knarr.projectSessionCollapsed.gamza")
        }
        defer { h.close() }
        TestWindow.present(h.window)
        h.settle()
        #expect(!identifiers(try #require(h.window.contentView)).contains("project-transfer-menu"))
        store.selectProjectConversation("gamza")
        h.settle()
        let sourceIDs = identifiers(try #require(h.window.contentView))
        #expect(sourceIDs.contains("thread-" + store.selectedThreadID))
        #expect(sourceIDs.contains("project-transfer-menu"))
        store.selectThread(ConversationThread.defaultID)
        h.settle()
        #expect(!identifiers(try #require(h.window.contentView)).contains("project-transfer-menu"))
        #expect(identifiers(try #require(h.window.contentView)).contains("thread-" + ConversationThread.defaultID))
    }

    @Test(arguments: [false, true]) func mainReceiptCardOpensOriginalConversationDirectly(archived: Bool) async throws {
        let store = SampleKnarrStore(projectSessionScene: .transferMain)
        let transfer = try #require(store.projectTransfers.first)
        if archived { store.setProjectArchived(transfer.originProjectID, true) }
        let h = HomeHarness(width: 1440, height: 900, store: store) {
            $0.set(true, forKey: "knarr.projectSessionCollapsed.gamza")
        }
        defer { h.close() }
        TestWindow.present(h.window); h.settle()
        let host = try #require(h.window.contentView)
        await h.waitWeb()
        let clicked = await h.webJSON("(()=>{const e=document.querySelector('[data-transfer-receipt] button');if(!e)return false;e.click();return true;})()") as? Bool
        #expect(clicked == true)
        let deadline = Date().addingTimeInterval(5)
        while store.selectedThreadID != transfer.originThreadID && Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        h.settle()
        #expect(store.selectedThreadID == transfer.originThreadID)
        #expect(identifiers(host).contains("thread-" + transfer.originThreadID))
        #expect(h.defaults.bool(forKey: "knarr.projectSessionCollapsed.gamza"))
        #expect(store.chat.contains { $0.id == transfer.requestMessageID })
        if archived {
            #expect(h.composer == nil)
            #expect(!identifiers(host).contains("project-transfer-menu"))
        }
    }
}
