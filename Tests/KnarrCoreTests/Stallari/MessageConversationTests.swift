import Foundation
import Testing
@testable import KnarrCore

@Suite(.serialized) struct MessageConversationTests {
    @Test func modelLinksExistingMessageWithoutCreatingSessionOrThread() async throws {
        let f = try await StallariFixture.make()
        do {
            let item = ChatItem(at: .now, kind: .user("DeepSeek도 연결할 수 있어?"))
            try await f.repository.appendChat(item, projectID: "p")
            let before = try await f.repository.snapshot()
            let result = try await f.session.performTool("link_message_conversation", arguments: .object(["messageID": .string(item.id.uuidString)]))
            #expect(result["messageID"]?.string == item.id.uuidString)
            let after = try await f.repository.snapshot()
            #expect(after.threads == before.threads)
            #expect(after.chat.count == before.chat.count)
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }
    @Test func linksAndRepliesSurviveReloadAndRejectForeignThread() async throws {
        let f = try await StallariFixture.make()
        do {
            let source = ChatItem(at: .now, kind: .user("연결할 주제"))
            try await f.repository.appendChat(source, projectID: "p")
            try await f.repository.linkMessageConversation(source.id, threadID: ConversationThread.defaultID)
            var reply = ChatItem(at: .now, kind: .stallari("보존할 답변", project: nil))
            reply.conversationRootID = source.id
            try await f.repository.appendChat(reply, projectID: "p", threadID: ConversationThread.defaultID)
            let foreign = ConversationThread(name: "다른 대화")
            try await f.repository.saveThread(foreign)
            await #expect(throws: (any Error).self) { try await f.repository.linkMessageConversation(source.id, threadID: foreign.id) }
            await #expect(throws: (any Error).self) { try await f.repository.appendChat(reply, projectID: "p", threadID: foreign.id) }
            let copy = try await SQLiteKnarrRepository.open(at: f.directory.appendingPathComponent("knarr.db"))
            let snapshot = try await copy.snapshot()
            #expect(snapshot.chat.first { $0.id == source.id }?.isConversationLink == true)
            #expect(snapshot.chat.first { $0.id == reply.id }?.conversationRootID == source.id)
            try await copy.close()
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }
    @Test func unknownMessageCannotBecomeLink() async throws {
        let f = try await StallariFixture.make()
        do {
            await #expect(throws: (any Error).self) {
                _ = try await f.session.performTool("link_message_conversation", arguments: .object(["messageID": .string(UUID().uuidString)]))
            }
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }
}
