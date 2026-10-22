import Foundation
import Testing
@testable import KnarrCore

@Suite(.serialized) struct HirdSubagentActivityTests {
    private func lifecycle(_ id: String, _ status: String) -> OMPJSON {
        .object(["type": .string("subagent_lifecycle"), "payload": .object([
            "id": .string(id), "index": .number(0), "agent": .string("task"),
            "agentSource": .string("builtin"), "status": .string(status), "parentToolCallId": .string("spawn")
        ])])
    }
    private func progress(_ id: String) -> OMPJSON {
        .object(["type": .string("subagent_progress"), "payload": .object([
            "index": .number(0), "agent": .string("task"), "agentSource": .string("builtin"),
            "parentToolCallId": .string("spawn"), "task": .string("관련 검사"),
            "progress": .object(["id": .string(id), "status": .string("running"), "currentTool": .string("read"), "toolCount": .number(1)])
        ])])
    }
    private func barrier(_ f: HirdFixture, _ number: Int) async throws -> PersistedRun {
        await f.rpc.frame(.object(["type": .string("extension_ui_request"), "id": .string("barrier-\(number)"),
                                  "method": .string("input"), "title": .string("수신 순서 경계")]))
        for _ in 0..<500 {
            let snapshot = try await f.repository.snapshot()
            if snapshot.questions.count == number { return try #require(snapshot.runs.first { $0.id == f.run.id }) }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw HirdError.staleRun
    }

    @Test func childProgressKeepsWaitingHirdAliveAndTerminalChildrenCannotReviveIt() async throws {
        let f = try await HirdFixture.make()
        let task = Task { try await f.adapter.start(f.run, emit: f.sink) }
        do {
            for _ in 0..<500 {
                if await f.rpc.requests.contains(where: { $0.0 == "prompt" }) { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            await f.rpc.frame(.object(["type": .string("tool_execution_start"), "toolName": .string("wait"), "toolCallId": .string("waiting")]))
            await f.rpc.frame(lifecycle("child-a", "started"))
            await f.rpc.frame(lifecycle("child-b", "started"))
            let before = try await barrier(f, 1)
            #expect(before.hird.currentCommand == "하위 작업 2개 진행 중")
            try await Task.sleep(for: .milliseconds(20))
            await f.rpc.frame(progress("child-a"))
            var updated = try await barrier(f, 2).hird
            #expect(updated.lastActivityAt > before.hird.lastActivityAt)
            updated.status = .working
            #expect(IssueCards.quietLabel(for: updated, now: before.hird.lastActivityAt.addingTimeInterval(90)) == nil)
            #expect(IssueCards.quietLabel(for: updated, now: updated.lastActivityAt.addingTimeInterval(90)) == "1분째 조용함")
            await f.rpc.frame(lifecycle("child-a", "completed"))
            await f.rpc.frame(lifecycle("child-b", "failed"))
            let finished = try await barrier(f, 3)
            #expect(finished.hird.currentCommand == "wait")
            await f.rpc.frame(progress("child-a"))
            let late = try await barrier(f, 4)
            #expect(late.hird.lastActivityAt == finished.hird.lastActivityAt)
            #expect(late.hird.currentCommand == "wait")
            await f.adapter.cancel(f.run.id); _ = await task.result
            #expect(await f.adapter.exits[f.run.id]?.remainingProcessIDs.isEmpty == true)
            try await f.cleanup()
        } catch {
            await f.adapter.cancel(f.run.id); _ = await task.result
            try await f.cleanup(); throw error
        }
    }
}
