import Foundation
import Testing
@testable import KnarrCore

@MainActor @Suite(.serialized) struct ConversationProgressTests {
    private func update(_ type: String, _ text: String, index: Int = 0, id: String = "reply", content: [OMPJSON]? = nil) -> OMPJSON {
        var message: [String: OMPJSON] = ["role": .string("assistant")]
        if let content { message["content"] = .array(content) }
        return .object(["type": .string("message_update"), "messageId": .string(id), "message": .object(message),
            "assistantMessageEvent": .object(["type": .string(type), "contentIndex": .number(Double(index)), "delta": .string(text)])])
    }
    private func end(_ content: [OMPJSON], id: String = "reply") -> OMPJSON {
        .object(["type": .string("message_end"), "messageId": .string(id), "message": .object(["role": .string("assistant"), "content": .array(content)])])
    }
    private func texts(_ items: [ChatItem]) -> [String] {
        items.compactMap { if case .stallari(let text, _) = $0.kind { text } else { nil } }
    }
    @Test func suppliedReasoningAndCommentaryRemainSeparateInOrderAndSurviveReopen() async throws {
        let f = try await LiveFixture.make()
        do {
            await f.store.observe(frame: .object(["type": .string("agent_start")]))
            await f.store.observe(frame: update("thinking_delta", "기존 화면을 "))
            await f.store.observe(frame: update("thinking_delta", "확인합니다."))
            await f.store.observe(frame: update("text_delta", "관련 파일을 읽겠습니다.", index: 1))
            try await f.store.whenIdle()
            #expect(texts(f.store.chat) == ["기존 화면을 확인합니다.", "관련 파일을 읽겠습니다."])
            let terminal = end([.object(["type": .string("thinking"), "thinking": .string("기존 화면을 확인합니다.")]),
                .object(["type": .string("text"), "text": .string("관련 파일을 읽겠습니다.")])])
            await f.store.observe(frame: terminal)
            await f.store.observe(frame: terminal)
            await f.store.observe(frame: update("thinking_delta", "늦은 중복"))
            await f.store.observe(frame: end([.object(["type": .string("text"), "text": .string("확인을 마쳤습니다.")])], id: "final"))
            let reopened = try await SQLiteKnarrRepository.open(at: f.directory.appendingPathComponent("knarr.db"))
            let saved = try await reopened.snapshot().chat.sorted { $0.at < $1.at }
            #expect(texts(saved) == ["기존 화면을 확인합니다.", "관련 파일을 읽겠습니다.", "확인을 마쳤습니다."])
            try await reopened.close()
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }
    @Test func snapshotFramesAlsoAdvanceStatusAndDoNotAppendDeltaTwice() async throws {
        let f = try await LiveFixture.make()
        do {
            await f.store.observe(frame: .object(["type": .string("agent_start")]))
            await f.store.observe(frame: update("thinking_delta", "요약", content: [.object(["type": .string("thinking"), "thinking": .string("요약")])]))
            #expect(f.store.responseStatus == "생각 중")
            await f.store.observe(frame: update("text_delta", "답변", index: 1, content: [
                .object(["type": .string("thinking"), "thinking": .string("요약")]),
                .object(["type": .string("text"), "text": .string("답변")])]))
            #expect(f.store.responseStatus == "답변 작성 중")
            try await f.store.whenIdle()
            #expect(texts(f.store.chat) == ["요약", "답변"])
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }
    @Test func toolExecutionHasOneVisibleTargetRowAndPersistsAfterFailure() async throws {
        let f = try await LiveFixture.make()
        do {
            let start: OMPJSON = .object(["type": .string("tool_execution_start"), "toolName": .string("read"), "toolCallId": .string("call-1"),
                "args": .object(["path": .string("Sources/example.swift")])])
            await f.store.observe(frame: start)
            await f.store.observe(frame: start)
            #expect(texts(f.store.chat).filter { $0.contains("Sources/example.swift") }.count == 1)
            await f.store.observe(frame: .object(["type": .string("tool_execution_end"), "toolName": .string("read"), "toolCallId": .string("call-1"), "isError": .bool(true)]))
            try await f.store.whenIdle()
            #expect(texts(try await f.repository.snapshot().chat).filter { $0.contains("Sources/example.swift") }.count == 1)
            #expect(f.store.chat.first?.activity?.state == .failed)
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }
    @Test func stoppedToolCannotBecomeCompletedFromLateResult() async throws {
        let f = try await LiveFixture.make()
        do {
            await f.store.observe(frame: .object(["type": .string("agent_start")]))
            await f.store.observe(frame: .object(["type": .string("tool_execution_start"), "toolName": .string("bash"), "toolCallId": .string("stopped"),
                "args": .object(["command": .string("swift test --token secret")])]))
            f.store.stopResponse()
            // A terminal event may arrive before the abort request continuation resumes.
            await f.store.observe(frame: .object(["type": .string("agent_end")]))
            try await f.store.whenIdle()
            await f.store.observe(frame: .object(["type": .string("tool_execution_end"), "toolCallId": .string("stopped"), "isError": .bool(false)]))
            let item = try #require(f.store.chat.first { $0.activity?.kind == .tool })
            #expect(item.activity?.state == .stopped)
            #expect(texts([item]) == ["swift"])
            #expect(try await f.repository.snapshot().chat.first { $0.id == item.id }?.activity?.state == .stopped)
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }
    @Test func failedProgressPersistenceRetainsRowAndRetryDoesNotRepeatTool() async throws {
        let f = try await LiveFixture.make()
        let writer = try SQLiteConnection(path: f.directory.appendingPathComponent("knarr.db").path, flags: 2)
        defer { try? writer.close() }
        do {
            await f.store.observe(frame: .object(["type": .string("tool_execution_start"), "toolName": .string("read"), "toolCallId": .string("retry"), "args": .object(["path": .string("file.swift")])]))
            let id = try #require(f.store.chat.first?.id)
            try writer.execute("CREATE TRIGGER reject_progress BEFORE INSERT ON chat BEGIN SELECT RAISE(ABORT,'fixture write failure'); END")
            let terminal: OMPJSON = .object(["type": .string("tool_execution_end"), "toolCallId": .string("retry"), "isError": .bool(false)])
            await f.store.observe(frame: terminal)
            #expect(f.store.assistantPersistenceError != nil)
            #expect(f.store.chat.first { $0.id == id }?.activity?.state == .completed)
            try writer.execute("DROP TRIGGER reject_progress")
            await f.store.retryAssistantPersistence()
            await f.store.observe(frame: terminal)
            #expect(f.store.assistantPersistenceError == nil)
            #expect(try await f.repository.snapshot().chat.filter { $0.id == id }.count == 1)
            try await f.cleanup()
        } catch {
            try? writer.execute("DROP TRIGGER IF EXISTS reject_progress")
            try await f.cleanup(); throw error
        }
    }
    @Test func progressIsOwnedByItsProjectConversationAndLegacyRowsDecode() async throws {
        let f = try await LiveFixture.make()
        let thread = try await f.repository.createProjectConversation(projectID: "p")
        let rpc = LiveTestRPC()
        let prefsName = "knarr-progress-owner-" + UUID().uuidString
        let prefs = try #require(UserDefaults(suiteName: prefsName))
        defer { prefs.removePersistentDomain(forName: prefsName) }
        let conversation = LiveConversation(repository: f.repository,
            session: StallariSession(repository: f.repository, rpc: rpc, hird: f.hird, threadID: thread.id),
            rpc: rpc, hird: f.hird, threadID: thread.id, preferences: prefs)
        do {
            try await conversation.connect()
            await conversation.observe(frame: update("thinking_delta", "프로젝트 기록 확인"))
            await conversation.observe(frame: end([]))
            let snapshot = try await f.repository.snapshot()
            let item = try #require(snapshot.chat.first { $0.activity != nil })
            let link = try #require(snapshot.chatLinks.first { $0.chatID == item.id })
            #expect(link.projectID == "p")
            #expect(link.conversationThreadID == thread.id)
            // Old rows have no activity field; optional metadata must remain backward compatible.
            var old = item; old.activity = nil
            let stored = StoredChat(old, link: link)
            let encoded = try JSONEncoder().encode(stored)
            #expect(!String(decoding: encoded, as: UTF8.self).contains("activity"))
            #expect(try JSONDecoder().decode(StoredChat.self, from: encoded).item() == old)
            _ = await conversation.shutdown(includeSharedHird: false)
            try await f.cleanup()
        } catch {
            _ = await conversation.shutdown(includeSharedHird: false)
            try await f.cleanup(); throw error
        }
    }
    @Test func fullSnapshotWithoutDeltaStillSignalsReasoning() async throws {
        let f = try await LiveFixture.make()
        do {
            await f.store.observe(frame: .object(["type": .string("agent_start")]))
            await f.store.observe(frame: .object(["type": .string("message_update"), "messageId": .string("snapshot"), "message": .object([
                "role": .string("assistant"), "content": .array([.object(["type": .string("thinking"), "thinking": .string("설정 확인 중")])])])]))
            #expect(f.store.responseStatus == "생각 중")
            #expect(texts(f.store.chat) == ["설정 확인 중"])
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }
    @Test func completingOneToolKeepsOtherActiveToolVisibleInStatus() async throws {
        let f = try await LiveFixture.make()
        do {
            for (id, tool) in [("one", "read"), ("two", "grep")] {
                await f.store.observe(frame: .object(["type": .string("tool_execution_start"), "toolCallId": .string(id), "toolName": .string(tool)]))
            }
            await f.store.observe(frame: .object(["type": .string("tool_execution_end"), "toolCallId": .string("one"), "isError": .bool(false)]))
            #expect(f.store.responseStatus == "내용 검색 진행 중")
            #expect(f.store.chat.filter { $0.activity?.state == .running }.count == 1)
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }
    @Test func reasoningReceivedBeforeConnectionExitIsRetained() async throws {
        let f = try await LiveFixture.make()
        do {
            await f.store.observe(frame: update("thinking_delta", "파일 구조를 확인합니다."))
            await f.rpc.terminate()
            for _ in 0..<200 {
                if f.store.stallari.engine == "OMP · 실행 종료" { break }
                try await Task.sleep(for: .milliseconds(5))
            }
            #expect(texts(try await f.repository.snapshot().chat) == ["파일 구조를 확인합니다."])
            #expect(f.store.chat.first?.activity?.state == .interrupted)
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }
}
