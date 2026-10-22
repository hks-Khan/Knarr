import AppKit
import SwiftUI
import WebKit
import Testing
import KnarrCore
@testable import KnarrUI

/// A visible picture, so the inline-image evidence shows a real thumbnail rather than one pixel.
@MainActor private func makePicture(at url: URL) throws {
    let pixels = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 320, pixelsHigh: 160,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: pixels)
    NSColor.systemIndigo.setFill(); NSRect(x: 0, y: 0, width: 320, height: 160).fill()
    NSColor.white.setFill(); NSRect(x: 24, y: 24, width: 120, height: 112).fill()
    NSGraphicsContext.restoreGraphicsState()
    try #require(pixels.representation(using: .png, properties: [:])).write(to: url)
}

@MainActor final class WebChatHarness {
    let window: NSWindow
    let store: any KnarrStore
    let defaults: UserDefaults
    init(store: any KnarrStore, defaults: UserDefaults, dark: Bool = false, target: UUID? = nil, pasteboard: NSPasteboard = .general,
         conversationRootID: UUID? = nil, openConversation: ((UUID) -> Void)? = nil, preview: @escaping (URL) -> Void = { _ in }, restore: @escaping (ChatDraft) -> Void = { _ in }) {
        self.store = store; self.defaults = defaults
        let root = ChatWebView(store: store, highlighted: nil, following: true, jumpToLatest: false, target: target,
            open: { _ in }, restore: restore, preview: preview, followingChanged: { _ in }, targetReached: {},
            conversationRootID: conversationRootID, openConversation: openConversation)
            .frame(maxWidth: .infinity, maxHeight: .infinity).defaultAppStorage(defaults).environment(\.chatWebPreferences, defaults).environment(\.chatWebPasteboard, pasteboard).environment(\.colorScheme, dark ? .dark : .light)
        window = TestWindow.make(size: NSSize(width: 800, height: 740), styleMask: [.titled, .resizable], dark: dark)
        window.title = "Knarr · React 채팅 검증"
        window.contentView = NSHostingView(rootView: root)
        TestWindow.present(window)
    }
    var web: WKWebView? {
        func all(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(all) }
        return window.contentView.flatMap { all($0).compactMap { $0 as? WKWebView }.first }
    }
    func js(_ expression: String) async throws -> String {
        guard let web else { throw CocoaError(.coderReadCorrupt) }
        return try await withCheckedThrowingContinuation { continuation in
            web.evaluateJavaScript("JSON.stringify((()=>{ return (" + expression + "); })())") { value, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: value as? String ?? "null") }
            }
        }
    }
    func wait(_ expression: String, seconds: Double = 10) async throws {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if (try? await js(expression)) == "true" { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        print("WEB DIAGNOSTIC", web?.frame as Any, (try? await js("({ready:window.knarr?.ready, text:document.body.textContent.slice(0,1000), height:document.querySelector('.viewport')?.clientHeight, html:document.getElementById('root')?.innerHTML.slice(0,1000)})")) as Any)
        Testing.Issue.record("WebView condition timed out: \(expression)")
        throw CocoaError(.coderReadCorrupt)
    }
    func screenshot(_ name: String) async throws {
        guard let path = ProcessInfo.processInfo.environment["KNARR_WEB_SCREENSHOTS"], let web else { return }
        let data: Data = try await withCheckedThrowingContinuation { continuation in
            web.takeSnapshot(with: nil) { image, error in
                if let error { continuation.resume(throwing: error) }
                else if let data = image?.tiffRepresentation, let rep = NSBitmapImageRep(data: data), let png = rep.representation(using: .png, properties: [:]) { continuation.resume(returning: png) }
                else { continuation.resume(throwing: CocoaError(.fileWriteUnknown)) }
            }
        }
        let root = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try data.write(to: root.appendingPathComponent(name + ".png"))
    }
    func close() { window.contentView = nil; window.close() }
}

@MainActor @Suite(.serialized, .enabled(if: KnarrUITests.enabled)) struct ChatWebIntegrationTests {
    private func preferences() throws -> (String, UserDefaults) {
        let suite = "knarr-web-integration-" + UUID().uuidString
        return (suite, try #require(UserDefaults(suiteName: suite)))
    }
    @Test(arguments: [false, true]) func messageConversationUsesNativeCallbacksAndFiltersEachWindow(dark: Bool) async throws {
        let (suite, prefs) = try preferences(); defer { prefs.removePersistentDomain(forName: suite) }
        let store = ChangingCardsStore()
        var source = ChatItem(at: .now, kind: .user("그리고 DeepSeek도 연결할 수 있어?"))
        source.isConversationLink = true
        var reply = ChatItem(at: .now, kind: .user("내 API 키로 쓰고 싶어"))
        reply.conversationRootID = source.id
        var answer = ChatItem(at: .now, kind: .stallari("네. 현재 연결 방식을 확인해 볼게요.", project: nil))
        answer.conversationRootID = source.id
        var other = ChatItem(at: .now, kind: .user("다른 주제")); other.isConversationLink = true
        var otherReply = ChatItem(at: .now, kind: .stallari("다른 창의 답변", project: nil)); otherReply.conversationRootID = other.id
        store.chat = [source, reply, answer, other, otherReply,
                      .init(at: .now, kind: .stallari("메인 대화는 계속 이어집니다.", project: nil))]
        var opened: [UUID] = [], restored: [ChatDraft] = []
        let h = WebChatHarness(store: store, defaults: prefs, dark: dark,
            openConversation: { opened.append($0) }, restore: { restored.append($0) }); defer { h.close() }
        try await h.wait("document.querySelector('.conversation-card') !== null")
        #expect(try await h.js("document.querySelector('.transcript').textContent.includes('현재 연결 방식')") == "false")
        _ = try await h.js("(()=>{document.querySelector('.conversation-card-open').click();return true;})()")
        try await h.wait("document.querySelector('.conversation-canvas') !== null")
        // A link expands in place; only the canvas header opens the separate window.
        #expect(opened.isEmpty)
        // The collapsed row survives as the anchor; the panel lives in the dock below the transcript.
        #expect(try await h.js("(()=>{const card=document.querySelector('.conversation-card'),dock=document.querySelector('.conversation-dock'),c=document.querySelector('.conversation-canvas');return !!card && card.classList.contains('active') && !!dock && dock.contains(c) && c.querySelector('.conversation-eyebrow')?.textContent==='집중 대화';})()") == "true")
        #expect(try await h.js("document.querySelector('.message-conversation') === null") == "true")
        try await h.wait("document.querySelector('.conversation-body')?.textContent.includes('현재 연결 방식') === true")
        // The link's own text starts the panel exactly once.
        #expect(try await h.js("[...document.querySelectorAll('.conversation-body [data-message] .bubble')].filter(e=>e.textContent==='그리고 DeepSeek도 연결할 수 있어?').length") == "1")
        let conversation = WebChatHarness(store: store, defaults: prefs, dark: dark,
            conversationRootID: source.id, restore: { restored.append($0) }); defer { conversation.close() }
        try await conversation.wait("document.body.textContent.includes('현재 연결 방식')")
        #expect(try await conversation.js("document.querySelectorAll('[data-message]').length") == "2")
        #expect(try await conversation.js("!document.body.textContent.includes('메인 대화는') && !document.body.textContent.includes('다른 창의 답변')") == "true")
        #expect(try await conversation.js("document.querySelector('[aria-label=\"새 창에서 대화\"]').disabled") == "true")
        _ = try await conversation.js("(()=>{document.querySelector('[aria-label=수정]').click();return true;})()")
        try await Task.sleep(for: .milliseconds(150))
        #expect(restored.count == 1)
        #expect(restored.last?.text == "내 API 키로 쓰고 싶어")
        #expect(restored.last?.conversationRootID == source.id)
        try await conversation.screenshot(dark ? "message-conversation-native-dark" : "message-conversation-native-light")
    }
    @Test func existingUserMessageLinksBeforeOpeningNativeConversationWithoutSending() async throws {
        let (suite, prefs) = try preferences(); defer { prefs.removePersistentDomain(forName: suite) }
        let store = ChangingCardsStore()
        let source = ChatItem(at: .now, kind: .user("이 메시지로 새 대화"))
        store.chat = [source]
        var opened: [UUID] = [], linkedAtOpen = false
        let h = WebChatHarness(store: store, defaults: prefs, openConversation: { id in
            opened.append(id); linkedAtOpen = store.chat.first { $0.id == id }?.isConversationLink == true
        }); defer { h.close() }
        try await h.wait("document.querySelector('[aria-label=\"새 창에서 대화\"]') !== null")
        _ = try await h.js("(()=>{document.querySelector('[aria-label=\"새 창에서 대화\"]').click();return true;})()")
        try await h.wait("document.querySelector('.conversation-card') !== null")
        // Linking goes through the native open callback, which expands the canvas in place.
        #expect(opened == [source.id])
        #expect(linkedAtOpen)
        #expect(store.chat.count == 1)
        #expect(store.submittedDrafts.isEmpty)
    }
    @Test func messageConversationKeepsLongTranscriptAnchorWhileRepliesArrive() async throws {
        let (suite, prefs) = try preferences(); defer { prefs.removePersistentDomain(forName: suite) }
        let store = ChangingCardsStore()
        var source = ChatItem(at: .now, kind: .user("이 주제로 이야기하기")); source.isConversationLink = true
        let history = (0..<50).map { ChatItem(at: .now, kind: .stallari("기존 대화 \($0) " + String(repeating: "읽던 위치를 유지합니다. ", count: 20), project: nil)) }
        store.chat = Array(history.prefix(25)) + [source] + Array(history.suffix(25))
        let h = WebChatHarness(store: store, defaults: prefs, target: source.id); defer { h.close() }
        try await h.wait("document.querySelector('.conversation-card') !== null && document.querySelector('.viewport').scrollTop > 100")
        try await Task.sleep(for: .milliseconds(150))
        let conversation = WebChatHarness(store: store, defaults: prefs, conversationRootID: source.id)
        defer { conversation.close() }
        _ = try await h.js("(()=>{window.originalScroll=document.querySelector('.viewport').scrollTop;return true;})()")
        var reply = ChatItem(at: .now, kind: .stallari("별도 창에만 도착한 답변", project: nil)); reply.conversationRootID = source.id
        store.chat.append(reply)
        try await conversation.wait("document.body.textContent.includes('별도 창에만 도착한 답변')")
        #expect(try await h.js("!document.body.textContent.includes('별도 창에만 도착한 답변')") == "true")
        #expect(try await h.js("document.querySelector('.message-conversation') === null") == "true")
        #expect(try await h.js("Math.abs(document.querySelector('.viewport').scrollTop-window.originalScroll)<2") == "true")
    }
    @Test func conversationViewportStateDoesNotOverwriteMainOrOtherRoots() async throws {
        let (suite, prefs) = try preferences(); defer { prefs.removePersistentDomain(forName: suite) }
        let store = ChangingCardsStore()
        var source = ChatItem(at: .now, kind: .user("첫 번째 주제")); source.isConversationLink = true
        var other = ChatItem(at: .now, kind: .user("두 번째 주제")); other.isConversationLink = true
        let history = (0..<60).map { ChatItem(at: .now, kind: .stallari("메인 \($0) " + String(repeating: "읽던 위치입니다. ", count: 20), project: nil)) }
        let replies = (0..<60).map { index -> ChatItem in
            var item = ChatItem(at: .now, kind: .stallari("답장 \(index) " + String(repeating: "창의 읽던 위치입니다. ", count: 20), project: nil))
            item.conversationRootID = source.id; return item
        }
        store.chat = [source, other] + history + replies
        let main = WebChatHarness(store: store, defaults: prefs); defer { main.close() }
        try await main.wait("document.querySelectorAll('[data-message]').length > 0")
        _ = try await main.js("(()=>{const e=document.querySelector('.viewport');e.dispatchEvent(new WheelEvent('wheel',{bubbles:true,deltaY:-1}));e.scrollTop=1800;e.dispatchEvent(new Event('scroll'));return true;})()")
        try await Task.sleep(for: .milliseconds(300))
        let states = ChatWebStateStore(preferences: prefs)
        let viewport = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        let mainState = states.load(thread: store.selectedThreadID, message: viewport)
        #expect(mainState["following"]?.bool == false)
        let conversation = WebChatHarness(store: store, defaults: prefs, conversationRootID: source.id)
        defer { conversation.close() }
        try await conversation.wait("document.querySelectorAll('[data-message]').length > 0")
        _ = try await conversation.js("(()=>{const e=document.querySelector('.viewport');e.dispatchEvent(new WheelEvent('wheel',{bubbles:true,deltaY:-1}));e.scrollTop=3000;e.dispatchEvent(new Event('scroll'));return true;})()")
        try await Task.sleep(for: .milliseconds(300))
        let scopedThread = store.selectedThreadID + ":conversation:" + source.id.uuidString
        let conversationState = states.load(thread: scopedThread, message: viewport)
        #expect(conversationState["following"]?.bool == false)
        #expect(states.load(thread: store.selectedThreadID, message: viewport) == mainState)
        #expect(states.load(thread: store.selectedThreadID + ":conversation:" + other.id.uuidString, message: viewport) == .object([:]))
        conversation.close()
        let reopened = WebChatHarness(store: store, defaults: prefs, conversationRootID: source.id)
        defer { reopened.close() }
        try await reopened.wait("document.querySelector('.viewport').scrollTop > 100")
        #expect(try await reopened.js("(()=>{const e=document.querySelector('.viewport');return e.scrollHeight-e.scrollTop-e.clientHeight>500;})()") == "true")
    }
    @Test func failedQuestionReplyKeepsDraftAndAllowsRetryAndCancel() async throws {
        let (suite, prefs) = try preferences(); defer { prefs.removePersistentDomain(forName: suite) }
        let store = ChangingCardsStore()
        let q = Question(id: "retry", issue: "above", run: "r", asker: "Hird", prompt: "진행할까요?", options: ["예"], askedAt: .now)
        store.questions = [q]; store.chat = [.init(at: .now, kind: .question(q.id))]; store.failQuestionReply = true
        let h = WebChatHarness(store: store, defaults: prefs); defer { h.close() }
        try await h.wait("document.querySelector('.question') !== null")
        #expect(try await h.js("document.querySelector('.question .meta').textContent.includes('합성 작업 above')") == "true")
        _ = try await h.js("(()=>{document.querySelector('.choices button').click();return true;})()")
        _ = try await h.js("(()=>{document.querySelector('.question .primary').click();return true;})()")
        try await h.wait("document.querySelector('.question [role=status]')?.textContent.includes('전송 실패') && !document.querySelector('.question fieldset').disabled")
        #expect(store.questionAttempts == 1)
        #expect(try await h.js("document.querySelector('.choices button').getAttribute('aria-pressed')") == "\"true\"")
        _ = try await h.js("(()=>{[...document.querySelectorAll('.question button')].find(e=>e.textContent==='질문 닫기').click();return true;})()")
        try await Task.sleep(for: .milliseconds(100))
        #expect(store.questionAttempts == 2)
        store.failQuestionReply = false
        _ = try await h.js("(()=>{document.querySelector('.question .primary').click();return true;})()")
        try await h.wait("document.querySelector('.question fieldset') === null")
        #expect(store.questionAttempts == 3)
        #expect(!store.questions[0].isPending)
    }
    @Test func actualWebViewRendersMarkdownAndLiveStoreChanges() async throws {
        let (suite, prefs) = try preferences(); defer { prefs.removePersistentDomain(forName: suite) }
        let store = ChangingCardsStore()
        let item = ChatItem(at: .now, kind: .stallari("# 확인 결과\n\n**한글 문장**과 표입니다.\n\n| 항목 | 상태 |\n| --- | --- |\n| 렌더링 | 확인 |\n\n```swift\nlet value = 42\n```\n\n> [!RESULT] 결과\n> 동작을 확인합니다.", project: nil))
        store.chat = [item]
        let h = WebChatHarness(store: store, defaults: prefs); defer { h.close() }
        try await h.wait("document.querySelector('table') !== null")
        #expect(try await h.js("document.querySelector('strong').textContent") == "\"한글 문장\"")
        #expect(try await h.js("document.querySelector('code').textContent.includes('42')") == "true")
        store.chat[0].kind = .stallari("# 갱신된 답변\n\n새 토큰이 도착했습니다.", project: nil)
        try await h.wait("document.body.textContent.includes('새 토큰이 도착했습니다.')")
        #expect(try await h.js("document.querySelectorAll('[data-message]').length") == "1")
    }
    @Test func openUIComputesAndRestoresUserStateAcrossWebViewRecreation() async throws {
        let (suite, prefs) = try preferences(); defer { prefs.removePersistentDomain(forName: suite) }
        let store = ChangingCardsStore()
        let source = """
        작업 시간을 바꾸면 주간 합계가 계산됩니다.

        ```openui
        root = Stack([Heading("작업 시간 계산"), Slider($hours, "하루 작업 시간", 1, 12, 1), Metric("주간 작업 시간", $hours * 5, "시간")])
        $hours = 4
        ```
        """
        let message = ChatItem(at: .now, kind: .stallari(source, project: nil)); store.chat = [message]
        let h = WebChatHarness(store: store, defaults: prefs)
        defer { h.close() }
        try await h.wait("document.querySelector('input[type=range]') !== null")
        #expect(try await h.js("document.querySelector('.metric strong').textContent") == "\"20시간\"")
        _ = try await h.js("(()=>{const e=document.querySelector('input[type=range]');Object.getOwnPropertyDescriptor(HTMLInputElement.prototype,'value').set.call(e,'7');e.dispatchEvent(new Event('input',{bubbles:true}));e.dispatchEvent(new Event('change',{bubbles:true}));return true;})()")
        try await h.wait("document.querySelector('.metric strong').textContent === '35시간'")
        try await h.screenshot("chat-openui-light")
        try await Task.sleep(for: .milliseconds(150))
        h.close()
        let second = WebChatHarness(store: store, defaults: prefs, dark: true); defer { second.close() }
        try await second.wait("document.querySelector('.metric strong')?.textContent === '35시간'")
        #expect(try await second.js("document.querySelector('input[type=range]').value") == "\"7\"")
        try await second.screenshot("chat-openui-dark")
    }
    @Test func questionInputSurvivesUpdatesAndProposalUsesReviewedVersion() async throws {
        let (suite, prefs) = try preferences(); defer { prefs.removePersistentDomain(forName: suite) }
        let store = ChangingCardsStore()
        var issue = ChangingCardsStore.card("proposal"); issue.state = .awaitingApproval; issue.hirds = []
        issue.proposal = .init(version: 3, instruction: "채팅 화면 이전", model: "test-model")
        store.issues = [issue]
        store.questions = [Question(id: "q", issue: issue.id, run: "r", asker: "Hird", prompt: "선택해 주세요", options: ["하나", "둘"], askedAt: .now)]
        let q = ChatItem(at: .now, kind: .question("q")), p = ChatItem(at: .now, kind: .proposal(issue.id, version: 3))
        store.chat = [q, p]
        let h = WebChatHarness(store: store, defaults: prefs); defer { h.close() }
        try await h.wait("document.querySelector('.question input') !== null")
        _ = try await h.js("(()=>{const e=document.querySelector('.question input');Object.getOwnPropertyDescriptor(HTMLInputElement.prototype,'value').set.call(e,'작성 중인 답변');e.dispatchEvent(new Event('input',{bubbles:true}));return true;})()")
        store.chat.append(.init(at: .now, kind: .stallari("새 답변", project: nil)))
        try await h.wait("document.body.textContent.includes('새 답변')")
        #expect(try await h.js("document.querySelector('.question input').value") == "\"작성 중인 답변\"")
        _ = try await h.js("(()=>{const b=[...document.querySelectorAll('.proposal button')].find(e=>e.textContent==='승인');b.click();b.click();return true;})()")
        try await Task.sleep(for: .milliseconds(300))
        #expect(store.performed.count == 1)
        #expect(store.performed.first?.0 == .approveProposal(version: 3))
    }
    @Test func longTranscriptVirtualizesAndKeepsReaderDuringUpdateAndResize() async throws {
        let (suite, prefs) = try preferences(); defer { prefs.removePersistentDomain(forName: suite) }
        let store = ChangingCardsStore()
        store.chat = (0..<160).map { index in .init(at: .now, kind: .stallari("메시지 \(index)\n\n" + String(repeating: "길이가 바뀌는 한글 기록입니다. ", count: 25), project: nil)) }
        let h = WebChatHarness(store: store, defaults: prefs); defer { h.close() }
        try await h.wait("document.querySelectorAll('[data-message]').length > 0")
        #expect(Int(try await h.js("document.querySelectorAll('[data-message]').length"))! < 30)
        _ = try await h.js("(()=>{const e=document.querySelector('.viewport');e.dispatchEvent(new WheelEvent('wheel',{bubbles:true,deltaY:-1}));e.scrollTop=6000;e.dispatchEvent(new Event('scroll'));return true;})()")
        try await Task.sleep(for: .milliseconds(400))
        let anchor = try await h.js("[...document.querySelectorAll('[data-message]')].find(e=>e.getBoundingClientRect().bottom>0)?.dataset.message")
        store.chat[159].kind = .stallari(String(repeating: "뒤에서 생성 중인 응답 ", count: 200), project: nil)
        try await Task.sleep(for: .milliseconds(300))
        let after = try await h.js("[...document.querySelectorAll('[data-message]')].find(e=>e.getBoundingClientRect().bottom>0)?.dataset.message")
        #expect(after == anchor)
        h.window.setContentSize(NSSize(width: 600, height: 740))
        try await Task.sleep(for: .milliseconds(400))
        #expect(try await h.js("document.querySelector('.viewport').scrollTop > 1000") == "true")
        #expect(try await h.js("(()=>{const e=document.querySelector('.viewport');return e.scrollHeight-e.scrollTop-e.clientHeight>500;})()") == "true")
    }
    @Test(arguments: [false, true]) func inlineLocalImagesRenderAndOpenInQuickLook(dark: Bool) async throws {
        let (suite, prefs) = try preferences(); defer { prefs.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("knarr-inline-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let shot = root.appendingPathComponent("shot.png")
        // A visible picture, so the screenshot evidence shows a real thumbnail rather than one pixel.
        try makePicture(at: shot)
        let width = 320
        let store = ChangingCardsStore()
        store.chat = [.init(at: .now, kind: .stallari("스크린샷입니다.\n\n![확인 화면](\(shot.path))\n\n![없는 파일](/nope/gone.png)\n\n![외부 그림](https://example.org/x.png)", project: nil))]
        var opened: [URL] = []
        let h = WebChatHarness(store: store, defaults: prefs, dark: dark, preview: { opened.append($0) })
        defer { h.close() }
        try await h.wait("document.querySelector('.inline-image img')?.naturalWidth === \(width)")
        // The page sees only the address Knarr minted; the file's own path never reaches it.
        #expect(try await h.js("document.querySelector('.inline-image img').getAttribute('src').startsWith('chat-image://image/')") == "true")
        #expect(try await h.js("!document.body.innerHTML.includes('knarr-inline-')") == "true")
        #expect(try await h.js("document.querySelector('.inline-image').title") == "\"확인 화면\"")
        #expect(try await h.js("document.querySelector('.inline-image img').getAttribute('alt')") == "\"확인 화면\"")
        // Paths Knarr refuses, and remote pictures, become a status line instead of loading anything.
        #expect(try await h.js("document.querySelectorAll('.markdown .image-status').length") == "2")
        #expect(try await h.js("document.querySelectorAll('img').length") == "1")
        _ = try await h.js("(()=>{document.querySelector('.inline-image').click();return true;})()")
        try await Task.sleep(for: .milliseconds(250))
        #expect(opened.count == 1)
        #expect(opened.first?.path == shot.standardizedFileURL.resolvingSymlinksInPath().path)
        try await h.screenshot(dark ? "chat-inline-image-dark" : "chat-inline-image-light")
    }

    @Test(arguments: [false, true]) func unavailableImagesShowWhyTheyAreMissing(dark: Bool) async throws {
        let (suite, prefs) = try preferences(); defer { prefs.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("knarr-status-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let shot = root.appendingPathComponent("shot.png")
        try makePicture(at: shot)
        let script = root.appendingPathComponent("run.sh")
        try Data("echo hi".utf8).write(to: script)
        let store = ChangingCardsStore()
        store.chat = [.init(at: .now, kind: .stallari("스크린샷입니다.\n\n![확인 화면](\(shot.path))\n\n![없는 파일](/nope/gone.png)\n\n![거부된 파일](\(script.path))\n\n![외부 그림](https://example.org/x.png)", project: nil))]
        let h = WebChatHarness(store: store, defaults: prefs, dark: dark, preview: { _ in })
        defer { h.close() }
        try await h.wait("document.querySelector('.inline-image img')?.naturalWidth === 320")
        // Text the reader can act on, not a bare alt fragment.
        #expect(try await h.js("[...document.querySelectorAll('.image-status')].length") == "3")
        #expect(try await h.js("[...document.querySelectorAll('.image-status')].filter(e=>e.textContent.includes('이미지를 찾을 수 없어요')).length") == "2")
        #expect(try await h.js("document.querySelectorAll('.image-status')[2].textContent.includes('외부 이미지는 표시하지 않아요')") == "true")
        // The alt still names which picture is missing, and nothing remote is fetched.
        #expect(try await h.js("document.querySelectorAll('.image-status')[0].textContent.includes('없는 파일')") == "true")
        #expect(try await h.js("document.querySelectorAll('.image-status')[2].textContent.includes('외부 그림')") == "true")
        #expect(try await h.js("document.querySelectorAll('img').length") == "1")
        #expect(try await h.js("[...document.querySelectorAll('.image-status')].every(e=>!e.querySelector('img'))") == "true")
        // A picture that disappears after it was served flips to the same status instead of a broken icon.
        try FileManager.default.removeItem(at: shot)
        _ = try await h.js("(()=>{const i=document.querySelector('.inline-image img');i.src=i.src+'?retry=1';return true;})()")
        try await h.wait("document.querySelectorAll('.image-status').length === 4")
        #expect(try await h.js("document.querySelector('.inline-image')") == "null")
        try await h.screenshot(dark ? "chat-inline-status-dark" : "chat-inline-status-light")
    }

    @Test func smallConversationWindowServesItsOwnImages() async throws {
        let (suite, prefs) = try preferences(); defer { prefs.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("knarr-inline-window-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let shot = root.appendingPathComponent("shot.png")
        try makePicture(at: shot)
        let store = ChangingCardsStore()
        var source = ChatItem(at: .now, kind: .user("이 주제로 이야기")); source.isConversationLink = true
        var reply = ChatItem(at: .now, kind: .stallari("그림입니다.\n\n![창 화면](\(shot.path))", project: nil)); reply.conversationRootID = source.id
        store.chat = [source, reply]
        var opened: [URL] = []
        let h = WebChatHarness(store: store, defaults: prefs, conversationRootID: source.id, preview: { opened.append($0) })
        defer { h.close() }
        try await h.wait("document.querySelector('.inline-image img')?.naturalWidth === 320")
        #expect(try await h.js("document.querySelector('.inline-image').title") == "\"창 화면\"")
        _ = try await h.js("(()=>{document.querySelector('.inline-image').click();return true;})()")
        try await Task.sleep(for: .milliseconds(250))
        #expect(opened.map(\.path) == [shot.standardizedFileURL.resolvingSymlinksInPath().path])
        // The same inline picture in a message window, not only in the main transcript.
        try await h.screenshot("message-conversation-inline-image")
    }

    @Test func markdownCannotExecuteScriptsOrLoadRemoteFrames() async throws {
        let (suite, prefs) = try preferences(); defer { prefs.removePersistentDomain(forName: suite) }
        let store = ChangingCardsStore()
        store.chat = [.init(at: .now, kind: .stallari("<script>window.compromised=true</script>\n\n[위험](javascript:alert(1))\n\n<iframe src=\"https://example.org\"></iframe>", project: nil))]
        let h = WebChatHarness(store: store, defaults: prefs); defer { h.close() }
        try await h.wait("document.querySelector('[data-message]') !== null")
        #expect(try await h.js("window.compromised === undefined && document.querySelector('iframe') === null") == "true")
        #expect(try await h.js("document.querySelector('a[href^=javascript]') === null") == "true")
    }
    @Test func searchTargetMountsTheRequestedMessage() async throws {
        let (suite, prefs) = try preferences(); defer { prefs.removePersistentDomain(forName: suite) }
        let store = ChangingCardsStore()
        store.chat = (0..<100).map { .init(at: .now, kind: .user("검색 기록 \($0) · " + String(repeating: "내용 ", count: 30))) }
        let id = store.chat[53].id.uuidString
        let h = WebChatHarness(store: store, defaults: prefs, target: store.chat[53].id); defer { h.close() }
        try await h.wait("document.querySelector('[data-message=\"\(id)\"]') !== null")
        try await Task.sleep(for: .milliseconds(150))
        #expect(try await h.js("(()=>{const r=document.querySelector('[data-message=\"\(id)\"]').getBoundingClientRect();return r.bottom>0&&r.top<740;})()") == "true")
    }

    @Test func wideCodeScrollsIndependentlyAndFoldedCalloutReflowsRows() async throws {
        let (suite, prefs) = try preferences(); defer { prefs.removePersistentDomain(forName: suite) }
        let store = ChangingCardsStore()
        let text = "```text\n" + String(repeating: "가로로 긴 코드 ", count: 70) + "\n```\n\n> [!INFO]- 접힌 내용\n> " + String(repeating: "펼쳐진 설명입니다. ", count: 50)
        let first = ChatItem(at: .now, kind: .stallari(text, project: nil))
        let second = ChatItem(at: .now, kind: .user("다음 메시지")); store.chat = [first, second]
        let h = WebChatHarness(store: store, defaults: prefs); defer { h.close() }
        try await h.wait("document.querySelector('pre') !== null")
        #expect(try await h.js("document.querySelector('pre').scrollWidth > document.querySelector('pre').clientWidth") == "true")
        _ = try await h.js("(()=>{document.querySelector('pre').scrollLeft=180;return true;})()")
        #expect(try await h.js("document.querySelector('pre').scrollLeft > 100") == "true")
        _ = try await h.js("(()=>{document.querySelector('.callout-title').click();return true;})()")
        try await h.wait("document.querySelector('.callout-title').getAttribute('aria-expanded') === 'true'")
        try await Task.sleep(for: .milliseconds(100))
        #expect(try await h.js("(()=>{const a=document.querySelector('[data-message=\"\(first.id.uuidString)\"]').getBoundingClientRect();const b=document.querySelector('[data-message=\"\(second.id.uuidString)\"]').getBoundingClientRect();return b.top>=a.bottom-1;})()") == "true")
    }

    @Test func messageActionsNeverCoverTheBodyOrShiftIt() async throws {
        let (suite, prefs) = try preferences(); defer { prefs.removePersistentDomain(forName: suite) }
        let store = ChangingCardsStore()
        store.chat = [.init(at: .now, kind: .user("실행 모델은?")),
                      .init(at: .now, kind: .stallari("DeepSeek V4.1입니다.", project: nil))]
        let h = WebChatHarness(store: store, defaults: prefs); defer { h.close() }
        try await h.wait("document.querySelectorAll('[data-message]').length === 2 && document.querySelector('.message.assistant .message-actions') !== null")
        try await Task.sleep(for: .milliseconds(120))
        // Controls must stay clear of the text in every message, hovered or not.
        let noOverlap = """
        (()=>{const box=e=>e.getBoundingClientRect();
          const hit=(a,b)=>a.left<b.right-0.5&&b.left<a.right-0.5&&a.top<b.bottom-0.5&&b.top<a.bottom-0.5;
          return [...document.querySelectorAll('.message')].filter(m=>m.querySelector('.message-actions')).every(m=>{
            const body=m.querySelector('.bubble') ?? m.querySelector('.markdown'), strip=m.querySelector('.message-actions');
            return !hit(box(body),box(strip));});})()
        """
        let shapes = """
        [...document.querySelectorAll('.message')].map(m=>{
          const body=(m.querySelector('.bubble') ?? m.querySelector('.markdown')).getBoundingClientRect(), row=m.getBoundingClientRect();
          return [body.left,body.top,body.width,body.height,row.height].map(v=>Math.round(v*10)/10);})
        """
        #expect(try await h.js(noOverlap) == "true")
        #expect(try await h.js("getComputedStyle(document.querySelector('.message.user .message-actions')).opacity") == "\"0\"")
        #expect(try await h.js("getComputedStyle(document.querySelector('.message.assistant .message-actions')).opacity") == "\"0\"")
        let before = try await h.js(shapes)
        // The test window never becomes key, so real hover is unavailable; the copied state shows the
        // strip through the same rule that hover and focus use, so revealed geometry is comparable.
        _ = try await h.js("(()=>{document.querySelectorAll('.copy').forEach(e=>e.classList.add('copied'));return true;})()")
        try await h.wait("getComputedStyle(document.querySelector('.message.user .message-actions')).opacity === '1' && getComputedStyle(document.querySelector('.message.assistant .message-actions')).opacity === '1'")
        try await Task.sleep(for: .milliseconds(80))
        #expect(try await h.js(noOverlap) == "true")
        #expect(try await h.js(shapes) == before)
        #expect(try await h.js("(()=>{const s=document.querySelector('.message.user .message-actions').getBoundingClientRect(),b=document.querySelector('.message.user .bubble').getBoundingClientRect();return s.right<=b.left+0.5&&s.bottom<=b.bottom+0.5;})()") == "true")
        try await h.screenshot("message-actions-light")
        h.window.setContentSize(NSSize(width: 560, height: 640))
        try await Task.sleep(for: .milliseconds(200))
        #expect(try await h.js(noOverlap) == "true")
        #expect(try await h.js("document.querySelector('.message.user .message-actions').getBoundingClientRect().right <= document.querySelector('.message.user .bubble').getBoundingClientRect().left + 0.5") == "true")
        try await h.screenshot("message-actions-narrow")
    }

    @Test func scrollbarDragRemainsUserControlledAfterOneSecond() async throws {
        let (suite, prefs) = try preferences(); defer { prefs.removePersistentDomain(forName: suite) }
        let store = ChangingCardsStore()
        store.chat = (0..<80).map { .init(at: .now, kind: .user("드래그 기록 \($0) " + String(repeating: "내용 ", count: 30))) }
        let h = WebChatHarness(store: store, defaults: prefs); defer { h.close() }
        try await h.wait("document.querySelectorAll('[data-message]').length > 0")
        _ = try await h.js("(()=>{const v=document.querySelector('.viewport');v.dispatchEvent(new WheelEvent('wheel',{bubbles:true,deltaY:-1}));v.scrollTop=1000;v.dispatchEvent(new Event('scroll'));return true;})()")
        try await Task.sleep(for: .milliseconds(100))
        _ = try await h.js("(()=>{document.querySelector('.viewport').dispatchEvent(new PointerEvent('pointerdown',{bubbles:true}));return true;})()")
        try await Task.sleep(for: .milliseconds(1100))
        _ = try await h.js("(()=>{const v=document.querySelector('.viewport');v.scrollTop=3500;v.dispatchEvent(new Event('scroll'));return true;})()")
        try await Task.sleep(for: .milliseconds(100))
        let index = try #require(Int(try await h.js("+[...document.querySelectorAll('.virtual-row')].find(e=>e.getBoundingClientRect().top>=0).dataset.index")))
        let anchor = store.chat[index].id.uuidString
        let top = try await h.js("document.querySelector('[data-message=\"\(anchor)\"]').getBoundingClientRect().top")
        store.chat[index].kind = .user("드래그 중 본문 갱신 " + String(repeating: "추가 내용 ", count: 60))
        try await Task.sleep(for: .milliseconds(120))
        #expect(try await h.js("document.querySelector('[data-message=\"\(anchor)\"]').getBoundingClientRect().top") == top)
        #expect(try await h.js("document.querySelector('.viewport').scrollTop>2500") == "true")
        _ = try await h.js("(()=>{window.dispatchEvent(new PointerEvent('pointerup'));return true;})()")
    }

    @Test func streamingGeometryRemainsConsistentAcrossQuestionAndHistoryChanges() async throws {
        let (suite, prefs) = try preferences(); defer { prefs.removePersistentDomain(forName: suite) }
        let store = ChangingCardsStore()
        store.chat = (0..<18).map { .init(at: .now, kind: .user("기록 \($0) " + String(repeating: "긴 사용자 인용문입니다. ", count: 12))) }
        let q = Question(id: "geometry", issue: "above", run: "r", asker: "Hird", prompt: "확인할 내용을 골라 주세요", options: ["확인"], askedAt: .now)
        store.questions = [q]; store.chat.append(.init(at: .now, kind: .question(q.id)))
        let item = ChatItem(at: .now, kind: .stallari("시작", project: nil)); store.chat.append(item)
        store.streamingMessageID = item.id; store.isResponding = true
        let h = WebChatHarness(store: store, defaults: prefs); defer { h.close() }
        try await h.wait("document.body.textContent.includes('시작')")
        try await Task.sleep(for: .milliseconds(100))
        _ = try await h.js("""
        (()=>{window.__geometry=[];window.__phase='following';window.__sample=()=>{
          const v=document.querySelector('.viewport');
          const rows=[...document.querySelectorAll('.virtual-row')].map(e=>({index:+e.dataset.index,top:e.getBoundingClientRect().top,bottom:e.getBoundingClientRect().bottom,height:e.getBoundingClientRect().height,content:e.firstElementChild.getBoundingClientRect().height})).sort((a,b)=>a.index-b.index);
          window.__geometry.push({time:performance.now(),phase:window.__phase,offset:v.scrollTop,total:v.scrollHeight,height:v.clientHeight,rows});
        };window.__probe=setInterval(window.__sample,16);return true;})()
        """)
        var text = "시작"
        for i in 1...20 {
            text += "\n\n프레임_\(i)_끝\n\n" + String(repeating: "한글 스트리밍 본문입니다. ", count: i * 3) + "\n\n|항목|값|\n|---|---|\n|진행|\(i)|\n\n```swift\n" + (0..<i).map { "let value\($0) = \($0)" }.joined(separator: "\n") + "\n```"
            store.chat[store.chat.count - 1].kind = .stallari(text, project: nil)
            try await h.wait("document.body.textContent.includes('프레임_\(i)_끝')")
            _ = try await h.js("(()=>{window.__sample();return true;})()")
            #expect(try await h.js("(()=>{const v=document.querySelector('.viewport');return v.scrollHeight-v.scrollTop-v.clientHeight <= 2;})()") == "true")
            if i == 10 {
                store.questions[0].state = .answered(.init(selectedOptions: ["확인"], text: nil))
            }
        }
        store.streamingMessageID = nil; store.isResponding = false
        try await Task.sleep(for: .milliseconds(80))
        _ = try await h.js("(()=>{window.__phase='history';const v=document.querySelector('.viewport');v.dispatchEvent(new WheelEvent('wheel',{bubbles:true,deltaY:-1}));v.scrollTop=1000;v.dispatchEvent(new Event('scroll'));return true;})()")
        try await Task.sleep(for: .milliseconds(100))
        let anchor = try await h.js("[...document.querySelectorAll('[data-message]')].find(e=>e.getBoundingClientRect().bottom>0)?.dataset.message")
        let before = try await h.js("document.querySelector('.viewport').scrollTop")
        for i in 21...25 {
            store.chat[store.chat.count - 1].kind = .stallari(text + String(repeating: "뒤쪽 응답 증가 ", count: i * 10), project: nil)
            try await Task.sleep(for: .milliseconds(40))
        }
        #expect(try await h.js("document.querySelector('.viewport').scrollTop") == before)
        #expect(try await h.js("[...document.querySelectorAll('[data-message]')].find(e=>e.getBoundingClientRect().bottom>0)?.dataset.message") == anchor)
        _ = try await h.js("(()=>{window.__sample();clearInterval(window.__probe);return true;})()")
        let raw = try await h.js("window.__geometry")
        let data = Data(raw.utf8)
        let samples = try #require(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        #expect(samples.count > 20)
        var overlap = 0.0, gap = 0.0
        for sample in samples {
            let rows = sample["rows"] as? [[String: Double]] ?? []
            for row in rows { overlap = max(overlap, (row["content"] ?? 0) - (row["height"] ?? 0)) }
            for pair in zip(rows, rows.dropFirst()) where pair.1["index"] == (pair.0["index"] ?? -2) + 1 {
                let distance = (pair.1["top"] ?? 0) - (pair.0["bottom"] ?? 0)
                overlap = max(overlap, -distance); gap = max(gap, distance)
            }
        }
        #expect(overlap <= 2, "DOM row overlap: \(overlap)")
        #expect(gap <= 2, "DOM row gap: \(gap)")
        if let directory = ProcessInfo.processInfo.environment["KNARR_WEB_EVIDENCE"] {
            let root = URL(fileURLWithPath: directory); try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try data.write(to: root.appendingPathComponent("stream-frames.json"))
            try JSONSerialization.data(withJSONObject: ["samples":samples.count,"maxOverlap":overlap,"maxGap":gap,"policy":"periodic and per-update DOM observations with timestamps; WebKit may throttle timers; not hardware compositor frames"], options: [.sortedKeys]).write(to: root.appendingPathComponent("stream-summary.json"))
        }
    }

    @Test func correctedUIProgramDoesNotReuseValuesFromDifferentSource() async throws {
        let (suite, prefs) = try preferences(); defer { prefs.removePersistentDomain(forName: suite) }
        let store = ChangingCardsStore()
        func program(_ value: Int) -> String { "```openui\nroot = Stack([Slider($n, \"값\", 1, 12, 1), Metric(\"결과\", $n * 5, \"시간\")])\n$n = \(value)\n```" }
        let item = ChatItem(at: .now, kind: .stallari(program(4), project: nil)); store.chat = [item]
        let h = WebChatHarness(store: store, defaults: prefs); defer { h.close() }
        try await h.wait("document.querySelector('.metric strong')?.textContent === '20시간'")
        _ = try await h.js("(()=>{const e=document.querySelector('input');Object.getOwnPropertyDescriptor(HTMLInputElement.prototype,'value').set.call(e,'7');e.dispatchEvent(new Event('input',{bubbles:true}));return true;})()")
        try await h.wait("document.querySelector('.metric strong')?.textContent === '35시간'")
        store.chat[0].kind = .stallari(program(9), project: nil)
        try await h.wait("document.querySelector('.metric strong')?.textContent === '45시간'")
    }

}
