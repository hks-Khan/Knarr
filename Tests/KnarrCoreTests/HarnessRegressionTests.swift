import Foundation
import Testing
@testable import KnarrCore

@Suite(.serialized) struct HarnessRegressionTests {
    @Test func quotedRegexAndProgramTextAreSingleChecks() {
        func single(_ command: String) -> Bool {
            VerificationRecord(id: "v", command: [command], workingDirectory: "/", startedAt: .now, finishedAt: .now, exitCode: 0, logPath: "/x", summary: "").isSingleCheck
        }
        #expect(single("swift test --filter 'Tests.(first|second)'"))
        #expect(single("python3 -c 'x = 1; print(x)'"))
        #expect(single("printf '%s' \"a|b\""))
        #expect(!single("swift test | tail -10"))
        #expect(!single("swift test || true"))
        #expect(!single("sh -c 'false; true'"))
        #expect(!single("echo $(false; true)"))
        #expect(!single("echo `false`"))
        #expect(!single("printf 'unfinished"))
    }
    @Test func noSourceChangesWithRecordedCheckCanComplete() async throws {
        let f = try await HirdFixture.make()
        let task = Task { try await f.adapter.start(f.run, emit: f.sink) }
        do {
            for _ in 0..<300 {
                if await f.rpc.requests.contains(where: { $0.0 == "prompt" }) { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            await f.rpc.frame(.object(["type": .string("tool_execution_start"), "toolCallId": .string("check"), "toolName": .string("bash"), "args": .object(["command": .string("git status --porcelain")])]))
            await f.rpc.frame(.object(["type": .string("tool_execution_end"), "toolCallId": .string("check"), "toolName": .string("bash"), "result": .object(["details": .object(["exitCode": .number(0)]), "content": .array([.object(["type": .string("text"), "text": .string("clean")])])])]))
            await f.rpc.frame(.object(["type": .string("message_end"), "message": .object(["role": .string("assistant"), "content": .array([.object(["type": .string("text"), "text": .string("조사 완료: 소스 수정 없이 확인했습니다.")])])])]))
            await f.rpc.frame(.object(["type": .string("prompt_result"), "status": .string("completed"), "sessionSettled": .bool(true)]))
            _ = await task.result
            let saved = try await f.repository.snapshot().runs[0]
            #expect(saved.state == .succeeded)
            #expect(saved.result?.verifications.count == 1)
            #expect(await f.adapter.remainingProcessIDs().isEmpty)
            try await f.cleanup()
        } catch { await f.adapter.cancel(f.run.id); _ = await task.result; try await f.cleanup(); throw error }
    }
    @Test func getIssueDoesNotReturnEveryResultSnapshot() async throws {
        let f = try await StallariFixture.make()
        do {
            try await f.session.connect()
            let t = try await f.issue("t"), r = try await f.dispatch("r", issue: t)
            for i in 0..<40 {
                let result = RunResult(worktreePath: f.directory.path, branch: "b", commit: "c", diffPath: nil, summary: String(repeating: "기록", count: 1000) + String(i), verifications: [])
                _ = try await f.session.receive(.init(id: "snapshot-\(i)", runID: r, at: .now, payload: .saveResult(result)))
            }
            await f.rpc.emit(.frame(.object(["type": .string("host_tool_call"), "id": .string("compact"), "toolName": .string("get_issue"), "arguments": .object(["issueID": .string("t")]) ])))
            for _ in 0..<300 { if await f.rpc.sent.contains(where: { $0["id"]?.string == "compact" }) { break }; try await Task.sleep(for: .milliseconds(5)) }
            let reply = try #require(await f.rpc.sent.first { $0["id"]?.string == "compact" })
            let details = try #require(reply["result"]?["details"])
            #expect(details["runs"]?.array?.first?["resultHistory"] == nil)
            #expect(try JSONEncoder().encode(details).count < 20000)
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }
}
