import Foundation
import Testing
@testable import KnarrCore

@MainActor @Suite(.serialized) struct IssueApprovalActionTests {
    @Test func pendingIssueIsVisibleAndRequiresUserApprovalAction() async throws {
        let f = try await LiveFixture.make()
        do {
            try await f.create()
            try await f.store.whenIdle()
            #expect(f.store.issues.first?.state == .awaitingApproval)
            #expect(f.store.issues.first?.proposal?.version == 1)
            #expect(await f.hird.runs.isEmpty)
            f.store.perform(.approveProposal(version: 1), on: "t")
            try await f.store.whenIdle()
            let run = try #require(try await f.repository.snapshot().runs.first)
            #expect(run.hird.role == "합계 함수를 고치고 검사해요")
            #expect(run.requestedModel == "openai-codex/fixture-gpt")
            #expect(f.store.issues.first?.state == .running)
            #expect(f.store.issues.first?.approval?.runID == run.id)
            #expect(await f.rpc.prompts.isEmpty)
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }

    @Test func proposalChangeActionSendsUserNoteAndLeavesIssuePending() async throws {
        let f = try await LiveFixture.make()
        do {
            try await f.create()
            f.store.perform(.requestProposalChanges(version: 1, note: "검사 계획도 적어 주세요"), on: "t")
            try await f.store.whenIdle()
            #expect(f.store.issues.first?.state == .awaitingApproval)
            #expect(f.store.issues.first?.proposalReviewNote == "검사 계획도 적어 주세요")
            #expect(await f.rpc.prompts.last?["message"]?.string?.contains("검사 계획도 적어 주세요") == true)
            #expect(try await f.repository.snapshot().runs.isEmpty)
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }

    @Test func rejectingProposalFromUIStartsNoRun() async throws {
        let f = try await LiveFixture.make()
        do {
            try await f.create()
            f.store.perform(.rejectProposal(version: 1, note: "실행하지 마세요"), on: "t")
            try await f.store.whenIdle()
            #expect(f.store.issues.first?.state == .rejected)
            #expect(f.store.issues.first?.proposalReviewNote == "실행하지 마세요")
            #expect(f.store.issues.first?.approval == nil)
            #expect(try await f.repository.snapshot().runs.isEmpty)
            #expect(await f.hird.runs.isEmpty)
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }

    @Test func staleApprovalActionCannotStartRevisedProposal() async throws {
        let f = try await LiveFixture.make()
        do {
            try await f.create()
            try await f.session.updateIssueProposal(issueID: "t", expectedVersion: 1, instruction: "달라진 실행 범위")
            f.store.perform(.approveProposal(version: 1), on: "t")
            try await f.store.whenIdle()
            #expect(f.store.lastError != nil)
            #expect(f.store.issues.first?.state == .awaitingApproval)
            #expect(f.store.issues.first?.proposal?.version == 2)
            #expect(try await f.repository.snapshot().runs.isEmpty)
            #expect(await f.hird.runs.isEmpty)
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }
}
