import Foundation
import Testing
@testable import KnarrCore

@Suite(.serialized) struct IssueApprovalTests {
    @Test func judgedCompletionTimePersistsUntilANewRunActuallyBegins() async throws {
        let f = try await StallariFixture.make()
        do {
            let id = try await f.issue("timing")
            let runID = try await f.dispatch("timing-run", issue: id)
            _ = try await f.session.receive(.init(id: "timing-complete", runID: runID,
                at: Date(timeIntervalSince1970: 20), payload: .complete(f.result(), notificationID: "timing-notice")))
            let before = Date.now
            try await f.session.judge(issueID: id, runID: runID,
                evidence: [.init(criterionIndex: 0, verificationIDs: ["v"], explanation: "검사 통과")])
            let snapshot = try await f.repository.snapshot()
            let completedAt = try #require(snapshot.issues.first { $0.id == id }?.completedAt)
            #expect(completedAt >= before)
            #expect(snapshot.issues.first { $0.id == id }?.hirds.first?.startedAt == snapshot.runs.first?.startedAt)
            try await f.session.judge(issueID: id, runID: runID,
                evidence: [.init(criterionIndex: 0, verificationIDs: ["v"], explanation: "검사 통과")])
            #expect(try await f.repository.snapshot().issues.first { $0.id == id }?.completedAt == completedAt)
            try await f.session.updateIssueProposal(issueID: id, expectedVersion: 1, instruction: "같은 목표 재검사", previousRunID: runID)
            #expect(try await f.repository.snapshot().issues.first { $0.id == id }?.completedAt == completedAt)
            _ = try await f.session.approveIssue(issueID: id, version: 2)
            #expect(try await f.repository.snapshot().issues.first { $0.id == id }?.completedAt == nil)
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }

    @Test func creatingIssueOwnsDedicatedNamedConversationWithoutCopyingMainHistory() async throws {
        let f = try await StallariFixture.make()
        do {
            let mainItem = ChatItem(at: .now, kind: .user("다른 이슈의 긴 대화는 전달하지 않아요"))
            try await f.repository.appendChat(mainItem, projectID: "p")
            let id = try await f.session.createIssue(id: "owned", title: "이슈 전용 대화", criteria: ["저장된 기준"], instruction: "정확한 실행 지시")
            let replay = try await f.session.createIssue(id: "owned", title: "이슈 전용 대화", criteria: ["저장된 기준"], instruction: "정확한 실행 지시")
            let snapshot = try await f.repository.snapshot()
            let issue = try #require(snapshot.issues.first { $0.id == id })
            #expect(replay == id)
            #expect(issue.conversationThreadID != ConversationThread.defaultID)
            #expect(snapshot.threads.first { $0.id == issue.conversationThreadID }?.name == issue.title)
            #expect(snapshot.threads.count == 2)
            #expect(snapshot.chatLinks.first { $0.chatID == mainItem.id }?.conversationThreadID == ConversationThread.defaultID)
            #expect(snapshot.chatLinks.contains { $0.issueID == id && $0.conversationThreadID == issue.conversationThreadID })
            try await f.session.updateIssueProposal(issueID: id, expectedVersion: 1, instruction: "같은 목표의 지시 보완")
            #expect(try await f.repository.snapshot().issues.first { $0.id == id }?.proposal?.version == 2)
            #expect(await f.hird.runs.isEmpty)
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }
    @Test func invalidNewIssueLeavesNoPartialConversationOrContext() async throws {
        let f = try await StallariFixture.make()
        do {
            let before = try await f.repository.snapshot()
            await #expect(throws: (any Error).self) {
                _ = try await f.session.createIssue(id: "invalid-owner", title: "원자적 생성", criteria: ["검사"],
                    instruction: "검사", previousRunID: "missing-run")
            }
            let after = try await f.repository.snapshot()
            #expect(after.threads == before.threads)
            #expect(after.issues == before.issues)
            #expect(after.chat == before.chat)
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }


    @Test func creatingIssuePersistsPendingProposalWithoutStartingHird() async throws {
        let f = try await StallariFixture.make()
        do {
            let id = try await f.session.createIssue(id: "pending", title: "검토할 변경", criteria: ["검사"], instruction: "승인 전에는 실행하지 않아요", model: "openai-codex/fixture-model", mode: .inspect)
            let issue = try #require(try await f.repository.snapshot().issues.first { $0.id == id })
            #expect(issue.state == .awaitingApproval)
            #expect(issue.proposal == IssueProposal(instruction: "승인 전에는 실행하지 않아요", model: "openai-codex/fixture-model", mode: .inspect, thinking: "xhigh"))
            #expect(issue.approval == nil)
            await #expect(throws: (any Error).self) { _ = try await f.session.dispatch(issueID: id, runID: "unapproved") }
            #expect(try await f.repository.snapshot().runs.isEmpty)
            #expect(await f.hird.runs.isEmpty)
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }

    @Test func userApprovalStartsExactSavedProposalWithoutModelPrompt() async throws {
        let f = try await StallariFixture.make()
        var owner: StallariSession?
        do {
            let id = try await f.session.createIssue(id: "exact", title: "승인", criteria: ["검사"], instruction: "저장된 지시 그대로", model: "openai-codex/fixture-model", mode: .inspect)
            await f.hird.setModel("openai-codex/second-model")
            let threadID = try #require(try await f.repository.snapshot().issues.first { $0.id == id }?.conversationThreadID)
            let session = StallariSession(repository: f.repository, rpc: TestStallariRPC(), hird: f.hird, threadID: threadID)
            owner = session
            let runID = try await session.approveIssue(issueID: id, version: 1)
            let saved = try await f.session.getRun(runID)
            #expect(saved.hird.role == "저장된 지시 그대로")
            #expect(saved.requestedModel == "openai-codex/fixture-model")
            #expect(saved.mode == .inspect)
            #expect(saved.previousRunID == nil)
            _ = try await f.session.selectModel("openai-codex/second-model")
            #expect(try await f.session.getRun(runID).requestedModel == "openai-codex/fixture-model")
            #expect(await f.rpc.prompts.isEmpty)
            let issue = try #require(try await f.repository.snapshot().issues.first)
            #expect(issue.approval?.version == 1)
            #expect(issue.approval?.runID == runID)
            _ = await owner?.shutdown()
            try await f.cleanup()
        } catch { _ = await owner?.shutdown(); try await f.cleanup(); throw error }
    }

    @Test func proposalUpdateInvalidatesApprovalAndRejectsStaleVersion() async throws {
        let f = try await StallariFixture.make()
        do {
            let id = try await f.issue("updated")
            _ = try await f.repository.approveIssueProposal(issueID: id, version: 1, at: .now)
            try await f.session.updateIssueProposal(issueID: id, expectedVersion: 1, instruction: "새 지시", model: "openai-codex/second-model", mode: .inspect)
            let issue = try #require(try await f.repository.snapshot().issues.first)
            #expect(issue.state == .awaitingApproval)
            #expect(issue.proposal?.version == 2)
            #expect(issue.proposal?.instruction == "새 지시")
            #expect(issue.approval == nil)
            #expect(issue.approvalHistory?.map(\.version) == [1])
            await #expect(throws: (any Error).self) { _ = try await f.session.approveIssue(issueID: id, version: 1) }
            await #expect(throws: (any Error).self) { _ = try await f.session.dispatch(issueID: id, runID: "stale") }
            await #expect(throws: (any Error).self) { try await f.session.updateIssueProposal(issueID: id, expectedVersion: 1, instruction: "덮어쓰기") }
            #expect(try await f.repository.snapshot().runs.isEmpty)
            let run = try await f.session.approveIssue(issueID: id, version: 2)
            #expect(try await f.session.getRun(run).hird.role == "새 지시")
            #expect(try await f.session.getRun(run).requestedModel == "openai-codex/second-model")
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }

    @Test func requestingProposalChangesPersistsNoteAndSendsStallariFollowUp() async throws {
        let f = try await StallariFixture.make()
        do {
            let id = try await f.issue("changes")
            _ = try await f.repository.approveIssueProposal(issueID: id, version: 1, at: .now)
            await f.rpc.setBusy(true)
            try await f.session.requestIssueProposalChanges(issueID: id, version: 1, note: "파일 범위를 줄여 주세요")
            let issue = try #require(try await f.repository.snapshot().issues.first)
            #expect(issue.state == .awaitingApproval)
            #expect(issue.approval == nil)
            #expect(issue.proposalReviewNote == "파일 범위를 줄여 주세요")
            #expect(await f.rpc.prompts.last?["message"]?.string?.contains("파일 범위를 줄여 주세요") == true)
            #expect(await f.rpc.prompts.last?["streamingBehavior"]?.string == "followUp")
            await #expect(throws: (any Error).self) { _ = try await f.session.dispatch(issueID: id, runID: "changes-run") }
            #expect(try await f.repository.snapshot().runs.isEmpty)
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }

    @Test func rejectionPreventsDispatchUntilRevisedProposalIsApproved() async throws {
        let f = try await StallariFixture.make()
        do {
            let id = try await f.issue("rejected")
            try await f.session.rejectIssueProposal(issueID: id, version: 1, note: "이번 변경은 하지 않아요")
            let rejected = try #require(try await f.repository.snapshot().issues.first)
            #expect(rejected.state == .rejected)
            #expect(rejected.proposalReviewNote == "이번 변경은 하지 않아요")
            await #expect(throws: (any Error).self) { _ = try await f.session.approveIssue(issueID: id, version: 1) }
            await #expect(throws: (any Error).self) { _ = try await f.session.dispatch(issueID: id, runID: "rejected-run") }
            try await f.session.updateIssueProposal(issueID: id, expectedVersion: 1, instruction: "다시 검토할 변경")
            #expect(try await f.repository.snapshot().issues.first?.state == .awaitingApproval)
            _ = try await f.session.approveIssue(issueID: id, version: 2)
            #expect(try await f.repository.snapshot().runs.count == 1)
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }

    @Test func concurrentDuplicateUserApprovalStartsOnlyOneRun() async throws {
        let f = try await StallariFixture.make()
        do {
            let id = try await f.issue("concurrent")
            async let first = f.session.approveIssue(issueID: id, version: 1)
            async let second = f.session.approveIssue(issueID: id, version: 1)
            let ids = try await [first, second]
            #expect(ids[0] == ids[1])
            for _ in 0..<200 { if await f.hird.runs.count == 1 { break }; await Task.yield() }
            #expect(await f.hird.runs.count == 1)
            #expect(try await f.repository.snapshot().runs.count == 1)
            #expect(try await f.session.approveIssue(issueID: id, version: 1) == ids[0])
            await #expect(throws: (any Error).self) { _ = try await f.session.dispatch(issueID: id, runID: "second-run") }
            #expect(try await f.repository.snapshot().runs.count == 1)
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }

    @Test func replacementApprovalPinsInstructionModelModeAndPreviousRun() async throws {
        let f = try await StallariFixture.make()
        do {
            let id = try await f.issue("replacement")
            let first = try await f.dispatch("first", issue: id)
            _ = try await f.session.receive(.init(id: "first-complete", runID: first, at: .now, payload: .complete(f.result(), notificationID: "first-notice")))
            try await f.session.updateIssueProposal(issueID: id, expectedVersion: 1, instruction: "보존된 결과를 읽기 전용으로 검토", model: "openai-codex/second-model", mode: .inspect, previousRunID: first)
            await f.hird.setModel("openai-codex/fixture-model")
            let second = try await f.session.approveIssue(issueID: id, version: 2)
            let run = try await f.session.getRun(second)
            #expect(run.hird.role == "보존된 결과를 읽기 전용으로 검토")
            #expect(run.requestedModel == "openai-codex/second-model")
            #expect(run.mode == .inspect)
            #expect(run.previousRunID == first)
            #expect(try await f.session.getRun(first).requestedModel == "openai-codex/fixture-model")
            #expect(try await f.repository.snapshot().issues.first?.approvalHistory?.map(\.version) == [1, 2])
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }

    @Test func activeRunPreventsReplacingItsConsumedProposal() async throws {
        let f = try await StallariFixture.make()
        do {
            let id = try await f.issue("active")
            let run = try await f.session.approveIssue(issueID: id, version: 1)
            await #expect(throws: (any Error).self) {
                try await f.session.updateIssueProposal(issueID: id, expectedVersion: 1, instruction: "실행 중 바꾼 지시")
            }
            let issue = try #require(try await f.repository.snapshot().issues.first)
            #expect(issue.proposal?.version == 1)
            #expect(issue.proposal?.instruction == "합계 수정")
            #expect(issue.approval?.runID == run)
            #expect(try await f.repository.snapshot().runs.count == 1)
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }

    @Test func oldResultCannotJudgeAReplacementProposalAwaitingApproval() async throws {
        let f = try await StallariFixture.make()
        do {
            let id = try await f.issue("replacement-judgement")
            let run = try await f.dispatch("old-result", issue: id)
            _ = try await f.session.receive(.init(id: "old-complete", runID: run, at: .now,
                payload: .complete(f.result(), notificationID: "old-notice")))
            try await f.session.updateIssueProposal(issueID: id, expectedVersion: 1, instruction: "새 범위")
            await #expect(throws: (any Error).self) {
                try await f.session.judge(issueID: id, runID: run,
                    evidence: [.init(criterionIndex: 0, verificationIDs: ["v"], explanation: "이전 실행 결과")])
            }
            let pending = try #require(try await f.repository.snapshot().issues.first)
            #expect(pending.state == .awaitingApproval)
            #expect(pending.acceptance.first?.state == .pending)
            #expect(pending.approval == nil)
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }

    @Test func restartPreservesPendingProposalWithoutImplicitApproval() async throws {
        let f = try await StallariFixture.make()
        let id = try await f.issue("restart")
        _ = await f.session.shutdown()
        try await f.repository.close()
        let reopened = try await SQLiteKnarrRepository.open(at: f.directory.appendingPathComponent("knarr.db"))
        let hird = TestHird(), rpc = TestStallariRPC()
        let session = StallariSession(repository: reopened, rpc: rpc, hird: hird)
        do {
            let issue = try #require(try await reopened.snapshot().issues.first)
            #expect(issue.id == id)
            #expect(issue.state == .awaitingApproval)
            #expect(issue.proposal?.version == 1)
            #expect(issue.approval == nil)
            await #expect(throws: (any Error).self) { _ = try await session.dispatch(issueID: id, runID: "restart-run") }
            #expect(await hird.runs.isEmpty)
            _ = try await session.approveIssue(issueID: id, version: 1)
            #expect(try await reopened.snapshot().runs.count == 1)
            _ = await session.shutdown()
            try await reopened.close()
            try FileManager.default.removeItem(at: f.directory)
        } catch { _ = await session.shutdown(); try await reopened.close(); try FileManager.default.removeItem(at: f.directory); throw error }
    }
}
