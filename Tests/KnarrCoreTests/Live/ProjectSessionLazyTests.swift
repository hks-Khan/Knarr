import Foundation
import Testing
@testable import KnarrCore

@MainActor @Suite(.serialized) struct ProjectSessionLazyTests {
    @Test func openingProjectsDoesNotPersistOrStartUntilFirstMessage() async throws {
        let f = try await LiveFixture.make()
        let suite = "knarr-project-lazy-\(UUID())"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        var opened: [String] = []
        var rpcs: [String: LiveTestRPC] = [:]
        f.store.setThreadFactory { thread in
            opened.append(thread.id)
            let rpc = LiveTestRPC(); rpcs[thread.id] = rpc
            return LiveConversation(repository: f.repository,
                session: StallariSession(repository: f.repository, rpc: rpc, hird: f.hird, threadID: thread.id),
                rpc: rpc, hird: f.hird, threadID: thread.id, preferences: preferences)
        }
        do {
            f.store.selectProjectConversation("p")
            let firstID = f.store.selectedThreadID
            f.store.composerDraft.text = "프로젝트별 초안"
            try await f.store.whenIdle()
            #expect(opened.isEmpty)
            #expect(try await f.repository.snapshot().threads.allSatisfy { $0.projectID == nil })
            #expect(f.store.chat.isEmpty)
            f.store.selectProjectConversation("other")
            #expect(f.store.composerDraft.text.isEmpty)
            f.store.selectProjectConversation("p")
            #expect(f.store.selectedThreadID == firstID)
            #expect(f.store.composerDraft.text == "프로젝트별 초안")
            await #expect(throws: (any Error).self) { try await f.store.submit(.init(text: " ", project: "p")) }
            await #expect(throws: StallariError.wrongProject) {
                try await f.store.submit(.init(text: "외부 프로젝트 요청", project: "other"))
            }
            #expect(opened.isEmpty)
            #expect(try await f.repository.snapshot().threads.allSatisfy { $0.projectID == nil })
            try await f.store.submit(.init(text: "첫 프로젝트 메시지", project: "p"))
            try await f.store.whenIdle()
            let thread = try #require(try await f.repository.snapshot().threads.first { $0.projectID == "p" })
            #expect(opened == [thread.id])
            #expect(f.store.selectedThreadID == thread.id)
            let rpc = try #require(rpcs[thread.id])
            #expect(await rpc.prompts.filter { $0["message"]?.string?.contains("첫 프로젝트 메시지") == true }.count == 1)
            f.store.composerDraft = .init(text: "시작 뒤 프로젝트 초안", project: "other")
            #expect(f.store.composerDraft.project == "p")
            f.store.selectThread(ConversationThread.defaultID)
            try await f.store.whenIdle()
            f.store.selectProjectConversation("p")
            try await f.store.whenIdle()
            #expect(opened == [thread.id])
            #expect(f.store.chat.contains { $0.kind == .user("첫 프로젝트 메시지") })
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }
    @Test func submittedProjectReplyPersistsThroughOMPFramesAndRecreation() async throws {
        let f = try await LiveFixture.make()
        let suite = "knarr-project-reply-\(UUID())"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let rpc = LiveTestRPC()
        f.store.setThreadFactory { thread in
            LiveConversation(repository: f.repository,
                session: StallariSession(repository: f.repository, rpc: rpc, hird: f.hird, threadID: thread.id),
                rpc: rpc, hird: f.hird, threadID: thread.id, preferences: preferences)
        }
        do {
            f.store.selectProjectConversation("p")
            try await f.store.submit(.init(text: "프로젝트 답변을 저장해 주세요", project: "p"))
            let threadID = f.store.selectedThreadID
            let promptID = try #require(await rpc.promptIDs.last)
            await rpc.frame(.object(["type": .string("message_update"), "messageId": .string("project-reply"),
                "message": .object(["role": .string("assistant")]),
                "assistantMessageEvent": .object(["type": .string("text_delta"), "contentIndex": .number(0), "delta": .string("프로젝트에 남길 답변")])]))
            await rpc.frame(.object(["type": .string("message_end"), "messageId": .string("project-reply"),
                "message": .object(["role": .string("assistant"), "content": .array([
                    .object(["type": .string("text"), "text": .string("프로젝트에 남길 답변")])])])]))
            await rpc.frame(.object(["type": .string("prompt_result"), "id": .string(promptID), "status": .string("completed")]))
            for _ in 0..<200 {
                if !f.store.isResponding { break }
                try await Task.sleep(for: .milliseconds(5))
            }
            try await f.store.whenIdle()
            #expect(!f.store.isResponding)
            let snapshot = try await f.repository.snapshot()
            let reply = try #require(snapshot.chat.first { $0.kind == .stallari("프로젝트에 남길 답변", project: nil) })
            let link = try #require(snapshot.chatLinks.first { $0.chatID == reply.id })
            #expect(link.projectID == "p" && link.conversationThreadID == threadID && link.issueID == nil)
            let reopenedRPC = LiveTestRPC()
            let restored = LiveKnarrStore(repository: f.repository,
                session: StallariSession(repository: f.repository, rpc: reopenedRPC, hird: f.hird),
                rpc: reopenedRPC, hird: f.hird, preferences: preferences, subscriptionUsage: .init(sample: true))
            do {
                try await restored.connect()
                restored.selectProjectConversation("p")
                try await restored.whenIdle()
                #expect(restored.chat.filter { $0.id == reply.id } == [reply])
                #expect(await reopenedRPC.prompts.isEmpty)
                _ = await restored.shutdown()
            } catch { _ = await restored.shutdown(); throw error }
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }
    @Test func restoredProjectSelectionShowsSavedChatAndDraftWithoutStartingRPC() async throws {
        let f = try await LiveFixture.make()
        let suite = "knarr-project-restored-\(UUID())"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let thread = try await f.repository.createProjectConversation(projectID: "p")
        try await f.repository.appendChat(.init(at: .now, kind: .user("저장된 프로젝트 메시지")), projectID: "p", threadID: thread.id)
        preferences.set(thread.id, forKey: "knarr.selectedThread")
        preferences.set(try JSONEncoder().encode(ChatDraft(text: "저장된 초안", project: "p")), forKey: "knarr.draft." + thread.id)
        let rpc = LiveTestRPC()
        let store = LiveKnarrStore(repository: f.repository,
            session: StallariSession(repository: f.repository, rpc: rpc, hird: f.hird),
            rpc: rpc, hird: f.hird, preferences: preferences, subscriptionUsage: .init(sample: true))
        var opened: [String] = []
        store.setThreadFactory { thread in
            opened.append(thread.id)
            let rpc = LiveTestRPC()
            return LiveConversation(repository: f.repository,
                session: StallariSession(repository: f.repository, rpc: rpc, hird: f.hird, threadID: thread.id),
                rpc: rpc, hird: f.hird, threadID: thread.id, preferences: preferences)
        }
        do {
            try await store.connect()
            try await store.whenIdle()
            #expect(store.selectedThreadID == thread.id && opened.isEmpty)
            #expect(store.chat.contains { $0.kind == .user("저장된 프로젝트 메시지") })
            #expect(store.composerDraft == .init(text: "저장된 초안", project: "p"))
            #expect(store.conversationTabs.filter { $0.projectID == "p" } == [thread])
            store.selectThread(ConversationThread.defaultID)
            store.selectProjectConversation("p")
            try await store.whenIdle()
            #expect(opened.isEmpty)
            _ = await store.shutdown(); try await f.cleanup()
        } catch { _ = await store.shutdown(); try await f.cleanup(); throw error }
    }
    @Test func archivedTabsStayReadableAndMissingSelectionFallsBackWithoutStartingRPC() async throws {
        let f = try await LiveFixture.make()
        do {
            let thread = try await f.repository.createProjectConversation(projectID: "p", threadID: "removed-project-tab")
            try await f.store.whenIdle()
            f.store.selectThread(thread.id)
            f.store.composerDraft.text = "삭제 전 초안"
            f.store.setProjectArchived("p", true)
            try await f.store.whenIdle()
            #expect(f.store.selectedThreadID == thread.id)
            #expect(f.store.conversationTabs.contains { $0.id == thread.id })
            let writer = try SQLiteConnection(path: f.directory.appendingPathComponent("knarr.db").path, flags: 2)
            // Isolated fixture-only removal; no production deletion API or migration.
            try writer.execute("DELETE FROM threads WHERE id=?", [thread.id])
            try writer.close()
            try await f.store.whenIdle()
            #expect(f.store.selectedThreadID == ConversationThread.defaultID)
            #expect(!f.store.conversationTabs.contains { $0.id == thread.id })
            #expect(await f.rpc.prompts.isEmpty)
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }
}
