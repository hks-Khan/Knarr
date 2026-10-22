import Foundation
import Testing
@testable import KnarrCore
@testable import KnarrUI

/// A canvas stop must cancel only the conversation whose answer is the one actually running. The
/// session has a single prompt in flight and `stopResponse()` also drops every queued draft, so a
/// canvas whose root is merely *waiting* must not be able to abort the main answer or a sibling's
/// queued reply. These checks drive the live store and the bridge together.
@MainActor @Suite(.serialized) struct MessageConversationStopTests {
    private func event(_ bridge: ChatWebBridge, _ store: any KnarrStore, root: UUID) -> OMPJSON {
        .object(["session": .string(bridge.session), "thread": .string(store.selectedThreadID),
                 "message": .string(root.uuidString), "action": .string("canvasStop")])
    }
    private func finish(_ store: LiveKnarrStore, _ id: String) async {
        await store.observe(frame: .object(["type": .string("prompt_result"), "id": .string(id), "status": .string("success")]))
    }
    /// Runs the canvas stop the way the transcript does: the bridge admits the event, then re-checks
    /// identity and only then stops. This is the same sequence `ChatWebView` uses.
    private func canvasStop(_ bridge: ChatWebBridge, _ store: LiveKnarrStore, root: UUID) -> Bool {
        let thread = store.selectedThreadID, session = bridge.session
        guard case .canvasStop(let admitted) = bridge.command(event(bridge, store, root: root), store: store),
              admitted == root else { return false }
        return bridge.stop(root, store: store, thread: thread, session: session)
    }
    private func linked(_ f: LiveFixture, _ text: String) async throws -> UUID {
        let root = try await f.store.startMessageConversation(.init(text: text, project: "p"))
        let id = try #require(await f.rpc.promptIDs.last)
        await finish(f.store, id)
        try await f.store.whenIdle()
        return root
    }
    private func waitForRoot(_ store: LiveKnarrStore, _ root: UUID) async throws {
        for _ in 0..<400 where !store.respondingConversationRoots.contains(root) {
            try await Task.sleep(for: .milliseconds(5))
        }
    }
    private func waitForPrompts(_ f: LiveFixture, _ count: Int) async throws {
        for _ in 0..<400 where await f.rpc.promptIDs.count < count {
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test func queuedCanvasReplyCannotStopTheMainAnswer() async throws {
        let f = try await LiveFixture.make()
        let bridge = ChatWebBridge()
        var queued: Task<Void, Error>?
        do {
            let root = try await linked(f, "대기할 대화")
            try await f.store.submit(.init(text: "메인 진행 중", project: "p"))
            let main = try #require(await f.rpc.promptIDs.last)
            queued = Task { try await f.store.submit(.init(text: "대화 후속 답장", project: "p", conversationRootID: root)) }
            try await waitForRoot(f.store, root)
            // The canvas shows this root as waiting; its stop must not reach the main answer.
            #expect(!canvasStop(bridge, f.store, root: root))
            #expect(!f.store.isStopping)
            #expect(await !f.rpc.requests.contains { $0.0 == "abort" })
            await finish(f.store, main)
            // The queued reply is still delivered, not discarded with the queue.
            try await waitForPrompts(f, 3)
            #expect(await f.rpc.prompts.contains { $0["message"]?.string?.contains("conversationRootID=\"\(root.uuidString)\"") == true })
            try await queued?.value
            try await f.cleanup()
        } catch {
            queued?.cancel(); try? await f.cleanup(); throw error
        }
    }

    @Test func waitingReplyElsewhereDoesNotMakeItsRootStoppable() async throws {
        let f = try await LiveFixture.make()
        let bridge = ChatWebBridge()
        var queued: Task<Void, Error>?
        do {
            let active = try await linked(f, "먼저 답할 대화")
            let waiting = try await linked(f, "뒤에 답할 대화")
            try await f.store.submit(.init(text: "먼저 답할 대화 후속", project: "p", conversationRootID: active))
            let firstID = try #require(await f.rpc.promptIDs.last)
            queued = Task { try await f.store.submit(.init(text: "뒤에 답할 대화 후속", project: "p", conversationRootID: waiting)) }
            try await waitForRoot(f.store, waiting)
            // Another root's reply is queued behind this answer, so the answer is shared, not this root's.
            #expect(!canvasStop(bridge, f.store, root: active))
            #expect(await !f.rpc.requests.contains { $0.0 == "abort" })
            await finish(f.store, firstID)
            try await waitForPrompts(f, 3)
            #expect(await f.rpc.prompts.last?["message"]?.string?.contains("conversationRootID=\"\(waiting.uuidString)\"") == true)
            try await queued?.value
            try await f.cleanup()
        } catch {
            queued?.cancel(); try? await f.cleanup(); throw error
        }
    }

    @Test func staleRootThreadOrSessionCannotStopANewerAnswer() async throws {
        let f = try await LiveFixture.make()
        let bridge = ChatWebBridge()
        do {
            let first = try await linked(f, "먼저 답할 대화")
            let second = try await linked(f, "뒤에 답할 대화")
            try await f.store.submit(.init(text: "먼저 답할 대화 후속", project: "p", conversationRootID: first))
            let firstID = try #require(await f.rpc.promptIDs.last)
            let thread = f.store.selectedThreadID, session = bridge.session
            #expect(f.store.stopBlockReason(for: first) == nil)
            // The answer ends and a different root starts before the admitted action runs.
            await finish(f.store, firstID)
            try await f.store.submit(.init(text: "뒤에 답할 대화 후속", project: "p", conversationRootID: second))
            let secondID = try #require(await f.rpc.promptIDs.last)
            #expect(bridge.stop(first, store: f.store, thread: thread, session: session) == false)
            #expect(bridge.stop(second, store: f.store, thread: thread, session: "stale") == false)
            #expect(bridge.stop(second, store: f.store, thread: "other-thread", session: session) == false)
            #expect(await !f.rpc.requests.contains { $0.0 == "abort" })
            #expect(f.store.isResponding)
            // The current root is still the one a fresh event may stop.
            #expect(bridge.stop(second, store: f.store, thread: thread, session: session))
            for _ in 0..<400 where await !f.rpc.requests.contains(where: { $0.0 == "abort" }) {
                try await Task.sleep(for: .milliseconds(5))
            }
            #expect(await f.rpc.requests.contains { $0.0 == "abort" })
            await finish(f.store, secondID)
            try await f.store.whenIdle()
            #expect(f.store.stopBlockReason(for: second) == nil)
            try await f.cleanup()
        } catch {
            try? await f.cleanup(); throw error
        }
    }

    @Test func stopReasonAppearsOnlyForAnAnswerThatCannotBeStoppedAlone() async throws {
        let f = try await LiveFixture.make()
        var queued: Task<Void, Error>?
        do {
            let active = try await linked(f, "이유를 확인할 대화")
            let sibling = try await linked(f, "뒤에 답할 대화")
            // A quiet root has no reason: nothing is running for it.
            #expect(f.store.stopBlockReason(for: active) == nil)
            try await f.store.submit(.init(text: "이유를 확인할 대화 후속", project: "p", conversationRootID: active))
            let firstID = try #require(await f.rpc.promptIDs.last)
            // Alone, this root can be stopped, so there is no reason to show.
            #expect(f.store.stoppableConversationRoots.contains(active))
            #expect(f.store.stopBlockReason(for: active) == nil)
            queued = Task { try await f.store.submit(.init(text: "뒤에 답할 대화 후속", project: "p", conversationRootID: sibling)) }
            try await waitForRoot(f.store, sibling)
            // A queued sibling makes the shared answer unstoppable, and the canvas gets the reason.
            #expect(!f.store.stoppableConversationRoots.contains(active))
            #expect(f.store.stopBlockReason(for: active)?.contains("대기") == true)
            await finish(f.store, firstID)
            try await waitForPrompts(f, 3)
            // The reason disappears as soon as its root is no longer the one answering.
            #expect(f.store.stopBlockReason(for: active) == nil)
            let next = try #require(await f.rpc.promptIDs.last)
            await finish(f.store, next)
            try await f.store.whenIdle()
            try await queued?.value
            #expect(f.store.stopBlockReason(for: sibling) == nil)
            try await f.cleanup()
        } catch {
            queued?.cancel(); try? await f.cleanup(); throw error
        }
    }

    @Test func loneRunningRootStillStopsAndLaterAnswersAreNotAborted() async throws {
        let f = try await LiveFixture.make()
        let bridge = ChatWebBridge()
        do {
            let active = try await linked(f, "혼자 답할 대화")
            let later = try await linked(f, "다음 대화")
            try await f.store.submit(.init(text: "혼자 답할 대화 후속", project: "p", conversationRootID: active))
            let firstID = try #require(await f.rpc.promptIDs.last)
            // The only in-flight answer belongs to this root, so its canvas can stop it.
            #expect(canvasStop(bridge, f.store, root: active))
            for _ in 0..<400 where await !f.rpc.requests.contains(where: { $0.0 == "abort" }) {
                try await Task.sleep(for: .milliseconds(5))
            }
            #expect(await f.rpc.requests.contains { $0.0 == "abort" })
            await finish(f.store, firstID)
            try await f.store.whenIdle()
            #expect(!f.store.isResponding)
            // A later conversation is unaffected by the finished stop.
            try await f.store.submit(.init(text: "다음 대화 후속", project: "p", conversationRootID: later))
            let secondID = try #require(await f.rpc.promptIDs.last)
            #expect(f.store.respondingConversationRoots.contains(later))
            #expect(!canvasStop(bridge, f.store, root: active))
            #expect(f.store.isResponding)
            await finish(f.store, secondID)
            try await f.store.whenIdle()
            try await f.cleanup()
        } catch {
            try? await f.cleanup(); throw error
        }
    }
}
