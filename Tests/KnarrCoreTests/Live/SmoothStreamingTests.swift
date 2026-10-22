import AppKit
import Testing
@testable import KnarrCore
@testable import KnarrUI

@MainActor @Suite(.serialized) struct SmoothStreamingTests {
    private func delta(_ text: String, id: String = "smooth-1") -> OMPJSON {
        .object(["type": .string("message_update"), "messageId": .string(id),
                 "message": .object(["role": .string("assistant")]),
                 "assistantMessageEvent": .object(["type": .string("text_delta"), "contentIndex": .number(0), "delta": .string(text)])])
    }
    private func end(_ text: String, id: String = "smooth-1") -> OMPJSON {
        .object(["type": .string("message_end"), "messageId": .string(id), "message": .object([
            "role": .string("assistant"), "content": .array([.object(["type": .string("text"), "text": .string(text)])])])])
    }

    @Test(.enabled(if: KnarrUITests.enabled)) func singleLargeDeltaReachesWebViewWithoutChangingStoredText() async throws {
        let f = try await LiveFixture.make()
        var harness: HomeHarness?
        do {
            f.store.send("표시와 저장을 구분해 주세요", about: nil)
            try await f.store.whenIdle()
            let h = HomeHarness(width: 1120, height: 780, store: f.store)
            harness = h
            TestWindow.present(h.window)
            await h.waitWeb()
            try await Task.sleep(for: .milliseconds(150))
            let hidden = await h.webJSON("document.hidden") as? Bool == true
            let text = "프레임 확인 " + String(repeating: "큰 덩어리도 조금씩 표시합니다. ", count: 30) + "끝"
            await f.store.observe(frame: delta(text))
            let id = try #require(f.store.streamingMessageID)
            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline {
                if let value = await h.webJSON("[...document.querySelectorAll('.assistant .markdown')].at(-1)?.textContent") as? String, !value.isEmpty { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            let first = try #require(await h.webJSON("[...document.querySelectorAll('.assistant .markdown')].at(-1)?.textContent") as? String)
            #expect(text.hasPrefix(first))
            if hidden { #expect(first == text) } else { #expect(first.count < text.count) }
            try await Task.sleep(for: .milliseconds(80))
            let second = try #require(await h.webJSON("[...document.querySelectorAll('.assistant .markdown')].at(-1)?.textContent") as? String)
            if hidden { #expect(second == text) } else { #expect(second.count > first.count) }
            #expect(text.hasPrefix(second))
            #expect(f.store.chat.first { $0.id == id }?.kind == .stallari(text, project: nil))
            #expect(try await f.repository.snapshot().chat.allSatisfy { $0.id != id })
            await f.store.observe(frame: end(text))
            try await Task.sleep(for: .milliseconds(80))
            #expect(await h.webJSON("[...document.querySelectorAll('.assistant .markdown')].at(-1)?.textContent") as? String == text)
            #expect(try await f.repository.snapshot().chat.first { $0.id == id }?.kind == .stallari(text, project: nil))
            #expect((await h.distanceFromBottom) < 23)
            h.close(); harness = nil
            try await f.cleanup()
        } catch {
            harness?.close()
            try await f.cleanup()
            throw error
        }
    }

    @Test func backlogSetsCatchUpSpeedAndUnicodeCharactersStayWhole() {
        let small = StreamingTextPresentation(), large = StreamingTextPresentation()
        let id = UUID()
        let unit = "한👨‍👩‍👧‍👦e\u{301}"
        small.receive(String(repeating: unit, count: 10), messageID: id)
        large.receive(String(repeating: unit, count: 100), messageID: id)
        small.advance(by: 1.0 / 60)
        large.advance(by: 1.0 / 60)
        #expect(large.visibleText.count > small.visibleText.count)
        #expect(large.receivedText.hasPrefix(large.visibleText))
        #expect(Array(large.visibleText) == Array(large.receivedText).prefix(large.visibleText.count).map { $0 })
        for _ in 0..<10 {
            small.advance(by: 1.0 / 60)
            large.advance(by: 1.0 / 60)
        }
        #expect(small.visibleText == small.receivedText)
        #expect(large.visibleText == large.receivedText)
        #expect(!large.hasPendingText)
    }

    @Test func completedMarkdownPromotesWithoutSplittingFencesOrReparsingEachFrame() {
        let p = StreamingTextPresentation(), id = UUID()
        let code = "문단\n\n```swift\nlet a = 1\n\nlet b = 2\n```\n\n"
        let text = code + "| 열 |\n| --- |\n| 값 |\n\n" + String(repeating: "마지막 문단 ", count: 80)
        p.receive(text, messageID: id)
        for _ in 0..<20 { p.advance(by: 1.0 / 60) }
        #expect(p.blocks.contains(.code(language: "swift", text: "let a = 1\n\nlet b = 2")))
        #expect(p.blocks.contains(.table(header: ["열"], alignments: [.leading], rows: [["값"]])))
        let blocks = p.blocks
        p.receive(text + "이어 쓰기", messageID: id)
        p.advance(by: 1.0 / 60)
        #expect(p.blocks == blocks)
        #expect(p.tail.hasPrefix("마지막 문단 "))
        p.finish()
        #expect(p.blocks == MarkdownBlocks.parse(text + "이어 쓰기"))
        #expect(p.tail.isEmpty)
        #expect(!p.hasPendingText)
    }

    @Test(arguments: ["message_end", "error", "aborted", "stop"])
    func terminalsRevealEverythingAndPreserveReceivedText(terminal: String) async throws {
        let f = try await LiveFixture.make()
        do {
            f.store.send("종료 경계", about: nil)
            try await f.store.whenIdle()
            let prompt = try #require(await f.rpc.promptIDs.last)
            let text = String(repeating: "종료 전 받은 전체 내용 👩🏽‍💻 ", count: 30) + "끝"
            await f.store.observe(frame: delta(text))
            let p = try #require(f.store.streamingPresentation)
            let id = try #require(f.store.streamingMessageID)
            p.advance(by: 1.0 / 60)
            #expect(p.visibleText != text)
            if terminal == "stop" {
                f.store.stopResponse()
                #expect(p.visibleText == text)
                try await f.store.whenIdle()
            } else if terminal == "message_end" {
                await f.store.observe(frame: end(text))
            } else {
                await f.store.observe(frame: .object(["type": .string("prompt_result"), "id": .string(prompt), "status": .string(terminal)]))
            }
            #expect(p.visibleText == text)
            #expect(!p.hasPendingText)
            #expect(try await f.repository.snapshot().chat.first { $0.id == id }?.kind == .stallari(text, project: nil))
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }

    @Test func threadSelectionFlushesWithoutEndingOrSavingTheResponse() async throws {
        let f = try await LiveFixture.make()
        let suite = "knarr-smooth-thread-\(UUID())"
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        f.store.setThreadFactory { thread in
            let rpc = LiveTestRPC()
            return LiveConversation(repository: f.repository,
                session: StallariSession(repository: f.repository, rpc: rpc, hird: f.hird, threadID: thread.id),
                rpc: rpc, hird: f.hird, threadID: thread.id, preferences: preferences)
        }
        do {
            await f.store.observe(frame: delta(String(repeating: "스레드 전환 전 내용 ", count: 50)))
            let p = try #require(f.store.streamingPresentation)
            let id = try #require(f.store.streamingMessageID)
            p.advance(by: 1.0 / 60)
            f.store.createThread(name: "다른 대화")
            try await f.store.whenIdle()
            #expect(f.store.selectedThreadID != ConversationThread.defaultID)
            #expect(p.visibleText == p.receivedText)
            f.store.selectThread(ConversationThread.defaultID)
            #expect(f.store.streamingMessageID == id)
            #expect(f.store.streamingPresentation === p)
            #expect(!p.hasPendingText)
            #expect(try await f.repository.snapshot().chat.allSatisfy { $0.id != id })
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }

    @Test func continuedResponseAfterFlushStaysInTheSameParagraphAndCorrectionsReplaceIt() {
        let p = StreamingTextPresentation(), id = UUID()
        let first = "# 머리\n\n이어지는 문단"
        p.receive(first, messageID: id)
        p.finish()
        p.receive(first + "의 다음 글자", messageID: id)
        p.advance(by: 1.0 / 60)
        #expect(p.blocks == [.heading(level: 1, text: "머리")])
        #expect(p.tail.hasPrefix("이어지는 문단"))
        p.finish()
        #expect(p.blocks == MarkdownBlocks.parse(first + "의 다음 글자"))
        p.receive("짧은 교정 👩🏽‍💻", messageID: id)
        #expect(p.visibleText == "짧은 교정 👩🏽‍💻")
        #expect(p.blocks == [.paragraph("짧은 교정 👩🏽‍💻")])
        #expect(!p.needsFrame)
        p.receive("새 메시지", messageID: UUID())
        #expect(p.visibleText.isEmpty)
        #expect(p.blocks.isEmpty)
    }
}
