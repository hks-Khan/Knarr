import Foundation
import Testing
@testable import KnarrCore

/// A reply that points at a picture on this Mac is saved pointing at Knarr's own copy.
@MainActor @Suite(.serialized) struct ChatInlineImagePersistenceTests {
    private func delta(_ text: String, id: String = "reply") -> OMPJSON {
        .object(["type": .string("message_update"), "messageId": .string(id),
            "message": .object(["role": .string("assistant")]),
            "assistantMessageEvent": .object(["type": .string("text_delta"), "contentIndex": .number(0), "delta": .string(text)])])
    }
    private func end(_ text: String, id: String = "reply") -> OMPJSON {
        .object(["type": .string("message_end"), "messageId": .string(id),
            "message": .object(["role": .string("assistant"), "content": .array([
                .object(["type": .string("text"), "text": .string(text)])])])])
    }

    /// The runtime keeps its records under `<data>/results`, so the copy lands in `<data>/attachments/stallari`.
    @Test func savedReplyKeepsItsImageAfterTheOriginalFileIsGone() async throws {
        let f = try await LiveFixture.make()
        let suite = "knarr-image-persist-\(UUID())"
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let data = f.directory.appendingPathComponent("data", isDirectory: true)
        let scratch = f.directory.appendingPathComponent("scratch", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let shot = scratch.appendingPathComponent("shot.png")
        try Data(repeating: 0x41, count: 128).write(to: shot)
        let thread = try await f.repository.createProjectConversation(projectID: "p")
        let rpc = LiveTestRPC()
        let conversation = LiveConversation(repository: f.repository,
            session: StallariSession(repository: f.repository, rpc: rpc, hird: f.hird, threadID: thread.id),
            rpc: rpc, hird: f.hird, threadID: thread.id, preferences: preferences,
            resultsRoot: data.appendingPathComponent("results"))
        try await conversation.connect()
        do {
            try await conversation.submit(.init(text: "화면을 봐 주세요", project: "p"))
            let text = "확인했습니다.\n\n![화면](\(shot.path))"
            await conversation.observe(frame: end(text))
            let saved = try #require(try await f.repository.snapshot().chat.last { item in
                if case .stallari = item.kind { return true } else { return false }
            })
            guard case .stallari(let stored, _) = saved.kind else { Issue.record("답변이 저장되지 않았어요"); return }
            #expect(!stored.contains(shot.path))
            let copied = try #require(stored.split(separator: "(").dropFirst().first.map {
                String($0.prefix(while: { $0 != ")" })).trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
            })
            #expect(copied.hasPrefix(data.appendingPathComponent("attachments/stallari").path + "/"))
            #expect(copied.hasSuffix(".png"))
            // The picture survives the file Stallari pointed at; a restart reads this copy.
            try FileManager.default.removeItem(at: shot)
            #expect(FileManager.default.contents(atPath: copied)?.count == 128)
            #expect(ChatImageSource.url(forPath: copied) != nil)
        } catch {
            _ = await conversation.shutdown(includeSharedHird: false)
            try await f.cleanup()
            throw error
        }
        _ = await conversation.shutdown(includeSharedHird: false)
        try await f.cleanup()
    }

    /// A path Knarr will not read leaves the reply exactly as the model wrote it.
    @Test func refusedImagePathStaysAsPlainText() async throws {
        let f = try await LiveFixture.make()
        let suite = "knarr-image-refuse-\(UUID())"
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let rpc = LiveTestRPC()
        let thread = try await f.repository.createProjectConversation(projectID: "p")
        let conversation = LiveConversation(repository: f.repository,
            session: StallariSession(repository: f.repository, rpc: rpc, hird: f.hird, threadID: thread.id),
            rpc: rpc, hird: f.hird, threadID: thread.id, preferences: preferences,
            resultsRoot: f.directory.appendingPathComponent("data/results"))
        try await conversation.connect()
        do {
            try await conversation.submit(.init(text: "비밀 파일을 봐 주세요", project: "p"))
            let text = "못 보여 드립니다.\n\n![비밀](/etc/hosts)"
            await conversation.observe(frame: end(text))
            #expect(conversation.chat.contains { $0.kind == .stallari(text, project: nil) })
            let saved = try await f.repository.snapshot().chat
            #expect(saved.contains { $0.kind == .stallari(text, project: nil) })
        } catch {
            _ = await conversation.shutdown(includeSharedHird: false)
            try await f.cleanup()
            throw error
        }
        _ = await conversation.shutdown(includeSharedHird: false)
        try await f.cleanup()
    }
}
