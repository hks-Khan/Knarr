import Foundation
import Testing
@testable import KnarrCore

@MainActor @Suite(.serialized) struct ChatQuestionReplyTests {
    @Test func failedExtensionReplyThrowsAndCanBeRetried() async throws {
        let f = try await LiveFixture.make()
        do {
            await f.store.observe(frame: .object(["type": .string("extension_ui_request"), "id": .string("reply-test"), "method": .string("confirm"), "title": .string("진행할까요?")]))
            let question = try #require(f.store.questions.first(where: { $0.extensionIdentity != nil && $0.isPending }))
            f.store.setThreadFactory { thread in
                let rpc = LiveTestRPC()
                return LiveConversation(repository: f.repository, session: StallariSession(repository: f.repository, rpc: rpc, hird: f.hird), rpc: rpc, hird: f.hird, threadID: thread.id)
            }
            f.store.createThread(name: "다른 대화")
            try await f.store.whenIdle()
            let other = try #require(f.store.threads.first(where: { $0.name == "다른 대화" }))
            f.store.selectThread(ConversationThread.defaultID)
            try await f.store.whenIdle()
            await f.rpc.setFailQuestionSend(true)
            await f.rpc.setQuestionSendDelay(.milliseconds(100))
            do {
                let reply = Task { try await f.store.replyToQuestion(question.id, answer: .init(selectedOptions: ["예"], text: nil)) }
                try await Task.sleep(for: .milliseconds(20))
                f.store.selectThread(other.id)
                try await reply.value
                Issue.record("Failed RPC must release the web submission through a thrown error")
            } catch {
                f.store.selectThread(ConversationThread.defaultID)
                try await f.store.whenIdle()
                #expect(f.store.question(question.id)?.isPending == true)
            }
            await f.rpc.setFailQuestionSend(false)
            try await f.store.replyToQuestion(question.id, answer: .init(selectedOptions: ["예"], text: nil))
            #expect(f.store.question(question.id)?.isPending == false)
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }
}
