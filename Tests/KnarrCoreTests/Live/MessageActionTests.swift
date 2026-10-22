import AppKit
import SwiftUI
import WebKit
import Testing
import KnarrCore
@testable import KnarrUI

@MainActor @Suite(.serialized, .enabled(if: KnarrUITests.enabled)) struct MessageActionTests {
    @Test(arguments: [false, true]) func restingActionsAreQuietButRemainKeyboardReachable(dark: Bool) async throws {
        let suite = "knarr-message-actions-" + UUID().uuidString
        let prefs = try #require(UserDefaults(suiteName: suite))
        defer { prefs.removePersistentDomain(forName: suite) }
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let store = ChangingCardsStore()
        store.chat = [.init(at: .now, kind: .user("합성 사용자 본문")),
                      .init(at: .now, kind: .stallari("합성 답변", project: nil))]
        let h = WebChatHarness(store: store, defaults: prefs, dark: dark, pasteboard: board); defer { h.close() }
        try await h.wait("document.querySelector('.user-actions') !== null")
        #expect(try await h.js("document.querySelector('.user-actions button[aria-label=수정]') !== null") == "true")
        #expect(try await h.js("getComputedStyle(document.querySelector('.user-actions')).opacity") == "\"0\"")
        #expect(try await h.js("document.querySelector('.copy').getAttribute('aria-label')") == "\"복사\"")
        _ = try await h.js("(()=>{document.querySelector('.user-actions button[aria-label=수정]').focus({preventScroll:true});return true})()")
        #expect(try await h.js("document.activeElement.getAttribute('aria-label')") == "\"수정\"")
        _ = try await h.js("(()=>{document.querySelector('.user-actions .copy').click();return true})()")
        try await h.wait("document.querySelector('.user-actions .copy').getAttribute('aria-label') === '복사됨'")
        #expect(try await h.js("getComputedStyle(document.querySelector('.user-actions')).opacity") == "\"1\"")
        #expect(try await h.js("getComputedStyle(document.querySelector('.symbol-edit')).webkitMaskImage !== 'none'") == "true")
        try await h.screenshot(dark ? "message-icons-dark" : "message-icons-light")
    }

    @Test func copyUsesPrivatePasteboardAndFeedbackCannotLeakBetweenRows() async throws {
        let suite = "knarr-message-copy-" + UUID().uuidString
        let prefs = try #require(UserDefaults(suiteName: suite))
        let board = NSPasteboard.withUniqueName()
        defer { prefs.removePersistentDomain(forName: suite); board.releaseGlobally() }
        let store = ChangingCardsStore()
        let text = "합성 본문 e\u{301} · 한글\n두 번째 줄"
        let first = ChatItem(at: .now, kind: .user(text))
        let second = ChatItem(at: .now, kind: .stallari("다른 합성 답변", project: nil))
        store.chat = [first, second]
        let h = WebChatHarness(store: store, defaults: prefs, pasteboard: board)
        defer { h.close() }
        let a = "[data-message=\"\(first.id.uuidString)\"] .copy"
        let b = "[data-message=\"\(second.id.uuidString)\"] .copy"
        try await h.wait("document.querySelectorAll('.copy').length === 2")
        let geometry = try await h.js("[...document.querySelectorAll('[data-message]')].map(e=>[e.getBoundingClientRect().top,e.getBoundingClientRect().height]).concat([document.querySelector('.viewport').scrollTop])")
        _ = try await h.js("(()=>{document.querySelector('\(a)').click();return true})()")
        try await h.wait("document.querySelector('\(a)').getAttribute('aria-label') === '복사됨'")
        #expect(board.string(forType: .string) == text)
        #expect(try await h.js("document.querySelector('\(b)').getAttribute('aria-label')") == "\"복사\"")
        try await Task.sleep(for: .milliseconds(950))
        _ = try await h.js("(()=>{document.querySelector('\(a)').click();return true})()")
        try await h.wait("document.querySelector('\(a)').getAttribute('aria-label') === '복사됨'")
        try await Task.sleep(for: .milliseconds(700))
        #expect(try await h.js("document.querySelector('\(a)').getAttribute('aria-label')") == "\"복사됨\"")
        #expect(try await h.js("[...document.querySelectorAll('[data-message]')].map(e=>[e.getBoundingClientRect().top,e.getBoundingClientRect().height]).concat([document.querySelector('.viewport').scrollTop])") == geometry)
        store.chat.removeFirst()
        try await h.wait("document.querySelectorAll('.copy').length === 1")
        try await Task.sleep(for: .milliseconds(850))
        #expect(try await h.js("document.querySelector('.copy').getAttribute('aria-label')") == "\"복사\"")
    }

}
