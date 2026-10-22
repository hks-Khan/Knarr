import AppKit
import WebKit
import SwiftUI
import Testing
import KnarrCore
@testable import KnarrUI

@MainActor @Suite(.serialized, .enabled(if: KnarrUITests.enabled)) struct MessageConversationWindowTests {
    init() { TestWindow.prepare() }
    private func source(_ text: String) -> ChatItem {
        var item = ChatItem(at: .now, kind: .user(text)); item.isConversationLink = true
        return item
    }
    private func isolatedPreferences() throws -> (UserDefaults, () -> Void) {
        let suite = "knarr-native-conversation-" + UUID().uuidString
        let preferences = try #require(UserDefaults(suiteName: suite))
        return (preferences, { preferences.removePersistentDomain(forName: suite) })
    }
    /// Holds one send open so a test can watch the window while the message is still in flight.
    @MainActor final class SubmitGate {
        private var continuation: CheckedContinuation<Void, Never>?
        private(set) var entries = 0
        var entered: Bool { entries > 0 }
        func wait() async {
            entries += 1
            await withCheckedContinuation { continuation = $0 }
        }
        func open() { continuation?.resume(); continuation = nil }
    }
    private func sendEvent(in window: NSWindow) -> NSEvent? {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .option,
            timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "\r",
            charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)
    }
    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    private func attribute(_ node: NSObject, _ selector: String) -> Any? {
        let action = NSSelectorFromString(selector)
        if node.responds(to: action), let result = node.perform(action)?.takeUnretainedValue() { return result }
        let name = ["accessibilityChildren": "AXChildren", "accessibilityLabel": "AXDescription",
                    "accessibilityIdentifier": "AXIdentifier", "accessibilityValue": "AXValue",
                    "accessibilityEnabled": "AXEnabled"][selector]
        return name.flatMap { node.accessibilityAttributeValue(NSAccessibility.Attribute(rawValue: $0)) }
    }
    private func elements(_ node: NSObject) -> [NSObject] {
        [node] + ((attribute(node, "accessibilityChildren") as? [NSObject]) ?? []).flatMap(elements)
    }
    /// Every text the window announces: labels, identifiers and values of SwiftUI's accessibility nodes.
    private func accessibilityTexts(_ host: NSView) -> [String] {
        elements(host).flatMap { node in
            ["accessibilityLabel", "accessibilityIdentifier"].compactMap { attribute(node, $0) as? String }
                + [attribute(node, "accessibilityValue") as? String].compactMap { $0 }
        }
    }
    @Test func reopensExistingWindowAndKeepsDifferentRootsIndependent() throws {
        _ = NSApplication.shared
        let store = ChangingCardsStore(), a = source("첫 주제\n문맥"), b = source("두 번째 주제")
        store.chat = [a, b]
        let (preferences, clean) = try isolatedPreferences()
        let windows = MessageConversationWindows(preferences: preferences)
        defer { windows.closeAll(); clean() }
        windows.open(a.id, store: store)
        let first = try #require(windows.window(for: a.id))
        windows.open(a.id, store: store)
        #expect(windows.window(for: a.id) === first)
        windows.open(b.id, store: store)
        let second = try #require(windows.window(for: b.id))
        #expect(first !== second && first.isVisible && second.isVisible)
        #expect(first.title == "첫 주제")
        #expect(first.styleMask.contains(.resizable) && second.styleMask.contains(.closable))
        windows.close(a.id)
        #expect(windows.window(for: a.id) == nil && windows.window(for: b.id) === second)
    }
    @Test func restoresRootSpecificFrameAcrossManagers() throws {
        _ = NSApplication.shared
        let suite = "knarr-conversation-frame-" + UUID().uuidString
        let prefs = try #require(UserDefaults(suiteName: suite))
        defer { prefs.removePersistentDomain(forName: suite) }
        let store = ChangingCardsStore(), a = source("프레임")
        store.chat = [a]
        let first = MessageConversationWindows(preferences: prefs)
        first.open(a.id, store: store)
        let window = try #require(first.window(for: a.id))
        let frame = NSRect(x: 100, y: 100, width: 630, height: 580)
        window.setFrame(frame, display: true)
        first.close(a.id)
        let next = MessageConversationWindows(preferences: prefs)
        defer { next.closeAll() }
        // The test presenter moves every window offscreen; capture the restored frame it was given.
        TestWindow.prepare()
        var presented: NSRect?
        MessageConversationWindows.present = { window in presented = window.frame; TestWindow.present(window) }
        defer { MessageConversationWindows.present = TestWindow.present }
        next.open(a.id, store: store)
        #expect(presented == frame)
        // The window keeps the restored frame but sits outside every screen while shown.
        let shown = try #require(next.window(for: a.id))
        #expect(shown.frame.origin == TestWindow.offscreenOrigin)
        #expect(!NSScreen.screens.contains { $0.frame.intersects(shown.frame) })
        #expect(!shown.canBecomeKey)
    }
    @Test func failureKeepsWindowDraftAndAttachmentsThenRetryClearsOnlySentDraft() async {
        let store = ChangingCardsStore(), a = source("첨부")
        store.chat = [a]; store.failSubmit = true
        let model = MessageConversationDraft(rootID: a.id, threadID: store.selectedThreadID)
        let file = URL(fileURLWithPath: "/tmp/window-attachment.txt")
        model.draft.text = "확인"; model.add([file, file])
        await model.submit(store)
        #expect(model.draft.text == "확인" && model.draft.attachments == [file])
        #expect(model.error != nil)
        store.failSubmit = false
        await model.submit(store)
        #expect(store.submittedDrafts.last?.conversationRootID == a.id)
        #expect(store.submittedDrafts.last?.attachments == [file])
        #expect(model.draft.isEmpty && model.error == nil)
    }
    @Test func closingDuringFailedSendReleasesInstallGate() async throws {
        let store = ChangingCardsStore(), a = source("닫기")
        store.chat = [a]; store.failSubmit = true
        let gate = SubmitGate()
        store.whileSubmitting = { await gate.wait() }
        var busy = false
        let model = MessageConversationDraft(rootID: a.id, threadID: store.selectedThreadID, busyChanged: { busy = $0 })
        model.draft.text = "작성 중"
        #expect(busy)
        model.draft.text = ""
        #expect(!busy)
        model.add([URL(fileURLWithPath: "/tmp/attachment.txt")])
        #expect(busy)
        let sending = Task { await model.submit(store) }
        for _ in 0..<100 where !gate.entered { try await Task.sleep(for: .milliseconds(10)) }
        model.windowClosed()
        #expect(busy)
        gate.open()
        await sending.value
        #expect(!busy)
        #expect(model.draft.isEmpty)
    }

    @Test func missingRootRejectsSubmission() async {
        let store = ChangingCardsStore(), a = source("삭제")
        let model = MessageConversationDraft(rootID: a.id, threadID: store.selectedThreadID)
        model.draft.text = "남은 초안"
        await model.submit(store)
        #expect(store.submittedDrafts.isEmpty && model.draft.text == "남은 초안")
    }
    /// A send that waits behind a running answer must still clear the input, say so, and stay a single send.
    @Test func waitingSendClearsInputShowsStatusAndSendsOnce() async throws {
        _ = NSApplication.shared
        let store = ChangingCardsStore(), a = source("대기 전송")
        store.chat = [a]
        store.isResponding = true
        let gate = SubmitGate()
        store.whileSubmitting = { await gate.wait() }
        let (preferences, clean) = try isolatedPreferences()
        let windows = MessageConversationWindows(preferences: preferences)
        defer { windows.closeAll(); clean() }
        windows.open(a.id, store: store)
        let window = try #require(windows.window(for: a.id))
        TestWindow.present(window)
        var editor: ComposerTextView?
        for _ in 0..<100 {
            editor = window.contentView.flatMap { descendants($0).compactMap { $0 as? ComposerTextView }.first }
            if editor != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let input = try #require(editor)
        input.insertText("대기 중 전송", replacementRange: NSRange(location: NSNotFound, length: 0))
        input.keyDown(with: try #require(sendEvent(in: window)))
        for _ in 0..<100 {
            if gate.entered { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(gate.entered)
        let host = try #require(window.contentView)
        var cleared = false
        for _ in 0..<100 {
            if input.string.isEmpty { cleared = true; break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(cleared, "보내기를 누르면 전송이 끝나기 전에 입력창이 비워져야 해요")
        var statusShown = false
        for _ in 0..<100 {
            if accessibilityTexts(host).contains(where: { $0.hasPrefix("보내는 중") }) { statusShown = true; break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(statusShown, "답을 기다리는 동안 보내는 중 상태가 창에 보여야 해요")
        // Pressing again while the first send is still in flight must not queue a second copy.
        input.insertText("두 번째 초안", replacementRange: NSRange(location: NSNotFound, length: 0))
        input.keyDown(with: try #require(sendEvent(in: window)))
        input.keyDown(with: try #require(sendEvent(in: window)))
        for _ in 0..<20 { await Task.yield() }
        #expect(gate.entries == 1, "보내는 중에는 다시 보내지고 저장되지 않아야 해요")
        gate.open()
        for _ in 0..<100 {
            if !store.submittedDrafts.isEmpty { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(store.submittedDrafts.map(\.text) == ["대기 중 전송"])
        #expect(store.submittedDrafts.first?.conversationRootID == a.id)
        #expect(input.string == "두 번째 초안", "보내는 동안 적은 내용은 다음 초안으로 남아야 해요")
    }
    @Test(arguments: [false, true]) func actualWindowFiltersRepliesAndClosesWhenRootDisappears(dark: Bool) async throws {
        _ = NSApplication.shared
        let store = ChangingCardsStore(), a = source("연결 방식 확인"), b = source("다른 주제")
        var reply = ChatItem(at: .now, kind: .stallari("## 연결 확인\n\n이 창의 답변입니다.", project: nil))
        reply.conversationRootID = a.id
        var foreign = ChatItem(at: .now, kind: .stallari("다른 창의 답변", project: nil))
        foreign.conversationRootID = b.id
        store.chat = [a, b, reply, foreign]
        let (preferences, clean) = try isolatedPreferences()
        let windows = MessageConversationWindows(preferences: preferences)
        defer { windows.closeAll(); clean() }
        windows.open(a.id, store: store)
        let window = try #require(windows.window(for: a.id))
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        var web: WKWebView?
        for _ in 0..<100 {
            web = window.contentView.flatMap { descendants($0).compactMap { $0 as? WKWebView }.first }
            if let web, (try? await web.evaluateJavaScript("document.body.textContent.includes('이 창의 답변입니다.')")) as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let transcript = try #require(web)
        #expect(try await transcript.evaluateJavaScript("document.body.textContent.includes('이 창의 답변입니다.')") as? Bool == true)
        #expect(try await transcript.evaluateJavaScript("document.body.textContent.includes('다른 창의 답변')") as? Bool == false)
        let editor = try #require(window.contentView.flatMap { descendants($0).compactMap { $0 as? ComposerTextView }.first })
        editor.insertText("한글 입력", replacementRange: NSRange(location: NSNotFound, length: 0))
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .option,
            timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "\r",
            charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        editor.keyDown(with: event)
        for _ in 0..<50 {
            if !store.submittedDrafts.isEmpty { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(store.submittedDrafts.last?.text == "한글 입력")
        #expect(store.submittedDrafts.last?.conversationRootID == a.id)
        if let directory = ProcessInfo.processInfo.environment["KNARR_WINDOW_SCREENSHOTS"], let content = window.contentView {
            content.layoutSubtreeIfNeeded()
            let bitmap = try #require(content.bitmapImageRepForCachingDisplay(in: content.bounds))
            content.cacheDisplay(in: content.bounds, to: bitmap)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            let folder = URL(fileURLWithPath: directory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try png.write(to: folder.appendingPathComponent(dark ? "conversation-window-dark.png" : "conversation-window-light.png"))
        }
        store.chat.removeAll { $0.id == a.id }
        for _ in 0..<50 {
            if windows.window(for: a.id) == nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(windows.window(for: a.id) == nil)
    }
    @Test func commandWAndEscapeCloseOnlyConversation() throws {
        _ = NSApplication.shared
        let main = TestWindow.make(size: NSSize(width: 800, height: 600), styleMask: [.titled, .closable])
        TestWindow.present(main)
        defer { main.close() }
        let store = ChangingCardsStore(), a = source("닫기")
        store.chat = [a]
        let (preferences, clean) = try isolatedPreferences()
        let windows = MessageConversationWindows(preferences: preferences)
        defer { windows.closeAll(); clean() }
        windows.open(a.id, store: store)
        let window = try #require(windows.window(for: a.id))
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "w",
            charactersIgnoringModifiers: "w", isARepeat: false, keyCode: 13))
        #expect(window.performKeyEquivalent(with: event))
        #expect(windows.window(for: a.id) == nil && main.isVisible)
        windows.open(a.id, store: store)
        try #require(windows.window(for: a.id)).cancelOperation(nil)
        #expect(windows.window(for: a.id) == nil && main.isVisible)
    }
    @Test func mainOptionReturnStartsFocusedConversationInPlace() async throws {
        _ = NSApplication.shared
        let store = ChangingCardsStore()
        store.chat = []
        let title = "새 집중 대화 " + UUID().uuidString
        let file = URL(fileURLWithPath: "/tmp/new-conversation-attachment.txt")
        store.composerDraft = ChatDraft(text: title, attachments: [file])
        let (preferences, clean) = try isolatedPreferences()
        defer { clean() }
        let main = TestWindow.make(size: NSSize(width: 1000, height: 740), styleMask: [.titled, .closable])
        main.contentView = NSHostingView(rootView: HomeView(store: store).environment(\.chatWebPreferences, preferences))
        TestWindow.present(main)
        defer {
            for window in NSApp.windows where window.title == title { window.close() }
            main.contentView = nil; main.close()
        }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        var editor: ComposerTextView?
        for _ in 0..<100 {
            editor = main.contentView.flatMap { descendants($0).compactMap { $0 as? ComposerTextView }.first }
            if editor != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let input = try #require(editor)
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .option,
            timestamp: 0, windowNumber: main.windowNumber, context: nil, characters: "\r",
            charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        input.keyDown(with: event)
        var started: ChatItem?
        for _ in 0..<150 {
            started = store.chat.first(where: { item in
                if case .user(title) = item.kind { true } else { false }
            })
            if started != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let root = try #require(started)
        #expect(root.isConversationLink && root.attachments == [file] && root.conversationRootID == nil)
        #expect(store.chat.filter { $0.kind == .user(title) }.count == 1)
        // A new focused conversation expands in the transcript; the canvas header owns the window action.
        let web = try #require(main.contentView.flatMap { descendants($0).compactMap { $0 as? WKWebView }.first })
        let literal = "\"" + title.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        var expanded = false
        for _ in 0..<150 {
            let script = "(function(){const c=document.querySelector('.conversation-canvas');"
                + "return !!c && c.textContent.includes(\(literal))"
                + " && c.querySelector('.conversation-header .conversation-eyebrow')?.textContent === '집중 대화'"
                + " && !!c.querySelector('textarea');})()"
            if (try? await web.evaluateJavaScript(script)) as? Bool == true { expanded = true; break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(expanded)
        // The main composer keeps working and the draft was sent exactly once.
        #expect(descendants(main.contentView!).contains { $0 is ComposerTextView })
        #expect(store.submittedDrafts.count == 1)
        #expect(!NSApp.windows.contains { $0.title == title && $0.isVisible && $0 !== main })
    }
}
