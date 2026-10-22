import Foundation
import Testing
import CSQLite
@testable import KnarrCore

@Suite(.serialized) struct WorkflowEfficiencyTests {
    @Test(arguments: [false, true]) func judgementToolReturnsSavedState(met: Bool) async throws {
        let f = try await StallariFixture.make()
        do {
            let id = try await f.issue("judgement"), run = try await f.dispatch("judgement-run", issue: id)
            _ = try await f.session.receive(.init(id: "finished", runID: run, at: .now,
                payload: .complete(f.result(passing: met), notificationID: "notice")))
            let answer = try await f.session.performTool("judge_issue", arguments: .object([
                "issueID": .string(id.rawValue), "runID": .string(run.rawValue), "evidence": .array([.object([
                    "criterionIndex": .number(0), "verificationIDs": .array([.string("v")]),
                    "explanation": .string(met ? "검사 통과" : "검사 실패"), "met": .bool(met)])])]))
            #expect(answer["state"]?.string == (met ? "done" : "failed"))
            #expect(try await f.repository.snapshot().issues.first?.state == (met ? .done : .failed))
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }

    @Test func projectReceivesOnlyAcceptedResultOnceAndMainDoesNotPrompt() async throws {
        let f = try await StallariFixture.make()
        let thread = try await f.repository.createProjectConversation(projectID: "p")
        let projectRPC = TestStallariRPC(), issueRPC = TestStallariRPC()
        let project = StallariSession(repository: f.repository, rpc: projectRPC, hird: f.hird, threadID: thread.id)
        let id = try await project.createIssue(id: "delivery", title: "작업", criteria: ["검사"], instruction: "수정")
        let issueThread = try #require(try await f.repository.snapshot().issues.first { $0.id == id }?.conversationThreadID)
        let owner = StallariSession(repository: f.repository, rpc: issueRPC, hird: f.hird, threadID: issueThread)
        do {
            let run = try await owner.approveIssue(issueID: id, version: 1)
            _ = try await owner.receive(.init(id: "complete", runID: run, at: .now,
                payload: .complete(f.result(), notificationID: "delivery-notice")))
            try await project.deliverNotifications(); try await f.session.deliverNotifications()
            #expect(await projectRPC.prompts.isEmpty)
            #expect(await f.rpc.prompts.isEmpty)
            try await owner.judge(issueID: id, runID: run, evidence: [.init(criterionIndex: 0, verificationIDs: ["v"], explanation: "미달", met: false)])
            try await project.deliverNotifications()
            #expect(await projectRPC.prompts.isEmpty)
            try await owner.judge(issueID: id, runID: run, evidence: [.init(criterionIndex: 0, verificationIDs: ["v"], explanation: "충족")])
            await projectRPC.setFailure(true)
            await #expect(throws: (any Error).self) { try await project.deliverNotifications() }
            await projectRPC.setFailure(false)
            try await project.deliverNotifications(); try await project.deliverNotifications()
            try await owner.judge(issueID: id, runID: run, evidence: [.init(criterionIndex: 0, verificationIDs: ["v"], explanation: "충족")])
            try await project.deliverNotifications(); try await f.session.deliverNotifications()
            #expect(await projectRPC.prompts.count == 1)
            #expect(await f.rpc.prompts.isEmpty)
            #expect(await issueRPC.prompts.filter { $0["message"]?.string?.contains("notificationID=delivery-notice") == true }.count == 1)
            _ = await owner.shutdown(); _ = await project.shutdown(); try await f.cleanup()
        } catch { _ = await owner.shutdown(); _ = await project.shutdown(); try await f.cleanup(); throw error }
    }

    @Test func unchangedIssueReusesDerivedRunsAcrossUnrelatedActivity() async throws {
        let f = try await StallariFixture.make()
        do {
            let a = try await f.issue("a"), b = try await f.issue("b")
            _ = try await f.dispatch("a-run", issue: a); _ = try await f.dispatch("b-run", issue: b)
            let before = try await f.repository.snapshot(includeHistory: false)
            try await f.repository.appendActivity(.init(at: .now, actor: "Hird", text: "changed"), issueID: a)
            let after = try await f.repository.snapshot(includeHistory: false)
            let old = try #require(before.issues.first { $0.id == b }), new = try #require(after.issues.first { $0.id == b })
            #expect(!old.hirds.isEmpty && old == new)
            #expect(old.hirds.withUnsafeBufferPointer { lhs in new.hirds.withUnsafeBufferPointer { lhs.baseAddress == $0.baseAddress } })
            #expect(before.issues.first { $0.id == a }?.events.isEmpty == true)
            #expect(after.issues.first { $0.id == a }?.events.count == 1)
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["GIT_TRACE2_EVENT"] != nil))
    func unchangedCommandsReuseSnapshotButExternalChangesInvalidateIt() async throws {
        let f = try await HirdFixture.make(temporary: true)
        let task = Task { try await f.adapter.start(f.run, emit: f.sink) }
        func command(_ name: String) async throws {
            await f.rpc.frame(HirdResultTests.start(name)); await f.rpc.frame(HirdResultTests.end(0, call: name))
            await f.rpc.frame(HirdStopEvidenceTests.question(name))
            let state = try await HirdStopEvidenceTests.wait(f) { $0.questions.contains { $0.state == .pending } }
            let q = try #require(state.questions.first { $0.state == .pending })
            _ = try await f.repository.answerQuestion(q.id, runID: f.run.id, answer: .init(selectedOptions: [], text: "continue"), at: .now)
        }
        func starts() throws -> Int {
            let path = try #require(ProcessInfo.processInfo.environment["GIT_TRACE2_EVENT"])
            return try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n").filter { $0.contains("\"event\":\"start\"") }.count
        }
        do {
            try await HirdVerificationRetryTests.awaitPrompts(1, f)
            let workspace = try #require(try await f.repository.snapshot().runs.first?.workspace)
            let file = URL(fileURLWithPath: workspace.worktreePath).appendingPathComponent("original.txt")
            try "changed!\n".write(to: file, atomically: true, encoding: .utf8)
            let first = ContinuousClock.now
            try await command("first")
            let firstMS = first.duration(to: .now)
            let before = try starts(), second = ContinuousClock.now
            try await command("unchanged")
            let unchangedMS = second.duration(to: .now), after = try starts()
            #expect(after == before + 4, "Only bounded path/config/attribute inventories run for an unchanged snapshot")
            // Same length and restored mtime must still invalidate through ctime/inode.
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            try "updated!\n".write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.modificationDate: attributes[.modificationDate]!], ofItemAtPath: file.path)
            try await command("changed")
            #expect(try starts() > after)
            await f.rpc.frame(HirdVerificationRetryTests.end(1))
            try await task.value
            #expect(try await f.repository.snapshot().runs.first?.state == .succeeded)
            print("EFFICIENCY_COMMAND first=\(firstMS) unchanged=\(unchangedMS) unchangedGitStarts=\(after-before)")
            try await f.cleanup()
        } catch { await f.adapter.cancel(f.run.id); _ = await task.result; try await f.cleanup(); throw error }
    }
}
