import Foundation
import Testing
@testable import KnarrCore

@Suite(.serialized) struct HirdTodoContinuationTests {
    @Test func blockedTodoWithoutAskNeverCreatesInputNeededState() async throws {
        let f = try await HirdFixture.make()
        do {
            _ = try await f.sink(.init(id: "blocked-todo", runID: f.run.id, at: .now,
                payload: .activity(.init(at: .now, actor: "Hird", text: "todo"), currentCommand: nil,
                    steps: [.init(title: "외부 확인", state: .blocked, blocker: "사람 확인")])))
            let snapshot = try await f.repository.snapshot()
            #expect(snapshot.runs[0].state == .working)
            #expect(snapshot.issues[0].state != .needsInput)
            #expect(snapshot.questions.isEmpty)
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }
    @Test func unfinishedTodoRetriesWithoutInventingHumanInputAndSharesVerificationLimit() async throws {
        let f = try await HirdFixture.make()
        let task = Task { try await f.adapter.start(f.run, emit: f.sink) }
        do {
            try await HirdVerificationRetryTests.awaitPrompts(1, f)
            try await HirdVerificationRetryTests.invalidate("missing", f)
            await f.rpc.setTodos(HirdTests.phases([("finish implementation", "in_progress", nil)]))
            await f.rpc.frame(HirdVerificationRetryTests.end(1))
            try await HirdVerificationRetryTests.awaitPrompts(2, f)
            #expect(try await f.repository.snapshot().questions.isEmpty)
            await f.rpc.setTodos(.array([]))
            await f.rpc.frame(HirdVerificationRetryTests.end(2))
            try await HirdVerificationRetryTests.awaitPrompts(3, f)
            await f.rpc.setTodos(HirdTests.phases([("finish implementation", "pending", nil)]))
            await f.rpc.frame(HirdVerificationRetryTests.end(3))
            _ = await task.result
            let saved = try await f.repository.snapshot()
            #expect(saved.runs[0].state == .failed)
            #expect(saved.runs[0].stopReason?.contains("finish implementation") == true)
            #expect(saved.questions.isEmpty)
            #expect(await f.rpc.started == 1)
            try await f.cleanup()
        } catch { await f.adapter.cancel(f.run.id); _ = await task.result; try await f.cleanup(); throw error }
    }
}
