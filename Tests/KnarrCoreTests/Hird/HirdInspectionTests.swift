import Foundation
import Testing
@testable import KnarrCore

@Suite(.serialized) struct HirdInspectionTests {
    @Test(arguments: ["error", "aborted"])
    func promptFailurePreservesItsCause(status: String) async throws {
        let f = try await HirdFixture.make()
        let task = Task { try await f.adapter.start(f.run, emit: f.sink) }
        do {
            for _ in 0..<300 {
                if await f.rpc.requests.contains(where: { $0.0 == "prompt" }) { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            await f.rpc.frame(.object(["type": .string("prompt_result"), "status": .string(status)]))
            _ = await task.result
            let saved = try await f.repository.snapshot().runs[0]
            #expect(saved.state == .failed)
            #expect(saved.stopReason?.contains("[prompt_" + status + "]") == true)
            #expect(saved.stopReason?.contains("missing_verification") == false)
            #expect(await f.adapter.remainingProcessIDs().isEmpty)
            try await f.cleanup()
        } catch { await f.adapter.cancel(f.run.id); _ = await task.result; try await f.cleanup(); throw error }
    }

    @Test(arguments: [false, true])
    func inspectionRecordsActualModelAndReportAndRejectsSourceEdits(changeSource: Bool) async throws {
        let f = try await HirdFixture.make(preserve: true)
        var run = f.run; run.mode = .inspect; run.requestedModel = "openai-codex/fixture-model"
        _ = try await f.repository.createRun(run)
        let execution = run
        let task = Task { try await f.adapter.start(execution, emit: f.sink) }
        do {
            for _ in 0..<300 {
                if await f.rpc.requests.contains(where: { $0.0 == "prompt" }) { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            let saved = try await f.repository.snapshot().runs[0]
            #expect(saved.observedModel == "openai-codex/fixture-model")
            #expect(saved.observedThinking == "off")
            let path = try #require(saved.workspace?.worktreePath)
            if changeSource { try "changed".write(toFile: path + "/original.txt", atomically: true, encoding: .utf8) }
            await f.rpc.frame(.object(["type": .string("tool_execution_start"), "toolCallId": .string("check"), "toolName": .string("bash"), "args": .object(["command": .string("/usr/bin/git --no-optional-locks --no-pager status --porcelain")])]))
            await f.rpc.frame(HirdResultTests.end(0, call: "check"))
            await f.rpc.frame(.object(["type": .string("message_end"), "message": .object(["role": .string("assistant"), "content": .array([.object(["type": .string("text"), "text": .string("확인한 최종 조사 보고서")])])])]))
            await f.rpc.frame(.object(["type": .string("prompt_result"), "status": .string("completed"), "sessionSettled": .bool(true)]))
            _ = await task.result
            let ended = try await f.repository.snapshot().runs[0]
            #expect(ended.state == (changeSource ? .failed : .succeeded))
            if changeSource { #expect(ended.stopReason?.contains("inspection_modified") == true) }
            let report = try #require(ended.result?.reportPath)
            #expect(try String(contentsOfFile: report, encoding: .utf8) == "확인한 최종 조사 보고서")
            #expect(await f.adapter.remainingProcessIDs().isEmpty)
            #expect(ended.processEndedAt != nil)
            #expect(await f.adapter.terminationConfirmed(run.id))
            try await f.cleanup()
        } catch { await f.adapter.cancel(run.id); _ = await task.result; try await f.cleanup(); throw error }
    }

    @Test func inspectionWithoutReportFailsEvenWhenCommandFinished() async throws {
        let f = try await HirdFixture.make(preserve: true)
        var run = f.run; run.mode = .inspect
        _ = try await f.repository.createRun(run)
        let execution = run
        let task = Task { try await f.adapter.start(execution, emit: f.sink) }
        do {
            for _ in 0..<300 {
                if await f.rpc.requests.contains(where: { $0.0 == "prompt" }) { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            await f.rpc.frame(.object(["type": .string("tool_execution_start"), "toolCallId": .string("inspect"),
                "toolName": .string("bash"), "args": .object(["command": .string("/bin/pwd")])]))
            await f.rpc.frame(HirdResultTests.end(0, call: "inspect"))
            await f.rpc.frame(.object(["type": .string("prompt_result"), "status": .string("completed"), "sessionSettled": .bool(true)]))
            _ = await task.result
            let saved = try await f.repository.snapshot().runs[0]
            #expect(saved.state == .failed)
            #expect(saved.stopReason == HirdError.noReport.reason)
            #expect(saved.result?.verifications.count == 1)
            try await f.cleanup()
        } catch { await f.adapter.cancel(run.id); _ = await task.result; try await f.cleanup(); throw error }
    }

}
