import AppKit
import Testing
import KnarrCore
@testable import KnarrUI

@MainActor @Suite(.serialized, .enabled(if: KnarrUITests.enabled)) struct ProjectTransferNavigationTests {
    @Test func deliveredSourceOffersMainMessageLink() throws {
        let store = SampleKnarrStore(projectSessionScene: .transferMain)
        let transfer = try #require(store.projectTransfers.first)
        store.selectThread(transfer.originThreadID)
        let source = try #require(store.chat.first { $0.id == transfer.requestMessageID })
        let row = ChatWebProjection.row(source, store: store, state: .object([:]))
        #expect(row["mainTransferID"]?.string == transfer.id)
        let bridge = ChatWebBridge()
        let event: OMPJSON = .object(["session": .string(bridge.session), "thread": .string(store.selectedThreadID),
            "message": .string(source.id.uuidString), "action": .string("transferMain")])
        #expect(bridge.command(event, store: store) != nil)
    }

    @Test func deliveredCardDoesNotStayPinnedInMainOrSource() throws {
        let store = SampleKnarrStore(projectSessionScene: .transferMain)
        let transfer = try #require(store.projectTransfers.first)
        let h = HomeHarness(width: 1440, height: 900, store: store)
        defer { h.close() }
        func identifiers(_ node: NSObject) -> [String] {
            func value(_ selector: String, _ attribute: String) -> Any? {
                let action = NSSelectorFromString(selector)
                if node.responds(to: action), let result = node.perform(action)?.takeUnretainedValue() { return result }
                return node.accessibilityAttributeValue(NSAccessibility.Attribute(rawValue: attribute))
            }
            let own = (value("accessibilityIdentifier", "AXIdentifier") as? String).map { [$0] } ?? []
            let children = value("accessibilityChildren", "AXChildren") as? [NSObject] ?? []
            return own + children.flatMap(identifiers)
        }
        TestWindow.present(h.window); h.settle()
        #expect(!identifiers(try #require(h.window.contentView)).contains("project-transfer-card-" + transfer.id))
        store.selectThread(transfer.originThreadID); h.settle()
        #expect(identifiers(try #require(h.window.contentView)).contains("project-transfer-menu"))
        #expect(!identifiers(try #require(h.window.contentView)).contains("project-transfer-card-" + transfer.id))
    }
    @Test func receiptIdentityAndPositionSurviveRoundTripWithoutChangingSavedMessages() throws {
        let store = SampleKnarrStore(projectSessionScene: .transferMain)
        let transfer = try #require(store.projectTransfers.first)
        let decoded = try JSONDecoder().decode(ProjectTransfer.self, from: JSONEncoder().encode(transfer))
        #expect(decoded.mainMessageID == transfer.mainMessageID)
        let before = ChatItem(at: transfer.deliveredAt!.addingTimeInterval(-1), kind: .user("앞 메시지"))
        let after = ChatItem(at: transfer.deliveredAt!.addingTimeInterval(1), kind: .user("뒤 메시지"))
        let saved = [before, after]
        let projected = ProjectTransfer.transcript(saved, transfers: [decoded], threadID: ConversationThread.defaultID)
        #expect(projected.map(\.id) == [before.id, transfer.mainMessageID, after.id])
        #expect(ProjectTransfer.transcript(projected, transfers: [decoded], threadID: ConversationThread.defaultID) == projected)
        #expect(ProjectTransfer.transcript(saved, transfers: [decoded], threadID: transfer.originThreadID) == saved)
        #expect(saved == [before, after])
    }

    @Test(arguments: [ProjectSessionScene.transferPending, .transferSource])
    func pendingAndFailedTransfersKeepStatusWithoutMainLink(scene: ProjectSessionScene) throws {
        let store = SampleKnarrStore(projectSessionScene: scene)
        let transfer = try #require(store.projectTransfers.first)
        let source = try #require(store.chat.first { $0.id == transfer.requestMessageID })
        #expect(transfer.receiptItem == nil)
        #expect(ChatWebProjection.row(source, store: store, state: .object([:]))["mainTransferID"] == nil)
        let bridge = ChatWebBridge()
        #expect(bridge.command(.object(["session": .string(bridge.session), "thread": .string(store.selectedThreadID),
            "message": .string(source.id.uuidString), "action": .string("transferMain")]), store: store) == nil)
    }

    @Test func transferActionsRejectForeignThreadAndArbitraryTargets() throws {
        let store = SampleKnarrStore(projectSessionScene: .transferMain)
        let transfer = try #require(store.projectTransfers.first)
        let bridge = ChatWebBridge()
        func event(_ message: UUID, _ action: String) -> OMPJSON {
            .object(["session": .string(bridge.session), "thread": .string(store.selectedThreadID),
                     "message": .string(message.uuidString), "action": .string(action), "target": .string(UUID().uuidString)])
        }
        #expect(bridge.command(event(transfer.requestMessageID, "transferMain"), store: store) == nil)
        #expect(bridge.command(event(UUID(), "transferSource"), store: store) == nil)
        guard case .navigateTransfer(let resolved, false) = bridge.command(event(transfer.mainMessageID, "transferSource"), store: store) else {
            Testing.Issue.record("receipt navigation missing"); return
        }
        #expect(resolved.requestMessageID == transfer.requestMessageID)
        store.selectThread(transfer.originThreadID)
        #expect(bridge.command(event(transfer.mainMessageID, "transferSource"), store: store) == nil)
    }

    @Test func sourceLinkReachesReceiptInLongMainTranscriptAndCanBeRepeated() async throws {
        let store = SampleKnarrStore(projectSessionScene: .transferMain)
        let transfer = try #require(store.projectTransfers.first)
        for index in 0..<90 { store.send("후속 메시지 \(index) " + String(repeating: "대화 기록 ", count: 20), about: nil, project: nil, attachments: []) }
        store.selectThread(transfer.originThreadID)
        let h = HomeHarness(width: 1440, height: 900, store: store)
        defer { h.close() }
        TestWindow.present(h.window)
        func wait(_ expression: String) async throws {
            let deadline = Date().addingTimeInterval(10)
            while Date() < deadline {
                if await h.webJSON(expression) as? Bool == true { return }
                try await Task.sleep(for: .milliseconds(30))
            }
            Testing.Issue.record("navigation condition failed: \(expression)")
            throw CocoaError(.coderReadCorrupt)
        }
        for _ in 0..<2 {
            await h.waitWeb()
            try await wait("[...document.querySelectorAll('button')].some(e=>e.textContent==='메인으로 이동')")
            _ = await h.webJSON("(()=>{[...document.querySelectorAll('button')].find(e=>e.textContent==='메인으로 이동').click();return true;})()")
            try await wait("document.querySelector('[data-message=\"\(transfer.mainMessageID.uuidString)\"] [data-transfer-receipt]')!==null")
            #expect(store.selectedThreadID == ConversationThread.defaultID)
            try await wait("(()=>{const e=document.querySelector('[data-message=\"\(transfer.mainMessageID.uuidString)\"]');const v=document.querySelector('.viewport');if(!e||!v)return false;const a=e.getBoundingClientRect(),b=v.getBoundingClientRect();return a.top>=b.top-1&&a.top<b.bottom&&a.bottom>b.top;})()")
            _ = await h.webJSON("(()=>{document.querySelector('[data-transfer-receipt] button').click();return true;})()")
            try await wait("document.querySelector('[data-message=\"\(transfer.requestMessageID.uuidString)\"]')!==null")
            #expect(store.selectedThreadID == transfer.originThreadID)
        }
    }

}
