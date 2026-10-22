import Foundation
import Testing
@testable import KnarrCore

@Suite(.serialized) struct ProjectSessionTests {
    @Test func projectCanControlItsIssueButMainCanOnlyReadIt() async throws {
        let f = try await StallariFixture.make()
        let thread = try await f.repository.createProjectConversation(projectID: "p")
        let rpc = TestStallariRPC()
        let project = StallariSession(repository: f.repository, rpc: rpc, hird: f.hird, threadID: thread.id)
        let stranger = StallariSession(repository: f.repository, rpc: TestStallariRPC(), hird: f.hird, threadID: UUID().uuidString)
        do {
            let id = try await project.createIssue(id: "project-owned", title: "프로젝트 목표", criteria: ["검사"], instruction: "검사")
            let issue = try #require(try await f.repository.snapshot().issues.first { $0.id == id })
            let owner = StallariSession(repository: f.repository, rpc: TestStallariRPC(), hird: f.hird, threadID: issue.conversationThreadID)
            await project.setApprovalRouter { id, version, source in try await owner.approveIssue(issueID: id, version: version, source: source) }
            try await project.updateIssueProposal(issueID: id, expectedVersion: 1, instruction: "같은 목표 수정")
            await #expect(throws: (any Error).self) { _ = try await project.approveIssue(issueID: id, version: 1) }
            let run = try await project.approveIssue(issueID: id, version: 2)
            #expect(try await project.approveIssue(issueID: id, version: 2) == run)
            try await project.steerRun(run, instruction: "범위 유지")
            #expect(await f.hird.steering.contains { $0.0 == run && $0.1 == "범위 유지" })
            try "프로젝트 검사 근거".write(to: f.directory.appendingPathComponent("test.log"), atomically: true, encoding: .utf8)
            _ = try await owner.receive(.init(id: "project-complete", runID: run, at: .now, payload: .complete(f.result(), notificationID: "project-notice")))
            let read = try await f.session.performTool("get_issue", arguments: .object(["issueID": .string(id.rawValue)]))
            #expect(read["issue"]?["id"]?["rawValue"]?.string == id.rawValue)
            #expect(try await f.session.getRun(run).id == run)
            let output = try await f.session.performTool("read_run_output", arguments: .object(["runID": .string(run.rawValue), "verificationID": .string("v")]))
            #expect(output["text"]?.string == "프로젝트 검사 근거")
            await #expect(throws: StallariError.missingIssue) { try await f.session.updateIssueProposal(issueID: id, expectedVersion: 2, instruction: "메인 침범") }
            await #expect(throws: StallariError.missingIssue) { _ = try await f.session.approveIssue(issueID: id, version: 2) }
            await #expect(throws: StallariError.missingIssue) { try await f.session.steerRun(run, instruction: "메인 침범") }
            await #expect(throws: StallariError.missingIssue) { _ = try await f.session.cancelRun(run) }
            await #expect(throws: StallariError.missingIssue) {
                _ = try await stranger.performTool("read_run_output", arguments: .object([
                    "runID": .string(run.rawValue), "verificationID": .string("v")]))
            }
            #expect(try await f.repository.snapshot().runs.count == 1)
            _ = await owner.shutdown()
            _ = await project.shutdown(); _ = await stranger.shutdown()
            try await f.cleanup()
        } catch { _ = await project.shutdown(); _ = await stranger.shutdown(); try await f.cleanup(); throw error }
    }

    @Test func projectCreationCannotEscapeItsProjectOrUseAnotherOrigin() async throws {
        let f = try await StallariFixture.make()
        try await f.repository.saveProject(.init(id: "other", name: "다른 프로젝트", absolutePath: f.directory.path))
        let thread = try await f.repository.createProjectConversation(projectID: "p")
        let project = StallariSession(repository: f.repository, rpc: TestStallariRPC(), hird: f.hird, threadID: thread.id)
        do {
            await #expect(throws: (any Error).self) {
                _ = try await project.createIssue(id: "escape", title: "다른 프로젝트", criteria: ["검사"], instruction: "검사", projectID: "other")
            }
            let id = try await project.createIssue(id: "local", title: "이 프로젝트", criteria: ["검사"], instruction: "검사")
            #expect(try await f.repository.projectID(forIssue: id) == "p")
            #expect(try await f.repository.snapshot().issues.count == 1)
            _ = await project.shutdown(); try await f.cleanup()
        } catch { _ = await project.shutdown(); try await f.cleanup(); throw error }
    }

    @Test func compactProjectHandoffIsDeliveredOnceAndNeverCopiesMainTranscript() async throws {
        let f = try await StallariFixture.make()
        var p = try #require(try await f.repository.snapshot().projects.first { $0.id == "p" })
        p.settings.memo = "프로젝트 메모"
        p.settings.verification = [.init(name: "검증", command: "swift test")]
        p.settings.criteria = ["기본 완료 조건"]
        try await f.repository.saveProject(p)
        try await f.repository.appendChat(.init(at: .now, kind: .user("MAIN_TRANSCRIPT_MUST_NOT_BE_COPIED")), projectID: "p")
        _ = try await f.issue("open-context")
        let thread = try await f.repository.createProjectConversation(projectID: "p")
        let rpc = TestStallariRPC()
        let session = StallariSession(repository: f.repository, rpc: rpc, hird: f.hird, threadID: thread.id)
        do {
            try await session.connect()
            let messages = await rpc.prompts.compactMap { $0["message"]?.string }
            #expect(messages.filter { $0.contains("projectID=p") && $0.contains("프로젝트 메모") }.count == 1)
            #expect(messages.contains { $0.contains("swift test") && $0.contains("기본 완료 조건") && $0.contains("open-context") })
            #expect(!messages.contains { $0.contains("MAIN_TRANSCRIPT_MUST_NOT_BE_COPIED") })
            try await session.connect()
            #expect(await rpc.prompts.count == messages.count)
            _ = await session.shutdown()
            let resumedRPC = TestStallariRPC()
            let resumed = StallariSession(repository: f.repository, rpc: resumedRPC, hird: f.hird, threadID: thread.id)
            try await resumed.connect()
            #expect(await resumedRPC.prompts.isEmpty)
            _ = await resumed.shutdown(); try await f.cleanup()
        } catch { _ = await session.shutdown(); try await f.cleanup(); throw error }
    }
    @Test func failedProjectHandoffRemainsRetryable() async throws {
        let f = try await StallariFixture.make()
        let thread = try await f.repository.createProjectConversation(projectID: "p")
        let rpc = TestStallariRPC()
        let session = StallariSession(repository: f.repository, rpc: rpc, hird: f.hird, threadID: thread.id)
        do {
            await rpc.setFailure(true)
            await #expect(throws: (any Error).self) { try await session.connect() }
            #expect(try await f.repository.snapshot().threads.first { $0.id == thread.id }?.projectHandoffDeliveredAt == nil)
            await rpc.setFailure(false)
            try await session.connect()
            #expect(try await f.repository.snapshot().threads.first { $0.id == thread.id }?.projectHandoffDeliveredAt != nil)
            #expect(await rpc.prompts.filter { $0["message"]?.string?.contains("project-handoff:") == true }.count == 1)
            _ = await session.shutdown(); try await f.cleanup()
        } catch { _ = await session.shutdown(); try await f.cleanup(); throw error }
    }

    @Test func handoffBoundsProjectSectionsAndDoesNotInterpretMemoAsTemplate() async throws {
        let f = try await StallariFixture.make()
        do {
            try await f.repository.saveProject(.init(id: "other", name: "다른 프로젝트", absolutePath: f.directory.path))
            _ = try await f.legacyIssue(id: "foreign-context", title: "외부 요약", criteria: ["검사"], instruction: "검사", projectID: "other")
            let recent = try await f.issue("recent-complete")
            let run = try await f.dispatch("recent-run", issue: recent)
            try "ok".write(to: f.directory.appendingPathComponent("test.log"), atomically: true, encoding: .utf8)
            _ = try await f.session.receive(.init(id: "recent-event", runID: run, at: .now, payload: .complete(f.result(), notificationID: "recent-notice")))
            try await f.session.judge(issueID: recent, runID: run, evidence: [.init(criterionIndex: 0, verificationIDs: ["v"], explanation: "검사 통과")])
            _ = try await f.session.performTool("close_issue", arguments: .object([
                "issueID": .string(recent.rawValue), "reason": .string("applied"), "note": .string("완료 요약")]))
            _ = try await f.issue("open-old")
            _ = try await f.issue("open-new")
            let snapshot = try await f.repository.snapshot()
            var p = try #require(snapshot.projects.first { $0.id == "p" })
            p.settings.memo = "메모 {{criteria}}\n" + String(repeating: "메", count: 1000)
            p.settings.criteria = ["실제 기준"]
            var object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(ProjectSessionPolicy.current)) as? [String: Any])
            object["openIssueLimit"] = 1; object["recentIssueLimit"] = 1
            object["handoffSectionCharacters"] = 128; object["handoffMaximumCharacters"] = 2000
            let policy = try ProjectSessionPolicy.decode(JSONSerialization.data(withJSONObject: object))
            let text = policy.handoff(project: p, snapshot: snapshot)
            #expect(text.contains("메모 {{criteria}}"))
            #expect(text.contains("실제 기준") && text.contains("open-new") && text.contains("recent-complete"))
            #expect(!text.contains("open-old") && !text.contains("foreign-context"))
            #expect(!text.contains(String(repeating: "메", count: 129)))
            #expect(text.count <= 2000)
            object["handoffMaximumCharacters"] = 80
            let shorter = try ProjectSessionPolicy.decode(JSONSerialization.data(withJSONObject: object))
            #expect(shorter.handoff(project: p, snapshot: snapshot).count == 80)
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }
}
