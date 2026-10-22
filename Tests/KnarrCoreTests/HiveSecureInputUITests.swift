import AppKit
import SwiftUI
import Testing
@testable import KnarrCore
@testable import KnarrUI

@MainActor private final class HiveUIStore: HiveCredentialStore {
    var credential: String? = "synthetic-previous-key"
    func load() -> String? { credential }
    func save(_ key: String) { credential = key }
    func insertIfAbsent(_ key: String) -> Bool {
        guard credential == nil else { return false }
        credential = key
        return true
    }
    func remove() { credential = nil }
}

@MainActor @Suite(.serialized, .enabled(if: KnarrUITests.enabled)) struct HiveSecureInputUITests {
    private func elements(_ node: NSObject) -> [NSObject] {
        [node] + ((value(node, "accessibilityChildren") as? [NSObject]) ?? []).flatMap(elements)
    }
    private func value(_ node: NSObject, _ selector: String) -> Any? {
        let action = NSSelectorFromString(selector)
        if node.responds(to: action) { return node.perform(action)?.takeUnretainedValue() }
        let attributes = ["accessibilityChildren": "AXChildren", "accessibilityIdentifier": "AXIdentifier"]
        return attributes[selector].flatMap { node.accessibilityAttributeValue(NSAccessibility.Attribute(rawValue: $0)) }
    }
    private func press(_ root: NSObject, _ id: String) throws {
        let button = try #require(elements(root).first { value($0, "accessibilityIdentifier") as? String == id })
        let action = NSSelectorFromString("accessibilityPerformPress")
        try #require(button.responds(to: action))
        typealias Press = @convention(c) (AnyObject, Selector) -> Bool
        #expect(unsafeBitCast(button.method(for: action), to: Press.self)(button, action))
    }
    private func views(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(views) }
    private func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.12)) }

    @Test(arguments: [false, true]) func nativeSecureEntryCancelAndReplace(dark: Bool) async throws {
        _ = NSApplication.shared
        let store = HiveUIStore()
        let actual = HiveConnection(store: store)
        let host = NSHostingView(rootView: HiveConnectionSettings(connection: actual, verify: {
            await actual.verify { throw HiveProbeError.incomplete }
        }).padding().frame(width: 720, height: 400).background(K.canvas).environment(\.colorScheme, dark ? .dark : .light))
        let window = TestWindow.make(size: NSSize(width: 720, height: 400), styleMask: [.borderless], dark: dark)
        window.contentView = host; TestWindow.present(window); host.layoutSubtreeIfNeeded(); settle()
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        let field = try #require(views(host).compactMap { $0 as? NSSecureTextField }.first)
        #expect(field.stringValue.isEmpty)
        #expect(actual.status == .prepared)
        field.stringValue = "synthetic-cancelled-key"
        NotificationCenter.default.post(name: NSControl.textDidChangeNotification, object: field); settle()
        try press(host, "hive-cancel-key"); settle()
        #expect(field.stringValue.isEmpty)
        #expect(store.credential == "synthetic-previous-key")
        field.stringValue = "synthetic-replacement-key"
        NotificationCenter.default.post(name: NSControl.textDidChangeNotification, object: field); settle()
        try press(host, "hive-save-key"); settle()
        #expect(store.credential == "synthetic-replacement-key")
        #expect(field.stringValue.isEmpty)
        #expect(actual.status == .prepared)
        try press(host, "hive-verify-connection")
        try await Task.sleep(for: .milliseconds(120))
        #expect(actual.status == .failed)
        #expect(!actual.message.contains("synthetic"))
        // Capture only this empty synthetic form, never the real app/user's key screen.
        if let output = ProcessInfo.processInfo.environment["KNARR_HIVE_UI_EVIDENCE"] {
            let directory = URL(fileURLWithPath: output)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try #require(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent(dark ? "hive-secure-dark.png" : "hive-secure-light.png"))
        }
        print("HIVE_SECURE_UI native=NSSecureTextField synthetic=true cancel_preserves=true replace_clears=true failed_verification_not_connected=true scheme=\(dark ? "dark" : "light")")
    }
}
