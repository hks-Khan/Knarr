import Foundation
import Testing
@testable import KnarrCore

@Suite(.serialized) struct HirdVerificationRetryTests {
    static func end(_ number: Int, settled: Bool = true) -> OMPJSON {
        .object(["type": .string("prompt_result"), "id": .string("prompt-\(number)"),
                 "status": .string("completed"), "sessionSettled": .bool(settled)])
    }
    static func awaitPrompts(_ count: Int, _ f: HirdFixture) async throws {
        for _ in 0..<500 {
            if await f.rpc.requests.filter({ $0.0 == "prompt" }).count >= count { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        let stopped = try await f.repository.snapshot().runs.first { $0.id == f.run.id }
        try #require(await f.rpc.requests.filter { $0.0 == "prompt" }.count >= count,
                     "prompt 접수 누락: \(stopped?.stopReason ?? "저장된 중단 사유 없음")")
    }
    static func invalidate(_ kind: String, _ f: HirdFixture) async throws {
        let tree = URL(fileURLWithPath: try #require(try await f.repository.snapshot().runs[0].workspace).worktreePath)
        try "changed\n".write(to: tree.appendingPathComponent("original.txt"), atomically: true, encoding: .utf8)
        if kind == "missing" { return }
        if kind == "changed" {
            try "stable\n".write(to: tree.appendingPathComponent("stable.txt"), atomically: true, encoding: .utf8)
            try "temporary\n".write(to: tree.appendingPathComponent("removed.txt"), atomically: true, encoding: .utf8)
        }
        await f.rpc.frame(HirdResultTests.start("first"))
        if kind == "unfinished" {
            await f.rpc.frame(.object(["type": .string("tool_execution_end"), "toolCallId": .string("first"), "toolName": .string("bash"),
                "isError": .bool(true), "result": .object(["details": .object(["timedOut": .bool(true)]), "content": .array([])])]))
            return
        }
        await f.rpc.frame(HirdResultTests.end(0, call: "first"))
        // A question is a sequential receive barrier after the verification diff was saved.
        await f.rpc.frame(.object(["type": .string("extension_ui_request"), "id": .string("barrier"), "method": .string("input")]))
        for _ in 0..<500 {
            if try await f.repository.snapshot().questions.count == 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let snapshot = try await f.repository.snapshot()
        let question = try #require(snapshot.questions.first)
        _ = try await f.repository.answerQuestion(question.id, runID: f.run.id, answer: .init(selectedOptions: [], text: "continue"), at: .now)
        try "late\n".write(to: tree.appendingPathComponent("original.txt"), atomically: true, encoding: .utf8)
        try "report\n".write(to: tree.appendingPathComponent("report with spaces.md"), atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: tree.appendingPathComponent("removed.txt"))
    }
    @Test func lateSettledEventCannotFinishCurrentUnsettledPrompt() async throws {
        let f = try await HirdFixture.make()
        let task = Task { try await f.adapter.start(f.run, emit: f.sink) }
        do {
            try await Self.awaitPrompts(1, f)
            try await Self.invalidate("missing", f)
            await f.rpc.frame(Self.end(1))
            try await Self.awaitPrompts(2, f)
            await f.rpc.setSettled(false)
            await f.rpc.frame(HirdResultTests.start("repair"))
            await f.rpc.frame(HirdResultTests.end(0, call: "repair"))
            await f.rpc.frame(Self.end(2, settled: false))
            await f.rpc.frame(.object(["type": .string("session_settled")]))
            await f.rpc.frame(.object(["type": .string("extension_ui_request"), "id": .string("settled-barrier"), "method": .string("input")]))
            for _ in 0..<500 {
                if try await f.repository.snapshot().questions.count == 1 { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            let saved = try await f.repository.snapshot()
            try #require(!saved.runs[0].state.isTerminal)
            let question = try #require(saved.questions.first)
            _ = try await f.repository.answerQuestion(question.id, runID: f.run.id, answer: .init(selectedOptions: [], text: "continue"), at: .now)
            await f.rpc.setSettled(true)
            await f.rpc.frame(.object(["type": .string("session_settled")]))
            try await task.value
            #expect(try await f.repository.snapshot().runs[0].state == .succeeded)
            #expect(try await f.repository.snapshot().notifications.count == 1)
            try await f.cleanup()
        } catch { await f.adapter.cancel(f.run.id); _ = await task.result; try await f.cleanup(); throw error }
    }

    @Test(arguments: ["missing", "unfinished", "changed"])
    func repairsVerificationInSameSessionAndIgnoresOldCompletion(kind: String) async throws {
        let f = try await HirdFixture.make()
        let task = Task { try await f.adapter.start(f.run, emit: f.sink) }
        do {
            try await Self.awaitPrompts(1, f)
            try await Self.invalidate(kind, f)
            await f.rpc.frame(Self.end(1))
            try await Self.awaitPrompts(2, f)
            let requests = await f.rpc.requests.filter { $0.0 == "prompt" }
            let instruction = try #require(requests.last?.1["message"]?.string)
            if kind == "changed" {
                #expect(instruction.contains("original.txt"))
                #expect(instruction.contains("report with spaces.md"))
                #expect(instruction.contains("removed.txt"))
                #expect(!instruction.contains("stable.txt"))
            }
            let before = try await f.repository.snapshot()
            #expect(!before.runs[0].state.isTerminal)
            #expect(before.issues[0].events.contains { $0.text.contains(instruction) })
            await f.rpc.frame(Self.end(1))
            await f.rpc.frame(.object(["type": .string("session_settled")]))
            await f.rpc.frame(.object(["type": .string("prompt_result"), "status": .string("completed")]))
            await f.rpc.frame(HirdResultTests.start("repair"))
            await f.rpc.frame(HirdResultTests.end(0, call: "repair"))
            await f.rpc.frame(Self.end(2, settled: false))
            await f.rpc.frame(.object(["type": .string("session_settled")]))
            try await task.value
            let saved = try await f.repository.snapshot()
            #expect(saved.runs[0].state == .succeeded)
            #expect(saved.runs[0].result?.verifications.last?.exitCode == 0)
            #expect(saved.notifications.count == 1)
            #expect(await f.rpc.started == 1)
            #expect(await f.rpc.requests.filter { $0.0 == "prompt" }.count == 2)
            try await f.cleanup()
        } catch { await f.adapter.cancel(f.run.id); _ = await task.result; try await f.cleanup(); throw error }
    }
    @Test(arguments: ["missing", "unfinished", "changed"])
    func twoRetriesThenFailsWithConcreteReason(kind: String) async throws {
        let f = try await HirdFixture.make()
        let task = Task { try await f.adapter.start(f.run, emit: f.sink) }
        do {
            try await Self.awaitPrompts(1, f)
            try await Self.invalidate(kind, f)
            for number in 1...3 {
                await f.rpc.frame(Self.end(number))
                if number < 3 { try await Self.awaitPrompts(number + 1, f) }
            }
            _ = await task.result
            let saved = try await f.repository.snapshot()
            #expect(saved.runs[0].state == .failed)
            let reason = try #require(saved.runs[0].stopReason)
            #expect(reason.contains("2"))
            if kind == "changed" { #expect(reason.contains("original.txt")) }
            #expect(saved.runs[0].result != nil)
            #expect(await f.rpc.requests.filter { $0.0 == "prompt" }.count == 3)
            #expect(await f.adapter.exits[f.run.id]?.remainingProcessIDs.isEmpty == true)
            try await f.cleanup()
        } catch { await f.adapter.cancel(f.run.id); _ = await task.result; try await f.cleanup(); throw error }
    }
    @Test func cancellationDuringRetryCannotCompleteOrPromptAgain() async throws {
        let f = try await HirdFixture.make()
        let task = Task { try await f.adapter.start(f.run, emit: f.sink) }
        do {
            try await Self.awaitPrompts(1, f)
            await f.rpc.holdPromptAdmission()
            await f.rpc.frame(Self.end(1))
            try await Self.awaitPrompts(2, f)
            await f.adapter.cancel(f.run.id)
            await f.rpc.frame(Self.end(2))
            await f.rpc.frame(.object(["type": .string("session_settled")]))
            _ = await task.result
            #expect(try await f.repository.snapshot().runs[0].state == .cancelled)
            #expect(try await f.repository.snapshot().notifications.isEmpty)
            #expect(await f.rpc.requests.filter { $0.0 == "prompt" }.count == 2)
            try await f.cleanup()
        } catch { await f.adapter.cancel(f.run.id); _ = await task.result; try await f.cleanup(); throw error }
    }
}
