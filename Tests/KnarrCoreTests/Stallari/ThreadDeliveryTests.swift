import Foundation
import Testing
@testable import KnarrCore

@Suite(.serialized) struct ThreadDeliveryTests {
    @Test func mainOriginKeepsIssueHandlingWithoutParentModelTurns() async throws {
        let f = try await StallariFixture.make()
        let id = try await f.session.createIssue(id: "main-owned", title: "메인의 목표", criteria: ["검사"], instruction: "검사")
        let threadID = try #require(try await f.repository.snapshot().issues.first { $0.id == id }?.conversationThreadID)
        let ownerRPC = TestStallariRPC()
        let owner = StallariSession(repository: f.repository, rpc: ownerRPC, hird: f.hird, threadID: threadID)
        var restarted: StallariSession?
        var reopened: SQLiteKnarrRepository?
        do {
            _ = try await f.repository.approveIssueProposal(issueID: id, version: 1, at: .now)
            let run = try await owner.dispatch(issueID: id, runID: "main-owned-run")
            let q = PersistedQuestion(id: "main-owned-question", runID: run, issueID: id, prompt: "검사 범위?", options: ["A"], createdAt: .now, source: .hird)
            let ask = HirdUpdate(id: "main-owned-ask", runID: run, at: .now, payload: .ask(q))
            _ = try await owner.receive(ask)
            _ = try await owner.receive(ask)
            try await f.session.deliverNotifications()
            try await f.session.deliverNotifications()
            #expect(await ownerRPC.prompts.filter { $0["message"]?.string?.contains("questionID=main-owned-question") == true }.count == 1)
            #expect(await f.rpc.prompts.filter { $0["message"]?.string?.contains("deliveryID=main:hird-question:main-owned-question") == true }.count == 0)
            await f.rpc.setFailure(true)
            let fail = HirdUpdate(id: "main-owned-fail", runID: run, at: .now, payload: .fail("검증 실패"))
            _ = try await owner.receive(fail)
            _ = try await owner.receive(fail)
            try await f.session.deliverNotifications()
            try await owner.updateIssueProposal(issueID: id, expectedVersion: 1, instruction: "같은 목표 보완", previousRunID: run)
            let next = try await owner.approveIssue(issueID: id, version: 2)
            let complete = HirdUpdate(id: "main-owned-complete", runID: next, at: .now, payload: .complete(f.result(), notificationID: "main-owned-notice"))
            _ = try await owner.receive(complete)
            _ = try await owner.receive(complete)
            try await f.session.deliverNotifications()
            #expect(try await f.repository.pendingThreadDeliveries(threadID: ConversationThread.defaultID).isEmpty)
            _ = await f.session.shutdown()
            _ = await owner.shutdown()
            let repository = try await SQLiteKnarrRepository.open(at: f.directory.appendingPathComponent("knarr.db"))
            reopened = repository
            #expect(try await repository.pendingThreadDeliveries(threadID: ConversationThread.defaultID).isEmpty)
            let rpc = TestStallariRPC()
            let main = StallariSession(repository: repository, rpc: rpc, hird: f.hird)
            restarted = main
            try await main.connect()
            try await main.deliverNotifications()
            #expect(await rpc.prompts.filter { $0["message"]?.string?.contains("main:hird-stopped:main-owned-run") == true }.count == 0)
            #expect(await rpc.prompts.filter { $0["message"]?.string?.contains("main:hird-complete:main-owned-notice") == true }.count == 0)
            #expect(await ownerRPC.prompts.filter { $0["message"]?.string?.contains("notificationID=main-owned-notice") == true }.count == 1)
            #expect(try await repository.snapshot().runs.count == 2)
            #expect(try await repository.pendingThreadDeliveries(threadID: ConversationThread.defaultID).isEmpty)
            _ = await main.shutdown()
            _ = await owner.shutdown()
            try await repository.close()
            try await f.cleanup()
        } catch { _ = await restarted?.shutdown(); _ = await owner.shutdown(); try await reopened?.close(); try await f.cleanup(); throw error }
    }
    @Test func questionsCompletionAndFailedDeliveryStayWithTheirIssueThread() async throws {
        let f = try await StallariFixture.make()
        let thread = ConversationThread(name: "다른 주제")
        try await f.repository.saveThread(thread)
        let rpc = TestStallariRPC()
        let source = StallariSession(repository: f.repository, rpc: TestStallariRPC(), hird: f.hird, threadID: thread.id)
        var session: StallariSession?
        do {
            try await f.session.connect()
            let first = try await f.issue("first")
            let firstRun = try await f.dispatch("first-run", issue: first)
            let second = try await source.createIssue(id: "second", title: "다른 주제 이슈", criteria: ["검사"], instruction: "검사한다")
            let ownerThreadID = try #require(try await f.repository.snapshot().issues.first { $0.id == second }?.conversationThreadID)
            let owner = StallariSession(repository: f.repository, rpc: rpc, hird: f.hird, threadID: ownerThreadID)
            session = owner
            try await owner.connect()
            _ = try await f.repository.approveIssueProposal(issueID: second, version: 1, at: .now)
            let secondRun = try await owner.dispatch(issueID: second, runID: "second-run")
            #expect(ownerThreadID != thread.id)
            let question = PersistedQuestion(id: "hird-question", runID: secondRun, issueID: second, prompt: "어느 옵션?", options: ["A", "B"], createdAt: .now, source: .hird)
            let ask = HirdUpdate(id: "ask-event", runID: secondRun, at: .now, payload: .ask(question))
            _ = try await owner.receive(ask)
            _ = try await owner.receive(ask)
            #expect(await rpc.prompts.filter { $0["message"]?.string?.contains("hird-question") == true }.count == 1)
            #expect(await f.rpc.prompts.isEmpty)
            let complete = HirdUpdate(id: "complete-event", runID: firstRun, at: .now, payload: .complete(f.result(), notificationID: "first-completion"))
            _ = try await f.session.receive(complete)
            try await owner.deliverNotifications()
            #expect(await f.rpc.prompts.filter { $0["message"]?.string?.contains("first-completion") == true }.count == 1)
            #expect(await rpc.prompts.allSatisfy { $0["message"]?.string?.contains("first-completion") != true })
            await rpc.setFailure(true)
            let failure = HirdUpdate(id: "failure-event", runID: secondRun, at: .now, payload: .fail("검사 실패"))
            _ = try await owner.receive(failure)
            _ = await owner.shutdown()
            let restartedRPC = TestStallariRPC()
            let restarted = StallariSession(repository: f.repository, rpc: restartedRPC, hird: f.hird, threadID: ownerThreadID)
            try await restarted.connect()
            try await restarted.deliverNotifications()
            #expect(await restartedRPC.prompts.filter { $0["message"]?.string?.contains("Hird run stopped") == true }.count == 1)
            #expect(await f.rpc.prompts.allSatisfy { $0["message"]?.string?.contains("second-run") != true })
            #expect(await restarted.shutdown().remainingProcessIDs.isEmpty)
            _ = await source.shutdown()
            try await f.cleanup()
        } catch { _ = await session?.shutdown(); _ = await source.shutdown(); try await f.cleanup(); throw error }
    }
}
