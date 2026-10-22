import AppKit
import Foundation
import Testing
@testable import KnarrCore

@MainActor @Suite(.serialized) struct ClearConversationTests {
    @Test func clearCreatesFreshModelSessionWithoutPromptAndPreservesRecords() async throws {
        let f = try await LiveFixture.make()
        do {
            try await f.create()
            try await f.dispatch()
            let old = ChatItem(at: .now, kind: .user("보존할 이전 대화"))
            try await f.repository.appendChat(old, projectID: "p")
            let before = try await f.repository.snapshot()
            let sessionID = await f.rpc.sessionID
            f.store.composerDraft = .init(text: " /clear ", project: "p")
            try await f.store.submit(f.store.composerDraft)
            try await f.store.whenIdle()
            #expect(await f.rpc.sessionID != sessionID)
            #expect(await f.rpc.requests.filter { $0.0 == "new_session" }.count == 1)
            #expect(await f.rpc.prompts.isEmpty)
            let after = try await f.repository.snapshot()
            #expect(after.chat.contains { $0.id == old.id && $0.kind == old.kind })
            #expect(after.projects.map(\.id) == before.projects.map(\.id))
            #expect(after.issues.map(\.id) == before.issues.map(\.id))
            #expect(after.runs.map(\.id) == before.runs.map(\.id))
            #expect(after.threads.map(\.id) == before.threads.map(\.id))
            #expect(await f.hird.cancelled.isEmpty)
            #expect(!f.store.isResponding)
            #expect(!f.store.isSubmitting)
            #expect(f.store.failedDraft == nil)
            #expect(f.store.composerDraft.isEmpty)
            #expect(f.store.chat.contains { if case .stallari(let text, _) = $0.kind { text.contains("문맥을 초기화했어요") } else { false } })
            try await f.store.submit(.init(text: "새 질문", project: "p"))
            #expect(await f.rpc.prompts.count == 1)
            #expect(await f.rpc.prompts.last?["message"]?.string?.contains("새 질문") == true)
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }

    @Test func clearRefusesWhileReplyIsActiveAndPreservesSession() async throws {
        let f = try await LiveFixture.make()
        do {
            try await f.store.submit(.init(text: "진행 중", project: "p"))
            let sessionID = await f.rpc.sessionID
            await #expect(throws: (any Error).self) { try await f.store.submit(.init(text: "/clear")) }
            #expect(await f.rpc.sessionID == sessionID)
            #expect(await f.rpc.prompts.count == 1)
            #expect(await f.rpc.requests.allSatisfy { $0.0 != "new_session" })
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }

    @Test func cancelledResetNeverReportsSuccessOrSendsCommandToModel() async throws {
        let f = try await LiveFixture.make()
        do {
            await f.rpc.setCancelNewSession()
            let sessionID = await f.rpc.sessionID
            await #expect(throws: (any Error).self) { try await f.store.submit(.init(text: "/clear")) }
            #expect(await f.rpc.sessionID == sessionID)
            #expect(await f.rpc.prompts.isEmpty)
            #expect(!f.store.isResponding)
            #expect(!f.store.isSubmitting)
            #expect(!f.store.chat.contains { if case .stallari(let text, _) = $0.kind { text.contains("문맥을 초기화했어요") } else { false } })
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }

    @Test func inlineMentionIsNormalTextButAttachmentsAndFocusedClearAreRejected() async throws {
        let f = try await LiveFixture.make()
        do {
            await #expect(throws: (any Error).self) {
                try await f.store.submit(.init(text: "/clear", attachments: [f.directory.appendingPathComponent("missing.png")]))
            }
            await #expect(throws: (any Error).self) {
                try await f.store.startMessageConversation(.init(text: "/clear"))
            }
            #expect(await f.rpc.requests.allSatisfy { $0.0 != "new_session" })
            #expect(await f.rpc.prompts.isEmpty)
            try await f.store.submit(.init(text: "/clear 사용법 알려줘", project: "p"))
            #expect(await f.rpc.prompts.count == 1)
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }
    @Test(.enabled(if: KnarrUITests.enabled)) func clearRecoversFailedDraftAndRendersPreservedHistory() async throws {
        let f = try await LiveFixture.make()
        let suite = "knarr-clear-web-" + UUID().uuidString
        let prefs = try #require(UserDefaults(suiteName: suite))
        defer { prefs.removePersistentDomain(forName: suite) }
        var harness: WebChatHarness?
        do {
            try await f.store.submit(.init(text: "내 프로젝트에서 오늘 해야 할 일이 뭐가 있어요?", project: "p"))
            let id = try #require(await f.rpc.promptIDs.last)
            await f.store.observe(frame: .object(["type": .string("prompt_result"), "id": .string(id), "status": .string("error")]))
            #expect(f.store.failedDraft != nil)
            let prompts = await f.rpc.prompts.count
            try await f.store.submit(.init(text: "/clear"))
            #expect(f.store.failedDraft == nil)
            #expect(await f.rpc.prompts.count == prompts)
            let h = WebChatHarness(store: f.store, defaults: prefs)
            harness = h
            h.window.setContentSize(NSSize(width: 900, height: 500))
            try await h.wait("document.body.textContent.includes('문맥을 초기화했어요') && document.body.textContent.includes('오늘 해야 할 일')")
            try await h.screenshot("clear-context-preserved-history")
            h.close(); harness = nil
            try await f.cleanup()
        } catch { harness?.close(); try await f.cleanup(); throw error }
    }

    @Test func runtimeBusyWithoutVisibleResponseStillRefusesReset() async throws {
        let f = try await LiveFixture.make()
        do {
            await f.rpc.setBusy()
            await #expect(throws: (any Error).self) { try await f.store.submit(.init(text: "/clear")) }
            #expect(await f.rpc.requests.allSatisfy { $0.0 != "new_session" })
            #expect(await f.rpc.prompts.isEmpty)
            #expect(!f.store.isSubmitting)
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }

}
