import AppKit
import Testing
@testable import KnarrCore
@testable import KnarrUI

@MainActor @Suite(.serialized, .enabled(if: KnarrUITests.enabled)) struct ConversationProgressWebTests {
    @Test func progressGroupsCollapsePersistAndKeepFinalAnswerVisible() async throws {
        let suite = "knarr-progress-web-" + UUID().uuidString
        let prefs = try #require(UserDefaults(suiteName: suite))
        defer { prefs.removePersistentDomain(forName: suite) }
        let store = ChangingCardsStore()
        let start = Date.now.addingTimeInterval(-25)
        store.isResponding = true
        store.responseStatus = "파일 읽기 진행 중"
        store.responseStartedAt = start
        store.responseLastEventAt = start.addingTimeInterval(4)
        var thinking = ChatItem(at: start, kind: .stallari("기존 대화 화면의 수신 처리와 기록 저장을 확인하고 있습니다.", project: nil))
        thinking.activity = .init(kind: .reasoning, title: "추론 요약", state: .completed, updatedAt: start.addingTimeInterval(3))
        var tool = ChatItem(at: start.addingTimeInterval(4), kind: .stallari("Sources/KnarrCore/Live/LiveConversation.swift", project: nil))
        tool.activity = .init(kind: .tool, title: "파일 읽기", updatedAt: start.addingTimeInterval(5))
        store.chat = [thinking, .init(at: start.addingTimeInterval(3), kind: .stallari("진행 정보가 빠지는 위치를 확인하겠습니다.", project: nil)), tool]
        let h = WebChatHarness(store: store, defaults: prefs)
        defer { h.close() }
        h.window.setContentSize(NSSize(width: 800, height: 360))
        TestWindow.present(h.window)
        try await h.wait("document.querySelector('.progress-group summary')?.textContent.includes('파일 읽기')")
        #expect(try await h.js("document.querySelector('.progress-group details').open") == "false")
        #expect(try await h.js("document.querySelectorAll('.activity').length") == "0")
        try await h.screenshot("progress-collapsed-light")
        _ = try await h.js("(()=>{document.querySelector('.progress-group summary').click();return true;})()")
        try await h.wait("document.querySelectorAll('.activity').length === 2")
        #expect(try await h.js("document.querySelectorAll('.progress-record').length") == "3")
        #expect(try await h.js("document.querySelector('.activity-running').textContent.includes('진행 중')") == "true")
        #expect(try await h.js("document.querySelectorAll('.activity-time').length") == "2")
        #expect(try await h.js("document.body.textContent.includes('LiveConversation.swift')") == "false")
        #expect(try await h.js("document.querySelector('.response-slot').textContent.trim()") == "\"\"")
        try await h.screenshot("progress-expanded-light")
        tool.activity?.state = .failed; tool.activity?.updatedAt = .now
        store.chat[2] = tool
        try await h.wait("document.querySelector('.activity-failed')?.textContent.includes('실패')")
        #expect(try await h.js("document.querySelectorAll('.activity').length") == "2")
        store.isResponding = false
        store.chat.append(.init(at: .now, kind: .stallari("작업 결과를 확인했습니다.", project: nil)))
        try await h.wait("document.querySelector('.assistant')?.textContent.includes('작업 결과를 확인했습니다.')")
        // Disclosure state is saved through the existing native message-state store.
        try await Task.sleep(for: .milliseconds(150))
        h.close()
        let dark = WebChatHarness(store: store, defaults: prefs, dark: true)
        defer { dark.close() }
        dark.window.setContentSize(NSSize(width: 800, height: 360))
        TestWindow.present(dark.window)
        try await dark.wait("document.querySelector('.activity-failed') !== null")
        try await dark.screenshot("progress-expanded-dark")
        // Model-supplied progress is inert Markdown, never interactive assistant content.
        store.chat[0].kind = .stallari("```openui\nroot = Button(\"실행\")\n```", project: nil)
        try await dark.wait("document.querySelector('.activity code') !== null")
        #expect(try await dark.js("document.querySelectorAll('.activity .generated-ui').length") == "0")
        _ = try await dark.js("(()=>{document.querySelector('.progress-group summary').click();return true;})()")
        try await dark.wait("document.querySelectorAll('.activity').length === 0")
        #expect(try await dark.js("document.querySelector('.assistant').textContent.includes('작업 결과를 확인했습니다.')") == "true")
        store.chat = []
        store.responseStatus = "응답 준비 중"
        store.isResponding = true
        try await dark.wait("document.querySelector('.response-slot')?.textContent.includes('응답 준비 중')")
        #expect(try await dark.js("document.querySelector('.response-slot').textContent.includes('마지막 수신')") == "false")
    }
    @Test func searchingFoldedProgressRevealsTheMatchingRecord() async throws {
        let suite = "knarr-progress-search-" + UUID().uuidString
        let prefs = try #require(UserDefaults(suiteName: suite))
        defer { prefs.removePersistentDomain(forName: suite) }
        let store = ChangingCardsStore()
        let start = Date.now.addingTimeInterval(-120)
        let records = (0..<30).map { index -> ChatItem in
            var item = ChatItem(at: start.addingTimeInterval(Double(index)), kind: .stallari("진행 기록 \(index) · 파일과 검사 결과를 확인했습니다.", project: nil))
            item.activity = .init(kind: .reasoning, title: "추론 요약", state: .completed, updatedAt: start.addingTimeInterval(Double(index + 1)))
            return item
        }
        store.chat = [.init(at: start, kind: .user("진행 기록 확인"))] + records + [.init(at: .now, kind: .stallari("확인을 마쳤습니다.", project: nil))]
        let target = records[25].id
        let h = WebChatHarness(store: store, defaults: prefs, target: target)
        defer { h.close() }
        h.window.setContentSize(NSSize(width: 800, height: 400))
        try await h.wait("document.querySelector('.progress-group details')?.open === true")

        try await h.wait("(()=>{const e=document.querySelector('[data-message=\"\(target.uuidString)\"]');const v=document.querySelector('.viewport');if(!e||!v)return false;const r=e.getBoundingClientRect(),b=v.getBoundingClientRect();return r.top>=b.top&&r.bottom<=b.bottom;})()")
        #expect(try await h.js("document.querySelectorAll('.progress-group').length") == "1")
    }

}
