import Foundation
import Testing
@testable import KnarrCore

@MainActor @Suite(.serialized) struct StreamingResponseTests {
    private func delta(_ text: String, id: String = "msg-1", index: Int = 0, type: String = "text_delta") -> OMPJSON {
        .object(["type": .string("message_update"), "messageId": .string(id),
                 "message": .object(["role": .string("assistant")]),
                 "assistantMessageEvent": .object(["type": .string(type), "contentIndex": .number(Double(index)), "delta": .string(text)])])
    }
    private func end(_ text: String, id: String = "msg-1") -> OMPJSON {
        .object(["type": .string("message_end"), "messageId": .string(id), "message": .object([
            "role": .string("assistant"), "content": .array([.object(["type": .string("text"), "text": .string(text)])])])])
    }

    @Test func whenIdlePublishesReceivedDeltasWithoutCompletingTheResponse() async throws {
        let f = try await LiveFixture.make()
        do {
            await f.store.observe(frame: .object(["type": .string("agent_start")]))
            await f.store.observe(frame: delta("첫"))
            let id = try #require(f.store.streamingMessageID)
            let presentation = try #require(f.store.streamingPresentation)
            await f.store.observe(frame: delta("째"))
            await f.store.observe(frame: delta("제공된 추론 요약", index: 1, type: "thinking_delta"))
            await f.store.observe(frame: delta("둘째 단락", index: 2))
            let received = "첫째\n둘째 단락"
            // Receipt is synchronous; transcript publication is separately coalesced.
            #expect(presentation.receivedText == received)
            try await f.store.whenIdle()
            #expect(f.store.streamingMessageID == id)
            #expect(f.store.streamingText == received)
            #expect(f.store.chat.first { $0.id == id }?.kind == .stallari(received, project: nil))
            #expect(presentation.isStreaming)
            #expect(f.store.isResponding)
            #expect(presentation.hasPendingText)
            #expect(try await f.repository.snapshot().chat.isEmpty)
            await f.store.observe(frame: delta(" 이어지는 응답", index: 2))
            let continued = received + " 이어지는 응답"
            #expect(presentation.receivedText == continued)
            try await f.store.whenIdle()
            #expect(f.store.streamingMessageID == id)
            #expect(f.store.streamingText == continued)
            await f.store.observe(frame: end(""))
            #expect(try await f.repository.snapshot().chat.first { $0.id == id }?.kind == .stallari(continued, project: nil))
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }

    @Test func deltaBlocksKeepIdentitySeparateThinkingAndDeduplicateFinalOnReopen() async throws {
        let f = try await LiveFixture.make()
        do {
            await f.store.observe(frame: delta("첫"))
            let id = try #require(f.store.streamingMessageID)
            let at = try #require(f.store.chat.first { $0.id == id }?.at)
            await f.store.observe(frame: delta("째 줄\n둘째 줄"))
            await f.store.observe(frame: delta("제공된 추론 요약", index: 1, type: "thinking_delta"))
            await f.store.observe(frame: delta("마지막 단락", index: 2))
            #expect(f.store.streamingMessageID == id)
            try await f.store.whenIdle()
            #expect(f.store.streamingText == "첫째 줄\n둘째 줄\n마지막 단락")
            #expect(f.store.chat.filter { $0.id == id }.count == 1)
            #expect(try await f.repository.snapshot().chat.isEmpty)
            let final = end("최종 첫째 줄\n둘째 줄\n마지막 단락")
            await f.store.observe(frame: final)
            await f.store.observe(frame: final)
            await f.store.observe(frame: delta("늦은 토큰"))
            try await f.store.whenIdle()
            let item = try #require(f.store.chat.first { $0.id == id })
            #expect(item.at == at)
            #expect(item.kind == .stallari("최종 첫째 줄\n둘째 줄\n마지막 단락", project: nil))
            #expect(f.store.chat.filter { $0.activity == nil }.count == 1)
            #expect(f.store.streamingMessageID == nil)
            #expect(f.store.streamingText.isEmpty)
            // Equal prose from a different OMP message is not a duplicate.
            await f.store.observe(frame: end("최종 첫째 줄\n둘째 줄\n마지막 단락", id: "msg-2"))
            let reopened = try await SQLiteKnarrRepository.open(at: f.directory.appendingPathComponent("knarr.db"))
            let saved = try await reopened.snapshot().chat
            #expect(saved.filter { $0.activity == nil }.count == 2)
            #expect(saved.first { $0.id == id } == item)
            let reopenedRPC = LiveTestRPC()
            let reopenedHird = LiveTestHird()
            let reopenedSession = StallariSession(repository: reopened, rpc: reopenedRPC, hird: reopenedHird)
            let reopenedStore = LiveKnarrStore(repository: reopened, session: reopenedSession, rpc: reopenedRPC, hird: reopenedHird,
                                              subscriptionUsage: .init(sample: true))
            try await reopenedStore.connect()
            #expect(reopenedStore.chat.first { $0.id == id } == item)
            #expect(reopenedStore.chat.filter { $0.activity == nil }.count == 2)
            #expect(reopenedStore.streamingMessageID == nil)
            _ = await reopenedStore.shutdown()
            try await reopened.close()
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }

    @Test(arguments: ["error", "aborted"])
    func terminalPreservesPartialAndNextMessageIsIndependent(status: String) async throws {
        let f = try await LiveFixture.make()
        do {
            f.store.send("첫 줄\n둘째 줄", about: nil)
            try await f.store.whenIdle()
            #expect(await f.rpc.prompts.last?["message"]?.string?.contains("첫 줄\n둘째 줄") == true)
            #expect(f.store.chat.contains { $0.kind == .user("첫 줄\n둘째 줄") })
            let prompt = try #require(await f.rpc.promptIDs.last)
            await f.store.observe(frame: delta("남겨 둘 부분\n응답"))
            let id = try #require(f.store.streamingMessageID)
            await f.store.observe(frame: .object(["type": .string("prompt_result"), "id": .string(prompt), "status": .string(status)]))
            #expect(!f.store.isResponding)
            #expect(try await f.repository.snapshot().chat.contains { $0.id == id && $0.kind == .stallari("남겨 둘 부분\n응답", project: nil) })
            await f.store.observe(frame: end("", id: "msg-1"))
            f.store.send("다음 요청", about: nil)
            try await f.store.whenIdle()
            await f.store.observe(frame: delta("다음 응답", id: "msg-2"))
            #expect(f.store.streamingMessageID != id)
            #expect(f.store.streamingText == "다음 응답")
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }

    @Test func emptyAbortEndAndProcessExitPreservePartial() async throws {
        let f = try await LiveFixture.make()
        do {
            await f.store.observe(frame: delta("취소 전 내용"))
            let first = try #require(f.store.streamingMessageID)
            await f.store.observe(frame: end(""))
            #expect(try await f.repository.snapshot().chat.contains { $0.id == first && $0.kind == .stallari("취소 전 내용", project: nil) })
            await f.store.observe(frame: delta("연결 종료 전 내용", id: "msg-2"))
            let second = try #require(f.store.streamingMessageID)
            await f.rpc.terminate()
            for _ in 0..<200 {
                if f.store.stallari.engine == "OMP · 실행 종료" { break }
                try await Task.sleep(for: .milliseconds(5))
            }
            #expect(try await f.repository.snapshot().chat.contains { $0.id == second && $0.kind == .stallari("연결 종료 전 내용", project: nil) })
            #expect(f.store.streamingMessageID == nil)
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }

    @Test func textEndReplacesBlockRatherThanAppendingAgain() async throws {
        let f = try await LiveFixture.make()
        do {
            await f.store.observe(frame: delta("중간"))
            let id = try #require(f.store.streamingMessageID)
            await f.store.observe(frame: .object([
                "type": .string("message_update"), "messageId": .string("msg-1"),
                "message": .object(["role": .string("assistant")]),
                "assistantMessageEvent": .object(["type": .string("text_end"), "contentIndex": .number(0), "content": .string("완성")])
            ]))
            #expect(f.store.streamingText == "완성")
            #expect(f.store.streamingMessageID == id)
            await f.store.observe(frame: .object(["type": .string("agent_end")]))
            #expect(try await f.repository.snapshot().chat.contains { $0.id == id && $0.kind == .stallari("완성", project: nil) })
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }

    @Test func publicErrorsKeepPolicyGuidanceWithoutProviderDetails() {
        let provider = NSError(domain: "OMP.provider", code: 1,
                               userInfo: [NSLocalizedDescriptionKey: "private-provider-diagnostic"])
        #expect(LiveConversation.safeError(provider, fallback: "안전한 안내") == "안전한 안내")
        #expect(LiveConversation.safeError(StallariThinkingError.unsupported, fallback: "") == StallariThinkingError.unsupported.localizedDescription)
        #expect(LiveConversation.safeError(ResponseRulesError.invalidPath, fallback: "") == ResponseRulesError.invalidPath.localizedDescription)
        let file = NSError(domain: NSCocoaErrorDomain, code: 257,
                           userInfo: [NSLocalizedDescriptionKey: "private-file-diagnostic"])
        let visible = LiveConversation.safeError(file, fallback: "")
        #expect(visible.contains("파일"))
        #expect(visible.contains("257"))
        #expect(!visible.contains("private-file-diagnostic"))
    }
}
