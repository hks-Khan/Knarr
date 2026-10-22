import Foundation
import Testing
@testable import KnarrCore

/// The top tab bar reads one judgment per thread: a Stallari response anywhere, a Hird bound to the
/// thread's issue, or a question waiting on the person. Selection must not change the answer.
@MainActor @Suite(.serialized) struct ThreadWorkingTests {
    @Test func unselectedThreadResponseCountsAsWorking() async throws {
        let f = try await LiveFixture.make()
        let childRPC = LiveTestRPC()
        f.store.setThreadFactory { thread in
            LiveConversation(repository: f.repository,
                session: StallariSession(repository: f.repository, rpc: childRPC, hird: f.hird, threadID: thread.id),
                rpc: childRPC, hird: f.hird, threadID: thread.id,
                preferences: UserDefaults(suiteName: "knarr-working-thread-\(UUID())")!)
        }
        do {
            f.store.createThread(name: "응답 중")
            try await f.store.whenIdle()
            let second = try #require(f.store.threads.first { $0.name == "응답 중" })
            try await f.store.submit(.init(text: "둘째 스레드 질문"))
            #expect(f.store.isThreadWorking(second.id))
            f.store.selectThread(ConversationThread.defaultID)
            try await f.store.whenIdle()
            #expect(f.store.selectedThreadID == ConversationThread.defaultID)
            #expect(f.store.isThreadWorking(second.id))
            #expect(!f.store.isThreadWorking(ConversationThread.defaultID))
            try await f.cleanup()
        } catch { _ = await f.store.shutdown(); try await f.cleanup(); throw error }
    }

    @Test func issueThreadWithRunningHirdCountsAsWorking() async throws {
        let f = try await LiveFixture.make()
        do {
            _ = try await f.session.createIssue(id: "worker", title: "실행 중인 작업", criteria: ["검사"],
                                                instruction: "검사", projectID: "p")
            let issue = try #require(try await f.repository.snapshot().issues.first { $0.id == "worker" })
            let threadID = issue.conversationThreadID
            #expect(threadID != ConversationThread.defaultID)
            #expect(!f.store.isThreadWorking(threadID))
            try await f.dispatch("r", issue: "worker")
            try await f.store.whenIdle()
            #expect(f.store.issues.first { $0.id == "worker" }?.hasActiveHird == true)
            #expect(f.store.isThreadWorking(threadID))
            #expect(!f.store.isThreadWorking(ConversationThread.defaultID))
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }

    @Test func pendingQuestionThreadCountsAsWorking() {
        let asking = SampleKnarrStore(issueSessionScene: .question)
        #expect(asking.isThreadWorking("issue-testflight"))
        #expect(!asking.isThreadWorking(ConversationThread.defaultID))
        #expect(!asking.isThreadWorking("missing-thread"))
    }

    @Test func idleIssueThreadAndIdleWorkspaceAreNotWorking() {
        let idle = SampleKnarrStore(issueSessionScene: .approval)
        #expect(!idle.isThreadWorking("issue-session-proposal"))
        // A finished run binds only its own issue thread; the main thread stays idle.
        let finished = SampleKnarrStore(issueSessionScene: .completed)
        #expect(!finished.isThreadWorking(ConversationThread.defaultID))
        #expect(!finished.isThreadWorking("issue-dark-mode"))
    }
}
