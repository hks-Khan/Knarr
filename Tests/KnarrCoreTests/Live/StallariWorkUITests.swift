import AppKit
import Testing
import KnarrCore
@testable import KnarrUI

@MainActor @Suite(.serialized, .enabled(if: KnarrUITests.enabled)) struct StallariWorkUITests {
    init() { _ = NSApplication.shared }

    private func value(_ node: NSObject, _ selector: String) -> Any? {
        let action = NSSelectorFromString(selector)
        if node.responds(to: action), let result = node.perform(action)?.takeUnretainedValue() { return result }
        let attribute = ["accessibilityChildren": "AXChildren", "accessibilityIdentifier": "AXIdentifier",
                         "accessibilityLabel": "AXDescription", "accessibilityValue": "AXValue"][selector]
        return attribute.flatMap { node.accessibilityAttributeValue(NSAccessibility.Attribute(rawValue: $0)) }
    }
    private func elements(_ node: NSObject) -> [NSObject] {
        [node] + ((value(node, "accessibilityChildren") as? [NSObject]) ?? []).flatMap(elements)
    }

    @Test(arguments: [StallariWorkScene.single, .multiple])
    func workOnlyConversationShowsEveryWorkerAndUsesCompactRows(scene: StallariWorkScene) throws {
        let store = SampleKnarrStore(stallariWorkScene: scene)
        let h = HomeHarness(width: 1100, height: 800, store: store)
        defer { h.close() }
        TestWindow.present(h.window); h.settle()
        let nodes = elements(try #require(h.window.contentView))
        let card = try #require(nodes.first { value($0, "accessibilityIdentifier") as? String == "stallari-work" })
        let labels = elements(card).flatMap { node in
            ["accessibilityLabel", "accessibilityValue"].compactMap { value(node, $0) as? String }
        }
        #expect(labels.contains("Stallari 작업"))
        #expect(labels.contains("IntegrateTabs"))
        #expect(labels.contains("read"))
        let frame = try #require(card.value(forKey: "accessibilityFrame") as? NSValue).rectValue
        if scene == .single {
            #expect(frame.height <= K.controlHeight * 2 + K.s2 * 2)
            #expect(!labels.contains("CheckCards"))
        } else {
            #expect(labels.contains("CheckCards"))
            #expect(labels.contains("bash"))
            #expect(labels.contains("7분째 조용함"))
            #expect(frame.height <= K.controlHeight * 3 + K.s2 * 2)
        }
        #expect(nodes.contains { value($0, "accessibilityIdentifier") as? String == "issue-cards-scroll" })
        let main = store.selectedThreadID
        store.createThread(name: "다른 대화")
        h.settle()
        #expect(!elements(try #require(h.window.contentView)).contains {
            value($0, "accessibilityIdentifier") as? String == "stallari-work"
        })
        store.selectThread(main)
        h.settle()
        #expect(elements(try #require(h.window.contentView)).contains {
            value($0, "accessibilityIdentifier") as? String == "stallari-work"
        })
    }
}
