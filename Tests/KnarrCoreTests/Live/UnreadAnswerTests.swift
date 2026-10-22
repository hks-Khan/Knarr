import Foundation
import Testing
@testable import KnarrCore

/// A tab's badge counts answers the person has not seen, per conversation. It must survive an
/// unselected tab, streaming, scrolling away, a background app and a relaunch, and must not treat
/// existing history as new.
@MainActor @Suite(.serialized) struct UnreadAnswerTests {
    private func suite() -> (String, UserDefaults) {
        let name = "knarr-unread-\(UUID())"
        return (name, UserDefaults(suiteName: name)!)
    }

    /// A store over the shared fixture repository, with its own preferences so a relaunch is exact.
    private func makeStore(_ f: LiveFixture, preferences: UserDefaults,
                           rpc: LiveTestRPC = LiveTestRPC()) -> LiveKnarrStore {
        let store = LiveKnarrStore(repository: f.repository,
            session: StallariSession(repository: f.repository, rpc: rpc, hird: f.hird),
            rpc: rpc, hird: f.hird, preferences: preferences, subscriptionUsage: .init(sample: true))
        store.setThreadFactory { thread in
            let child = LiveTestRPC()
            return LiveConversation(repository: f.repository,
                session: StallariSession(repository: f.repository, rpc: child, hird: f.hird, threadID: thread.id),
                rpc: child, hird: f.hird, threadID: thread.id, preferences: preferences)
        }
        return store
    }

    @Test func newConversationUnreadSurvivesRestartBeforeItIsRead() async throws {
        let f = try await LiveFixture.make()
        let (name, preferences) = suite()
        defer { preferences.removePersistentDomain(forName: name) }
        let first = makeStore(f, preferences: preferences)
        var second: LiveKnarrStore?
        do {
            try await first.connect()
            let thread = try await projectTab(f, project: "p", thread: "created-after-baseline")
            try await first.whenIdle()
            try await f.repository.appendChat(.init(at: .now, kind: .stallari("아직 읽지 않은 새 답변", project: nil)),
                                              projectID: "p", threadID: thread.id)
            try await first.whenIdle()
            #expect(first.unreadAnswerCount(forThread: thread.id) == 1)
            _ = await first.shutdown()
            let reopened = makeStore(f, preferences: preferences); second = reopened
            try await reopened.connect()
            #expect(reopened.unreadAnswerCount(forThread: thread.id) == 1)
            _ = await reopened.shutdown()
            try await f.cleanup()
        } catch { _ = await first.shutdown(); _ = await second?.shutdown(); try await f.cleanup(); throw error }
    }

    private func delta(_ text: String, id: String = "msg-1") -> OMPJSON {
        .object(["type": .string("message_update"), "messageId": .string(id),
                 "message": .object(["role": .string("assistant")]),
                 "assistantMessageEvent": .object(["type": .string("text_delta"), "contentIndex": .number(0), "delta": .string(text)])])
    }
    private func end(_ text: String, id: String = "msg-1") -> OMPJSON {
        .object(["type": .string("message_end"), "messageId": .string(id), "message": .object([
            "role": .string("assistant"), "content": .array([.object(["type": .string("text"), "text": .string(text)])])])])
    }

    private func projectTab(_ f: LiveFixture, project: String, thread: String) async throws -> ConversationThread {
        try await f.repository.createProjectConversation(projectID: project, threadID: thread)
    }

    /// Two project tabs and the main conversation: an answer in an unselected project tab is
    /// counted there and nowhere else, and selecting the tab does not clear it.
    @Test func unselectedProjectAnswerCountsOnItsOwnTabOnly() async throws {
        let f = try await LiveFixture.make()
        let (name, preferences) = suite()
        defer { preferences.removePersistentDomain(forName: name) }
        let store = makeStore(f, preferences: preferences)
        do {
            let a = try await projectTab(f, project: "p", thread: "unread-a")
            let b = try await projectTab(f, project: "other", thread: "unread-b")
            try await store.connect()
            #expect(store.unreadAnswerCount(forThread: ConversationThread.defaultID) == 0)
            #expect(store.unreadAnswerCount(forThread: a.id) == 0)
            #expect(store.unreadAnswerCount(forThread: b.id) == 0)

            try await f.repository.appendChat(.init(at: .now, kind: .stallari("A 프로젝트 답변", project: nil)),
                                             projectID: "p", threadID: a.id)
            try await store.whenIdle()
            #expect(store.unreadAnswerCount(forThread: a.id) == 1)
            #expect(store.unreadAnswerCount(forThread: b.id) == 0)
            #expect(store.unreadAnswerCount(forThread: ConversationThread.defaultID) == 0)

            store.selectThread(a.id)
            try await store.whenIdle()
            #expect(store.selectedThreadID == a.id)
            // Selecting is not reading: only a viewport report clears the count.
            #expect(store.unreadAnswerCount(forThread: a.id) == 1)

            let answer = try #require(store.chat.first { UnreadAnswers.isCountable($0) })
            store.markAnswersRead([answer.id], threadID: a.id)
            #expect(store.unreadAnswerCount(forThread: a.id) == 0)

            try await f.repository.appendChat(.init(at: .now, kind: .stallari("B 프로젝트 답변", project: nil)),
                                              projectID: "other", threadID: b.id)
            try await store.whenIdle()
            #expect(store.unreadAnswerCount(forThread: b.id) == 1)
            #expect(store.unreadAnswerCount(forThread: a.id) == 0)
            #expect((await store.shutdown()).remainingProcessIDs.isEmpty)
            try await f.cleanup()
        } catch { _ = await store.shutdown(); try await f.cleanup(); throw error }
    }

    /// One streamed answer stays one answer across every delta and its commit, and text that grows
    /// after it was read does not make it unread again.
    @Test func streamingAnswerCountsOnceAndStaysReadWhileGrowing() async throws {
        let f = try await LiveFixture.make()
        let (name, preferences) = suite()
        defer { preferences.removePersistentDomain(forName: name) }
        let store = makeStore(f, preferences: preferences)
        do {
            try await store.connect()
            await store.observe(frame: delta("첫 문장"))
            let id = try #require(store.streamingMessageID)
            #expect(store.unreadAnswerCount(forThread: ConversationThread.defaultID) == 1)
            await store.observe(frame: delta("이어지는 문장"))
            #expect(store.unreadAnswerCount(forThread: ConversationThread.defaultID) == 1)

            // The person is at the answer while it streams.
            store.markAnswersRead([id], threadID: ConversationThread.defaultID)
            #expect(store.unreadAnswerCount(forThread: ConversationThread.defaultID) == 0)
            await store.observe(frame: delta(" 더 붙는 문장"))
            #expect(store.unreadAnswerCount(forThread: ConversationThread.defaultID) == 0)

            await store.observe(frame: end("첫 문장이어지는 문장 더 붙는 문장"))
            try await store.whenIdle()
            #expect(store.unreadAnswerCount(forThread: ConversationThread.defaultID) == 0)
            #expect(store.chat.filter { UnreadAnswers.isCountable($0) }.count == 1)
            // Tool and reasoning rows are not answers.
            await store.observe(frame: .object(["type": .string("tool_execution_start"),
                "toolCallId": .string("call-1"), "toolName": .string("read"), "args": .object([:])]))
            try await store.whenIdle()
            #expect(store.unreadAnswerCount(forThread: ConversationThread.defaultID) == 0)
            #expect((await store.shutdown()).remainingProcessIDs.isEmpty)
            try await f.cleanup()
        } catch { _ = await store.shutdown(); try await f.cleanup(); throw error }
    }

    /// Reading a newer answer while an older one is off screen keeps the older one unread.
    @Test func olderAnswerStaysUnreadWhenANewerOneIsSeen() async throws {
        let f = try await LiveFixture.make()
        let (name, preferences) = suite()
        defer { preferences.removePersistentDomain(forName: name) }
        let store = makeStore(f, preferences: preferences)
        do {
            let thread = try await projectTab(f, project: "p", thread: "unread-gap")
            try await store.connect()
            let first = ChatItem(at: .now.addingTimeInterval(-60), kind: .stallari("먼저 온 답변", project: nil))
            let second = ChatItem(at: .now, kind: .stallari("나중에 온 답변", project: nil))
            try await f.repository.appendChat(first, projectID: "p", threadID: thread.id)
            try await f.repository.appendChat(second, projectID: "p", threadID: thread.id)
            try await store.whenIdle()
            #expect(store.unreadAnswerCount(forThread: thread.id) == 2)
            store.selectThread(thread.id)
            try await store.whenIdle()

            store.markAnswersRead([second.id], threadID: thread.id)
            #expect(store.unreadAnswerCount(forThread: thread.id) == 1)
            store.markAnswersRead([first.id], threadID: thread.id)
            #expect(store.unreadAnswerCount(forThread: thread.id) == 0)
            #expect((await store.shutdown()).remainingProcessIDs.isEmpty)
            try await f.cleanup()
        } catch { _ = await store.shutdown(); try await f.cleanup(); throw error }
    }

    /// A background app keeps the count; the same ids clear once the app is active again.
    @Test func inactiveAppKeepsAnswersUnread() async throws {
        let f = try await LiveFixture.make()
        let (name, preferences) = suite()
        defer { preferences.removePersistentDomain(forName: name) }
        let store = makeStore(f, preferences: preferences)
        do {
            let thread = try await projectTab(f, project: "p", thread: "unread-background")
            try await store.connect()
            try await f.repository.appendChat(.init(at: .now, kind: .stallari("자리를 비운 사이 온 답변", project: nil)),
                                              projectID: "p", threadID: thread.id)
            try await store.whenIdle()
            store.selectThread(thread.id)
            let answer = try #require(store.chat.first { UnreadAnswers.isCountable($0) })
            store.setAppActive(false)
            store.markAnswersRead([answer.id], threadID: thread.id)
            #expect(store.unreadAnswerCount(forThread: thread.id) == 1)
            store.setAppActive(true)
            store.markAnswersRead([answer.id], threadID: thread.id)
            #expect(store.unreadAnswerCount(forThread: thread.id) == 0)
            #expect((await store.shutdown()).remainingProcessIDs.isEmpty)
            try await f.cleanup()
        } catch { _ = await store.shutdown(); try await f.cleanup(); throw error }
    }

    /// Existing history is the baseline; only answers after the first run are new. The read marks
    /// and the count both survive a relaunch.
    @Test func existingHistoryIsBaselinedAndReadMarksSurviveRelaunch() async throws {
        let f = try await LiveFixture.make()
        let (name, preferences) = suite()
        defer { preferences.removePersistentDomain(forName: name) }
        do {
            let thread = try await projectTab(f, project: "p", thread: "unread-relaunch")
            try await f.repository.appendChat(.init(at: .now.addingTimeInterval(-600), kind: .stallari("예전 답변", project: nil)),
                                              projectID: "p", threadID: thread.id)
            let first = makeStore(f, preferences: preferences)
            try await first.connect()
            #expect(first.unreadAnswerCount(forThread: thread.id) == 0, "History before the feature must not become unread")
            try await f.repository.appendChat(.init(at: .now, kind: .stallari("새 답변", project: nil)),
                                              projectID: "p", threadID: thread.id)
            try await first.whenIdle()
            #expect(first.unreadAnswerCount(forThread: thread.id) == 1)
            first.selectThread(thread.id)
            try await first.whenIdle()
            let answer = try #require(first.chat.last { UnreadAnswers.isCountable($0) })
            first.markAnswersRead([answer.id], threadID: thread.id)
            #expect(first.unreadAnswerCount(forThread: thread.id) == 0)
            #expect((await first.shutdown()).remainingProcessIDs.isEmpty)

            // An answer that arrives while the app is closed is new on the next launch.
            try await f.repository.appendChat(.init(at: .now.addingTimeInterval(1), kind: .stallari("다시 실행 뒤 답변", project: nil)),
                                              projectID: "p", threadID: thread.id)
            let second = makeStore(f, preferences: preferences)
            try await second.connect()
            #expect(second.unreadAnswerCount(forThread: thread.id) == 1)
            #expect((await second.shutdown()).remainingProcessIDs.isEmpty)
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }

    /// The count is a tab fact, so an issue conversation never joins it even after its own answer.
    @Test func issueConversationsAreExcludedFromTabCounts() async throws {
        let f = try await LiveFixture.make()
        let (name, preferences) = suite()
        defer { preferences.removePersistentDomain(forName: name) }
        let rpc = LiveTestRPC()
        let store = LiveKnarrStore(repository: f.repository, session: f.session, rpc: rpc, hird: f.hird,
                                   preferences: preferences, subscriptionUsage: .init(sample: true))
        store.setThreadFactory { thread in
            let child = LiveTestRPC()
            return LiveConversation(repository: f.repository,
                session: StallariSession(repository: f.repository, rpc: child, hird: f.hird, threadID: thread.id),
                rpc: child, hird: f.hird, threadID: thread.id, preferences: preferences)
        }
        do {
            try await store.connect()
            _ = try await f.session.createIssue(id: "unread-issue", title: "배지 제외", criteria: ["검사"],
                                                instruction: "검사", projectID: "p")
            try await f.dispatch("r", issue: "unread-issue")
            let issue = try #require(try await f.repository.snapshot().issues.first { $0.id == "unread-issue" })
            store.goToThread(for: issue.id)
            try await store.whenIdle()
            try await f.repository.appendChat(.init(at: .now, kind: .stallari("이슈 대화 답변", project: nil)),
                                              projectID: "p", issueID: issue.id, runID: "r", threadID: issue.conversationThreadID)
            store.selectThread(issue.conversationThreadID)
            try await store.whenIdle()
            #expect(store.chat.contains { $0.kind == .stallari("이슈 대화 답변", project: nil) })
            #expect(store.unreadAnswerCount(forThread: issue.conversationThreadID) == 0)
            #expect((await store.shutdown()).remainingProcessIDs.isEmpty)
            try await f.cleanup()
        } catch { _ = await store.shutdown(); try await f.cleanup(); throw error }
    }

    /// The thresholds are presentation-only: the exact number always reaches accessibility.
    @Test func badgeTextCapsAtNinetyNinePlus() {
        #expect(UnreadAnswers.badgeText(1) == "1")
        #expect(UnreadAnswers.badgeText(99) == "99")
        #expect(UnreadAnswers.badgeText(100) == "99+")
        #expect(UnreadAnswers.badgeText(4_321) == "99+")
    }

    /// A ledger collapses a contiguous read prefix into one boundary and keeps gaps as ids.
    @Test func ledgerBaselinesHistoryAndPreservesGaps() {
        let older = UnreadAnswer(id: UUID(), at: .now.addingTimeInterval(-100))
        let newer = UnreadAnswer(id: UUID(), at: .now)
        var ledger = UnreadAnswerLedger(baselining: [older])
        #expect(ledger.isRead(older))
        #expect(!ledger.isRead(newer))
        ledger.markRead([newer], among: [older, newer])
        #expect(ledger.isRead(newer))
        #expect(ledger.readMarks.map(\.id) == [newer.id], "Only the tie at the boundary stays as an id")

        var gap = UnreadAnswerLedger()
        gap.markRead([newer], among: [older, newer])
        #expect(gap.isRead(newer))
        #expect(!gap.isRead(older), "A newer answer must not read an older off-screen one")
        #expect(gap.readThrough == .distantPast)
    }

    /// Only assistant rows of the tab itself are answers.
    @Test func countablePolicyExcludesToolsUsersAndFocusedAnswers() {
        let root = UUID()
        var focused = ChatItem(at: .now, kind: .stallari("집중 대화의 답변", project: nil))
        focused.conversationRootID = root
        var tool = ChatItem(at: .now, kind: .stallari("도구 실행", project: nil))
        tool.activity = .init(kind: .tool, title: "파일 읽기")
        var link = ChatItem(at: .now, kind: .stallari("대화 링크", project: nil))
        link.isConversationLink = true
        #expect(UnreadAnswers.isCountable(.init(at: .now, kind: .stallari("답변", project: nil))))
        #expect(!UnreadAnswers.isCountable(.init(at: .now, kind: .stallari("  \n", project: nil))))
        #expect(!UnreadAnswers.isCountable(.init(at: .now, kind: .user("질문"))))
        #expect(!UnreadAnswers.isCountable(.init(at: .now, kind: .day("오늘"))))
        #expect(!UnreadAnswers.isCountable(focused))
        #expect(!UnreadAnswers.isCountable(tool))
        #expect(!UnreadAnswers.isCountable(link))
    }
}
