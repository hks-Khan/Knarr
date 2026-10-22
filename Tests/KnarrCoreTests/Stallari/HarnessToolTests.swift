import Foundation
import Testing
@testable import KnarrCore

@Suite(.serialized) struct HarnessToolTests {
    func invoke(_ name: String, _ args: OMPJSON, fixture f: StallariFixture, rpc override: TestStallariRPC? = nil) async throws -> OMPJSON {
        let id = UUID().uuidString
        let rpc = override ?? f.rpc
        await rpc.emit(.frame(.object(["type": .string("host_tool_call"), "id": .string(id), "toolName": .string(name), "arguments": args])))
        for _ in 0..<300 {
            if let reply = await rpc.sent.first(where: { $0["id"]?.string == id }) { return .object(reply) }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw OMPRPCError.timedOut
    }
    @Test func mainProposalToolsReviseOwnIssueWithoutBypassingExactApproval() async throws {
        let f = try await StallariFixture.make()
        var owner: StallariSession?
        do {
            try await f.session.connect()
            let created = try await invoke("create_issue", .object([
                "issueID": .string("proposal"), "title": .string("제안"), "criteria": .array([.string("검사")]),
                "instruction": .string("처음 계획"), "model": .string("openai-codex/fixture-model")
            ]), fixture: f)
            #expect(created["isError"]?.bool != true)
            #expect(try await f.repository.snapshot().issues.first?.state == .awaitingApproval)
            let denied = try await invoke("dispatch_hird", .object(["issueID": .string("proposal"), "runID": .string("unapproved")]), fixture: f)
            #expect(denied["isError"]?.bool == true)
            let mainRevision = try await invoke("update_issue_proposal", .object([
                "issueID": .string("proposal"), "expectedVersion": .number(1), "instruction": .string("수정된 검사 계획"),
                "model": .string("openai-codex/second-model"), "mode": .string("inspect")
            ]), fixture: f)
            #expect(mainRevision["isError"]?.bool != true)
            let issue = try #require(try await f.repository.snapshot().issues.first)
            let ownerRPC = TestStallariRPC()
            let issueSession = StallariSession(repository: f.repository, rpc: ownerRPC, hird: f.hird, threadID: issue.conversationThreadID)
            owner = issueSession
            try await issueSession.connect()
            #expect(try await f.repository.snapshot().issues.first?.proposal?.version == 2)
            #expect(try await f.repository.snapshot().issues.first?.approval == nil)
            #expect(try await f.repository.snapshot().runs.isEmpty)
            let stale = try await invoke("update_issue_proposal", .object([
                "issueID": .string("proposal"), "expectedVersion": .number(1), "instruction": .string("오래된 덮어쓰기")
            ]), fixture: f, rpc: ownerRPC)
            #expect(stale["isError"]?.bool == true)
            let run = try await issueSession.approveIssue(issueID: "proposal", version: 2)
            let replay = try await invoke("dispatch_hird", .object(["issueID": .string("proposal"), "runID": .string(run.rawValue)]), fixture: f, rpc: ownerRPC)
            #expect(replay["isError"]?.bool != true)
            let saved = try await issueSession.getRun(run)
            #expect(saved.hird.role == "수정된 검사 계획")
            #expect(saved.requestedModel == "openai-codex/second-model")
            #expect(saved.mode == .inspect)
            #expect(try await f.repository.snapshot().runs.count == 1)
            _ = await issueSession.shutdown()
            try await f.cleanup()
        } catch {
            if let owner { _ = await owner.shutdown() }
            try await f.cleanup()
            throw error
        }
    }

    @Test func oversizedHostReplyReturnsBoundedErrorInsteadOfHanging() async throws {
        let f = try await StallariFixture.make()
        do {
            try await f.session.connect()
            _ = try await f.session.createIssue(id: "large", title: String(repeating: "큰 결과", count: 4000), criteria: ["검증"], instruction: "검증해요")
            await f.rpc.setSendByteLimit(4096)
            let reply = try await invoke("get_issue", .object(["issueID": .string("large")]), fixture: f)
            #expect(reply["isError"]?.bool == true)
            #expect(reply["result"]?["details"]?["error"]?.string == "host_tool_response_too_large")
            #expect(try reply.jsonLine().count < 4096)
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }

    @Test func exactRunLogsReadInPagesAndCancellationEndsOwnedRun() async throws {
        let f = try await StallariFixture.make()
        do {
            try await f.session.connect()
            let t = try await f.issue("t"), r = try await f.dispatch("r", issue: t)
            let log = f.directory.appendingPathComponent("check.log")
            try "가나다라마바사".write(to: log, atomically: true, encoding: .utf8)
            let v = VerificationRecord(id: "only-this-run", command: ["swift test --filter 'A|B'"], workingDirectory: f.directory.path, startedAt: .now, finishedAt: .now, exitCode: 0, logPath: log.path, summary: "check")
            let result = RunResult(worktreePath: f.directory.path, branch: "b", commit: "c", diffPath: nil, summary: "s", verifications: [v], reportPath: log.path)
            _ = try await f.session.receive(.init(id: "saved", runID: r, at: .now, payload: .saveResult(result)))
            let page = try await invoke("get_run", .object(["runID": .string("r")]), fixture: f)
            #expect(page["result"]?["details"]?["verifications"]?.array?.first?["singleCheck"]?.bool == true)
            #expect(page["result"]?["details"]?["run"]?["reportAvailable"]?.bool == true)
            let output = try await invoke("read_run_output", .object(["runID": .string("r"), "verificationID": .string("only-this-run"), "limit": .number(6)]), fixture: f)
            #expect(output["result"]?["details"]?["text"]?.string == "가나")
            #expect(output["result"]?["details"]?["nextOffset"]?.integer == 6)
            let invalid = try await invoke("read_run_output", .object(["runID": .string("r"), "verificationID": .string("foreign-id")]), fixture: f)
            #expect(invalid["isError"]?.bool == true)
            let cancelled = try await invoke("cancel_run", .object(["runID": .string("r")]), fixture: f)
            #expect(cancelled["result"]?["details"]?["cleanupVerified"]?.bool == true)
            #expect(cancelled["result"]?["details"]?["run"]?["state"]?.string == "cancelled")
            #expect(await f.hird.cancelledRuns.contains(r))
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }

    @Test func cancellationAdmissionIsNotProcessTerminationAndLateCompletionCannotRevive() async throws {
        let f = try await StallariFixture.make()
        let t = try await f.issue("t"), r = try await f.dispatch("r", issue: t)
        await f.hird.holdCancel()
        let cancellation = Task { try await f.session.cancelRun(r) }
        do {
            for _ in 0..<300 {
                if await f.hird.cancellationEntered { break }
                try await Task.sleep(for: .milliseconds(5))
            }
            let requested = try await f.session.getRun(r)
            #expect(requested.state == .cancelled)
            #expect(requested.cancellationRequestedAt != nil)
            #expect(requested.endedAt == nil)
            #expect(requested.processEndedAt == nil)
            #expect(StallariReadback.run(requested)["cleanupVerified"]?.bool == false)
            #expect(try await f.session.receive(.init(id: "late", runID: r, at: .now,
                payload: .complete(f.result(), notificationID: "late-notice"))) == .ignoredTerminal)
            await f.hird.releaseCancel()
            #expect(try await cancellation.value == .applied)
            let stopped = try await f.session.getRun(r)
            #expect(stopped.processEndedAt != nil)
            #expect(stopped.endedAt == stopped.processEndedAt)
            #expect(try await f.session.cancelRun(r) == .duplicate)
            #expect(try await f.session.getRun(r).cancellationRequestedAt == requested.cancellationRequestedAt)
            #expect(try await f.repository.snapshot().notifications.isEmpty)
            try await f.cleanup()
        } catch {
            await f.hird.releaseCancel(); _ = await cancellation.result
            try await f.cleanup(); throw error
        }
    }

    @Test func runtimeAndSteeringUseTheSameExactRunCoreAsTheUI() async throws {
        let f = try await StallariFixture.make()
        do {
            try await f.session.connect()
            let t = try await f.issue("t"), r = try await f.dispatch("r", issue: t)
            try await f.session.steerRun(r, instruction: "UI instruction")
            let steered = try await invoke("steer_run", .object(["runID": .string("r"), "instruction": .string("tool instruction")]), fixture: f)
            #expect(steered["result"]?["details"]?["status"]?.string == "accepted")
            #expect(await f.hird.steering.map { $0.1 } == ["UI instruction", "tool instruction"])
            let runtime = try await f.session.getRuntime()
            #expect(runtime["stallariThinking"]?.string == "high")
            #expect(runtime["hirdRequestedThinking"]?.string == "xhigh")
            let run = try await f.session.getRun(r)
            #expect(run.requestedThinking == "xhigh")
            #expect(run.observedThinking == nil)
            #expect(run.requestedModel == "openai-codex/fixture-model")
            #expect(run.observedModel == nil)
            _ = try await f.session.cancelRun(r)
            await #expect(throws: StallariError.self) { try await f.session.steerRun(r, instruction: "late") }
            await #expect(throws: StallariError.self) { try await f.session.steerRun("foreign", instruction: "wrong") }
            #expect(await f.hird.steering.count == 2)
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }

    @Test func busyModelSelectionPinsNewRunsWithoutRewritingExistingRuns() async throws {
        let f = try await StallariFixture.make()
        do {
            let t = try await f.issue("t"), first = try await f.dispatch("first", issue: t)
            await f.rpc.setBusy(true)
            let selected = try await f.session.selectModel("openai-codex/second-model")
            #expect(selected["model"]?["id"]?.string == "fixture-model")
            #expect(selected["requestedModel"]?.string == "openai-codex/second-model")
            #expect(selected["pendingModel"]?.string == "openai-codex/second-model")
            _ = try await f.session.receive(.init(id: "first-complete", runID: first, at: .now, payload: .complete(f.result(), notificationID: "first-notice")))
            try await f.session.updateIssueProposal(issueID: t, expectedVersion: 1, instruction: "새 모델로 검토", model: "openai-codex/second-model")
            let second = try await f.dispatch("second", issue: t)
            #expect(try await f.session.getRun(first).requestedModel == "openai-codex/fixture-model")
            #expect(try await f.session.getRun(second).requestedModel == "openai-codex/second-model")
            await #expect(throws: StallariError.self) { _ = try await f.dispatch("first", issue: t) }
            #expect(try await f.repository.snapshot().runs.count == 2)
            await f.rpc.setBusy(false)
            _ = try await f.session.send("next turn", about: t)
            let actual = try await f.session.getState()["data"]
            #expect(actual?["model"]?["id"]?.string == "second-model")
            #expect(actual?["thinkingLevel"]?.string == "high")
            #expect(actual?["pendingModel"] == .null)
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }

    @Test func inspectionJudgementNeedsReportAndEvidenceButNotADiff() async throws {
        let f = try await StallariFixture.make()
        do {
            let t = try await f.issue("t")
            try await f.session.updateIssueProposal(issueID: t, expectedVersion: 1, instruction: "조사", mode: .inspect)
            let r = try await f.dispatch("inspect", issue: t)
            let report = f.directory.appendingPathComponent("report.md")
            try "조사 근거와 결론".write(to: report, atomically: true, encoding: .utf8)
            let result = RunResult(worktreePath: f.directory.path, branch: nil, commit: nil, diffPath: nil,
                summary: "조사 완료", verifications: f.result().verifications, reportPath: report.path)
            _ = try await f.session.receive(.init(id: "end", runID: r, at: .now, payload: .complete(result, notificationID: "notice")))
            try await f.session.judge(issueID: t, runID: r, evidence: [.init(criterionIndex: 0, verificationIDs: ["v"], explanation: "저장된 근거에서 확인")])
            #expect(try await f.repository.snapshot().issues[0].state == .done)
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }

    @Test func appliedResponseRulesVersionAdvancesOnlyAfterPromptAdmission() async throws {
        let f = try await StallariFixture.make()
        let file = ResponseRulesFile(url: f.directory.appendingPathComponent("response-rules.md"))
        let session = StallariSession(repository: f.repository, rpc: f.rpc, hird: f.hird, responseRules: file)
        do {
            try file.save("첫 지침")
            _ = try await session.send("첫 요청", about: nil)
            #expect(try await session.getRuntime()["appliedResponseRulesVersion"]?.string == ResponseRulesFile.version(of: "첫 지침"))
            try file.save("바뀐 지침")
            await f.rpc.setFailure(true)
            await #expect(throws: (any Error).self) { try await session.send("거절된 요청", about: nil) }
            #expect(try await session.getRuntime()["appliedResponseRulesVersion"]?.string == ResponseRulesFile.version(of: "첫 지침"))
            await f.rpc.setFailure(false)
            _ = try await session.send("다음 요청", about: nil)
            #expect(try await session.getRuntime()["appliedResponseRulesVersion"]?.string == ResponseRulesFile.version(of: "바뀐 지침"))
            #expect(await f.rpc.prompts.last?["message"]?.string?.contains("바뀐 지침") == true)
            _ = await session.shutdown(); try await f.cleanup()
        } catch { _ = await session.shutdown(); try await f.cleanup(); throw error }
    }
}
