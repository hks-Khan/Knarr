import Foundation
import Testing
@testable import KnarrCore

private actor CheckpointEvents {
    var results: [RunResult] = []
    func record(_ update: HirdUpdate) {
        if case .saveResult(let result) = update.payload { results.append(result) }
    }
}

@Suite(.serialized) struct HirdCheckpointPerformanceTests {
    @Test(arguments: [0, 1]) func oneBashCompletionCapturesOnceAndKeepsExitEvidence(exitCode: Int) async throws {
        let f = try await HirdFixture.make(), events = CheckpointEvents()
        let task = Task {
            try await f.adapter.start(f.run) { update in
                await events.record(update)
                return try await f.sink(update)
            }
        }
        do {
            try await HirdVerificationRetryTests.awaitPrompts(1, f)
            await f.rpc.frame(HirdResultTests.start("single"))
            await f.rpc.frame(HirdResultTests.end(exitCode, call: "single"))
            await f.rpc.frame(.object(["type": .string("extension_ui_request"), "id": .string("barrier"), "method": .string("input")]))
            for _ in 0..<500 {
                if try await !f.repository.snapshot().questions.isEmpty { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            let saved = await events.results
            print("bash checkpoint exit=\(exitCode) captures=\(saved.count) captureGitCommands=\(saved.count * 4)")
            #expect(saved.count == 1)
            #expect(saved.last?.verifications.count == 1)
            #expect(saved.last?.verifications.last?.exitCode == Int32(exitCode))
            await f.adapter.cancel(f.run.id); _ = await task.result
            try await f.cleanup()
        } catch { await f.adapter.cancel(f.run.id); _ = await task.result; try await f.cleanup(); throw error }
    }

    @Test func incompleteBashMetadataStillCapturesChangesWithoutInventingVerification() async throws {
        let f = try await HirdFixture.make(), events = CheckpointEvents()
        let task = Task { try await f.adapter.start(f.run) { update in
            await events.record(update); return try await f.sink(update)
        } }
        do {
            try await HirdVerificationRetryTests.awaitPrompts(1, f)
            // Missing tool start/result cannot become verification, but must still checkpoint.
            await f.rpc.frame(.object(["type": .string("tool_execution_end"), "toolName": .string("bash"), "toolCallId": .string("unknown")]))
            await f.rpc.frame(.object(["type": .string("extension_ui_request"), "id": .string("barrier"), "method": .string("input")]))
            for _ in 0..<500 {
                if try await !f.repository.snapshot().questions.isEmpty { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            let saved = await events.results
            #expect(saved.count == 1)
            #expect(saved.last?.verifications.isEmpty == true)
            await f.adapter.cancel(f.run.id); _ = await task.result; try await f.cleanup()
        } catch { await f.adapter.cancel(f.run.id); _ = await task.result; try await f.cleanup(); throw error }
    }

    @Test func hirdFiltersUnusedMessageDeltasBeforePrompt() async throws {
        let f = try await HirdFixture.make()
        let task = Task { try await f.adapter.start(f.run, emit: f.sink) }
        do {
            try await HirdVerificationRetryTests.awaitPrompts(1, f)
            let requests = await f.rpc.requests
            let filter = try #require(requests.first { $0.0 == "set_event_filter" })
            #expect(filter.1["events"] == .array(["message_update", "message_end", "tool_execution_start", "tool_execution_end"].map(OMPJSON.string)))
            #expect(filter.1["messageUpdates"] == .string("delta"))
            #expect(try #require(requests.firstIndex { $0.0 == "set_event_filter" }) < #require(requests.firstIndex { $0.0 == "prompt" }))
            await f.adapter.cancel(f.run.id); _ = await task.result
            try await f.cleanup()
        } catch { await f.adapter.cancel(f.run.id); _ = await task.result; try await f.cleanup(); throw error }
    }
}
