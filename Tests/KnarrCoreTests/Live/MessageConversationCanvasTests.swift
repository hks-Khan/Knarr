import AppKit
import SwiftUI
import WebKit
import Testing
import KnarrCore
@testable import KnarrUI

/// Hosts the transcript exactly as `ConversationView` wires it: a link click asks the native side
/// for a canvas request, and only the canvas header asks for a separate window.
@MainActor private struct CanvasHost: View {
    let store: any KnarrStore
    let openWindow: (UUID) -> Void
    var initialRequest: MessageConversationCanvasRequest?
    @State private var request: MessageConversationCanvasRequest?
    var body: some View {
        ChatWebView(store: store, highlighted: nil, following: true, jumpToLatest: false, target: nil,
            open: { _ in }, restore: { _ in }, preview: { _ in }, followingChanged: { _ in }, targetReached: {},
            openConversation: { request = .init(root: $0, token: UUID()) },
            openConversationWindow: openWindow,
            canvasRequest: request ?? initialRequest)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

@MainActor private final class CanvasHarness {
    let window: NSWindow
    let store: any KnarrStore
    let preferences: UserDefaults
    init(store: any KnarrStore, preferences: UserDefaults, width: CGFloat = 900, height: CGFloat = 780,
         openWindow: @escaping (UUID) -> Void = { _ in }, initialRequest: MessageConversationCanvasRequest? = nil) {
        self.store = store; self.preferences = preferences
        window = TestWindow.make(size: NSSize(width: width, height: height))
        window.contentView = NSHostingView(rootView: CanvasHost(store: store, openWindow: openWindow, initialRequest: initialRequest)
            .defaultAppStorage(preferences)
            .environment(\.chatWebPreferences, preferences)
            .environment(\.chatWebPasteboard, NSPasteboard(name: NSPasteboard.Name("knarr-canvas-test-" + UUID().uuidString))))
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
        Testing.Issue.record("WebView condition timed out: \(expression)")
        throw CocoaError(.coderReadCorrupt)
    }
    func close() { window.contentView = nil; window.close() }
}

@MainActor private final class CanvasGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var entered = false
    func wait() async {
        entered = true
        await withCheckedContinuation { continuation = $0 }
    }
    func open() { continuation?.resume(); continuation = nil }
}

@MainActor @Suite(.serialized, .enabled(if: KnarrUITests.enabled)) struct MessageConversationCanvasTests {
    private func preferences() throws -> (String, UserDefaults) {
        let suite = "knarr-canvas-" + UUID().uuidString
        return (suite, try #require(UserDefaults(suiteName: suite)))
    }
    private func link(_ text: String) -> ChatItem {
        var item = ChatItem(at: .now, kind: .user(text)); item.isConversationLink = true
        return item
    }
    private func focused(_ text: String, root: UUID, assistant: Bool = true) -> ChatItem {
        var item = ChatItem(at: .now, kind: assistant ? .stallari(text, project: nil) : .user(text))
        item.conversationRootID = root
        return item
    }

    @Test func linkClickExpandsCanvasInPlaceAndKeepsMainReaderPosition() async throws {
        let (suite, prefs) = try preferences(); defer { prefs.removePersistentDomain(forName: suite) }
        let store = ChangingCardsStore()
        let source = link("이 주제로 따로 이야기하자")
        let history = (0..<12).map { ChatItem(at: .now, kind: .stallari("기존 기록 \($0) " + String(repeating: "읽던 위치를 지킵니다. ", count: 20), project: nil)) }
        var answer = focused("집중 대화의 답변입니다.", root: source.id)
        answer.conversationRootID = source.id
        store.chat = history + [source, answer]
        let h = CanvasHarness(store: store, preferences: prefs); defer { h.close() }
        try await h.wait("document.querySelector('.conversation-card') !== null")
        _ = try await h.js("(()=>{const e=document.querySelector('.viewport');e.dispatchEvent(new WheelEvent('wheel',{bubbles:true,deltaY:-1}));e.scrollTop=e.scrollHeight-e.clientHeight-320;e.dispatchEvent(new Event('scroll'));return true;})()")
        try await Task.sleep(for: .milliseconds(300))
        #expect(try await h.js("document.querySelector('.conversation-card') !== null") == "true")
        _ = try await h.js("(()=>{window.before=document.querySelector('.viewport').scrollTop;return true;})()")
        _ = try await h.js("(()=>{document.querySelector('.conversation-card button').click();return true;})()")
        try await h.wait("document.querySelector('.conversation-canvas') !== null")
        try await Task.sleep(for: .milliseconds(300))
        #expect(try await h.js("document.querySelector('.conversation-canvas').textContent.includes('집중 대화의 답변입니다.')") == "true")
        // The starting message is shown in full, once, at the top of the panel body.
        #expect(try await h.js("document.querySelector('.conversation-canvas').textContent.includes('이 주제로 따로 이야기하자')") == "true")
        #expect(try await h.js("[...document.querySelectorAll('.conversation-body [data-message]')].filter(e=>e.textContent.includes('이 주제로 따로 이야기하자')).length") == "1")
        // The collapsed card stays as the anchor row, marked as the one the panel shows.
        #expect(try await h.js("document.querySelector('.conversation-card').classList.contains('active') && document.querySelector('.conversation-card-open').getAttribute('aria-expanded') === 'true'") == "true")
        // Docking outside the scroller leaves the main reader exactly where it was.
        #expect(try await h.js("Math.abs(document.querySelector('.viewport').scrollTop-window.before)<2") == "true")
        #expect(try await h.js("['접기','새 창으로 열기','닫기'].every(l=>document.querySelector(`[aria-label=\"${l}\"]`))") == "true")
        #expect(try await h.js("document.querySelector('.conversation-header').getBoundingClientRect().height >= 24 && document.querySelector('.conversation-body').clientHeight > 120") == "true")
        #expect(try await h.js("(()=>{const c=document.querySelector('.conversation-canvas').getBoundingClientRect(),f=document.querySelector('.conversation-form').getBoundingClientRect();return f.bottom<=c.bottom+1 && f.top>c.top;})()") == "true")
        // Wide: the panel takes most of the message column, inset and centered, so its rounded edge shows.
        #expect(try await h.js("(()=>{const t=document.querySelector('.virtual-list').getBoundingClientRect(),c=document.querySelector('.conversation-canvas').getBoundingClientRect();const ratio=c.width/t.width;return ratio>0.86 && ratio<1 && (c.left-t.left)>8 && (t.right-c.right)>8 && Math.abs((c.left+c.right)/2-(t.left+t.right)/2)<2;})()") == "true")
        let height = Int(try await h.js("Math.round(document.querySelector('.conversation-canvas').getBoundingClientRect().height)")) ?? 0
        #expect(height >= 320 && height <= 640, "canvas height \(height)")
        // Closing restores the plain row and removes the panel.
        _ = try await h.js("(()=>{document.querySelector('[aria-label=닫기]').click();return true;})()")
        try await h.wait("document.querySelector('.conversation-canvas') === null")
        #expect(try await h.js("document.querySelector('.conversation-card.active') === null && document.querySelector('.conversation-card-open').getAttribute('aria-expanded') === 'false'") == "true")
        _ = try await h.js("(()=>{document.querySelector('.conversation-card button').click();return true;})()")
        try await h.wait("document.querySelector('.conversation-canvas') !== null")
        _ = try await h.js("(()=>{document.querySelector('[aria-label=접기]').click();return true;})()")
        try await h.wait("document.querySelector('.conversation-canvas') === null")
    }

    @Test func collapsedCardShowsRunningUnreadDoneAndClearsOnOpen() async throws {
        let (suite, prefs) = try preferences(); defer { prefs.removePersistentDomain(forName: suite) }
        let store = ChangingCardsStore()
        let source = link("지금 진행 상황 알려 줘")
        store.chat = [source, focused("첫 답변", root: source.id)]
        store.isResponding = true
        store.respondingRoots = [source.id]
        store.responseStatus = "생각 중"
        store.responseStartedAt = Date().addingTimeInterval(-12)
        let h = CanvasHarness(store: store, preferences: prefs); defer { h.close() }
        try await h.wait("document.querySelector('.conversation-card')?.textContent.includes('응답 중') === true")
        store.isResponding = false
        store.respondingRoots = []
        store.chat.append(focused("새로 도착한 답변", root: source.id))
        try await h.wait("document.querySelector('.conversation-card')?.textContent.includes('새 답변 1개') === true")
        _ = try await h.js("(()=>{document.querySelector('.conversation-card button').click();return true;})()")
        try await h.wait("document.querySelector('.conversation-canvas') !== null")
        store.isResponding = true
        store.respondingRoots = [source.id]
        store.responseStatus = "생각 중"
        store.responseStartedAt = Date().addingTimeInterval(-12)
        try await h.wait("document.querySelector('.conversation-canvas')?.textContent.includes('생각 중 · 12초') === true")
        _ = try await h.js("(()=>{document.querySelector('[aria-label=접기]').click();return true;})()")
        try await h.wait("document.querySelector('.conversation-card') !== null")
        try await Task.sleep(for: .milliseconds(200))
        let states = ChatWebStateStore(preferences: prefs)
        #expect((states.load(thread: store.selectedThreadID, message: source.id)["conversation-read-at"]?.integer ?? 0) > 0)
        store.isResponding = false
        store.respondingRoots = []
        try await h.wait("document.querySelector('.conversation-card')?.textContent.includes('답변 완료') === true")
        #expect(try await h.js("document.querySelector('.conversation-card').textContent.includes('새 답변')") == "false")
    }

    @Test func canvasKeepsBubbleColumnWidthInWideAndNarrowWindows() async throws {
        let (suite, prefs) = try preferences(); defer { prefs.removePersistentDomain(forName: suite) }
        let store = ChangingCardsStore()
        let source = link("폭 확인")
        store.chat = [ChatItem(at: .now, kind: .user("일반 말풍선")), source, focused("답변", root: source.id)]
        let h = CanvasHarness(store: store, preferences: prefs); defer { h.close() }
        try await h.wait("document.querySelector('.conversation-card') !== null")
        _ = try await h.js("(()=>{document.querySelector('.conversation-card button').click();return true;})()")
        try await h.wait("document.querySelector('.conversation-canvas') !== null")
        let matchesColumn = "(()=>{const t=document.querySelector('.virtual-list').getBoundingClientRect();const c=document.querySelector('.conversation-canvas').getBoundingClientRect();const ratio=c.width/t.width;return ratio>0.8 && ratio<1 && Math.abs((c.left+c.right)/2-(t.left+t.right)/2)<2 && c.left>=0 && c.right<=document.querySelector('.chat-shell').clientWidth;})()"
        #expect(try await h.js(matchesColumn) == "true")
        h.window.setContentSize(NSSize(width: 560, height: 780))
        try await Task.sleep(for: .milliseconds(600))
        #expect(try await h.js(matchesColumn) == "true")
        #expect(try await h.js("document.querySelector('.conversation-canvas').scrollWidth<=document.querySelector('.conversation-canvas').clientWidth+1") == "true")
        // The header keeps its controls on one line, and the reply field stays inside the panel.
        #expect(try await h.js("(()=>{const c=document.querySelector('.conversation-canvas').getBoundingClientRect(),h=document.querySelector('.conversation-header').getBoundingClientRect(),f=document.querySelector('.conversation-form').getBoundingClientRect();return h.height>=32 && h.height<=48 && h.width<=c.width+1 && f.bottom<=c.bottom+1 && f.top>=h.bottom && document.querySelector('.conversation-form textarea').clientWidth>40;})()") == "true")
        // A narrow window keeps the main conversation visible above the panel.
        #expect(try await h.js("document.querySelector('.conversation-dock').getBoundingClientRect().top > document.querySelector('.viewport').getBoundingClientRect().top + 80") == "true")
    }

    @Test func canvasReplyTargetsItsRootAndStopUsesNativeStop() async throws {
        let (suite, prefs) = try preferences(); defer { prefs.removePersistentDomain(forName: suite) }
        let store = ChangingCardsStore()
        let source = link("답장할 대화")
        store.chat = [source, focused("첫 답변", root: source.id)]
        let h = CanvasHarness(store: store, preferences: prefs); defer { h.close() }
        try await h.wait("document.querySelector('.conversation-card') !== null")
        _ = try await h.js("(()=>{document.querySelector('.conversation-card button').click();return true;})()")
        try await h.wait("document.querySelector('.conversation-canvas textarea') !== null")
        #expect(try await h.js("document.querySelector('.conversation-canvas textarea').placeholder") == "\"이 대화에 답장\"")
        _ = try await h.js("(()=>{const e=document.querySelector('.conversation-canvas textarea');Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype,'value').set.call(e,'이어서 물어볼게');e.dispatchEvent(new Event('input',{bubbles:true}));return true;})()")
        _ = try await h.js("(()=>{document.querySelector('.conversation-canvas [aria-label=\"보내기\"]').click();return true;})()")
        try await Task.sleep(for: .milliseconds(300))
        #expect(store.submittedDrafts.last?.text == "이어서 물어볼게")
        #expect(store.submittedDrafts.last?.conversationRootID == source.id)
        // A failed send must surface in the canvas instead of leaving the reply pending.
        store.failSubmit = true
        _ = try await h.js("(()=>{const e=document.querySelector('.conversation-canvas textarea');Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype,'value').set.call(e,'실패할 답장');e.dispatchEvent(new Event('input',{bubbles:true}));return true;})()")
        _ = try await h.js("(()=>{document.querySelector('.conversation-canvas [aria-label=\"보내기\"]').click();return true;})()")
        try await h.wait("document.querySelector('.conversation-error')?.textContent.includes('전송 실패') === true")
        store.failSubmit = false
        store.isResponding = true; store.respondingRoots = [source.id]; store.stoppableRoots = [source.id]
        store.responseStatus = "답변 작성 중"
        try await h.wait("document.querySelector('.conversation-canvas [aria-label=\"답변 중지\"]') !== null")
        _ = try await h.js("(()=>{document.querySelector('.conversation-canvas [aria-label=\"답변 중지\"]').click();return true;})()")
        try await Task.sleep(for: .milliseconds(200))
        #expect(store.stopCalls == 1)
        // A queue behind another answer hides the stop button instead of offering a no-op.
        store.stoppableRoots = []
        store.waitingRoots = [source.id]
        try await h.wait("document.querySelector('.conversation-canvas [aria-label=\"답변 중지\"]') === null")
        #expect(try await h.js("document.querySelector('.conversation-canvas [aria-label=\"보내기\"]').disabled") == "true")
        #expect(try await h.js("document.querySelector('.conversation-footer-status .conversation-status').textContent") == "\"답변 순서를 기다리는 중\"")
        #expect(store.stopCalls == 1)
    }

    @Test func unstoppableAnswerShowsItsReasonAndClearsWhenItCanStopOrFinishes() async throws {
        let (suite, prefs) = try preferences(); defer { prefs.removePersistentDomain(forName: suite) }
        let store = ChangingCardsStore()
        let source = link("이유를 보여 줄 대화")
        let other = link("대기 중인 다른 대화")
        store.chat = [source, focused("첫 답변", root: source.id), other, focused("다른 답변", root: other.id)]
        let h = CanvasHarness(store: store, preferences: prefs); defer { h.close() }
        try await h.wait("document.querySelector('.conversation-card') !== null")
        _ = try await h.js("(()=>{document.querySelector('.conversation-card button').click();return true;})()")
        try await h.wait("document.querySelector('.conversation-canvas') !== null")
        // Answering while another conversation's reply is queued: no stop button, and the canvas says why.
        store.isResponding = true; store.respondingRoots = [source.id, other.id]
        store.stoppableRoots = []; store.waitingRoots = [other.id]
        store.responseStatus = "답변 작성 중"
        try await h.wait("document.querySelector('.conversation-stop-reason') !== null")
        #expect(try await h.js("document.querySelector('.conversation-stop-reason').textContent") == "\"대기 중인 메시지가 있어 이 답변만 중지할 수 없어요\"")
        #expect(try await h.js("document.querySelector('.conversation-canvas [aria-label=\"답변 중지\"]') === null") == "true")
        // The reason shares the footer with the reply field, so it never squeezes the body.
        #expect(try await h.js("(()=>{const c=document.querySelector('.conversation-canvas').getBoundingClientRect(),h=document.querySelector('.conversation-header').getBoundingClientRect(),f=document.querySelector('.conversation-form').getBoundingClientRect(),r=document.querySelector('.conversation-stop-reason').getBoundingClientRect();return r.bottom<=f.bottom+1 && r.top>=f.top && r.top>=h.bottom && f.bottom<=c.bottom+1 && document.querySelector('.conversation-body').clientHeight>40;})()") == "true")
        h.window.setContentSize(NSSize(width: 560, height: 780))
        try await Task.sleep(for: .milliseconds(400))
        #expect(try await h.js("(()=>{const c=document.querySelector('.conversation-canvas'),r=document.querySelector('.conversation-stop-reason').getBoundingClientRect();return c.scrollWidth<=c.clientWidth+1 && r.right<=c.getBoundingClientRect().right+1 && document.querySelector('.conversation-form textarea').clientWidth>40;})()") == "true")
        // Alone again, the stop button returns and the reason is gone.
        store.waitingRoots = []
        store.stoppableRoots = [source.id]
        try await h.wait("document.querySelector('.conversation-stop-reason') === null && document.querySelector('.conversation-canvas [aria-label=\"답변 중지\"]') !== null")
        // Finished: the reason stays absent and the walkthrough text returns.
        store.isResponding = false; store.respondingRoots = []; store.stoppableRoots = []
        try await h.wait("document.querySelector('.conversation-stop-reason') === null && document.querySelector('.conversation-canvas [aria-label=\"보내기\"]') !== null")
    }

    @Test func closingKeepsTheResponseRunningAndTheLinkReopensIt() async throws {
        let (suite, prefs) = try preferences(); defer { prefs.removePersistentDomain(forName: suite) }
        let store = ChangingCardsStore()
        let source = link("닫아도 계속 답할 대화")
        store.chat = [source, focused("첫 답변", root: source.id)]
        store.isResponding = true; store.respondingRoots = [source.id]; store.stoppableRoots = [source.id]
        store.responseStatus = "답변 작성 중"; store.responseStartedAt = Date().addingTimeInterval(-5)
        let h = CanvasHarness(store: store, preferences: prefs); defer { h.close() }
        try await h.wait("document.querySelector('.conversation-card') !== null")
        _ = try await h.js("(()=>{document.querySelector('.conversation-card button').click();return true;})()")
        try await h.wait("document.querySelector('.conversation-canvas [aria-label=\"답변 중지\"]') !== null")
        _ = try await h.js("(()=>{document.querySelector('[aria-label=\"닫기\"]').click();return true;})()")
        try await h.wait("document.querySelector('.conversation-card') !== null")
        try await Task.sleep(for: .milliseconds(200))
        // Closing is not stopping: native was never asked to abort, and the root still answers.
        #expect(store.stopCalls == 0)
        #expect(store.respondingRoots.contains(source.id))
        store.chat.append(focused("닫힌 뒤 도착한 답변", root: source.id))
        try await h.wait("document.querySelector('.conversation-card')?.textContent.includes('응답 중') === true")
        _ = try await h.js("(()=>{document.querySelector('.conversation-card button').click();return true;})()")
        try await h.wait("document.querySelector('.conversation-canvas')?.textContent.includes('닫힌 뒤 도착한 답변') === true")
    }

    @Test func failedReplyKeepsItsDraftForRetry() async throws {
        let (suite, prefs) = try preferences(); defer { prefs.removePersistentDomain(forName: suite) }
        let store = ChangingCardsStore()
        let source = link("전송 실패를 확인할 대화")
        store.chat = [source, focused("첫 답변", root: source.id)]
        let h = CanvasHarness(store: store, preferences: prefs); defer { h.close() }
        try await h.wait("document.querySelector('.conversation-card') !== null")
        _ = try await h.js("(()=>{document.querySelector('.conversation-card button').click();return true;})()")
        try await h.wait("document.querySelector('.conversation-canvas textarea') !== null")
        store.failSubmit = true
        _ = try await h.js("(()=>{const e=document.querySelector('.conversation-canvas textarea');Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype,'value').set.call(e,'실패해도 남을 답장');e.dispatchEvent(new Event('input',{bubbles:true}));return true;})()")
        _ = try await h.js("(()=>{document.querySelector('.conversation-canvas [aria-label=\"보내기\"]').click();return true;})()")
        try await h.wait("document.querySelector('.conversation-error') !== null")
        #expect(try await h.js("document.querySelector('.conversation-canvas textarea').value") == "\"실패해도 남을 답장\"")
        // Retrying the kept draft sends it once the store accepts it.
        store.failSubmit = false
        _ = try await h.js("(()=>{document.querySelector('.conversation-canvas [aria-label=\"보내기\"]').click();return true;})()")
        try await Task.sleep(for: .milliseconds(300))
        #expect(store.submittedDrafts.last?.text == "실패해도 남을 답장")
        #expect(store.submittedDrafts.last?.conversationRootID == source.id)
    }

    @Test func innerScrollFollowsStreamingAndReleasesWhenTheReaderScrollsUp() async throws {
        let (suite, prefs) = try preferences(); defer { prefs.removePersistentDomain(forName: suite) }
        let store = ChangingCardsStore()
        let source = link("긴 답변 스크롤")
        let long = (0..<40).map { "문단 \($0) " + String(repeating: "긴 답변 본문입니다. ", count: 8) }.joined(separator: "\n\n")
        let answer = focused(long, root: source.id)
        store.chat = [source, answer]
        let h = CanvasHarness(store: store, preferences: prefs); defer { h.close() }
        try await h.wait("document.querySelector('.conversation-card') !== null")
        _ = try await h.js("(()=>{document.querySelector('.conversation-card button').click();return true;})()")
        try await h.wait("document.querySelector('.conversation-canvas') !== null")
        // A finished conversation opens at its beginning; scrolling to the end starts following.
        try await h.wait("(()=>{const b=document.querySelector('.conversation-body');return b.scrollHeight>b.clientHeight+40 && b.scrollTop===0;})()")
        // Wait for the replies to lay out, then take the reader to the live end.
        try await h.wait("(()=>{const b=document.querySelector('.conversation-body');return b.scrollHeight>b.clientHeight+40;})()")
        _ = try await h.js("(()=>{const b=document.querySelector('.conversation-body');b.dispatchEvent(new WheelEvent('wheel',{bubbles:true,deltaY:1}));b.scrollTop=b.scrollHeight;b.dispatchEvent(new Event('scroll'));return true;})()")
        try await h.wait("(()=>{const b=document.querySelector('.conversation-body');return b.scrollHeight-b.scrollTop-b.clientHeight<8;})()")
        _ = try await h.js("(()=>{window.mainBefore=document.querySelector('.viewport').scrollTop;return true;})()")
        store.chat[1].kind = .stallari(long + "\n\n바닥에서 도착한 문단", project: nil)
        try await h.wait("(()=>{const b=document.querySelector('.conversation-body');return b.textContent.includes('바닥에서 도착한 문단') && b.scrollHeight-b.scrollTop-b.clientHeight<8;})()")
        #expect(try await h.js("document.querySelector('.viewport').scrollTop") == (try await h.js("window.mainBefore")))
        _ = try await h.js("(()=>{const b=document.querySelector('.conversation-body');b.dispatchEvent(new WheelEvent('wheel',{bubbles:true,deltaY:-1}));b.scrollTop=40;b.dispatchEvent(new Event('scroll'));return true;})()")
        try await Task.sleep(for: .milliseconds(150))
        _ = try await h.js("(()=>{window.innerBefore=document.querySelector('.conversation-body').scrollTop;return true;})()")
        store.chat[1].kind = .stallari(long + "\n\n뒤에 도착한 문단 " + String(repeating: "추가 본문입니다. ", count: 30), project: nil)
        try await h.wait("document.querySelector('.conversation-body').textContent.includes('뒤에 도착한 문단') === true")
        #expect(try await h.js("document.querySelector('.conversation-body').scrollTop") == "40")
        #expect(try await h.js("document.querySelector('.viewport').scrollTop") == (try await h.js("window.mainBefore")))
        // Returning to the bottom resumes following, and the main reader still stays put.
        _ = try await h.js("(()=>{const b=document.querySelector('.conversation-body');b.scrollTop=b.scrollHeight;b.dispatchEvent(new Event('scroll'));return true;})()")
        try await Task.sleep(for: .milliseconds(100))
        store.chat[1].kind = .stallari(long + "\n\n돌아온 뒤 도착한 문단 " + String(repeating: "마지막 본문입니다. ", count: 20), project: nil)
        try await h.wait("(()=>{const b=document.querySelector('.conversation-body');return b.textContent.includes('돌아온 뒤 도착한 문단') && b.scrollHeight-b.scrollTop-b.clientHeight<8;})()")
        #expect(try await h.js("document.querySelector('.viewport').scrollTop") == (try await h.js("window.mainBefore")))
    }

    @Test func returningToTheSameBottomWithoutGrowthResumesFollowing() async throws {
        let (suite, prefs) = try preferences(); defer { prefs.removePersistentDomain(forName: suite) }
        let store = ChangingCardsStore()
        let source = link("같은 바닥으로 돌아오기")
        let long = (0..<40).map { "문단 \($0) " + String(repeating: "긴 답변 본문입니다. ", count: 8) }.joined(separator: "\n\n")
        store.chat = [source, focused(long, root: source.id)]
        let h = CanvasHarness(store: store, preferences: prefs); defer { h.close() }
        try await h.wait("document.querySelector('.conversation-card') !== null")
        _ = try await h.js("(()=>{document.querySelector('.conversation-card button').click();return true;})()")
        try await h.wait("document.querySelector('.conversation-canvas') !== null")
        // Wait for the replies to lay out, then take the reader to the live end.
        try await h.wait("(()=>{const b=document.querySelector('.conversation-body');return b.scrollHeight>b.clientHeight+40;})()")
        _ = try await h.js("(()=>{const b=document.querySelector('.conversation-body');b.dispatchEvent(new WheelEvent('wheel',{bubbles:true,deltaY:1}));b.scrollTop=b.scrollHeight;b.dispatchEvent(new Event('scroll'));return true;})()")
        try await h.wait("(()=>{const b=document.querySelector('.conversation-body');return b.scrollHeight-b.scrollTop-b.clientHeight<8;})()")
        // Wait for the pinned geometry to stop moving, so the recorded bottom is the settled one.
        try await h.wait("(()=>{const b=document.querySelector('.conversation-body');const same=b.scrollHeight===window.settledHeight;window.settledHeight=b.scrollHeight;return same && b.scrollHeight-b.scrollTop-b.clientHeight<8;})()")
        _ = try await h.js("(()=>{window.mainBefore=document.querySelector('.viewport').scrollTop;return true;})()")
        // The premise is a return with no height change, so record the bottom only once it is exact.
        try await h.wait("(()=>{const b=document.querySelector('.conversation-body');if (b.scrollTop !== b.scrollHeight-b.clientHeight) return false; window.pinned=b.scrollTop; window.pinnedBottom=b.scrollHeight-b.clientHeight; return true;})()")
        _ = try await h.js("(()=>{const b=document.querySelector('.conversation-body');b.dispatchEvent(new WheelEvent('wheel',{bubbles:true,deltaY:-1}));b.scrollTop=40;b.dispatchEvent(new Event('scroll'));return true;})()")
        // No text is added while reading, so the bottom coordinate must still be the recorded one.
        try await h.wait("(()=>{const b=document.querySelector('.conversation-body');return b.scrollTop === 40 && b.scrollHeight-b.clientHeight === window.pinnedBottom;})()")
        // Come back to that very coordinate without any new text, so the bottom value is unchanged.
        _ = try await h.js("(()=>{const b=document.querySelector('.conversation-body');b.scrollTop=window.pinned;b.dispatchEvent(new Event('scroll'));return b.scrollTop;})()")
        try await h.wait("(()=>{const b=document.querySelector('.conversation-body');return b.scrollTop === window.pinned && b.scrollHeight-b.scrollTop-b.clientHeight === 0;})()")
        // The next answer must be followed again from this same bottom.
        store.chat[1].kind = .stallari(long + "\n\n같은 바닥 뒤 도착한 문단 " + String(repeating: "따라가야 하는 본문입니다. ", count: 20), project: nil)
        try await h.wait("document.querySelector('.conversation-body').textContent.includes('같은 바닥 뒤 도착한 문단') === true")
        try await h.wait("(()=>{const b=document.querySelector('.conversation-body');return b.scrollHeight-b.scrollTop-b.clientHeight<8;})()")
        #expect(try await h.js("document.querySelector('.viewport').scrollTop") == (try await h.js("window.mainBefore")))
    }

    @Test func wheelIntentCancelsTheFrameOwedToTheBottom() async throws {
        let (suite, prefs) = try preferences(); defer { prefs.removePersistentDomain(forName: suite) }
        let store = ChangingCardsStore()
        let source = link("프레임 경계 스크롤")
        let long = (0..<30).map { "문단 \($0) " + String(repeating: "긴 답변 본문입니다. ", count: 8) }.joined(separator: "\n\n")
        store.chat = [source, focused(long, root: source.id)]
        let h = CanvasHarness(store: store, preferences: prefs); defer { h.close() }
        try await h.wait("document.querySelector('.conversation-card') !== null")
        _ = try await h.js("(()=>{document.querySelector('.conversation-card button').click();return true;})()")
        try await h.wait("document.querySelector('.conversation-canvas') !== null")
        // Wait for the replies to lay out, then take the reader to the live end.
        try await h.wait("(()=>{const b=document.querySelector('.conversation-body');return b.scrollHeight>b.clientHeight+40;})()")
        _ = try await h.js("(()=>{const b=document.querySelector('.conversation-body');b.dispatchEvent(new WheelEvent('wheel',{bubbles:true,deltaY:1}));b.scrollTop=b.scrollHeight;b.dispatchEvent(new Event('scroll'));return true;})()")
        try await h.wait("(()=>{const b=document.querySelector('.conversation-body');return b.scrollHeight-b.scrollTop-b.clientHeight<8;})()")
        // Hold frames so the frame this render owes can be delivered after a reader gesture.
        _ = try await h.js("(()=>{window.__frames=[];window.__raf=window.requestAnimationFrame;window.__caf=window.cancelAnimationFrame;window.requestAnimationFrame=(cb)=>{window.__frames.push(cb);return window.__frames.length;};window.cancelAnimationFrame=(id)=>{if(id)window.__frames[id-1]=null;};window.__flushFrames=()=>{const q=window.__frames;window.__frames=[];q.forEach(f=>f&&f(performance.now()));return q.length;};window.__pendingFrames=()=>window.__frames.length;return true;})()")
        // New text arrives while the canvas still follows, so a frame is owed to the bottom.
        store.chat[1].kind = .stallari(long + "\n\n## 새 문단\n\n- 목록 항목 하나\n- 목록 항목 둘", project: nil)
        try await h.wait("document.querySelector('.conversation-body').textContent.includes('목록 항목 둘') === true")
        try await h.wait("window.__pendingFrames() > 0")
        // An upward wheel is the reader taking over before scrollTop has moved yet.
        _ = try await h.js("(()=>{const b=document.querySelector('.conversation-body');b.dispatchEvent(new WheelEvent('wheel',{bubbles:true,deltaY:-120}));b.scrollTop=120;b.dispatchEvent(new Event('scroll'));return true;})()")
        _ = try await h.js("window.__flushFrames()")
        try await Task.sleep(for: .milliseconds(150))
        // The owed automatic scroll must not override the reader's position.
        #expect(try await h.js("document.querySelector('.conversation-body').scrollTop") == "120")
        _ = try await h.js("(()=>{window.requestAnimationFrame=window.__raf;window.cancelAnimationFrame=window.__caf;return true;})()")
    }

    @Test func canvasHeaderOpensTheExistingWindowWithoutTakingOverTheCanvas() async throws {
        let (suite, prefs) = try preferences(); defer { prefs.removePersistentDomain(forName: suite) }
        let store = ChangingCardsStore()
        let source = link("창으로도 열어야 하는 대화")
        store.chat = [source, focused("답변", root: source.id)]
        var opened: [UUID] = []
        let h = CanvasHarness(store: store, preferences: prefs, openWindow: { opened.append($0) }); defer { h.close() }
        try await h.wait("document.querySelector('.conversation-card') !== null")
        _ = try await h.js("(()=>{document.querySelector('.conversation-card button').click();return true;})()")
        try await h.wait("document.querySelector('.conversation-canvas [aria-label=\"새 창으로 열기\"]') !== null")
        _ = try await h.js("(()=>{document.querySelector('[aria-label=\"새 창으로 열기\"]').click();return true;})()")
        try await Task.sleep(for: .milliseconds(300))
        #expect(opened == [source.id])
        #expect(try await h.js("document.querySelector('.conversation-canvas') !== null") == "true")
    }

    @Test func lateCanvasSendResultDoesNotClearAStateFromAnotherThread() async throws {
        let (suite, prefs) = try preferences(); defer { prefs.removePersistentDomain(forName: suite) }
        let store = ChangingCardsStore()
        let source = link("스레드를 옮길 대화")
        store.chat = [source, focused("첫 답변", root: source.id)]
        let gate = CanvasGate()
        let h = CanvasHarness(store: store, preferences: prefs); defer { h.close() }
        try await h.wait("document.querySelector('.conversation-card') !== null")
        _ = try await h.js("(()=>{document.querySelector('.conversation-card button').click();return true;})()")
        try await h.wait("document.querySelector('.conversation-canvas textarea') !== null")
        store.failSubmit = true
        _ = try await h.js("(()=>{const e=document.querySelector('.conversation-canvas textarea');Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype,'value').set.call(e,'먼저 실패');e.dispatchEvent(new Event('input',{bubbles:true}));return true;})()")
        _ = try await h.js("(()=>{document.querySelector('.conversation-canvas [aria-label=\"보내기\"]').click();return true;})()")
        try await h.wait("document.querySelector('.conversation-error') !== null")
        // The retry is still in flight when the person moves to another thread.
        store.failSubmit = false
        store.whileSubmitting = { await gate.wait() }
        _ = try await h.js("(()=>{const e=document.querySelector('.conversation-canvas textarea');Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype,'value').set.call(e,'스레드를 넘긴 답장');e.dispatchEvent(new Event('input',{bubbles:true}));return true;})()")
        _ = try await h.js("(()=>{document.querySelector('.conversation-canvas [aria-label=\"보내기\"]').click();return true;})()")
        for _ in 0..<200 where !gate.entered { try await Task.sleep(for: .milliseconds(10)) }
        _ = try await h.js("(()=>{window.__lateResults=0;window.addEventListener('knarr-result',e=>{if(e.detail.message==='" + source.id.uuidString + "')window.__lateResults++;});return true;})()")
        store.createThread(name: "다른 스레드")
        try await Task.sleep(for: .milliseconds(200))
        gate.open()
        try await Task.sleep(for: .milliseconds(400))
        #expect(store.submittedDrafts.last?.text == "스레드를 넘긴 답장")
        // Its late success must not be reported into the thread the canvas now shows.
        #expect(try await h.js("window.__lateResults") == "0")
    }

    @Test func nativeStartConversationRequestOpensTheCanvasForThatRoot() async throws {
        let (suite, prefs) = try preferences(); defer { prefs.removePersistentDomain(forName: suite) }
        let store = ChangingCardsStore()
        let source = link("방금 시작한 대화")
        store.chat = [source, focused("첫 답변", root: source.id)]
        let request = MessageConversationCanvasRequest(root: source.id, token: UUID())
        let h = CanvasHarness(store: store, preferences: prefs, initialRequest: request); defer { h.close() }
        try await h.wait("document.querySelector('.conversation-canvas')?.textContent.includes('첫 답변') === true")
    }

    /// The panel is the whole exchange: the starting message once, then its replies, with the reply
    /// field and live status in one footer. The main composer keeps whatever its user was writing.
    @Test func panelShowsTheWholeExchangeWithItsOwnFooter() async throws {
        let (suite, prefs) = try preferences(); defer { prefs.removePersistentDomain(forName: suite) }
        let store = ChangingCardsStore()
        let question = String(repeating: "세션 탭 표시 규칙을 자세히 알려 줘. ", count: 14)
        let source = link(question)
        let replies = (0..<4).map { focused("답변 \($0) " + String(repeating: "본문입니다. ", count: 12), root: source.id) }
        store.chat = [source] + replies
        store.composerDraft.text = "메인에 쓰던 초안"
        let h = CanvasHarness(store: store, preferences: prefs); defer { h.close() }
        try await h.wait("document.querySelector('.conversation-card') !== null")
        _ = try await h.js("(()=>{document.querySelector('.conversation-card button').click();return true;})()")
        try await h.wait("document.querySelector('.conversation-canvas') !== null")
        try await h.wait("document.querySelectorAll('.conversation-body [data-message]').length === 5")
        // It opens at the beginning even while the conversation is answering.
        #expect(try await h.js("document.querySelector('.conversation-body').scrollTop") == "0")
        // The starting message is the first body row and appears exactly once.
        #expect(try await h.js("document.querySelector('.conversation-body [data-message] .bubble').textContent") == "\"\(question)\"")
        #expect(try await h.js("[...document.querySelectorAll('.conversation-body [data-message]')].filter(e=>e.querySelector('.bubble')?.textContent===\"\(question)\").length") == "1")
        // The full original is present, not a one-line preview.
        #expect(try await h.js("(()=>{const b=document.querySelector('.conversation-body [data-message] .bubble');const r=b.getBoundingClientRect(),s=getComputedStyle(b);return r.height>60 && s.whiteSpace==='pre-wrap';})()") == "true")
        // Replies follow below the start in order.
        #expect(try await h.js("(()=>{const rows=[...document.querySelectorAll('.conversation-body [data-message]')];return rows.slice(1).every((e,i)=>e.textContent.includes('답변 '+i+' ')) && rows[0].getBoundingClientRect().bottom<=rows[1].getBoundingClientRect().top+1;})()") == "true")
        // Header: a compact title line with all three controls, the close button last.
        #expect(try await h.js("(()=>{const h=document.querySelector('.conversation-header');const labels=[...h.querySelectorAll('button')].map(b=>b.getAttribute('aria-label'));return h.textContent.includes('집중 대화') && labels.join(',')==='접기,새 창으로 열기,닫기';})()") == "true")
        // Footer: the reply field sits last and keeps usable space; the status lives there too.
        #expect(try await h.js("(()=>{const f=document.querySelector('.conversation-form'),w=f.querySelector('textarea').getBoundingClientRect();return f.querySelector('.conversation-compose') && w.height>=28 && w.width>200;})()") == "true")
        // The main composer keeps the draft the user was writing.
        #expect(store.composerDraft.text == "메인에 쓰던 초안")
        // Reply from the panel without touching that draft.
        _ = try await h.js("(()=>{const e=document.querySelector('.conversation-canvas textarea');Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype,'value').set.call(e,'패널에서 답장');e.dispatchEvent(new Event('input',{bubbles:true}));return true;})()")
        _ = try await h.js("(()=>{document.querySelector('.conversation-canvas [aria-label=\"보내기\"]').click();return true;})()")
        try await Task.sleep(for: .milliseconds(300))
        #expect(store.submittedDrafts.last?.text == "패널에서 답장")
        #expect(store.submittedDrafts.last?.conversationRootID == source.id)
        #expect(store.composerDraft.text == "메인에 쓰던 초안")
    }

    /// A short window must still show the original message at the top of the panel, not a scrolled tail.
    @Test func shortWindowKeepsTheOriginalMessageAtThePanelTop() async throws {
        let (suite, prefs) = try preferences(); defer { prefs.removePersistentDomain(forName: suite) }
        let store = ChangingCardsStore()
        let source = link("짧은 창에서 시작 확인")
        let replies = (0..<6).map { focused("답변 \($0) " + String(repeating: "본문입니다. ", count: 10), root: source.id) }
        store.chat = [source] + replies
        store.isResponding = true; store.respondingRoots = [source.id]; store.stoppableRoots = [source.id]
        store.responseStatus = "생각 중"
        let h = CanvasHarness(store: store, preferences: prefs, width: 900, height: 700); defer { h.close() }
        try await h.wait("document.querySelector('.conversation-card') !== null")
        _ = try await h.js("(()=>{document.querySelector('.conversation-card button').click();return true;})()")
        try await h.wait("document.querySelector('.conversation-canvas') !== null")
        try await h.wait("document.querySelector('.conversation-body')?.scrollHeight > document.querySelector('.conversation-body').clientHeight + 40")
        // The panel opens on the original, even though this conversation is answering.
        #expect(try await h.js("(()=>{const b=document.querySelector('.conversation-body');const first=b.querySelector('[data-message] .bubble');const r=first.getBoundingClientRect(),c=b.getBoundingClientRect();return b.scrollTop===0 && r.top>=c.top-1 && r.bottom<=c.bottom+1;})()") == "true")
        // The main conversation keeps its own rows visible above the panel.
        #expect(try await h.js("document.querySelector('.viewport').getBoundingClientRect().height > 120") == "true")
        // Taking the reader to the bottom resumes following the live answer.
        _ = try await h.js("(()=>{const b=document.querySelector('.conversation-body');b.dispatchEvent(new WheelEvent('wheel',{bubbles:true,deltaY:1}));b.scrollTop=b.scrollHeight;b.dispatchEvent(new Event('scroll'));return true;})()")
        try await h.wait("(()=>{const b=document.querySelector('.conversation-body');return b.scrollHeight-b.scrollTop-b.clientHeight<8;})()")
    }
}
