import Foundation
import Testing
@testable import KnarrCore

@MainActor @Suite(.serialized) struct AssistantPersistenceTests {
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
    private func projectConversation(_ f: LiveFixture, rpc: LiveTestRPC, preferences: UserDefaults) async throws -> LiveConversation {
        let thread = try await f.repository.createProjectConversation(projectID: "p")
        let conversation = LiveConversation(repository: f.repository,
            session: StallariSession(repository: f.repository, rpc: rpc, hird: f.hird, threadID: thread.id),
            rpc: rpc, hird: f.hird, threadID: thread.id, preferences: preferences)
        try await conversation.connect()
        return conversation
    }

    @Test func writeFailureKeepsFinalTextAndRetriesSameUUIDWithoutAnotherModelRequest() async throws {
        let f = try await LiveFixture.make()
        let suite = "knarr-assistant-write-\(UUID())"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let rpc = LiveTestRPC()
        let conversation = try await projectConversation(f, rpc: rpc, preferences: preferences)
        let writer = try SQLiteConnection(path: f.directory.appendingPathComponent("knarr.db").path, flags: 2)
        defer { try? writer.close() }
        do {
            try await conversation.submit(.init(text: "답변을 보존해 주세요", project: "p"))
            let prompts = await rpc.prompts.count
            await conversation.observe(frame: delta("초안"))
            let id = try #require(conversation.streamingMessageID)
            try writer.execute("CREATE TRIGGER reject_assistant BEFORE INSERT ON chat BEGIN SELECT RAISE(ABORT,'fixture write failure'); END")
            await conversation.observe(frame: end("저장 실패에도 남아야 하는 최종 답변"))
            let retained = try #require(conversation.chat.first { $0.id == id })
            #expect(retained.kind == .stallari("저장 실패에도 남아야 하는 최종 답변", project: nil))
            #expect(conversation.assistantPersistenceError?.contains("저장하지 못했어요") == true)
            #expect(conversation.streamingMessageID == nil)
            #expect(try await !f.repository.snapshot().chat.contains { $0.id == id })
            await conversation.observe(frame: end("중복 종료가 최종 본문을 바꾸면 안 돼요"))
            await conversation.observe(frame: delta("늦은 토큰"))
            #expect(conversation.chat.first { $0.id == id } == retained)
            try writer.execute("DROP TRIGGER reject_assistant")
            async let first: Void = conversation.retryAssistantPersistence()
            async let second: Void = conversation.retryAssistantPersistence()
            _ = await (first, second)
            await conversation.observe(frame: end("저장 실패에도 남아야 하는 최종 답변"))
            #expect(conversation.assistantPersistenceError == nil)
            #expect(!conversation.isRetryingAssistantPersistence)
            #expect(await rpc.prompts.count == prompts)
            #expect(conversation.chat.filter { $0.id == id } == [retained])
            let reopened = try await SQLiteKnarrRepository.open(at: f.directory.appendingPathComponent("knarr.db"))
            #expect(try await reopened.snapshot().chat.filter { $0.id == id } == [retained])
            try await reopened.close()
            _ = await conversation.shutdown(includeSharedHird: false)
            try await f.cleanup()
        } catch {
            try? writer.execute("DROP TRIGGER IF EXISTS reject_assistant")
            _ = await conversation.shutdown(includeSharedHird: false)
            try await f.cleanup()
            throw error
        }
    }

    @Test func committedReplyRefreshFailureRetriesReadOnlyWithoutReappend() async throws {
        let f = try await LiveFixture.make()
        let suite = "knarr-assistant-refresh-\(UUID())"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let rpc = LiveTestRPC()
        let conversation = try await projectConversation(f, rpc: rpc, preferences: preferences)
        let writer = try SQLiteConnection(path: f.directory.appendingPathComponent("knarr.db").path, flags: 2)
        let other = try #require(writer.rows("SELECT payload FROM projects WHERE id='other'").first?.first)
        defer { try? writer.close() }
        do {
            try await conversation.submit(.init(text: "저장과 새로고침을 구분해 주세요", project: "p"))
            let prompts = await rpc.prompts.count
            await conversation.observe(frame: delta("초안"))
            let id = try #require(conversation.streamingMessageID)
            try writer.execute("CREATE TRIGGER break_projection AFTER INSERT ON chat BEGIN UPDATE projects SET payload='{' WHERE id='other'; END")
            await conversation.observe(frame: end("이미 저장된 최종 답변"))
            #expect(try writer.rows("SELECT id FROM chat WHERE id=?", [id.uuidString]).count == 1)
            #expect(conversation.chat.first { $0.id == id }?.kind == .stallari("이미 저장된 최종 답변", project: nil))
            #expect(conversation.assistantPersistenceError?.contains("응답은 저장했지만") == true)
            try writer.execute("DROP TRIGGER break_projection")
            try writer.execute("UPDATE projects SET payload=? WHERE id='other'", [other])
            // A reserved write lock permits snapshot reads but rejects any accidental append transaction.
            try writer.execute("BEGIN IMMEDIATE")
            await conversation.retryAssistantPersistence()
            #expect(conversation.assistantPersistenceError == nil)
            #expect(await rpc.prompts.count == prompts)
            #expect(try writer.rows("SELECT id FROM chat WHERE id=?", [id.uuidString]).count == 1)
            #expect(conversation.chat.filter { $0.id == id }.count == 1)
            try writer.execute("ROLLBACK")
            _ = await conversation.shutdown(includeSharedHird: false)
            try await f.cleanup()
        } catch {
            try? writer.execute("ROLLBACK")
            try? writer.execute("DROP TRIGGER IF EXISTS break_projection")
            try? writer.execute("UPDATE projects SET payload=? WHERE id='other'", [other])
            _ = await conversation.shutdown(includeSharedHird: false)
            try await f.cleanup()
            throw error
        }
    }

    @Test func shutdownFlushesThrottledPartialToItsProjectExactlyOnce() async throws {
        let f = try await LiveFixture.make()
        let suite = "knarr-assistant-shutdown-\(UUID())"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let rpc = LiveTestRPC()
        let conversation = try await projectConversation(f, rpc: rpc, preferences: preferences)
        do {
            try await conversation.submit(.init(text: "부분 답변도 보존해 주세요", project: "p"))
            await conversation.observe(frame: delta("첫 부분"))
            let id = try #require(conversation.streamingMessageID)
            await conversation.observe(frame: delta("과 종료 직전 부분"))
            _ = await conversation.shutdown(includeSharedHird: false)
            let snapshot = try await f.repository.snapshot()
            #expect(snapshot.chat.filter { $0.id == id }.map(\.kind) == [.stallari("첫 부분과 종료 직전 부분", project: nil)])
            #expect(snapshot.chatLinks.first { $0.chatID == id }?.projectID == "p")
            #expect(conversation.chat.first { $0.id == id }?.kind == .stallari("첫 부분과 종료 직전 부분", project: nil))
            #expect(conversation.assistantPersistenceError == nil)
            try await f.cleanup()
        } catch {
            _ = await conversation.shutdown(includeSharedHird: false)
            try await f.cleanup()
            throw error
        }
    }

    @Test func shutdownRetriesFailedDraftWithoutRegeneratingIt() async throws {
        let f = try await LiveFixture.make()
        let suite = "knarr-assistant-shutdown-retry-\(UUID())"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let rpc = LiveTestRPC()
        let conversation = try await projectConversation(f, rpc: rpc, preferences: preferences)
        let writer = try SQLiteConnection(path: f.directory.appendingPathComponent("knarr.db").path, flags: 2)
        defer { try? writer.close() }
        do {
            try await conversation.submit(.init(text: "종료 때도 저장을 시도해 주세요", project: "p"))
            await conversation.observe(frame: delta("남은 답변"))
            let id = try #require(conversation.streamingMessageID)
            let prompts = await rpc.prompts.count
            try writer.execute("CREATE TRIGGER reject_assistant BEFORE INSERT ON chat BEGIN SELECT RAISE(ABORT,'fixture write failure'); END")
            await conversation.observe(frame: end("남은 답변"))
            #expect(conversation.assistantPersistenceError != nil)
            try writer.execute("DROP TRIGGER reject_assistant")
            _ = await conversation.shutdown(includeSharedHird: false)
            #expect(try await f.repository.snapshot().chat.filter { $0.id == id }.map(\.kind) == [.stallari("남은 답변", project: nil)])
            #expect(await rpc.prompts.count == prompts)
            #expect(conversation.assistantPersistenceError == nil)
            try await f.cleanup()
        } catch {
            try? writer.execute("DROP TRIGGER IF EXISTS reject_assistant")
            _ = await conversation.shutdown(includeSharedHird: false)
            try await f.cleanup()
            throw error
        }
    }

    @Test(arguments: ["main", "issue"])
    func submittedMainAndIssueRepliesKeepTheirDurableOwner(scope: String) async throws {
        let f = try await LiveFixture.make()
        let suite = "knarr-assistant-owner-\(UUID())"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let threadID = scope == "main" ? ConversationThread.defaultID : "issue-thread"
        if scope == "issue" {
            var issue = KnarrCore.Issue(id: "owned-issue", title: "이슈 답변", projectName: "프로젝트",
                state: .awaitingApproval, headline: "", detail: "", acceptance: [], hirds: [], events: [], startedAt: .now)
            issue.threadID = threadID
            issue.proposal = .init(instruction: "이슈 답변을 보존해요", model: "provider/model")
            try await f.repository.createIssueConversation(issue, projectID: "p", originThreadID: ConversationThread.defaultID, handoffSummary: "이슈 문맥")
        }
        let rpc = LiveTestRPC()
        let conversation = LiveConversation(repository: f.repository,
            session: StallariSession(repository: f.repository, rpc: rpc, hird: f.hird, threadID: threadID),
            rpc: rpc, hird: f.hird, threadID: threadID, preferences: preferences)
        do {
            try await conversation.connect()
            try await conversation.submit(.init(text: "이 대화의 답변을 저장해 주세요"))
            let promptID = try #require(await rpc.promptIDs.last)
            await rpc.frame(delta("저장할 답변"))
            await rpc.frame(end("저장할 답변"))
            await rpc.frame(end("저장할 답변"))
            await rpc.frame(.object(["type": .string("prompt_result"), "id": .string(promptID), "status": .string("completed")]))
            for _ in 0..<200 {
                if !conversation.isResponding { break }
                try await Task.sleep(for: .milliseconds(5))
            }
            try await conversation.whenIdle()
            #expect(!conversation.isResponding)
            #expect(conversation.assistantPersistenceError == nil)
            let snapshot = try await f.repository.snapshot()
            let replies = snapshot.chat.filter { $0.kind == .stallari("저장할 답변", project: nil) }
            #expect(replies.count == 1)
            let reply = try #require(replies.first)
            let link = try #require(snapshot.chatLinks.first { $0.chatID == reply.id })
            #expect(link.conversationThreadID == threadID)
            #expect(link.projectID == (scope == "main" ? StoredProject.hubID : "p"))
            #expect(link.issueID == (scope == "main" ? nil : "owned-issue"))
            _ = await conversation.shutdown(includeSharedHird: false)
            try await f.cleanup()
        } catch {
            _ = await conversation.shutdown(includeSharedHird: false)
            try await f.cleanup()
            throw error
        }
    }
}
