import AppKit
import WebKit
import Testing
import KnarrCore
@testable import KnarrUI

/// Reading is a layout fact: the page reports only assistant rows whose visible area is actually
/// on screen. App activity is the store's decision, so re-activation re-reports the same rows.
@MainActor @Suite(.serialized, .enabled(if: KnarrUITests.enabled)) struct ThreadUnreadWebTests {
    private func preferences() throws -> (String, UserDefaults) {
        let suite = "knarr-web-unread-" + UUID().uuidString
        return (suite, try #require(UserDefaults(suiteName: suite)))
    }
    private func settle(_ deadline: TimeInterval = 8, _ check: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(deadline)
        while Date() < end {
            if check() { return true }
            try? await Task.sleep(for: .milliseconds(60))
        }
        return check()
    }

    /// A transcript with an old answer at the top and a new one at the bottom: the page starts
    /// following the newest answer, so only that answer is reported. Scrolling back to the old
    /// answer reports it later, which is what keeps an off-screen answer unread.
    @Test func onlyAnswersInsideTheViewportAreReported() async throws {
        let (suite, prefs) = try preferences()
        defer { prefs.removePersistentDomain(forName: suite) }
        let store = ChangingCardsStore()
        let old = ChatItem(at: .now.addingTimeInterval(-3_600), kind: .stallari("아주 오래전 답변", project: nil))
        let filler = (0..<70).map { ChatItem(at: .now.addingTimeInterval(-1_800 + Double($0)),
                                             kind: .user("이전 기록 \($0) " + String(repeating: "내용 ", count: 40))) }
        let new = ChatItem(at: .now, kind: .stallari("방금 도착한 답변", project: nil))
        store.chat = [old] + filler + [new]
        let harness = WebChatHarness(store: store, defaults: prefs)
        defer { harness.close() }
        try await harness.wait("document.querySelectorAll('[data-message]').length > 0")

        #expect(await settle { store.markedRead.contains { $0.ids.contains(new.id) } },
                "The answer at the bottom of the followed transcript was never reported")
        #expect(!store.markedRead.contains { $0.ids.contains(old.id) },
                "An answer scrolled out of view was reported as read")
        #expect(store.markedRead.allSatisfy { $0.thread == store.selectedThreadID })

        // Visiting the old answer makes it visible, so it may be reported then.
        _ = try await harness.js("""
        (()=>{const v=document.querySelector('.viewport');v.dispatchEvent(new WheelEvent('wheel',{bubbles:true,deltaY:-1}));
        v.scrollTop=0;v.dispatchEvent(new Event('scroll'));return true;})()
        """)
        #expect(await settle { store.markedRead.contains { $0.ids.contains(old.id) } },
                "An answer the person scrolled to was never reported")
    }

    /// A focused conversation's answers belong to its own canvas, never to the tab the person is
    /// reading, so the page never reports them as tab reads.
    @Test func focusedConversationAnswersAreNeverReported() async throws {
        let (suite, prefs) = try preferences()
        defer { prefs.removePersistentDomain(forName: suite) }
        let store = ChangingCardsStore()
        var root = ChatItem(at: .now.addingTimeInterval(-60), kind: .user("집중 대화 시작"))
        root.isConversationLink = true
        var answer = ChatItem(at: .now, kind: .stallari("집중 대화 안의 답변", project: nil))
        answer.conversationRootID = root.id
        store.chat = [root, answer]
        let harness = WebChatHarness(store: store, defaults: prefs, conversationRootID: root.id)
        defer { harness.close() }
        try await harness.wait("document.body.textContent.includes('집중 대화 안의 답변')")
        try await Task.sleep(for: .milliseconds(600))
        #expect(!store.markedRead.contains { $0.ids.contains(answer.id) },
                "A focused conversation reported its answer as a tab read")
        _ = try await harness.js("window.knarr.recheckVisibility?.() ?? true")
        try await Task.sleep(for: .milliseconds(300))
        #expect(store.markedRead.isEmpty)
    }

    /// Becoming active again must re-post the rows already on screen: the store ignored them while
    /// the app was inactive, so the page's last batch cannot stand in for this report.
    @Test func activationRepostsTheSameVisibleAnswer() async throws {
        let (suite, prefs) = try preferences()
        defer { prefs.removePersistentDomain(forName: suite) }
        let store = ChangingCardsStore()
        let answer = ChatItem(at: .now, kind: .stallari("돌아왔을 때 보이는 답변", project: nil))
        store.chat = [.init(at: .now.addingTimeInterval(-60), kind: .user("질문")), answer]
        let harness = WebChatHarness(store: store, defaults: prefs)
        defer { harness.close() }
        #expect(await settle { !store.markedRead.isEmpty }, "The visible answer was never reported")
        store.markedRead.removeAll()

        // The real path: the store advances its activation revision, the view re-renders, and the
        // page is asked to report again. Nothing in the payload or transcript changed.
        store.setAppActive(false)
        store.setAppActive(true)
        #expect(await settle { store.markedRead.contains { $0.ids.contains(answer.id) } },
                "Re-activation did not re-report the answer that is still on screen")
    }
}
