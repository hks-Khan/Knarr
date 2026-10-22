import AppKit
import SwiftUI
import WebKit
import Testing
import KnarrCore
@testable import KnarrUI

/// The real home screen hosted offscreen at a chosen window size, framed like KnarrApp.
@MainActor final class HomeHarness {
    let store: any KnarrStore
    let suite: String
    let defaults: UserDefaults
    let window: NSWindow

    init(width: CGFloat, height: CGFloat, opened: KnarrCore.Issue.ID? = nil, page: HomePage = .conversation,
         messages: Int = 0, store: any KnarrStore = SampleKnarrStore(), suite: String? = nil,
         preferences: (UserDefaults) -> Void = { _ in }) {
        self.store = store
        self.suite = suite ?? "knarr-home-test-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: self.suite)!
        defaults.set(false, forKey: "knarr.issueCardsCollapsed")
        preferences(defaults)
        for i in 0..<messages {
            let label = String(format: "메시지 %02d ", i)
            store.send(label + String(repeating: "창 너비가 바뀌면 줄바꿈이 달라지는 긴 문장입니다. ", count: 8), about: nil, project: nil, attachments: [])
        }
        let root = HomeView(store: store, opened: opened, page: page)
            .frame(minWidth: 720, minHeight: 540)
            .defaultAppStorage(defaults)
            .environment(\.chatWebPreferences, defaults)
            .environment(\.colorScheme, .light)
        let host = NSHostingView(rootView: root)
        host.appearance = NSAppearance(named: .aqua)
        window = TestWindow.make(size: NSSize(width: width, height: height), styleMask: [.borderless])
        window.contentView = host
        TestWindow.present(window)
        settle()
    }

    func settle(_ seconds: Double = 0.5) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
    func resize(width: CGFloat, height: CGFloat) {
        window.setContentSize(NSSize(width: width, height: height))
        settle()
    }
    /// `keepingPreferences` leaves the suite behind so a second harness can read what the app saved.
    func close(keepingPreferences: Bool = false) {
        window.contentView = nil
        window.close()
        if !keepingPreferences { defaults.removePersistentDomain(forName: suite) }
    }

    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    var views: [NSView] { window.contentView.map(descendants) ?? [] }
    func frameInWindow(_ view: NSView) -> NSRect { view.convert(view.bounds, to: nil) }

    /// The transcript scroll view: the one ConversationView tracks.
    var conversation: WKWebView? { views.compactMap { $0 as? WKWebView }.first }
    var composer: ComposerTextView? { views.lazy.compactMap { $0 as? ComposerTextView }.first }
    /// Non-transcript scroll views, including top cards and the detail drawer.
    var sideScrolls: [NSScrollView] {
        views.compactMap { $0 as? NSScrollView }
            .filter { scroll in !(scroll.documentView is NSTextView) && !(conversation.map { scroll.isDescendant(of: $0) } ?? false) }
            .sorted { frameInWindow($0).minX < frameInWindow($1).minX }
    }
    /// The detail's scroll view: flush with the window's trailing edge and spanning the transcript's
    /// vertical middle. A split panel is narrower than the transcript; a narrow-window overlay covers it.
    var panel: NSScrollView? {
        guard let conversation else { return nil }
        let midpoint = frameInWindow(conversation).midY
        return sideScrolls.last {
            let frame = frameInWindow($0)
            return abs(frame.maxX - window.frame.width) < 1 && frame.minY <= midpoint && frame.maxY >= midpoint
        }
    }

    func webJSON(_ expression: String) async -> Any? {
        guard let web = conversation else { return nil }
        let raw: String? = await withCheckedContinuation { continuation in
            web.evaluateJavaScript("JSON.stringify((()=>{return (" + expression + ");})())") { value, _ in continuation.resume(returning: value as? String) }
        }
        return raw.flatMap { $0.data(using: .utf8) }.flatMap { try? JSONSerialization.jsonObject(with: $0, options: .fragmentsAllowed) }
    }
    func waitWeb() async {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if await webJSON("window.knarr?.ready === true && document.querySelectorAll('[data-message]').length > 0") as? Bool == true { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }
    var distanceFromBottom: CGFloat {
        get async {
            await waitWeb()
            try? await Task.sleep(for: .milliseconds(150))
            let distance = (await webJSON("(()=>{const e=document.querySelector('.viewport');return e.scrollHeight-e.scrollTop-e.clientHeight;})()") as? NSNumber).map { CGFloat(truncating: $0) } ?? .infinity
            return distance
        }
    }
    func field(_ prefix: String) -> NSTextField? {
        views.lazy.compactMap { $0 as? NSTextField }.first { $0.stringValue.hasPrefix(prefix) }
    }
    func revealMessage(_ prefix: String) async -> String? {
        guard let item = store.chat.first(where: { item in
            switch item.kind { case .user(let s), .stallari(let s, _): s.hasPrefix(prefix); default: false }
        }) else { return nil }
        await waitWeb(); await userScroll(toDocumentY: 0)
        for _ in 0..<200 {
            if await webJSON("document.querySelector('[data-message=\"\(item.id.uuidString)\"]') !== null") as? Bool == true { return item.id.uuidString }
            _ = await webJSON("(()=>{const e=document.querySelector('.viewport');e.dispatchEvent(new WheelEvent('wheel',{bubbles:true,deltaY:-1}));e.scrollTop+=e.clientHeight/2;return true;})()")
            try? await Task.sleep(for: .milliseconds(20))
        }
        return nil
    }
    func messageOffset(_ id: String) async -> CGFloat? {
        (await webJSON("document.querySelector('[data-message=\"\(id)\"]')?.getBoundingClientRect().top") as? NSNumber).map { CGFloat(truncating: $0) }
    }
    func alignMessage(_ id: String, offset: CGFloat) async {
        _ = await webJSON("(()=>{const e=document.querySelector('[data-message=\"\(id)\"]');document.querySelector('.viewport').dispatchEvent(new WheelEvent('wheel',{bubbles:true,deltaY:-1}));document.querySelector('.viewport').scrollTop+=e.getBoundingClientRect().top-\(offset);return true;})()")
        settle()
    }
    func userScroll(toDocumentY y: CGFloat) async {
        _ = await webJSON("(()=>{const e=document.querySelector('.viewport');e.dispatchEvent(new WheelEvent('wheel',{bubbles:true,deltaY:-1}));e.scrollTop=\(y);e.dispatchEvent(new Event('scroll'));return true;})()")
        settle()
    }

}

@MainActor @Suite(.serialized, .enabled(if: KnarrUITests.enabled)) struct HomeUsabilityTests {
    // MARK: Small windows and the task panel

    @Test func minimumWindowKeepsRailConversationAndComposerOnScreen() async throws {
        let h = HomeHarness(width: 720, height: 540)
        defer { h.close() }
        let conversation = h.frameInWindow(try #require(h.conversation))
        #expect(conversation.minX >= 63.5)
        #expect(conversation.maxX <= 720.5)
        let composer = h.frameInWindow(try #require(h.composer?.enclosingScrollView))
        #expect(composer.minX >= conversation.minX && composer.maxX <= conversation.maxX)
    }

    @Test func openDrawerFitsInsideConversationWithoutASidebar() async throws {
        let h = HomeHarness(width: 900, height: 620, opened: "npc-repeat")
        defer { h.close() }
        let conversation = h.frameInWindow(try #require(h.conversation))
        let drawer = try #require(h.sideScrolls.first { abs(h.frameInWindow($0).maxX - 900) < 1 })
        let frame = h.frameInWindow(drawer)
        #expect(conversation.minX >= 63.5)
        #expect(frame.minX >= conversation.minX - 0.5)
        #expect(frame.maxX <= 900.5)
    }

    @Test func topCardsNeverReduceConversationWidthWhenResized() async throws {
        let h = HomeHarness(width: 1200, height: 700)
        defer { h.close() }
        let widths: [CGFloat] = [1200, 760, 950]
        for width in widths {
            h.resize(width: width, height: 700)
            let frame = h.frameInWindow(try #require(h.conversation))
            #expect(frame.minX >= 63.5)
            #expect(abs(frame.maxX - width) < 1)
        }
    }

    // MARK: Transcript position across resizes

    @Test func latestMessageStaysInViewWhenWindowResizes() async throws {
        let h = HomeHarness(width: 1400, height: 900, messages: 24)
        defer { h.close() }
        // "At the latest message" leaves at most the transcript's 22pt bottom padding below the view.
        #expect((await h.distanceFromBottom) < 23)
        h.resize(width: 720, height: 540)
        #expect((await h.distanceFromBottom) < 23)
        h.resize(width: 1300, height: 820)
        #expect((await h.distanceFromBottom) < 23)
    }

    @Test func historyBeingReadStaysPutWhenWindowResizes() async throws {
        let h = HomeHarness(width: 1400, height: 900, messages: 24)
        defer { h.close() }
        let target = try #require(await h.revealMessage("메시지 08 "))
        await h.alignMessage(target, offset: 40)
        let before = try #require(await h.messageOffset(target))
        #expect(abs(before - 40) < 2)
        h.resize(width: 720, height: 540)
        let after = try #require(await h.messageOffset(target))
        #expect(abs(after - before) < 24)
        #expect((await h.distanceFromBottom) > 200)
        h.resize(width: 1400, height: 900)
        let restored = try #require(await h.messageOffset(target))
        #expect(abs(restored - before) < 24)
    }

    // MARK: Keyboard

    @Test func commandFOpensSearchAndKeepsTheDraftInFocus() async throws {
        let h = HomeHarness(width: 1120, height: 780)
        defer { h.close() }
        h.store.composerDraft.text = "첫 줄\n둘째 줄"
        h.settle(0.2)
        let editor = try #require(h.composer)
        #expect(h.window.makeFirstResponder(editor))
        let commandF = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                                                    windowNumber: h.window.windowNumber, context: nil, characters: "f",
                                                    charactersIgnoringModifiers: "f", isARepeat: false, keyCode: 3))
        #expect(h.window.performKeyEquivalent(with: commandF))
        h.settle(0.2)
        #expect(h.window.firstResponder === editor)
        #expect(editor.string == "첫 줄\n둘째 줄")
        #expect(h.store.composerDraft.text == "첫 줄\n둘째 줄")
    }
}
