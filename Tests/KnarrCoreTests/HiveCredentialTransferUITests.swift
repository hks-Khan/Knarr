import AppKit
import SwiftUI
import Testing
@testable import KnarrCore
@testable import KnarrUI

@MainActor private final class HiveTransferUIStore: HiveCredentialStore {
    var credential: String?
    var loadCount = 0
    var insertCount = 0
    var failure: Error?

    init(_ credential: String? = nil) { self.credential = credential }

    func load() throws -> String? {
        loadCount += 1
        if let failure { throw failure }
        return credential
    }

    func insertIfAbsent(_ key: String) throws -> Bool {
        insertCount += 1
        if let failure { throw failure }
        guard credential == nil else { return false }
        credential = key
        return true
    }

    func save(_ key: String) { credential = key }
    func remove() { credential = nil }
}

@MainActor @Suite(.serialized, .enabled(if: KnarrUITests.enabled)) struct HiveCredentialTransferUITests {
    @Test func invalidLaunchShowsOnlyAnErrorPanel() throws {
        try withWindow(content: HiveCredentialTransferLaunchErrorView()) { host in
            _ = try control(host, "hive-transfer-launch-error")
            #expect(!elements(host).contains {
                value($0, "accessibilityIdentifier") as? String == "hive-transfer-confirm"
            })
            #expect(elements(host).contains { text($0).contains("운영 대화와 Hird는 시작하지 않았어요") })
        }
    }

    @Test(arguments: [false, true]) func sourceAndDestinationRemainDistinctAndCancelNeverAccessesStores(dark: Bool) throws {
        let source = HiveTransferUIStore("synthetic-source-key")
        let destination = HiveTransferUIStore()
        let transfer = makeTransfer(source: source, destination: destination)
        #expect(source.loadCount == 0 && destination.loadCount == 0 && destination.insertCount == 0)
        try withWindow(dark: dark, content: HiveCredentialTransferView(transfer: transfer)) { host in
            let sourceText = text(try control(host, "hive-transfer-source"))
            let destinationText = text(try control(host, "hive-transfer-destination"))
            #expect(sourceText.contains("/synthetic/Knarr/source-data"))
            #expect(sourceText.contains("원본"))
            #expect(!sourceText.contains("/synthetic/Knarr/destination-data"))
            #expect(destinationText.contains("/synthetic/Knarr/destination-data"))
            #expect(destinationText.contains("대상"))
            #expect(!destinationText.contains("/synthetic/Knarr/source-data"))
            #expect(transfer.status == .awaitingConfirmation)
            #expect(transfer.canConfirm)
            #expect(source.loadCount == 0 && destination.loadCount == 0 && destination.insertCount == 0)
            try capture(host, name: dark ? "hive-transfer-review-dark" : "hive-transfer-review-light")
            try press(host, "hive-transfer-cancel")
            #expect(transfer.status == .cancelled)
            #expect(!transfer.canConfirm)
            #expect(!isEnabled(try control(host, "hive-transfer-confirm")))
            #expect(source.loadCount == 0 && destination.loadCount == 0 && destination.insertCount == 0)
            #expect(source.credential == "synthetic-source-key" && destination.credential == nil)
        }
    }

    @Test(arguments: [false, true]) func explicitNativeApprovalCopiesOnceAndOnlyPreparesConnection(dark: Bool) throws {
        let source = HiveTransferUIStore("synthetic-source-key")
        let destination = HiveTransferUIStore()
        let transfer = makeTransfer(source: source, destination: destination)
        try withWindow(dark: dark, content: HiveCredentialTransferView(transfer: transfer)) { host in
            #expect(source.loadCount == 0 && destination.insertCount == 0)
            try press(host, "hive-transfer-confirm")
            #expect(transfer.status == .completed)
            #expect(!transfer.canConfirm)
            #expect(source.loadCount == 1 && destination.loadCount == 0 && destination.insertCount == 1)
            #expect(source.credential == "synthetic-source-key")
            #expect(destination.credential == "synthetic-source-key")
            #expect(!isEnabled(try control(host, "hive-transfer-confirm")))
            #expect(text(try control(host, "hive-transfer-status")).contains("준비"))
            #expect(elements(host).contains { text($0).contains("인증 검증 성공이나 실행 결과를 뜻하지 않아요") })
            #expect(!elements(host).contains { text($0).contains("synthetic-source-key") })
            try capture(host, name: dark ? "hive-transfer-completed-dark" : "hive-transfer-completed-light")
        }
    }

    @Test func existingDestinationIsPreservedAfterNativeApproval() throws {
        let source = HiveTransferUIStore("synthetic-source-key")
        let destination = HiveTransferUIStore("synthetic-existing-destination-key")
        let transfer = makeTransfer(source: source, destination: destination)
        try withWindow(content: HiveCredentialTransferView(transfer: transfer)) { host in
            #expect(source.loadCount == 0 && destination.insertCount == 0)
            try press(host, "hive-transfer-confirm")
            #expect(transfer.status == .conflict)
            #expect(!transfer.canConfirm)
            #expect(source.credential == "synthetic-source-key")
            #expect(destination.credential == "synthetic-existing-destination-key")
            #expect(source.loadCount == 1 && destination.loadCount == 0 && destination.insertCount == 1)
            #expect(!isEnabled(try control(host, "hive-transfer-confirm")))
            #expect(text(try control(host, "hive-transfer-status")).contains("기존"))
            #expect(!elements(host).contains { text($0).contains("synthetic-existing-destination-key") })
        }
    }

    @Test func failureCanRetryOnlyWithAnotherExplicitApproval() throws {
        let source = HiveTransferUIStore("synthetic-source-key")
        source.failure = NSError(domain: "synthetic-source-key", code: 1,
                                 userInfo: [NSLocalizedDescriptionKey: "synthetic-source-key"])
        let destination = HiveTransferUIStore()
        let transfer = makeTransfer(source: source, destination: destination)
        try withWindow(content: HiveCredentialTransferView(transfer: transfer)) { host in
            try press(host, "hive-transfer-confirm")
            #expect(transfer.status == .failed)
            #expect(transfer.canConfirm)
            #expect(isEnabled(try control(host, "hive-transfer-confirm")))
            #expect(source.loadCount == 1 && destination.insertCount == 0)
            #expect(!elements(host).contains { text($0).contains("synthetic-source-key") })
            source.failure = nil
            settle()
            #expect(source.loadCount == 1 && destination.insertCount == 0)
            try press(host, "hive-transfer-confirm")
            #expect(transfer.status == .completed)
            #expect(source.loadCount == 2 && destination.insertCount == 1)
            #expect(source.credential == "synthetic-source-key")
            #expect(destination.credential == "synthetic-source-key")
        }
    }

    @Test func sameNamespaceCannotBeApprovedOrAccessStores() throws {
        let source = HiveTransferUIStore("synthetic-source-key")
        let destination = HiveTransferUIStore()
        let directory = URL(fileURLWithPath: "/synthetic/Knarr/source-data", isDirectory: true)
        let transfer = HiveCredentialTransfer(sourceDirectory: directory, destinationDirectory: directory,
                                              sourceStore: source, destinationStore: destination)
        try withWindow(content: HiveCredentialTransferView(transfer: transfer)) { host in
            #expect(transfer.status == .failed)
            #expect(!transfer.canConfirm)
            let approval = try control(host, "hive-transfer-confirm")
            #expect(!isEnabled(approval))
            #expect(source.loadCount == 0 && destination.loadCount == 0 && destination.insertCount == 0)
        }
    }

    private func makeTransfer(source: HiveTransferUIStore, destination: HiveTransferUIStore) -> HiveCredentialTransfer {
        HiveCredentialTransfer(
            sourceDirectory: URL(fileURLWithPath: "/synthetic/Knarr/source-data", isDirectory: true),
            destinationDirectory: URL(fileURLWithPath: "/synthetic/Knarr/destination-data", isDirectory: true),
            sourceStore: source, destinationStore: destination)
    }

    private func isEnabled(_ node: NSObject) -> Bool {
        let action = NSSelectorFromString("isAccessibilityEnabled")
        guard node.responds(to: action) else { return false }
        typealias Enabled = @convention(c) (AnyObject, Selector) -> Bool
        return unsafeBitCast(node.method(for: action), to: Enabled.self)(node, action)
    }

    private func value(_ node: NSObject, _ selector: String) -> Any? {
        let action = NSSelectorFromString(selector)
        if node.responds(to: action), let result = node.perform(action)?.takeUnretainedValue() { return result }
        let attributes = ["accessibilityChildren": "AXChildren", "accessibilityIdentifier": "AXIdentifier",
                          "accessibilityLabel": "AXDescription", "accessibilityValue": "AXValue"]
        return attributes[selector].flatMap { node.accessibilityAttributeValue(NSAccessibility.Attribute(rawValue: $0)) }
    }

    private func elements(_ node: NSObject) -> [NSObject] {
        [node] + ((value(node, "accessibilityChildren") as? [NSObject]) ?? []).flatMap(elements)
    }

    private func control(_ root: NSObject, _ id: String) throws -> NSObject {
        try #require(elements(root).first { value($0, "accessibilityIdentifier") as? String == id })
    }

    private func press(_ root: NSObject, _ id: String) throws {
        let button = try control(root, id)
        let action = NSSelectorFromString("accessibilityPerformPress")
        try #require(button.responds(to: action))
        typealias Press = @convention(c) (AnyObject, Selector) -> Bool
        #expect(unsafeBitCast(button.method(for: action), to: Press.self)(button, action))
        settle()
    }

    private func text(_ node: NSObject) -> String {
        ["accessibilityLabel", "accessibilityValue"].compactMap { value(node, $0) as? String }.joined(separator: " ")
    }

    private func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.12)) }

    private func withWindow<Content: View>(dark: Bool = false, content: Content,
                                           _ body: (NSHostingView<Content>) throws -> Void) throws {
        let host = NSHostingView(rootView: content)
        let window = TestWindow.make(size: NSSize(width: 820, height: 600), styleMask: [.borderless], dark: dark)
        window.contentView = host
        TestWindow.present(window)
        host.layoutSubtreeIfNeeded()
        settle()
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        try body(host)
    }

    private func capture(_ host: NSView, name: String) throws {
        guard let path = ProcessInfo.processInfo.environment["KNARR_HIVE_TRANSFER_UI_EVIDENCE"] else { return }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:]))
            .write(to: directory.appendingPathComponent(name + ".png"))
    }
}
