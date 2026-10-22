import AppKit
import Foundation
import SwiftUI
import Testing
import KnarrCore
@testable import KnarrUI

/// The transcript must not rebuild rows whose content did not change: a Hird activity tick changes
/// one card, and a person clicking another control must keep the caret where they put it.
@MainActor @Suite(.serialized, .enabled(if: KnarrUITests.enabled)) struct ChatWebPerformanceTests {
    private func preferences() throws -> (String, UserDefaults) {
        let suite = "knarr-web-performance-" + UUID().uuidString
        return (suite, try #require(UserDefaults(suiteName: suite)))
    }

    /// A transcript with many plain messages and one running Issue card.
    private func store() -> ChangingCardsStore {
        let store = ChangingCardsStore()
        store.chat = (0..<60).map { .init(at: .now, kind: .user("메시지 \($0) " + String(repeating: "본문 ", count: 20))) }
            + [.init(at: .now, kind: .issue("above"))]
        return store
    }

    @Test func issueActivityRebuildsOnlyItsOwnRow() async throws {
        let (suite, prefs) = try preferences(); defer { prefs.removePersistentDomain(forName: suite) }
        let store = store()
        let h = WebChatHarness(store: store, defaults: prefs); defer { h.close() }
        try await h.wait("document.querySelectorAll('[data-message]').length > 10")
        try await h.wait("document.body.textContent.includes('합성 작업')")
        // The first refresh built every row; the next one must build none while nothing changes.
        ChatWebProjection.resetBuildCount()
        store.isResponding = true
        try await Task.sleep(for: .milliseconds(150))
        let quiet = ChatWebProjection.buildCount
        ChatWebProjection.resetBuildCount()
        // One tool activity tick on the card's Hird: the card's own text changes, nothing else does.
        store.issues[0].hirds[0].currentCommand = "edit Sources/Changed.swift"
        store.issues[0].hirds[0].lastActivityAt = .now
        try await h.wait("document.querySelector('.live-label') !== null")
        try await Task.sleep(for: .milliseconds(150))
        let afterTick = ChatWebProjection.buildCount
        #expect(quiet == 0, "an unrelated state change rebuilt \(quiet) unchanged rows")
        #expect(afterTick == 1, "one card changed but \(afterTick) rows were rebuilt")
    }

    @Test func pictureMarkdownIsRewrittenOnceForTheWholeTranscript() async throws {
        let (suite, prefs) = try preferences(); defer { prefs.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("knarr-rewrite-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let shot = root.appendingPathComponent("shot.png")
        // Bytes only need to exist; the resolver checks the path rules, not the image.
        try Data([0x89, 0x50, 0x4e, 0x47]).write(to: shot)
        let resolver = ChatImageResolver()
        let text = "보세요 ![화면](\(shot.path))"
        let first = resolver.rewriting(text)
        #expect(first != text)
        #expect(first == resolver.rewriting(text))
        // The same address serves on every build, so the page does not reload the picture.
        #expect(first.contains("chat-image://image/"))
        // A different reply is still rewritten and served.
        let other = resolver.rewriting("다른 그림 ![두번째](\(shot.path))")
        #expect(other != first && other.contains("chat-image://image/"))
    }
}
