import Foundation
import Testing
@testable import KnarrCore

/// Regression for the v3 defect: six different states arriving back to back wrote six ledger
/// rows, so the stored activity tracked every delta instead of one line of current state.
/// It is the same script used against the pre-fix source (where it wrote six rows) minus the
/// fixture's explicit interval; that source had no interval at all.
@Suite(.serialized) struct HirdActivityRateLimitRedTests {
    private func message(_ event: String) -> OMPJSON {
        .object(["type": .string("message_update"), "messageId": .string("msg"), "message": .object(["role": .string("assistant")]),
                 "assistantMessageEvent": .object(["type": .string(event), "contentIndex": .number(0)])])
    }
    private func tool(_ name: String, _ call: String, _ args: [String: OMPJSON]) -> OMPJSON {
        .object(["type": .string("tool_execution_start"), "toolName": .string(name), "toolCallId": .string(call), "args": .object(args)])
    }
    private func rows(_ snapshot: PersistenceSnapshot) -> [String] {
        snapshot.issues.first?.events.map(\.text).filter {
            ["생각 중", "답변 작성 중"].contains($0) || $0.hasPrefix("읽는 중") || $0.hasPrefix("편집 중")
                || $0.hasPrefix("검색 중") || $0.hasPrefix("명령 실행")
        } ?? []
    }

    @Test func oneBurstOfSixStatesWritesAtMostTwoRowsAndEndsOnTheLast() async throws {
        let f = try await HirdFixture.make(activityInterval: HirdActivityCoalescer.defaultInterval)
        let task = Task { try await f.adapter.start(f.run, emit: f.sink) }
        do {
            for _ in 0..<500 {
                if await f.rpc.requests.contains(where: { $0.0 == "prompt" }) { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            await f.rpc.frame(message("thinking_start"))
            await f.rpc.frame(tool("read", "r1", ["path": .string("/tmp/work/A.swift")]))
            await f.rpc.frame(tool("edit", "e1", ["path": .string("/tmp/work/B.swift")]))
            await f.rpc.frame(tool("grep", "g1", ["pattern": .string("needle")]))
            await f.rpc.frame(tool("bash", "b1", ["command": .string("swift build")]))
            await f.rpc.frame(message("text_delta"))
            await f.rpc.frame(.object(["type": .string("extension_ui_request"), "id": .string("rate-barrier"),
                                       "method": .string("input"), "title": .string("수신 순서 경계")]))
            var snapshot = try await f.repository.snapshot()
            for _ in 0..<500 {
                snapshot = try await f.repository.snapshot()
                if snapshot.questions.count == 1 { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(rows(snapshot).count <= 2)
            // The last observation must still land, not be replaced by an older one.
            for _ in 0..<100 {
                snapshot = try await f.repository.snapshot()
                if snapshot.runs.first?.hird.currentActivity?.kind == .writing { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(snapshot.runs.first?.hird.currentActivity?.displayText == "답변 작성 중")
            #expect(rows(snapshot).last == "답변 작성 중")
            await f.adapter.cancel(f.run.id); _ = await task.result
            try await f.cleanup()
        } catch {
            await f.adapter.cancel(f.run.id); _ = await task.result
            try await f.cleanup(); throw error
        }
    }
}
