import Foundation
import Testing
@testable import KnarrCore

@Suite(.serialized) struct MainIssueManagementTests {
    @Test func closedPrimaryCannotBeUsedToCloseMoreIssues() async throws {
        let f = try await StallariFixture.make()
        do {
            let primary = try await f.issue("already-closed"), included = try await f.issue("still-open")
            _ = try await f.session.performTool("close_issue", arguments: .object([
                "issueID": .string(primary.rawValue), "reason": .string("cancelled"), "note": .string("취소")]))
            let before = try await f.repository.snapshot()
            await #expect(throws: (any Error).self) {
                _ = try await f.session.performTool("close_issue", arguments: .object([
                    "issueID": .string(primary.rawValue), "reason": .string("applied"), "note": .string("반영"),
                    "includedIssueIDs": .array([.string(included.rawValue)])]))
            }
            #expect(try await f.repository.snapshot().issues == before.issues)
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }

    @MainActor @Test func mainAnswerRoutesThroughLiveOwnerAndKeepsOtherQuestionWaiting() async throws {
        let f = try await LiveFixture.make()
        let projectThread = try await f.repository.createProjectConversation(projectID: "p")
        let project = StallariSession(repository: f.repository, rpc: TestStallariRPC(), hird: f.hird, threadID: projectThread.id)
        do {
            let id = try await project.createIssue(id: "project-question", title: "프로젝트 질문", criteria: ["검사"], instruction: "검사", model: "openai-codex/fixture-model")
            let issue = try #require(try await f.repository.snapshot().issues.first { $0.id == id })
            let rpc = TestStallariRPC()
            let owner = StallariSession(repository: f.repository, rpc: rpc, hird: f.hird, threadID: issue.conversationThreadID)
            f.store.setThreadFactory { thread in
                guard thread.id == issue.conversationThreadID else { throw StallariError.missingIssue }
                return LiveConversation(repository: f.repository, session: owner, rpc: rpc, hird: f.hird, threadID: thread.id)
            }
            let run = try await owner.approveIssue(issueID: id, version: 1)
            for questionID in ["first", "second"] {
                let q = PersistedQuestion(id: questionID, runID: run, issueID: id, prompt: questionID, options: [], createdAt: .now, source: .hird)
                _ = try await owner.receive(.init(id: "ask-" + questionID, runID: run, at: .now, payload: .ask(q)))
            }
            func args(_ questionID: String) -> OMPJSON {
                .object(["issueID": .string(id.rawValue), "runID": .string(run.rawValue), "questionID": .string(questionID), "text": .string("사용자 답변")])
            }
            await #expect(throws: (any Error).self) { _ = try await project.performTool("answer_hird_question", arguments: args("first")) }
            _ = try await f.session.performTool("answer_hird_question", arguments: args("first"))
            #expect(try await f.repository.snapshot().runs.first { $0.id == run }?.state == .waitingOnHuman)
            _ = try await f.session.performTool("answer_hird_question", arguments: args("second"))
            let after = try await f.repository.snapshot()
            #expect(after.runs.first { $0.id == run }?.state == .working)
            #expect(after.questions.allSatisfy { $0.state == .answered && $0.deliveredAt != nil })
            #expect(await f.hird.resolutions.map(\.questionID) == ["first", "second"])
            #expect(after.runs.count == 1)
            #expect(after.issues.first { $0.id == id }?.approval?.version == 1)
            _ = await project.shutdown(); try await f.cleanup()
        } catch { _ = await project.shutdown(); try await f.cleanup(); throw error }
    }

    @Test func answerToolResolvesOnlyPendingQuestionForExactRun() async throws {
        let f = try await StallariFixture.make()
        do {
            let id = try await f.issue("asking"), other = try await f.issue("other-asking")
            let run = try await f.dispatch("asking-run", issue: id), otherRun = try await f.dispatch("other-run", issue: other)
            let q = PersistedQuestion(id: "hird-question", runID: run, issueID: id, prompt: "어떤 방식?", options: ["A", "B"], createdAt: .now, source: .hird)
            _ = try await f.session.receive(.init(id: "hird-ask", runID: run, at: .now, payload: .ask(q)))
            #expect(try await f.repository.snapshot().runs.first { $0.id == run }?.state == .waitingOnHuman)
            func args(question: String = "hird-question", runID: HirdRun.ID = run, issueID: KnarrCore.Issue.ID = id, option: String = "B") -> OMPJSON {
                .object(["questionID": .string(question), "runID": .string(runID.rawValue), "issueID": .string(issueID.rawValue),
                    "selectedOptions": .array([.string(option)])])
            }
            for invalid in [args(question: "missing"), args(runID: otherRun), args(issueID: other), args(option: "invalid")] {
                await #expect(throws: (any Error).self) { _ = try await f.session.performTool("answer_hird_question", arguments: invalid) }
            }
            #expect(try await f.repository.snapshot().questions.first?.state == .pending)
            #expect(await f.hird.resolutions.isEmpty)
            let result = try await f.session.performTool("answer_hird_question", arguments: args())
            #expect(result["status"]?.string == "answered")
            let snapshot = try await f.repository.snapshot()
            #expect(snapshot.questions.first?.answer == .init(selectedOptions: ["B"], text: nil))
            #expect(snapshot.questions.first?.deliveredAt != nil)
            #expect(snapshot.runs.first { $0.id == run }?.state == .working)
            #expect(snapshot.runs.map(\.id) == [run, otherRun])
            #expect(await f.hird.resolutions.map(\.questionID) == ["hird-question"])
            await #expect(throws: (any Error).self) { _ = try await f.session.performTool("answer_hird_question", arguments: args()) }
            _ = try await f.session.ask(id: "late", runID: otherRun, issueID: other, prompt: "종료 후 답", options: ["B"])
            _ = try await f.session.cancelRun(otherRun)
            await #expect(throws: (any Error).self) {
                _ = try await f.session.performTool("answer_hird_question", arguments: args(question: "late", runID: otherRun, issueID: other))
            }
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }

    @Test func mainClosesIssueWithoutOriginButOtherConversationsCannot() async throws {
        let f = try await StallariFixture.make()
        let legacyThread = ConversationThread(name: "기존 소유 대화")
        try await f.repository.saveThread(legacyThread)
        var legacy = KnarrCore.Issue(id: "legacy-owned", title: "기존 이슈", projectName: "project", state: .running,
            headline: "", detail: "", acceptance: [], hirds: [], events: [], startedAt: .now)
        legacy.threadID = legacyThread.id
        try await f.repository.saveIssue(legacy, projectID: "p")
        let projectThread = try await f.repository.createProjectConversation(projectID: "p")
        let project = StallariSession(repository: f.repository, rpc: TestStallariRPC(), hird: f.hird, threadID: projectThread.id)
        do {
            let own = try await project.createIssue(id: "project-owned", title: "프로젝트 이슈", criteria: ["검사"], instruction: "검사")
            let args: OMPJSON = .object(["issueID": .string(legacy.id.rawValue), "reason": .string("applied"), "note": .string("사용자 정리 요청")])
            await #expect(throws: StallariError.missingIssue) { _ = try await project.performTool("close_issue", arguments: args) }
            let ownIssue = try #require(try await f.repository.snapshot().issues.first { $0.id == own })
            let issueSession = StallariSession(repository: f.repository, rpc: TestStallariRPC(), hird: f.hird, threadID: ownIssue.conversationThreadID)
            await #expect(throws: StallariError.missingIssue) { _ = try await issueSession.performTool("close_issue", arguments: args) }
            _ = await issueSession.shutdown()
            #expect(try await f.session.performTool("close_issue", arguments: args)["status"]?.string == "closed")
            #expect(try await f.session.performTool("close_issue", arguments: .object([
                "issueID": .string(own.rawValue), "reason": .string("cancelled"), "note": .string("정리")]))["status"]?.string == "closed")
            let snapshot = try await f.repository.snapshot()
            #expect(snapshot.issues.allSatisfy { $0.archivedAt != nil })
            #expect(snapshot.runs.isEmpty)
            _ = await project.shutdown(); try await f.cleanup()
        } catch { _ = await project.shutdown(); try await f.cleanup(); throw error }
    }

    @Test func projectCannotCloseAnotherProjectsIssueAndMainCannotCloseActiveIssue() async throws {
        let f = try await StallariFixture.make()
        try await f.repository.saveProject(.init(id: "other", name: "다른 프로젝트", absolutePath: f.directory.path))
        let first = try await f.repository.createProjectConversation(projectID: "p")
        let second = try await f.repository.createProjectConversation(projectID: "other")
        let a = StallariSession(repository: f.repository, rpc: TestStallariRPC(), hird: f.hird, threadID: first.id)
        let b = StallariSession(repository: f.repository, rpc: TestStallariRPC(), hird: f.hird, threadID: second.id)
        var owner: StallariSession?
        do {
            let id = try await b.createIssue(id: "other-owned", title: "다른 프로젝트", criteria: ["검사"], instruction: "검사")
            let args: OMPJSON = .object(["issueID": .string(id.rawValue), "reason": .string("applied"), "note": .string("정리")])
            await #expect(throws: StallariError.missingIssue) { _ = try await a.performTool("close_issue", arguments: args) }
            let issue = try #require(try await f.repository.snapshot().issues.first { $0.id == id })
            let workerOwner = StallariSession(repository: f.repository, rpc: TestStallariRPC(), hird: f.hird, threadID: issue.conversationThreadID)
            owner = workerOwner
            _ = try await workerOwner.approveIssue(issueID: id, version: 1)
            await #expect(throws: (any Error).self) { _ = try await f.session.performTool("close_issue", arguments: args) }
            #expect(try await f.repository.snapshot().issues.first { $0.id == id }?.archivedAt == nil)
            _ = await workerOwner.shutdown(); _ = await a.shutdown(); _ = await b.shutdown(); try await f.cleanup()
        } catch { _ = await owner?.shutdown(); _ = await a.shutdown(); _ = await b.shutdown(); try await f.cleanup(); throw error }
    }

    @Test func appliedBatchClosesIncludedIssuesAndReportsActiveSkip() async throws {
        let f = try await StallariFixture.make()
        do {
            let integrated = try await f.issue("integrated"), included = try await f.issue("included"), active = try await f.issue("active")
            _ = try await f.dispatch("active-run", issue: active)
            let result = try await f.session.performTool("close_issue", arguments: .object([
                "issueID": .string(integrated.rawValue), "reason": .string("applied"), "note": .string("함께 반영"),
                "includedIssueIDs": .array([.string(included.rawValue), .string(active.rawValue)])]))
            let snapshot = try await f.repository.snapshot()
            #expect(snapshot.issues.first { $0.id == included }?.archiveReason == IssueCloseReason.applied.rawValue)
            let readback = try await f.session.performTool("get_issue", arguments: .object(["issueID": .string(included.rawValue)]))
            #expect(readback["issue"]?["integratedInto"]?["rawValue"]?.string == integrated.rawValue)
            #expect(snapshot.issues.first { $0.id == active }?.archivedAt == nil)
            let results = try #require(result["includedIssues"]?.array)
            #expect(results.first { $0["issueID"]?.string == included.rawValue }?["status"]?.string == "closed")
            #expect(results.first { $0["issueID"]?.string == active.rawValue }?["status"]?.string == "skipped")
            #expect(results.first { $0["issueID"]?.string == active.rawValue }?["reason"]?.string == "진행 중인 이슈 실행이 있어요")
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }
}
